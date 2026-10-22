"""Screen Timeline: a quiet, searchable memory of what was on screen.

While the user has it on, Compii notes the window in front, reads its words with the
OCR engine Windows already has, and keeps a small picture of it - all in one local
database. That makes "what was that error at 3pm?" and "which page was I on yesterday?"
answerable. It is off until the user turns it on, it pauses whenever screen reading is
off, it skips password managers and private browsing windows, and old moments are
pruned after the retention the user chose.
"""

from __future__ import annotations

import json
import math
import re
import sqlite3
import sys
import threading
import time
from dataclasses import asdict, dataclass, fields
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

SCREEN_WIDTH = 1600  # OCR and the stored picture are scaled to this width
THUMB_WIDTH = 360
TEXT_CHARS = 12_000
MAX_ROWS = 60_000
PRUNE_SECONDS = 600
# Windows that show things the user expects to stay unrecorded.
PRIVATE_TITLES = ("incognito", "inprivate", "private browsing", "private window", "private mode")
DEFAULT_EVERY = 30
DEFAULT_KEEP_DAYS = 3
DEFAULT_MAX_MB = 200


@dataclass
class Settings:
    enabled: bool = False
    every_seconds: int = DEFAULT_EVERY
    keep_days: float = DEFAULT_KEEP_DAYS
    max_mb: int = DEFAULT_MAX_MB
    pictures: bool = True

    def __post_init__(self) -> None:
        self.enabled = bool(self.enabled)
        self.every_seconds = min(600, max(10, int(self.every_seconds)))
        self.keep_days = min(90.0, max(1.0, float(self.keep_days)))
        self.max_mb = min(5000, max(50, int(self.max_mb)))
        self.pictures = bool(self.pictures)

    @classmethod
    def load(cls, path: Path) -> "Settings":
        if not path.exists():
            return cls()
        try:
            raw = json.loads(path.read_text(encoding="utf-8-sig"))
            known = {f.name for f in fields(cls)}
            return cls(**{k: v for k, v in raw.items() if k in known})
        except (OSError, ValueError, TypeError):
            return cls()

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(asdict(self), indent=1), encoding="utf-8")
        tmp.replace(path)


