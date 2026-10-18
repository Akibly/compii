"""Wake-word tests with real speech (Compii's own voice model) fed in place of
the microphone, in real time. Skipped unless the free models are downloaded."""

import threading
import time
from pathlib import Path

import numpy as np
import pytest

from compii_core.voice import RATE, Voice
from compii_core.wake import match_wake

MODELS = Path.home() / "Compii" / "models"
needs_models = pytest.mark.skipif(
    not (MODELS / "faster-whisper-base.en" / "model.bin").exists() or not (MODELS / "voices-v1.0.bin").exists(),
    reason="free voice models not downloaded",
)


def test_matching_accepts_the_name_and_rejects_lookalikes():
    assert match_wake("Hey Compii, open notepad") == (True, "open notepad")
    assert match_wake("Compie what time is it")[0]
    for text in ["Hey everyone", "hey come here", "Hey, copy that", "The company called", "Hey computer"]:
        assert not match_wake(text)[0], text


class ScriptedMic:
    """Plays a list of audio clips (with gaps) into Compii in real time."""

    def __init__(self, clips: list[np.ndarray]) -> None:
        self.clips = clips
        self.on = False

    def start(self, on_audio) -> None:
        self.on = True

        def run() -> None:
            rng = np.random.default_rng(0)
            for clip in self.clips:
                for i in range(0, len(clip), RATE // 10):
                    if not self.on:
                        return
                    block = clip[i:i + RATE // 10]
                    if block.size < RATE // 10:
                        block = np.pad(block, (0, RATE // 10 - block.size))
                    on_audio((block + rng.normal(0, 0.002, block.size)).astype(np.float32))
                    time.sleep(0.1)

        threading.Thread(target=run, daemon=True).start()

    def stop(self) -> None:
        self.on = False


class Silent:
    speaking = False

    def say(self, text: str) -> None:
        self.said = text

    def stop(self) -> None:
        pass


def _speech(voice: Voice, text: str) -> np.ndarray:
    a, sr = voice._kokoro().create(text, voice="am_michael", lang="en-us")
    x = np.interp(np.arange(0, len(a), sr / RATE), np.arange(len(a)), a).astype(np.float32)
    return x * 0.3  # about the level of a laptop microphone


def _gap(seconds: float) -> np.ndarray:
    return np.zeros(int(RATE * seconds), np.float32)


def _run(clips_from, seconds: float, until=None):
    """Play the clips, then wait up to `seconds` (or until `until(commands, events)` is true)."""
    events: list[dict] = []
    commands: list[str] = []
    builder = Voice(MODELS, events.append, speaker=Silent())
    clips = clips_from(builder)
    voice = Voice(MODELS, events.append, recorder_factory=lambda: ScriptedMic(clips), speaker=Silent())
    voice._stt = builder._whisper()
    voice.on_command = commands.append
    voice.set_wake(True)
    played = sum(len(c) for c in clips) / RATE
    deadline = time.monotonic() + max(seconds, played + 15)
    time.sleep(played)
    while time.monotonic() < deadline and not (until and until(commands, events)):
        time.sleep(0.2)
    voice.set_wake(False)
    return commands, events, voice._wake.checks


@needs_models
def test_wake_phrase_with_request_in_one_breath():
    commands, events, _ = _run(lambda v: [_gap(1), _speech(v, "Hey Compy, tidy my downloads folder."), _gap(2)], 9,
                               until=lambda c, e: bool(c))
    assert len(commands) == 1 and "downloads" in commands[0].lower()
    assert not any(e["type"] == "voice_wake" for e in events), "no 'Yes?' needed when the request came with it"


@needs_models
def test_wake_phrase_then_pause_then_request():
    commands, events, _ = _run(
        lambda v: [_gap(1), _speech(v, "Hey Compy."), _gap(1.5), _speech(v, "What's on my calendar today?"), _gap(2.5)], 14,
        until=lambda c, e: bool(c))
    assert any(e["type"] == "voice_wake" for e in events)
    assert len(commands) == 1 and "calendar" in commands[0].lower()


@needs_models
def test_other_speech_and_noise_do_nothing():
    commands, events, checks = _run(lambda v: [_gap(1), _speech(v, "Hey everyone, dinner is ready."), _gap(3)], 8)
    assert commands == [] and not any(e["type"] == "voice_wake" for e in events)
    _, _, idle_checks = _run(lambda v: [_gap(4)], 5)
    assert idle_checks == 0, "background noise alone never runs speech recognition"
