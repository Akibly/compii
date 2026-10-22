"""See and operate Windows apps through UI Automation (the accessibility tree).

Elements are found by their visible names, not by guessing pixels, and
actions use the element's own controls (invoke, set value, toggle) so the
user's mouse is left alone whenever possible. Compii's own windows are
never searched or touched.
"""

from __future__ import annotations

import functools
import re
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
VALUE_CHARS = 200
TEXT_CHARS = 600
SELECTION_CHARS = 3000
HANDLES_SECONDS = 90.0

# UI Automation pattern ids: the fixed numbers Windows assigns to each thing a control can do.
# GetPattern(id) works on every element, unlike the library's GetInvokePattern()-style helpers,
# which only exist on some control classes.
PATTERN_CLICK = 10000  # Invoke
PATTERN_TYPE = 10002  # Value: what a field holds, and setting it
PATTERN_OPEN = 10005  # ExpandCollapse
PATTERN_PICK = 10010  # SelectionItem
PATTERN_TOGGLE = 10015  # Toggle
PATTERN_TEXT = 10014  # Text: the words inside a document or edit area

_TOGGLE = {0: "off", 1: "on", 2: "mixed"}
_EXPAND = {0: "closed", 1: "open", 2: "partly open"}

# Which patterns are worth asking about, per role: keeps reading a screen to 1-2 calls an item.
_BY_ROLE: dict[str, tuple[int, ...]] = {
    "Button": (PATTERN_CLICK,),
    "Hyperlink": (PATTERN_CLICK,),
    "MenuItem": (PATTERN_CLICK, PATTERN_OPEN),
    "Group": (PATTERN_CLICK,),
    "TabItem": (PATTERN_CLICK, PATTERN_PICK),
    "ListItem": (PATTERN_PICK,),
    "TreeItem": (PATTERN_PICK, PATTERN_OPEN),
    "CheckBox": (PATTERN_TOGGLE, PATTERN_CLICK),
    "RadioButton": (PATTERN_PICK, PATTERN_TOGGLE),
    "ComboBox": (PATTERN_TYPE, PATTERN_OPEN),
    "Edit": (PATTERN_TYPE,),
    "Document": (PATTERN_TYPE,),
    "Slider": (PATTERN_TYPE,),
    "Spinner": (PATTERN_TYPE,),
    "Custom": (PATTERN_CLICK, PATTERN_TYPE),
}
_VERB = {PATTERN_CLICK: "click", PATTERN_TYPE: "type", PATTERN_OPEN: "open",
         PATTERN_PICK: "pick", PATTERN_TOGGLE: "toggle"}

# Elements remembered from the last screen read: id -> (when, what it is, the live control).
# Only touched on the compii-uia thread, so no lock is needed.
_handles: dict[str, tuple[float, "Found", Any]] = {}


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
    src: str = "control"  # "control": read from the app's own element; "picture": seen in a screenshot
    value: str = ""  # exactly what it holds, or its state, right now
    can: tuple[str, ...] = ()  # what Compii can do to it without guessing pixels

    def as_event(self) -> dict[str, object]:
        return {
            "name": self.name,
            "role": self.role,
            "window": self.window,
            "x": self.left,
            "y": self.top,
            "w": self.right - self.left,
            "h": self.bottom - self.top,
            "src": self.src,
            "value": self.value,
            "can": list(self.can),
        }

    @property
    def centre(self) -> tuple[int, int]:
        return (self.left + self.right) // 2, (self.top + self.bottom) // 2


def how_found(found: Found) -> str:
    """The honest line about where an item came from, for Compii to say out loud."""
    if found.src == "ocr":
        return "read from a picture of the window with local OCR, so Compii aimed at the text"
    if found.src == "picture":
        return "spotted in a picture of the screen, so Compii aimed by position"
    if found.value == "hidden":
        return "read from the app's own controls; it's a password field, so what's in it stays unread"
    if found.value:
        return f"read from the app's own controls (exact): it holds “{found.value}”"
    return "read from the app's own controls (exact), not from a picture"


# All screen reading runs on ONE long-lived thread. UI Automation is COM: setting it up
# and tearing it down on a new thread per call, while sharing one automation object,
# can crash Python outright (Core vanished with exit code 139).
_uia_jobs: Any = None
_uia_lock = threading.Lock()
# ...but one thread is also one queue: a hung app can block a call for as long as it likes and
# every read behind it waits on the same stuck thread. So a call gets this long, then Compii says
# so and moves the queue on. The abandoned thread stays where it is; it never takes new work.
UIA_TIMEOUT = 20.0
UIA_RESTARTS = 3
_uia_stalls = 0
_uia_stuck = ""


