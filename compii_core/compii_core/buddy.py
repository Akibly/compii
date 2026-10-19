"""The cursor buddy: talk to Compii from any app, Clicky-style.

Shortcuts (all work in any app; the Compii window can stay closed):
- Hold Ctrl + Alt and talk; let go to send. Tap them once: Compii listens
  hands-free and sends when you pause.
- While holding, move the mouse over or around something: that's what you
  mean ("this", "here"). Compii sees the items under your trail.
- Hold Ctrl + Win and talk: your words are typed where your cursor is
  (dictation), never into password fields.
- Ctrl + Alt + W: watch me. Show Compii a task, press it again (or say
  "done") and it saves the steps as a skill.
- Ctrl + Alt + R: say the last answer again. Ctrl + Alt + H: hide or show the buddy.

The moment you press, Compii notes the window you're in (items and labels
only, never passwords). Events for the overlay are `voice_buddy` with a
`state`: listening → thinking → answer (or needs_you / watching /
dictating / idle / setup / error), plus `voice_buddy_visible`.
"""

from __future__ import annotations

import asyncio
import random
import re
import threading
import time
from collections.abc import Awaitable, Callable
from typing import Any

from .hotkey import TAP_MAX, VK_CONTROL, VK_WIN, HoldToTalk
from .watch import Watcher

ACKS = ["On it.", "Let me look.", "One sec.", "Sure, let me check.", "Okay, looking."]
WATCH_START = re.compile(r"^(?:ok(?:ay)?\s+)?(?:watch me|watch this|let me show you|i'?ll show you)\b[\s,.:]*(?P<goal>.*)$", re.I)
WATCH_STOP = re.compile(r"^(?:ok(?:ay)?\s+)?(?:done|i'?m done|that'?s it|stop watching|finished|all done)[.!]?$", re.I)


