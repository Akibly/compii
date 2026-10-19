"""Watch me: you demonstrate a task once, Compii writes down the steps.

Recorded: what you click (the item's label and window, not pixels), the
shortcuts you press (Ctrl+S, Enter…), and the windows you switch to. Never
recorded: what you type (only "typed in the Subject field"), passwords, or
the screen itself. The steps become a skill you can run again by name.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from typing import Any

MAX_SECONDS = 600  # like Grok Bot's 10-minute teaching limit
KEY_NAMES = {0x0D: "Enter", 0x09: "Tab", 0x1B: "Esc", 0x2E: "Delete", 0x08: "Backspace"}
MODS = {0xA2: "Ctrl", 0xA3: "Ctrl", 0xA4: "Alt", 0xA5: "Alt", 0x5B: "Win", 0x5C: "Win"}


class Watcher:
    def __init__(self, item_at: Callable[[int, int], dict[str, Any] | None],
                 cursor: Callable[[], tuple[int, int]], foreground: Callable[[], str],
                 key_down: Callable[[int], bool], focused: Callable[[], dict[str, Any] | None]) -> None:
        self._item_at, self._cursor, self._foreground, self._key, self._focused = item_at, cursor, foreground, key_down, focused
        self.steps: list[str] = []
        self.running = False
        self.started = 0.0
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self.running:
            return
        self.steps, self.running, self.started = [], True, time.monotonic()
        self._thread = threading.Thread(target=self._loop, name="compii-watch", daemon=True)
        self._thread.start()

    def stop(self) -> list[str]:
        self.running = False
        if self._thread is not None:
            self._thread.join(timeout=1)
        return list(self.steps)

    def _add(self, step: str) -> None:
        if step and (not self.steps or self.steps[-1] != step):
            self.steps.append(step)

    def _loop(self) -> None:
        was_down = False
        held: set[int] = set()
        window = self._foreground()
        typing_in: str | None = None
        while self.running and time.monotonic() - self.started < MAX_SECONDS:
            try:
                # Window switches.
                w = self._foreground()
                if w and w != window and "compii" not in w.lower():
                    window = w
                    self._add(f"Switch to the “{w}” window")
                # Clicks: what was clicked, by name.
                down = self._key(0x01)
                if down and not was_down:
                    x, y = self._cursor()
                    item = self._item_at(x, y)
                    if item and item.get("name") and "compii" not in item.get("window", "").lower():
                        self._add(f"Click {item['role'].lower() or 'item'} “{item['name']}” in “{item['window']}”")
                    typing_in = None
                was_down = down
                # Shortcuts (modifier + key) and special keys; never the letters you type.
                mods = sorted({MODS[vk] for vk in MODS if self._key(vk)}, key=["Ctrl", "Alt", "Win"].index)
                for vk in list(range(0x30, 0x5B)) + list(range(0x70, 0x7C)) + list(KEY_NAMES):
                    is_down = self._key(vk)
                    if is_down and vk not in held:
                        held.add(vk)
                        name = KEY_NAMES.get(vk) or (f"F{vk - 0x6F}" if 0x70 <= vk <= 0x7B else chr(vk))
                        if mods:
                            self._add(f"Press {'+'.join(mods + [name])}")
                        elif vk in KEY_NAMES:
                            self._add(f"Press {name}")
                        elif not mods:
                            f = self._focused() or {}
                            label = f.get("name") or f.get("role") or "the field"
                            if typing_in != label and not f.get("password"):
                                typing_in = label
                                self._add(f"Type the text into “{label}”")
                    elif not is_down:
                        held.discard(vk)
            except Exception:  # noqa: BLE001 - recording is best effort
                pass
            time.sleep(0.04)
        self.running = False