def _uia_worker(jobs: Any) -> None:
    import ctypes

    ctypes.windll.ole32.CoInitializeEx(None, 0x2)  # apartment-threaded, kept for the thread's life
    while True:
        fn, args, kw, done = jobs.get()
        try:
            done.set_result(fn(*args, **kw))
        except BaseException as e:  # noqa: BLE001 - handed back to the caller
            done.set_exception(e)


def _start_uia_worker() -> Any:
    """A fresh queue and the thread that works it. Only ever called with `_uia_lock` held."""
    import queue

    jobs: Any = queue.SimpleQueue()
    threading.Thread(target=_uia_worker, args=(jobs,), name="compii-uia", daemon=True).start()
    return jobs


def _on_uia_thread(fn: Callable) -> Callable:
    @functools.wraps(fn)
    def run(*args: Any, **kw: Any) -> Any:
        global _uia_jobs, _uia_stalls, _uia_stuck
        if sys.platform != "win32" or threading.current_thread().name == "compii-uia":
            return fn(*args, **kw)
        from concurrent.futures import Future
        from concurrent.futures import TimeoutError as WaitTimeout

        if _uia_stuck:
            raise ScreenError(_uia_stuck)
        with _uia_lock:
            if _uia_jobs is None:
                _uia_jobs = _start_uia_worker()
        done: Future = Future()
        _uia_jobs.put((fn, args, kw, done))
        try:
            out = done.result(UIA_TIMEOUT)
        except WaitTimeout:
            with _uia_lock:
                _uia_stalls += 1
                if _uia_stalls <= UIA_RESTARTS:
                    _uia_jobs = _start_uia_worker()
                else:
                    _uia_stuck = (f"Compii has given up reading the screen: {UIA_RESTARTS} apps in a row "
                                  "stopped answering it. Restart Compii Core to look again.")
            raise ScreenError(
                f"Nothing answered from the screen in {int(UIA_TIMEOUT)}s, so the app is probably hung. "
                "Compii stopped waiting — anything it had just asked that app to do may or may not have "
                "happened, so check before doing it again."
            ) from None
        with _uia_lock:
            _uia_stalls = 0
        return out

    return run


_REFUSE = object()  # sentinel: this read answers that it isn't allowed rather than a blank


def _sighted(kind: str, then: Any = _REFUSE) -> Callable:
    """The one gate on Compii's eyes: it looks only while the user allows it, and the app is told
    each time it starts and stops, so the "Compii is seeing your screen" light is never a guess.

    Passive reads answer with `then` (None, "" or []) when sight is off, because their callers
    already handle "nothing to read". Actions and window reading raise instead, so Compii can say
    why it stopped rather than quietly doing nothing.
    """

    def wrap(fn: Callable) -> Callable:
        @functools.wraps(fn)
        def inner(*args: Any, **kw: Any) -> Any:
            from . import sight

            if not sight.enabled():
                if then is _REFUSE:
                    raise ScreenError(sight.refusal())
                return list(then) if isinstance(then, list) else then
            with sight.look(kind):
                return fn(*args, **kw)

        return inner

    return wrap


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


# Icons from private-use fonts, replacement boxes and control codes: apps hand these over as
# "labels", and they turn into junk when written to a log or shown to a model.
_GLYPHS = re.compile(r"[\ue000-\uf8ff\ufffd\x00-\x08\x0b\x0c\x0e-\x1f]")


def _clean(text: str) -> str:
    """One readable line: what the app calls this thing, with the icon glyphs taken out."""
    return " ".join(_GLYPHS.sub(" ", text or "").split())


def _clean_block(text: str) -> str:
    """Text from a document or field, keeping its lines."""
    return _GLYPHS.sub("", (text or "").replace("\r\n", "\n").replace("\r", "\n")).strip()


def _score(name: str, target: str) -> int:
    n = name.strip().lower()
    if not n:
        return 0
    if n == target:
        return 3
    if n.startswith(target):
        return 2
    return 1 if target in n else 0


def _role_of(control) -> str:
    return (control.ControlTypeName or "").replace("Control", "")


