"""Compii's eyes: one switch for every read, and a light that only says what really happened."""

from __future__ import annotations

import time
from typing import Any, Callable

import pytest

from compii_core import sight
from compii_core.screen import ScreenError, _sighted


@pytest.fixture(autouse=True)
def _eyes_open():
    """Every test starts and ends with the switch where the user left it."""
    was = sight.enabled()
    sight.set_enabled(True)
    yield
    sight.set_enabled(was)


def _watch() -> tuple[list[dict[str, Any]], Callable[[], None]]:
    events: list[dict[str, Any]] = []
    return events, sight.on_change(events.append)


def test_a_look_lights_the_indicator_and_then_goes_out(monkeypatch):
    monkeypatch.setattr(sight, "SETTLE_SECONDS", 0.05)
    events, stop = _watch()
    try:
        with sight.look("window"):
            assert events == [{"type": "voice_sight", "screen_aware": True, "looking": True, "kind": "window"}]
        time.sleep(0.3)
    finally:
        stop()
    assert events[-1] == {"type": "voice_sight", "screen_aware": True, "looking": False}


def test_looks_one_after_another_do_not_flicker(monkeypatch):
    """Watching a step means reading several times a second; the light stays on through that."""
    monkeypatch.setattr(sight, "SETTLE_SECONDS", 0.2)
    events, stop = _watch()
    try:
        for _ in range(4):
            with sight.look("screen"):
                pass
            time.sleep(0.05)
    finally:
        stop()
    assert len([e for e in events if e["looking"]]) == 1, events


def test_the_switch_refuses_a_read_instead_of_answering_blank():
    @_sighted("screen")
    def read() -> str:
        return "the window in front"

    events, stop = _watch()
    try:
        assert read() == "the window in front"
        sight.set_enabled(False)
        with pytest.raises(ScreenError) as e:
            read()
        assert "turned off" in str(e.value)
        assert not any(ev["looking"] for ev in events[1:]), events
    finally:
        stop()


def test_a_read_that_promised_a_plain_answer_still_answers_it():
    @_sighted("screen", then=[])
    def titles() -> list[str]:
        return ["Word"]

    sight.set_enabled(False)
    assert titles() == []
    sight.set_enabled(True)
    assert titles() == ["Word"]


def test_turning_the_eyes_off_quiets_the_light_at_once(monkeypatch):
    monkeypatch.setattr(sight, "SETTLE_SECONDS", 5)
    events, stop = _watch()
    try:
        with sight.look("window"):
            sight.set_enabled(False)
            assert events[-1] == {"type": "voice_sight", "screen_aware": False, "looking": False}
            assert not sight.enabled()
    finally:
        sight.set_enabled(True)
        stop()
    assert not any(e["looking"] for e in events[2:]), events


def test_a_watcher_can_stop_listening():
    events, stop = _watch()
    sight.set_enabled(False)
    stop()
    sight.set_enabled(True)
    assert [e["screen_aware"] for e in events] == [False]  # only the change made while it listened


def test_status_counts_looks_so_the_app_can_say_how_much_it_saw():
    before = sight.status()["reads"]
    with sight.look("window"):
        pass
    assert sight.status()["reads"] == before + 1
    assert sight.status()["last_seen"]
    assert sight.status()["screen_aware"] is True
