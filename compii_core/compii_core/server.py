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
from . import proactive as pro
from .tools import Tool
from .policy import ActionKind as AK

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


class RoutineBody(BaseModel):
    title: str
    instruction: str
    schedule: dict[str, Any]


class WatchBody(BaseModel):
    title: str
    kind: str
    spec: dict[str, Any]
    every_minutes: int | None = None


class ToggleBody(BaseModel):
    enabled: bool


class BriefBody(BaseModel):
    enabled: bool | None = None
    at: str | None = None


class ReadBody(BaseModel):
    id: str | None = None


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

    plans = pro.Proactive(workspace / "proactive.json")

    async def post(update: pro.Update, speak: bool = True) -> None:
        plans.post(update)
        await hub.emit({"type": "update", "task_id": "", "at": time.time(), **pro.asdict(update)})
        if speak and voice.settings.speak_replies:
            voice.say(update.body if update.kind == "brief" else f"{update.title}. {update.body}")

    async def agent_emit(event: dict[str, Any]) -> None:
        await hub.emit(event)
        task = agent.tasks.get(event.get("task_id", ""))
        origin = task.origin if task else None
        if origin and "watch" in origin:
            # AI watches run quietly; only a "YES" becomes an update.
            if event["type"] == "task_finished":
                await _finish_ai_watch(origin["watch"], event.get("text", ""))
            return
        if origin and "routine" in origin:
            if event["type"] == "task_finished":
                await post(pro.Update("routine", f"Routine: {origin['title']}", event.get("text", ""), task_id=task.id))
                return
            if event["type"] == "approval_needed":
                await post(pro.Update("needs_you", f"Routine needs you: {origin['title']}",
                                      str(event.get("label", "")), task_id=task.id))
                return
        # Jarvis-style: Compii says its answers and its questions out loud.
        if voice.settings.speak_replies:
            if event["type"] == "task_finished" and event.get("status") in ("done", "failed"):
                voice.say(event.get("text", ""))
            elif event["type"] == "approval_needed":
                voice.say(f"I need your okay. {event.get('label', '')}")

    async def _finish_ai_watch(watch_id: str, text: str) -> None:
        w = plans.watches.get(watch_id)
        first = text.strip().splitlines()[0] if text.strip() else ""
        if w and first.upper().startswith("YES"):
            w.last_triggered = pro._now().isoformat()
            plans.save()
            await post(pro.Update("watch", w.title, first[3:].lstrip(" :—-") or "It happened."))

    async def tick() -> None:
        """One pass of the proactive loop: brief, routines, watches."""
        now = pro._now()
        b = plans.brief
        if b.get("enabled") and b.get("last") != now.date().isoformat():
            h, m = b.get("at", "08:00").split(":")
            if now.time() >= pro.dt.time(int(h), int(m)):
                b["last"] = now.date().isoformat()
                await post(pro.compose_brief(tasks=list(agent.tasks.values()), proactive=plans,
                                             downloads=_downloads(toolbox), now=now))
        for r in plans.due_routines(now):
            task = agent.start(r.instruction, origin={"routine": r.id, "title": r.title})
            plans.mark_ran(r, now, task.id)
        for w in plans.due_watches(now):
            w.last_check = now.isoformat()
            try:
                if w.kind == "folder":
                    new = await asyncio.to_thread(pro.check_folder, w, toolbox.path)
                    if new:
                        w.last_triggered = now.isoformat()
                        names = ", ".join(new[:4]) + (f" and {len(new) - 4} more" if len(new) > 4 else "")
                        await post(pro.Update("watch", w.title, f"New: {names}"))
                elif w.kind == "web":
                    msg = await asyncio.to_thread(pro.check_web, w)
                    if msg:
                        w.last_triggered = now.isoformat()
                        await post(pro.Update("watch", w.title, msg))
                else:
                    agent.start(
                        f"Check this for me: {w.spec['check']}\n\nAnswer on the first line with YES or NO: "
                        f"{w.spec.get('notify_when') or 'is there something I should know now?'} "
                        "After YES, add one short sentence saying what you found.",
                        origin={"watch": w.id, "title": w.title},
                    )
                w.error = None
            except Exception as e:  # noqa: BLE001 - one bad watch must not stop the others
                w.error = str(e)[:200]
            plans.save()

    async def loop() -> None:
        while True:
            try:
                await tick()
            except Exception:  # noqa: BLE001
                pass
            await asyncio.sleep(20)

    agent = Agent(brain, toolbox, Policy(), Journal(workspace / "journal.jsonl"), agent_emit)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        hub.loop = asyncio.get_running_loop()
        voice.warm_up()
        ticker = asyncio.create_task(loop())
        yield
        ticker.cancel()
        agent.stop_all()
        voice.cancel_listening()
        voice.stop_speaking()
        if toolbox._browser is not None:
            toolbox._browser.close()

    app = FastAPI(title="Compii Core", version=__version__, lifespan=lifespan)
    app.state.agent = agent
    app.state.voice = voice
    app.state.plans = plans
    app.state.tick = tick
    _proactive_tools(toolbox, plans)

    def auth(x_compii_token: str = Header("")) -> None:
        if not secrets.compare_digest(x_compii_token, token):
            raise HTTPException(401, "Missing or wrong Compii token")

    def task_view(t: Any) -> dict[str, Any]:
        return {"id": t.id, "request": t.request, "status": t.status, "created": t.created, "events": t.events,
                "origin": t.origin}

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

    @app.get("/proactive", dependencies=[Depends(auth)])
    def proactive_view() -> dict[str, Any]:
        return plans.view()

    @app.post("/routines", dependencies=[Depends(auth)])
    def add_routine(body: RoutineBody) -> dict[str, Any]:
        try:
            plans.add_routine(body.title, body.instruction, body.schedule)
        except (ValueError, KeyError) as e:
            raise HTTPException(400, str(e)) from e
        return plans.view()

    @app.post("/watches", dependencies=[Depends(auth)])
    def add_watch(body: WatchBody) -> dict[str, Any]:
        spec = dict(body.spec)
        if body.kind == "folder":
            if not str(spec.get("folder", "")).strip():
                raise HTTPException(400, "A folder watch needs a folder.")
            try:
                spec["folder"] = str(toolbox.path(str(spec.get("folder", ""))))
            except ToolError as e:
                raise HTTPException(403, str(e)) from e
        try:
            plans.add_watch(body.title, body.kind, spec, body.every_minutes)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return plans.view()

    @app.patch("/proactive/{item_id}", dependencies=[Depends(auth)])
    def toggle(item_id: str, body: ToggleBody) -> dict[str, Any]:
        if not plans.set_enabled(item_id, body.enabled):
            raise HTTPException(404, "No such routine or watch")
        return plans.view()

    @app.delete("/proactive/{item_id}", dependencies=[Depends(auth)])
    def remove(item_id: str) -> dict[str, Any]:
        if not plans.remove(item_id):
            raise HTTPException(404, "No such routine or watch")
        return plans.view()

    @app.post("/routines/{routine_id}/run", dependencies=[Depends(auth)])
    async def run_now(routine_id: str) -> dict[str, Any]:
        r = plans.routines.get(routine_id)
        if r is None:
            raise HTTPException(404, "No such routine")
        task = agent.start(r.instruction, origin={"routine": r.id, "title": r.title})
        r.last_run, r.last_task = pro._now().isoformat(), task.id  # the schedule itself is unchanged
        plans.save()
        return task_view(task)

    @app.put("/brief", dependencies=[Depends(auth)])
    def brief_settings(body: BriefBody) -> dict[str, Any]:
        if body.at is not None:
            try:
                h, m = body.at.split(":")
                pro.dt.time(int(h), int(m))
            except ValueError as e:
                raise HTTPException(400, "Use a time like 08:00") from e
            plans.brief["at"] = body.at
        if body.enabled is not None:
            plans.brief["enabled"] = body.enabled
        plans.save()
        return plans.view()

    @app.post("/brief/now", dependencies=[Depends(auth)])
    async def brief_now() -> dict[str, Any]:
        update = pro.compose_brief(tasks=list(agent.tasks.values()), proactive=plans,
                                   downloads=_downloads(toolbox), now=pro._now())
        await post(update)
        return pro.asdict(update)

    @app.post("/inbox/read", dependencies=[Depends(auth)])
    def inbox_read(body: ReadBody) -> dict[str, Any]:
        plans.mark_read(body.id)
        return plans.view()

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