def _read_state(control, role: str) -> tuple[str, list[str]]:
    """(what it holds, what Compii can do to it), asked of the element itself.

    Never guesses: an app that doesn't offer a control pattern simply reports nothing.
    Password fields give up no value.
    """
    if getattr(control, "IsPassword", False):
        return "hidden", []
    value, actions = "", []
    for pid in _BY_ROLE.get(role, (PATTERN_CLICK,)):
        try:
            pattern = control.GetPattern(pid)
        except Exception:  # noqa: BLE001 - some elements refuse every question
            continue
        if pattern is None:
            continue
        try:
            if pid == PATTERN_TYPE:
                if not pattern.IsReadOnly:
                    value = _clean(pattern.Value)[:VALUE_CHARS]
                    actions.append("type")
            elif pid == PATTERN_TOGGLE:
                value = value or _TOGGLE.get(int(pattern.ToggleState), "")
                actions.append("toggle")
            elif pid == PATTERN_OPEN:
                state = _EXPAND.get(int(pattern.ExpandCollapseState), "")
                value = value or state
                actions.append("close" if state == "open" else "open")
            elif pid == PATTERN_PICK:
                if pattern.IsSelected:
                    value = (value + " selected").strip()
                actions.append("pick")
            else:
                actions.append("click")
        except Exception:  # noqa: BLE001 - the element changed while we asked
            continue
    return value, actions


def _document_text(control, limit: int = TEXT_CHARS) -> str:
    """The words inside a document or edit area, read exactly from it ("" if it has none)."""
    try:
        pattern = control.GetPattern(PATTERN_TEXT)
    except Exception:  # noqa: BLE001
        return ""
    if pattern is None:
        return ""
    try:
        return _clean_block(pattern.DocumentRange.GetText(limit))[:limit]
    except Exception:  # noqa: BLE001
        return ""


def clear_handles() -> None:
    """Forget the elements of the last screen read (a new read, or the user stops sharing)."""
    _handles.clear()


def _remember(item_id: str, found: Found, control) -> None:
    _handles[item_id] = (time.monotonic(), found, control)


def _retained(target: str, window: str | None):
    """(Found, control) for an id from the last screen read, if that very element is still there.

    Acting on the remembered element is the most accurate thing Compii can do: no name search,
    no pixels — it is the same control the user was just shown. Called only from `_search`,
    which always runs on the compii-uia thread where the controls were made.
    """
    held = _handles.get(target.strip())
    if held is None or time.monotonic() - held[0] > HANDLES_SECONDS:
        return None, None
    _at, found, control = held
    if window and window.strip().lower() not in found.window.lower():
        return None, None
    try:
        alive = not control.IsOffscreen and control.Exists(0, 0)
    except Exception:  # noqa: BLE001 - the app destroyed it
        alive = False
    if not alive:
        _handles.pop(target.strip(), None)
        return None, None
    return found, control


def _user_windows(auto, window: str | None = None) -> list:
    """Top-level windows in stacking order, minus Compii's own and hidden ones.

    With `window`, only windows whose title contains it. Windows can close
    while we look at them; those are skipped.
    """
    want = window.strip().lower() if window else None
    out = []
    for w in auto.GetRootControl().GetChildren():
        try:
            name = _clean(w.Name)
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


def _walk(auto, wanted: str, window: str | None, by_value: bool):
    """(key, Found, control) for the best match in the user's top windows, or None.

    Matching names is fast, so it's the first pass; matching the words a control currently
    holds costs an extra question per element, so Compii only walks again for it when the
    labels found nothing (fields and cells often keep their text in the value, not the name).
    """
    best = None
    deadline = time.monotonic() + SEARCH_SECONDS * (0.75 if by_value else 1)
    for win, title in _user_windows(auto, window):
        seen = 0
        try:
            for control, _depth in auto.WalkControl(win, includeTop=True, maxDepth=25):
                seen += 1
                if seen > MAX_ELEMENTS or time.monotonic() > deadline:
                    break
                try:
                    if control.IsOffscreen:
                        continue
                    name = _clean(control.Name)
                    score = _score(name, wanted)
                    value, actions, role = "", [], _role_of(control)
                    if not by_value and not score:
                        continue
                    value, actions = _read_state(control, role)
                    if not score:
                        # Never match on a password field's placeholder, whatever the user asked for.
                        score = 0 if value == "hidden" else max(0, _score(value, wanted) - 1)
                    if not score:
                        continue
                    r = control.BoundingRectangle
                    if r.width() <= 0 or r.height() <= 0:
                        continue
                    found = Found(name or value, role, title, r.left, r.top, r.right, r.bottom,
                                  value=value, can=tuple(actions))
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
    return best


def _search(auto, target: str, window: str | None = None):
    """(Found, control) for the best match, or (None, None).

    An id like "e12" from the last screen read resolves to that exact element.
    """
    if re.fullmatch(r"e\d+", target.strip()):
        found, control = _retained(target, window)
        if found is not None:
            return found, control
    wanted = target.strip().lower()
    best = _walk(auto, wanted, window, by_value=False) or _walk(auto, wanted, window, by_value=True)
    return (best[1], best[2]) if best else (None, None)


@_sighted("screen", then=None)
@_on_uia_thread
def find_element(target: str, window: str | None = None) -> Found | None:
    """Best match for `target` among the visible elements of the user's top windows."""
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        return _search(auto, target, window)[0]


