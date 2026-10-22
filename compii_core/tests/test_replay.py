"""Watch me: the recording keeps actions for replay, and replay repeats only what happened."""

from __future__ import annotations

import json
import time

from compii_core.replay import Replayer
from compii_core.skills import Skills, skill_tools
from compii_core.tools import ToolError, ToolResult
from compii_core.watch import Watcher

ACTIONS = [
    {"kind": "switch", "window": "Inbox - Outlook"},
    {"kind": "click", "target": "New mail", "window": "Inbox - Outlook"},
    {"kind": "type", "field": "Subject", "window": "Untitled - Message"},
    {"kind": "keys", "keys": "ctrl+enter", "window": "Untitled - Message"},
]


class FakeTools:
    def __init__(self, fail: dict[str, str] | None = None) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.fail = fail or {}

    def focus_window(self, a):
        self._maybe_fail("switch")
        self.calls.append(("switch", a))
        return ToolResult(f"Switched to “{a['window']}”.")

    def click_on(self, a):
        self._maybe_fail("click")
        self.calls.append(("click", a))
        return ToolResult(f"Clicked button “{a['target']}” in “{a.get('window', '')}”.")

    def press_keys(self, a):
        self._maybe_fail("keys")
        self.calls.append(("keys", a))
        return ToolResult(f"Pressed {a['keys']}.")

    def type_into(self, a):
        self._maybe_fail("type")
        self.calls.append(("type", a))
        return ToolResult(f"Typed {len(a['text'])} characters into “{a['target']}”.")

    def _maybe_fail(self, kind: str) -> None:
        if kind in self.fail:
            raise ToolError(self.fail[kind])


# ---- recording ----------------------------------------------------------------


def test_recording_keeps_actions_but_never_the_text_that_was_typed():
    state = {"down": set(), "window": "Report - Word", "cursor": (110, 60)}
    w = Watcher(lambda x, y: {"name": "Insert", "role": "TabItem", "window": "Report - Word"},
                lambda: state["cursor"], lambda: state["window"], lambda vk: vk in state["down"],
                lambda: {"name": "Subject", "role": "Edit", "window": "Report - Word",
                         "password": False, "value": "my private draft"})
    w.start()

    def act(keys, wait=0.12):
        state["down"] = set(keys)
        time.sleep(wait)
        state["down"] = set()
        time.sleep(wait)

    act({0x01})
    act({0x48})
    act({0xA2, ord("S")})
    state["window"] = "Outlook"
    time.sleep(0.15)
    steps = w.stop()

    assert [a["kind"] for a in w.recorded()] == ["click", "type", "keys", "switch"]
    assert w.recorded()[0] == {"kind": "click", "target": "Insert", "role": "TabItem", "window": "Report - Word"}
    assert w.recorded()[2]["keys"] == "ctrl+s"
    assert "my private draft" not in json.dumps(w.recorded()), "what was typed is never recorded"
    assert len(w.recorded()) == len(steps), "actions and steps stay index-aligned"


# ---- replay -------------------------------------------------------------------


def test_replay_does_the_recorded_actions_in_order():
    fake = FakeTools()
    got = Replayer(fake).run(ACTIONS, values=["Scholarship"])
    assert [c[0] for c in fake.calls] == ["switch", "click", "type", "keys"]
    assert fake.calls[2][1]["text"] == "Scholarship"
    assert got["done"] == 4 and got["stopped"] is None and got["needs"] is None
    assert len(got["lines"]) == 4 and got["lines"][-1].startswith("4.")


def test_several_typing_steps_take_values_in_order():
    fake = FakeTools()
    actions = [{"kind": "type", "field": "To", "window": "Mail"},
               {"kind": "type", "field": "Subject", "window": "Mail"}]
    Replayer(fake).run(actions, values=["sam@example.com", "Friday"])
    assert [c[1]["text"] for c in fake.calls] == ["sam@example.com", "Friday"]


def test_a_missing_value_stops_before_typing_and_names_the_field():
    fake = FakeTools()
    got = Replayer(fake).run(ACTIONS, values=[])
    assert [c[0] for c in fake.calls] == ["switch", "click"]
    assert got["needs"] == {"step": 3, "field": "Subject"} and got["stopped"] is None


def test_a_step_that_no_longer_works_stops_the_replay_there():
    fake = FakeTools(fail={"click": "Couldn't find anything named “New mail”."})
    got = Replayer(fake).run(ACTIONS, values=["x"])
    assert "Stopped at step 2" in got["stopped"]
    assert [c[0] for c in fake.calls] == ["switch"], "later steps are not attempted"


def test_resuming_from_a_step_skips_the_earlier_ones():
    fake = FakeTools()
    Replayer(fake).run(ACTIONS, values=["Scholarship"], start_at=3)
    assert [c[0] for c in fake.calls] == ["type", "keys"]


# ---- skills -------------------------------------------------------------------


def test_a_recorded_skill_replays_and_written_recipes_are_not_guessed(tmp_path):
    skills = Skills(tmp_path / "skills.json")
    skills.add("New mail", "Start a new email", ["Click New mail"], actions=ACTIONS)
    skills.add("Write letter", "Write a letter", ["Open Word", "Write it"])
    tools = {t.name: t for t in skill_tools(skills, FakeTools())}

    assert "Replayed all 4 step(s)" in tools["replay_skill"].run({"name": "New mail", "values": ["x"]}).text
    text = tools["replay_skill"].run({"name": "Write letter"}).text
    assert "written recipe, not a recording" in text and "Open Word" in text


def test_replay_is_only_offered_when_there_is_a_screen_to_act_on(tmp_path):
    skills = Skills(tmp_path / "skills.json")
    assert "replay_skill" not in {t.name for t in skill_tools(skills)}


def test_the_recording_is_saved_with_the_skill_and_survives_a_reload(tmp_path):
    path = tmp_path / "skills.json"
    Skills(path).add("New mail", "Start a new email", ["Click New mail"], actions=ACTIONS)
    assert Skills(path).named("New mail").actions == ACTIONS


def test_older_skill_files_without_actions_still_load(tmp_path):
    path = tmp_path / "skills.json"
    path.write_text(json.dumps([{"name": "Old", "instruction": "x", "steps": ["a"], "id": "s1"}]))
    assert Skills(path).items["s1"].actions == []
