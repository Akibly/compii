"""More shortcuts: Ctrl+Alt+W/R/H, Ctrl+Win dictation, gestures, watch me, click-to-advance."""

import threading
import time

from compii_core import hotkey
from compii_core.buddy import focus_from_trail, tidy_dictation
from compii_core.hotkey import VK_CONTROL, VK_WIN, HoldToTalk
from compii_core.screen import Found
from compii_core.walkthrough import Walkthroughs
from compii_core.watch import Watcher

from test_core import home, opened, toolbox  # noqa: F401 - fixtures

CTRL, ALT, WIN = 0xA2, 0xA4, 0x5B


def test_ctrl_alt_letters_run_commands_without_listening(monkeypatch):
    monkeypatch.setattr(hotkey, "HOLD_TO_START", 0.05)
    seen = []
    h = HoldToTalk(lambda: seen.append("start"), lambda held: seen.append("end"), lambda: seen.append("cancel"),
                   on_command=seen.append)
    for letter in "WRH":
        h.key(CTRL, True)
        h.key(ALT, True)
        h.key(ord(letter), True)
        h.key(ord(letter), False)
        h.key(ALT, False)
        h.key(CTRL, False)
    time.sleep(0.1)
    assert seen == ["W", "R", "H"]
    h.key(CTRL, True)
    h.key(ALT, True)
    h.key(ord("T"), True)  # not a Compii command: plain cancel, nothing runs
    h.key(ALT, False)
    h.key(CTRL, False)
    assert seen == ["W", "R", "H"]


def test_ctrl_win_is_a_separate_hold(monkeypatch):
    monkeypatch.setattr(hotkey, "HOLD_TO_START", 0.05)
    seen = []
    d = HoldToTalk(lambda: seen.append("dictate"), lambda held: seen.append("type"), first=VK_CONTROL, second=VK_WIN)
    d.key(CTRL, True)
    d.key(ALT, True)  # Ctrl+Alt is not this shortcut
    time.sleep(0.1)
    d.key(ALT, False)
    assert seen == []
    d.key(WIN, True)
    time.sleep(0.12)
    d.key(WIN, False)
    d.key(CTRL, False)
    assert seen == ["dictate", "type"]


def test_dictation_is_tidied():
    assert tidy_dictation("  please send the report to sam tomorrow ") == "Please send the report to sam tomorrow."
    assert tidy_dictation("ok") == "Ok"


SNAP = {"title": "Report - Word", "elements": [
    {"id": "e1", "role": "TabItem", "name": "Insert", "x": 100, "y": 50, "w": 60, "h": 24},
    {"id": "e2", "role": "Button", "name": "Table", "x": 300, "y": 90, "w": 40, "h": 40},
    {"id": "e3", "role": "Pane", "name": "Document", "x": 0, "y": 0, "w": 1000, "h": 800}]}


def test_circling_an_item_makes_it_the_focus():
    circle = [(320 + int(40 * __import__("math").cos(a / 10)), 110 + int(40 * __import__("math").sin(a / 10))) for a in range(0, 64)]
    assert focus_from_trail(SNAP, circle)[0] == "e2"
    wave = [(110 + i, 60) for i in range(0, 45, 3)]
    assert focus_from_trail(SNAP, wave)[0] == "e1"
    assert focus_from_trail(SNAP, [(500, 500)] * 10) == []  # no gesture


def test_watch_me_records_clicks_shortcuts_and_windows_not_typing():
    state = {"down": set(), "window": "Report - Word", "cursor": (110, 60)}
    w = Watcher(lambda x, y: {"name": "Insert", "role": "TabItem", "window": "Report - Word"},
                lambda: state["cursor"], lambda: state["window"], lambda vk: vk in state["down"],
                lambda: {"name": "Subject", "role": "Edit", "password": False})
    w.start()

    def act(keys, wait=0.12):
        state["down"] = set(keys)
        time.sleep(wait)
        state["down"] = set()
        time.sleep(wait)

    act({0x01})  # click
    act({0x48})  # typing "h"
    act({0x49})  # typing "i": still the same field, one step
    act({0xA2, ord("S")})  # Ctrl+S
    state["window"] = "Outlook"
    time.sleep(0.15)
    steps = w.stop()
    assert steps == ["Click tabitem “Insert” in “Report - Word”", "Type the text into “Subject”", "Press Ctrl+S",
                     "Switch to the “Outlook” window"]


def test_walkthrough_moves_on_when_you_click_the_item(toolbox, tmp_path):
    class Screen:
        clicks = False

        def mouse_down(self):
            return self.clicks

        def cursor_position(self):
            return (120, 60)

        def list_windows(self):
            return [{"title": "Word"}]

    screen = Screen()
    toolbox.screen = screen
    toolbox._find = lambda label: Found(label, "TabItemControl", "Word", 100, 50, 160, 74)  # never disappears
    walks = Walkthroughs(toolbox, tmp_path / "w.json", step_seconds=5, poll=0.02)
    threading.Timer(0.2, lambda: setattr(screen, "clicks", True)).start()
    out = walks.run({"goal": "x", "steps": [{"instruction": "Click Insert.", "target": "Insert"}]})
    assert "all 1 steps done" in out.text