# ---- operating apps ----------------------------------------------------------------


@_sighted("windows")
@_on_uia_thread
def list_windows() -> list[dict[str, Any]]:
    _need_windows()
    import uiautomation as auto

    out = []
    with auto.UIAutomationInitializerInThread():
        for w in auto.GetRootControl().GetChildren():
            try:
                name = _clean(w.Name)
                if name and "compii" not in name.lower() and not w.IsOffscreen:
                    out.append({"title": name, "app": w.ClassName})
            except Exception:  # noqa: BLE001
                continue
    return out[:40]


@_sighted("app")
@_on_uia_thread
def focus_window(window: str) -> str:
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        return _to_front(auto, window)


def _to_front(auto, window: str) -> str:
    """Bring a window forward, and only return once Windows agrees it is the one in front.

    Windows can refuse to hand over the focus. Typing anyway would put the words in whichever
    app stayed in front, so Compii stops and says so instead.
    """
    wins = _user_windows(auto, window)
    if not wins:
        raise ScreenError(f"No open window has “{window}” in its title.")
    win, title = wins[0]
    try:
        win.SetActive()
    except Exception as e:  # noqa: BLE001
        raise ScreenError(f"Couldn't switch to “{title}”: {e}") from e
    want = window.strip().lower()
    for _ in range(8):
        time.sleep(0.1)
        if want in user_foreground()[1].lower():
            return title
    raise ScreenError(f"“{title}” wouldn't come to the front, so nothing was typed there. "
                      "Click its window once, then ask again.")


@_sighted("window")
@_on_uia_thread
def read_window(window: str | None = None) -> str:
    """The visible text, values and controls of a window, one per line, for the agent to read.

    Everything here is taken from the app's own elements: labels, what fields hold, and what
    Compii can do to each item. Nothing is guessed from where things look like they are.
    """
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        wins = _user_windows(auto, window)
        if not wins:
            raise ScreenError(f"No open window has “{window}” in its title." if window else "No windows are open.")
        win, title = wins[0]
        lines = [f"Window: {title} (read from the app's own controls — exact)"]
        seen: set[str] = set()
        deadline = time.monotonic() + SEARCH_SECONDS
        for control, depth in auto.WalkControl(win, includeTop=False, maxDepth=25):
            if len(lines) >= MAX_READ_LINES or time.monotonic() > deadline:
                lines.append("… (more not shown)")
                break
            try:
                if control.IsOffscreen:
                    continue
                role = _role_of(control)
                name = _clean(control.Name)
                value, actions = _read_state(control, role)
                pad = f"{'  ' * min(depth, 6)}"
                if value == "hidden":
                    lines.append(f"{pad}{role}: a password field — Compii doesn't read it")
                    continue
                block = ""
                if role in ("Document", "Edit", "Text", "Pane") and (len(value) > 80 or not name or not value):
                    block = _document_text(control)  # keep the lines: a paragraph isn't one long sentence
                shown = block or value
                if not name and not shown:
                    continue  # nothing to say about this one
                area = f"{pad}{role}: {name}" + (f" [can {', '.join(actions)}]" if actions else "")
                if "\n" in shown:
                    lines.append(area + ":")
                    lines.extend(f"{pad}  {ln}" for ln in shown.splitlines()[:60])
                    continue
                line = area + (f" = {shown[:300]}" if shown and shown != name else "")
                if line not in seen:
                    seen.add(line)
                    lines.append(line)
            except Exception:  # noqa: BLE001
                continue
        return "\n".join(lines)


@_sighted("app")
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
    """Activate a button, menu, link, tab or checkbox by its visible name or snapshot id."""

    def press(auto, control) -> None:
        for pid, verb in ((PATTERN_CLICK, "Invoke"), (PATTERN_TOGGLE, "Toggle"),
                          (PATTERN_PICK, "Select"), (PATTERN_OPEN, "Expand")):
            try:
                pattern = control.GetPattern(pid)
            except Exception:  # noqa: BLE001
                pattern = None
            if pattern:
                getattr(pattern, verb)()
                return
        control.Click(simulateMove=False)  # last resort: a real click at its own centre

    return _act(target, window, before, press)


@_sighted("app")
@_on_uia_thread
def type_text(text: str, target: str | None = None, window: str | None = None,
              before: Callable[[Found], None] | None = None) -> Found | None:
    """Put text into a field (by its label or snapshot id), or type it where the cursor is."""
    if target:
        def fill(auto, control) -> None:
            if getattr(control, "IsPassword", False):
                raise ScreenError("That's a password field. Compii never types there.")
            try:
                pattern = control.GetPattern(PATTERN_TYPE)
            except Exception:  # noqa: BLE001
                pattern = None
            if pattern is not None and not pattern.IsReadOnly:
                pattern.SetValue(text)
            else:
                control.SetFocus()
                if not control.HasKeyboardFocus:
                    raise ScreenError(f"Couldn't get the caret into “{getattr(control, 'Name', '')}”, "
                                      "so nothing was typed. Click in that field, then ask again.")
                auto.SendKeys(_literal(text), waitTime=0.02)

        return _act(target, window, before, fill)
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        if window:
            _to_front(auto, window)
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