class Buddy:
    def __init__(self, voice, agent, emit: Callable[[dict[str, Any]], None],
                 handle_intent: Callable[[str], Awaitable[bool]], loop_getter: Callable[[], Any],
                 snapshot: Callable[[], dict[str, Any] | None] | None = None,
                 cursor: Callable[[], tuple[int, int]] | None = None,
                 save_skill: Callable[[str, str, list[str]], Any] | None = None) -> None:
        self.voice = voice
        self.agent = agent
        self._emit = emit
        self._intent = handle_intent
        self._loop = loop_getter
        self._save_skill = save_skill
        from . import screen

        self._snapshot = snapshot or screen.snapshot_foreground
        self._cursor = cursor or screen.cursor_position
        self._screen = screen
        self._snap: dict[str, Any] | None = None
        self._snap_thread: threading.Thread | None = None
        self._trail: list[tuple[int, int]] = []
        self._busy = threading.Lock()
        self.tasks: set[str] = set()  # conversations started from the buddy
        self.last_answer = ""
        self.visible = True
        self.dictating = False
        self.watch_goal = ""
        self.watcher = Watcher(screen.item_at, self._cursor, screen.foreground_title, self._key_down, screen.focused_item)
        self.hotkey = HoldToTalk(self.start, self.end, self.cancel, on_command=self.command)
        self.dictation = HoldToTalk(self.dictate_start, self.dictate_end, self.cancel, first=VK_CONTROL, second=VK_WIN)
        voice.on_auto_end = self.finish

    @staticmethod
    def _key_down(vk: int) -> bool:
        import ctypes

        return bool(ctypes.windll.user32.GetAsyncKeyState(vk) & 0x8000)

    def start_shortcuts(self) -> None:
        self.hotkey.start()
        self.dictation.start()

    def emit(self, state: str, **data: Any) -> None:
        try:
            x, y = self._cursor()
        except Exception:  # noqa: BLE001
            x, y = 0, 0
        self._emit({"type": "voice_buddy", "state": state, "cursor": [x, y], **data})

    def say(self, text: str) -> None:
        if self.voice.settings.speak_replies:
            self.voice.say(text)

    # ---- talking: hold Ctrl + Alt ----

    def start(self) -> None:
        """Ctrl+Alt held: look at the screen, follow the mouse, listen."""
        if not self.voice.can_listen():
            self.emit("setup", text="Turn on listening in Compii → Settings → Voice first.")
            return
        self._snap = None
        self._trail = []

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
        threading.Thread(target=self._follow_mouse, daemon=True).start()
        self.emit("listening")

    def _follow_mouse(self) -> None:
        """While you talk, where the mouse goes is what you mean."""
        while self.voice._listening:
            try:
                p = self._cursor()
                if self._trail and abs(p[0] - self._trail[-1][0]) + abs(p[1] - self._trail[-1][1]) > 400:
                    self._trail = []  # a jump, not a gesture
                if not self._trail or abs(p[0] - self._trail[-1][0]) + abs(p[1] - self._trail[-1][1]) > 4:
                    self._trail.append(p)
            except Exception:  # noqa: BLE001
                return
            time.sleep(0.04)

    def end(self, held: float) -> None:
        """Ctrl+Alt released: a hold sends now; a quick tap keeps listening until you pause."""
        if held < TAP_MAX:
            self.voice.listen_hands_free()
            self.emit("listening", hands_free=True)
            return
        threading.Thread(target=self.finish, daemon=True).start()

    def cancel(self) -> None:
        self.voice.cancel_listening()
        self.dictating = False
        self.emit("idle")

    def finish(self) -> None:
        if not self._busy.acquire(blocking=False):
            return
        try:
            self.voice.stop_recording()  # mic off the moment you let go
            self.emit("thinking", heard="")
            if self._snap_thread is not None:
                self._snap_thread.join(timeout=2.5)
            snap = dict(self._snap or {})
            # Words on screen help recognise names and labels you say.
            self.voice.set_hints([snap.get("title", "")] + [e["name"] for e in snap.get("elements", [])[:30]])
            text = self.voice.stop_listening().strip()
            if not text:
                self.emit("idle", text="I didn't catch that.")
                return
            focus = focus_from_trail(snap, self._trail)
            if focus:
                snap["focus"] = focus
            self.emit("thinking", heard=text)
            loop = self._loop()
            if loop is None:
                return
            asyncio.run_coroutine_threadsafe(self._handle(text, snap or None), loop)
        finally:
            self._busy.release()

    async def _handle(self, text: str, snap: dict[str, Any] | None) -> None:
        if self.watcher.running and WATCH_STOP.match(text.strip()):
            self.stop_watching()
            return
        m = WATCH_START.match(text.strip())
        if m and not self.watcher.running:
            self.start_watching(m.group("goal").strip(" .") or "")
            return
        if await self._intent(text):
            self.emit("idle")
            return
        self.say(random.choice(ACKS))  # instant, human acknowledgement while the AI thinks
        task = self.agent.start(self.voice.annotate(text), origin={"buddy": True, "title": "Asked from the cursor"}, screen=snap)
        self.tasks.add(task.id)
        self.emit("thinking", heard=text, task_id=task.id, screen=(snap or {}).get("title", ""))

    # ---- commands: Ctrl + Alt + letter ----

    def command(self, letter: str) -> None:
        if letter == "W":
            self.stop_watching() if self.watcher.running else self.start_watching("")
        elif letter == "R":
            if self.last_answer:
                self.emit("answer", text=self.last_answer)
                self.say(self.last_answer)
            else:
                self.emit("idle", text="Nothing to repeat yet.")
        elif letter == "H":
            self.visible = not self.visible
            self._emit({"type": "voice_buddy_visible", "visible": self.visible})

    # ---- watch me: you demonstrate ----

    def start_watching(self, goal: str) -> None:
        self.watch_goal = goal
        self.watcher.start()
        self.emit("watching")
        self.say("I'm watching. Show me, then say done.")

    def stop_watching(self) -> None:
        steps = self.watcher.stop()
        if not steps:
            self.emit("idle", text="I didn't see any steps.")
            return
        goal = self.watch_goal or "What you showed me"
        name = goal[:1].upper() + goal[1:] if self.watch_goal else time.strftime("Shown %d %b %H:%M")
        if self._save_skill:
            self._save_skill(name, f"Repeat what the user demonstrated: {goal}.", steps)
        n = len(steps)
        summary = f"Got it: {n} step{'s' if n != 1 else ''}, saved as “{name}”. Ask me to do it any time."
        self.last_answer = summary
        self.emit("answer", text=summary, steps=steps)
        self.say(summary)

    # ---- dictation: hold Ctrl + Win ----

    def dictate_start(self) -> None:
        if not self.voice.can_listen():
            self.emit("setup", text="Turn on listening in Compii → Settings → Voice first.")
            return
        try:
            title = self._screen.foreground_title()
            self.voice.set_hints([title])
            self.voice.start_listening()
        except Exception as e:  # noqa: BLE001
            self.emit("error", text=f"I can't hear you: {e}")
            return
        self.dictating = True
        self.emit("dictating")

    def dictate_end(self, held: float) -> None:
        self.voice.stop_recording()  # mic off the moment you let go

        def run() -> None:
            text = tidy_dictation(self.voice.stop_listening())
            self.dictating = False
            if not text:
                self.emit("idle", text="I didn't catch that.")
                return
            try:
                self._screen.type_unicode(text + " ")
                self.emit("idle")
            except Exception as e:  # noqa: BLE001 - e.g. a password field
                self.emit("error", text=str(e))

        threading.Thread(target=run, daemon=True).start()

    # ---- task events → buddy states ----

    def on_task_event(self, event: dict[str, Any]) -> None:
        tid = event.get("task_id", "")
        if tid not in self.tasks:
            return
        kind = event.get("type")
        if kind == "task_finished":
            self.last_answer = event.get("text", "")
            self.emit("answer", task_id=tid, text=self.last_answer, status=event.get("status"))
        elif kind == "approval_needed":
            self.emit("needs_you", task_id=tid, text=f"{event.get('label', '')} — say yes or no.")
        elif kind == "action_started":
            self.emit("thinking", task_id=tid, step=event.get("label", ""))


