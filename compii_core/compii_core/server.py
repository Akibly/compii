"""Compii Core HTTP + WebSocket service. Binds to localhost only and requires a per-install token."""

from __future__ import annotations

import asyncio
import json
import os
import secrets
import socket
import subprocess
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from . import __version__
from .agent import Agent, Brain
from .audit import AuditLog
from .keys import KeyStore, KeyStoreError
from .policy import Rule
from . import providers as prov
from .skills import Skills, from_task, skill_tools, suggest_name
from .walkthrough import Walkthroughs
from . import intents
from .buddy import Buddy
from .journal import Journal
from .policy import ActionKind, Autonomy, Policy
from .screen import make_dpi_aware
from .tools import Toolbox, ToolError, default_roots
from .voice import Voice
from .remote import Pairing, RemoteHost, lan_ip, pairing_link
from . import proactive as pro
from .tools import Tool
from .policy import ActionKind as AK

HOST = "127.0.0.1"
PORT = int(os.environ.get("COMPII_PORT", "8765"))
REMOTE_PORT = int(os.environ.get("COMPII_REMOTE_PORT", "8766"))


def workspace_dir() -> Path:
    return Path(os.environ.get("COMPII_HOME", Path.home() / "Compii"))


class NewTask(BaseModel):
    request: str


class Decision(BaseModel):
    approved: bool
    always: bool = False  # "Always allow": saves a rule (only from this PC)


class DialChange(BaseModel):
    kind: ActionKind
    level: Autonomy


class ClaimBody(BaseModel):
    code: str
    name: str = "Phone"


class Reply(BaseModel):
    text: str


class Choice(BaseModel):
    provider: str = "claude"
    model: str = ""
    base_url: str = ""


class BrainBody(BaseModel):
    primary: Choice
    fallback: Choice | None = None
    fallback_enabled: bool = False


class KeyBody(BaseModel):
    value: str


class SkillBody(BaseModel):
    name: str = ""


class SkillRoutineBody(BaseModel):
    schedule: dict[str, Any]


