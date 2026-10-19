"""Hold-to-talk from anywhere: hold Ctrl + Alt (like Clicky's Ctrl + Option).

Compii checks whether Ctrl and Alt are held, about 33 times a second. Holding both
(and nothing else) for a moment starts listening; letting go sends. A quick
tap starts listening hands-free and Compii sends when you stop talking.
Pressing any other key while holding them (Ctrl+Alt+Del, AltGr letters…)
cancels, so normal shortcuts and typing are untouched. Keys are never
blocked or recorded: only whether Ctrl and Alt (and anything held with them) are down.
"""

from __future__ import annotations

import sys
import threading
import time
from collections.abc import Callable

HOLD_TO_START = 0.18  # seconds both keys must be held before listening starts
TAP_MAX = 0.45  # shorter than this counts as a tap (hands-free: sends on silence)

VK_CONTROL = {0x11, 0xA2, 0xA3}
VK_ALT = {0x12, 0xA4, 0xA5}


class HoldToTalk:
    """Calls `on_start()` when Ctrl+Alt is held, `on_end(held_seconds)` on release,
    and `on_cancel()` if another key joins in after listening started."""

    def __init__(self, on_start: Callable[[], None], on_end: Callable[[float], None],
                 on_cancel: Callable[[], None] | None = None) -> None:
        self.on_start, self.on_end, self.on_cancel = on_start, on_end, on_cancel
        self._down: set[int] = set()
        self._both_since: float | None = None
        self._spoiled = False  # another key was pressed during this hold
        self._active = False  # listening started for this hold
        self._timer: threading.Timer | None = None
        self._thread: threading.Thread | None = None
        self._thread_id: int | None = None
        self.running = False

    # ---- key logic (platform independent, unit-tested) ----

    def key(self, vk: int, down: bool) -> None:
        is_mod = vk in VK_CONTROL or vk in VK_ALT
        if down:
            if not is_mod:
                if self._both() and not self._spoiled:
                    self._spoiled = True
                    self._cancel_timer()
                    if self._active:
                        self._active = False
                        if self.on_cancel:
                            self.on_cancel()
                return
            self._down.add(vk)
            if self._both() and self._both_since is None and not self._spoiled:
                self._both_since = time.monotonic()
                self._timer = threading.Timer(HOLD_TO_START, self._fire)
                self._timer.daemon = True
                self._timer.start()
            return
        if not is_mod:
            return
        self._down.discard(vk)
        if not self._both():
            self._cancel_timer()
            held = time.monotonic() - self._both_since if self._both_since else 0.0
            if self._active:
                self._active = False
                self.on_end(held)
            self._both_since = None
            if not self._down:
                self._spoiled = False

    def _both(self) -> bool:
        return bool(self._down & VK_CONTROL) and bool(self._down & VK_ALT)

    def _fire(self) -> None:
        if self._both() and not self._spoiled and not self._active:
            self._active = True
            self.on_start()

    def _cancel_timer(self) -> None:
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None

    # ---- Windows hook ----

    def start(self) -> None:
        if sys.platform != "win32" or self.running:
            return
        self._thread = threading.Thread(target=self._loop, name="compii-hotkey", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self.running = False

    def _loop(self) -> None:
        """Poll the real key state ~33 times a second. Unlike a keyboard hook, this
        can't be silently dropped by Windows when Compii is busy transcribing,
        so letting go of Ctrl+Alt is never missed (at worst it's seen 30 ms late)."""
        import ctypes

        get = ctypes.windll.user32.GetAsyncKeyState
        watched = sorted(VK_CONTROL - {0x11} | VK_ALT - {0x12})  # left/right Ctrl and Alt
        # Any other key held with them means a real shortcut (Ctrl+Alt+Del, AltGr letters…).
        others = [vk for vk in range(0x08, 0xFF)
                  if vk not in VK_CONTROL | VK_ALT | {0x10, 0xA0, 0xA1} and not 0x01 <= vk <= 0x06]
        before: set[int] = set()
        self.running = True
        while self.running:
            try:
                now = {vk for vk in watched if get(vk) & 0x8000}
                if now & VK_CONTROL and now & VK_ALT:
                    other = next((vk for vk in others if get(vk) & 0x8000), None)
                    if other is not None:
                        now.add(other)
                for vk in now - before:
                    self.key(vk, True)
                for vk in before - now:
                    self.key(vk, False)
                before = now
            except Exception:  # noqa: BLE001 - never stop watching
                pass
            time.sleep(0.03)
