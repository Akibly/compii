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
SPEECH_RMS = 0.012  # louder than this counts as speech
AUTO_END_SILENCE = 1.1  # hands-free: this much quiet after you spoke sends it
AUTO_END_WAIT = 6.0  # hands-free: give up if you never start talking
MAX_SECONDS = 120

WHISPER_MODEL = "base.en"
KOKORO_FILES = {
    "kokoro-v1.0.int8.onnx": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx",
    "voices-v1.0.bin": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
}
DOWNLOAD_SIZES_MB = {"listen": 145, "speak": 120, "listen_hq": 465, "speak_hq": 170}
# Capitalised words that aren't names; anything else capitalised gets a second, sharper listen.
COMMON_CAPS = {"downloads", "documents", "desktop", "pictures", "monday", "tuesday", "wednesday", "thursday",
               "friday", "saturday", "sunday", "january", "february", "march", "april", "june", "july", "august",
               "september", "october", "november", "december", "excel", "word", "outlook", "chrome", "edge",
               "windows", "google", "notepad", "settings", "compii", "doctor", "mister", "misses", "please"}
# Fuller-quality voice model (half precision instead of 8-bit): smoother, less "robot".
KOKORO_HQ = ("kokoro-v1.0.fp16.onnx",
             "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.fp16.onnx")
CLOUD_WHISPER = "whisper-large-v3-turbo"
WHISPER_HQ = "small.en"  # sharper final transcripts (optional download)
KOKORO_VOICES = {
    "compii_warm": "Compii (warm)",
    "compii_bright": "Compii (bright)",
    "compii_playful": "Compii (playful)",
    "af_heart": "Heart (warm, US)",
    "af_bella": "Bella (bright, US)",
    "am_michael": "Michael (calm, US)",
    "bf_emma": "Emma (British)",
    "bm_george": "George (British)",
}

# Compii's own voices: blends of Kokoro's voices, so it sounds like itself.
VOICE_BLENDS = {
    "compii_warm": {"af_heart": .6, "af_bella": .4},
    "compii_bright": {"af_heart": .55, "af_sky": .45},
    "compii_playful": {"af_heart": .5, "am_puck": .5},
}


def kokoro_lang(voice: str) -> str:
    """British voices need British pronunciation, or they sound off."""
    return "en-gb" if voice.startswith(("bf_", "bm_")) else "en-us"


Emit = Callable[[dict[str, Any]], None]

_CHIME = object()  # a queued sound effect instead of words
_CHIME_AUDIO: tuple[np.ndarray, int] | None = None


@dataclass
class VoiceSettings:
    # How Compii answers when it isn't in the conversation window:
    # "voice" speaks, "sound" plays a chime and puts the words on screen,
    # "caption" only puts the words on screen, "off" stays out of the way.
    output_mode: str = "voice"
    voice: str = "compii_warm"
    speed: float = 1.05
    # "natural" uses Kokoro when downloaded; "windows" is the instant built-in voice.
    engine: str = "natural"
    # "Hey Compii": off until the user turns it on (the mic stays open while it's on).
    wake_word: bool = False
    # Recognise speech on Groq (fast, accurate, spares your CPU) when a Groq key is stored;
    # the on-device recogniser is the backup. Off: everything stays on this PC.
    cloud_listening: bool = True
    # Compii's eyes: reading which windows are open and what's in them. Off is a real off - nothing
    # is read and every tool that needs the screen says so, instead of quietly guessing.
    screen_aware: bool = True
    # When an app doesn't describe itself (Blender, games…) and you ask about the screen,
    # send a picture of that window to a free vision model. Off: Compii only reads labels.
    see_pictures: bool = True


