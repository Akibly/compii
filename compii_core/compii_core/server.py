"""Compii Core HTTP + WebSocket service. Binds to localhost only and requires a per-install token."""

from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from . import __version__, catalog
from .agent import Agent, Brain
from .audit import AuditLog
from .bots import TEMPLATES, Bots, packs_view
from .supervise import Supervisor
from .suggest import Suggestions
from .chats import load as load_chats, restore as restore_chats, save as save_chats
from .keys import KeyStore, KeyStoreError
from .library import Library, LibraryError
from .knowledge import Knowledge, KnowledgeError, knowledge_tools
from .daybook import build_daybook, daybook_tool
from .workjournal import WorkJournal, journal_tool
from .ledger import Ledger, usage_tool
from .opinion import second_opinion_tool
from .reach import Reach, reach_tools
from .policy import Rule
from . import providers as prov
from .search import search_everything
from .skills import Skills, draft as draft_skill, from_task, skill_tools, suggest_name
from .walkthrough import Walkthroughs
from . import intents
from .buddy import Buddy
from .context import ContextBundle
from .journal import Journal
from .policy import ActionKind, Autonomy, Policy
from .screen import desktop_now, make_dpi_aware
from . import sight
from .tools import Toolbox, ToolError, default_roots
from .voice import CLOUD_VOICES, Voice, spoken_reply
from .remote import Pairing, RemoteHost, _is_overlay, pairing_link, reach_addresses
from . import proactive as pro
from .tools import Tool
from .policy import ActionKind as AK

HOST = "127.0.0.1"
PORT = int(os.environ.get("COMPII_PORT", "8765"))
REMOTE_PORT = int(os.environ.get("COMPII_REMOTE_PORT", "8766"))


def workspace_dir() -> Path:
    return Path(os.environ.get("COMPII_HOME", Path.home() / "Compii"))


_RESERVED_NAMES = {"CON", "PRN", "AUX", "NUL"} | {f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}


def _safe_filename(raw: str) -> str:
    """An uploaded file's own name, with anything Windows or a path can't carry taken out."""
    clean = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", Path(raw.replace("\\", "/")).name).strip(" .")
    stem, dot, ext = clean.rpartition(".")
    if not dot:
        stem, ext = clean, ""
    stem = (stem[:110] or "file").strip(" .") or "file"
    ext = re.sub(r"[^A-Za-z0-9]", "", ext)[:16]
    name = f"{stem}.{ext}" if ext else stem
    return f"_{name}" if stem.upper() in _RESERVED_NAMES else name


class NewTask(BaseModel):
    request: str
    bot_id: str | None = None
    # Team chat: 2–6 bots share the thread; the first one speaks first.
    team: list[str] = []
    # Files already on this PC that the user attached to the message.
    attachments: list[str] = []
    # Context items the user struck off before sending (ids from GET /context).
    context_off: list[str] = []


class BotNew(BaseModel):
    name: str
    job: str = ""
    instructions: str = ""
    color: str = ""
    avatar: str = ""
    template: str = ""
    mode: str = ""
    tools: list[str] | None = None
    provider: str = ""
    model: str = ""


class BotEdit(BaseModel):
    name: str | None = None
    job: str | None = None
    instructions: str | None = None
    color: str | None = None
    avatar: str | None = None
    pinned: bool | None = None
    archived: bool | None = None
    trust: str | None = None
    mode: str | None = None
    tools: list[str] | None = None
    provider: str | None = None
    model: str | None = None


class HireBody(BaseModel):
    """The user's own name and role for a teammate Compii proposed."""
    name: str = ""
    job: str = ""
    instructions: str = ""
    avatar: str = ""
    color: str = ""


class BotFact(BaseModel):
    fact: str


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
    attachments: list[str] = []
    context_off: list[str] = []


class Transfer(BaseModel):
    """Hand a conversation to another teammate; `note` is what the user says as they pass it over."""
    bot_id: str
    note: str = ""


class UiShow(BaseModel):
    """Another Compii surface asking the workspace to show something: a conversation,
    or a page of the app by name when the news it is pointing at has no thread."""
    task_id: str = ""
    section: str = ""


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
    about: str = ""


class LibraryImport(BaseModel):
    path: str = ""
    url: str = ""
    allow_private: bool = False


class CatalogAdd(BaseModel):
    entry: dict[str, Any]  # one row from /library/catalog, fetched again from where it names


class LibraryApprove(BaseModel):
    acknowledge: bool = False  # "I read the serious warnings and still want it"
    allow_private: bool = False
    name: str = ""


class LibrarySecret(BaseModel):
    value: str


class KnowledgeFolder(BaseModel):
    path: str


class ReachBody(BaseModel):
    enabled: bool | None = None
    browser_session: bool | None = None


class Answer(BaseModel):
    text: str


class Takeover(BaseModel):
    outcome: str = "done"  # done | skip


class SkillRoutineBody(BaseModel):
    schedule: dict[str, Any]
    bot_id: str | None = None


KEY_NAMES = {p["key"] for p in prov.PRESETS.values() if p.get("key")}


class RoutineBody(BaseModel):
    title: str
    instruction: str
    schedule: dict[str, Any]
    bot_id: str | None = None


class TeachStart(BaseModel):
    goal: str = ""


class TeachSave(BaseModel):
    name: str = ""
    about: str = ""
    schedule: dict[str, Any] | None = None
    bot_id: str | None = None
    # Which recorded steps to keep (indices into the demonstration, in order), and
    # optional rewording of those kept steps. Replay data follows the same indices.
    keep: list[int] | None = None
    steps: list[str] | None = None


class TeachCheck(BaseModel):
    keep: list[int] | None = None


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


class CheckinBody(BaseModel):
    enabled: bool | None = None
    every_hours: int | None = None
    start: str | None = None  # "from" in the settings: the first time of day it may nudge
    end: str | None = None


class ReadBody(BaseModel):
    id: str | None = None


class SuggestionAccept(BaseModel):
    # A time from the user turns a "skill" offer into a scheduled routine; empty means take the suggested one.
    schedule: dict[str, Any] | None = None
    bot_id: str | None = None


class UndoBody(BaseModel):
    id: str = ""


class JournalBody(BaseModel):
    enabled: bool | None = None
    at: str | None = None


class TimelineBody(BaseModel):
    enabled: bool | None = None
    every_seconds: int | None = None
    keep_days: float | None = None
    max_mb: int | None = None
    pictures: bool | None = None


class ClipsBody(BaseModel):
    enabled: bool | None = None
    keep_days: float | None = None
    max_items: int | None = None


class ClipPinBody(BaseModel):
    pinned: bool


class SnippetBody(BaseModel):
    name: str = ""
    body: str = ""
    replace: bool = False


class SnippetEdit(BaseModel):
    name: str | None = None
    body: str | None = None


