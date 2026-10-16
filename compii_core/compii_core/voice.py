"""Free, local voice: push-to-talk speech recognition and spoken replies.

Nothing here costs money or sends audio anywhere:
- Listening uses faster-whisper (OpenAI's open Whisper model, run locally).
- Speaking uses Kokoro (an open 82M-parameter voice model) when its files are
  downloaded, and otherwise the voice built into Windows.
Models download only when the user asks for them in Settings.
"""

from __future__ import annotations

import queue
import sys
import threading
import time
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

RATE = 16_000
PARTIAL_EVERY = 0.7  # seconds between live transcript updates
MAX_SECONDS = 120

WHISPER_MODEL = "base.en"
KOKORO_FILES = {
    "kokoro-v1.0.int8.onnx": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx",
    "voices-v1.0.bin": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
}
DOWNLOAD_SIZES_MB = {"listen": 145, "speak": 120}
KOKORO_VOICES = {
    "af_heart": "Heart (warm, US)",
    "af_bella": "Bella (bright, US)",
    "am_michael": "Michael (calm, US)",
    "bf_emma": "Emma (British)",
    "bm_george": "George (British)",
}

Emit = Callable[[dict[str, Any]], None]


@dataclass
class VoiceSettings:
    speak_replies: bool = True
    voice: str = "af_heart"
    speed: float = 1.05


class Voice:
    """Owns the microphone and the speaker. Thread-safe; events go to `emit`."""

    def __init__(self, models: Path, emit: Emit, recorder_factory: Callable[[], Any] | None = None,
                 speaker: Any = None) -> None:
        self.models = models
        models.mkdir(parents=True, exist_ok=True)
        self.emit = emit
        self.settings = VoiceSettings()
        self._recorder_factory = recorder_factory or _MicStream
        self._stt = None
        self._stt_lock = threading.Lock()
        self._tts = None
        self._lock = threading.Lock()
        self._chunks: list[np.ndarray] = []
        self._stream = None
        self._listening = False
        self._partial_thread: threading.Thread | None = None
        self._speaker = speaker or _Speaker(self)
        self.downloading: dict[str, float] = {}  # what -> progress 0..1

    # ---- status ------------------------------------------------------------

    @property
    def whisper_dir(self) -> Path:
        return self.models / f"faster-whisper-{WHISPER_MODEL}"

    def can_listen(self) -> bool:
        return (self.whisper_dir / "model.bin").exists()

    def has_natural_voice(self) -> bool:
        return all((self.models / f).exists() for f in KOKORO_FILES)

    def status(self) -> dict[str, Any]:
        return {
            "listen_ready": self.can_listen(),
            "natural_voice": self.has_natural_voice(),
            "engine": "kokoro" if self.has_natural_voice() else ("windows" if sys.platform == "win32" else "none"),
            "listening": self._listening,
            "speaking": self._speaker.speaking,
            "downloading": dict(self.downloading),
            "download_sizes_mb": DOWNLOAD_SIZES_MB,
            "voices": KOKORO_VOICES,
            "settings": vars(self.settings),
        }

    # ---- downloads (only when the user asks) ---------------------------------

    def download(self, what: str) -> None:
        if what in self.downloading:
            return
        if what not in DOWNLOAD_SIZES_MB:
            raise ValueError(what)
        self.downloading[what] = 0.0
        threading.Thread(target=self._download, args=(what,), daemon=True).start()

    def _download(self, what: str) -> None:
        try:
            if what == "listen":
                from faster_whisper import download_model

                download_model(WHISPER_MODEL, output_dir=str(self.whisper_dir))
            else:
                files = list(KOKORO_FILES.items())
                for i, (name, url) in enumerate(files):
                    target = self.models / name
                    if target.exists():
                        continue
                    part = target.with_suffix(target.suffix + ".part")

                    def hook(blocks: int, size: int, total: int, i: int = i) -> None:
                        if total > 0:
                            self.downloading[what] = (i + min(1.0, blocks * size / total)) / len(files)

                    urllib.request.urlretrieve(url, part, hook)  # noqa: S310 - fixed https URLs
                    part.replace(target)
            self.emit({"type": "voice_ready", "what": what})
        except Exception as e:  # noqa: BLE001
            self.emit({"type": "voice_error", "what": what, "error": f"Download failed: {e}"})
        finally:
            self.downloading.pop(what, None)

    # ---- listening ------------------------------------------------------------

    def _whisper(self):
        with self._stt_lock:
            if self._stt is None:
                from faster_whisper import WhisperModel

                self._stt = WhisperModel(str(self.whisper_dir), device="cpu", compute_type="int8")
            return self._stt

    def transcribe(self, audio: np.ndarray) -> str:
        if audio.size < RATE * 0.3:
            return ""
        segments, _ = self._whisper().transcribe(audio, language="en", beam_size=1, vad_filter=False)
        return " ".join(s.text.strip() for s in segments).strip()

    def start_listening(self) -> None:
        if not self.can_listen():
            raise RuntimeError("Speech recognition isn't downloaded yet. Turn it on in Settings → Voice.")
        self.stop_speaking()  # pressing the mic always interrupts Compii
        with self._lock:
            if self._listening:
                return
            self._chunks = []
            self._listening = True
            self._stream = self._recorder_factory()
            self._stream.start(self._on_audio)
        self.emit({"type": "voice_listening", "on": True})
        self._partial_thread = threading.Thread(target=self._partials, daemon=True)
        self._partial_thread.start()
        threading.Thread(target=self._whisper, daemon=True).start()  # warm up while you talk

    def _on_audio(self, block: np.ndarray) -> None:
        if self._listening:
            self._chunks.append(block.copy())
            level = float(np.sqrt(np.mean(block.astype(np.float32) ** 2)))
            self.emit({"type": "voice_level", "level": min(1.0, level * 8)})

    def _audio(self) -> np.ndarray:
        with self._lock:
            chunks = list(self._chunks)
        return np.concatenate(chunks).astype(np.float32) if chunks else np.zeros(0, np.float32)

    def _partials(self) -> None:
        last = ""
        started = time.monotonic()
        while self._listening:
            time.sleep(PARTIAL_EVERY)
            if not self._listening:
                break
            if time.monotonic() - started > MAX_SECONDS:
                break
            try:
                text = self.transcribe(self._audio())
            except Exception:  # noqa: BLE001 - a partial is best effort
                continue
            if text and text != last and self._listening:
                last = text
                self.emit({"type": "voice_partial", "text": text})

    def stop_listening(self) -> str:
        """Stop recording and return the final transcript."""
        with self._lock:
            if not self._listening:
                return ""
            self._listening = False
            stream, self._stream = self._stream, None
        if stream is not None:
            stream.stop()
        self.emit({"type": "voice_listening", "on": False})
        text = self.transcribe(self._audio())
        self.emit({"type": "voice_final", "text": text})
        return text

    def cancel_listening(self) -> None:
        with self._lock:
            self._listening = False
            stream, self._stream = self._stream, None
        if stream is not None:
            stream.stop()
        self.emit({"type": "voice_listening", "on": False})

    # ---- speaking ---------------------------------------------------------------

    def say(self, text: str) -> None:
        """Speak `text`, cutting off anything already being said."""
        text = text.strip()
        if text:
            self._speaker.say(text)

    def stop_speaking(self) -> None:
        self._speaker.stop()

    def _kokoro(self):
        if self._tts is None:
            from kokoro_onnx import Kokoro

            self._tts = Kokoro(str(self.models / "kokoro-v1.0.int8.onnx"), str(self.models / "voices-v1.0.bin"))
        return self._tts