class Voice:
    """Owns the microphone and the speaker. Thread-safe; events go to `emit`."""

    def __init__(self, models: Path, emit: Emit, recorder_factory: Callable[[], Any] | None = None,
                 speaker: Any = None) -> None:
        self.models = models
        models.mkdir(parents=True, exist_ok=True)
        self.emit = emit
        self.settings = VoiceSettings()
        self.cloud_key: Callable[[], str | None] | None = None  # set by the server: the Groq key, if stored
        self._recorder_factory = recorder_factory or _MicStream
        self._stt = None
        self._stt_lock = threading.Lock()
        self._stopped = threading.Event()
        self._load_lock = threading.Lock()
        self._tts = None
        self._lock = threading.Lock()
        self._chunks: list[np.ndarray] = []
        self._stream = None
        self._listening = False
        self._recorded_pending = False  # recording stopped, transcript not taken yet
        # Hands-free mode: send automatically when you stop talking.
        self.on_auto_end: Callable[[], None] | None = None
        self._auto = False
        self._heard_speech = False
        self._last_loud = 0.0
        self._listen_started = 0.0
        self._partial_thread: threading.Thread | None = None
        self._speaker = speaker or _Speaker(self)
        self._wake = None
        # Called with a spoken request heard hands-free.
        self.on_command: Callable[[str], None] | None = None
        self.downloading: dict[str, float] = {}  # what -> progress 0..1

    # ---- status ------------------------------------------------------------

    @property
    def whisper_dir(self) -> Path:
        return self.models / f"faster-whisper-{WHISPER_MODEL}"

    def can_listen(self) -> bool:
        """Ready to hear you: the on-PC model is downloaded, or speech is recognised on Groq."""
        return self.has_local_listening() or bool(self._cloud_key())

    def has_local_listening(self) -> bool:
        return (self.whisper_dir / "model.bin").exists()

    def has_natural_voice(self) -> bool:
        return all((self.models / f).exists() for f in KOKORO_FILES)

    def uses_natural_voice(self) -> bool:
        return self.settings.engine == "natural" and self.has_natural_voice()

    @property
    def announces(self) -> bool:
        """Does Compii answer at all when something finishes? Only the "off" mode says nothing."""
        return self.settings.output_mode != "off"

    def warm_up(self) -> None:
        """Load the voice model in the background so the first reply isn't slow."""
        if self.has_natural_voice():
            def run() -> None:
                try:
                    self._kokoro().create("Ready.", voice=self.kokoro_voice(), lang=kokoro_lang(self.settings.voice))
                except Exception:  # noqa: BLE001 - warm-up is best effort
                    pass
            threading.Thread(target=run, daemon=True).start()

    @property
    def whisper_hq_dir(self) -> Path:
        return self.models / f"faster-whisper-{WHISPER_HQ}"

    def has_hq(self) -> bool:
        return (self.whisper_hq_dir / "model.bin").exists()

    def status(self) -> dict[str, Any]:
        return {
            "listen_ready": self.can_listen(),
            "local_listening": self.has_local_listening(),
            "listen_hq": self.has_hq(),
            "speak_hq": (self.models / KOKORO_HQ[0]).exists(),
            "natural_voice": self.has_natural_voice(),
            "engine": "kokoro" if self.uses_natural_voice() else ("windows" if sys.platform == "win32" else "none"),
            "listening": self._listening,
            "wake_listening": bool(self._wake and self._wake.running),
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
            if what in ("listen", "listen_hq"):
                from faster_whisper import download_model

                if what == "listen":
                    download_model(WHISPER_MODEL, output_dir=str(self.whisper_dir))
                else:
                    download_model(WHISPER_HQ, output_dir=str(self.whisper_hq_dir))
                    self._stt_hq = None
            elif what == "speak_hq":
                target = self.models / KOKORO_HQ[0]
                part = target.with_suffix(".part")

                def hook_hq(blocks: int, size: int, total: int) -> None:
                    if total > 0:
                        self.downloading[what] = min(1.0, blocks * size / total)

                urllib.request.urlretrieve(KOKORO_HQ[1], part, hook_hq)  # noqa: S310 - fixed https URL
                part.replace(target)
                with self._lock:
                    self._tts = None  # reload with the better model
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

    # ---- "Hey Compii" ------------------------------------------------------------------

    def set_wake(self, on: bool) -> None:
        """Turn hands-free listening on or off."""
        if on and not self.has_local_listening():  # "Hey Compii" listens on this PC
            raise RuntimeError("Download speech recognition first (Settings → Voice).")
        self.settings.wake_word = on
        if on:
            if self._wake is None:
                from .wake import WakeListener

                self._wake = WakeListener(
                    transcribe=self._transcribe_hint,
                    on_wake=self._woke,
                    on_command=self._heard_command,
                    on_level=lambda lv: self.emit({"type": "voice_level", "level": lv}),
                    paused=lambda: self._listening or self._speaker.speaking,
                    mic_factory=self._recorder_factory,
                )
            self._wake.start()
            threading.Thread(target=self._warm_listen, daemon=True).start()
        elif self._wake is not None:
            self._wake.stop()
        self.emit({"type": "voice_wake_word", "on": on})

    def _transcribe_hint(self, audio: np.ndarray, hint: str) -> str:
        """Short reads for the wake phrase, primed to expect the name."""
        if audio.size < RATE * 0.3 or float(np.abs(audio).max()) < 0.003:
            return ""
        peak = float(np.abs(audio).max())
        if peak < 0.5:
            audio = audio * (0.5 / peak)
        with self._stt_lock:
            segments, _ = self._whisper().transcribe(
                # No speech detector here: the wake listener's loudness gate already
                # cut out the burst, and the detector clips short words like "Hey".
                audio, language="en", beam_size=1, vad_filter=False,
                condition_on_previous_text=False, initial_prompt=hint or None,
            )
            words = [seg.text.strip() for seg in segments if seg.no_speech_prob < 0.6 and seg.avg_logprob > -1.2]
        return " ".join(words).strip()

    def _woke(self) -> None:
        self.emit({"type": "voice_wake"})
        self.emit({"type": "voice_listening", "on": True})
        if self.announces:  # answers off: the app shows it's listening instead
            self.say("Yes?")

    def _heard_command(self, text: str) -> None:
        self.emit({"type": "voice_listening", "on": False})
        if text.strip():
            self.emit({"type": "voice_final", "text": text, "hands_free": True})
            if self.on_command:
                self.on_command(text)

    def close(self) -> None:
        if self._wake is not None:
            self._wake.stop()

    def _warm_listen(self) -> None:
        if self._cloud_key():
            return  # recognised on Groq: no need to load the on-device model
        try:
            self._whisper()
        except Exception:  # noqa: BLE001 - only an optimisation; the real call reports problems
            pass

    def _whisper(self):
        if self._stt is None:
            with self._load_lock:
                if self._stt is None:
                    from faster_whisper import WhisperModel

                    self._stt = WhisperModel(str(self.whisper_dir), device="cpu", compute_type="int8")
        return self._stt

    def _whisper_hq(self):
        """The sharper model for final transcripts, if downloaded (else the fast one)."""
        if not self.has_hq():
            return self._whisper()
        if getattr(self, "_stt_hq", None) is None:
            with self._load_lock:
                if getattr(self, "_stt_hq", None) is None:
                    from faster_whisper import WhisperModel

                    self._stt_hq = WhisperModel(str(self.whisper_hq_dir), device="cpu", compute_type="int8")
        return self._stt_hq

    def set_hints(self, words: list[str]) -> None:
        """Words likely to be said (names on screen, the app's title) help recognition."""
        clean = []
        for w in words:
            w = " ".join(str(w).split())[:40]
            if w and w not in clean:
                clean.append(w)
        self._hints = clean[:40]

    def transcribe(self, audio: np.ndarray, final: bool = True) -> str:
        """Speech to text. Silence and noise give "" instead of invented words."""
        if final:
            text, self.last_unclear = self.transcribe_detailed(audio)
            self.last_final = (text, time.monotonic())
            return text
        return self._transcribe_fast(audio)

    def transcribe_detailed(self, audio: np.ndarray) -> tuple[str, list[str]]:
        """The careful final pass (~1 s): beam search with a vocabulary hint from the
        screen. Words the live preview and this pass disagree on were hard to hear;
        only then, if the sharper model is downloaded, it re-checks (a few seconds)."""
        if audio.size < RATE * 0.3 or float(np.abs(audio).max()) < 0.003:
            return "", []
        peak = float(np.abs(audio).max())
        if peak < 0.5:
            audio = audio * (0.5 / peak)
        hints = getattr(self, "_hints", [])
        prompt = ("Compii." + (" " + ", ".join(hints) + "." if hints else ""))[:400]
        key = self._cloud_key()
        if key:
            try:
                text = self._transcribe_cloud(audio, prompt, key)
                unclear = [w for w in _words(text) if len(w) > 2 and _words(getattr(self, "_last_preview", ""))
                           and w not in set(_words(getattr(self, "_last_preview", "")))]
                return text, list(dict.fromkeys(unclear))[:6]
            except Exception:  # noqa: BLE001 - offline or over the free limit: recognise on this PC
                pass
        if not self.has_local_listening():
            return "", []  # no on-PC model to fall back to: "I didn't catch that"

        def run(model) -> str:
            segments, _ = model.transcribe(
                audio, language="en", beam_size=5, vad_filter=True,
                vad_parameters={"min_silence_duration_ms": 400}, condition_on_previous_text=False,
                no_speech_threshold=0.5, initial_prompt=prompt,
            )
            return " ".join(seg.text.strip() for seg in segments
                            if seg.no_speech_prob < 0.6 and seg.avg_logprob > -1.2).strip()

        def words(t: str) -> list[str]:
            return [w.strip(" .,!?;:\"'").lower() for w in t.split()]

        def differ(a: str, b: str) -> list[str]:
            other = set(words(b))
            return list(dict.fromkeys(w for w in words(a) if len(w) > 2 and other and w not in other))

        with self._stt_lock:
            text = run(self._whisper())
            unclear = differ(text, getattr(self, "_last_preview", ""))
            known = {w.lower() for h in hints for w in h.split()} | COMMON_CAPS
            names = [w.strip(".,!?;:'\"") for w in text.split()[1:]]
            names = [w for w in names if len(w) > 3 and w[:1].isupper() and not w.isupper() and w.lower() not in known]
            if (unclear or names) and self.has_hq():
                sharp = run(self._whisper_hq())
                if sharp:
                    # Still unclear: words the two careful passes disagree on.
                    unclear = differ(sharp, text)
                    text = sharp
        return text, unclear[:6]

    def kokoro_voice(self) -> Any:
        """The chosen voice: a Kokoro name, or the mixed style of one of Compii's own voices."""
        name = self.settings.voice
        blend = VOICE_BLENDS.get(name)
        if not blend:
            return name
        cached = getattr(self, "_blend", None)
        if cached and cached[0] == name:
            return cached[1]
        k = self._kokoro()
        style = sum(k.get_voice_style(v) * w for v, w in blend.items())
        self._blend = (name, style)
        return style

    def _cloud_key(self) -> str | None:
        if not self.settings.cloud_listening or self.cloud_key is None:
            return None
        try:
            return self.cloud_key()
        except Exception:  # noqa: BLE001
            return None

    def _transcribe_cloud(self, audio: np.ndarray, prompt: str, key: str) -> str:
        """Groq's Whisper large-v3-turbo: about half a second for a spoken request."""
        import io
        import wave

        import httpx

        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
        r = httpx.post("https://api.groq.com/openai/v1/audio/transcriptions",
                       headers={"Authorization": f"Bearer {key}"},
                       data={"model": CLOUD_WHISPER, "language": "en", "prompt": prompt[:200], "temperature": "0",
                             "response_format": "json"},
                       files={"file": ("speech.wav", buf.getvalue(), "audio/wav")}, timeout=8)
        r.raise_for_status()
        return (r.json().get("text") or "").strip()

    def annotate(self, text: str) -> str:
        """If `text` is what was just heard, note the words that were unclear, for the AI."""
        last = getattr(self, "last_final", None)
        unclear = getattr(self, "last_unclear", [])
        if not unclear or not last or last[0].strip() != text.strip() or time.monotonic() - last[1] > 30:
            return text
        return f"{text}\n\n(Spoken request. Possibly misheard words: {', '.join(unclear)}.)"

    def _transcribe_fast(self, audio: np.ndarray) -> str:
        """Live preview while you talk: quick and good enough."""
        if audio.size < RATE * 0.3:
            return ""
        peak = float(np.abs(audio).max())
        if peak < 0.003:  # nothing but silence
            return ""
        if peak < 0.5:  # quiet microphones: bring speech up to a useful level
            audio = audio * (0.5 / peak)
        with self._stt_lock:  # one transcription at a time; the final one never waits behind a stale preview
            segments, _ = self._whisper().transcribe(
                audio,
                language="en",
                beam_size=1,  # greedy: word-perfect in tests and fast on laptop CPUs
                vad_filter=True,  # Silero speech detection: skip non-speech
                vad_parameters={"min_silence_duration_ms": 400},
                condition_on_previous_text=False,
                no_speech_threshold=0.5,
            )
            words = [seg.text.strip() for seg in segments if seg.no_speech_prob < 0.6 and seg.avg_logprob > -1.2]
        return " ".join(words).strip()

    def start_listening(self) -> None:
        if not self.can_listen():
            raise RuntimeError("Speech recognition isn't downloaded yet. Turn it on in Settings → Voice.")
        self.stop_speaking()  # pressing the mic always interrupts Compii
        with self._lock:
            if self._listening:
                return
            self._chunks = []
            self._last_preview = ""
            self._heard_speech = False
            self._listen_started = self._last_loud = time.monotonic()
            self._listening = True
            self._stopped.clear()
            self._stream = self._recorder_factory()
            self._stream.start(self._on_audio)
        self.emit({"type": "voice_listening", "on": True})
        self._partial_thread = threading.Thread(target=self._partials, daemon=True)
        self._partial_thread.start()
        threading.Thread(target=self._warm_listen, daemon=True).start()  # warm up while you talk

    def _on_audio(self, block: np.ndarray) -> None:
        if self._listening:
            self._chunks.append(block.copy())
            level = float(np.sqrt(np.mean(block.astype(np.float32) ** 2)))
            if level > SPEECH_RMS:
                self._heard_speech = True
                self._last_loud = time.monotonic()
            self.emit({"type": "voice_level", "level": min(1.0, level * 8)})

    def _audio(self) -> np.ndarray:
        with self._lock:
            chunks = list(self._chunks)
        return np.concatenate(chunks).astype(np.float32) if chunks else np.zeros(0, np.float32)

    def _partials(self) -> None:
        last = ""
        started = time.monotonic()
        while self._listening:
            if self._stopped.wait(0.15 if self._auto else PARTIAL_EVERY):  # wakes at once when you release
                break
            now = time.monotonic()
            if self._auto and self._listening and (
                (self._heard_speech and now - self._last_loud >= AUTO_END_SILENCE)
                or (not self._heard_speech and now - self._listen_started >= AUTO_END_WAIT)
            ):
                self._auto = False
                if self.on_auto_end:
                    threading.Thread(target=self.on_auto_end, daemon=True).start()
                break
            if self._auto and now - getattr(self, "_last_partial", 0) < PARTIAL_EVERY:
                continue
            self._last_partial = now
            if time.monotonic() - started > MAX_SECONDS:
                break
            if self._cloud_key():
                continue  # recognised on Groq when you let go: spare your PC the live preview
            if self._stt_lock.locked():
                continue  # still working on the previous preview
            try:
                text = self.transcribe(self._audio(), final=False)
            except Exception:  # noqa: BLE001 - a partial is best effort
                continue
            if text and text != last and self._listening:
                last = text
                self._last_preview = text
                self.emit({"type": "voice_partial", "text": text})

    def listen_hands_free(self) -> None:
        """Keep listening after a quick tap and send by itself when you stop talking."""
        self._auto = True

    def stop_recording(self) -> bool:
        """Turn the microphone off right away (the transcript comes after).
        Returns False if nothing was being recorded."""
        with self._lock:
            if not self._listening:
                return self._recorded_pending
            self._auto = False
            self._listening = False
            self._recorded_pending = True
            self._stopped.set()
            stream, self._stream = self._stream, None
        if stream is not None:
            stream.stop()
        self.emit({"type": "voice_listening", "on": False})
        return True

    def stop_listening(self) -> str:
        """Stop recording (if still on) and return the final transcript."""
        if not self.stop_recording():
            return ""
        self._recorded_pending = False
        if self._partial_thread is not None:
            # Let any preview finish first (it holds the on-device recogniser), unless the cloud does the final pass.
            self._partial_thread.join(timeout=0.05 if self._cloud_key() else 5)
        text = self.transcribe(self._audio())
        self.emit({"type": "voice_final", "text": text})
        return text

    def cancel_listening(self) -> None:
        with self._lock:
            self._listening = False
            self._stopped.set()
            stream, self._stream = self._stream, None
        if stream is not None:
            stream.stop()
        self.emit({"type": "voice_listening", "on": False})

    # ---- speaking ---------------------------------------------------------------

    def say(self, text: str, spoken: str | None = None) -> None:
        """Answer the way the user set it: out loud, a chime with the words on
        screen, or the words on their own. Cuts off anything already being said.

        `spoken` is the shorter thing worth saying; someone reading gets all of `text`."""
        text = text.strip()
        if not text or self.settings.output_mode == "off":
            return
        self.emit({"type": "voice_caption", "text": text})  # every mode is readable
        if self.settings.output_mode == "voice":
            self.say_now(spoken or text)
        elif self.settings.output_mode == "sound":
            self._speaker.chime()

    def say_now(self, text: str) -> None:
        """Speak whatever the answer mode is - what the "hear this voice" preview needs."""
        text = text.strip()
        if text:
            self._speaker.say(text)

    def stop_speaking(self) -> None:
        self._speaker.stop()

    def _kokoro(self):
        with self._lock:
            return self._load_kokoro()

    def _load_kokoro(self):
        if self._tts is None:
            from kokoro_onnx import Kokoro

            hq = self.models / KOKORO_HQ[0]
            model = hq if hq.exists() else self.models / "kokoro-v1.0.int8.onnx"
            self._tts = Kokoro(str(model), str(self.models / "voices-v1.0.bin"))
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
        self._jobs: queue.Queue[Any] = queue.Queue()
        self._generation = 0
        self.speaking = False
        self._sapi = None
        threading.Thread(target=self._loop, daemon=True).start()

    def say(self, text: str) -> None:
        self.stop()
        self._jobs.put(text)

    def chime(self) -> None:
        """Two rising notes instead of words. Queued like speech: only this
        thread may touch the audio device."""
        self.stop()
        self._jobs.put(_CHIME)

    def stop(self) -> None:
        self._generation += 1
        while not self._jobs.empty():
            try:
                self._jobs.get_nowait()
            except queue.Empty:
                break
        # Playback notices the new generation within a few milliseconds and stops itself.
        # Never touch the audio device from here: stopping it from another thread
        # crashed Core (PortAudio isn't thread-safe). The Windows voice is purged by its
        # own thread too (COM objects stay on one thread).

    def _set(self, on: bool) -> None:
        if self.speaking != on:
            self.speaking = on
            self.voice.emit({"type": "voice_speaking", "on": on})

    def _loop(self) -> None:
        if sys.platform == "win32":
            import comtypes

            comtypes.CoInitialize()  # the Windows voice lives on this thread
        while True:
            job = self._jobs.get()
            if job is None:
                return
            if job is _CHIME:
                try:
                    self._chime()
                except Exception as e:  # noqa: BLE001
                    self.voice.emit({"type": "voice_error", "what": "chime", "error": str(e)})
                continue
            generation = self._generation
            try:
                self._set(True)
                if self.voice.uses_natural_voice():
                    self._speak_kokoro(job, generation)
                elif sys.platform == "win32":
                    self._speak_windows(job, generation)
            except Exception as e:  # noqa: BLE001
                self.voice.emit({"type": "voice_error", "what": "speak", "error": str(e)})
            finally:
                if self._jobs.empty():
                    self._set(False)

    def _chime(self) -> None:
        global _CHIME_AUDIO
        if _CHIME_AUDIO is None:
            _CHIME_AUDIO = _make_chime()
        samples, rate = _CHIME_AUDIO
        self._play(samples.copy(), rate, self._generation)

    def _speak_kokoro(self, text: str, generation: int) -> None:
        """Pipelined: the next phrase is generated while the current one plays,
        so speech flows even when generation is close to real time."""
        s = self.voice.settings
        ready: queue.Queue[tuple[np.ndarray, int] | None] = queue.Queue(maxsize=2)

        def produce() -> None:
            try:
                for phrase in _phrases(text):
                    if generation != self._generation:
                        break
                    ready.put(self.voice._kokoro().create(phrase, voice=self.voice.kokoro_voice(), speed=s.speed,
                                                          lang=kokoro_lang(s.voice)))
            finally:
                ready.put(None)

        threading.Thread(target=produce, daemon=True).start()
        while True:
            item = ready.get()
            if item is None or generation != self._generation:
                return
            samples, rate = item
            samples = _trim(samples)
            pause = np.zeros(int(rate * 0.12), dtype=samples.dtype)  # a breath between sentences
            self._play(np.concatenate([samples, pause]), rate, generation)

    def _play(self, audio: np.ndarray, rate: int, generation: int) -> None:
        """Play on this (the speaker) thread only; stops early when interrupted."""
        import sounddevice as sd

        audio = audio.astype(np.float32)
        pos = 0
        done = threading.Event()

        def fill(out, frames, _time, _status) -> None:
            nonlocal pos
            if generation != self._generation:
                out.fill(0)
                raise sd.CallbackStop
            chunk = audio[pos:pos + frames]
            out[:len(chunk), 0] = chunk
            pos += frames
            if len(chunk) < frames:
                out[len(chunk):] = 0
                raise sd.CallbackStop

        with sd.OutputStream(samplerate=rate, channels=1, dtype="float32", callback=fill,
                             finished_callback=done.set):
            while not done.wait(0.05):
                if generation != self._generation:
                    break  # leaving the block stops and closes the stream, here on this thread

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


def _words(t: str) -> list[str]:
    return [w.strip(" .,!?;:\"'").lower() for w in t.split()]


def _make_chime() -> tuple[np.ndarray, int]:
    """Two soft rising notes: "I have something for you", without using words."""
    rate = 22_050
    notes = []
    for freq, secs in ((660.0, .09), (880.0, .16)):
        t = np.arange(int(rate * secs)) / rate
        tone = np.sin(2 * np.pi * freq * t) * np.exp(-3.2 * t)
        fade = int(rate * .01)
        tone[:fade] *= np.linspace(0.0, 1.0, fade)
        notes.append((tone * .3).astype(np.float32))
    gap = np.zeros(int(rate * .04), dtype=np.float32)
    return np.concatenate([notes[0], gap, notes[1]]), rate


def _trim(samples: np.ndarray, floor: float = 0.004) -> np.ndarray:
    """Cut the silence the voice model leaves at the start and end of each sentence."""
    loud = np.flatnonzero(np.abs(samples) > floor)
    if loud.size == 0:
        return samples
    return samples[max(0, loud[0] - 400): loud[-1] + 1200]


def _sentences(text: str) -> list[str]:
    import re

    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()]
    return parts or [text]


