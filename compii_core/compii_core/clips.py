"""Clipboard history and snippets: what you copied recently, and text you reuse.

The history is a private, local list of the last things copied on this PC. It is off
until the user turns it on, it skips whatever a password manager or a private window
copied — judged by the window that set the data, not the one in front a moment later —
and it prunes itself. Snippets are named blocks of text
the user saves on purpose (a signature, an address, a reply they send often); they are
available whether or not the history is on, and copy with one click.
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import sys
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from typing import Any, Callable

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

POLL_SECONDS = 0.8
MAX_TEXT = 100_000
PREVIEW = 500
PRUNE_SECONDS = 3600
DEFAULT_KEEP_DAYS = 7
DEFAULT_MAX_ITEMS = 500
CF_UNICODETEXT = 13


# ---- talking to Windows -------------------------------------------------------


def _clipboard_api() -> Any:
    """user32/kernel32 with 64-bit-safe signatures, or None where there is no clipboard."""
    if sys.platform != "win32":
        return None
    import ctypes
    from ctypes import wintypes

    user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.OpenClipboard.restype = wintypes.BOOL
    user32.GetClipboardData.argtypes = [wintypes.UINT]
    user32.GetClipboardData.restype = wintypes.HANDLE
    user32.CloseClipboard.restype = wintypes.BOOL
    user32.GetClipboardSequenceNumber.restype = wintypes.DWORD
    kernel32.GlobalLock.argtypes = [wintypes.HANDLE]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [wintypes.HANDLE]
    return user32, kernel32


def clipboard_sequence() -> int:
    """Changes whenever anything is copied, without reading what it is."""
    api = _clipboard_api()
    return int(api[0].GetClipboardSequenceNumber()) if api else 0


def read_clipboard() -> str:
    """The text on the Windows clipboard, or "" when it holds no text."""
    api = _clipboard_api()
    if api is None:
        return ""
    user32, kernel32 = api
    if not user32.OpenClipboard(None):
        return ""
    try:
        handle = user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return ""
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            return ""
        try:
            import ctypes

            return ctypes.wstring_at(pointer) or ""
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


def write_clipboard(text: str) -> None:
    """Put text on the clipboard. It travels in an environment variable, never in the
    command line, so quotes and newlines in it can't change what the command does."""
    if sys.platform != "win32":
        raise ToolError("Compii puts text on the clipboard on Windows only.")
    from .tools import _powershell

    try:
        _powershell("Set-Clipboard -Value $env:COMPII_CLIPBOARD_TEXT", {"COMPII_CLIPBOARD_TEXT": text[:MAX_TEXT]})
    except ToolError as e:
        raise ToolError(f"Windows would not put that on the clipboard: {e}") from e


def _foreground_source() -> tuple[str, str]:
    """The app and window the user is in when a copy happens, for the history label."""
    if sys.platform != "win32":
        return "", ""
    try:
        import ctypes

        from . import screen

        hwnd, title = screen.user_foreground()
        if not hwnd:
            return "", ""
        pid = ctypes.c_ulong()
        ctypes.windll.user32.GetWindowThreadProcessId(ctypes.c_void_p(hwnd), ctypes.byref(pid))
        return screen._process_name(pid.value), title[:300]
    except Exception:  # noqa: BLE001 - a missing label is harmless
        return "", ""


def _clipboard_owner_source() -> tuple[str, str]:
    """The app that actually put something on the clipboard, by the window that set it.

    The watcher only notices a copy up to a poll later, and by then the user has usually
    tabbed away — judging privacy by the window in front would then read a password manager's
    code as copied from the chat. Windows remembers who set the data, so ask it instead.
    """
    if sys.platform != "win32":
        return "", ""
    try:
        import ctypes
        from ctypes import wintypes

        from . import screen

        user32 = ctypes.windll.user32
        user32.GetClipboardOwner.restype = wintypes.HWND
        hwnd = user32.GetClipboardOwner()
        if not hwnd:
            return "", ""
        buf = ctypes.create_unicode_buffer(520)
        user32.GetWindowTextW(ctypes.c_void_p(int(hwnd)), buf, 519)
        pid = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(ctypes.c_void_p(int(hwnd)), ctypes.byref(pid))
        return screen._process_name(pid.value), buf.value[:300]
    except Exception:  # noqa: BLE001 - no owner means nothing extra to go on
        return "", ""


