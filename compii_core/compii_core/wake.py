"""Hands-free "Hey Compii", free and local.

How it stays cheap: while idle, only the loudness of the microphone is
measured. When a short burst of sound ends, the first two seconds are read
by the same local Whisper model Compii already uses, primed to expect the
word "Compii", and loosely matched against "hey / hi / ok Compii". Audio is
processed in memory and never stored.

After the wake phrase, Compii either takes the rest of the sentence as the
request ("Hey Compii, tidy my Downloads") or answers "Yes?" and listens until
you stop talking.
"""

from __future__ import annotations

import difflib
import re
import threading
import time
from collections import deque
from collections.abc import Callable
from typing import Any

import numpy as np

RATE = 16_000
BLOCK = RATE // 10  # 100 ms
CHECK_SECONDS = 2.2  # how much of a burst is read for the wake phrase
MAX_BURST = 10.0  # seconds; longer stretches are conversation, not a wake phrase
END_SILENCE = 0.5  # pause that ends a burst
COMMAND_SILENCE = 1.2  # pause that ends a spoken command
COMMAND_WAIT = 6.0  # how long to wait for a command after "Yes?"
COMMAND_MAX = 20.0

GREETINGS = {"hey", "hi", "hay", "he", "hei", "ok", "okay", "yo", "hello", "a"}
NAMES = ("compii", "compy", "compie", "compi", "kompi", "kompy", "campy")


def _name_like(word: str) -> bool:
    if len(word) < 5:  # "come", "copy", "camp" are not the name
        return False
    return max(difflib.SequenceMatcher(None, word, n).ratio() for n in NAMES) >= 0.8


def match_wake(text: str) -> tuple[bool, str]:
    """(heard the wake phrase?, whatever was said after it).

    The name must open the sentence ("Compii, …") or follow a greeting
    ("hey / hi / ok Compii"), within the first few words.
    """
    words = re.findall(r"[a-z']+", text.lower())
    for i, w in enumerate(words[:4]):
        if _name_like(w) and (i == 0 or words[i - 1] in GREETINGS):
            parts = re.split(re.escape(w), text, maxsplit=1, flags=re.IGNORECASE)
            after = parts[1] if len(parts) > 1 else ""
            return True, after.strip(" ,.!?-–—").strip()
    return False, ""


class WakeListener:
    """Runs on its own thread while enabled."""

    def __init__(
        self,
        transcribe: Callable[[np.ndarray, str], str],
        on_wake: Callable[[], None],
        on_command: Callable[[str], None],
        on_level: Callable[[float], None] | None = None,
        paused: Callable[[], bool] = lambda: False,
        mic_factory: Callable[[], Any] | None = None,
    ) -> None:
        self.transcribe = transcribe
        self.on_wake = on_wake
        self.on_command = on_command
        self.on_level = on_level
        self.paused = paused
        self._mic_factory = mic_factory
        self._blocks: deque[np.ndarray] = deque()
        self._have = threading.Condition()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._mic = None
        self.running = False
        self.checks = 0  # bursts actually read by Whisper (for diagnostics)

    # ---- lifecycle -----------------------------------------------------------

    def start(self) -> None:
        if self.running:
            return
        self._stop.clear()
        if self._mic_factory is None:
            from .voice import _MicStream

            self._mic_factory = _MicStream
        self._mic = self._mic_factory()
        self._mic.start(self._feed)
        self.running = True
        self._thread = threading.Thread(target=self._loop, daemon=True, name="compii-wake")
        self._thread.start()

    def stop(self) -> None:
        if not self.running:
            return
        self.running = False
        self._stop.set()
        with self._have:
            self._have.notify_all()
        if self._mic is not None:
            self._mic.stop()
            self._mic = None

    def _feed(self, block: np.ndarray) -> None:
        with self._have:
            self._blocks.append(block)
            if len(self._blocks) > 600:  # never let a stalled loop hoard audio
                self._blocks.popleft()
            self._have.notify()

    def _next(self, timeout: float = 0.5) -> np.ndarray | None:
        with self._have:
            if not self._blocks:
                self._have.wait(timeout)
            return self._blocks.popleft() if self._blocks else None

    # ---- the loop ----------------------------------------------------------------

    def _loop(self) -> None:
        noise = 0.004
        burst: list[np.ndarray] = []
        quiet = 0.0
        pre: deque[np.ndarray] = deque(maxlen=3)  # 300 ms before speech, so the first word isn't clipped
        while not self._stop.is_set():
            block = self._next()
            if block is None:
                continue
            if self.paused():
                burst, quiet = [], 0.0
                pre.clear()
                continue
            level = float(np.sqrt(np.mean(block * block)))
            loud = level > max(0.012, noise * 3.5)
            if not burst:
                noise = 0.95 * noise + 0.05 * level if not loud else noise  # follow the room's background
                if loud:
                    burst = [*pre, block]
                    quiet = 0.0
                else:
                    pre.append(block)
                continue
            burst.append(block)
            quiet = quiet + 0.1 if not loud else 0.0
            seconds = len(burst) * 0.1
            if quiet >= END_SILENCE or seconds >= MAX_BURST:
                audio = np.concatenate(burst)
                burst, quiet = [], 0.0
                pre.clear()
                if seconds < 0.4 or seconds >= MAX_BURST:
                    continue  # a click, or a long stretch of conversation
                self._check(audio)

    def _check(self, audio: np.ndarray) -> None:
        self.checks += 1
        head = self.transcribe(audio[: int(RATE * CHECK_SECONDS)], "Hey Compii.")
        heard, _ = match_wake(head)
        if not heard:
            return
        # Read the whole burst: the request may follow the wake phrase.
        full = self.transcribe(audio, "Hey Compii.") if audio.size > RATE * CHECK_SECONDS else head
        _, after = match_wake(full)
        if len(after.split()) >= 2:
            self.on_command(after)
            return
        self.on_wake()
        command = self._listen_for_command()
        if command:
            self.on_command(command)

    def _listen_for_command(self) -> str:
        """After "Yes?": record until the user stops talking."""
        with self._have:
            self._blocks.clear()
        chunks: list[np.ndarray] = []
        started = time.monotonic()
        spoke = False
        quiet = 0.0
        while not self._stop.is_set():
            block = self._next()
            if block is None:
                continue
            if self.paused():  # Compii's own "Yes?" is playing; don't record it
                started = time.monotonic()
                continue
            level = float(np.sqrt(np.mean(block * block)))
            if self.on_level:
                self.on_level(min(1.0, level * 8))
            loud = level > 0.012
            if loud:
                spoke = True
                quiet = 0.0
            elif spoke:
                quiet += 0.1
            if spoke:
                chunks.append(block)
            waited = time.monotonic() - started
            if (spoke and quiet >= COMMAND_SILENCE) or waited >= COMMAND_MAX or (not spoke and waited >= COMMAND_WAIT):
                break
        if not chunks:
            return ""
        return self.transcribe(np.concatenate(chunks), "").strip()
