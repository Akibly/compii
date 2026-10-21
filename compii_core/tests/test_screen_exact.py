"""Reading a screen exactly: what each control holds, what can be done to it, and where the
information came from (the app's own element, or a picture of it)."""

from __future__ import annotations

import time
import types

from compii_core import screen
from compii_core.screen import (PATTERN_CLICK, PATTERN_OPEN, PATTERN_PICK, PATTERN_TEXT, PATTERN_TOGGLE,
                                PATTERN_TYPE, Found, describe_snapshot, how_found, what_changed)


class Rect:
    def __init__(self, left, top, right, bottom):
        self.left, self.top, self.right, self.bottom = left, top, right, bottom

    def width(self):
        return self.right - self.left

    def height(self):
        return self.bottom - self.top


class Pattern:
    """A stand-in for one UI Automation control pattern."""

    def __init__(self, value=None, read_only=False, toggle=None, expand=None, selected=None, text=None):
        self.Value, self.IsReadOnly, self.ToggleState = value, read_only, toggle
        self.ExpandCollapseState, self.IsSelected = expand, selected
        if text is not None:
            self.DocumentRange = types.SimpleNamespace(GetText=lambda limit=-1: text)

    def SetValue(self, text):  # noqa: N802 - UIA spelling
        self.Value = text

    def Invoke(self):  # noqa: N802
        self.invoked = True


class Control:
    def __init__(self, name="", role="Button", rect=(0, 0, 100, 30), patterns=None, password=False,
                 help_text="", offscreen=False):
        self.Name, self.ControlTypeName = name, role + "Control"
        self.BoundingRectangle = Rect(*rect)
        self.IsPassword, self.HelpText, self.IsOffscreen = password, help_text, offscreen
        self._patterns = patterns or {}
        self.exists = True

    def GetPattern(self, pid):  # noqa: N802 - UIA spelling
        return self._patterns.get(pid)

    def Exists(self, max_seconds=0, interval=0):  # noqa: N802
        return self.exists


def read_state(role, patterns=None, password=False):
    control = Control(role=role, patterns=patterns or {}, password=password)
    return screen._read_state(control, role)


def test_button_reports_only_that_it_can_be_clicked():
    assert read_state("Button", {PATTERN_CLICK: Pattern()}) == ("", ["click"])


def test_field_reports_exactly_what_it_holds():
    value, actions = read_state("Edit", {PATTERN_TYPE: Pattern(value="Jane Okafor")})
    assert (value, actions) == ("Jane Okafor", ["type"])


def test_read_only_field_offers_nothing():
    assert read_state("Edit", {PATTERN_TYPE: Pattern(value="Total: 4", read_only=True)}) == ("", [])


def test_checkbox_and_menu_report_their_state():
    assert read_state("CheckBox", {PATTERN_TOGGLE: Pattern(toggle=1)}) == ("on", ["toggle"])
    value, actions = read_state("MenuItem", {PATTERN_CLICK: Pattern(), PATTERN_OPEN: Pattern(expand=1)})
    assert value == "open" and actions == ["click", "close"]  # it's open, so what's left is closing it


def test_a_selected_row_says_so():
    assert read_state("ListItem", {PATTERN_PICK: Pattern(selected=True)}) == ("selected", ["pick"])


def test_password_field_gives_up_nothing():
    assert read_state("Edit", password=True) == ("hidden", [])
    assert read_state("Edit", {PATTERN_TYPE: Pattern(value="hunter2")}, password=True) == ("hidden", [])


def test_document_text_is_read_from_the_text_pattern():
    c = Control(role="Document", patterns={PATTERN_TEXT: Pattern(text="Quarterly results\nRevenue up 12%")})
    assert screen._document_text(c).startswith("Quarterly results")
    assert screen._document_text(Control(role="Text")) == ""


# ---- searching a window ---------------------------------------------------------------


def fake_auto(windows):
    """A stand-in for the uiautomation module: `windows` is [(title, [controls])]."""
    table = dict(windows)
    root = types.SimpleNamespace(GetChildren=lambda: [
        Control(name=title, rect=(0, 0, 1200, 800)) for title in table])
    return types.SimpleNamespace(
        GetRootControl=lambda: root,
        WalkControl=lambda win, includeTop=False, maxDepth=25: iter([(c, 1) for c in table[win.Name]]),
    )