class _MicStream:
    """Default microphone at 16 kHz mono."""

    def __init__(self) -> None:
        self._stream = None

    def start(self, on_audio: Callable[[np.ndarray], None]) -> None:
        import sounddevice as sd

        def callback(indata, _frames, _time, _status) -> None:
            on_audio(indata[:, 0].copy())  # the driver reuses its buffer

        self._stream = sd.InputStream(samplerate=RATE, channels=1, dtype="float32", blocksize=RATE // 10, callback=callback)
        self._stream.start()

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()


class _Speaker:
    """Plays one utterance at a time on a background thread; any new utterance,
    the mic or Stop interrupts the current one immediately."""

    def __init__(self, voice: Voice) -> None:
        self.voice = voice
        self._jobs: queue.Queue[str | None] = queue.Queue()
        self._generation = 0
        self.speaking = False
        self._sapi = None
        threading.Thread(target=self._loop, daemon=True).start()

    def say(self, text: str) -> None:
        self.stop()
        self._jobs.put(text)

    def stop(self) -> None:
        self._generation += 1
        while not self._jobs.empty():
            try:
                self._jobs.get_nowait()
            except queue.Empty:
                break
        if self.speaking:
            try:
                import sounddevice as sd

                sd.stop()
            except Exception:  # noqa: BLE001
                pass
            # The Windows voice is purged by its own thread (COM objects stay on one thread).

    def _set(self, on: bool) -> None:
        if self.speaking != on:
            self.speaking = on
            self.voice.emit({"type": "voice_speaking", "on": on})

    def _loop(self) -> None:
        if sys.platform == "win32":
            import comtypes

            comtypes.CoInitialize()  # the Windows voice lives on this thread
        while True:
            text = self._jobs.get()
            if text is None:
                return
            generation = self._generation
            try:
                self._set(True)
                if self.voice.has_natural_voice():
                    self._speak_kokoro(text, generation)
                elif sys.platform == "win32":
                    self._speak_windows(text, generation)
            except Exception as e:  # noqa: BLE001
                self.voice.emit({"type": "voice_error", "what": "speak", "error": str(e)})
            finally:
                if self._jobs.empty():
                    self._set(False)

    def _speak_kokoro(self, text: str, generation: int) -> None:
        import sounddevice as sd

        s = self.voice.settings
        # Sentence by sentence, so speech starts quickly and stops promptly.
        for sentence in _sentences(text):
            if generation != self._generation:
                return
            samples, rate = self.voice._kokoro().create(sentence, voice=s.voice, speed=s.speed, lang="en-us")
            if generation != self._generation:
                return
            sd.play(samples, rate)
            sd.wait()

    def _speak_windows(self, text: str, generation: int) -> None:
        if self._sapi is None:
            import comtypes.client as cc

            self._sapi = cc.CreateObject("SAPI.SpVoice")
            self._sapi.Rate = 1
        self._sapi.Speak(text, 1)  # 1 = async, so we can interrupt it
        while not self._sapi.WaitUntilDone(80):
            if generation != self._generation:
                self._sapi.Speak("", 3)  # async + purge: stop talking now
                return


def _sentences(text: str) -> list[str]:
    import re

    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()]
    return parts or [text]
