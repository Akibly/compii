"""Find things on screen through Windows UI Automation, so Compii can point at them.

Uses element names from the accessibility tree rather than guessing pixels.
Searches the user's own windows, top of the stack first, skipping Compii's.
"""

from __future__ import annotations

import sys
import time
from dataclasses import dataclass

SEARCH_SECONDS = 4.0
MAX_ELEMENTS = 4000
MAX_WINDOWS = 4


@dataclass
class Found:
    name: str
    role: str
    window: str
    left: int
    top: int
    right: int
    bottom: int

    def as_event(self) -> dict[str, object]:
        return {
            "name": self.name,
            "role": self.role,
            "window": self.window,
            "x": self.left,
            "y": self.top,
            "w": self.right - self.left,
            "h": self.bottom - self.top,
        }


def make_dpi_aware() -> None:
    """Report physical pixels so positions match the screen exactly."""
    if sys.platform != "win32":
        return
    import ctypes

    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except (AttributeError, OSError):
        pass


def _score(name: str, target: str) -> int:
    n = name.strip().lower()
    if not n:
        return 0
    if n == target:
        return 3
    if n.startswith(target):
        return 2
    return 1 if target in n else 0


def _user_windows(auto) -> list:
    """Top-level windows in stacking order, minus Compii's own and hidden ones.

    Windows can close while we look at them; those are skipped.
    """
    out = []
    for w in auto.GetRootControl().GetChildren():
        try:
            if w.Name and "compii" not in w.Name.lower() and not w.IsOffscreen:
                out.append((w, w.Name))
        except Exception:  # noqa: BLE001 - the window vanished mid-read
            continue
        if len(out) >= MAX_WINDOWS:
            break
    return out


def find_element(target: str) -> Found | None:
    """Best match for `target` among the visible elements of the user's top windows."""
    if sys.platform != "win32":
        raise RuntimeError("Pointing at things on screen is only available on Windows for now.")
    import uiautomation as auto

    wanted = target.strip().lower()
    best: tuple[int, Found] | None = None
    with auto.UIAutomationInitializerInThread():
        deadline = time.monotonic() + SEARCH_SECONDS
        for window, title in _user_windows(auto):
            seen = 0
            try:
                walker = auto.WalkControl(window, includeTop=True, maxDepth=25)
                for control, _depth in walker:
                    seen += 1
                    if seen > MAX_ELEMENTS or time.monotonic() > deadline:
                        break
                    try:
                        score = _score(control.Name or "", wanted)
                        if not score or control.IsOffscreen:
                            continue
                        r = control.BoundingRectangle
                        if r.width() <= 0 or r.height() <= 0:
                            continue
                        found = Found(control.Name, control.ControlTypeName, title,
                                      r.left, r.top, r.right, r.bottom)
                    except Exception:  # noqa: BLE001 - element went away
                        continue
                    # Prefer exact names, then smaller (more specific) elements.
                    key = score * 10_000_000 - r.width() * r.height()
                    if best is None or key > best[0]:
                        best = (key, found)
            except Exception:  # noqa: BLE001 - window closed while walking it
                continue
            if best and best[1].window == title:
                break  # the topmost window with a match wins
    return best[1] if best else None