def _proactive_tools(toolbox, plans: "pro.Proactive") -> None:
    """Tools the agent uses when you ask for routines and watches in plain language."""
    from .tools import ToolError, ToolResult

    def create_routine(a: dict[str, Any]) -> ToolResult:
        try:
            r = plans.add_routine(a["title"], a["instruction"], a["schedule"])
        except (ValueError, KeyError) as e:
            raise ToolError(f"Couldn't schedule that: {e}") from e
        return ToolResult(f"Routine “{r.title}” scheduled: {pro.describe(r.schedule)}. Next run {r.next_run}.")

    def create_watch(a: dict[str, Any]) -> ToolResult:
        kind = a["kind"]
        spec = {k: a[k] for k in ("folder", "pattern", "url", "contains", "check", "notify_when") if a.get(k)}
        if kind == "folder":
            if not str(spec.get("folder", "")).strip():
                raise ToolError("Which folder should I watch?")
            spec["folder"] = str(toolbox.path(spec["folder"]))
        try:
            w = plans.add_watch(a["title"], kind, spec, a.get("every_minutes"))
        except ValueError as e:
            raise ToolError(str(e)) from e
        cost = " (uses Claude on each check)" if kind == "ai" else " (free, checked locally)"
        return ToolResult(f"Watching “{w.title}” every {w.every_minutes} minutes{cost}.")

    def list_plans(a: dict[str, Any]) -> ToolResult:
        v = plans.view()
        lines = [f"- routine {r['id']}: {r['title']} — {r['when']}{'' if r['enabled'] else ' (paused)'}" for r in v["routines"]]
        lines += [f"- watch {w['id']}: {w['title']} ({w['kind']}, every {w['every_minutes']} min)" for w in v["watches"]]
        b = v["brief"]
        lines.append(f"- daily brief: {'on at ' + b['at'] if b['enabled'] else 'off'}")
        return ToolResult("\n".join(lines))

    def remove_plan(a: dict[str, Any]) -> ToolResult:
        if not plans.remove(a["id"]):
            raise ToolError("No routine or watch with that id; list them first.")
        return ToolResult("Removed.")

    s = {"type": "string"}
    schedule = {
        "type": "object",
        "description": "When it runs. kind: daily | weekdays | weekly (with days) | every (with minutes) | once (with date).",
        "properties": {
            "kind": {"type": "string", "enum": ["daily", "weekdays", "weekly", "every", "once"]},
            "at": {"type": "string", "description": "24-hour time, e.g. 07:30"},
            "days": {"type": "array", "items": {"type": "string", "enum": pro.DAYS}},
            "minutes": {"type": "integer"},
            "date": {"type": "string", "description": "YYYY-MM-DD, for once"},
        },
        "required": ["kind"],
        "additionalProperties": False,
    }
    for t in [
        Tool("create_routine", "Schedule something for Compii to do on its own, e.g. every weekday at 8. "
             "The instruction is what you would be asked to do at that time.",
             {"title": s, "instruction": s, "schedule": schedule}, ["title", "instruction", "schedule"],
             AK.CHANGE, create_routine, lambda a: f"Schedule “{a['title']}”"),
        Tool("create_watch", "Tell the user when something happens. kind=folder (new files matching a pattern; free), "
             "web (a page starts containing some text, or changes; free), ai (anything needing judgement; uses Claude, at most every 30 min).",
             {"title": s, "kind": {"type": "string", "enum": ["folder", "web", "ai"]},
              "folder": s, "pattern": s, "url": s, "contains": s, "check": s, "notify_when": s,
              "every_minutes": {"type": "integer"}}, ["title", "kind"],
             AK.CHANGE, create_watch, lambda a: f"Watch “{a['title']}”"),
        Tool("list_routines_and_watches", "List scheduled routines, watches and the daily brief setting.", {}, [],
             AK.READ, list_plans, lambda a: "Look at routines and watches"),
        Tool("remove_routine_or_watch", "Remove a routine or watch by id.", {"id": s}, ["id"],
             AK.DELETE, remove_plan, lambda a: f"Remove {a['id']}"),
    ]:
        toolbox.tools[t.name] = t


def _downloads(toolbox) -> Path | None:
    """The Downloads folder Compii is allowed to look in, if any."""
    return next((r for r in toolbox.roots if r.name.lower() == "downloads"), None)