@_sighted("app")
@_on_uia_thread
def press_keys(combo: str, window: str | None = None) -> str:
    _need_windows()
    import uiautomation as auto

    keys = keys_to_sendkeys(combo)
    with auto.UIAutomationInitializerInThread():
        title = ""
        if window:
            title = _to_front(auto, window)
        auto.SendKeys(keys, waitTime=0.05)
    return title


def _literal(text: str) -> str:
    """Escape text so SendKeys types it exactly (braces are its key syntax)."""
    return "".join("{" + ch + "}" if ch in "{}" else ch for ch in text)


# ---- checking an action did what Compii claimed ------------------------------------------


def _read_back(auto, target: str, window: str | None = None) -> Found | None:
    """Re-read the item from its control, so an action's result is a fact and not a hope.

    Called only from read_back, which runs on the compii-uia thread where the controls live.
    """
    found, control = _search(auto, target, window)
    if found is None:
        return None
    try:
        role = _role_of(control)
        value, actions = _read_state(control, role)
        if not value and role in ("Document", "Edit"):
            value = _document_text(control)
        name = _clean(control.Name)
        r = control.BoundingRectangle
    except Exception:  # noqa: BLE001 - the element vanished while we asked it
        return found
    return Found(name or found.name, role, found.window, r.left, r.top, r.right, r.bottom,
                 src=found.src, value=value, can=tuple(actions))


@_sighted("app")
@_on_uia_thread
def read_back(target: str, window: str | None = None) -> Found | None:
    """The item again, read from the app's control right now, after Compii used it.

    None means the app no longer shows that item - which is news of its own: the screen changed.
    """
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        return _read_back(auto, target, window)


def focus_found() -> Found | None:
    """Where the caret is right now, as an item to compare before and after a keystroke."""
    item = focused_item()
    if not item:
        return None
    return Found(item.get("name", ""), item.get("role", ""), item.get("window", ""), 0, 0, 0, 0,
                 value="" if item.get("password") else item.get("value", ""),
                 can=tuple(item.get("can") or ()))


def what_changed(before: Found | None, after: Found | None, *, typed: str = "",
                 window_before: str = "", window_after: str = "") -> str:
    """One honest clause about what the app's own controls show after an action; "" when
    there's nothing to compare.

    Compii only claims a click or a keystroke worked when the app says so; when the app keeps
    its own counsel, that's what this reports, instead of a confident "done".
    """
    if window_before and window_after and window_before.lower() != window_after.lower():
        return f"the window in front is now “{window_after}”"
    if before is None and after is None:
        return ""
    if before is None:
        return f"the caret is now in “{after.name or after.role}”"
    if after is None:
        return f"“{before.name}” is no longer in the window, so the screen changed"
    if after.src in ("picture", "ocr"):
        return "it was aimed at by position from a picture, so Compii can't read the result back"
    if typed:
        want = " ".join(typed.split()).lower()
        if after.value == "hidden":
            return "it's a password field, so Compii never reads what's in it"
        if want and want in after.value.lower():
            return f"it now holds “{after.value[:80]}”"
        return "the app doesn't show that text in its controls, so Compii can't confirm it landed"
    if after.value and after.value != before.value:
        return f"it now shows “{after.value[:60]}”"
    if set(after.can) != set(before.can):
        return f"it now offers {', '.join(after.can) or 'nothing'}"
    return "the app's controls show no change, so Compii can't confirm it did anything"


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


