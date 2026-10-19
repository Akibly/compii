"""The cursor buddy: talk to Compii from any app, Clicky-style.

Hold Ctrl + Alt and talk; let go to send. Or tap them once and just talk:
Compii sends when you pause. The moment you press, Compii notes the window
you're in (items and labels only, never passwords) so it can answer about
it and point at things. Everything happens beside your mouse pointer; the
app's window can stay closed.

Events for the overlay are sent as `voice_buddy` with a `state`:
listening → thinking → answer (or needs_you / idle / setup / error).
"""

from __future__ import annotations

import asyncio
import random
import threading
import time
from collections.abc import Awaitable, Callable
from typing import Any

from .hotkey import TAP_MAX, HoldToTalk

ACKS = ["On it.", "Let me look.", "One sec.", "Sure, let me check.", "Okay, looking."]


class Buddy:
    def __init__(self, voice, agent, emit: Callable[[dict[str, Any]], None],
                 handle_intent: Callable[[str], Awaitable[bool]], loop_getter: Callable[[], Any],
                 snapshot: Callable[[], dict[str, Any] | None] | None = None,
                 cursor: Callable[[], tuple[int, int]] | None = None) -> None:
        self.voice = voice
        self.agent = agent
        self._emit = emit
        self._intent = handle_intent
        self._loop = loop_getter
        if snapshot is None or cursor is None:
            from . import screen

            snapshot = snapshot or screen.snapshot_foreground
            cursor = cursor or screen.cursor_position
        self._snapshot = snapshot
        self._cursor = cursor
        self._snap: dict[str, Any] | None = None
        self._snap_thread: threading.Thread | None = None
        self._busy = threading.Lock()
        self.tasks: set[str] = set()  # conversations started from the buddy
        self.hotkey = HoldToTalk(self.start, self.end, self.cancel)
        voice.on_auto_end = self.finish

    def emit(self, state: str, **data: Any) -> None:
        try:
            x, y = self._cursor()
        except Exception:  # noqa: BLE001
            x, y = 0, 0
        self._emit({"type": "voice_buddy", "state": state, "cursor": [x, y], **data})

    # ---- the shortcut ----

    def start(self) -> None:
        """Ctrl+Alt held: look at the screen and listen."""
        if not self.voice.can_listen():
            self.emit("setup", text="Turn on listening in Compii → Settings → Voice first.")
            return
        self._snap = None

        def look() -> None:
            try:
                self._snap = self._snapshot()
            except Exception:  # noqa: BLE001 - screen awareness is best effort
                self._snap = None

        self._snap_thread = threading.Thread(target=look, daemon=True)
        self._snap_thread.start()
        try:
            self.voice.start_listening()
        except Exception as e:  # noqa: BLE001 - e.g. no microphone
            self.emit("error", text=f"I can't hear you: {e}")
            return
        self.emit("listening")

    def end(self, held: float) -> None:
        """Ctrl+Alt released: a hold sends now; a quick tap keeps listening until you pause."""
        if held < TAP_MAX:
            self.voice.listen_hands_free()
            self.emit("listening", hands_free=True)
            return
        threading.Thread(target=self.finish, daemon=True).start()

    def cancel(self) -> None:
        self.voice.cancel_listening()
        self.emit("idle")

    def finish(self) -> None:
        if not self._busy.acquire(blocking=False):
            return
        try:
            text = self.voice.stop_listening().strip()
            if not text:
                self.emit("idle", text="I didn't catch that.")
                return
            if self._snap_thread is not None:
                self._snap_thread.join(timeout=2.5)
            self.emit("thinking", heard=text)
            loop = self._loop()
            if loop is None:
                return
            asyncio.run_coroutine_threadsafe(self._handle(text, self._snap), loop)
        finally:
            self._busy.release()

    async def _handle(self, text: str, snap: dict[str, Any] | None) -> None:
        if await self._intent(text):
            self.emit("idle")
            return
        if self.voice.settings.speak_replies:
            self.voice.say(random.choice(ACKS))  # instant, human acknowledgement while the AI thinks
        task = self.agent.start(text, origin={"buddy": True, "title": "Asked from the cursor"}, screen=snap)
        self.tasks.add(task.id)
        self.emit("thinking", heard=text, task_id=task.id, screen=(snap or {}).get("title", ""))

    # ---- task events → buddy states ----

    def on_task_event(self, event: dict[str, Any]) -> None:
        tid = event.get("task_id", "")
        if tid not in self.tasks:
            return
        kind = event.get("type")
        if kind == "task_finished":
            self.emit("answer", task_id=tid, text=event.get("text", ""), status=event.get("status"))
        elif kind == "approval_needed":
            self.emit("needs_you", task_id=tid, text=f"{event.get('label', '')} — say yes or no.")
        elif kind == "action_started":
            self.emit("thinking", task_id=tid, step=event.get("label", ""))


def wait(seconds: float) -> None:  # pragma: no cover - tiny helper for manual tests
    time.sleep(seconds)