def test_search_matches_a_label_and_reports_what_it_can_do():
    save = Control(name="Save", patterns={PATTERN_CLICK: Pattern()})
    found, control = screen._search(fake_auto([("Note", [save])]), "Save")
    assert (found.name, found.role, found.src) == ("Save", "Button", "control")
    assert found.can == ("click",) and control is save


def test_icon_glyphs_are_taken_out_of_what_apps_report():
    assert screen._clean(" Save   now\nagain") == "Save now again"
    assert screen._clean(" ") == ""  # a window titled with a space isn't a window worth reading
    assert screen._clean_block("line one\r\nline two ") == "line one\nline two"


def test_a_label_wrapped_in_icon_glyphs_still_matches_what_the_user_says():
    save = Control(name="Save", patterns={PATTERN_CLICK: Pattern()})
    found, _ = screen._search(fake_auto([("Note", [save])]), "Save")
    assert found is not None and found.name == "Save"


def test_search_falls_back_to_the_words_a_field_holds():
    field = Control(name="field", role="Edit", patterns={PATTERN_TYPE: Pattern(value="Horizon Scholarship")})
    apply_ = Control(name="Apply", patterns={PATTERN_CLICK: Pattern()})
    found, _ = screen._search(fake_auto([("Form", [apply_, field])]), "Horizon")
    assert found.value == "Horizon Scholarship"


def test_search_prefers_a_real_label_over_held_words():
    holder = Control(name="Apply", patterns={PATTERN_CLICK: Pattern()})
    other = Control(name="Apply later", role="Edit", patterns={PATTERN_TYPE: Pattern(value="Apply")})
    found, _ = screen._search(fake_auto([("Form", [other, holder])]), "Apply")
    assert found.name == "Apply" and found.role == "Button"


def test_a_remembered_id_is_that_exact_element(monkeypatch):
    cell = Control(name="Insert", role="TabItem", rect=(200, 40, 260, 64))
    monkeypatch.setitem(screen._handles, "e7",
                        (time.monotonic(), Found("Insert", "TabItem", "Word", 200, 40, 260, 64), cell))
    never_walked = types.SimpleNamespace(
        GetRootControl=lambda: (_ for _ in ()).throw(AssertionError("walked the whole screen")), WalkControl=None)
    found, control = screen._search(never_walked, "e7")
    assert control is cell and found.name == "Insert"


def test_a_dead_or_forgotten_id_is_dropped(monkeypatch):
    dead = Control(name="Insert", role="TabItem")
    dead.exists = False
    monkeypatch.setitem(screen._handles, "e8",
                        (time.monotonic(), Found("Insert", "TabItem", "Word", 0, 0, 50, 20), dead))
    assert screen._retained("e8", None) == (None, None)
    assert "e8" not in screen._handles
    old = Control(name="Old", role="Button")
    monkeypatch.setitem(screen._handles, "e9", (time.monotonic() - screen.HANDLES_SECONDS - 1, Found(
        "Old", "Button", "Word", 0, 0, 50, 20), old))
    assert screen._retained("e9", None) == (None, None)


def test_an_id_from_another_window_is_not_used(monkeypatch):
    c = Control(name="Save", rect=(0, 0, 40, 20))
    monkeypatch.setitem(screen._handles, "e10", (time.monotonic(), Found("Save", "Button", "Note", 0, 0, 40, 20), c))
    assert screen._retained("e10", "Word") == (None, None)


# ---- what the AI is shown --------------------------------------------------------------


def test_snapshot_lines_show_values_and_what_is_possible():
    snap = {"title": "Form", "app": "chrome.exe", "cursor": [10, 10],
            "elements": [
                {"id": "e1", "role": "Edit", "name": "Full name", "value": "Jane Okafor",
                 "can": ["type"], "x": 0, "y": 0, "w": 200, "h": 30},
                {"id": "e2", "role": "Button", "name": "Submit", "can": ["click"], "x": 0, "y": 40, "w": 80, "h": 30},
                {"id": "v1", "role": "Seen", "src": "picture", "name": "a graph", "x": 0, "y": 80, "w": 60, "h": 40},
            ]}
    text = describe_snapshot(snap)
    assert "e1 · Edit · Full name = Jane Okafor [can type]" in text
    assert "e2 · Button · Submit [can click]" in text
    assert "2 item(s) below are read from the app's own controls" in text
    assert "v1 · Seen · a graph [from the picture, not the control]" in text


