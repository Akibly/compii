"""See and operate Windows apps through UI Automation (the accessibility tree).

Elements are found by their visible names, not by guessing pixels, and
actions use the element's own controls (invoke, set value, toggle) so the
user's mouse is left alone whenever possible. Compii's own windows are
never searched or touched.
"""

from __future__ import annotations

import functools
import sys
import threading
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


# All screen reading runs on ONE long-lived thread. UI Automation is COM: setting it up
# and tearing it down on a new thread per call, while sharing one automation object,
# can crash Python outright (Core vanished with exit code 139).
_uia_jobs: Any = None
_uia_lock = threading.Lock()


def _uia_worker(jobs: Any) -> None:
    import ctypes

    ctypes.windll.ole32.CoInitializeEx(None, 0x2)  # apartment-threaded, kept for the thread's life
    while True:
        fn, args, kw, done = jobs.get()
        try:
            done.set_result(fn(*args, **kw))
        except BaseException as e:  # noqa: BLE001 - handed back to the caller
            done.set_exception(e)


def _on_uia_thread(fn: Callable) -> Callable:
    @functools.wraps(fn)
    def run(*args: Any, **kw: Any) -> Any:
        global _uia_jobs
        if sys.platform != "win32" or threading.current_thread().name == "compii-uia":
            return fn(*args, **kw)
        from concurrent.futures import Future
        import queue

        with _uia_lock:
            if _uia_jobs is None:
                _uia_jobs = queue.SimpleQueue()
                threading.Thread(target=_uia_worker, args=(_uia_jobs,), name="compii-uia", daemon=True).start()
        done: Future = Future()
        _uia_jobs.put((fn, args, kw, done))
        return done.result()

    return run


def warm_up() -> None:
    """Read the screen once in the background, so the first Ctrl+Alt isn't slow
    (browser-based apps build their accessibility tree on first use)."""
    threading.Thread(target=lambda: _safely(snapshot_foreground), daemon=True).start()


def _safely(fn: Callable) -> None:
    try:
        fn()
    except Exception:  # noqa: BLE001 - best effort
        pass


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


@_on_uia_thread
def find_element(target: str, window: str | None = None) -> Found | None:
    """Best match for `target` among the visible elements of the user's top windows."""
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        return _search(auto, target, window)[0]


# ---- operating apps ----------------------------------------------------------------


@_on_uia_thread
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


@_on_uia_thread
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


@_on_uia_thread
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


@_on_uia_thread
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


@_on_uia_thread
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


@_on_uia_thread
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


# ---- what's on screen when you ask (screen awareness) ----------------------------------

# Apps whose windows Compii never reads: password managers and the like.
BLOCKED_APPS = ("1password", "bitwarden", "keepass", "lastpass", "dashlane", "enpass", "roboform", "nordpass", "keeper")
SNAPSHOT_ITEMS = 160
SNAPSHOT_SECONDS = 1.2


def _process_name(pid: int) -> str:
    """e.g. "excel.exe" for a window's process (no extra packages)."""
    import ctypes
    from ctypes import wintypes

    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(520)
        size = wintypes.DWORD(520)
        if k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return buf.value.replace("/", "\\").rsplit("\\", 1)[-1].lower()
        return ""
    finally:
        k.CloseHandle(h)


def cursor_position() -> tuple[int, int]:
    import ctypes
    from ctypes import wintypes

    pt = wintypes.POINT()
    ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
    return pt.x, pt.y