class Timeline:
    """The recorder and its local store. `capture` is injectable for tests and rehearsal."""

    def __init__(self, path: Path, settings_path: Path, capture: Callable[[], dict[str, Any] | None] | None = None,
                 clock: Callable[[], float] = time.time, allow: Callable[[], bool] | None = None,
                 background: bool = True) -> None:
        self.path = path
        self.settings_path = settings_path
        self.settings = Settings.load(settings_path)
        self._clock = clock
        self._capture = capture or self._capture_screen
        self._allow = allow or _sight_allows
        self._background = background
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._last_thumb: tuple[int, str] | None = None
        self._last_prune = 0.0
        path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    # ---- storage -----------------------------------------------------------

    def _db(self) -> sqlite3.Connection:
        con = sqlite3.connect(self.path, timeout=10)
        con.execute("PRAGMA foreign_keys=ON")
        return con

    def _init_db(self) -> None:
        with self._lock:
            con = self._db()
            try:
                con.executescript("""
                    CREATE TABLE IF NOT EXISTS thumbs (
                        id INTEGER PRIMARY KEY,
                        png BLOB NOT NULL,
                        hash TEXT NOT NULL DEFAULT '',
                        at REAL NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS moments (
                        id INTEGER PRIMARY KEY,
                        started REAL NOT NULL,
                        ended REAL NOT NULL,
                        app TEXT NOT NULL DEFAULT '',
                        title TEXT NOT NULL DEFAULT '',
                        text TEXT NOT NULL DEFAULT '',
                        thumb_id INTEGER REFERENCES thumbs(id) ON DELETE SET NULL
                    );
                    CREATE INDEX IF NOT EXISTS moments_started ON moments(started);
                    CREATE INDEX IF NOT EXISTS moments_ended ON moments(ended);
                """)
                con.commit()
                self._reload_thumb(con)
            finally:
                con.close()

    def _reload_thumb(self, con: sqlite3.Connection) -> None:
        last = con.execute("SELECT id, hash FROM thumbs ORDER BY id DESC LIMIT 1").fetchone()
        self._last_thumb = (last[0], last[1]) if last else None

    # ---- recording ---------------------------------------------------------

    def capture_once(self) -> dict[str, Any] | None:
        """Look at the screen once and remember it, if it is allowed and changed."""
        if not self.settings.enabled or not self._allow():
            return None
        try:
            sample = self._capture()
        except Exception:  # noqa: BLE001 - a failed look is simply no moment
            return None
        if not sample:
            return None
        app = str(sample.get("app") or "").strip()[:120]
        title = " ".join(str(sample.get("title") or "").split())[:300]
        if not title or _private(app, title):
            return None
        text = _clean_text(str(sample.get("text") or ""))[:TEXT_CHARS]
        now = self._clock()
        thumb = self._make_thumb(sample.get("pixels")) if self.settings.pictures else None
        with self._lock:
            con = self._db()
            try:
                last = con.execute(
                    "SELECT id, app, title, text, thumb_id, ended FROM moments ORDER BY ended DESC, id DESC LIMIT 1"
                ).fetchone()
                same_window = bool(last and last[1] == app and last[2] == title)
                same_moment = bool(same_window and _same_text(last[3], text))
                thumb_id = last[4] if last else None
                if thumb is not None:
                    png, digest = thumb
                    reuse = same_window and thumb_id is not None and _hamming(self._last_thumb, digest) <= 8
                    if not reuse:
                        thumb_id = con.execute(
                            "INSERT INTO thumbs (png, hash, at) VALUES (?, ?, ?)", (png, digest, now)
                        ).lastrowid
                        self._last_thumb = (thumb_id, digest)
                if same_moment:
                    con.execute("UPDATE moments SET ended = ?, thumb_id = COALESCE(?, thumb_id) WHERE id = ?",
                                (now, thumb_id, last[0]))
                    con.commit()
                    moment_id, fresh = last[0], False
                else:
                    moment_id = con.execute(
                        "INSERT INTO moments (started, ended, app, title, text, thumb_id) VALUES (?, ?, ?, ?, ?, ?)",
                        (now, now, app, title, text, thumb_id),
                    ).lastrowid
                    con.commit()
                    fresh = True
                if con.execute("SELECT COUNT(*) FROM moments").fetchone()[0] > MAX_ROWS:
                    con.execute("DELETE FROM moments WHERE id IN (SELECT id FROM moments ORDER BY started LIMIT 2000)")
                    con.commit()
            finally:
                con.close()
        if now - self._last_prune > PRUNE_SECONDS:
            self.prune()
        return {"id": moment_id, "new": fresh, "app": app, "title": title, "text": text}

    def _capture_screen(self) -> dict[str, Any] | None:
        """The real thing: the window in front, its OCR words, and its pixels."""
        if sys.platform != "win32":
            return None
        from . import ocr, screen, vision

        hwnd, title = screen.user_foreground()
        if not hwnd or not title:
            return None
        app = _app_name(hwnd)
        if _private(app, title):
            return None
        shot = vision.grab_foreground(hwnd)
        if shot is None:
            return {"app": app, "title": title, "text": "", "pixels": None}
        pixels, _rect = shot
        step = max(1, -(-pixels.shape[1] // SCREEN_WIDTH))
        small = pixels[::step, ::step]
        text = ocr.read_png(vision.encode_png(small))
        if len(text.strip()) < 80:  # drawn apps and blank pictures: the app's own labels fill in
            text = _uia_text() or text
        return {"app": app, "title": title, "text": text, "pixels": pixels}

    def _make_thumb(self, pixels: Any) -> tuple[bytes, str] | None:
        if pixels is None:
            return None
        try:
            import numpy as np

            from . import vision

            h, w = pixels.shape[:2]
            if h < 8 or w < 8:
                return None
            step = max(1, -(-w // THUMB_WIDTH))
            small = np.ascontiguousarray(pixels[::step, ::step])
            return vision.encode_png(small), _ahash(small)
        except Exception:  # noqa: BLE001 - a picture is a nice extra, never the point
            return None

    # ---- background loop ---------------------------------------------------

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self.prune()
        self._thread = threading.Thread(target=self._loop, name="compii-timeline", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=3)
            self._thread = None

    def _loop(self) -> None:
        while not self._stop.is_set():
            if self.settings.enabled and self._allow():
                try:
                    self.capture_once()
                except Exception:  # noqa: BLE001 - the next quiet look can still work
                    pass
            wait = max(5, self.settings.every_seconds) if self.settings.enabled else 2
            self._wake.wait(wait)
            self._wake.clear()

    def update(self, **changes: Any) -> dict[str, Any]:
        s = self.settings
        if changes.get("enabled") is not None:
            s.enabled = bool(changes["enabled"])
        if changes.get("every_seconds") is not None:
            s.every_seconds = min(600, max(10, int(changes["every_seconds"])))
        if changes.get("keep_days") is not None:
            s.keep_days = min(90.0, max(1.0, float(changes["keep_days"])))
        if changes.get("max_mb") is not None:
            s.max_mb = min(5000, max(50, int(changes["max_mb"])))
        if changes.get("pictures") is not None:
            s.pictures = bool(changes["pictures"])
        s.save(self.settings_path)
        self._wake.set()
        if s.enabled and self._background:
            self.start()
        self.prune()
        return self.status()

    # ---- searching ---------------------------------------------------------

    def search(self, query: str = "", after: float | None = None, before: float | None = None,
               app: str = "", limit: int = 50, full: bool = False) -> list[dict[str, Any]]:
        where: list[str] = []
        params: list[Any] = []
        if after is not None:
            where.append("ended >= ?")
            params.append(after)
        if before is not None:
            where.append("started <= ?")
            params.append(before)
        if app.strip():
            where.append("app LIKE ? ESCAPE '\\'")
            params.append(f"%{_like(app.strip())}%")
        terms = [t for t in re.split(r"\s+", query.strip()) if t][:8]
        for term in terms:
            pattern = f"%{_like(term)}%"
            where.append("(app LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\' OR text LIKE ? ESCAPE '\\')")
            params.extend([pattern, pattern, pattern])
        sql = ("SELECT id, started, ended, app, title, text, thumb_id FROM moments"
               + (" WHERE " + " AND ".join(where) if where else "")
               + " ORDER BY started DESC LIMIT ?")
        params.append(min(200, max(1, int(limit))))
        with self._lock:
            con = self._db()
            try:
                rows = con.execute(sql, params).fetchall()
            finally:
                con.close()
        return [{"id": r[0], "started": r[1], "ended": r[2], "app": r[3], "title": r[4],
                 "excerpt": _excerpt(r[5], terms), "text": r[5][:12_000 if full else 2_000],
                 "has_picture": r[6] is not None} for r in rows]

    def moment(self, moment_id: int) -> dict[str, Any] | None:
        with self._lock:
            con = self._db()
            try:
                r = con.execute("SELECT id, started, ended, app, title, text, thumb_id FROM moments WHERE id = ?",
                                (moment_id,)).fetchone()
            finally:
                con.close()
        if r is None:
            return None
        return {"id": r[0], "started": r[1], "ended": r[2], "app": r[3], "title": r[4], "text": r[5],
                "has_picture": r[6] is not None}

    def picture(self, moment_id: int) -> bytes | None:
        with self._lock:
            con = self._db()
            try:
                r = con.execute("SELECT t.png FROM moments m JOIN thumbs t ON t.id = m.thumb_id WHERE m.id = ?",
                                (moment_id,)).fetchone()
            finally:
                con.close()
        return bytes(r[0]) if r else None

    def status(self) -> dict[str, Any]:
        with self._lock:
            con = self._db()
            try:
                count, oldest, newest = con.execute(
                    "SELECT COUNT(*), MIN(started), MAX(started) FROM moments").fetchone()
            finally:
                con.close()
        paused = self.settings.enabled and not self._allow()
        reason = ""
        if not self.settings.enabled:
            reason = "Screen timeline is off."
        elif paused:
            reason = "Screen reading is off, so nothing is being remembered."
        from . import ocr

        return {**asdict(self.settings), "moments": count, "oldest": oldest, "newest": newest,
                "megabytes": round(self.path.stat().st_size / 1_000_000, 1) if self.path.exists() else 0.0,
                "paused": paused, "reason": reason, "ocr": "ready" if ocr.available() else "unavailable",
                "recording": self._thread is not None and self._thread.is_alive()}

    # ---- forgetting --------------------------------------------------------

    def forget(self, hours: float = 0.0, everything: bool = False) -> int:
        """Delete recorded moments: everything, or those that overlap the last `hours`."""
        with self._lock:
            con = self._db()
            try:
                if everything:
                    deleted = con.execute("DELETE FROM moments").rowcount
                elif hours > 0:
                    deleted = con.execute("DELETE FROM moments WHERE ended >= ?",
                                          (self._clock() - hours * 3600,)).rowcount
                else:
                    deleted = 0
                self._orphans(con)
                con.commit()
                if deleted:
                    con.execute("VACUUM")
                self._reload_thumb(con)
            finally:
                con.close()
        return deleted

    def forget_moment(self, moment_id: int) -> bool:
        """Delete one moment the user pointed at, with its picture if nothing else uses it."""
        with self._lock:
            con = self._db()
            try:
                deleted = con.execute("DELETE FROM moments WHERE id = ?", (moment_id,)).rowcount
                if deleted:
                    self._orphans(con)
                    con.commit()
                    con.execute("VACUUM")
                    self._reload_thumb(con)
                return bool(deleted)
            finally:
                con.close()

    def prune(self) -> int:
        """Forget moments older than the retention, then trim the store to its size cap."""
        now = self._clock()
        cutoff = now - max(1.0, self.settings.keep_days) * 86400
        deleted = 0
        with self._lock:
            con = self._db()
            try:
                deleted = con.execute("DELETE FROM moments WHERE ended < ?", (cutoff,)).rowcount
                limit = max(50, self.settings.max_mb) * 1_000_000
                while self.path.exists() and self.path.stat().st_size > limit:
                    rows = con.execute("SELECT id FROM moments ORDER BY started LIMIT 2000").fetchall()
                    if not rows:
                        break
                    con.executemany("DELETE FROM moments WHERE id = ?", rows)
                    deleted += len(rows)
                    con.commit()
                    con.execute("VACUUM")
                self._orphans(con)
                con.commit()
                if deleted > 20:
                    con.execute("VACUUM")
                if deleted:
                    self._reload_thumb(con)
            finally:
                con.close()
        self._last_prune = now
        return deleted

    @staticmethod
    def _orphans(con: sqlite3.Connection) -> None:
        con.execute("DELETE FROM thumbs WHERE id NOT IN (SELECT thumb_id FROM moments WHERE thumb_id IS NOT NULL)")


# ---- helpers ---------------------------------------------------------------

def _sight_allows() -> bool:
    from . import sight

    return sight.enabled()


def _app_name(hwnd: int) -> str:
    import ctypes

    from . import screen

    pid = ctypes.c_ulong()
    try:
        ctypes.windll.user32.GetWindowThreadProcessId(ctypes.c_void_p(hwnd), ctypes.byref(pid))
        return screen._process_name(pid.value)
    except Exception:  # noqa: BLE001
        return ""


def _uia_text() -> str:
    """The labels and values the window itself reports, for when a picture has little text."""
    from . import screen

    try:
        snap = screen.snapshot_foreground()
    except Exception:  # noqa: BLE001
        return ""
    if not snap or snap.get("blocked"):
        return ""
    lines = []
    for e in snap.get("elements", []):
        name = str(e.get("name") or "").strip()
        value = str(e.get("value") or "").strip()
        if name and name != "(no label)":
            lines.append(name)
        if value and value not in (name, "a password field — not read"):
            lines.append(value)
    return "\n".join(lines)


def _private(app: str, title: str) -> bool:
    from .screen import BLOCKED_APPS

    hay = f"{app} {title}".lower()
    return (any(b in hay for b in BLOCKED_APPS) or any(p in title.lower() for p in PRIVATE_TITLES)
            or "compii" in title.lower())


def _clean_text(text: str) -> str:
    text = text.replace("\x00", " ")
    text = re.sub(r"[\x01-\x08\x0b\x0c\x0e-\x1f]", " ", text)
    lines = [" ".join(line.split()) for line in text.splitlines()]
    return "\n".join(line for line in lines if line).strip()


def _same_text(a: str, b: str) -> bool:
    return " ".join(a.lower().split()) == " ".join(b.lower().split())


def _ahash(pixels: Any) -> str:
    """A 64-bit average hash: two pictures that look alike get nearly the same string."""
    import numpy as np

    h, w = pixels.shape[:2]
    ys = np.linspace(0, h - 1, 8).astype(int)
    xs = np.linspace(0, w - 1, 8).astype(int)
    grey = pixels[ys][:, xs, :3].mean(axis=2)
    return "".join("1" if bit else "0" for bit in (grey > grey.mean()).flatten())


def _hamming(last: tuple[int, str] | None, digest: str) -> int:
    if last is None or len(last[1]) != len(digest):
        return 64
    return sum(a != b for a, b in zip(last[1], digest))


def _like(term: str) -> str:
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _excerpt(text: str, terms: list[str], width: int = 240) -> str:
    flat = " ".join((text or "").split())
    if not flat:
        return ""
    lower = flat.lower()
    spots = [lower.find(t.lower()) for t in terms if t and t.lower() in lower]
    if not spots:
        return flat[:width] + ("…" if len(flat) > width else "")
    start = max(0, min(spots) - width // 3)
    end = min(len(flat), start + width)
    return ("…" if start else "") + flat[start:end] + ("…" if end < len(flat) else "")


def _when(value: Any) -> float | None:
    """A date, date-time or unix time from a tool argument, in local time."""
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        pass
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _span(start: float, end: float, now: float | None = None) -> str:
    now = now or time.time()
    a, b = datetime.fromtimestamp(start), datetime.fromtimestamp(end)
    today = datetime.fromtimestamp(now).date()
    if a.date() == today:
        day = "Today"
    elif a.date() == today - timedelta(days=1):
        day = "Yesterday"
    else:
        day = a.strftime("%a %d %b")
    same_minute = a.strftime("%H:%M") == b.strftime("%H:%M")
    return f"{day} {a:%H:%M}" + ("" if same_minute else f"–{b:%H:%M}")


def timeline_tools(timeline: Timeline) -> list[Tool]:
    s = {"type": "string"}

    def search(a: dict[str, Any]) -> ToolResult:
        after = _when(a.get("after"))
        if a.get("hours") and after is None:
            after = time.time() - max(0.0, float(a["hours"])) * 3600
        before = _when(a.get("before"))
        rows = timeline.search(str(a.get("query") or ""), after=after, before=before,
                               app=str(a.get("app") or ""), limit=int(a.get("limit") or 20))
        if not rows:
            if not timeline.settings.enabled:
                raise ToolError("Screen timeline is off, so nothing has been remembered yet. The user can turn it "
                                "on in Settings; it records only from then on and never looks back.")
            return ToolResult("Nothing in screen memory matches that. " + (
                "It has only been on since it was turned on, so older screens aren't there."
                if timeline.status()["moments"] < 20 else "Try fewer or different words, or a wider time."))
        lines = [f"- {_span(r['started'], r['ended'])} · {r['app'] or 'an app'} · “{r['title']}”"
                 + (f"\n  {r['excerpt']}" if r["excerpt"] else "") for r in rows]
        return ToolResult(f"From screen memory (recorded on this PC only), newest first:\n" + "\n".join(lines))

    def forget(a: dict[str, Any]) -> ToolResult:
        scope = str(a.get("scope") or "").strip().lower()
        if scope == "all":
            deleted = timeline.forget(everything=True)
        elif scope in ("hour", "day", "week"):
            deleted = timeline.forget(hours={"hour": 1, "day": 24, "week": 168}[scope])
        else:
            raise ToolError("Choose what to forget: all, hour, day or week.")
        return ToolResult(f"Deleted {deleted} moment(s) from screen memory." if deleted
                          else "There was nothing in that range to delete.")

    return [
        Tool("search_screen_memory",
             "Search the user's own screen timeline: what was on screen at a time, or which page had some words. "
             "Only what was recorded while the user had Screen timeline on. Use it for questions like 'what was that "
             "error at 3pm?', 'which tab had the invoice?', 'what was I doing yesterday morning?'.",
             {"query": {**s, "description": "Words to look for in the window title, app name or on-screen text. "
                                            "Leave empty to browse a time range."},
              "after": {**s, "description": "Only moments at or after this local date/time, ISO, e.g. 2026-10-21T15:00."},
              "before": {**s, "description": "Only moments at or before this local date/time, ISO."},
              "hours": {"type": "number", "description": "Or: how many hours back to look (default all retained)."},
              "app": {**s, "description": "Only this app, e.g. chrome or winword."},
              "limit": {"type": "integer", "description": "How many moments to return (default 20, max 200)."}},
             ["query"], ActionKind.READ, search,
             lambda a: f"Search screen memory for “{a.get('query', '')}”"),
        Tool("forget_screen_memory",
             "Delete moments from the user's screen timeline. Ask the user how much to forget before calling.",
             {"scope": {"type": "string", "enum": ["all", "hour", "day", "week"],
                        "description": "all history, or the last hour, day or week."}},
             ["scope"], ActionKind.DELETE, forget, lambda a: f"Forget screen memory ({a.get('scope')})"),
    ]
