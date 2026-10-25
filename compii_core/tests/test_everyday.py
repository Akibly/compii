"""The everyday tools: forgetting on request, reading back what ran, the time
anywhere, and the weather — all checked offline."""

from __future__ import annotations

import datetime as dt

import pytest

from compii_core.audit import AuditLog
from compii_core.bots import TOOL_PACKS, tools_for
from compii_core.everyday import everyday_tools
from compii_core.guard import UNTRUSTED_TOOLS
from compii_core.policy import ActionKind
from compii_core.tools import Toolbox, ToolError

NOON_UTC = dt.datetime(2026, 10, 26, 12, 0, tzinfo=dt.timezone.utc)


def _tools(tmp_path, audit=None, fetch=None):
    box = Toolbox([], tmp_path / "ws")
    tools = {t.name: t for t in everyday_tools(box, audit, fetch=fetch, now=lambda: NOON_UTC)}
    box.tools.update(tools)
    return box, tools


def test_forget_removes_only_the_facts_that_match_and_says_which(tmp_path):
    box, tools = _tools(tmp_path)
    for fact in ("Sister Awa's birthday is 3 May", "Prefers tea", "Sister lives in Dakar"):
        box.remember({"fact": fact})
    out = tools["forget_memory"].run({"about": "sister birthday"}).text
    assert "Sister Awa's birthday" in out
    left = [m["fact"] for m in box.memories()]
    assert left == ["Prefers tea", "Sister lives in Dakar"]
    assert tools["forget_memory"].kind_for({}) is ActionKind.DELETE  # asks first like any deletion


def test_forget_refuses_a_sweep_rather_than_wiping_everything(tmp_path):
    box, tools = _tools(tmp_path)
    for i in range(12):
        box.remember({"fact": f"Project note {i}"})
    with pytest.raises(ToolError, match="more specific"):
        tools["forget_memory"].run({"about": "project"})
    assert len(box.memories()) == 12
    assert "nothing to forget" in tools["forget_memory"].run({"about": "zebra"}).text


def test_activity_log_reads_back_what_ran_in_plain_words(tmp_path):
    audit = AuditLog(tmp_path / "audit.jsonl")
    box, tools = _tools(tmp_path, audit=audit)
    audit.record("done", task="t1", tool="world_time", kind="read", args={"places": ["Tokyo"]})
    audit.record("failed", task="t1", tool="weather", args={"place": "Atlantis"}, error="no such place")
    audit.record("delegated", task="t1", job="j1", bot="b1", objective="Audit the login code")
    out = tools["activity_log"].run({"hours": 1}).text
    assert "did: Check the time in Tokyo" in out
    assert "tried and failed: Check the weather in Atlantis (no such place)" in out
    assert "handed a job to a teammate: Audit the login code" in out
    assert "chain checks out" in out


def test_activity_log_says_when_nothing_happened(tmp_path):
    _, tools = _tools(tmp_path, audit=AuditLog(tmp_path / "audit.jsonl"))
    assert "Nothing was recorded" in tools["activity_log"].run({}).text


def test_world_time_knows_cities_and_converts_a_time(tmp_path):
    _, tools = _tools(tmp_path)
    now = tools["world_time"].run({"places": ["Tokyo", "London", "Europe/Paris"]}).text
    assert "Tokyo: Mon 26 Oct, 21:00 (UTC+09:00)" in now
    assert "London: Mon 26 Oct, 12:00 (UTC+00:00)" in now  # BST ended the day before
    converted = tools["world_time"].run({"places": ["New York"], "at": "15:00", "from_place": "London"}).text
    assert "New York: Mon 26 Oct, 11:00 (UTC-04:00)" in converted
    with pytest.raises(ToolError, match="time zone"):
        tools["world_time"].run({"places": ["Nowhereville"]})


def test_weather_reads_the_forecast_and_sends_only_the_place(tmp_path):
    sent = []

    def fetch(url, params):
        sent.append((url, params))
        if "geocoding" in url:
            return {"results": [{"name": "Banjul", "country": "Gambia", "latitude": 13.45, "longitude": -16.58,
                                 "timezone": "Africa/Banjul"}]}
        return {"current": {"temperature_2m": 31, "apparent_temperature": 35, "weather_code": 2,
                            "wind_speed_10m": 12},
                "daily": {"time": ["2026-10-26", "2026-10-27"], "temperature_2m_min": [24, 25],
                          "temperature_2m_max": [32, 33], "precipitation_probability_max": [10, 60],
                          "weather_code": [1, 63]}}

    _, tools = _tools(tmp_path, fetch=fetch)
    out = tools["weather"].run({"place": "Banjul", "days": 2}).text
    assert "Banjul, Gambia, now: 31°C (feels 35°C), partly cloudy" in out
    assert "Tue 27 Oct: 25–33°C, rain, 60% chance of rain" in out
    assert sent[0][1] == {"name": "Banjul", "count": 1}


def test_weather_says_plainly_when_offline_or_unknown(tmp_path):
    _, offline = _tools(tmp_path, fetch=None)
    with pytest.raises(ToolError, match="internet"):
        offline["weather"].run({"place": "Paris"})
    _, nowhere = _tools(tmp_path, fetch=lambda url, params: {"results": []})
    with pytest.raises(ToolError, match="couldn't find"):
        nowhere["weather"].run({"place": "Atlantis"})


def test_new_tools_are_granted_by_lane_not_to_everyone(tmp_path):
    # A teammate gets them only through the lane that covers them.
    assert {"forget_memory", "activity_log"} <= tools_for(["knowledge"])
    assert "weather" in tools_for(["web"]) and "weather" not in tools_for(["files"])
    assert "forget_memory" not in tools_for(["web", "files", "code"])
    named = {n for p in TOOL_PACKS.values() for n in p["tools"]}
    assert {t.name for t in everyday_tools(Toolbox([], tmp_path / "ws"))} <= named
    # Outside text is marked as such for the injection guard.
    assert {"weather", "activity_log"} <= UNTRUSTED_TOOLS
