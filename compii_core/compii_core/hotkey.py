"""Hold-to-talk from anywhere: hold Ctrl + Alt (like Clicky's Ctrl + Option).

A low-level keyboard hook watches only the Ctrl and Alt keys. Holding both
(and nothing else) for a moment starts listening; letting go sends. A quick
tap starts listening hands-free and Compii sends when you stop talking.
Pressing any other key while holding them (Ctrl+Alt+Del, AltGr letters…)
cancels, so normal shortcuts and typing are untouched. Keys are never
blocked or recorded: the hook only looks at whether Ctrl and Alt are down.
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
        if self._thread_id is not None:
            import ctypes

            ctypes.windll.user32.PostThreadMessageW(self._thread_id, 0x0012, 0, 0)  # WM_QUIT
        self.running = False

    def _loop(self) -> None:
        import ctypes
        from ctypes import wintypes

        user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class KBDLLHOOKSTRUCT(ctypes.Structure):
            _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD), ("flags", wintypes.DWORD),
                        ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_void_p)]

        LRESULT = ctypes.c_ssize_t
        HOOKPROC = ctypes.WINFUNCTYPE(LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
        user32.SetWindowsHookExW.restype = wintypes.HHOOK
        user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
        user32.CallNextHookEx.restype = LRESULT
        user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
        kernel32.GetModuleHandleW.restype = wintypes.HMODULE

        def proc(code: int, wparam: int, lparam: int) -> int:
            if code == 0:
                info = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
                down = wparam in (0x0100, 0x0104)  # WM_KEYDOWN, WM_SYSKEYDOWN
                up = wparam in (0x0101, 0x0105)
                if down or up:
                    try:
                        self.key(int(info.vkCode), down)
                    except Exception:  # noqa: BLE001 - never break the user's keyboard
                        pass
            return user32.CallNextHookEx(None, code, wparam, lparam)  # never swallow keys

        self._proc = HOOKPROC(proc)  # keep a reference
        hook = user32.SetWindowsHookExW(13, self._proc, kernel32.GetModuleHandleW(None), 0)  # WH_KEYBOARD_LL
        if not hook:
            return
        self._thread_id = kernel32.GetCurrentThreadId()
        self.running = True
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
        user32.UnhookWindowsHookEx(hook)
        self.running = False