@_on_uia_thread
def snapshot_foreground() -> dict[str, Any] | None:
    """The window you're looking at, as a compact list of items with ids (e1, e2…),
    roles, labels and positions, plus the item under the mouse. None if it's
    Compii's own window. Password fields and password-manager apps are skipped."""
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        try:
            win = auto.GetForegroundControl()
            win = win.GetTopLevelControl() or win
            title = (win.Name or "").strip()
        except Exception:  # noqa: BLE001
            return None
        if not title or "compii" in title.lower():
            return None
        app = ""
        try:
            app = _process_name(win.ProcessId) or (win.ClassName or "").lower()
        except Exception:  # noqa: BLE001
            app = (win.ClassName or "").lower()
        cx, cy = cursor_position()
        snap: dict[str, Any] = {"title": title, "app": app, "cursor": [cx, cy], "elements": [], "at": time.time()}
        if any(b in app or b in title.lower() for b in BLOCKED_APPS):
            snap["blocked"] = True
            return snap
        under = None
        try:
            c = auto.ControlFromPoint(cx, cy)
            if c is not None and not getattr(c, "IsPassword", False):
                under = (c.Name or "").strip()
        except Exception:  # noqa: BLE001
            pass
        seen: set[tuple] = set()
        deadline = time.monotonic() + SNAPSHOT_SECONDS
        for control, _depth in auto.WalkControl(win, includeTop=False, maxDepth=25):
            if len(snap["elements"]) >= SNAPSHOT_ITEMS or time.monotonic() > deadline:
                snap["truncated"] = True
                break
            try:
                if control.IsOffscreen or getattr(control, "IsPassword", False):
                    continue
                name = (control.Name or "").strip()
                if not name:
                    continue
                r = control.BoundingRectangle
                if r.width() <= 2 or r.height() <= 2:
                    continue
                role = control.ControlTypeName.replace("Control", "")
                key = (role, name[:60], r.left // 8, r.top // 8)
                if key in seen:
                    continue
                seen.add(key)
                snap["elements"].append({"id": f"e{len(snap['elements']) + 1}", "role": role, "name": name[:120],
                                         "x": r.left, "y": r.top, "w": r.width(), "h": r.height()})
            except Exception:  # noqa: BLE001 - the window changed while we read it
                continue
        snap["under_cursor"] = under
        return snap


def describe_snapshot(snap: dict[str, Any]) -> str:
    """The snapshot as compact text for the AI (one line per item)."""
    if snap.get("blocked"):
        return f"The user is in “{snap['title']}”, a password manager or similar; Compii doesn't read it."
    lines = [f"Window: “{snap['title']}” ({snap.get('app', '')}). Mouse at {snap['cursor'][0]},{snap['cursor'][1]}"
             + (f", over “{snap['under_cursor']}”." if snap.get("under_cursor") else ".")]
    if snap.get("seen"):
        lines.append("What the window shows (from a picture of it): " + snap["seen"]
                     + " Items with ids v1, v2… were found in that picture; point at them by id.")
    if snap.get("focus"):
        by_id = {e["id"]: e for e in snap["elements"]}
        shown = [f"{i} · {by_id[i]['role']} · {by_id[i]['name']}" for i in snap["focus"] if i in by_id]
        if shown:
            lines.append("While talking, the user circled or moved the mouse over (most likely first; "
                         "\"this\"/\"here\" means these): " + "; ".join(shown))
    lines.append("Items (id · type · label):")
    for e in snap["elements"]:
        lines.append(f"{e['id']} · {e['role']} · {e['name']}")
    if snap.get("truncated"):
        lines.append("… more items not listed.")
    return "\n".join(lines)


# ---- dictation, clicks and demonstrations ----------------------------------------------


def mouse_down() -> bool:
    """Is the left mouse button held right now?"""
    import ctypes

    return bool(ctypes.windll.user32.GetAsyncKeyState(0x01) & 0x8000)


@_on_uia_thread
def item_at(x: int, y: int) -> dict[str, Any] | None:
    """The item under a screen point: label, type, window. Never a password field's contents."""
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        try:
            c = auto.ControlFromPoint(x, y)
            if c is None:
                return None
            top = c.GetTopLevelControl()
            name = (c.Name or "").strip()
            r = c.BoundingRectangle
            return {"name": name[:80], "role": c.ControlTypeName.replace("Control", ""),
                    "window": (top.Name if top else "") or "", "password": bool(getattr(c, "IsPassword", False)),
                    "x": r.left, "y": r.top, "w": r.width(), "h": r.height()}
        except Exception:  # noqa: BLE001
            return None


@_on_uia_thread
def focused_item() -> dict[str, Any] | None:
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        try:
            c = auto.GetFocusedControl()
            if c is None:
                return None
            top = c.GetTopLevelControl()
            return {"name": (c.Name or "").strip()[:80], "role": c.ControlTypeName.replace("Control", ""),
                    "window": (top.Name if top else "") or "", "password": bool(getattr(c, "IsPassword", False))}
        except Exception:  # noqa: BLE001
            return None


def foreground_title() -> str:
    import ctypes

    user32 = ctypes.windll.user32
    h = user32.GetForegroundWindow()
    n = user32.GetWindowTextLengthW(h)
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(h, buf, n + 1)
    return buf.value


def type_unicode(text: str) -> None:
    """Type text where the cursor is, in any app (dictation). Refuses password fields."""
    _need_windows()
    f = focused_item()
    if f and f["password"]:
        raise ScreenError("That's a password field. Compii never types there.")
    import ctypes
    from ctypes import wintypes

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                    ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

    class INPUT(ctypes.Structure):
        class _U(ctypes.Union):
            _fields_ = [("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]

        _anonymous_ = ("u",)
        _fields_ = [("type", wintypes.DWORD), ("u", _U)]

    events = []
    for ch in text.replace("\r\n", "\n"):
        if ch == "\n":
            events += [INPUT(type=1, ki=KEYBDINPUT(0x0D, 0, 0, 0, 0)), INPUT(type=1, ki=KEYBDINPUT(0x0D, 0, 2, 0, 0))]
            continue
        code = ord(ch)
        units = [code] if code <= 0xFFFF else [0xD800 + ((code - 0x10000) >> 10), 0xDC00 + ((code - 0x10000) & 0x3FF)]
        for u in units:
            events.append(INPUT(type=1, ki=KEYBDINPUT(0, u, 0x0004, 0, 0)))  # KEYEVENTF_UNICODE
            events.append(INPUT(type=1, ki=KEYBDINPUT(0, u, 0x0004 | 0x0002, 0, 0)))
    if events:
        arr = (INPUT * len(events))(*events)
        ctypes.windll.user32.SendInput(len(events), arr, ctypes.sizeof(INPUT))