def tidy_dictation(text: str) -> str:
    """Light clean-up for typed dictation: no stray spaces, a capital, final punctuation."""
    t = " ".join(text.split())
    if not t:
        return ""
    t = t[0].upper() + t[1:]
    if len(t.split()) > 3 and t[-1] not in ".!?":
        t += "."
    return t


def focus_from_trail(snap: dict[str, Any], trail: list[tuple[int, int]]) -> list[str]:
    """Items you circled or moved over while talking (ids, most likely first)."""
    if len(trail) < 3 or not snap.get("elements"):
        return []
    xs, ys = [p[0] for p in trail], [p[1] for p in trail]
    if max(xs) - min(xs) + max(ys) - min(ys) < 30:
        return []  # the mouse barely moved: no gesture
    start, end = trail[0], trail[-1]
    closed = abs(start[0] - end[0]) + abs(start[1] - end[1]) < 0.35 * (max(xs) - min(xs) + max(ys) - min(ys))
    scores: dict[str, float] = {}
    for e in snap["elements"]:
        x0, y0, x1, y1 = e["x"], e["y"], e["x"] + e["w"], e["y"] + e["h"]
        area = max(1, e["w"] * e["h"])
        if closed and min(xs) <= x0 and x1 <= max(xs) and min(ys) <= y0 and y1 <= max(ys):
            scores[e["id"]] = scores.get(e["id"], 0) + 5 + 1e4 / area  # circled: inside the loop
        hits = sum(1 for (x, y) in trail if x0 <= x <= x1 and y0 <= y <= y1)
        if hits:
            # Moved over it; small, specific items beat the big pane behind them.
            scores[e["id"]] = scores.get(e["id"], 0) + hits / (1 + area / 5000)
    return [i for i, _ in sorted(scores.items(), key=lambda kv: -kv[1])[:5]]
