"""The cursor buddy: talk to Compii from any app, Clicky-style.

Shortcuts (all work in any app; the Compii window can stay closed):
- Hold Ctrl + Alt and talk; let go to send. A quick tap offers the words you have
  highlighted back to you with taps (Explain, Summarise, Translate, Look it up).
- While holding, move the mouse over or around something: that's what you
  mean ("this", "here"). Compii sees the items under your trail.
- Highlight words anywhere first, then hold Ctrl + Alt: Compii reads the
  selection off the app itself (nothing is copied) and "explain this" /
  "translate this" work on those exact words. The overlay also shows taps
  — Explain, Summarise, Translate, Look it up — for when you'd rather not talk.
- Hold Ctrl + Win and talk: your words are typed where your cursor is
  (dictation), never into password fields.
- Say "watch me", show Compii a task, then say "done": it saves the steps
  as a skill. Say "say that again", "hide" or "show yourself" too.
- Questions within 10 minutes of the last answer continue the same
  conversation, so "and what about…" works. Say "new topic" to start fresh.

The moment you press, Compii notes the window you're in (items, labels and any
selected words only, never passwords), but only sends it to the AI when you ask
about the screen or point at something; plain questions skip it and answer
faster. Events for the overlay are `voice_buddy` with a
`state`: listening → thinking → answer (or needs_you / watching /
dictating / idle / setup / error / selected), plus `voice_buddy_visible`.
`selected` carries the words highlighted when the user tapped Ctrl+Alt, so the
overlay can offer taps instead of making them speak.
"""

from __future__ import annotations

import asyncio
import re
import threading
import time
from collections.abc import Awaitable, Callable
from typing import Any

from .hotkey import TAP_MAX, VK_CONTROL, VK_WIN, HoldToTalk
from . import sight
from .voice import spoken_reply
from .watch import MAX_SECONDS, Watcher

WATCH_START = re.compile(r"^(?:ok(?:ay)?\s+)?(?:watch me|watch this|let me show you|i'?ll show you)\b[\s,.:]*(?P<goal>.*)$", re.I)
REPEAT = re.compile(r"^(?:ok(?:ay)?\s+)?(?:say (?:that|it) again|repeat (?:that|it)?|what did you say|come again)[?.!]?$", re.I)
HIDE = re.compile(r"^(?:ok(?:ay)?\s+)?(?:hide|go away|hide yourself|disappear)[.!]?$", re.I)
NEW_TOPIC = re.compile(r"^(?:ok(?:ay)?\s+)?(?:new (?:topic|conversation|question)|start over|forget (?:that|it)|never ?mind)[.!]?$", re.I)
FOLLOW_UP_SECONDS = 600  # questions this close together continue one conversation
SHOW = re.compile(r"^(?:ok(?:ay)?\s+)?(?:show yourself|come back|show up|appear)[.!]?$", re.I)
WATCH_STOP = re.compile(r"^(?:ok(?:ay)?\s+)?(?:done|i'?m done|that'?s it|stop watching|finished|all done)[.!]?$", re.I)


