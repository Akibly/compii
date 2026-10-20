"""The coach: during a lesson, Compii watches the screen and moves on by itself.

After teaching a step, the AI calls watch_for_step("a clip is on the timeline"). The coach
then looks at the window you're in about once a second, on this PC. Only when the picture
has changed and settled does it ask the vision model whether the step is done; when it
is, the conversation continues on its own ("Nice, that's in. Next…"). No "what next?"
needed. It never looks at password managers or Compii itself, stops when you ask
something else, and gives up quietly after a while.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from typing import Any

import numpy as np

TICK = 1.2  # seconds between local looks (nothing leaves the PC for these)
MIN_GAP = 4.0  # at most one vision check this often
RECHECK = 25.0  # check now and then even if little changed (small changes are easy to miss)
GIVE_UP = 15 * 60  # stop watching a step after 15 minutes
CHANGED = 1.5  # mean grey-level change that counts as "something happened"
SETTLED = 0.8  # ...and below this the screen has settled again
FIRST_CHECK = 2.5  # first look a moment after the instruction (the step may already be done)


class Coach:
    def __init__(self, check: Callable[[bytes, str], tuple[bool, str]], on_done: Callable[[str, str, str], None],
                 allowed: Callable[[], bool], grab: Callable[[], tuple[np.ndarray, Any] | None] | None = None,
                 emit: Callable[[dict[str, Any]], None] | None = None) -> None:
        from . import vision

        self._check = check
        self._on_done = on_done
        self._allowed = allowed
        self._grab = grab or vision.grab_foreground
        self._emit = emit or (lambda e: None)
        self._lock = threading.Lock()
        self._job: dict[str, Any] | None = None

    @property
    def watching(self) -> str:
        job = self._job
        return job["done_when"] if job else ""

    def watch(self, task_id: str, done_when: str) -> str:
        """Start watching for one step (replaces any earlier one). Returns a note for the AI."""
        done_when = done_when.strip()
        if not done_when:
            return "Say what the screen will show when the step is done."
        if not self._allowed():
            return ("Watching the screen is off or unavailable here, so ask the user to say \"done\" when they've done it.")
        job = {"task": task_id, "done_when": done_when, "start": time.monotonic(), "stop": threading.Event()}
        with self._lock:
            if self._job:
                self._job["stop"].set()
            self._job = job
        threading.Thread(target=self._loop, args=(job,), name="compii-coach", daemon=True).start()
        self._emit({"type": "voice_coach", "watching": True, "text": done_when})
        return ("Watching. Don't ask the user to tell you when they're done; you'll get a note when it happens. "
                "End your turn now with the instruction for this step.")

    def stop(self) -> None:
        with self._lock:
            job, self._job = self._job, None
        if job:
            job["stop"].set()
            self._emit({"type": "voice_coach", "watching": False})

    def _loop(self, job: dict[str, Any]) -> None:
        from .vision import encode_png, MAX_WIDTH

        last: np.ndarray | None = None
        changed = True  # check soon after starting: it may already be done
        last_check = time.monotonic() - MIN_GAP + FIRST_CHECK
        while not job["stop"].wait(TICK):
            now = time.monotonic()
            if now - job["start"] > GIVE_UP:
                break
            if not self._allowed():
                continue
            try:
                shot = self._grab()
            except Exception:  # noqa: BLE001 - try again next tick
                continue
            if shot is None:
                continue
            rgb, window = shot
            step = max(1, rgb.shape[1] // 96)
            thumb = rgb[::step, ::step].mean(axis=2)
            diff = float(np.abs(thumb - last).mean()) if last is not None and last.shape == thumb.shape else 99.0
            last = thumb
            if diff > CHANGED:
                changed = True
            settled = diff < SETTLED
            due = (changed and settled and now - last_check >= MIN_GAP) or now - last_check >= RECHECK
            if not due:
                continue
            last_check, changed = now, False
            k = max(1, -(-rgb.shape[1] // MAX_WIDTH))
            try:
                done, why = self._check(encode_png(np.ascontiguousarray(rgb[::k, ::k])), job["done_when"])
            except Exception:  # noqa: BLE001 - the free endpoint hiccups; look again later
                continue
            if done and not job["stop"].is_set():
                with self._lock:
                    if self._job is job:
                        self._job = None
                self._emit({"type": "voice_coach", "watching": False})
                self._on_done(job["task"], job["done_when"], why)
                return
        with self._lock:
            if self._job is job:
                self._job = None