KEY_NAMES = {"anthropic", "groq", "gemini", "nvidia", "ollama", "openrouter", "openai", "custom"}


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
    wake_word: bool | None = None
    engine: str | None = None
    voice: str | None = None
    speed: float | None = None
    cloud_listening: bool | None = None


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
              token: str | None = None, voice: Voice | None = None, keys: KeyStore | None = None) -> FastAPI:
    workspace = workspace or workspace_dir()
    workspace.mkdir(parents=True, exist_ok=True)
    token = token or secrets.token_urlsafe(24)
    (workspace / "core-token").write_text(token, encoding="utf-8")

    mode = os.environ.get("COMPII_BRAIN", "claude")
    # Rehearsal never opens windows on the user's desktop.
    open_fn = (lambda _target: None) if mode == "rehearsal" else None
    toolbox = Toolbox(roots if roots is not None else default_roots(), workspace, open_fn)
    keys = keys or KeyStore()
    brain_file = workspace / "brain.json"
    brain_settings = prov.BrainSettings.load(brain_file)
    fixed_brain = brain is not None or mode == "rehearsal"  # tests and rehearsal keep their brain
    if brain is None and mode == "rehearsal":
        from .rehearsal import RehearsalBrain

        brain = RehearsalBrain(Path.home() / "Downloads", workspace)
    brain_state: dict[str, Any] = {"probe": None, "fallback_note": None, "problem": None}
    hub = Hub()
    voice = voice or Voice(workspace / "models", hub.emit_threadsafe)
    toolbox.on_point = lambda p: hub.emit_threadsafe({"type": "point", **p})
    voice_file = workspace / "voice.json"
    voice.cloud_key = lambda: keys.get("groq") or prov._env_key("groq")  # fast speech recognition, if stored

    async def act_on(text: str) -> bool:
        """Short spoken commands ("yes", "no", "stop", "quiet") act at once,
        without the AI. Returns True when the words were one of those."""
        pending = list(agent._pending.items())
        approval_id, info = pending[-1] if pending else (None, None)
        intent = intents.parse(text, info[2].value if info else None)
        if intent is None:
            return False
        if intent.kind == "quiet":
            voice.stop_speaking()
        elif intent.kind in ("approve", "decline") and approval_id:
            agent.decide(approval_id, intent.kind == "approve")
            audit.record("voice_answer", tool=info[0], answer=intent.kind)
        elif intent.kind == "stop":
            agent.stop_all()
            voice.stop_speaking()
        await hub.emit({"type": "voice_intent", "task_id": "", "at": time.time(), "kind": intent.kind,
                        "text": text, "reply": intent.reply, "label": info[3] if info else ""})
        if intent.reply and voice.settings.speak_replies and intent.kind != "stop":
            voice.say(intent.reply)
        return True

    async def hands_free(text: str) -> None:
        """A request heard after "Hey Compii": the app routes it (to the open
        conversation or a new one); with no app connected, Core starts one."""
        if await act_on(text):
            return
        if hub.clients:
            await hub.emit({"type": "voice_command", "task_id": "", "at": time.time(), "text": text})
        else:
            agent.start(text)

    voice.on_command = lambda text: hub.loop and asyncio.run_coroutine_threadsafe(hands_free(text), hub.loop)

    plans = pro.Proactive(workspace / "proactive.json")
    buddy: Buddy | None = None  # set once the agent exists

    async def post(update: pro.Update, speak: bool = True) -> None:
        plans.post(update)
        await hub.emit({"type": "update", "task_id": "", "at": time.time(), **pro.asdict(update)})
        if speak and voice.settings.speak_replies:
            voice.say(update.body if update.kind == "brief" else f"{update.title}. {update.body}")

    async def agent_emit(event: dict[str, Any]) -> None:
        await hub.emit(event)
        if buddy is not None:
            buddy.on_task_event(event)
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
                answer = {"spend": " Press the button to pay.", "delete": " Say yes, delete it, or no."}.get(
                    str(event.get("kind")), " Say yes or no.")
                voice.say(f"I need your okay. {event.get('label', '')}.{answer if voice.status().get('listen_ready') else ''}")

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

    def make_current_brain() -> Brain:
        """The brain the user chose in Settings, with their opt-in backup."""
        try:
            main = prov.make_brain(brain_settings.primary, keys)
        except (prov.NoKeyError, ValueError) as e:
            main = None
            brain_state["problem"] = str(e)
        else:
            brain_state["problem"] = None
        backup = None
        if brain_settings.fallback_enabled and brain_settings.fallback:
            try:
                backup = prov.make_brain(brain_settings.fallback, keys)
            except (prov.NoKeyError, ValueError):
                backup = None
        if main is None:
            return backup or prov.MissingBrain(brain_state["problem"] or "No AI chosen yet.")

        def fell_back(why: str) -> None:
            brain_state["fallback_note"] = f"Used your backup AI because the main one failed: {why}"
            audit.record("brain_fallback", why=why)

        return prov.FallbackBrain(main, backup, fell_back) if backup else main

    audit = AuditLog(workspace / "audit" / "audit.jsonl")
    if brain is None:
        brain = make_current_brain()
        mode = brain_settings.primary.provider
    agent = Agent(brain, toolbox, Policy(), Journal(workspace / "journal.jsonl"), agent_emit)
    agent.audit = audit

    rules_file = workspace / "rules.json"
    try:
        agent.gate.rules = [Rule(**r) for r in json.loads(rules_file.read_text(encoding="utf-8-sig"))]
    except (OSError, ValueError, TypeError):
        pass

    def save_rules() -> None:
        rules_file.write_text(json.dumps([vars(r) for r in agent.gate.rules], indent=1), encoding="utf-8")

    agent.on_rules_changed = save_rules

    from .web import web_tools

    for t in web_tools():
        toolbox.tools[t.name] = t
    skills = Skills(workspace / "skills.json")
    agent.extra_context = skills.context
    for t in skill_tools(skills):
        toolbox.tools[t.name] = t

    def say_step(text: str) -> None:
        if voice.settings.speak_replies:
            voice.say(text)

    walks = Walkthroughs(toolbox, workspace / "walkthrough.json",
                         notify=lambda e: hub.emit_threadsafe({"task_id": "", "at": time.time(), **e}), say=say_step)
    toolbox.tools["start_walkthrough"] = walks.tool()

    pairing = Pairing(workspace / "devices")
    remote: RemoteHost | None = None

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        hub.loop = asyncio.get_running_loop()
        if pairing.devices and remote is not None and os.environ.get("COMPII_REMOTE", "1") != "0":
            try:
                await remote.start()  # phones already paired: be reachable for them
            except Exception:  # noqa: BLE001 - shown in /health; the PC side still works
                pass
        _restore_voice(voice, voice_file)
        voice.warm_up()
        ticker = asyncio.create_task(loop())
        yield
        ticker.cancel()
        if remote is not None:
            await remote.stop()
        agent.stop_all()
        voice.cancel_listening()
        voice.stop_speaking()
        voice.close()
        if toolbox._browser is not None:
            toolbox._browser.close()

    app = FastAPI(title="Compii Core", version=__version__, lifespan=lifespan)
    app.state.agent = agent
    remote = RemoteHost(app, pairing, REMOTE_PORT)
    app.state.pairing = pairing
    app.state.remote = remote
    app.state.voice = voice
    app.state.plans = plans
    app.state.tick = tick
    app.state.act_on = act_on
    buddy = Buddy(voice, agent, hub.emit_threadsafe, act_on, lambda: hub.loop,
                  save_skill=lambda name, instruction, steps: skills.add(name, instruction, steps))
    app.state.buddy = buddy
    _proactive_tools(toolbox, plans)

    def auth(x_compii_token: str = Header(""), x_compii_device: str = Header("")) -> None:
        """This PC's app (token from disk) or a paired phone (its own key)."""
        if x_compii_token and secrets.compare_digest(x_compii_token, token):
            return
        if pairing.device_for(x_compii_device):
            return
        raise HTTPException(401, "Missing or wrong Compii token")

    def auth_local(x_compii_token: str = Header("")) -> None:
        """Only the app on this PC: pairing and removing phones."""
        if not secrets.compare_digest(x_compii_token, token):
            raise HTTPException(403, "Only Compii on this PC can do that")

    def task_view(t: Any) -> dict[str, Any]:
        return {"id": t.id, "request": t.request, "status": t.status, "created": t.created, "events": t.events,
                "origin": t.origin}

    @app.get("/health")
    def health() -> dict[str, Any]:
        has_key = bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")) \
            or keys.has("anthropic")
        return {"ok": True, "version": __version__, "brain": "rehearsal" if mode == "rehearsal" else mode,
                "credentials": "found" if fixed_brain or (not brain_state["problem"] and (has_key or mode != "claude"))
                else "not_found",
                "lockdown": agent.gate.lockdown}

    # ---- brain: which AI thinks, and its keys ----

    def brain_view() -> dict[str, Any]:
        return {
            "settings": prov.asdict(brain_settings),
            "presets": {k: {"label": v["label"], "where": v["where"], "needs_key": bool(v["key"]), "key": v["key"],
                            "model": v["model"], "base_url": v["base_url"], "price": v.get("price", ""),
                            "signup": v.get("signup", "")} for k, v in prov.PRESETS.items()},
            "keys": {n: keys.has(n) or bool(prov._env_key(n)) for n in sorted(KEY_NAMES)},
            "active": "rehearsal" if mode == "rehearsal" else brain_settings.primary.provider,
            "fixed": fixed_brain, "local": brain_settings.primary.local,
            "problem": None if fixed_brain else brain_state["problem"],
            "probe": brain_state["probe"], "fallback_note": brain_state["fallback_note"],
        }

    @app.get("/brain", dependencies=[Depends(auth)])
    def get_brain() -> dict[str, Any]:
        return brain_view()

    @app.put("/brain", dependencies=[Depends(auth_local)])
    def set_brain(body: BrainBody) -> dict[str, Any]:
        nonlocal brain_settings, mode
        if body.primary.provider not in prov.PRESETS:
            raise HTTPException(400, "Unknown AI provider")
        brain_settings = prov.BrainSettings(
            prov.BrainChoice(**body.primary.model_dump()),
            prov.BrainChoice(**body.fallback.model_dump()) if body.fallback else None,
            body.fallback_enabled,
        )
        brain_settings.save(brain_file)
        brain_state.update(probe=None, fallback_note=None)
        audit.record("brain_changed", provider=body.primary.provider, model=body.primary.model,
                     fallback=body.fallback.provider if body.fallback and body.fallback_enabled else "")
        if not fixed_brain:
            agent.brain = make_current_brain()
            mode = brain_settings.primary.provider
        return brain_view()

    @app.put("/keys/{name}", dependencies=[Depends(auth_local)])
    def set_key(name: str, body: KeyBody) -> dict[str, Any]:
        """Write-only: the key goes to Windows Credential Manager and is never sent back."""
        if name not in KEY_NAMES:
            raise HTTPException(404, "Unknown key")
        try:
            keys.set(name, body.value)
        except KeyStoreError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("key_saved", name=name)
        if not fixed_brain:
            agent.brain = make_current_brain()
        return brain_view()

    @app.delete("/keys/{name}", dependencies=[Depends(auth_local)])
    def delete_key(name: str) -> dict[str, Any]:
        if name not in KEY_NAMES:
            raise HTTPException(404, "Unknown key")
        keys.delete(name)
        audit.record("key_removed", name=name)
        if not fixed_brain:
            agent.brain = make_current_brain()
        return brain_view()

    @app.post("/brain/test", dependencies=[Depends(auth_local)])
    async def test_brain() -> dict[str, Any]:
        result = await prov.probe(agent.brain)
        brain_state["probe"] = {**result, "at": time.time()}
        return brain_view()

    @app.get("/brain/models", dependencies=[Depends(auth_local)])
    async def brain_models(base_url: str = Query("http://127.0.0.1:11434/v1"), provider: str = Query("")) -> dict[str, Any]:
        preset = prov.PRESETS.get(provider, {})
        key = (keys.get(preset["key"]) or prov._env_key(preset["key"])) if preset.get("key") else None
        if preset.get("key") and not key:
            return {"models": [], "running": False, "error": "Add the key first to see the models."}
        try:
            models = await prov.local_models(preset.get("base_url") or base_url, key)
            return {"models": sorted(models), "running": True}
        except Exception as e:  # noqa: BLE001 - server not running
            return {"models": [], "running": False, "error": str(e)[:200]}

    # ---- safety: rules, kill switch, audit log ----

    def safety_view() -> dict[str, Any]:
        return {"lockdown": agent.gate.lockdown, "rules": [vars(r) for r in agent.gate.rules],
                "audit": audit.verify()}

    @app.get("/safety", dependencies=[Depends(auth)])
    def get_safety() -> dict[str, Any]:
        return safety_view()

    @app.delete("/rules/{rule_id}", dependencies=[Depends(auth)])
    def remove_rule(rule_id: str) -> dict[str, Any]:
        if not agent.gate.remove_rule(rule_id):
            raise HTTPException(404, "No such rule")
        save_rules()
        audit.record("rule_removed", rule=rule_id)
        return safety_view()

    @app.post("/killswitch", dependencies=[Depends(auth)])
    async def kill_switch() -> dict[str, Any]:
        """Stop everything now; until lifted on this PC, every action asks first."""
        stopped = agent.kill()
        voice.stop_speaking()
        voice.cancel_listening()
        await hub.emit({"type": "lockdown", "task_id": "", "at": time.time(), "on": True, "stopped": stopped})
        return {**safety_view(), "stopped": stopped}

    @app.delete("/killswitch", dependencies=[Depends(auth_local)])
    async def lift_kill_switch() -> dict[str, Any]:
        agent.gate.lockdown = False
        audit.record("lockdown_lifted")
        await hub.emit({"type": "lockdown", "task_id": "", "at": time.time(), "on": False})
        return safety_view()

    @app.get("/audit", dependencies=[Depends(auth_local)])
    def get_audit(limit: int = Query(200)) -> dict[str, Any]:
        return {"entries": audit.entries(max(1, min(limit, 2000))), "verify": audit.verify()}

    # ---- skills and walkthroughs ----

    @app.get("/skills", dependencies=[Depends(auth)])
    def list_skills() -> list[dict[str, Any]]:
        return skills.view()

    @app.post("/tasks/{task_id}/skill", dependencies=[Depends(auth)])
    def save_as_skill(task_id: str, body: SkillBody) -> dict[str, Any]:
        task = agent.tasks.get(task_id)
        if task is None:
            raise HTTPException(404, "No such conversation")
        if task.status != "done":
            raise HTTPException(409, "Save a conversation as a skill once it has finished successfully.")
        instruction, steps = from_task(task)
        skill = skills.add(body.name.strip() or suggest_name(task.request), instruction, steps, task.id)
        audit.record("skill_saved", name=skill.name, task=task.id)
        return prov.asdict(skill)

    @app.delete("/skills/{skill_id}", dependencies=[Depends(auth)])
    def delete_skill(skill_id: str) -> list[dict[str, Any]]:
        if not skills.remove(skill_id):
            raise HTTPException(404, "No such skill")
        return skills.view()

    @app.post("/skills/{skill_id}/run", dependencies=[Depends(auth)])
    async def run_skill(skill_id: str) -> dict[str, Any]:
        skill = skills.items.get(skill_id)
        if skill is None:
            raise HTTPException(404, "No such skill")
        skills.used(skill)
        return task_view(agent.start(f"Do my skill “{skill.name}” now.\n\n{skill.as_prompt()}"))

    @app.post("/skills/{skill_id}/routine", dependencies=[Depends(auth)])
    def skill_to_routine(skill_id: str, body: SkillRoutineBody) -> dict[str, Any]:
        skill = skills.items.get(skill_id)
        if skill is None:
            raise HTTPException(404, "No such skill")
        try:
            plans.add_routine(skill.name, f"Do my skill “{skill.name}”.\n\n{skill.as_prompt()}", body.schedule)
        except (ValueError, KeyError) as e:
            raise HTTPException(400, str(e)) from e
        return plans.view()

    @app.get("/walkthrough", dependencies=[Depends(auth)])
    def walkthrough_state() -> dict[str, Any]:
        return walks.current() or {}

    @app.post("/tasks", dependencies=[Depends(auth)])
    async def create_task(body: NewTask) -> dict[str, Any]:
        if not body.request.strip():
            raise HTTPException(400, "Empty request")
        return task_view(agent.start(voice.annotate(body.request.strip())))

    @app.get("/tasks", dependencies=[Depends(auth)])
    def list_tasks() -> list[dict[str, Any]]:
        return [task_view(t) for t in sorted(agent.tasks.values(), key=lambda t: t.created, reverse=True)]

    @app.post("/tasks/{task_id}/messages", dependencies=[Depends(auth)])
    async def follow_up(task_id: str, body: Reply) -> dict[str, Any]:
        if not body.text.strip():
            raise HTTPException(400, "Empty message")
        try:
            return task_view(agent.reply(task_id, voice.annotate(body.text.strip())))
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
        if body.wake_word is not None:
            try:
                voice.set_wake(body.wake_word)
            except RuntimeError as e:
                raise HTTPException(409, str(e)) from e
            except Exception as e:  # noqa: BLE001 - e.g. no microphone
                raise HTTPException(500, f"Couldn't open the microphone: {e}") from e
        if body.speed is not None:
            voice.settings.speed = max(.7, min(1.4, body.speed))
        if body.cloud_listening is not None:
            voice.settings.cloud_listening = body.cloud_listening
        voice_file.write_text(json.dumps(vars(voice.settings)), encoding="utf-8")
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
    async def listen_stop() -> dict[str, Any]:
        text = await asyncio.to_thread(voice.stop_listening)
        if text and await act_on(text):
            return {"text": "", "handled": True, "heard": text}  # done: nothing for the app to route
        return {"text": text, "handled": False}

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
    def decide(approval_id: str, body: Decision, x_compii_token: str = Header("")) -> dict[str, bool]:
        if body.always and not secrets.compare_digest(x_compii_token, token):
            raise HTTPException(403, "“Always allow” can only be set on your PC.")
        try:
            ok = agent.decide(approval_id, body.approved, always=body.always)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        if not ok:
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
        audit.record("dial_changed", kind=body.kind.value, level=body.level.value)
        return get_policy()

    @app.post("/pair/start", dependencies=[Depends(auth_local)])
    async def pair_start() -> dict[str, Any]:
        """Show a QR code on this PC that a phone can scan to pair."""
        try:
            await remote.start()
        except RuntimeError as e:
            raise HTTPException(500, str(e)) from e
        code, expires = pairing.new_code()
        host, fp, pc = lan_ip(), pairing.ensure_certificate(), socket.gethostname()
        return {"link": pairing_link(host, REMOTE_PORT, code, fp, pc), "host": host, "port": REMOTE_PORT,
                "code": code, "fingerprint": fp, "pc": pc, "expires": expires}

    @app.post("/pair/claim")
    async def pair_claim(body: ClaimBody) -> dict[str, Any]:
        try:
            device, device_token = pairing.claim(body.code, body.name)
        except PermissionError as e:
            raise HTTPException(403, str(e)) from e
        await hub.emit({"type": "device_paired", "task_id": "", "at": time.time(), "name": device.name, "id": device.id})
        return {"token": device_token, "device_id": device.id, "pc": socket.gethostname()}

    @app.get("/devices", dependencies=[Depends(auth_local)])
    def devices() -> dict[str, Any]:
        return {"devices": pairing.view(), "listening": remote.running, "error": remote.error,
                "host": lan_ip(), "port": REMOTE_PORT}

    @app.delete("/devices/{device_id}", dependencies=[Depends(auth_local)])
    def unpair(device_id: str) -> dict[str, Any]:
        if not pairing.remove(device_id):
            raise HTTPException(404, "No such phone")
        return devices()

    @app.websocket("/events")
    async def events(ws: WebSocket, t: str = Query(""), d: str = Query("")) -> None:
        if not (t and secrets.compare_digest(t, token)) and not pairing.device_for(d):
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
    _log_to_file()

    app = build_app()
    if os.environ.get("COMPII_HOTKEY", "1") != "0":
        app.state.buddy.start_shortcuts()  # hold Ctrl+Alt to talk, Ctrl+Win to dictate
        from .screen import warm_up

        warm_up()  # the first screen read of a browser-based app is slow: do it now, not on first use
    uvicorn.run(app, host=HOST, port=PORT, log_level="info", access_log=False)  # the app polls every second


