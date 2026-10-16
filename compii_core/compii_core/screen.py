"""See and operate Windows apps through UI Automation (the accessibility tree).

Elements are found by their visible names, not by guessing pixels, and
actions use the element's own controls (invoke, set value, toggle) so the
user's mouse is left alone whenever possible. Compii's own windows are
never searched or touched.
"""

from __future__ import annotations

import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

SEARCH_SECONDS = 4.0
MAX_ELEMENTS = 4000
MAX_WINDOWS = 4
MAX_READ_LINES = 250


class ScreenError(Exception):
    """Something on screen couldn't be found or used; the agent can adapt."""


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


def _need_windows() -> None:
    if sys.platform != "win32":
        raise ScreenError("Seeing and operating apps is only available on Windows for now.")


def _score(name: str, target: str) -> int:
    n = name.strip().lower()
    if not n:
        return 0
    if n == target:
        return 3
    if n.startswith(target):
        return 2
    return 1 if target in n else 0


def _user_windows(auto, window: str | None = None) -> list:
    """Top-level windows in stacking order, minus Compii's own and hidden ones.

    With `window`, only windows whose title contains it. Windows can close
    while we look at them; those are skipped.
    """
    want = window.strip().lower() if window else None
    out = []
    for w in auto.GetRootControl().GetChildren():
        try:
            name = w.Name or ""
            if not name or "compii" in name.lower() or w.IsOffscreen:
                continue
            if want and want not in name.lower():
                continue
            out.append((w, name))
        except Exception:  # noqa: BLE001 - the window vanished mid-read
            continue
        if len(out) >= MAX_WINDOWS:
            break
    return out


def _search(auto, target: str, window: str | None = None):
    """(Found, control) for the best match, or (None, None)."""
    wanted = target.strip().lower()
    best = None
    deadline = time.monotonic() + SEARCH_SECONDS
    for win, title in _user_windows(auto, window):
        seen = 0
        try:
            for control, _depth in auto.WalkControl(win, includeTop=True, maxDepth=25):
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
                    found = Found(control.Name, control.ControlTypeName, title, r.left, r.top, r.right, r.bottom)
                except Exception:  # noqa: BLE001 - element went away
                    continue
                # Prefer exact names, then smaller (more specific) elements.
                key = score * 10_000_000 - r.width() * r.height()
                if best is None or key > best[0]:
                    best = (key, found, control)
        except Exception:  # noqa: BLE001 - window closed while walking it
            continue
        if best and best[1].window == title:
            break  # the topmost window with a match wins
    return (best[1], best[2]) if best else (None, None)


def find_element(target: str, window: str | None = None) -> Found | None:
    """Best match for `target` among the visible elements of the user's top windows."""
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        return _search(auto, target, window)[0]


# ---- operating apps ----------------------------------------------------------------


def list_windows() -> list[dict[str, Any]]:
    _need_windows()
    import uiautomation as auto

    out = []
    with auto.UIAutomationInitializerInThread():
        for w in auto.GetRootControl().GetChildren():
            try:
                name = w.Name or ""
                if name and "compii" not in name.lower() and not w.IsOffscreen:
                    out.append({"title": name, "app": w.ClassName})
            except Exception:  # noqa: BLE001
                continue
    return out[:40]


def focus_window(window: str) -> str:
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        wins = _user_windows(auto, window)
        if not wins:
            raise ScreenError(f"No open window has “{window}” in its title.")
        win, title = wins[0]
        try:
            win.SetActive()
            win.SetFocus()
        except Exception as e:  # noqa: BLE001
            raise ScreenError(f"Couldn't switch to “{title}”: {e}") from e
        return title


def read_window(window: str | None = None) -> str:
    """The visible text and controls of a window, one per line, for the agent to read."""
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        wins = _user_windows(auto, window)
        if not wins:
            raise ScreenError(f"No open window has “{window}” in its title." if window else "No windows are open.")
        win, title = wins[0]
        lines = [f"Window: {title}"]
        seen: set[str] = set()
        deadline = time.monotonic() + SEARCH_SECONDS
        for control, depth in auto.WalkControl(win, includeTop=False, maxDepth=25):
            if len(lines) >= MAX_READ_LINES or time.monotonic() > deadline:
                lines.append("… (more not shown)")
                break
            try:
                if control.IsOffscreen:
                    continue
                name = (control.Name or "").strip()
                value = ""
                try:
                    vp = control.GetValuePattern()
                    value = (vp.Value or "").strip() if vp else ""
                except Exception:  # noqa: BLE001
                    pass
                if not name and not value:
                    continue
                line = f"{'  ' * min(depth, 6)}{control.ControlTypeName.replace('Control', '')}: {name}"
                if value and value != name:
                    line += f" = {value[:300]}"
                if line in seen:
                    continue
                seen.add(line)
                lines.append(line)
            except Exception:  # noqa: BLE001
                continue
        return "\n".join(lines)