FILE_KINDS = {"pdf": "PDF", "xlsx": "spreadsheet", "xls": "spreadsheet", "csv": "spreadsheet", "docx": "document",
              "doc": "document", "pptx": "slides", "png": "picture", "jpg": "picture", "jpeg": "picture",
              "mp4": "video", "mp3": "audio", "zip": "zip file"}


def spoken_reply(text: str, sentences: int = 2, longest: int = 280) -> str:
    """What Compii says out loud: the first sentence or two of its reply, cleaned up.
    The full reply stays in the bubble; reading reports aloud is tiring and odd."""
    out = ""
    for sentence in _sentences(speakable(text)):
        if out and (len(out) + len(sentence) > longest or out.count(". ") + out.count("? ") + 1 >= sentences):
            break
        out = f"{out} {sentence}".strip()
    return out


def speakable(text: str) -> str:
    """Turn a written reply into something natural to say: no markdown, bullets,
    code, raw links, long paths, ids, emoji or abbreviations read letter by letter."""
    import re

    t = re.sub(r"```.*?```", " ", text, flags=re.S)
    t = re.sub(r"^\s*\|.*\|\s*$", " ", t, flags=re.M)  # tables
    t = re.sub(r"\((?:[^()]{40,})\)", "", t)  # long asides in brackets
    t = re.sub(r"\b(e\.g|i\.e|etc|vs)\.", lambda m: {"e.g": "for example", "i.e": "that is", "etc": "and so on",
                                                       "vs": "versus"}[m.group(1).lower()], t, flags=re.I)
    t = re.sub(r"\b[eEvV]\d{1,4}\b", "", t)  # screen item ids (e12, v3)
    t = re.sub(r"\bCtrl\b", "Control", t)
    t = re.sub(r"(?<=\w)\s*\+\s*(?=[A-Z])", " ", t)  # Control+Alt -> Control Alt
    t = t.replace("→", " to ").replace("&", " and ").replace("–", " to ")
    t = re.sub(r"\s*—\s*", ", ", t)
    t = re.sub(r"[\U0001F000-\U0001FAFF\u2600-\u27BF\uFE0F]", "", t)  # emoji
    t = re.sub(r"`([^`]*)`", r"\1", t)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)  # [label](link) -> label
    t = re.sub(r"https?://\S+?(?=[.,!?)]*(?:\s|$))", "a link", t)  # keeps the full stop after a link
    t = re.sub(r"(?:[A-Za-z]:)?(?:[\\/][^\\/\s]+){2,}[\\/]([^\\/\s]+)", r"\1", t)  # paths -> file name
    t = re.sub(r"\b([\w-]+)\.(\w{2,4})\b", lambda m: f"{m.group(1)} {FILE_KINDS[m.group(2).lower()]}"
               if m.group(2).lower() in FILE_KINDS else (m.group(1) if m.group(2).lower() in
               ("md", "txt", "json", "py", "html", "log") else m.group(0)), t)  # report.md -> report
    t = re.sub(r"[*_#>|]+", "", t)
    t = re.sub(r"^\s*(?:[-•]|\d+[.)])\s+", "", t, flags=re.M)  # list markers
    t = re.sub(r"[:;]?\s*\n+\s*", ". ", t)
    t = re.sub(r"\.\s*\.", ".", t)
    t = re.sub(r"\s{2,}", " ", t).strip(" .")
    return t + ("." if t and t[-1] not in ".!?" else "")


def _phrases(text: str, longest: int = 220) -> list[str]:
    """Whole sentences, so the voice keeps its natural rise and fall. Only a long
    first sentence is split at a comma, to get the voice going quickly."""
    import re

    out: list[str] = []
    for sentence in _sentences(speakable(text)):
        if len(sentence) <= longest:
            out.append(sentence)
            continue
        chunk = ""
        for part in re.split(r"(?<=[,;:])\s+", sentence):
            if chunk and len(chunk) + len(part) > longest:
                out.append(chunk)
                chunk = part
            else:
                chunk = f"{chunk} {part}".strip()
        if chunk:
            out.append(chunk)
    # A long first sentence: start with its opening clause.
    # A long first sentence: start with its opening clause (whole sentences sound most natural).
    if out and len(out[0]) > 110 and "," in out[0][:90]:
        head, _, rest = out[0].partition(",")
        out[0:1] = [head + ",", rest.strip()]
    return out
