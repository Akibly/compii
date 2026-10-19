"""Hold-to-talk from anywhere (like Clicky's Ctrl + Option), and more shortcuts.

Compii checks whether the shortcut keys are held, about 33 times a second
(a keyboard hook can be silently dropped by Windows while Compii is busy,
which used to leave it stuck "listening"). Keys are never blocked or
recorded: only whether the modifier keys (and anything held with them) are down.

- Hold Ctrl + Alt and talk; let go to send. A quick tap listens hands-free and
  sends when you pause.
- Hold Ctrl + Win to dictate into any app.
- Ctrl + Alt + a letter runs a command (W watch me, R repeat, H hide the buddy).
  Any other key held with them (Ctrl+Alt+Del, AltGr letters…) cancels, so
  normal shortcuts and typing are untouched.
"""

from __future__ import annotations

import sys
import threading
import time
from collections.abc import Callable

HOLD_TO_START = 0.18  # seconds the keys must be held before listening starts
TAP_MAX = 0.45  # shorter than this counts as a tap (hands-free: sends on silence)

VK_CONTROL = {0x11, 0xA2, 0xA3}
VK_ALT = {0x12, 0xA4, 0xA5}
VK_WIN = {0x5B, 0x5C}
COMMAND_KEYS = {ord("W"), ord("R"), ord("H")}


class HoldToTalk:
    """Calls `on_start()` when both modifier groups are held, `on_end(held_seconds)` on
    release, `on_cancel()` if another key joins in after listening started, and
    `on_command(letter)` for Ctrl+Alt+W/R/H style commands."""

    def __init__(self, on_start: Callable[[], None], on_end: Callable[[float], None],
                 on_cancel: Callable[[], None] | None = None, on_command: Callable[[str], None] | None = None,
                 first: set[int] = VK_CONTROL, second: set[int] = VK_ALT, commands: set[int] | None = None) -> None:
        self.on_start, self.on_end, self.on_cancel, self.on_command = on_start, on_end, on_cancel, on_command
        self.first, self.second = first, second
        self.commands = COMMAND_KEYS if commands is None and on_command else (commands or set())
        self._down: set[int] = set()
        self._both_since: float | None = None
        self._spoiled = False  # another key was pressed during this hold
        self._active = False  # listening started for this hold
        self._timer: threading.Timer | None = None
        self._thread: threading.Thread | None = None
        self.running = False

    # ---- key logic (platform independent, unit-tested) ----

    def _is_mod(self, vk: int) -> bool:
        return vk in self.first or vk in self.second

    def key(self, vk: int, down: bool) -> None:
        if down:
            if not self._is_mod(vk):
                if self._both() and not self._spoiled:
                    self._spoiled = True
                    self._cancel_timer()
                    if self._active:
                        self._active = False
                        if self.on_cancel:
                            self.on_cancel()
                    if vk in self.commands and self.on_command:
                        self.on_command(chr(vk))
                return
            self._down.add(vk)
            if self._both() and self._both_since is None and not self._spoiled:
                self._both_since = time.monotonic()
                self._timer = threading.Timer(HOLD_TO_START, self._fire)
                self._timer.daemon = True
                self._timer.start()
            return
        if not self._is_mod(vk):
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
        return bool(self._down & self.first) and bool(self._down & self.second)

    def _fire(self) -> None:
        if self._both() and not self._spoiled and not self._active:
            self._active = True
            self.on_start()

    def _cancel_timer(self) -> None:
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None

    # ---- polling the real key state ----

    def start(self) -> None:
        if sys.platform != "win32" or self.running:
            return
        self._thread = threading.Thread(target=self._loop, name="compii-hotkey", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self.running = False

    def _loop(self) -> None:
        import ctypes

        get = ctypes.windll.user32.GetAsyncKeyState
        generic = {0x11, 0x12, 0x10}
        watched = sorted((self.first | self.second) - generic)  # left/right versions only
        mods = self.first | self.second | VK_CONTROL | VK_ALT | VK_WIN | {0x10, 0xA0, 0xA1}
        others = [vk for vk in range(0x08, 0xFF) if vk not in mods and not 0x01 <= vk <= 0x06]
        before: set[int] = set()
        self.running = True
        while self.running:
            try:
                now = {vk for vk in watched if get(vk) & 0x8000}
                if now & self.first and now & self.second:
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
