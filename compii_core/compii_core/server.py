"""Compii Core HTTP + WebSocket service. Binds to localhost only and requires a per-install token."""

from __future__ import annotations

import asyncio
import os
import secrets
import subprocess
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from . import __version__
from .agent import Agent, Brain, ClaudeBrain
from .journal import Journal
from .policy import ActionKind, Autonomy, Policy
from .screen import make_dpi_aware
from .tools import Toolbox, ToolError, default_roots
from .voice import Voice

HOST = "127.0.0.1"
PORT = int(os.environ.get("COMPII_PORT", "8765"))


def workspace_dir() -> Path:
    return Path(os.environ.get("COMPII_HOME", Path.home() / "Compii"))


class NewTask(BaseModel):
    request: str


class Decision(BaseModel):
    approved: bool


class DialChange(BaseModel):
    kind: ActionKind
    level: Autonomy


class Reply(BaseModel):
    text: str


class VoiceSettingsBody(BaseModel):
    speak_replies: bool | None = None
    engine: str | None = None
    voice: str | None = None
    speed: float | None = None


class DownloadBody(BaseModel):
    what: str


class FileRequest(BaseModel):
    path: str


class PointRequest(BaseModel):
    """Point at an item by its label, or at an exact screen rectangle (physical pixels)."""

    target: str = ""
    message: str = ""
    x: int | None = None
    y: int | None = None
    w: int = 40
    h: int = 40


class Hub:
    """Fans task events out to every connected client."""

    def __init__(self) -> None:
        self.clients: set[WebSocket] = set()
        self.loop: asyncio.AbstractEventLoop | None = None

    def emit_threadsafe(self, event: dict[str, Any]) -> None:
        """For events from audio threads."""
        if self.loop is not None and not self.loop.is_closed():
            asyncio.run_coroutine_threadsafe(self.emit({"task_id": "", "at": time.time(), **event}), self.loop)

    async def emit(self, event: dict[str, Any]) -> None:
        for ws in list(self.clients):
            try:
                await ws.send_json(event)
            except Exception:  # noqa: BLE001 - a dead client must not break the task
                self.clients.discard(ws)