# ---- settings -----------------------------------------------------------------


@dataclass
class Settings:
    enabled: bool = False
    keep_days: float = DEFAULT_KEEP_DAYS
    max_items: int = DEFAULT_MAX_ITEMS

    def __post_init__(self) -> None:
        self.enabled = bool(self.enabled)
        self.keep_days = min(90.0, max(1.0, float(self.keep_days)))
        self.max_items = min(5000, max(50, int(self.max_items)))

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


# ---- snippets -----------------------------------------------------------------


@dataclass
class Snippet:
    name: str
    body: str
    id: str = field(default_factory=lambda: "n" + uuid.uuid4().hex[:8])
    created: float = field(default_factory=time.time)
    uses: int = 0
    last_used: float | None = None


class Snippets:
    """Named text the user saves deliberately. Small, so a JSON file is enough."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self.items: dict[str, Snippet] = {}
        if path.exists():
            try:
                for d in json.loads(path.read_text(encoding="utf-8-sig")):
                    self.items[d["id"]] = Snippet(**d)
            except (ValueError, TypeError, KeyError):
                path.replace(path.with_suffix(f".broken-{int(time.time())}.json"))

    def save(self) -> None:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps([asdict(s) for s in self.items.values()], indent=1, ensure_ascii=False),
                           encoding="utf-8")
            tmp.replace(self.path)

    def named(self, name: str) -> Snippet | None:
        want = name.strip().lower()
        return next((s for s in self.items.values() if s.name.lower() == want), None)

    def find(self, name: str) -> Snippet | None:
        want = name.strip().lower()
        found = self.named(want)
        if found:
            return found
        for s in self.items.values():
            if want and (want in s.name.lower() or s.name.lower() in want):
                return s
        return None

    def add(self, name: str, body: str, replace: bool = False) -> Snippet:
        name, body = " ".join(name.split())[:60], body.strip()[:MAX_TEXT]
        if not name or not body:
            raise ValueError("A snippet needs a name and some text.")
        old = self.named(name)
        if old:
            if not replace:
                raise ValueError(f"There's already a snippet called “{old.name}”.")
            self.items.pop(old.id)
        snippet = Snippet(name, body)
        self.items[snippet.id] = snippet
        self.save()
        return snippet

    def update(self, snippet_id: str, name: str | None = None, body: str | None = None) -> Snippet:
        snippet = self.items.get(snippet_id)
        if snippet is None:
            raise KeyError(snippet_id)
        if name is not None:
            clean = " ".join(name.split())[:60]
            if not clean:
                raise ValueError("A snippet needs a name.")
            other = self.named(clean)
            if other and other.id != snippet.id:
                raise ValueError(f"There's already a snippet called “{other.name}”.")
            snippet.name = clean
        if body is not None:
            clean_body = body.strip()[:MAX_TEXT]
            if not clean_body:
                raise ValueError("A snippet needs some text.")
            snippet.body = clean_body
        self.save()
        return snippet

    def remove(self, snippet_id: str) -> bool:
        if self.items.pop(snippet_id, None) is None:
            return False
        self.save()
        return True

    def used(self, snippet: Snippet) -> None:
        snippet.uses += 1
        snippet.last_used = time.time()
        self.save()

    def search(self, query: str = "") -> list[dict[str, Any]]:
        terms = [t.lower() for t in query.split() if t][:6]
        rows = [asdict(s) for s in self.items.values()
                if all(t in f"{s.name} {s.body}".lower() for t in terms)]
        return sorted(rows, key=lambda s: s["name"].lower())

    def view(self) -> list[dict[str, Any]]:
        return [asdict(s) for s in sorted(self.items.values(), key=lambda s: s.name.lower())]

    def context(self) -> str:
        if not self.items:
            return ""
        names = ", ".join(f"“{s.name}”" for s in list(self.items.values())[:25])
        return (f"Saved snippets (text the user reuses): {names}. When one fits, call use_snippet to copy it "
                "for them rather than retyping it.")


# ---- history ------------------------------------------------------------------


class Clips:
    """The watcher and its local store. `reader`, `source`, `sequence` and `owner` are injectable."""

    def __init__(self, path: Path, settings_path: Path, snippets_path: Path,
                 reader: Callable[[], str] | None = None, source: Callable[[], tuple[str, str]] | None = None,
                 sequence: Callable[[], int] | None = None,
                 owner: Callable[[], tuple[str, str]] | None = None,
                 clock: Callable[[], float] = time.time,
                 background: bool = True) -> None:
        self.path = path
        self.settings_path = settings_path
        self.settings = Settings.load(settings_path)
        self.snippets = Snippets(snippets_path)
        self._read = reader or read_clipboard
        self._source = source or _foreground_source
        self._sequence = sequence or clipboard_sequence
        self._owner = owner or _clipboard_owner_source
        self._clock = clock
        self._background = background
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._last_seq = 0
        self._last_text: str | None = None
        self._last_prune = 0.0
        path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _db(self) -> sqlite3.Connection:
        return sqlite3.connect(self.path, timeout=10)

    def _init_db(self) -> None:
        with self._lock:
            con = self._db()
            try:
                con.executescript("""
                    CREATE TABLE IF NOT EXISTS clips (
                        id INTEGER PRIMARY KEY,
                        text TEXT NOT NULL,
                        hash TEXT NOT NULL UNIQUE,
                        kind TEXT NOT NULL DEFAULT 'text',
                        app TEXT NOT NULL DEFAULT '',
                        title TEXT NOT NULL DEFAULT '',
                        at REAL NOT NULL,
                        copies INTEGER NOT NULL DEFAULT 1,
                        pinned INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE INDEX IF NOT EXISTS clips_at ON clips(at DESC);
                """)
                con.commit()
            finally:
                con.close()

    # ---- watching ----------------------------------------------------------

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._last_seq = self._sequence()
        self.prune()
        self._thread = threading.Thread(target=self._loop, name="compii-clips", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=3)
            self._thread = None

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                if self.settings.enabled:
                    seq = self._sequence()
                    # A zero sequence means Windows won't say; read and compare the text instead.
                    if not seq or seq != self._last_seq:
                        self._last_seq = seq
                        self.remember_once()
            except Exception:  # noqa: BLE001 - the next copy can still be caught
                pass
            self._wake.wait(POLL_SECONDS)
            self._wake.clear()

    def remember_once(self) -> dict[str, Any] | None:
        """Look at the clipboard once and remember it, unless it is private or unchanged."""
        if not self.settings.enabled:
            return None
        app, title = self._source()
        # The window in front is the wrong thing to judge a copy by: a poll notices it up to
        # POLL_SECONDS after the copy, and by then the user has tabbed away from the password
        # manager. Windows names the window that put the data there, and that window is what the
        # promise is about — and the honest label for the history entry.
        owner_app, owner_title = self._owner()
        if _private(app, title) or _private(owner_app, owner_title):
            return None  # never even read what a password manager copied
        app, title = owner_app or app, owner_title or title
        try:
            text = _clean(self._read())[:MAX_TEXT]
        except Exception:  # noqa: BLE001 - a failed read is simply no copy
            return None
        if not text.strip() or text == self._last_text:
            self._last_text = text
            return None
        self._last_text = text
        return self.remember_text(text, app=app, title=title)

    def remember_text(self, text: str, app: str = "", title: str = "") -> dict[str, Any] | None:
        """Add text to the history (phone sends, and the watcher). Dedupes by content."""
        if not self.settings.enabled:
            return None
        text = _clean(text)[:MAX_TEXT]
        if not text.strip():
            return None
        now = self._clock()
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        kind = _kind(text)
        with self._lock:
            con = self._db()
            try:
                old = con.execute("SELECT id, copies FROM clips WHERE hash = ?", (digest,)).fetchone()
                if old:
                    con.execute("UPDATE clips SET at = ?, copies = copies + 1, app = ?, title = ? WHERE id = ?",
                                (now, app[:120], title[:300], old[0]))
                    clip_id, fresh = old[0], False
                else:
                    clip_id = con.execute(
                        "INSERT INTO clips (text, hash, kind, app, title, at) VALUES (?, ?, ?, ?, ?, ?)",
                        (text, digest, kind, app[:120], title[:300], now)).lastrowid
                    fresh = True
                con.commit()
                over = con.execute("SELECT COUNT(*) FROM clips WHERE pinned = 0").fetchone()[0] - self.settings.max_items
                if over > 0:
                    con.execute("DELETE FROM clips WHERE pinned = 0 AND id IN "
                                "(SELECT id FROM clips WHERE pinned = 0 ORDER BY at LIMIT ?)", (over,))
                    con.commit()
            finally:
                con.close()
        if now - self._last_prune > PRUNE_SECONDS:
            self.prune()
        return {"id": clip_id, "new": fresh, "kind": kind, "app": app, "title": title}

    # ---- reading, pinning, forgetting --------------------------------------

    def search(self, query: str = "", limit: int = 100, pinned: bool | None = None) -> list[dict[str, Any]]:
        where: list[str] = []
        params: list[Any] = []
        for term in [t for t in re.split(r"\s+", query.strip()) if t][:8]:
            pattern = f"%{_like(term)}%"
            where.append("(text LIKE ? ESCAPE '\\' OR app LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')")
            params.extend([pattern, pattern, pattern])
        if pinned is not None:
            where.append("pinned = ?")
            params.append(1 if pinned else 0)
        sql = ("SELECT id, text, kind, app, title, at, copies, pinned FROM clips"
               + (" WHERE " + " AND ".join(where) if where else "")
               + " ORDER BY pinned DESC, at DESC LIMIT ?")
        params.append(min(500, max(1, int(limit))))
        with self._lock:
            con = self._db()
            try:
                rows = con.execute(sql, params).fetchall()
            finally:
                con.close()
        return [{"id": r[0], "preview": _preview(r[1]), "chars": len(r[1]), "kind": r[2], "app": r[3],
                 "title": r[4], "at": r[5], "copies": r[6], "pinned": bool(r[7])} for r in rows]

    def item(self, clip_id: int) -> dict[str, Any] | None:
        with self._lock:
            con = self._db()
            try:
                r = con.execute("SELECT id, text, kind, app, title, at, copies, pinned FROM clips WHERE id = ?",
                                (clip_id,)).fetchone()
            finally:
                con.close()
        if r is None:
            return None
        return {"id": r[0], "text": r[1], "kind": r[2], "app": r[3], "title": r[4],
                "at": r[5], "copies": r[6], "pinned": bool(r[7])}

    def pin(self, clip_id: int, pinned: bool = True) -> bool:
        with self._lock:
            con = self._db()
            try:
                changed = con.execute("UPDATE clips SET pinned = ? WHERE id = ?",
                                      (1 if pinned else 0, clip_id)).rowcount
                con.commit()
            finally:
                con.close()
        return changed > 0

    def forget(self, clip_id: int) -> bool:
        with self._lock:
            con = self._db()
            try:
                deleted = con.execute("DELETE FROM clips WHERE id = ?", (clip_id,)).rowcount
                con.commit()
            finally:
                con.close()
        return deleted > 0

    def forget_many(self, hours: float = 0.0, keep_pinned: bool = True) -> int:
        """Delete the last `hours` of copies (0 = all), leaving pinned ones unless told otherwise."""
        where, params = [], []
        if hours > 0:
            where.append("at >= ?")
            params.append(self._clock() - hours * 3600)
        if keep_pinned:
            where.append("pinned = 0")
        sql = "DELETE FROM clips" + (" WHERE " + " AND ".join(where) if where else "")
        with self._lock:
            con = self._db()
            try:
                deleted = con.execute(sql, params).rowcount
                con.commit()
            finally:
                con.close()
        return deleted

    def prune(self) -> int:
        """Drop old copies, then the oldest unpinned ones beyond the size the user chose."""
        cutoff = self._clock() - self.settings.keep_days * 86400
        with self._lock:
            con = self._db()
            try:
                deleted = con.execute("DELETE FROM clips WHERE pinned = 0 AND at < ?", (cutoff,)).rowcount
                extra = con.execute("SELECT COUNT(*) FROM clips WHERE pinned = 0").fetchone()[0]
                if extra > self.settings.max_items:
                    deleted += con.execute(
                        "DELETE FROM clips WHERE pinned = 0 AND id IN "
                        "(SELECT id FROM clips WHERE pinned = 0 ORDER BY at LIMIT ?)",
                        (extra - self.settings.max_items,)).rowcount
                con.commit()
                if deleted:
                    con.execute("VACUUM")
            finally:
                con.close()
        self._last_prune = self._clock()
        return deleted

    def status(self) -> dict[str, Any]:
        with self._lock:
            con = self._db()
            try:
                count, pinned, oldest, newest = con.execute(
                    "SELECT COUNT(*), COALESCE(SUM(pinned), 0), MIN(at), MAX(at) FROM clips").fetchone()
            finally:
                con.close()
        reason = "" if self.settings.enabled else "Clipboard history is off."
        if sys.platform != "win32":
            reason = reason or "Clipboard history works on Windows only."
        return {**asdict(self.settings), "items": count, "pinned": pinned, "oldest": oldest, "newest": newest,
                "megabytes": round(self.path.stat().st_size / 1_000_000, 1) if self.path.exists() else 0.0,
                "watching": sys.platform == "win32",
                "running": self._thread is not None and self._thread.is_alive(),
                "snippets": len(self.snippets.items), "reason": reason}

    def update(self, **changes: Any) -> dict[str, Any]:
        s = self.settings
        was_on = s.enabled
        if changes.get("enabled") is not None:
            s.enabled = bool(changes["enabled"])
        if changes.get("keep_days") is not None:
            s.keep_days = min(90.0, max(1.0, float(changes["keep_days"])))
        if changes.get("max_items") is not None:
            s.max_items = min(5000, max(50, int(changes["max_items"])))
        s.save(self.settings_path)
        if s.enabled and not was_on:
            # Only from now on: whatever was already on the clipboard is not history.
            self._last_seq = self._sequence()
            self._last_text = None
        self._wake.set()
        if s.enabled and self._background:
            self.start()
        self.prune()
        return self.status()


# ---- helpers ------------------------------------------------------------------


def _clean(text: str) -> str:
    text = (text or "").replace("\x00", " ")
    text = re.sub(r"[\x01-\x08\x0b\x0c\x0e-\x1f]", " ", text)
    return text.strip()


def _kind(text: str) -> str:
    flat = text.strip()
    if re.fullmatch(r"https?://\S+", flat):
        return "link"
    if "\n" in flat and re.search(r"[{};=>]|^\s{2,}\S", flat, re.M):
        return "code"
    return "text"


def _preview(text: str) -> str:
    flat = " ".join(text.split())
    return flat[:PREVIEW] + ("…" if len(flat) > PREVIEW else "")


def _like(term: str) -> str:
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _private(app: str, title: str) -> bool:
    from .screen import BLOCKED_APPS

    hay = f"{app} {title}".lower()
    return any(b in hay for b in BLOCKED_APPS) or any(p in title.lower() for p in (
        "incognito", "inprivate", "private browsing", "private window", "private mode"))


def _ago(when: float | None) -> str:
    if not when:
        return "just now"
    delta = max(0, time.time() - when)
    if delta < 90:
        return "just now"
    if delta < 3600:
        return f"{int(delta // 60)} min ago"
    if delta < 86400:
        return f"{int(delta // 3600)} h ago"
    return f"{int(delta // 86400)} d ago"


# ---- agent tools --------------------------------------------------------------


def clip_tools(clips: Clips) -> list[Tool]:
    s = {"type": "string"}

    def search(a: dict[str, Any]) -> ToolResult:
        rows = clips.search(str(a.get("query") or ""), limit=int(a.get("limit") or 20))
        if not rows:
            if not clips.settings.enabled and not clips.status()["items"]:
                raise ToolError("Clipboard history is off, so nothing has been kept. The user can turn it on in "
                                "the Clips page; it remembers copies only from then on.")
            return ToolResult("Nothing copied recently matches that. Try fewer or different words.")
        if not clips.settings.enabled:
            return ToolResult("Clipboard history is off now; only what was kept before is searchable. "
                              "Newest first:\n" + _clip_lines(rows))
        return ToolResult("From clipboard history on this PC, newest first:\n" + _clip_lines(rows))

    def list_snippets(_a: dict[str, Any]) -> ToolResult:
        rows = clips.snippets.view()
        if not rows:
            return ToolResult("No snippets saved yet.")
        return ToolResult("\n".join(f"- {r['name']} ({len(r['body'])} chars): {_preview(r['body'])[:120]}"
                                    for r in rows))

    def use_snippet(a: dict[str, Any]) -> ToolResult:
        snippet = clips.snippets.find(str(a.get("name") or ""))
        if snippet is None:
            raise ToolError(f"No saved snippet called “{a.get('name')}”. Use list_snippets to see them.")
        write_clipboard(snippet.body)
        clips.snippets.used(snippet)
        return ToolResult(f"Copied “{snippet.name}” to the clipboard ({len(snippet.body)} characters), ready to paste.")

    def save_snippet(a: dict[str, Any]) -> ToolResult:
        try:
            snippet = clips.snippets.add(str(a["name"]), str(a["body"]), replace=bool(a.get("replace")))
        except ValueError as e:
            raise ToolError(str(e)) from e
        return ToolResult(f"Saved the snippet “{snippet.name}” ({len(snippet.body)} characters).")

    def delete_snippet(a: dict[str, Any]) -> ToolResult:
        snippet = clips.snippets.find(str(a.get("name") or ""))
        if snippet is None:
            raise ToolError(f"No saved snippet called “{a.get('name')}”.")
        clips.snippets.remove(snippet.id)
        return ToolResult(f"Deleted the snippet “{snippet.name}”.")

    return [
        Tool("search_clips", "Search what the user copied recently (clipboard history on this PC): text, links, "
             "code, the app it came from. Use it for 'what did I copy earlier?', 'the link I copied yesterday'. "
             "Pinned copies are listed first.",
             {"query": {**s, "description": "Words to look for; leave empty to list the most recent copies."},
              "limit": {"type": "integer", "description": "How many copies to return (default 20, max 100)."}},
             ["query"], ActionKind.READ, search, lambda a: f"Search clipboard history for “{a.get('query', '')}”"),
        Tool("list_snippets", "List the text snippets the user saved to reuse (signatures, addresses, replies).",
             {}, [], ActionKind.READ, list_snippets, lambda a: "Look at saved snippets"),
        Tool("use_snippet", "Copy a saved snippet to the clipboard, ready to paste. Use this instead of retyping text "
             "the user already saved; find its name with list_snippets.",
             {"name": {**s, "description": "The snippet's name, e.g. 'Work signature'."}},
             ["name"], ActionKind.CHANGE, use_snippet, lambda a: f"Copy the snippet “{a.get('name')}”"),
        Tool("save_snippet", "Save a piece of text as a named snippet when the user asks to keep it for reuse "
             "(a signature, address, canned reply). Ask what to call it unless they said.",
             {"name": {**s, "description": "A short name the user chose or agreed to."},
              "body": {**s, "description": "The exact text to save."},
              "replace": {"type": "boolean", "description": "true only after the user agreed to replace a snippet with this name."}},
             ["name", "body"], ActionKind.CREATE, save_snippet, lambda a: f"Save the snippet “{a.get('name')}”"),
        Tool("delete_snippet", "Delete a saved snippet by name. Ask the user first.",
             {"name": s}, ["name"], ActionKind.DELETE, delete_snippet,
             lambda a: f"Delete the snippet “{a.get('name')}”"),
    ]


def _clip_lines(rows: list[dict[str, Any]]) -> str:
    return "\n".join(
        f"- {_ago(r['at'])} · {r['app'] or 'an app'} · {r['kind']}"
        + (" · pinned" if r["pinned"] else "") + (f" · copied {r['copies']}×" if r["copies"] > 1 else "")
        + f"\n  “{r['preview'][:200]}”" for r in rows)