class Buddy:
    def __init__(self, voice, agent, emit: Callable[[dict[str, Any]], None],
                 handle_intent: Callable[[str], Awaitable[bool]], loop_getter: Callable[[], Any],
                 snapshot: Callable[[], dict[str, Any] | None] | None = None,
                 cursor: Callable[[], tuple[int, int]] | None = None,
                 save_skill: Callable[[str, str, list[str], list[dict[str, Any]]], Any] | None = None,
                 selection: Callable[[], dict[str, Any] | None] | None = None) -> None:
        self.voice = voice
        self.agent = agent
        self._emit = emit
        self._intent = handle_intent
        self._loop = loop_getter
        self._save_skill = save_skill
        from . import screen

        self._snapshot = snapshot or screen.snapshot_foreground
        self._cursor = cursor or screen.cursor_position
        self._selection = selection or screen.selection
        self._screen = screen
        self._snap: dict[str, Any] | None = None
        self._snap_thread: threading.Thread | None = None
        # The words the user had highlighted when they pressed, kept for the whole exchange.
        self._sel: dict[str, Any] | None = None
        self._trail: list[tuple[int, int]] = []
        self._busy = threading.Lock()
        self.tasks: set[str] = set()  # conversations started from the buddy
        self.last_answer = ""
        self.conversation: str | None = None  # the buddy conversation follow-ups continue
        self.vision_key: Callable[[], str | None] | None = None  # set by the server: the NVIDIA key
        self._last_done = 0.0
        self.visible = True
        self.dictating = False
        self.watch_goal = ""
        self.last_demo: dict[str, Any] | None = None  # the last recording, kept until saved or replaced
        self.watcher = Watcher(screen.item_at, self._cursor, screen.foreground_title, self._key_down, screen.focused_item)
        self.hotkey = HoldToTalk(self.start, self.end, self.cancel)
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

    def say(self, text: str, spoken: str | None = None) -> None:
        self.voice.say(text, spoken)

    # ---- talking: hold Ctrl + Alt ----

    def start(self) -> None:
        """Ctrl+Alt held: look at the screen, follow the mouse, listen."""
        if not self.voice.can_listen():
            self.emit("setup", text="Turn on listening in Compii → Settings → Voice first.")
            return
        self._snap = None
        self._sel = None
        self._trail = []

        def look() -> None:
            try:
                self._snap = self._snapshot()
            except Exception:  # noqa: BLE001 - screen awareness is best effort
                self._snap = None
            try:
                self._sel = self._selection()  # read-only: the app's own highlight, nothing copied
            except Exception:  # noqa: BLE001 - some apps simply won't say
                self._sel = None

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
        """Ctrl+Alt released: send what you said. A quick tap offers the highlighted words back."""
        if held < TAP_MAX:
            # A tap with words highlighted is not an accident: it means "do something to these".
            threading.Thread(target=self.offer_selection, daemon=True).start()
            return
        threading.Thread(target=self.finish, daemon=True).start()

    def offer_selection(self) -> None:
        """Show the highlighted words beside the cursor, with taps for what to do with them."""
        if self._snap_thread is not None:
            self._snap_thread.join(timeout=0.8)  # the read started the moment they pressed
        text = str((self._sel or {}).get("text") or "").strip()
        if not text:
            self.cancel()  # a quick tap with nothing in front of Compii stays the accident it looks like
            return
        self.voice.cancel_listening()
        self.emit("selected", text=text[:220] + ("…" if len(text) > 220 else ""),
                  words=(self._sel or {}).get("words", 0), window=(self._sel or {}).get("window", ""))

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
                self._snap_thread.join(timeout=0.4)  # don't keep you waiting for a slow window
            snap = dict(self._snap or {})
            # Words on screen help recognise names and labels you say.
            self.voice.set_hints([snap.get("title", "")] + [e["name"] for e in snap.get("elements", [])[:30]])
            text = self.voice.stop_listening().strip()
            if not text:
                self.emit("idle", text="I didn't catch that.")
                return
            gestured = moved(self._trail)
            if wants_screen(text, gestured):
                if not sight.enabled():  # don't answer a question about the screen from nothing
                    self.emit("idle", text=sight.refusal())
                    self.say("Screen reading is turned off in Settings, so I can't see what's in front of you.")
                    return
                if self._snap_thread is not None:
                    self._snap_thread.join(timeout=2.5)
                snap = self._with_picture(dict(self._snap or {}), text)
                focus = focus_from_trail(snap, self._trail)
                if focus:
                    snap["focus"] = focus
                if self._sel:  # "this" is most often the words they highlighted
                    snap["selection"] = self._sel
            else:
                snap = {}  # a plain question: answer it without reading the screen (faster)
            self.emit("thinking", heard=text)
            loop = self._loop()
            if loop is None:
                return
            asyncio.run_coroutine_threadsafe(self._handle(text, snap or None), loop)
        finally:
            self._busy.release()

    def _with_picture(self, snap: dict[str, Any], question: str) -> dict[str, Any]:
        """Add what a snapshot can't name: the words a local OCR pass reads from a picture of
        the window (no key needed), plus a vision model when the user has one. Only when asked
        about the screen, and never for password managers."""
        from . import vision

        if not sight.enabled() or not getattr(self.voice.settings, "see_pictures", True):
            return snap
        if not vision.needs_picture(snap):
            return snap
        try:
            self.emit("thinking", heard=question, step="Looking at your screen")
            shot = vision.grab_foreground()
            if shot is None:
                return snap
            pixels, window = shot
            from . import ocr
            boxes = ocr.read_png_boxes(vision.ocr_png(pixels))
            if boxes:
                snap = vision.merge_ocr(snap, boxes, window)
            key = self.vision_key() if self.vision_key else None
            if key:
                snap = vision.merge(snap, vision.look(vision.png_of(pixels), question, key,
                                                      window=str(snap.get("title") or "")), window)
            if not snap.get("title"):
                try:
                    snap["title"] = self._screen.foreground_title()
                except Exception:  # noqa: BLE001 - the words are still worth having
                    pass
            snap.setdefault("cursor", list(self._cursor()))
            return snap
        except Exception:  # noqa: BLE001 - seeing is a bonus; answer from the labels instead
            return snap

    async def _handle(self, text: str, snap: dict[str, Any] | None) -> None:
        said = text.strip()
        if REPEAT.match(said):
            return self.command("R")
        if HIDE.match(said) or SHOW.match(said):
            self.visible = bool(SHOW.match(said))
            self._emit({"type": "voice_buddy_visible", "visible": self.visible})
            return self.emit("idle", text="Okay." if self.visible else "")
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
        if NEW_TOPIC.match(said):
            self.conversation = None
            return self.emit("idle", text="Okay, fresh start.")
        task = None
        if self.conversation and time.monotonic() - self._last_done < FOLLOW_UP_SECONDS:
            try:  # a follow-up: Compii remembers what you were just talking about
                task = self.agent.reply(self.conversation, self.voice.annotate(text), screen=snap)
            except (KeyError, RuntimeError):
                task = None
        if task is None:
            task = self.agent.start(self.voice.annotate(text), origin={"buddy": True, "title": "Asked from the cursor"},
                                    screen=snap)
            self.conversation = task.id
        self.tasks.add(task.id)
        self.emit("thinking", heard=text, task_id=task.id, screen=(snap or {}).get("title", ""))

    # ---- the words you highlighted: tapped instead of said ----

    @property
    def selected(self) -> dict[str, Any] | None:
        """The highlight Compii read when the user pressed Ctrl+Alt, if any."""
        return self._sel

    def ask(self, instruction: str) -> bool:
        """Work on the selected words now, because the user tapped a word rather than spoke it.

        The words are the ones that were highlighted when they pressed — read off the app then,
        never from the clipboard, and never from a password field or manager.
        """
        said = " ".join(str(instruction or "").split())[:120]
        picked = self._sel or {}
        if not said:
            return False
        if not str(picked.get("text") or "").strip():
            # Say why first: a tap that finds no words is worth an answer, not silence.
            self.emit("idle", text="I can’t see any selected text. Highlight the words first, "
                                   "then hold Control Alt.")
            return False
        loop = self._loop()
        if loop is None:
            return False
        snap = {"title": picked.get("window") or "", "app": picked.get("app") or "",
                "cursor": list(self._cursor()), "elements": [], "selection": picked}
        asyncio.run_coroutine_threadsafe(self._handle(said, snap), loop)
        return True

    # ---- commands (by voice: "say that again", "watch me", "hide") ----

    def command(self, letter: str) -> None:
        if letter == "W":
            self.stop_watching() if self.watcher.running else self.start_watching("")
        elif letter == "R":
            if self.last_answer:
                self.emit("answer", text=self.last_answer)
                self.say(self.last_answer, spoken_reply(self.last_answer))
            else:
                self.emit("idle", text="Nothing to repeat yet.")
        elif letter == "H":
            self.visible = not self.visible
            self._emit({"type": "voice_buddy_visible", "visible": self.visible})

    # ---- watch me: you demonstrate ----

    def start_watching(self, goal: str) -> None:
        if not sight.enabled():  # the recording is made of what it reads on screen
            self.emit("idle", text=sight.refusal())
            self.say("I can't watch you, because screen reading is turned off in Settings.")
            return
        if self.watcher.running:
            return
        self.watch_goal = goal
        self.last_demo = None
        self.watcher.start()
        self.emit("watching")
        self.say("I'm watching. Show me, then hold Control Alt and say done.")

    def watch_status(self) -> dict[str, Any]:
        watching = self.watcher.running
        return {
            "watching": watching,
            "goal": self.watch_goal,
            "steps": list(self.watcher.steps),
            "actions": self.watcher.recorded(),
            "seconds": int(time.monotonic() - self.watcher.started) if watching else 0,
            "limit": MAX_SECONDS,
        }

    def stop_watching(self, save: bool = True) -> dict[str, Any]:
        """Stop recording and return the demonstration. Saves it as a skill when
        `save` is set (the voice/hotkey path); the app reviews it first."""
        steps = self.watcher.stop()
        if not steps:
            self.emit("idle", text="I didn't see any steps.")
            return {}
        goal = self.watch_goal or "What you showed me"
        name = goal[:1].upper() + goal[1:] if self.watch_goal else time.strftime("Shown %d %b %H:%M")
        instruction = f"Repeat what the user demonstrated: {goal}."
        demo = {"goal": goal, "name": name, "instruction": instruction,
                "steps": steps, "actions": self.watcher.recorded()}
        self.last_demo = demo
        if save and self._save_skill:
            self._save_skill(name, instruction, steps, self.watcher.recorded())
        n = len(steps)
        if save:
            summary = f"Got it: {n} step{'s' if n != 1 else ''}, saved as “{name}”. Ask me to do it any time."
        else:
            summary = f"Got it: {n} step{'s' if n != 1 else ''}. Review it and save it in Compii."
        self.last_answer = summary
        self.emit("answer", text=summary, steps=steps)
        self.say(summary)
        return demo

    def cancel_watching(self) -> None:
        self.watcher.stop()
        self.last_demo = None
        self.emit("idle")

    # ---- dictation: hold Ctrl + Win ----

    def dictate_start(self) -> None:
        if not sight.enabled():  # typing safely means reading the field first
            self.emit("idle", text=sight.refusal())
            return
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
            self._last_done = time.monotonic()
            self.last_answer = event.get("text", "")
            self.emit("answer", task_id=tid, text=self.last_answer, status=event.get("status"))
        elif kind == "approval_needed":
            self.emit("needs_you", task_id=tid, approval_id=event.get("approval_id", ""),
                      text=f"{event.get('label', '')}?")  # Yes / No buttons beside the cursor, or say it
        elif kind == "question":
            # Choice buttons beside the cursor; type the answer in the app if none of them fit.
            self.emit("needs_you", task_id=tid, question_id=event.get("question_id", ""),
                      choices=event.get("choices", []), text=event.get("question", ""))
        elif kind == "takeover":
            # A secret step is the user's to do; the card says "Done — carry on".
            self.emit("needs_you", task_id=tid, takeover_id=event.get("takeover_id", ""),
                      text=event.get("what", ""))
        elif kind == "question_answered" or kind == "takeover_done":
            self.emit("thinking", task_id=tid, step="Thanks — carrying on")
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


SCREEN_WORDS = re.compile(
    r"\b(this|that|these|those|here|there|it'?s|screen|window|page|tab|site|button|icon|menu|link|box|field|"
    r"click|tap|select|open|close|scroll|type|fill|where|which|see|look|showing|shown|show me|how do i|how can i|"
    r"how to|error|warning|message|popup|pop-?up|dialog|settings?|option|app|file|folder|document|email|"
    r"spreadsheet|cell|column|row|chart|picture|image|video|text|word|line|code|read|explain|translate|summari[sz]e)\b",
    re.I)


def moved(trail: list[tuple[int, int]]) -> bool:
    """Did the mouse move with purpose while you talked (pointing at something)?"""
    if len(trail) < 3:
        return False
    xs, ys = [p[0] for p in trail], [p[1] for p in trail]
    return max(xs) - min(xs) + max(ys) - min(ys) >= 30


def wants_screen(text: str, gestured: bool = False) -> bool:
    """Only read the screen when the request is about it ("what's this?", "where do I
    click", or the mouse pointed at something). Plain questions skip it and come back faster."""
    return gestured or bool(SCREEN_WORDS.search(text))


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