def test_unlabelled_field_is_still_shown_with_what_it_asks_for():
    snap = {"title": "Form", "cursor": [0, 0], "elements": [
        {"id": "e1", "role": "Edit", "name": "(no label)", "hint": "City", "can": ["type"],
         "x": 0, "y": 0, "w": 100, "h": 24}]}
    text = describe_snapshot(snap)
    assert "(no label)" in text and "asks for: City" in text and "[can type]" in text


def test_compii_says_how_it_found_a_thing():
    assert "own controls (exact)" in how_found(Found("Save", "Button", "Note", 0, 0, 20, 20))
    assert "it holds “42”" in how_found(Found("Age", "Edit", "Form", 0, 0, 20, 20, value="42"))
    assert "password field" in how_found(Found("", "Edit", "Form", 0, 0, 20, 20, value="hidden"))
    assert "by position" in how_found(Found("a graph", "Seen", "Form", 0, 0, 20, 20, src="picture"))


def test_a_point_carries_the_source_along():
    event = Found("Save", "Button", "Note", 10, 20, 60, 44, value="draft", can=("click",)).as_event()
    assert event == {"name": "Save", "role": "Button", "window": "Note", "x": 10, "y": 20, "w": 50, "h": 24,
                     "src": "control", "value": "draft", "can": ["click"]}
    assert Found("Save", "Button", "Note", 10, 20, 60, 44).centre == (35, 32)


# ---- checking what an action really did -------------------------------------------------


def test_read_back_uses_the_live_control_not_the_old_snapshot(monkeypatch):
    box = Control(name="Volume", role="Slider", patterns={PATTERN_TYPE: Pattern(value="30%")})
    monkeypatch.setitem(screen._handles, "e3", (time.monotonic(),
                        Found("Volume", "Slider", "Player", 0, 0, 60, 20, value="10%"), box))
    assert screen._read_back(fake_auto([]), "e3", None).value == "30%"


def test_read_back_of_a_document_reads_the_words_inside_it(monkeypatch):
    doc = Control(name="Text editor", role="Document", patterns={PATTERN_TEXT: Pattern(text="Dear Sir\nRegards")})
    monkeypatch.setitem(screen._handles, "e4", (time.monotonic(),
                        Found("Text editor", "Document", "Notepad", 0, 0, 60, 20), doc))
    assert "Dear Sir" in screen._read_back(fake_auto([]), "e4", None).value


def test_read_back_of_a_gone_item_is_none():
    assert screen._read_back(fake_auto([("Note", [])]), "Save") is None


def test_a_state_the_app_shows_is_what_gets_claimed():
    before = Found("Sync", "Button", "Word", 0, 0, 10, 10, can=("click",))
    on = Found("Sync", "Button", "Word", 0, 0, 10, 10, value="on", can=("click",))
    assert what_changed(before, on) == "it now shows “on”"
    assert "can't confirm it did anything" in what_changed(before, before)
    assert "no longer in the window" in what_changed(before, None)
    assert what_changed(before, before, window_after="Print") == \
        "the app's controls show no change, so Compii can't confirm it did anything"
    assert "the window in front is now “Print”" == what_changed(
        before, before, window_before="Word", window_after="Print")
    assert what_changed(None, None) == ""
    assert "the caret is now in “Sync”" == what_changed(None, on)


def test_text_is_only_claimed_when_the_field_shows_it():
    field = Found("Subject", "Edit", "Mail", 0, 0, 10, 10, can=("type",))
    filled = Found("Subject", "Edit", "Mail", 0, 0, 10, 10, value="Dear Sir or Madam", can=("type",))
    assert "it now holds “Dear Sir or Madam”" in what_changed(field, filled, typed="dear  sir or madam")
    assert "can't confirm it landed" in what_changed(field, filled, typed="Dear Madam only")
    hidden = Found("Code", "Edit", "Mail", 0, 0, 10, 10, value="hidden")
    assert "never reads what's in it" in what_changed(field, hidden, typed="123456")