def build_app(brain: Brain | None = None, workspace: Path | None = None, roots: list[Path] | None = None,
              token: str | None = None, voice: Voice | None = None) -> FastAPI:
    workspace = workspace or workspace_dir()
    workspace.mkdir(parents=True, exist_ok=True)
    token = token or secrets.token_urlsafe(24)
    (workspace / "core-token").write_text(token, encoding="utf-8")

    mode = os.environ.get("COMPII_BRAIN", "claude")
    # Rehearsal never opens windows on the user's desktop.
    open_fn = (lambda _target: None) if mode == "rehearsal" else None
    toolbox = Toolbox(roots if roots is not None else default_roots(), workspace, open_fn)
    if brain is None:
        if mode == "rehearsal":
            from .rehearsal import RehearsalBrain

            brain = RehearsalBrain(Path.home() / "Downloads", workspace)
        else:
            brain = ClaudeBrain()
            mode = "claude"
    hub = Hub()
    voice = voice or Voice(workspace / "models", hub.emit_threadsafe)
    toolbox.on_point = lambda p: hub.emit_threadsafe({"type": "point", **p})

    async def agent_emit(event: dict[str, Any]) -> None:
        await hub.emit(event)
        # Jarvis-style: Compii says its answers and its questions out loud.
        if voice.settings.speak_replies:
            if event["type"] == "task_finished" and event.get("status") in ("done", "failed"):
                voice.say(event.get("text", ""))
            elif event["type"] == "approval_needed":
                voice.say(f"I need your okay. {event.get('label', '')}")

    agent = Agent(brain, toolbox, Policy(), Journal(workspace / "journal.jsonl"), agent_emit)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        hub.loop = asyncio.get_running_loop()
        voice.warm_up()
        yield
        agent.stop_all()
        voice.cancel_listening()
        voice.stop_speaking()
        if toolbox._browser is not None:
            toolbox._browser.close()

    app = FastAPI(title="Compii Core", version=__version__, lifespan=lifespan)
    app.state.agent = agent
    app.state.voice = voice

    def auth(x_compii_token: str = Header("")) -> None:
        if not secrets.compare_digest(x_compii_token, token):
            raise HTTPException(401, "Missing or wrong Compii token")

    def task_view(t: Any) -> dict[str, Any]:
        return {"id": t.id, "request": t.request, "status": t.status, "created": t.created, "events": t.events}

    @app.get("/health")
    def health() -> dict[str, Any]:
        has_key = bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))
        return {"ok": True, "version": __version__, "brain": mode,
                "credentials": "found" if has_key or mode != "claude" else "not_found"}

    @app.post("/tasks", dependencies=[Depends(auth)])
    async def create_task(body: NewTask) -> dict[str, Any]:
        if not body.request.strip():
            raise HTTPException(400, "Empty request")
        return task_view(agent.start(body.request.strip()))

    @app.get("/tasks", dependencies=[Depends(auth)])
    def list_tasks() -> list[dict[str, Any]]:
        return [task_view(t) for t in sorted(agent.tasks.values(), key=lambda t: t.created, reverse=True)]

    @app.post("/tasks/{task_id}/messages", dependencies=[Depends(auth)])
    async def follow_up(task_id: str, body: Reply) -> dict[str, Any]:
        if not body.text.strip():
            raise HTTPException(400, "Empty message")
        try:
            return task_view(agent.reply(task_id, body.text.strip()))
        except KeyError as e:
            raise HTTPException(404, "No such conversation") from e
        except RuntimeError as e:
            raise HTTPException(409, str(e)) from e

    @app.get("/memory", dependencies=[Depends(auth)])
    def memory() -> list[dict[str, Any]]:
        return toolbox.memories()

    @app.delete("/memory/{memory_id}", dependencies=[Depends(auth)])
    def forget(memory_id: int) -> dict[str, bool]:
        if not toolbox.forget(memory_id):
            raise HTTPException(404, "No such memory")
        return {"ok": True}

    @app.post("/files/open", dependencies=[Depends(auth)])
    def open_file(body: FileRequest) -> dict[str, bool]:
        try:
            p = toolbox.path(body.path)
        except ToolError as e:
            raise HTTPException(403, str(e)) from e
        if not p.exists():
            raise HTTPException(404, "File not found")
        toolbox._open(str(p))
        return {"ok": True}

    @app.post("/files/reveal", dependencies=[Depends(auth)])
    def reveal_file(body: FileRequest) -> dict[str, bool]:
        """Show the file selected in File Explorer."""
        try:
            p = toolbox.path(body.path)
        except ToolError as e:
            raise HTTPException(403, str(e)) from e
        if not p.exists():
            raise HTTPException(404, "File not found")
        if sys.platform == "win32":
            subprocess.Popen(["explorer.exe", f"/select,{p}"])
        else:
            toolbox._open(str(p.parent))
        return {"ok": True}

    @app.get("/voice", dependencies=[Depends(auth)])
    def voice_status() -> dict[str, Any]:
        return voice.status()

    @app.put("/voice/settings", dependencies=[Depends(auth)])
    def voice_settings(body: VoiceSettingsBody) -> dict[str, Any]:
        if body.speak_replies is not None:
            voice.settings.speak_replies = body.speak_replies
            if not body.speak_replies:
                voice.stop_speaking()
        if body.voice is not None:
            voice.settings.voice = body.voice
        if body.engine in ("natural", "windows"):
            voice.stop_speaking()
            voice.settings.engine = body.engine
        if body.speed is not None:
            voice.settings.speed = max(.7, min(1.4, body.speed))
        return voice.status()

    @app.post("/voice/download", dependencies=[Depends(auth)])
    def voice_download(body: DownloadBody) -> dict[str, Any]:
        try:
            voice.download(body.what)
        except ValueError as e:
            raise HTTPException(400, "Unknown download") from e
        return voice.status()

    @app.post("/voice/listen/start", dependencies=[Depends(auth)])
    def listen_start() -> dict[str, bool]:
        try:
            voice.start_listening()
        except RuntimeError as e:
            raise HTTPException(409, str(e)) from e
        except Exception as e:  # noqa: BLE001 - e.g. no microphone
            raise HTTPException(500, f"Couldn't open the microphone: {e}") from e
        return {"listening": True}

    @app.post("/voice/listen/stop", dependencies=[Depends(auth)])
    async def listen_stop() -> dict[str, str]:
        return {"text": await asyncio.to_thread(voice.stop_listening)}

    @app.post("/voice/listen/cancel", dependencies=[Depends(auth)])
    def listen_cancel() -> dict[str, bool]:
        voice.cancel_listening()
        return {"ok": True}

    @app.post("/voice/say", dependencies=[Depends(auth)])
    def say(body: Reply) -> dict[str, bool]:
        voice.say(body.text)
        return {"ok": True}

    @app.post("/voice/quiet", dependencies=[Depends(auth)])
    def quiet() -> dict[str, bool]:
        voice.stop_speaking()
        return {"ok": True}

    @app.post("/tasks/{task_id}/stop", dependencies=[Depends(auth)])
    def stop_task(task_id: str) -> dict[str, bool]:
        voice.stop_speaking()
        return {"stopped": agent.stop(task_id)}

    @app.post("/stop", dependencies=[Depends(auth)])
    def stop_everything() -> dict[str, int]:
        voice.stop_speaking()
        return {"stopped": agent.stop_all()}

    @app.post("/tasks/{task_id}/undo", dependencies=[Depends(auth)])
    def undo(task_id: str) -> dict[str, str]:
        return {"result": agent.journal.undo_last(task_id)}

    @app.post("/approvals/{approval_id}", dependencies=[Depends(auth)])
    def decide(approval_id: str, body: Decision) -> dict[str, bool]:
        if not agent.decide(approval_id, body.approved):
            raise HTTPException(404, "No pending approval with that id")
        return {"ok": True}

    @app.post("/point", dependencies=[Depends(auth)])
    async def point(body: PointRequest) -> dict[str, Any]:
        """Point at something on screen directly (used by the phone and for testing)."""
        if body.x is not None and body.y is not None:
            point = {"name": body.target, "role": "", "window": "", "x": body.x, "y": body.y,
                     "w": body.w, "h": body.h, "message": body.message}
            await hub.emit({"type": "point", "task_id": "", "at": time.time(), **point})
            return point
        if not body.target.strip():
            raise HTTPException(400, "Give a target label or x and y")
        try:
            result = await asyncio.to_thread(
                toolbox.execute, "point_at", {"target": body.target, "message": body.message}
            )
        except ToolError as e:
            raise HTTPException(404, str(e)) from e
        await hub.emit({"type": "point", "task_id": "", "at": time.time(), **(result.point or {})})
        return result.point or {}

    @app.get("/policy", dependencies=[Depends(auth)])
    def get_policy() -> dict[str, str]:
        return {k.value: v.value for k, v in agent.policy.dial.items()}

    @app.put("/policy", dependencies=[Depends(auth)])
    def set_policy(body: DialChange) -> dict[str, str]:
        try:
            agent.policy.set(body.kind, body.level)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return get_policy()

    @app.websocket("/events")
    async def events(ws: WebSocket, t: str = Query("")) -> None:
        if not secrets.compare_digest(t, token):
            await ws.close(code=4401)
            return
        await ws.accept()
        hub.clients.add(ws)
        try:
            while True:
                await ws.receive_text()  # keepalive pings from the client
        except WebSocketDisconnect:
            pass
        finally:
            hub.clients.discard(ws)

    return app


def main() -> None:
    import uvicorn

    make_dpi_aware()

    uvicorn.run(build_app(), host=HOST, port=PORT, log_level="info")


if __name__ == "__main__":
    main()
