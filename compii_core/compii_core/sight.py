"""Compii's eyes: one switch for every way it can look at the screen, and a signal when it does.

Nothing reads the desktop except inside `look()`, so the "Compii is seeing your screen" light in
the app can't lie, and turning the switch off really does stop every read - labels, pictures,
pointing, watching and the phone's glance at the PC alike.
"""
from __future__ import annotations

import threading
import time
from contextlib import contextmanager
from typing import Any, Callable, Iterator

REFUSAL = ("Compii isn't looking at your screen: screen reading is turned off (Settings, under "
           "Compii). Turn it back on if you want help with what's in front of you.")

# How long the light stays on after the last read. Compii looks many times a second while it
# watches a step, and a light that flickered with each look would say nothing at all - so this
# outlasts the gap between two of those looks (the coach ticks every 1.2 s) and only goes off once
# nothing has been read for a while. Turning the switch off clears it at once.
SETTLE_SECONDS = 2.0

_lock = threading.Lock()
_enabled = True
_reads = 0  # looks in flight right now
_lit = False  # what the app's light was told last: only real changes are published
_total = 0  # looks since Compii started
_last_at = 0.0  # when it last looked
_off_timer: threading.Timer | None = None
_watchers: list[Callable[[dict[str, Any]], None]] = []


def enabled() -> bool:
    with _lock:
        return _enabled


def set_enabled(flag: bool) -> dict[str, Any]:
    """Turn screen reading on or off. A look already in flight finishes; nothing new starts."""
    global _enabled, _reads, _lit, _off_timer
    with _lock:
        _enabled = bool(flag)
        if not _enabled:
            _reads = 0
            if _off_timer is not None:
                _off_timer.cancel()
                _off_timer = None
        _lit = False
        state = {"screen_aware": _enabled, "looking": _reads > 0}
    _publish({"type": "voice_sight", **state})
    return status()


def refusal() -> str:
    return REFUSAL


def on_change(watcher: Callable[[dict[str, Any]], None]) -> Callable[[], None]:
    """Hear about the switch changing, and about Compii starting or stopping a look.
    Returns the one call that stops listening again."""
    _watchers.append(watcher)

    def stop() -> None:
        if watcher in _watchers:
            _watchers.remove(watcher)

    return stop


def status() -> dict[str, Any]:
    with _lock:
        return {"screen_aware": _enabled, "looking": _reads > 0, "reads": _total,
                "last_seen": _last_at or None}


def _publish(event: dict[str, Any]) -> None:
    for watcher in list(_watchers):
        try:
            watcher(event)
        except Exception:  # noqa: BLE001 - an indicator must never break a look
            pass


def _settled() -> None:
    """Called SETTLE_SECONDS after the last look ends, if nothing has started meanwhile."""
    global _lit, _off_timer
    with _lock:
        _off_timer = None
        if _reads or not _lit:
            return
        _lit = False
    _publish({"type": "voice_sight", "screen_aware": _enabled, "looking": False})


@contextmanager
def look(kind: str) -> Iterator[None]:
    """Mark one stretch of reading the screen, so the user's indicator says exactly that."""
    global _reads, _lit, _total, _last_at, _off_timer
    with _lock:
        _reads += 1
        _total += 1
        _last_at = time.time()
        began = _reads == 1 and not _lit
        if began:
            _lit = True
        if _off_timer is not None:
            _off_timer.cancel()
            _off_timer = None
    if began:
        _publish({"type": "voice_sight", "screen_aware": True, "looking": True, "kind": kind})
    try:
        yield
    finally:
        with _lock:
            _reads = max(0, _reads - 1)
            quiet = _reads == 0
            if quiet and _off_timer is None:
                _off_timer = threading.Timer(SETTLE_SECONDS, _settled)
                _off_timer.daemon = True
                _off_timer.start()