def _act(target: str, window: str | None, before: Callable[[Found], None] | None, action) -> Found:
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        found, control = _search(auto, target, window)
        if found is None:
            where = f" in “{window}”" if window else ""
            raise ScreenError(f"Couldn't find anything named “{target}”{where}. Use read_window to see the exact labels.")
        if before:
            before(found)
        action(auto, control)
        return found


def click(target: str, window: str | None = None, before: Callable[[Found], None] | None = None) -> Found:
    """Activate a button, menu, link, tab or checkbox by its visible name."""

    def press(auto, control) -> None:
        for getter, verb in (
            ("GetInvokePattern", "Invoke"),
            ("GetTogglePattern", "Toggle"),
            ("GetSelectionItemPattern", "Select"),
            ("GetExpandCollapsePattern", "Expand"),
        ):
            try:
                pattern = getattr(control, getter)()
            except Exception:  # noqa: BLE001
                pattern = None
            if pattern:
                getattr(pattern, verb)()
                return
        control.Click(simulateMove=False)  # last resort: a real click

    return _act(target, window, before, press)


def type_text(text: str, target: str | None = None, window: str | None = None,
              before: Callable[[Found], None] | None = None) -> Found | None:
    """Put text into a field (by its label), or type it where the cursor is."""
    if target:
        def fill(auto, control) -> None:
            try:
                vp = control.GetValuePattern()
            except Exception:  # noqa: BLE001
                vp = None
            if vp and not getattr(vp, "IsReadOnly", False):
                vp.SetValue(text)
            else:
                control.SetFocus()
                auto.SendKeys(_literal(text), waitTime=0.02)

        return _act(target, window, before, fill)
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        if window:
            wins = _user_windows(auto, window)
            if not wins:
                raise ScreenError(f"No open window has “{window}” in its title.")
            wins[0][0].SetActive()
        auto.SendKeys(_literal(text), waitTime=0.02)
    return None


KEY_NAMES = {
    "ctrl": "Ctrl", "control": "Ctrl", "alt": "Alt", "shift": "Shift", "win": "Win",
    "enter": "Enter", "return": "Enter", "tab": "Tab", "esc": "Esc", "escape": "Esc",
    "backspace": "Back", "delete": "Del", "del": "Del", "up": "Up", "down": "Down",
    "left": "Left", "right": "Right", "home": "Home", "end": "End", "pageup": "PageUp",
    "pagedown": "PageDown", "space": "Space", **{f"f{i}": f"F{i}" for i in range(1, 13)},
}


def keys_to_sendkeys(combo: str) -> str:
    """'ctrl+s' -> '{Ctrl}s'; 'alt+f4' -> '{Alt}{F4}'; 'enter' -> '{Enter}'."""
    out = []
    for part in combo.replace(" ", "").split("+"):
        p = part.lower()
        if p in KEY_NAMES:
            out.append("{" + KEY_NAMES[p] + "}")
        elif len(part) == 1:
            out.append(part.lower())
        else:
            raise ScreenError(f"Unknown key “{part}”. Use names like ctrl, alt, shift, enter, tab, f5.")
    return "".join(out)


def press_keys(combo: str, window: str | None = None) -> str:
    _need_windows()
    import uiautomation as auto

    keys = keys_to_sendkeys(combo)
    with auto.UIAutomationInitializerInThread():
        title = ""
        if window:
            wins = _user_windows(auto, window)
            if not wins:
                raise ScreenError(f"No open window has “{window}” in its title.")
            wins[0][0].SetActive()
            title = wins[0][1]
        auto.SendKeys(keys, waitTime=0.05)
    return title


def _literal(text: str) -> str:
    """Escape text so SendKeys types it exactly (braces are its key syntax)."""
    return "".join("{" + ch + "}" if ch in "{}" else ch for ch in text)
