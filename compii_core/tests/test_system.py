"""The PC's own state: read honestly, change only small reversible things, and read them back."""

from __future__ import annotations

import sys

import pytest

from compii_core import system
from compii_core.system import system_tools
from compii_core.tools import ToolError

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="these controls are Windows'")

TOOLS = {t.name: t for t in system_tools()}

STATUS = {
    "os": "Microsoft Windows 11 Home Single Language", "version": "10.0.26300",
    "uptime_min": 805, "ram_free_mb": 5724, "ram_total_mb": 24359,
    "battery": {"percent": 100, "on_ac": True},
    "disks": [{"drive": "C:", "free_gb": 356.9, "total_gb": 931.4}],
    "networks": [{"name": "Gokul AP", "adapter": "Wi-Fi", "internet": "Internet"}],
    "ipv4": ["172.16.99.172"], "brightness": 70,
}


class FakeVolume:
    def __init__(self, level: float = 0.5, muted: bool = False) -> None:
        self.level = level
        self.muted = muted

    def GetMasterVolumeLevelScalar(self) -> float:
        return self.level

    def SetMasterVolumeLevelScalar(self, value: float, _ctx) -> None:
        self.level = value

    def GetMute(self) -> bool:
        return self.muted

    def SetMute(self, muted: bool, _ctx) -> None:
        self.muted = muted


def _volume(monkeypatch, fake: FakeVolume) -> FakeVolume:
    monkeypatch.setattr(system, "_volume", lambda: fake)
    return fake


def _stub(monkeypatch, answer):
    seen: list[dict] = []
    monkeypatch.setattr(system, "_run", lambda script, args=None: seen.append(args or {}) or answer)
    return seen


def test_status_says_battery_disks_network_and_volume_in_plain_words(monkeypatch):
    _stub(monkeypatch, STATUS)
    _volume(monkeypatch, FakeVolume(0.42))
    text = TOOLS["system_status"].run({}).text
    assert "Battery 100% (on mains)" in text
    assert "Screen brightness 70%" in text
    assert "Volume 42%" in text
    assert "C: 356.9 GB free of 931.4 GB" in text
    assert "Gokul AP on Wi-Fi (Internet)" in text
    assert "172.16.99.172" in text
    assert "Up 13h 25m" in text


def test_status_still_reports_the_machine_when_there_is_no_speaker_control(monkeypatch):
    _stub(monkeypatch, STATUS)
    monkeypatch.setattr(system, "_volume", lambda: (_ for _ in ()).throw(ToolError("no audio")))
    text = TOOLS["system_status"].run({}).text
    assert "no speaker volume control was available" in text
    assert "C: 356.9 GB free" in text


def test_setting_the_volume_reads_the_speakers_back(monkeypatch):
    fake = _volume(monkeypatch, FakeVolume(0.10))
    text = TOOLS["set_volume"].run({"level": 30}).text
    assert round(fake.level * 100) == 30
    assert "Volume is now 30%." in text


def test_asking_for_a_level_while_muted_makes_it_audible(monkeypatch):
    fake = _volume(monkeypatch, FakeVolume(0.10, muted=True))
    TOOLS["set_volume"].run({"level": 45})
    assert round(fake.level * 100) == 45 and not fake.muted


def test_mute_and_unmute_keep_the_level(monkeypatch):
    fake = _volume(monkeypatch, FakeVolume(0.60))
    assert "muted" in TOOLS["set_volume"].run({"mute": True}).text
    assert fake.muted and round(fake.level * 100) == 60
    assert "and muted" not in TOOLS["set_volume"].run({"mute": False}).text
    assert not fake.muted and round(fake.level * 100) == 60


def test_volume_without_a_level_or_mute_is_refused(monkeypatch):
    _volume(monkeypatch, FakeVolume())
    with pytest.raises(ToolError, match="Give a level"):
        TOOLS["set_volume"].run({})


def test_brightness_is_clamped_and_the_real_value_is_reported(monkeypatch):
    calls = _stub(monkeypatch, {"brightness": 30})
    text = TOOLS["set_brightness"].run({"level": 140}).text
    assert calls[0]["level"] == 100, "out-of-range levels are clamped before Windows sees them"
    assert "now 30%" in text and "Asked for 140%" in text


def test_an_external_screen_is_said_to_be_undimable_not_pretended(monkeypatch):
    _stub(monkeypatch, {"error": "no_brightness"})
    with pytest.raises(ToolError, match="can't be dimmed"):
        TOOLS["set_brightness"].run({"level": 20})


def test_media_keys_never_claim_the_playing_app_listened(monkeypatch):
    _stub(monkeypatch, {"pressed": "next"})
    text = TOOLS["media_control"].run({"action": "next"}).text
    assert "next track" in text and "isn't visible from here" in text


def test_only_real_media_actions_are_offered(monkeypatch):
    _stub(monkeypatch, {"pressed": "rewind"})
    with pytest.raises(ToolError, match="Unknown media action"):
        TOOLS["media_control"].run({"action": "rewind"})


def test_the_scripts_never_contain_a_leftover_placeholder():
    for script in (system._STATUS, system._BRIGHTNESS, system._MEDIA):
        assert "{env}" not in script and "$env:COMPII_SYSTEM_ARGS" in script
        assert "ConvertFrom-Json" in script, "arguments are read from the environment, not stitched in"
    for script in (system._BRIGHTNESS, system._MEDIA):
        assert "$a." in script