class VoiceSettingsBody(BaseModel):
    # "voice" | "sound" | "caption" | "off"
    output_mode: str | None = None
    wake_word: bool | None = None
    engine: str | None = None
    cloud_voice: str | None = None
    voice: str | None = None
    speed: float | None = None
    cloud_listening: bool | None = None
    screen_aware: bool | None = None
    see_pictures: bool | None = None


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
    """Fans task events out to every connected client.

    Each client gets its own queue drained by a dedicated sender task: `emit`
    only enqueues, so one slow or stalled client can never block the agent's
    turn loop or the other clients. A client that falls too far behind is
    dropped (it reconnects and re-syncs via GET /tasks) rather than growing an
    unbounded buffer.
    """

    QUEUE_MAX = 256

    def __init__(self) -> None:
        self.clients: dict[WebSocket, asyncio.Queue[dict[str, Any]]] = {}
        self.loop: asyncio.AbstractEventLoop | None = None

    def subscribe(self, ws: WebSocket) -> asyncio.Queue[dict[str, Any]]:
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=self.QUEUE_MAX)
        self.clients[ws] = q
        return q

    def unsubscribe(self, ws: WebSocket) -> None:
        self.clients.pop(ws, None)

    def emit_threadsafe(self, event: dict[str, Any]) -> None:
        """For events from audio threads."""
        if self.loop is not None and not self.loop.is_closed():
            asyncio.run_coroutine_threadsafe(self.emit({"task_id": "", "at": time.time(), **event}), self.loop)

    async def emit(self, event: dict[str, Any]) -> None:
        for ws, q in list(self.clients.items()):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:  # a client that can't keep up is dropped, not allowed to stall others
                self.unsubscribe(ws)


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
    ticker_state: dict[str, Any] = {"error": None, "at": 0.0}  # surfaced in /health so the app can be honest
    voice = voice or Voice(workspace / "models", hub.emit_threadsafe)
    toolbox.on_point = lambda p: hub.emit_threadsafe({"type": "point", **p})
    toolbox.on_draw = lambda d: hub.emit_threadsafe({"type": "voice_draw", **d})  # the overlay draws it
    voice_file = workspace / "voice.json"
    voice.cloud_key = lambda: keys.get("groq") or prov._env_key("groq")  # fast speech recognition, if stored
    vision_key = lambda: keys.get("nvidia") or prov._env_key("nvidia")  # noqa: E731 - free vision model

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
        if intent.reply and voice.announces and intent.kind != "stop":
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
            primary = bots.primary()
            agent.start(text, bot_id=primary.id if primary else None)

    voice.on_command = lambda text: hub.loop and asyncio.run_coroutine_threadsafe(hands_free(text), hub.loop)

    plans = pro.Proactive(workspace / "proactive.json")
    bots = Bots(workspace / "bots.json")
    supervisor = Supervisor(workspace / "team.json")
    suggestions = Suggestions(workspace / "suggestions.json")  # repeated asks Compii has noticed
    work = WorkJournal(workspace / "journal")  # one Markdown file per day, written once the day has closed
    archive_path = workspace / "chats.json"
    save_handle: asyncio.Task[None] | None = None
    buddy: Buddy | None = None  # set once the agent exists

    def screen_for(request: str) -> dict[str, Any] | None:
        """A look at the screen for a request that actually refers to it.

        Local controls plus local OCR, so this works without a vision key. Runs in a
        worker thread (the route awaits to_thread): screen capture must never block
        Core's event loop.
        """
        try:
            from .observe import observe, refers_to_screen

            if not refers_to_screen(request) or not sight.enabled() \
                    or not getattr(voice.settings, "see_pictures", True):
                return None
            snap = observe(request)
            if not snap or snap.get("blocked"):
                return None
            return snap
        except Exception:  # noqa: BLE001 - a screen look is a bonus, never a failed message
            return None

    async def post(update: pro.Update, speak: bool = True) -> None:
        plans.post(update)
        await announce(update, speak)

    async def announce(update: pro.Update, speak: bool = True) -> None:
        """Tell the app (and say it, if Compii announces) about an update already in the inbox."""
        await hub.emit({"type": "update", "task_id": "", "at": time.time(), **pro.asdict(update)})
        if speak and voice.announces:
            body = update.body if update.kind == "brief" else f"{update.title}. {update.body}"
            voice.say(body, spoken=spoken_reply(body))

    async def agent_emit(event: dict[str, Any]) -> None:
        await hub.emit(event)
        if event.get("type") in ("task_started", "user_message", "task_finished", "approval_needed"):
            schedule_save()  # bots keep their threads across restarts, not just this process's memory
        if buddy is not None:
            buddy.on_task_event(event)
        task = agent.tasks.get(event.get("task_id", ""))
        origin = task.origin if task else None
        if origin and "watch" in origin:
            # AI watches run quietly; only a "YES" becomes an update.
            if event["type"] == "task_finished":
                await _finish_ai_watch(origin["watch"], event.get("text", ""), task.id)
            return
        if origin and "routine" in origin:
            if event["type"] == "task_finished":
                plans.finish_run(task.id, str(event.get("status") or "done"))
                await post(pro.Update("routine", f"Routine: {origin['title']}", event.get("text", ""), task_id=task.id))
                return
            if event["type"] == "approval_needed":
                await post(pro.Update("needs_you", f"Routine needs you: {origin['title']}",
                                      str(event.get("label", "")), task_id=task.id))
                return
        # Jarvis-style: Compii says its answers and its questions out loud.
        if voice.announces:
            if event["type"] == "answer_delta" and not (origin and any(
                    kind in origin for kind in ("watch", "routine", "delegated"))):
                # The answer is still being written: say whole sentences as they arrive.
                voice.say_stream(str(event.get("task_id") or ""), str(event.get("text") or ""))
            elif event["type"] == "task_finished" and event.get("status") in ("done", "failed"):
                answer = event.get("text", "")
                voice.finish_stream(str(event.get("task_id") or ""), answer)
            elif event["type"] == "approval_needed":
                voice.drop_stream(str(event.get("task_id") or ""))
                ask = f"Can I go ahead? {event.get('label', '')}"
                voice.say(ask, spoken=spoken_reply(ask, sentences=2, longest=160))
            elif event["type"] == "question":
                voice.drop_stream(str(event.get("task_id") or ""))
                ask = str(event.get("question", ""))
                voice.say(ask, spoken=spoken_reply(ask, sentences=2, longest=160))

    async def _finish_ai_watch(watch_id: str, text: str, task_id: str = "") -> None:
        w = plans.watches.get(watch_id)
        first = text.strip().splitlines()[0] if text.strip() else ""
        if w and first.upper().startswith("YES"):
            w.last_triggered = pro._now().isoformat()
            plans.save()
            # The thread it came from travels with the news: a surface that is already
            # watching that conversation can tell you once instead of twice.
            await post(pro.Update("watch", w.title, first[3:].lstrip(" :—-") or "It happened.", task_id=task_id))

    def _write_journal() -> dict[str, Any] | None:
        """Write yesterday's record from the live stores, then index it so ask_my_files can search it."""
        made = work.write(tasks=list(agent.tasks.values()), journal=agent.journal, timeline=timeline)
        if made is None:
            return None
        try:
            knowledge.add_folder(str(work.folder))
            knowledge.refresh(str(work.folder))
        except (KnowledgeError, OSError) as e:  # the file is the record; the index is a convenience
            print(f"[compii] the journal was written but could not be indexed: {e}", file=sys.stderr, flush=True)
        return made

    async def tick() -> None:
        """One pass of the proactive loop: brief, journal, routines, watches."""
        now = pro._now()
        b = plans.brief
        if b.get("enabled") and b.get("last") != now.date().isoformat():
            h, m = b.get("at", "08:00").split(":")
            if now.time() >= pro.dt.time(int(h), int(m)):
                b["last"] = now.date().isoformat()
                await post(pro.compose_brief(tasks=list(agent.tasks.values()), proactive=plans,
                                             downloads=_downloads(toolbox), now=now))
        j = plans.journal
        if j.get("enabled") and j.get("last") != now.date().isoformat():
            h, m = j.get("at", "21:00").split(":")
            if now.time() >= pro.dt.time(int(h), int(m)):
                # Marked before writing: a day that fails to record must not be retried every 20 seconds.
                j["last"] = now.date().isoformat()
                plans.save()
                made = await asyncio.to_thread(_write_journal)
                if made:
                    await post(pro.Update("journal", f"{made['title']} is written down",
                                          f"{made['lead']} Saved on this PC as a plain text file, "
                                          "so Compii can look back through it.",
                                          sections=[{"title": "Where it is", "items": [made["path"]]}]),
                               speak=False)
        # The end-of-day recap and the every-few-hours "needs you" check; already in the inbox.
        for update, speak in plans.due_digests(now, list(agent.tasks.values())):
            await announce(update, speak)
        for r in plans.due_routines(now):
            bot = bots.get(r.bot_id) if r.bot_id else None
            if bot is not None and bot.archived:
                # The user put this teammate away, so its errand does not run under their name.
                # The slot is still spent: a skipped run must not be re-announced every tick.
                plans.mark_ran(r, now, None)
                await post(pro.Update("routine", r.title,
                                      f"{bot.name} is archived, so this did not run. Bring {bot.name} back, "
                                      "or give the routine to someone else."), speak=False)
                continue
            task = agent.start(r.instruction, origin={"routine": r.id, "title": r.title, "bot": r.bot_id or ""},
                               bot_id=bot.id if bot else None)
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
                ticker_state["error"] = None
            except Exception as e:  # noqa: BLE001 - the loop must survive, but never silently
                # A swallowed failure here means routines, watches and the daily brief just
                # stop happening while Compii still says they are on. Record it, log it, show it.
                ticker_state["error"] = f"{type(e).__name__}: {str(e)[:200]}"
                ticker_state["at"] = time.time()
                print(f"[compii] the proactive loop hit an error and will retry: {ticker_state['error']}",
                      file=sys.stderr, flush=True)
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
    # Re-hashed at startup, not on demand: a safety log that is only checked when
    # someone opens the page can be edited for as long as nobody looks.
    audit_state: dict[str, Any] = {"checked": False}
    ledger = Ledger(workspace / "usage.jsonl")  # what each answer cost, kept on this PC only
    if voice is not None:
        voice.ledger = ledger  # a heard request is counted as audio seconds
    if brain is None:
        brain = make_current_brain()
        mode = brain_settings.primary.provider
    agent = Agent(brain, toolbox, Policy(), Journal(workspace / "journal.jsonl"), agent_emit)
    agent.audit = audit
    agent.ledger = ledger
    agent.bot_context = lambda bot_id: (bot.prompt() if (bot := bots.get(bot_id)) else "")
    agent.bot_info = lambda bot_id: (bot.view() if (bot := bots.get(bot_id)) else None)
    agent.on_bot_fact = lambda bot_id, fact: bots.add_fact(bot_id, fact)
    # An AI that gave up mid-job is a Settings problem, not just a lost message: say so on the card.
    agent.on_brain_error = lambda why: brain_state.update(problem=f"Your AI stopped answering: {why}")

    # Which AI each teammate answers with. A bot with no choice of its own uses Compii's, so the
    # team is untouched until the user names a model — and a choice that can't be built is shown
    # as a problem on that teammate's page instead of being quietly swapped for another one.
    bot_brains = prov.BotBrains(keys)
    bot_brain_problems: dict[str, str] = {}

    def bot_ai(view: dict[str, Any] | None) -> tuple[Any | None, str]:
        """(the AI this teammate answers with, why it can't). Under a test or rehearsal brain the
        shared one always answers and no model that isn't speaking is ever named."""
        if fixed_brain:
            return None, ""
        return bot_brains.resolve(view)

    def brain_of_bot(bot_id: str | None) -> Any:
        brain, problem = bot_ai(agent.bot_info(bot_id) if bot_id else None)
        if problem:
            bot_brain_problems[bot_id or ""] = problem
        else:
            bot_brain_problems.pop(bot_id or "", None)
        return brain

    agent.brain_for = brain_of_bot

    def brain_label(brain: Any) -> str:
        """`provider · model` for the AI that actually answers, or nothing when it can't be named."""
        if brain is None or isinstance(brain, prov.MissingBrain):
            return ""
        return " · ".join([p for p in (str(getattr(brain, "provider", "") or ""),
                                       str(getattr(brain, "model", "") or "")) if p])

    def roster(*, active_only: bool = True) -> list[dict[str, Any]]:
        """Everyone on the team, with their live workload and track record.

        With `active_only` an archived teammate is left out — this is the list Compii reads, and a
        put-away role must not offer itself as someone to delegate to, mention or hire a duplicate
        of. The app asks for the full list: a conversation with an archived teammate still has to
        say who answered it."""
        out = []
        for view in bots.view():
            if active_only and view.get("archived"):
                continue
            working = [t for t in agent.tasks.values()
                       if t.bot_id == view["id"] and t.status in ("running", "waiting")]
            brain, problem = bot_ai(view)
            out.append({**view, "stats": supervisor.stats(view["id"]), "answers_with": brain_label(brain or agent.brain),
                        "model_note": problem,
                        "working": [{"id": t.id, "title": t.request[:90], "status": t.status}
                                    for t in working[:3]]})
        return out

    def review_job(job_id: str, verdict: str, note: str) -> dict[str, Any]:
        job = supervisor.review_job(job_id, verdict, note)
        return {"job": job.view(), "stats": supervisor.stats(job.bot_id)} if job else {"job": None}

    def reopen_job(job_id: str) -> dict[str, Any]:
        job = supervisor.reopen_job(job_id)
        return {"job": job.view(), "stats": supervisor.stats(job.bot_id)} if job else {"job": None}

    agent.roster = roster
    agent.on_job_open = lambda **kw: supervisor.open_job(**kw).view()
    agent.on_job_done = lambda job_id, status, result, **kw: supervisor.finish_job(job_id, status, result, **kw)
    agent.on_job_review = review_job
    agent.on_job_reopen = reopen_job
    agent.on_job_info = lambda job_id: (job.view() if (job := supervisor.job(job_id)) else None)
    agent.on_proposal = lambda **kw: supervisor.propose(**kw).view()
    agent.on_proposal_closed = lambda pid, status: supervisor.resolve_proposal(pid, status)

    def save_conversations() -> None:
        try:
            save_chats(archive_path, list(agent.tasks.values()))
        except OSError:
            pass  # a full disk must not take Core down; the thread is still in memory

    async def _save_later() -> None:
        await asyncio.sleep(.6)
        save_conversations()

    def schedule_save() -> None:
        nonlocal save_handle
        if save_handle is not None and not save_handle.done():
            return
        save_handle = asyncio.create_task(_save_later())

    restore_chats(agent, load_chats(archive_path), set(bots.items),
                  bots.primary().id if bots.primary() else None)

    rules_file = workspace / "rules.json"
    try:
        loaded = [Rule(**r) for r in json.loads(rules_file.read_text(encoding="utf-8-sig"))]
        # Old builds could save a scopeless rule that matched everything; drop those.
        agent.gate.rules = [r for r in loaded if r.scope or r.kind == ActionKind.READ]
    except (OSError, ValueError, TypeError):
        pass

    def save_rules() -> None:
        rules_file.write_text(json.dumps([vars(r) for r in agent.gate.rules], indent=1), encoding="utf-8")

    agent.on_rules_changed = save_rules

    from .web import web_tools

    for t in web_tools():
        toolbox.tools[t.name] = t
    skills = Skills(workspace / "skills.json")
    library = Library(workspace, keys=keys)
    knowledge = Knowledge(workspace, extract=toolbox._file_text)
    research = Reach(workspace)  # what this PC can look up outside
    from .lessons import Lessons, lesson_tools

    lessons = Lessons(workspace / "lesson.json")  # "teach me Blender" → "what next?" carries on
    from .profile import Profile
    from .forms import profile_form_tools
    from .projects import Projects, project_tools
    from .leads import lead_tools
    from .system import system_tools
    from .timeline import Timeline, timeline_tools
    from .clips import Clips, clip_tools
    from .everyday import everyday_tools

    profile = Profile(workspace / "profile.json")
    projects = Projects(workspace / "projects.json")
    timeline = Timeline(workspace / "timeline.db", workspace / "timeline.json")
    clips = Clips(workspace / "clips.db", workspace / "clips.json", workspace / "snippets.json")

    from . import outlook

    # Only offered when there is an Outlook on this PC that opens: six tools that can only ever
    # answer "not installed" are noise in the model's hands.
    outlook_tools_list = outlook.outlook_tools() if outlook.installed() else []

    def context_items() -> ContextBundle:
        """Everything Compii attaches before the user has said anything, one item at a time.

        Each piece says where it came from and which permission made it possible, so the app
        can show the list and the user can strike one off without losing the rest.
        """
        bundle = ContextBundle()
        for m in toolbox.memories()[-25:]:
            bundle.add_text("remembered", str(m["fact"]), kind="memory", scope="memory",
                            sensitivity="personal", at=float(m.get("at") or time.time()),
                            why="Compii learned this earlier and saved it on this PC")
        for source, text, kind, scope, sensitivity, why in (
                ("profile", profile.context(), "memory", "profile", "personal", "You filled this in under You"),
                ("projects", projects.context(), "memory", "projects", "personal", "Your projects on this PC"),
                ("snippets", clips.snippets.context(), "memory", "clips", "personal",
                 "Saved from your screen, so Compii could reuse the words"),
                ("skills", skills.context(), "instruction", "skills", "normal",
                 "Installed or taught to Compii as a way of working"),
                ("lessons", lessons.context(), "instruction", "lessons", "normal",
                 "Recorded from your own demonstrations")):
            if text:
                bundle.add_text(source, text, kind=kind, scope=scope, sensitivity=sensitivity, why=why)
        return bundle

    agent.context_sources = context_items
    agent.ambient = desktop_now
    for t in [*skill_tools(skills, toolbox), *lesson_tools(lessons), *profile_form_tools(profile, lambda: toolbox.browser),
              *project_tools(projects), *lead_tools(workspace, toolbox.path), *outlook_tools_list,
              *system_tools(), *timeline_tools(timeline), *clip_tools(clips), *knowledge_tools(knowledge),
              *reach_tools(research), *everyday_tools(toolbox, audit), usage_tool(ledger),
              second_opinion_tool(keys, ledger=ledger,
                                  current=lambda: str(getattr(agent.brain, "provider", "") or "")),
              daybook_tool(lambda: list(agent.tasks.values()), agent.journal, timeline),
              journal_tool(work)]:
        toolbox.tools[t.name] = t
    library.attach(toolbox, skills)

    walks = Walkthroughs(toolbox, workspace / "walkthrough.json",
                         notify=lambda e: hub.emit_threadsafe({"task_id": "", "at": time.time(), **e}), say=voice.say)
    toolbox.tools["start_walkthrough"] = walks.tool()
    toolbox.tools["undo_action"] = _undo_tool(
        agent.journal, lambda: {t.id: " ".join(str(t.request).split())[:120] for t in agent.tasks.values()})

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
        # The one switch for Compii's eyes, told to the app as it happens, restored from the user's choice.
        stop_sight = sight.on_change(hub.emit_threadsafe)
        sight.set_enabled(voice.settings.screen_aware)
        timeline.start()
        clips.start()
        voice.warm_up()
        # Check the safety log's chain before anything else can be claimed from it,
        # and keep the verdict for /health so the app can say so out loud.
        audit_state.update(audit.verify())
        audit_state["checked"] = True
        if not audit_state.get("ok"):
            audit.record("audit_chain_broken", broken_at=audit_state.get("broken_at"),
                         why=str(audit_state.get("why", "")))
        ticker = asyncio.create_task(loop())
        # Asked in the background, so the first task of the day knows whether this AI can call tools
        # at all, instead of finding out by describing work it will never do.
        check_brain = asyncio.create_task(probe_now())
        yield
        check_brain.cancel()
        stop_sight()
        buddy.hotkey.stop()
        buddy.dictation.stop()
        timeline.stop()
        clips.stop()
        ticker.cancel()
        if remote is not None:
            await remote.stop()
        agent.stop_all()
        save_conversations()
        voice.cancel_listening()
        voice.stop_speaking()
        voice.close()
        if toolbox._browser is not None:
            toolbox._browser.close()

    app = FastAPI(title="Compii Core", version=__version__, lifespan=lifespan)

    # Core binds 127.0.0.1 with one token, and every web page open on this PC can send
    # requests to it. Compii's own apps never add an Origin header; a browser always
    # does and cannot be told to stop, so that is the line: a page is not the app, even
    # one that guessed the token. Same-origin is allowed back (it is this port's own
    # page), everything else is refused before any route runs.
    _rejected = {"at": 0.0}

    @app.middleware("http")
    async def reject_strangers(request: Request, call_next):  # noqa: ANN001
        origin = (request.headers.get("origin") or "").strip()
        site = (request.headers.get("sec-fetch-site") or "").strip().lower()
        same_host = bool(origin) and urlparse(origin).netloc == (request.headers.get("host") or "")
        if (origin and not same_host) or site == "cross-site":
            if time.time() - _rejected["at"] > 60:  # one line per minute, not one per retry
                _rejected["at"] = time.time()
                audit.record("api_rejected", origin=origin[:80], site=site[:20], path=request.url.path[:80])
            return JSONResponse({"detail": "Compii's API answers the Compii app on this PC, not a web page."},
                                status_code=403)
        return await call_next(request)

    app.state.lessons = lessons
    app.state.library = library
    app.state.knowledge = knowledge
    app.state.research = research
    app.state.ledger = ledger
    app.state.agent = agent
    app.state.bots = bots
    app.state.supervisor = supervisor
    app.state.profile = profile
    app.state.projects = projects
    remote = RemoteHost(app, pairing, REMOTE_PORT)
    app.state.pairing = pairing
    app.state.remote = remote
    app.state.voice = voice
    app.state.timeline = timeline
    app.state.clips = clips
    app.state.plans = plans
    app.state.suggestions = suggestions
    app.state.work = work
    app.state.tick = tick
    app.state.ticker = ticker_state
    app.state.act_on = act_on
    buddy = Buddy(voice, agent, hub.emit_threadsafe, act_on, lambda: hub.loop,
                  save_skill=lambda name, instruction, steps, actions=None: skills.add(
                      name, instruction, steps, actions=actions))
    buddy.vision_key = vision_key
    _wire_seeing(agent, toolbox, voice, hub, vision_key)
    app.state.buddy = buddy
    _proactive_tools(toolbox, plans, bots)

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
                "origin": t.origin, "bot_id": t.bot_id, "owner_id": t.owner_id or t.bot_id, "team": t.team,
                "parent_id": t.parent_id, "job": t.supervised, "probation": t.probation,
                # Which AI is answering, named from the brain itself, so the app never claims a
                # model the thread isn't using. Empty when there is nothing to name yet.
                "answers_with": brain_label(agent.brain_of(t))}

    def _attached(paths: list[str]) -> list[str]:
        """Files the app attached: real files Compii is allowed to read, in order, once each."""
        out: list[str] = []
        for raw in paths[:10]:
            try:
                p = toolbox.path(raw)
            except ToolError as e:
                raise HTTPException(403, f"Can't attach {Path(raw).name}: {e}") from e
            if not p.is_file():
                raise HTTPException(400, f"The attached file {p.name} is no longer there.")
            if str(p) not in out:
                out.append(str(p))
        return out

    @app.get("/health")
    def health() -> dict[str, Any]:
        has_key = bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")) \
            or keys.has("anthropic")
        return {"ok": True, "version": __version__, "brain": "rehearsal" if mode == "rehearsal" else mode,
                "credentials": "found" if fixed_brain or (not brain_state["problem"] and (has_key or mode != "claude"))
                else "not_found",
                "lockdown": agent.gate.lockdown, "proactive_error": ticker_state["error"], "sight": sight.status(),
                # Re-hashed when Core started: the safety log is only worth trusting if the
                # chain still holds, and the app can say so without opening the audit page.
                "audit": {"ok": bool(audit_state.get("ok", True)), "count": int(audit_state.get("count", 0)),
                          "broken_at": audit_state.get("broken_at"), "why": str(audit_state.get("why") or "")}}

    # ---- diagnostics: a report you can save and send ----

    @app.post("/diagnostics", dependencies=[Depends(auth_local)])
    def diagnostics() -> dict[str, Any]:
        from .diagnostics import build_report

        stored = {n: keys.has(n) or bool(prov._env_key(n)) for n in sorted(KEY_NAMES)}
        secrets_ = [token] + [k for k in (keys.get(n) for n in KEY_NAMES if stored.get(n)) if k]
        facts = {"brain": prov.asdict(brain_settings), "keys_stored": stored, "voice": vars(voice.settings),
                 "tasks": len(agent.tasks), "buddy_shortcuts": os.environ.get("COMPII_HOTKEY", "1") != "0"}
        path = build_report(workspace, facts, secrets_)
        if sys.platform == "win32":
            subprocess.Popen(["explorer.exe", f"/select,{path}"])
        return {"path": str(path)}

    # ---- updates: the app asks Core to get out of the way ----

    @app.post("/shutdown", dependencies=[Depends(auth_local)])
    def shutdown_core() -> dict[str, str]:
        """Close Core cleanly so an update can replace the files it is holding open.
        Only this PC's app can ask; a paired phone has no business stopping the PC."""
        buddy.hotkey.stop()  # release the keyboard before anything else
        buddy.dictation.stop()
        audit.record("core_shutdown")
        hub.emit_threadsafe({"type": "core_shutdown"})
        server = getattr(app.state, "uvicorn", None)
        if server is not None:
            # Answer first, then wind down: the same lifespan teardown as a Ctrl+C.
            hub.loop.call_later(0.5, lambda: setattr(server, "should_exit", True))
        return {"stopping": "yes" if server is not None else "no"}

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

    def store_probe(result: dict[str, Any] | None) -> None:
        """The probe is not only a card in Settings. The loop needs to know when the model on the
        other end cannot call tools at all, so a task can say that out loud instead of describing
        work it will never do."""
        brain_state["probe"] = result
        agent.can_call_tools = None if result is None else bool(result.get("tools"))

    async def probe_now() -> None:
        """Ask the AI we just configured one tiny question.

        A wrong key or a model id that does not exist used to be saved happily and then
        killed every task the user tried afterwards, with the reason buried in a chat
        bubble. Testing at the moment of saving puts it on the Settings card instead."""
        if fixed_brain or isinstance(agent.brain, prov.MissingBrain):
            return
        try:
            store_probe({**(await asyncio.wait_for(prov.probe(agent.brain), 15)), "at": time.time()})
        except asyncio.TimeoutError:
            store_probe({"ok": False, "tools": False, "ms": 15000, "at": time.time(),
                         "error": "No answer in 15 seconds. Check the address and the model name."})

    @app.put("/brain", dependencies=[Depends(auth_local)])
    async def set_brain(body: BrainBody) -> dict[str, Any]:
        nonlocal brain_settings, mode
        if body.primary.provider not in prov.PRESETS:
            raise HTTPException(400, "Unknown AI provider")
        brain_settings = prov.BrainSettings(
            prov.BrainChoice(**body.primary.model_dump()),
            prov.BrainChoice(**body.fallback.model_dump()) if body.fallback else None,
            body.fallback_enabled,
        )
        brain_settings.save(brain_file)
        store_probe(None)
        brain_state["fallback_note"] = None
        audit.record("brain_changed", provider=body.primary.provider, model=body.primary.model,
                     fallback=body.fallback.provider if body.fallback and body.fallback_enabled else "")
        if not fixed_brain:
            agent.brain = make_current_brain()
            mode = brain_settings.primary.provider
            await probe_now()
        return brain_view()

    @app.put("/keys/{name}", dependencies=[Depends(auth_local)])
    async def set_key(name: str, body: KeyBody) -> dict[str, Any]:
        """Write-only: the key goes to Windows Credential Manager and is never sent back."""
        if name not in KEY_NAMES:
            raise HTTPException(404, "Unknown key")
        try:
            keys.set(name, body.value)
        except KeyStoreError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("key_saved", name=name)
        bot_brains.reset()  # a teammate's own AI was built with the key that used to be there
        if not fixed_brain:
            agent.brain = make_current_brain()
            await probe_now()  # a pasted placeholder key must fail here, not in the user's first task
        return brain_view()

    @app.delete("/keys/{name}", dependencies=[Depends(auth_local)])
    def delete_key(name: str) -> dict[str, Any]:
        if name not in KEY_NAMES:
            raise HTTPException(404, "Unknown key")
        keys.delete(name)
        audit.record("key_removed", name=name)
        bot_brains.reset()
        if not fixed_brain:
            agent.brain = make_current_brain()
        return brain_view()

    @app.post("/brain/test", dependencies=[Depends(auth_local)])
    async def test_brain() -> dict[str, Any]:
        store_probe({**(await prov.probe(agent.brain)), "at": time.time()})
        return brain_view()

    @app.get("/brain/models", dependencies=[Depends(auth_local)])
    async def brain_models(base_url: str = Query("http://127.0.0.1:11434/v1"), provider: str = Query("")) -> dict[str, Any]:
        preset = prov.PRESETS.get(provider, {})
        key = (keys.get(preset["key"]) or prov._env_key(preset["key"])) if preset.get("key") else None
        if preset.get("key") and not key:
            return {"models": [], "running": False, "error": "Add the key first to see the models."}
        try:
            models = await prov.local_models(preset.get("base_url") or base_url, key, preset.get("models_url"))
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
        skill = skills.add(body.name.strip() or suggest_name(task.request), instruction, steps, task.id, about=body.about)
        audit.record("skill_saved", name=skill.name, task=task.id)
        return prov.asdict(skill)

    @app.post("/tasks/{task_id}/skill/draft", dependencies=[Depends(auth)])
    async def skill_draft(task_id: str) -> dict[str, Any]:
        """A name and summary that fit the conversation, for the save dialog to offer."""
        task = agent.tasks.get(task_id)
        if task is None:
            raise HTTPException(404, "No such conversation")
        return await draft_skill(agent.brain, task, skills)

    @app.delete("/skills/{skill_id}", dependencies=[Depends(auth)])
    def delete_skill(skill_id: str) -> list[dict[str, Any]]:
        skill = skills.items.get(skill_id)
        if skill is None:
            raise HTTPException(404, "No such skill")
        # An imported skill is owned by its Library entry: turning it off there
        # keeps the next start from bringing it back.
        if skill.library_id and skill.library_id in library.items:
            library.disable(skill.library_id)
        else:
            skills.remove(skill_id)
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
            plans.add_routine(skill.name, f"Do my skill “{skill.name}”.\n\n{skill.as_prompt()}", body.schedule,
                              bot_id=_bot_owner(body.bot_id))
        except (ValueError, KeyError) as e:
            raise HTTPException(400, str(e)) from e
        return plans.view()

    # ---- library: imported skills and connectors (quarantined until approved) ----

    @app.get("/library", dependencies=[Depends(auth)])
    def list_library() -> dict[str, Any]:
        return library.view()

    @app.get("/library/catalog", dependencies=[Depends(auth)])
    def search_catalog(q: str = "", kind: str = "", refresh: bool = False) -> dict[str, Any]:
        """What the public catalogues call the skills and remote servers Compii could learn."""
        try:
            return catalog.search(q, library=library, kind=kind, fresh=refresh)
        except LibraryError as e:
            raise HTTPException(400, str(e)) from e

    @app.post("/library/catalog/add", dependencies=[Depends(auth_local)])
    def add_from_catalog(body: CatalogAdd) -> dict[str, Any]:
        try:
            items = catalog.add(library, body.entry)
        except LibraryError as e:
            raise HTTPException(400, str(e)) from e
        for item in items:
            audit.record("library_imported", id=item.id, name=item.name, format=item.format)
        return library.view()

    @app.post("/library/import", dependencies=[Depends(auth_local)])
    def import_library(body: LibraryImport) -> dict[str, Any]:
        try:
            if body.path.strip():
                items = library.import_path(body.path.strip())
            elif body.url.strip():
                items = library.import_url(body.url.strip(), allow_private=body.allow_private)
            else:
                raise LibraryError("Choose a file, a folder, or a link to import.")
        except LibraryError as e:
            raise HTTPException(400, str(e)) from e
        except OSError as e:
            raise HTTPException(400, f"Compii couldn't read that: {e}") from e
        for item in items:
            audit.record("library_imported", id=item.id, name=item.name, format=item.format)
        return library.view()

    @app.post("/library/{item_id}/approve", dependencies=[Depends(auth_local)])
    def approve_library(item_id: str, body: LibraryApprove) -> dict[str, Any]:
        try:
            item = library.approve(item_id, acknowledge=body.acknowledge, allow_private=body.allow_private,
                                   name=body.name)
        except LibraryError as e:
            raise HTTPException(400, str(e)) from e
        except Exception as e:  # noqa: BLE001 - a broken server must read as a review problem, not a crash
            raise HTTPException(400, f"Compii couldn't switch that on: {str(e)[:300]}") from e
        audit.record("library_approved", id=item.id, name=item.name, kind=item.kind)
        return library.view()

    @app.post("/library/{item_id}/reject", dependencies=[Depends(auth_local)])
    def reject_library(item_id: str) -> dict[str, Any]:
        try:
            item = library.reject(item_id)
        except LibraryError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("library_rejected", id=item.id, name=item.name)
        return library.view()

    @app.post("/library/{item_id}/enable", dependencies=[Depends(auth_local)])
    def enable_library(item_id: str) -> dict[str, Any]:
        try:
            item = library.enable(item_id)
        except LibraryError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("library_enabled", id=item.id, name=item.name)
        return library.view()

    @app.post("/library/{item_id}/disable", dependencies=[Depends(auth_local)])
    def disable_library(item_id: str) -> dict[str, Any]:
        try:
            item = library.disable(item_id)
        except LibraryError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("library_disabled", id=item.id, name=item.name)
        return library.view()

    @app.delete("/library/{item_id}", dependencies=[Depends(auth_local)])
    def remove_library(item_id: str) -> dict[str, Any]:
        try:
            item = library._get(item_id)
            library.remove(item_id)
        except LibraryError as e:
            raise HTTPException(404 if "No such" in str(e) else 400, str(e)) from e
        audit.record("library_removed", id=item.id, name=item.name)
        return library.view()

    @app.post("/library/{item_id}/secret", dependencies=[Depends(auth_local)])
    def set_library_secret(item_id: str, body: LibrarySecret) -> dict[str, Any]:
        try:
            library.set_secret(item_id, body.value)
        except LibraryError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("library_key_set", id=item_id)
        return library.view()

    @app.delete("/library/{item_id}/secret", dependencies=[Depends(auth_local)])
    def clear_library_secret(item_id: str) -> dict[str, Any]:
        library.clear_secret(item_id)
        audit.record("library_key_removed", id=item_id)
        return library.view()

    # ---- Knowledge: the user's own folders, searched on this PC ----

    @app.get("/knowledge", dependencies=[Depends(auth)])
    def knowledge_view() -> dict[str, Any]:
        return knowledge.view()

    @app.get("/knowledge/search", dependencies=[Depends(auth)])
    def knowledge_search(q: str = "", limit: int = 8) -> dict[str, Any]:
        try:
            return {"query": q, "results": knowledge.search(q, limit=limit)}
        except KnowledgeError as e:
            raise HTTPException(400, str(e)) from e

    @app.post("/knowledge/folders", dependencies=[Depends(auth_local)])
    def add_knowledge_folder(body: KnowledgeFolder) -> dict[str, Any]:
        try:
            path = knowledge.add_folder(body.path)
        except (KnowledgeError, OSError) as e:
            raise HTTPException(400, str(e)) from e
        audit.record("knowledge_folder_added", path=path)
        return knowledge.view()

    @app.delete("/knowledge/folders", dependencies=[Depends(auth_local)])
    def remove_knowledge_folder(path: str) -> dict[str, Any]:
        try:
            removed = knowledge.remove_folder(path)
        except (KnowledgeError, OSError) as e:
            raise HTTPException(400, str(e)) from e
        if not removed:
            raise HTTPException(404, "That folder isn't in Knowledge")
        audit.record("knowledge_folder_removed", path=path)
        return knowledge.view()

    @app.post("/knowledge/refresh", dependencies=[Depends(auth_local)])
    def refresh_knowledge(folder: str = "") -> dict[str, Any]:
        try:
            stats = knowledge.refresh(folder)
        except (KnowledgeError, OSError) as e:
            raise HTTPException(400, str(e)) from e
        audit.record("knowledge_refreshed", folder=folder, files=stats["files"], indexed=stats["indexed"])
        return {**knowledge.view(), "last": stats}

    # ---- catch me up: the user's own day, from stores already on this PC ----

    @app.get("/daybook", dependencies=[Depends(auth)])
    def daybook(hours: int = 24) -> dict[str, Any]:
        return build_daybook(tasks=list(agent.tasks.values()), journal=agent.journal, timeline=timeline,
                             hours=hours)

    # ---- research: what this PC can actually reach, and the one read-only door ----
    # (the URLs are /research: /reach already means "how a phone finds this PC")

    @app.get("/research", dependencies=[Depends(auth)])
    def research_status(probe: bool = False) -> dict[str, Any]:
        return research.status(probe=probe)

    @app.put("/research", dependencies=[Depends(auth_local)])
    def research_settings(body: ReachBody) -> dict[str, Any]:
        changes = {k: v for k, v in body.model_dump().items() if v is not None}
        st = research.set(changes)
        # Turning on the browser session hands Compii the user's logged-in read access: worth a line in the audit log.
        audit.record("reach_changed", enabled=st["enabled"], browser_session=st["browser_session"], by="this PC")
        return research.status()

    # ---- usage: what answering has cost here, counted from what each provider reported ----

    @app.get("/usage", dependencies=[Depends(auth)])
    def usage_summary(days: int = 7) -> dict[str, Any]:
        return ledger.report(days=days)

    # ---- teach a task: demonstrate it once, review the steps, keep them ----

    def _teach_status() -> dict[str, Any]:
        st = buddy.watch_status()
        st["available"] = sight.enabled()
        st["reason"] = "" if sight.enabled() else sight.refusal()
        st["draft"] = buddy.last_demo is not None
        return st

    def _teach_slice(keep: list[int] | None) -> tuple[list[str], list[dict[str, Any]]]:
        demo = buddy.last_demo
        if not demo:
            raise HTTPException(409, "There's no recording to review. Teach it again first.")
        steps = list(demo.get("steps") or [])
        actions = list(demo.get("actions") or [])
        if keep is not None:
            idx = list(dict.fromkeys(i for i in keep if isinstance(i, int) and 0 <= i < len(steps)))
            steps = [steps[i] for i in idx]
            actions = [actions[i] for i in idx]
        return steps, actions

    @app.get("/teach", dependencies=[Depends(auth_local)])
    def teach_state() -> dict[str, Any]:
        return _teach_status()

    @app.post("/teach/start", dependencies=[Depends(auth_local)])
    def teach_start(body: TeachStart) -> dict[str, Any]:
        if not sight.enabled():
            raise HTTPException(423, sight.refusal())
        if not buddy.watcher.running:
            buddy.start_watching(body.goal.strip())
            if not buddy.watcher.running:
                raise HTTPException(409, "Screen recording couldn't start.")
        return _teach_status()

    @app.post("/teach/stop", dependencies=[Depends(auth_local)])
    def teach_stop() -> dict[str, Any]:
        if not buddy.watcher.running:
            if buddy.last_demo:
                return {"watching": False, **buddy.last_demo}
            if not buddy.watcher.steps:
                raise HTTPException(409, "Nothing is being recorded.")
        demo = buddy.stop_watching(save=False)
        if not demo:
            raise HTTPException(409, "I didn't see any steps. Try again and click or switch windows as you go.")
        return {"watching": False, **demo}

    @app.post("/teach/cancel", dependencies=[Depends(auth_local)])
    def teach_cancel() -> dict[str, Any]:
        buddy.cancel_watching()
        return {"watching": False}

    @app.post("/teach/check", dependencies=[Depends(auth_local)])
    def teach_check(body: TeachCheck | None = None) -> dict[str, Any]:
        steps, actions = _teach_slice(body.keep if body else None)
        from .replay import Replayer

        checks = Replayer(toolbox).check(actions)
        return {"steps": steps, "checks": checks, "ok": all(c["ok"] for c in checks)}

    @app.post("/teach/save", dependencies=[Depends(auth_local)])
    def teach_save(body: TeachSave) -> dict[str, Any]:
        demo = buddy.last_demo
        if not demo:
            raise HTTPException(409, "There's no recording to save. Teach it again first.")
        steps, actions = _teach_slice(body.keep)
        if body.steps is not None:
            if len(body.steps) != len(steps):
                raise HTTPException(400, "The edited steps don't line up with the recording.")
            steps = [s.strip()[:200] for s in body.steps]
            if not all(steps):
                raise HTTPException(400, "Every kept step needs some words.")
        if not steps:
            raise HTTPException(400, "Keep at least one step.")
        owner: str | None = None
        if body.schedule:
            try:
                spec = pro.validate_schedule(body.schedule)
                if pro.next_run(spec, pro._now()) is None:
                    raise ValueError("That time has already passed.")
                owner = _bot_owner(body.bot_id)
            except (ValueError, KeyError) as e:
                raise HTTPException(400, str(e)) from e
        name = body.name.strip() or str(demo.get("name") or "My skill")
        try:
            skill = skills.add(name, str(demo.get("instruction") or "Repeat what the user demonstrated."),
                               steps, about=body.about, actions=actions)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        routine = None
        if body.schedule:
            routine = plans.add_routine(skill.name, f"Do my skill “{skill.name}”.\n\n{skill.as_prompt()}",
                                        body.schedule, bot_id=owner)
        buddy.last_demo = None
        audit.record("skill_taught", name=skill.name, steps=len(skill.actions),
                     routine=routine.id if routine else "")
        return {"skill": prov.asdict(skill), "routine": pro.asdict(routine) if routine else None}

    @app.get("/walkthrough", dependencies=[Depends(auth)])
    def walkthrough_state() -> dict[str, Any]:
        return walks.current() or {}

    @app.post("/tasks", dependencies=[Depends(auth)])
    async def create_task(body: NewTask) -> dict[str, Any]:
        files = _attached(body.attachments)
        request = body.request.strip() or ("Please take a look at the attached file(s)." if files else "")
        if not request:
            raise HTTPException(400, "Empty request")
        team = [b.id for i in body.team if (b := bots.get(i)) is not None]
        team = list(dict.fromkeys(team))  # keep who spoke first first
        away = [b for i in team if (b := bots.get(i)) is not None and b.archived]
        if away:
            raise HTTPException(409, f"{away[0].name} is archived. Bring them back before putting them on a team.")
        if len(team) > 6:
            raise HTTPException(400, "A team chat fits at most 6 bots.")
        if len(team) < 2:
            team = []  # one name (or none) is just a normal chat
        bot = bots.get(body.bot_id)
        if team and (bot is None or bot.id not in team):
            bot = bots.get(team[0])
        if bot is None:
            raise HTTPException(400, "No such bot")
        if bot.archived:
            # Its old conversations stay open to the user; starting a new one with a teammate
            # they put away is not what "archived" means. Bring it back first, from the directory.
            raise HTTPException(409, f"{bot.name} is archived. Bring them back before asking for anything new.")
        screen = await asyncio.to_thread(screen_for, request)
        return task_view(agent.start(voice.annotate(request), bot_id=bot.id, team=team, attachments=files,
                                     screen=screen, context_off=body.context_off))

    @app.get("/context", dependencies=[Depends(auth)])
    async def context_preview() -> dict[str, Any]:
        """What the next message would be answered with - where each piece came from, when it
        was read and how long it stays true - so the user can strike one off before sending."""
        return await agent.preview_context()

    @app.get("/tasks", dependencies=[Depends(auth)])
    def list_tasks() -> list[dict[str, Any]]:
        return [task_view(t) for t in sorted(agent.tasks.values(), key=lambda t: t.created, reverse=True)]

    @app.post("/tasks/{task_id}/messages", dependencies=[Depends(auth)])
    async def follow_up(task_id: str, body: Reply) -> dict[str, Any]:
        files = _attached(body.attachments)
        text = body.text.strip() or ("Please take a look at the attached file(s)." if files else "")
        if not text:
            raise HTTPException(400, "Empty message")
        try:
            screen = await asyncio.to_thread(screen_for, text)
            return task_view(agent.reply(task_id, voice.annotate(text), attachments=files, screen=screen,
                                         context_off=body.context_off))
        except KeyError as e:
            raise HTTPException(404, "No such conversation") from e
        except RuntimeError as e:
            raise HTTPException(409, str(e)) from e

    @app.post("/tasks/{task_id}/again", dependencies=[Depends(auth)])
    async def answer_again(task_id: str) -> dict[str, Any]:
        """Answer the same ask again. The earlier answer stays in the thread as it was said;
        this starts a fresh turn over the same history."""
        try:
            return task_view(agent.again(task_id))
        except KeyError as e:
            raise HTTPException(404, "No such conversation") from e
        except RuntimeError as e:
            raise HTTPException(409, str(e)) from e

    @app.post("/tasks/{task_id}/transfer", dependencies=[Depends(auth)])
    def transfer_task(task_id: str, body: Transfer) -> dict[str, Any]:
        """Move a conversation to another teammate because the user said so. The thread, the
        files it touched and what was already established come with it, and the answer that
        follows is spoken by them, not by Compii."""
        try:
            target = bots.get(body.bot_id)
            if target is not None and target.archived:
                raise RuntimeError(f"{target.name} is archived. Bring them back before handing them this thread.")
            task, event = agent.transfer(task_id, body.bot_id, body.note)
        except KeyError as e:
            raise HTTPException(404, "No such conversation or teammate") from e
        except RuntimeError as e:
            raise HTTPException(409, str(e)) from e
        hub.emit_threadsafe(event)
        schedule_save()
        audit.record("conversation_transferred", task=task.id, to=task.bot_id)
        return task_view(task)

    @app.delete("/tasks/{task_id}", dependencies=[Depends(auth)])
    def drop_conversation(task_id: str) -> dict[str, Any]:
        """Forget a conversation for good. It leaves the live set and the archive at once,
        so it does not reappear after a restart. A thread still working or still waiting for
        an answer has to be stopped first — an answer in mid-sentence is never thrown away.

        Jobs this conversation delegated are left alone: they are another teammate's work,
        and one of them may still be running.
        """
        task = agent.tasks.get(task_id)
        if task is None:
            raise HTTPException(404, "No such conversation")
        if task.status in ("running", "waiting"):
            raise HTTPException(409, "Compii is still working on this; stop it first.")
        agent.tasks.pop(task_id)
        save_conversations()
        hub.emit_threadsafe({"type": "task_dropped", "task_id": task_id, "at": time.time()})
        audit.record("conversation_deleted", task=task_id)
        return {"ok": True, "id": task_id}

    def drop_finished(match: Callable[[Any], bool]) -> tuple[list[str], int]:
        """Delete every finished conversation `match` accepts. Ones still working or
        waiting on an answer are kept and counted, never cut off mid-sentence."""
        dropped, busy = [], 0
        for tid, task in list(agent.tasks.items()):
            if not match(task):
                continue
            if task.status in ("running", "waiting"):
                busy += 1
                continue
            agent.tasks.pop(tid, None)
            dropped.append(tid)
        if dropped:
            save_conversations()
            for tid in dropped:
                hub.emit_threadsafe({"type": "task_dropped", "task_id": tid, "at": time.time()})
            audit.record("conversations_deleted", count=len(dropped))
        return dropped, busy

    @app.delete("/tasks", dependencies=[Depends(auth)])
    def drop_conversations(bot_id: str = "", older_than_days: float = 0) -> dict[str, Any]:
        """Clear history: every finished conversation, or only one teammate's, or only
        those older than some days."""
        cutoff = time.time() - older_than_days * 86400 if older_than_days > 0 else None
        dropped, busy = drop_finished(
            lambda t: (not bot_id or getattr(t, "bot_id", None) == bot_id)
            and (cutoff is None or float(getattr(t, "created", 0) or 0) < cutoff))
        return {"deleted": len(dropped), "still_running": busy}

    @app.post("/bots/primary/reset", dependencies=[Depends(auth)])
    def reset_compii() -> dict[str, Any]:
        bots.reset_primary()
        audit.record("compii_reset")
        return changed_bots()

    @app.delete("/memory", dependencies=[Depends(auth)])
    def forget_everything() -> dict[str, int]:
        gone = sum(1 for m in toolbox.memories() if toolbox.forget(m["id"]))
        audit.record("memory_cleared", count=gone)
        return {"deleted": gone}

    _housekeeping_tools(toolbox, bots, drop_finished, forget_everything, reset_compii)

    @app.post("/ui/show", dependencies=[Depends(auth)])
    async def ui_show(body: UiShow) -> dict[str, Any]:
        """Relay "show this" to every open Compii window.

        The island uses this when you send a thread to the full workspace, and when a
        routine, watch or the daily brief left something with no conversation of its
        own to open. Core only carries the request, so each window decides how to
        present it.
        """
        await hub.emit({"type": "ui_show", "task_id": body.task_id, "section": body.section, "at": time.time()})
        return {"ok": True}

    @app.get("/search", dependencies=[Depends(auth)])
    def search(q: str = "", limit: int = 5) -> dict[str, Any]:
        """One query across conversations, teammates, routines, skills, memories, clips and screen moments."""
        return search_everything(q, agent=agent, bots=bots, skills=skills, plans=plans, toolbox=toolbox,
                                 clips=clips, timeline=timeline, limit=limit)

    @app.get("/memory", dependencies=[Depends(auth)])
    def memory() -> list[dict[str, Any]]:
        return toolbox.memories()

    @app.delete("/memory/{memory_id}", dependencies=[Depends(auth)])
    def forget(memory_id: int) -> dict[str, bool]:
        if not toolbox.forget(memory_id):
            raise HTTPException(404, "No such memory")
        return {"ok": True}

    # ---- bots: named teammates, each with a job and its own memory ----

    def bots_view() -> dict[str, Any]:
        primary = bots.primary()
        return {"bots": roster(active_only=False), "templates": TEMPLATES, "packs": packs_view(),
                "primary": primary.id if primary else None}

    def changed_bots() -> dict[str, Any]:
        """What a route returns after it moved the roster: the new list, plus a nudge to every open
        Compii, so a teammate that was just created or renamed is never missing from the Team page
        because that window fetched its list before the change."""
        hub.emit_threadsafe({"type": "team_changed", "task_id": "", "at": time.time()})
        return bots_view()

    def _bot_owner(bot_id: str | None) -> str | None:
        """A routine's owner must be a bot that exists and is on the team; empty means Compii."""
        if not bot_id:
            return None
        found = bots.get(bot_id)
        if found is None:
            raise HTTPException(400, "That teammate doesn't exist any more.")
        if found.archived:
            raise HTTPException(400, f"{found.name} is archived. Bring them back before giving them errands.")
        return bot_id

    def _check_ai_choice(provider: str, model: str) -> None:
        """Only an AI Compii knows can be a teammate's own, and a model needs the one offering it."""
        if provider and provider not in prov.PRESETS:
            raise HTTPException(400, "Compii doesn't know that AI. Add it in Settings → Brain first.")
        if model and not provider:
            raise HTTPException(400, "Say which AI offers that model first.")

    @app.get("/bots", dependencies=[Depends(auth)])
    def list_bots() -> dict[str, Any]:
        return bots_view()

    @app.post("/bots", dependencies=[Depends(auth)])
    def new_bot(body: BotNew) -> dict[str, Any]:
        provider = body.provider.strip().lower()
        _check_ai_choice(provider, body.model)
        try:
            bot = bots.create(body.name, job=body.job, instructions=body.instructions,
                              color=body.color, template=body.template, avatar=body.avatar,
                              mode=body.mode, tools=body.tools, provider=provider, model=body.model)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("bot_created", bot=bot.id, name=bot.name, provider=bot.provider, model=bot.model)
        return changed_bots()

    @app.patch("/bots/{bot_id}", dependencies=[Depends(auth)])
    def edit_bot(bot_id: str, body: BotEdit) -> dict[str, Any]:
        changes = body.model_dump(exclude_none=True)
        found = bots.get(bot_id)
        if found is None:
            raise HTTPException(404, "No such bot")
        # A change to the model alone is checked against the AI already chosen for it.
        provider = str(changes.get("provider") or "").strip().lower() if "provider" in changes else found.provider
        model = str(changes["model"]) if "model" in changes else found.model
        _check_ai_choice(provider, model)
        try:
            bot = bots.update(bot_id, **changes)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("bot_changed", bot=bot.id)
        return changed_bots()

    @app.delete("/bots/{bot_id}", dependencies=[Depends(auth)])
    def remove_bot(bot_id: str) -> dict[str, Any]:
        try:
            found = bots.delete(bot_id)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        if not found:
            raise HTTPException(404, "No such bot")
        audit.record("bot_removed", bot=bot_id)
        return changed_bots()

    @app.post("/bots/{bot_id}/facts", dependencies=[Depends(auth)])
    def remember_for_bot(bot_id: str, body: BotFact) -> dict[str, Any]:
        try:
            bots.add_fact(bot_id, body.fact)
        except KeyError as e:
            raise HTTPException(404, "No such bot") from e
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return changed_bots()

    @app.delete("/bots/{bot_id}/facts/{index}", dependencies=[Depends(auth)])
    def forget_for_bot(bot_id: str, index: int) -> dict[str, Any]:
        if not bots.forget_fact(bot_id, index):
            raise HTTPException(404, "No such memory")
        return changed_bots()

    @app.get("/bots/{bot_id}/conversations", dependencies=[Depends(auth)])
    def bot_conversations(bot_id: str, limit: int = 40) -> dict[str, Any]:
        """One teammate's conversations with the user, most recently used first.

        Kept server-side so an agent's history does not depend on the app pulling every
        thread in the workspace. A thread counts as this teammate's if the user came to it
        through them, if they are answering it now, or if they are on its team — so a chat
        handed over shows up for both, and stays where the user left it. A job another bot
        assigned is not a conversation with the user, so those are left out.
        """
        if bots.get(bot_id) is None:
            raise HTTPException(404, "No such teammate")
        mine = [t for t in agent.tasks.values()
                if t.parent_id is None and bot_id in {(t.owner_id or t.bot_id), t.bot_id, *t.team}]
        ordered = sorted(mine, key=lambda t: t.active, reverse=True)[:max(1, min(limit, 200))]
        return {"bot_id": bot_id, "conversations": [task_view(t) for t in ordered]}

    # ---- the supervisor: delegated jobs, reviews and hiring ----

    @app.get("/team", dependencies=[Depends(auth)])
    def team_view() -> dict[str, Any]:
        primary = bots.primary()
        return {"roster": roster(active_only=False), "jobs": supervisor.jobs_view(80), "proposals": supervisor.proposals_view(),
                "packs": packs_view(), "primary": primary.id if primary else None}

    @app.post("/team/hires/{proposal_id}", dependencies=[Depends(auth)])
    def hire(proposal_id: str, body: HireBody | None = None) -> dict[str, Any]:
        prop = supervisor.proposal(proposal_id)
        if prop is None:
            raise HTTPException(404, "That hiring card doesn't exist any more.")
        if prop.status == "hired":
            raise HTTPException(409, "That teammate was already hired.")
        if prop.status in ("declined", "expired"):
            raise HTTPException(409, "That hiring card has expired. Ask Compii to propose it again.")
        data = body or HireBody()
        try:
            bot = bots.create(
                (data.name or prop.name).strip(), job=(data.job or prop.job).strip(),
                instructions=data.instructions.strip(), color=data.color.strip(),
                avatar=(data.avatar or prop.avatar).strip(),
            )
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        supervisor.resolve_proposal(proposal_id, "hired", bot_id=bot.id)
        agent.resolve_hire(proposal_id, bot.view())
        audit.record("teammate_hired", proposal=proposal_id, bot=bot.id, name=bot.name)
        return {"bots": changed_bots(), "hired": bot.view()}

    @app.post("/team/hires/{proposal_id}/decline", dependencies=[Depends(auth)])
    def decline_hire(proposal_id: str) -> dict[str, Any]:
        prop = supervisor.proposal(proposal_id)
        if prop is None:
            raise HTTPException(404, "That hiring card doesn't exist any more.")
        supervisor.resolve_proposal(proposal_id, "declined")
        agent.resolve_hire(proposal_id, None)
        audit.record("teammate_declined", proposal=proposal_id)
        return {"ok": True}

    # ---- screen timeline: local, opt-in memory of what was on screen ----

    @app.get("/timeline", dependencies=[Depends(auth)])
    def timeline_status() -> dict[str, Any]:
        return timeline.status()

    @app.put("/timeline", dependencies=[Depends(auth)])
    def set_timeline(body: TimelineBody) -> dict[str, Any]:
        changed = body.model_dump(exclude_none=True)
        result = timeline.update(**changed)
        audit.record("timeline_settings", **changed)
        return result

    @app.get("/timeline/moments", dependencies=[Depends(auth)])
    def timeline_moments(q: str = "", after: float | None = None, before: float | None = None,
                         app: str = "", limit: int = 60, full: bool = False) -> list[dict[str, Any]]:
        return timeline.search(q, after=after, before=before, app=app, limit=limit, full=full)

    @app.get("/timeline/moments/{moment_id}", dependencies=[Depends(auth)])
    def timeline_moment(moment_id: int) -> dict[str, Any]:
        found = timeline.moment(moment_id)
        if found is None:
            raise HTTPException(404, "No such moment")
        return found

    @app.delete("/timeline/moments/{moment_id}", dependencies=[Depends(auth)])
    def forget_timeline_moment(moment_id: int) -> dict[str, bool]:
        if not timeline.forget_moment(moment_id):
            raise HTTPException(404, "No such moment")
        audit.record("screen_timeline_forget_moment", moment=moment_id)
        return {"ok": True}

    @app.get("/timeline/moments/{moment_id}/picture", dependencies=[Depends(auth)])
    def timeline_picture(moment_id: int):
        """The small picture kept with a moment. Never leaves this PC."""
        from fastapi.responses import Response

        png = timeline.picture(moment_id)
        if png is None:
            raise HTTPException(404, "No picture for that moment")
        return Response(png, media_type="image/png", headers={"Cache-Control": "private, max-age=3600"})

    @app.delete("/timeline", dependencies=[Depends(auth)])
    def forget_timeline(hours: float = 0) -> dict[str, int]:
        deleted = timeline.forget(hours=hours, everything=hours <= 0)
        audit.record("screen_timeline_forget", hours=hours, deleted=deleted)
        return {"deleted": deleted}

    # ---- clipboard history and snippets: local, opt-in, forgettable ----

    @app.get("/clips", dependencies=[Depends(auth)])
    def clips_status() -> dict[str, Any]:
        return clips.status()

    @app.put("/clips", dependencies=[Depends(auth)])
    def set_clips(body: ClipsBody) -> dict[str, Any]:
        changed = body.model_dump(exclude_none=True)
        result = clips.update(**changed)
        audit.record("clipboard_settings", **changed)
        return result

    @app.get("/clips/items", dependencies=[Depends(auth)])
    def clip_items(q: str = "", limit: int = 100, pinned: bool | None = None) -> list[dict[str, Any]]:
        return clips.search(q, limit=limit, pinned=pinned)

    @app.get("/clips/items/{clip_id}", dependencies=[Depends(auth)])
    def clip_item(clip_id: int) -> dict[str, Any]:
        found = clips.item(clip_id)
        if found is None:
            raise HTTPException(404, "No such copy")
        return found

    @app.post("/clips/items/{clip_id}/copy", dependencies=[Depends(auth)])
    def copy_clip(clip_id: int) -> dict[str, Any]:
        found = clips.item(clip_id)
        if found is None:
            raise HTTPException(404, "No such copy")
        try:
            from .clips import write_clipboard

            write_clipboard(found["text"])
        except ToolError as e:
            raise HTTPException(501, str(e)) from e
        audit.record("clipboard_restored", clip=clip_id, chars=len(found["text"]))
        return {"ok": True, "chars": len(found["text"])}

    @app.patch("/clips/items/{clip_id}", dependencies=[Depends(auth)])
    def pin_clip(clip_id: int, body: ClipPinBody) -> dict[str, Any]:
        if not clips.pin(clip_id, body.pinned):
            raise HTTPException(404, "No such copy")
        return clips.item(clip_id) or {}

    @app.delete("/clips/items/{clip_id}", dependencies=[Depends(auth)])
    def forget_clip(clip_id: int) -> dict[str, bool]:
        if not clips.forget(clip_id):
            raise HTTPException(404, "No such copy")
        audit.record("clipboard_forget_item", clip=clip_id)
        return {"ok": True}

    @app.delete("/clips", dependencies=[Depends(auth)])
    def forget_clips(hours: float = 0) -> dict[str, int]:
        deleted = clips.forget_many(hours=hours, keep_pinned=True)
        audit.record("clipboard_forget", hours=hours, deleted=deleted)
        return {"deleted": deleted}

    @app.get("/snippets", dependencies=[Depends(auth)])
    def list_snippets(q: str = "") -> list[dict[str, Any]]:
        return clips.snippets.search(q)

    @app.post("/snippets", dependencies=[Depends(auth)])
    def save_snippet(body: SnippetBody) -> dict[str, Any]:
        try:
            snippet = clips.snippets.add(body.name, body.body, replace=body.replace)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("snippet_saved", name=snippet.name)
        return prov.asdict(snippet)

    @app.put("/snippets/{snippet_id}", dependencies=[Depends(auth)])
    def edit_snippet(snippet_id: str, body: SnippetEdit) -> dict[str, Any]:
        try:
            snippet = clips.snippets.update(snippet_id, name=body.name, body=body.body)
        except KeyError as e:
            raise HTTPException(404, "No such snippet") from e
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        audit.record("snippet_edited", name=snippet.name)
        return prov.asdict(snippet)

    @app.delete("/snippets/{snippet_id}", dependencies=[Depends(auth)])
    def delete_snippet(snippet_id: str) -> dict[str, bool]:
        if not clips.snippets.remove(snippet_id):
            raise HTTPException(404, "No such snippet")
        audit.record("snippet_deleted", snippet=snippet_id)
        return {"ok": True}

    @app.post("/snippets/{snippet_id}/copy", dependencies=[Depends(auth)])
    def copy_snippet(snippet_id: str) -> dict[str, Any]:
        snippet = clips.snippets.items.get(snippet_id)
        if snippet is None:
            raise HTTPException(404, "No such snippet")
        try:
            from .clips import write_clipboard

            write_clipboard(snippet.body)
        except ToolError as e:
            raise HTTPException(501, str(e)) from e
        clips.snippets.used(snippet)
        audit.record("snippet_copied", name=snippet.name, chars=len(snippet.body))
        return {"ok": True, "chars": len(snippet.body)}

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

    @app.post("/open_url", dependencies=[Depends(auth)])
    def open_url(body: FileRequest) -> dict[str, bool]:
        """Open a web link Compii read, in the user's own browser. http(s) only."""
        url = body.path.strip()
        if not url.startswith(("http://", "https://")):
            raise HTTPException(400, "Only http(s) links can be opened this way")
        toolbox._open(url)
        return {"ok": True}

    @app.get("/screen/peek", dependencies=[Depends(auth)])
    def screen_peek(x_compii_device: str = Header(""), full: bool = True):
        """A small live picture of the PC's screen, for a glance from the phone. Never while a
        password manager is in front, and every peek is in the audit log."""
        from fastapi.responses import Response

        from . import vision as vis

        if not sight.enabled():
            raise HTTPException(423, sight.refusal())
        if vis.private_foreground():
            raise HTTPException(423, "A private window (like a password manager) is in front, so Compii won't show the screen.")
        shot = vis.grab_screen() if full else vis.grab_foreground()
        if shot is None:
            raise HTTPException(503, "Compii couldn't capture the screen right now.")
        pixels, _ = shot
        step = max(1, -(-pixels.shape[1] // 1280))
        device = pairing.device_for(x_compii_device) if x_compii_device else None
        audit.record("screen_peek", device=device.name if device else "this PC")
        return Response(vis.encode_png(vis.np.ascontiguousarray(pixels[::step, ::step])), media_type="image/png",
                        headers={"Cache-Control": "no-store"})

    class SelectionAsk(BaseModel):
        instruction: str

    @app.get("/screen/selection", dependencies=[Depends(auth)])
    def screen_selection() -> dict[str, Any]:
        """The words the user has highlighted in front of them, read off the app itself.

        Nothing is copied and no key is pressed: the app's own selection is asked what it holds.
        Password fields and password managers answer nothing at all."""
        from . import screen

        picked = screen.selection()
        if picked:
            audit.record("selection_read", words=picked.get("words"), window=picked.get("window", ""))
        return {"selection": picked, "available": sight.enabled(),
                "reason": "" if sight.enabled() else sight.refusal()}

    @app.post("/screen/selection", dependencies=[Depends(auth)])
    def screen_selection_act(body: SelectionAsk) -> dict[str, Any]:
        """Do that to the words Compii is holding from the last Ctrl+Alt press."""
        return {"started": buddy.ask(body.instruction) if buddy is not None else False}

    class ClipBody(BaseModel):
        text: str

    @app.post("/clipboard", dependencies=[Depends(auth)])
    def push_clipboard(body: ClipBody) -> dict[str, bool]:
        """Put text from the phone on the PC's clipboard, ready to paste."""
        from .clips import write_clipboard

        try:
            write_clipboard(body.text)
        except ToolError as e:
            raise HTTPException(501, str(e)) from e
        clips.remember_text(body.text, app="phone", title="Sent from your phone")
        audit.record("clipboard_from_phone", chars=len(body.text))
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

    @app.post("/uploads", dependencies=[Depends(auth)])
    async def upload_file(request: Request, x_compii_filename: str = Header("")) -> dict[str, Any]:
        """Take a file from the app - a phone across the room, or this PC - so Compii can read it.

        The bytes land in Compii's own uploads folder, named by the file's own name (never a path),
        and the returned path is what a message attaches. Nothing outside that folder is written.
        """
        from urllib.parse import unquote

        name = _safe_filename(unquote(x_compii_filename or "file"))
        folder = toolbox.workspace / "uploads" / time.strftime("%Y-%m-%d")
        folder.mkdir(parents=True, exist_ok=True)
        p = folder / name
        n = 2
        while p.exists():
            p = folder / f"{Path(name).stem} ({n}){Path(name).suffix}"
            n += 1
        limit = 64 * 1024 * 1024
        total = 0
        try:
            with p.open("wb") as fh:
                async for chunk in request.stream():
                    total += len(chunk)
                    if total > limit:
                        raise HTTPException(413, "That file is larger than 64 MB.")
                    fh.write(chunk)
        except HTTPException:
            p.unlink(missing_ok=True)
            raise
        if total == 0:
            p.unlink(missing_ok=True)
            raise HTTPException(400, "That file is empty.")
        audit.record("file_attached", name=p.name, bytes=total)
        return {"name": p.name, "path": str(p), "size": total, "kind": p.suffix.lower().lstrip(".")}

    # ---- habits: repeated asks Compii can offer to take over ----

    def _already_mine() -> list[str]:
        """Text of anything already scheduled or saved as a skill, so Compii never offers it twice."""
        return [f"{r.title} {r.instruction}" for r in plans.routines.values()] + \
               [f"{s.name} {s.about} {s.instruction}" for s in skills.items.values()]

    def _habit_offers() -> dict[str, Any]:
        return {"suggestions": suggestions.refresh(load_chats(archive_path), exclude=_already_mine())}

    def _journal_view() -> dict[str, Any]:
        return {"journal": dict(plans.journal), "days": work.days(), "folder": str(work.folder)}

    _habit_tool(toolbox, lambda: _habit_offers()["suggestions"])

    @app.get("/proactive", dependencies=[Depends(auth)])
    def proactive_view() -> dict[str, Any]:
        # Tell the app when the loop that fires these is broken, so the screen
        # can say "not running" instead of implying a schedule Compii can't keep.
        return {**plans.view(), **_habit_offers(), **_journal_view(), "error": ticker_state["error"]}

    @app.post("/routines", dependencies=[Depends(auth)])
    def add_routine(body: RoutineBody) -> dict[str, Any]:
        try:
            plans.add_routine(body.title, body.instruction, body.schedule, bot_id=_bot_owner(body.bot_id))
        except (ValueError, KeyError) as e:
            raise HTTPException(400, str(e)) from e
        return plans.view()

    @app.put("/routines/{routine_id}", dependencies=[Depends(auth)])
    def edit_routine(routine_id: str, body: RoutineBody) -> dict[str, Any]:
        try:
            plans.edit_routine(routine_id, body.title, body.instruction, body.schedule,
                               bot_id=_bot_owner(body.bot_id))
        except KeyError as e:
            raise HTTPException(404, "No such routine") from e
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
        bot = bots.get(r.bot_id) if r.bot_id else None
        if bot is not None and bot.archived:
            raise HTTPException(409, f"{bot.name} is archived. Bring them back, or give this routine to someone else.")
        task = agent.start(r.instruction, origin={"routine": r.id, "title": r.title, "bot": r.bot_id or ""},
                           bot_id=bot.id if bot else None)
        plans.note_run(r, task.id)  # the schedule itself is unchanged
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

    def _clock(at: str) -> str:
        try:
            h, m = at.split(":")
            return pro.dt.time(int(h), int(m)).strftime("%H:%M")
        except ValueError as e:
            raise HTTPException(400, "Use a time like 18:00") from e

    @app.put("/recap", dependencies=[Depends(auth)])
    def recap_settings(body: BriefBody) -> dict[str, Any]:
        """The end-of-day recap: on or off, and when."""
        if body.at is not None:
            plans.recap["at"] = _clock(body.at)
        if body.enabled is not None:
            plans.recap["enabled"] = body.enabled
        plans.save()
        return plans.view()

    @app.put("/checkin", dependencies=[Depends(auth)])
    def checkin_settings(body: CheckinBody) -> dict[str, Any]:
        """The "needs you" check: on or off, how often, and the hours it may nudge in."""
        if body.every_hours is not None:
            if not 1 <= body.every_hours <= 12:
                raise HTTPException(400, "Check in every 1 to 12 hours.")
            plans.checkin["every_hours"] = body.every_hours
        if body.start is not None:
            plans.checkin["from"] = _clock(body.start)
        if body.end is not None:
            plans.checkin["to"] = _clock(body.end)
        if body.enabled is not None:
            plans.checkin["enabled"] = body.enabled
        plans.save()
        return plans.view()

    @app.post("/brief/now", dependencies=[Depends(auth)])
    async def brief_now() -> dict[str, Any]:
        update = pro.compose_brief(tasks=list(agent.tasks.values()), proactive=plans,
                                   downloads=_downloads(toolbox), now=pro._now())
        await post(update)
        return pro.asdict(update)

    @app.get("/journal", dependencies=[Depends(auth)])
    def journal_view() -> dict[str, Any]:
        return _journal_view()

    @app.put("/journal", dependencies=[Depends(auth)])
    def journal_settings(body: JournalBody) -> dict[str, Any]:
        if body.at is not None:
            try:
                h, m = body.at.split(":")
                pro.dt.time(int(h), int(m))
            except ValueError as e:
                raise HTTPException(400, "Use a time like 21:00") from e
            plans.journal["at"] = body.at
        if body.enabled is not None:
            plans.journal["enabled"] = body.enabled
        plans.save()
        return _journal_view()

    @app.post("/journal/now", dependencies=[Depends(auth)])
    async def journal_now() -> dict[str, Any]:
        """Write the last closed day down, whether or not the nightly time has come."""
        made = await asyncio.to_thread(_write_journal)
        return {**_journal_view(), "written": made}

    @app.get("/journal/{day}", dependencies=[Depends(auth)])
    def journal_day(day: str) -> dict[str, Any]:
        text = work.read(day)
        if text is None:
            raise HTTPException(404, "Nothing is written down for that day")
        return {"date": day, "text": text}

    @app.post("/inbox/read", dependencies=[Depends(auth)])
    def inbox_read(body: ReadBody) -> dict[str, Any]:
        plans.mark_read(body.id)
        return plans.view()

    @app.post("/suggestions/{suggestion_id}/accept", dependencies=[Depends(auth)])
    def accept_suggestion(suggestion_id: str, body: SuggestionAccept) -> dict[str, Any]:
        """Turn an offer into the routine or skill it proposed. Nothing is scheduled without this call."""
        if suggestions.get(suggestion_id) is None:
            raise HTTPException(404, "No such suggestion")
        owner = _bot_owner(body.bot_id)
        try:
            made = suggestions.accept(suggestion_id, plans=plans, skills=skills,
                                      bot_id=owner, schedule=body.schedule)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return {**plans.view(), "made": made, "error": ticker_state["error"], **_habit_offers()}

    @app.post("/suggestions/{suggestion_id}/decline", dependencies=[Depends(auth)])
    def decline_suggestion(suggestion_id: str) -> dict[str, Any]:
        if suggestions.resolve(suggestion_id, "declined") is None:
            raise HTTPException(404, "No such suggestion")
        return {**plans.view(), "error": ticker_state["error"], **_habit_offers()}

    @app.get("/voice", dependencies=[Depends(auth)])
    def voice_status() -> dict[str, Any]:
        return voice.status()

    @app.put("/voice/settings", dependencies=[Depends(auth)])
    def voice_settings(body: VoiceSettingsBody) -> dict[str, Any]:
        if body.output_mode in ("voice", "sound", "caption", "off"):
            if body.output_mode != "voice":
                voice.stop_speaking()
            voice.settings.output_mode = body.output_mode
        if body.voice is not None:
            voice.settings.voice = body.voice
        if body.cloud_voice is not None and body.cloud_voice in CLOUD_VOICES:
            voice.settings.cloud_voice = body.cloud_voice
        if body.engine in ("cloud", "natural", "fast", "windows"):
            voice.stop_speaking()
            voice.settings.engine = body.engine
            voice.warm_up()  # switching engines shouldn't cost the first reply its opening words
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
        if body.screen_aware is not None:
            voice.settings.screen_aware = body.screen_aware
            sight.set_enabled(body.screen_aware)
        if body.see_pictures is not None:
            voice.settings.see_pictures = body.see_pictures
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
        voice.say_now(body.text)
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

    @app.get("/undo", dependencies=[Depends(auth)])
    def undo_list(hours: int = 24) -> dict[str, Any]:
        # hours 0 means the whole journal, not nothing.
        since = time.time() - hours * 3600 if hours > 0 else None
        asked = {t.id: " ".join(str(t.request).split())[:120] for t in agent.tasks.values()}
        return {"actions": [dict(r, about=asked.get(r["task_id"], ""))
                            for r in agent.journal.reversible(since=since)]}

    @app.post("/undo", dependencies=[Depends(auth)])
    def undo_one(body: UndoBody) -> dict[str, str]:
        if not body.id.strip():
            raise HTTPException(400, "Say which action to put back.")
        return {"result": agent.journal.undo_by_id(body.id)}

    @app.post("/questions/{question_id}/answer", dependencies=[Depends(auth)])
    def answer_question(question_id: str, body: Answer) -> dict[str, bool]:
        if not agent.answer(question_id, body.text):
            raise HTTPException(404, "That question has already been answered")
        return {"ok": True}

    @app.post("/takeovers/{takeover_id}", dependencies=[Depends(auth)])
    def finish_takeover(takeover_id: str, body: Takeover) -> dict[str, bool]:
        """The user says they finished (or skipped) a password/card/code step; the task carries on."""
        if body.outcome not in ("done", "skip"):
            raise HTTPException(400, "Outcome must be done or skip")
        if not agent.finish_takeover(takeover_id, body.outcome):
            raise HTTPException(404, "That hand-off is no longer waiting")
        return {"ok": True}

    @app.get("/profile", dependencies=[Depends(auth)])
    def profile_view() -> dict[str, Any]:
        return {"fields": profile.view(), "updated": profile.updated}

    @app.delete("/profile/{name}", dependencies=[Depends(auth)])
    def profile_forget(name: str) -> dict[str, Any]:
        if not profile.forget(name):
            raise HTTPException(404, "Nothing stored with that name")
        return {"fields": profile.view()}

    @app.get("/projects", dependencies=[Depends(auth)])
    def projects_view() -> list[dict[str, Any]]:
        return [prov.asdict(p) for p in sorted(projects.items.values(), key=lambda p: -p.updated)]

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
        hosts, fp, pc = reach_addresses(), pairing.ensure_certificate(), socket.gethostname()
        return {"link": pairing_link(hosts[0], REMOTE_PORT, code, fp, pc, hosts[1:]), "host": hosts[0], "hosts": hosts,
                "port": REMOTE_PORT, "code": code, "fingerprint": fp, "pc": pc, "expires": expires,
                "anywhere": any(_is_overlay(h) for h in hosts)}

    @app.post("/pair/claim")
    async def pair_claim(body: ClaimBody) -> dict[str, Any]:
        try:
            device, device_token = pairing.claim(body.code, body.name)
        except PermissionError as e:
            raise HTTPException(403, str(e)) from e
        await hub.emit({"type": "device_paired", "task_id": "", "at": time.time(), "name": device.name, "id": device.id})
        return {"token": device_token, "device_id": device.id, "pc": socket.gethostname(), "hosts": reach_addresses()}

    @app.get("/reach", dependencies=[Depends(auth)])
    def reach() -> dict[str, Any]:
        """Where phones can find this PC now (it changes when Tailscale is installed or Wi-Fi changes)."""
        return {"hosts": reach_addresses(), "port": REMOTE_PORT}

    @app.get("/devices", dependencies=[Depends(auth_local)])
    def devices() -> dict[str, Any]:
        hosts = reach_addresses()
        return {"devices": pairing.view(), "listening": remote.running, "error": remote.error,
                "host": hosts[0], "hosts": hosts, "anywhere": any(_is_overlay(h) for h in hosts), "port": REMOTE_PORT}

    @app.delete("/devices/{device_id}", dependencies=[Depends(auth_local)])
    def unpair(device_id: str) -> dict[str, Any]:
        if not pairing.remove(device_id):
            raise HTTPException(404, "No such phone")
        return devices()

    @app.websocket("/events")
    async def events(ws: WebSocket, t: str = Query(""), d: str = Query("")) -> None:
        # A browser page can put the token in a URL it opens itself, so the live stream
        # needs the same "you are not a web page" test the HTTP routes get.
        origin = (ws.headers.get("origin") or "").strip()
        if origin and urlparse(origin).netloc != (ws.headers.get("host") or ""):
            await ws.close(code=4403)
            return
        if not (t and secrets.compare_digest(t, token)) and not pairing.device_for(d):
            await ws.close(code=4401)
            return
        await ws.accept()
        queue = hub.subscribe(ws)

        async def pump() -> None:
            while True:
                event = await queue.get()
                await ws.send_json(event)
                if hub.clients.get(ws) is not queue:
                    return  # dropped as too slow: the app reconnects and re-syncs via GET /tasks

        sender = asyncio.create_task(pump())
        try:
            reader = asyncio.create_task(_drain_incoming(ws))
            done, pending = await asyncio.wait({sender, reader}, return_when=asyncio.FIRST_COMPLETED)
            for t_ in pending:
                t_.cancel()
            for t_ in done:  # surface a real send failure, swallow disconnect
                exc = t_.exception()
                if exc is not None and not isinstance(exc, (WebSocketDisconnect, RuntimeError)):
                    raise exc
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            hub.unsubscribe(ws)
            sender.cancel()
            try:
                await ws.close()
            except (WebSocketDisconnect, RuntimeError):
                pass  # the client went away mid-close: nothing left to tell

    async def _drain_incoming(ws: WebSocket) -> None:
        while True:
            await ws.receive_text()  # keepalive pings from the client

    return app


def main() -> None:
    import uvicorn

    make_dpi_aware()
    _log_to_file()

    # Another Core is already answering: don't start a second one, and above all don't rewrite
    # core-token, which would lock the app and any paired phone out of the Core that is working.
    if _port_busy(HOST, PORT):
        print(f"Compii Core is already running on {HOST}:{PORT}; using that one.")
        return

    app = build_app()
    if os.environ.get("COMPII_HOTKEY", "1") != "0":
        app.state.buddy.start_shortcuts()  # hold Ctrl+Alt to talk, Ctrl+Win to dictate
        from .screen import warm_up

        warm_up()  # the first screen read of a browser-based app is slow: do it now, not on first use
    # Keep the Server object: POST /shutdown tells it to stop. The app holds a WebSocket open
    # for its whole life, so without a timeout uvicorn would wait for a connection that never closes.
    server = uvicorn.Server(uvicorn.Config(
        app, host=HOST, port=PORT, log_level="info", access_log=False, timeout_graceful_shutdown=3))
    app.state.uvicorn = server
    server.run()  # the app polls every second


def _port_busy(host: str, port: int) -> bool:
    import socket

    with socket.socket() as probe:
        probe.settimeout(0.4)
        return probe.connect_ex((host, port)) == 0


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


def _habit_tool(toolbox, notices) -> None:
    """Let Compii count its own repetitions, so a habit is raised from evidence rather than a guess."""
    from .tools import ToolResult

    def noticed_habits(_a: dict[str, Any]) -> ToolResult:
        items = notices()
        if not items:
            return ToolResult("Nothing has come back three times on different days, so there is no habit "
                              "worth offering a routine for.")
        lines = []
        for it in items:
            line = f"- {it['title']} ({it['kind']}): asked {it['count']} times."
            if it["steps"]:
                line += " Steps that worked: " + "; ".join(it["steps"][:6])
            lines.append(line)
        return ToolResult("Repeated asks counted from the conversations saved on this PC:\n" + "\n".join(lines)
                          + "\nOffer one of these as a routine or a skill and let the user decide. Never schedule "
                          "or save anything on your own, and never say a number of times that isn't listed here.")

    toolbox.tools["noticed_habits"] = Tool(
        "noticed_habits", "What the user keeps asking for, counted from their saved conversations on this PC. "
                          "Use it before saying anything has repeated, and before offering to make a habit into a "
                          "routine or skill.", {}, [], AK.READ, noticed_habits,
        lambda a: "Check what keeps repeating")


def _undo_tool(journal, asks: Callable[[], dict[str, str]] | None = None) -> Tool:
    """Let Compii reverse its own changes, one at a time, from what the journal recorded."""
    from .tools import ToolResult

    def undo_action(args: dict[str, Any]) -> ToolResult:
        wanted = str(args.get("id") or "").strip()
        if not wanted:
            rows = journal.reversible()
            if not rows:
                return ToolResult("Nothing Compii changed is still waiting to be put back.")
            asked = asks() if asks is not None else {}
            lines = []
            for r in rows:
                how = asked.get(r["task_id"], "")
                lines.append(f"- {r['id']} ({time.strftime('%H:%M on %d %B', time.localtime(r['at']))}): "
                             f"{r['summary']}" + (f" — asked as “{how}”" if how else ""))
            return ToolResult("What Compii changed and can still put back, newest first:\n" + "\n".join(lines)
                              + "\nOnly reverse one of these when the user asks, and only the one they mean. "
                                "Call undo_action with the id from this list; never make one up.")
        return ToolResult(journal.undo_by_id(wanted))

    return Tool(
        "undo_action", "Put back something Compii changed earlier - a move it made or a file it created. "
                       "Call it with no id to list what can still be reversed, then pass that id to undo it. "
                       "Changes that later work was built on are not offered.",
        {"id": {"type": "string", "description": "The id from the list of reversible actions"}},
        [], lambda a: AK.CHANGE if str(a.get("id") or "").strip() else AK.READ, undo_action,
        lambda a: "Putting back a change Compii made" if str(a.get("id") or "").strip()
                  else "Checking what Compii can put back")


def _housekeeping_tools(toolbox, bots: Bots, drop_finished, forget_everything, reset_compii) -> None:
    """Deleting, when the user asks for it in words: conversations, a teammate, or
    Compii's own memory and set-up. Every one is a DELETE, so it asks first."""
    from .tools import ToolError, ToolResult

    def delete_conversations(a: dict[str, Any]) -> ToolResult:
        about = str(a.get("about", "")).strip().lower()
        who = str(a.get("teammate", "")).strip().lower()
        bot = next((b for b in bots.items.values() if b.name.lower() == who), None) if who else None
        if who and bot is None:
            raise ToolError(f"There's no teammate called \u201c{a.get('teammate')}\u201d.")
        everything = about in ("all", "everything")
        words = [] if everything or not about else [w for w in about.split() if len(w) > 1]
        if not words and bot is None and not everything:
            raise ToolError("Say which conversations: a few words from them, a teammate, or 'all'.")

        def match(t: Any) -> bool:
            text = str(getattr(t, "request", "")).lower()
            return (bot is None or getattr(t, "bot_id", None) == bot.id) and all(w in text for w in words)

        dropped, busy = drop_finished(match)
        if not dropped and not busy:
            return ToolResult("No conversation matches that, so nothing was deleted.")
        note = f" {busy} still working were kept; stop them first to delete them." if busy else ""
        return ToolResult(f"Deleted {len(dropped)} conversation(s) for good.{note}")

    def delete_teammate(a: dict[str, Any]) -> ToolResult:
        name = str(a.get("name", "")).strip().lower()
        bot = next((b for b in bots.items.values() if b.name.lower() == name), None)
        if bot is None:
            raise ToolError(f"There's no teammate called \u201c{a.get('name')}\u201d.")
        if bot.primary:
            raise ToolError("Compii itself can't be deleted, but it can be reset: use reset_compii.")
        bots.delete(bot.id)
        return ToolResult(f"Deleted the teammate {bot.name}. Its past conversations stay unless you delete them too.")

    def reset(a: dict[str, Any]) -> ToolResult:
        what = {str(w) for w in (a.get("what") or [])} or {"memory", "setup"}
        done = []
        if "memory" in what:
            done.append(f"forgot {forget_everything()['deleted']} saved fact(s)")
        if "setup" in what:
            reset_compii()
            done.append("put its name, instructions, look and AI back to the start")
        if "conversations" in what:
            dropped, busy = drop_finished(lambda t: True)
            done.append(f"deleted {len(dropped)} conversation(s)" + (f", kept {busy} still working" if busy else ""))
        if not done:
            raise ToolError("Choose what to reset: memory, setup or conversations.")
        return ToolResult("Compii reset: " + "; ".join(done) + ".")

    s = {"type": "string"}
    for t in [
        Tool("delete_conversations", "Delete conversations for good when the user asks: ones containing some "
             "words, all of one teammate's, or 'all'. Conversations still working are kept.",
             {"about": {**s, "description": "Words from the conversations, or 'all'."},
              "teammate": {**s, "description": "Only this teammate's conversations (its name)."}},
             [], AK.DELETE, delete_conversations,
             lambda a: f"Delete conversations about \u201c{a.get('about') or a.get('teammate') or 'all'}\u201d"),
        Tool("delete_teammate", "Delete one of the user's teammates (bots) by name. Compii itself can't be deleted.",
             {"name": s}, ["name"], AK.DELETE, delete_teammate, lambda a: f"Delete the teammate {a.get('name')}"),
        Tool("reset_compii", "Reset Compii when the user asks to start over: forget what it saved about them "
             "(memory), restore its name, instructions and look (setup), and/or delete every finished conversation.",
             {"what": {"type": "array", "items": {"type": "string", "enum": ["memory", "setup", "conversations"]}}},
             [], AK.DELETE, reset, lambda a: f"Reset Compii ({', '.join(a.get('what') or ['memory', 'setup'])})"),
    ]:
        toolbox.tools[t.name] = t


def _proactive_tools(toolbox, plans: "pro.Proactive", bots: Bots) -> None:
    """Tools the agent uses when you ask for routines and watches in plain language."""
    from .tools import ToolError, ToolResult

    def _owner(name: str) -> str | None:
        want = name.strip().lower()
        if not want or want == "compii":
            return None
        bot = next((b for b in bots.items.values() if b.name.lower() == want), None)
        if bot is None:
            raise ToolError(f"There's no teammate called “{name}”. Ask the user which of their bots should own it.")
        return bot.id

    def create_routine(a: dict[str, Any]) -> ToolResult:
        try:
            r = plans.add_routine(a["title"], a["instruction"], a["schedule"],
                                  bot_id=_owner(a.get("bot", "")))
        except (ValueError, KeyError) as e:
            raise ToolError(f"Couldn't schedule that: {e}") from e
        who = bots.get(r.bot_id).name if r.bot_id and bots.get(r.bot_id) else "Compii"
        return ToolResult(f"Routine “{r.title}” scheduled with {who}: {pro.describe(r.schedule)}. Next run {r.next_run}.")

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
        lines = []
        for r in v["routines"]:
            owner = bots.get(r.get("bot_id")).name if r.get("bot_id") and bots.get(r.get("bot_id")) else "Compii"
            lines.append(f"- routine {r['id']}: {r['title']} ({owner}) — {r['when']}"
                         f"{'' if r['enabled'] else ' (paused)'}")
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
             "The instruction is what you would be asked to do at that time. Set bot to a teammate's name when the "
             "user wants one of their bots to own it; leave it out for Compii itself.",
             {"title": s, "instruction": s, "schedule": schedule,
              "bot": {**s, "description": "Name of the teammate who owns it, or empty for Compii."}},
             ["title", "instruction", "schedule"],
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
    if "speak_replies" in saved and "output_mode" not in saved:  # the switch it replaced
        saved["output_mode"] = "voice" if saved["speak_replies"] else "off"
    for key in ("output_mode", "voice", "speed", "engine", "cloud_voice", "cloud_listening", "screen_aware",
                "see_pictures"):
        if key in saved:
            setattr(voice.settings, key, saved[key])
    if saved.get("wake_word") and voice.can_listen():
        try:
            voice.set_wake(True)
        except Exception:  # noqa: BLE001 - no microphone right now; the setting stays saved
            voice.settings.wake_word = True



def _wire_seeing(agent, toolbox, voice, hub, vision_key) -> None:
    """Looking at the window you're in: the app's own controls, the words a local OCR pass
    reads from a picture (both work with no key and nothing leaving the PC), plus a vision
    model when one is configured — and the lesson coach that notices when a step is done."""
    from . import ocr as local_ocr
    from . import vision as vis
    from .agent import COACH_NOTE
    from .coach import Coach

    def can_read(named: bool = False) -> bool:
        """Compii may look. Local reading needs no model key, only the user's switch."""
        return (sight.enabled() and getattr(voice.settings, "see_pictures", True)
                and (named or not vis.blocked_foreground()))

    def can_see(named: bool = False) -> bool:
        """A vision model is also available, for pictures of things that aren't text."""
        return can_read(named) and bool(vision_key())

    def read_words(png: bytes) -> dict[str, Any] | None:
        try:
            return local_ocr.read_png_boxes(png)
        except Exception:  # noqa: BLE001 - the app's own labels are still there
            return None

    def look_at(snap: dict[str, Any], question: str) -> dict[str, Any]:
        if not can_read():
            return snap
        shot = vis.grab_foreground()
        if shot is None:
            return snap
        pixels, window = shot
        boxes = read_words(vis.ocr_png(pixels))
        if boxes and not snap.get("ocr_text"):
            snap = vis.merge_ocr(snap, boxes, window)
        if can_see():
            try:
                snap = vis.merge(snap, vis.look(vis.png_of(pixels), question, vision_key(),
                                                window=str(snap.get("title") or "")), window)
            except Exception:  # noqa: BLE001 - the local words are already a real look
                pass
        return snap

    def see_item(target: str) -> dict[str, Any] | None:
        if not can_read():
            return None
        shot = vis.grab_foreground()
        if shot is None:
            return None
        pixels, window = shot
        # Text first: OCR matches a visible label exactly, where a vision model guesses.
        hit = vis.locate_text(read_words(vis.ocr_png(pixels)), window, target)
        if hit:
            return {**hit, "src": "ocr"}
        if not can_see():
            return None
        return vis.locate_precise(pixels, window, target, vision_key())

    def read_screen(question: str, full: bool, window: str | None = None) -> dict[str, Any] | None:
        if not can_read(named=bool(window)):
            return None
        from .screen import (BLOCKED_APPS, describe_snapshot, find_window, private_window, snapshot_foreground,
                             window_titles)

        target = ""
        if window:
            hwnd, target = find_window(window)
            if not hwnd:
                others = [t for t in window_titles(12) if not any(b in t.lower() for b in BLOCKED_APPS)]
                listing = (" Right now these windows are visible: " + "; ".join(f"“{t}”" for t in others[:8]) + "."
                           if others else "")
                return {"text": f"No visible window has “{window}” in its title right now.{listing} "
                                "Use part of one of those titles, or look at the window in front.", "snap": None}
            if private_window(hwnd, target):
                return {"text": f"“{target}” is a private window (like a password manager), so Compii won't look at it.",
                        "snap": None}
            shot = vis.grab_foreground(hwnd)
        else:
            shot = vis.grab_screen() if full else vis.grab_foreground()
        if shot is None:
            return None
        pixels, rect = shot
        base: dict[str, Any] = {}
        if not target and not full:
            try:
                base = snapshot_foreground() or {}
            except Exception:  # noqa: BLE001
                base = {}
            if base.get("blocked"):
                return {"text": f"The user is in “{base.get('title')}”, which Compii doesn't read.", "snap": None}
        # Telling the model which window it is looking at stops it describing whatever else it
        # half-recognises in the picture (a browser behind, a thumbnail, its own idea of Excel).
        looked_at = target or ("the whole screen" if full else str(base.get("title") or ""))
        snap: dict[str, Any] = {**base, "elements": [] if full else base.get("elements", [])}
        if target:
            snap["title"] = target
        boxes = read_words(vis.ocr_png(pixels))
        if boxes:
            snap = vis.merge_ocr(snap, boxes, rect, max_items=140)
        seen = None
        if can_see(named=bool(window)):
            try:
                seen = vis.read(vis.png_of(pixels), question, vision_key(), window="" if full else looked_at)
                snap = vis.merge(snap, seen, rect)
            except Exception:  # noqa: BLE001 - local OCR and the controls are still a real look
                seen = None
        words = str(snap.get("ocr_text") or "")
        details = seen.get("summary", "") if seen else ""
        if not words and seen:
            words = str(seen.get("text") or "")
        if not words and not details and not snap.get("elements") and not full:
            return None  # nothing readable: let the caller fall back to the controls
        lines = [f"Looked at: {looked_at or 'the screen'}"
                 + (" (read locally: the app's controls and Windows OCR)" if not seen else "")]
        if details:
            lines.append(details)
        if words:
            source = "local OCR, accurate to a few pixels" if snap.get("ocr_text") else "from the picture"
            lines.append(f"Visible text ({source}; may contain small mistakes):\n{words[:4000]}")
        items = "\n".join(f"{e['id']}: {e['name']}" for e in snap["elements"]
                          if e.get("role") in ("Seen", "Text"))
        if items:
            lines.append(f"Items you can point at by id (t = OCR text, v = seen in the picture):\n{items}")
        if base and not full and not target:
            controls = [e for e in base.get("elements", []) if e.get("name")]
            if controls:
                lines.append("The window's own controls (exact labels and actions):\n"
                             + describe_snapshot({**base, "seen": "", "ocr_text": ""})[:3000])
        return {"text": "\n\n".join(lines), "snap": snap}

    def step_done(task_id: str, done_when: str, why: str) -> None:
        async def go() -> None:
            from .screen import snapshot_foreground

            try:
                snap = await asyncio.to_thread(snapshot_foreground)
            except Exception:  # noqa: BLE001
                snap = None
            note = (f"{COACH_NOTE} You can see the step is done: {done_when} ({why}). In a few warm words, say so. "
                    "Then, if a lesson is going, call update_lesson to move it on, teach the next small step and show it "
                    "on screen with point_at or draw_on_screen, then call watch_for_step for it. If that was the last "
                    "step, celebrate and finish.")
            try:
                agent.reply(task_id, note, screen=snap)
            except (KeyError, RuntimeError):
                pass  # the conversation is busy or gone

        if hub.loop is not None:
            asyncio.run_coroutine_threadsafe(go(), hub.loop)

    agent.look_at = look_at
    toolbox.see_item = see_item
    toolbox.read_screen = read_screen
    agent.coach = Coach(lambda png, done_when: vis.check(png, done_when, vision_key()), step_done,
                        lambda: can_see(), emit=hub.emit_threadsafe)


if __name__ == "__main__":
    main()