def _log_to_file() -> None:
    """Keep Core's output, errors and crashes in ~/Compii/core.log (it usually runs
    in a hidden window), so a Core that stops can say why. Restarted fresh past 2 MB.
    COMPII_LOG=console keeps output in the terminal instead."""
    import faulthandler

    log = workspace_dir() / "core.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    mode = "w" if log.exists() and log.stat().st_size > 2_000_000 else "a"
    out = open(log, mode, encoding="utf-8", buffering=1)  # noqa: SIM115 - lives as long as Core
    out.write(f"\n--- Compii Core {__version__} started {time.strftime('%Y-%m-%d %H:%M:%S')} ---\n")
    faulthandler.enable(out)  # native crashes (voice models etc.) leave a trace too
    if os.environ.get("COMPII_LOG") != "console":
        sys.stdout = sys.stderr = out


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


def _restore_voice(voice: Voice, path: Path) -> None:
    """Bring back the user's voice choices, including hands-free listening."""
    if not path.exists():
        return
    try:
        saved = json.loads(path.read_text(encoding="utf-8-sig"))
    except ValueError:
        return
    for key in ("speak_replies", "voice", "speed", "engine", "cloud_listening"):
        if key in saved:
            setattr(voice.settings, key, saved[key])
    if saved.get("wake_word") and voice.can_listen():
        try:
            voice.set_wake(True)
        except Exception:  # noqa: BLE001 - no microphone right now; the setting stays saved
            voice.settings.wake_word = True