@_sighted("screen", then=None)
@_on_uia_thread
def snapshot_foreground() -> dict[str, Any] | None:
    """The window the user is looking at, as a compact list of items with ids (e1, e2…),
    roles, labels and positions, plus the item under the mouse. None if there's nothing
    but Compii's own windows. Password fields and password-manager apps are skipped."""
    _need_windows()
    import uiautomation as auto

    hwnd, wanted = user_foreground()
    if not hwnd:
        return None
    with auto.UIAutomationInitializerInThread():
        try:
            win = auto.ControlFromHandle(hwnd)
            win = (win.GetTopLevelControl() if win else None) or auto.GetForegroundControl()
            win = win.GetTopLevelControl() or win
            title = (win.Name or wanted).strip()
        except Exception:  # noqa: BLE001
            return None
        if not title:
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
                under = _clean(c.Name)
        except Exception:  # noqa: BLE001
            pass
        seen: set[tuple] = set()
        _handles.clear()  # ids belong to this read only
        deadline = time.monotonic() + SNAPSHOT_SECONDS
        for control, _depth in auto.WalkControl(win, includeTop=False, maxDepth=25):
            if len(snap["elements"]) >= SNAPSHOT_ITEMS or time.monotonic() > deadline:
                snap["truncated"] = True
                break
            try:
                if control.IsOffscreen:
                    continue
                role = _role_of(control)
                password = bool(getattr(control, "IsPassword", False))
                name = _clean(control.Name)
                value, actions = _read_state(control, role) if not password else ("hidden", [])
                if not name and not actions and not value:
                    continue  # nothing to say about it, and nothing Compii could do with it
                r = control.BoundingRectangle
                if r.width() <= 2 or r.height() <= 2:
                    continue
                key = (role, name[:60], r.left // 8, r.top // 8)
                if key in seen:
                    continue
                seen.add(key)
                item: dict[str, Any] = {"id": f"e{len(snap['elements']) + 1}", "role": role,
                                        "name": (name or "(no label)")[:120],
                                        "x": r.left, "y": r.top, "w": r.width(), "h": r.height()}
                if password:
                    item["value"] = "a password field — not read"
                elif value and value != name:
                    item["value"] = value[:120]
                if actions:
                    item["can"] = actions
                if not name:
                    try:
                        hint = _clean(control.HelpText)
                        if hint:
                            item["hint"] = hint[:80]
                    except Exception:  # noqa: BLE001
                        pass
                snap["elements"].append(item)
                _remember(item["id"], Found(item["name"], role, title, r.left, r.top, r.right, r.bottom,
                                            value=item.get("value", ""), can=tuple(actions)), control)
            except Exception:  # noqa: BLE001 - the window changed while we read it
                continue
        snap["under_cursor"] = under
        return snap


def describe_snapshot(snap: dict[str, Any]) -> str:
    """The snapshot as compact text for the AI (one line per item)."""
    if snap.get("blocked"):
        return f"The user is in “{snap['title']}”, a password manager or similar; Compii doesn't read it."
    # A context can be made of the selection alone when the window itself gave nothing away.
    cx, cy = (snap.get("cursor") or [0, 0])[:2]
    lines = [f"Window: “{snap.get('title') or 'the app the user is in'}” ({snap.get('app', '')}). "
             f"Mouse at {cx},{cy}"
             + (f", over “{snap['under_cursor']}”." if snap.get("under_cursor") else ".")]
    picked = snap.get("selection") or {}
    if str(picked.get("text") or "").strip():
        words = picked.get("words") or len(str(picked["text"]).split())
        body = str(picked["text"])[:2000] + ("…" if len(str(picked["text"])) > 2000 else "")
        lines.append(f"The user has {words} {'word' if words == 1 else 'words'} selected in "
                     f"“{picked.get('window') or snap.get('title') or 'the app the user is in'}”. "
                     f"When they say “this”, they mean these exact "
                     f"words — work on them, and quote from them rather than describing them:\n{body}")
    if snap.get("seen"):
        lines.append("What the window shows (from a picture of it): " + snap["seen"]
                     + " Items with ids v1, v2… were found in that picture; point at them by id.")
    if any(e.get("src") == "ocr" for e in snap.get("elements", [])):
        lines.append("Items with ids t1, t2… are lines of text read from a picture of the window with local OCR. "
                     "They are accurate to a few pixels; point at them by id.")
    elif snap.get("ocr_text"):
        lines.append("Words read from a picture of the window (local OCR; may contain small mistakes):")
        lines.append(snap["ocr_text"][:2500] + ("…" if len(snap["ocr_text"]) > 2500 else ""))
    if snap.get("focus"):
        by_id = {e["id"]: e for e in snap["elements"]}
        shown = [f"{i} · {by_id[i]['role']} · {by_id[i]['name']}" for i in snap["focus"] if i in by_id]
        if shown:
            lines.append("While talking, the user circled or moved the mouse over (most likely first; "
                         "\"this\"/\"here\" means these): " + "; ".join(shown))
    items = snap.get("elements") or []
    exact = [e for e in items if e.get("src") not in ("picture", "ocr")]
    if exact:
        lines.append(f"{len(exact)} item(s) below are read from the app's own controls: labels and values are "
                     "exact, and 'can' is what Compii can really do to them. Use the id (e12) to act on one.")
    if items:  # a context can be only the selected words, and then there are no items to list
        lines.append("Items (id · type · label [= what it holds] [can …]):")
    for e in items:
        line = f"{e['id']} · {e['role']} · {e['name']}"
        if e.get("value"):
            line += f" = {e['value']}"
        if e.get("hint"):
            line += f" (asks for: {e['hint']})"
        if e.get("can"):
            line += f" [can {', '.join(e['can'])}]"
        if e.get("src") == "picture":
            line += " [from the picture, not the control]"
        elif e.get("src") == "ocr":
            line += " [read from a picture of the window]"
        lines.append(line)
    if snap.get("truncated"):
        lines.append("… more items not listed.")
    return "\n".join(lines)


# ---- dictation, clicks and demonstrations ----------------------------------------------


def mouse_down() -> bool:
    """Is the left mouse button held right now?"""
    import ctypes

    return bool(ctypes.windll.user32.GetAsyncKeyState(0x01) & 0x8000)


@_sighted("screen", then=None)
@_on_uia_thread
def item_at(x: int, y: int) -> dict[str, Any] | None:
    """The item under a screen point: exact label, type, what it holds, what Compii could do to it."""
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        try:
            c = auto.ControlFromPoint(x, y)
            if c is None:
                return None
            top = c.GetTopLevelControl()
            role = _role_of(c)
            name = _clean(c.Name)
            r = c.BoundingRectangle
            value, actions = _read_state(c, role)
            out = {"name": name[:80], "role": role, "src": "control",
                   "window": _clean(top.Name) if top else "", "password": bool(getattr(c, "IsPassword", False)),
                   "x": r.left, "y": r.top, "w": r.width(), "h": r.height(), "can": actions}
            if value:
                out["value"] = value[:120]
            return out
        except Exception:  # noqa: BLE001
            return None


@_sighted("screen", then=None)
@_on_uia_thread
def focused_item() -> dict[str, Any] | None:
    """What the user's caret is in right now, read from the control itself."""
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        try:
            c = auto.GetFocusedControl()
            if c is None:
                return None
            top = c.GetTopLevelControl()
            role = _role_of(c)
            value, actions = _read_state(c, role)
            out = {"name": _clean(c.Name)[:80], "role": role, "src": "control",
                   "window": _clean(top.Name) if top else "", "password": bool(getattr(c, "IsPassword", False)),
                   "can": actions}
            if value:
                out["value"] = value[:120]
            return out
        except Exception:  # noqa: BLE001
            return None


@_sighted("screen", then=None)
@_on_uia_thread
def selection(limit: int = SELECTION_CHARS) -> dict[str, Any] | None:
    """What the user has highlighted right now, lifted from the app's own text control.

    Nothing is copied, no keystroke is sent and the clipboard is left alone: UIA is simply
    asked what its selection holds, which is a read. A password field, a password manager, or
    an app that keeps its selection to itself answers None.
    """
    _need_windows()
    import uiautomation as auto

    with auto.UIAutomationInitializerInThread():
        try:
            control = auto.GetFocusedControl()
            if control is None:
                return None
            top = control.GetTopLevelControl()
            title = _clean(top.Name) if top else ""
            try:
                app = _process_name(control.ProcessId) or (control.ClassName or "").lower()
            except Exception:  # noqa: BLE001 - the window went away while we asked
                app = ""
            if getattr(control, "IsPassword", False) or any(b in app or b in title.lower() for b in BLOCKED_APPS):
                return None
            pattern = control.GetPattern(PATTERN_TEXT)
            if pattern is None:
                return None
            parts = []
            for found in pattern.GetSelection():
                text = _clean_block(found.GetText(limit))
                if text and text not in parts:
                    parts.append(text)
        except Exception:  # noqa: BLE001 - the app changed its mind about having a selection
            return None
    text = "\n\n".join(parts)[:limit].strip()
    if not text:
        return None
    return {"text": text, "words": len(text.split()), "chars": len(text), "window": title, "app": app}


@_sighted("screen", then="")
def foreground_title() -> str:
    import ctypes

    user32 = ctypes.windll.user32
    h = user32.GetForegroundWindow()
    n = user32.GetWindowTextLengthW(h)
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(h, buf, n + 1)
    return buf.value


def _window_visible_now(user32, hwnd: int) -> bool:
    """True for a window the user can actually see on this desktop right now.

    Minimized windows keep their old place in the z-order (and report a -32000 rect), and
    windows on another virtual desktop or a suspended UWP app stay "visible" to Windows while
    being invisible to the person. Either one used to become "the window in front", so Compii
    read or photographed the wrong app.
    """
    import ctypes
    from ctypes import wintypes

    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.restype = wintypes.BOOL
    user32.IsIconic.argtypes = [wintypes.HWND]
    user32.IsIconic.restype = wintypes.BOOL
    user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    user32.GetWindowRect.restype = wintypes.BOOL
    user32.GetSystemMetrics.argtypes = [ctypes.c_int]
    user32.GetSystemMetrics.restype = ctypes.c_int
    if not user32.IsWindowVisible(hwnd) or user32.IsIconic(hwnd):
        return False
    try:
        dwm = ctypes.windll.dwmapi
        dwm.DwmGetWindowAttribute.argtypes = [wintypes.HWND, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
        cloaked = wintypes.DWORD()
        if dwm.DwmGetWindowAttribute(hwnd, 14, ctypes.byref(cloaked), ctypes.sizeof(cloaked)) == 0 and cloaked.value:
            return False  # another virtual desktop, or a suspended app: not on this screen
    except (AttributeError, OSError):
        pass
    rect = wintypes.RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return False
    w, h = rect.right - rect.left, rect.bottom - rect.top
    if rect.left <= -30000 or rect.top <= -30000 or w < 80 or h < 60:
        return False
    vl, vt = user32.GetSystemMetrics(76), user32.GetSystemMetrics(77)
    vw, vh = user32.GetSystemMetrics(78), user32.GetSystemMetrics(79)
    return rect.right > vl and rect.bottom > vt and rect.left < vl + vw and rect.top < vt + vh


def _top_windows(limit: int = 30) -> list[tuple[int, str]]:
    """Windows the user can see right now, front to back, with their titles.

    Cheap: no UI Automation. Minimized, cloaked and off-screen windows are left out.
    """
    if sys.platform != "win32":
        return []
    import ctypes
    from ctypes import wintypes

    user32 = ctypes.windll.user32
    GW_HWNDNEXT, GWL_EXSTYLE, WS_EX_TOOLWINDOW = 2, -20, 0x80
    user32.GetWindow.restype = wintypes.HWND
    user32.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
    user32.GetTopWindow.restype = wintypes.HWND
    user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.GetWindowLongW.restype = ctypes.c_long
    user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
    user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    out: list[tuple[int, str]] = []
    h = user32.GetTopWindow(None)
    for _ in range(500):
        if not h:
            break
        title = ""
        n = user32.GetWindowTextLengthW(h)
        if n:
            buf = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(h, buf, n + 1)
            title = buf.value.strip()
        if (title and title not in ("Program Manager", "Windows Input Experience", "Default IME", "MSCTFIME UI")
                and not user32.GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW
                and _window_visible_now(user32, h)):
            out.append((int(h), title[:120]))
            if len(out) >= limit:
                break
        h = user32.GetWindow(h, GW_HWNDNEXT)
    return out


def find_window(title: str) -> tuple[int, str]:
    """The visible window whose title contains `title`, front-most first, or (0, "")."""
    want = title.strip().lower()
    if not want:
        return 0, ""
    for hwnd, shown in _top_windows(60):
        if want in shown.lower():
            return hwnd, shown
    return 0, ""


@_sighted("screen", then=(0, ""))
def user_foreground() -> tuple[int, str]:
    """The window the user is actually looking at: the front-most one that isn't Compii's own.

    The buddy overlay sits on top of every monitor, so Windows' foreground is nearly always
    ours; anything that reads the screen has to look past it. (0, "") when nothing else is there.
    """
    for hwnd, title in _top_windows():
        if "compii" not in title.lower():
            return hwnd, title
    return 0, ""


def private_window(hwnd: int, title: str = "") -> bool:
    """A password manager or similar: never captured, never read, never named."""
    if sys.platform != "win32":
        return False
    import ctypes

    pid = ctypes.c_ulong()
    ctypes.windll.user32.GetWindowThreadProcessId(ctypes.c_void_p(hwnd), ctypes.byref(pid))
    return any(b in f"{_process_name(pid.value)} {title}".lower() for b in BLOCKED_APPS)


@_sighted("screen", then=[])
def window_titles(limit: int = 15) -> list[str]:
    """Titles of the visible top-level windows, front to back, Compii's own left out."""
    out: list[str] = []
    for _hwnd, title in _top_windows(limit * 2):
        if "compii" in title.lower() or title in out:
            continue
        out.append(title)
        if len(out) >= limit:
            break
    return out


def desktop_now() -> str:
    """One short paragraph of what's open, for every message. Password managers stay unnamed."""
    titles = window_titles()
    if not titles:
        return ""

    def shown(t: str) -> str:
        return "a password manager" if any(b in t.lower() for b in BLOCKED_APPS) else f"“{t}”"

    lines = [f"In front: {shown(titles[0])}"]
    if len(titles) > 1:
        lines.append("Also open: " + "; ".join(shown(t) for t in titles[1:]))
    return "\n".join(lines)


@_sighted("app")
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
