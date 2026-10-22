"""Ask your own files: a local index of folders the user chooses.

Only text is kept, in a SQLite database on this PC, together with the file it
came from so every answer can cite the source. Files are never copied or
uploaded, and password stores, keys and system credential folders are skipped.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

SUPPORTED = {".txt", ".md", ".markdown", ".csv", ".tsv", ".json", ".xml", ".html", ".htm", ".log", ".ini", ".cfg",
             ".yaml", ".yml", ".toml", ".py", ".js", ".ts", ".css", ".srt", ".vtt", ".pdf", ".docx", ".xlsx", ".xlsm"}
SKIP_DIRS = {".git", ".hg", ".svn", ".venv", "venv", "node_modules", "__pycache__", ".cache", ".ssh", ".gnupg",
             ".aws", ".azure", "AppData"}
SKIP_FILE = re.compile(
    r"^(\.env(\..*)?|\.npmrc|\.pypirc|id_(rsa|dsa|ecdsa|ed25519)(\..*)?|credentials?(\..*)?|passwords?.*|.*\.kdbx)$",
    re.IGNORECASE)
SKIP_SUFFIX = {".kdbx", ".key", ".pem", ".pfx", ".p12", ".asc", ".gpg"}
MAX_FILE = 20 * 1024 * 1024
MAX_FILES = 4000
MAX_CHARS = 1_500_000
CHUNK = 1200
OVERLAP = 200
MAX_RESULTS = 12
STOPWORDS = {"what", "when", "where", "who", "whom", "which", "how", "why", "is", "are", "was", "were", "be",
             "been", "the", "a", "an", "of", "in", "on", "at", "to", "for", "from", "and", "or", "do", "does",
             "did", "can", "could", "should", "would", "my", "me", "i", "you", "your", "it", "this", "that",
             "these", "those", "with", "about", "tell", "say", "says", "please", "there", "their",
             "not", "near"}  # FTS query operators: quoting them with a prefix star matches everything


class KnowledgeError(Exception):
    """The user or agent asked for something the index cannot do."""


def _norm(raw: str) -> Path:
    return Path(raw).expanduser().resolve()


def _terms(query: str) -> list[str]:
    words = re.findall(r"\w+", query.lower(), flags=re.UNICODE)
    seen: list[str] = []
    for w in words:
        if len(w) >= 2 and w not in STOPWORDS and w not in seen:
            seen.append(w)
    if not seen:  # a question made only of small words: search them as typed
        seen = [w for w in words if len(w) >= 2][:8]
    return seen[:8]


def _term(t: str) -> str:
    return f'"{t}"*' if len(t) >= 3 else f'"{t}"'


def _match(terms: list[str], op: str) -> str:
    return op.join(_term(t) for t in terms)


def _title(text: str, path: Path) -> str:
    for line in text[:2000].splitlines():
        s = line.strip()
        if s.startswith("# ") and len(s) > 2:
            return s[2:].strip()[:120]
    return path.stem[:120]


def _chunks(text: str) -> Iterator[str]:
    text = text.replace("\x00", " ").strip()
    if not text:
        return
    start = 0
    while start < len(text):
        end = min(len(text), start + CHUNK)
        if end < len(text):
            for sep in ("\n\n", "\n", ". ", " "):
                cut = text.rfind(sep, start + 400, end)
                if cut != -1:
                    end = cut + (len(sep) if sep != "\n\n" else 0)
                    break
        piece = text[start:end].strip()
        if piece:
            yield piece
        if end >= len(text):
            break
        start = max(end - OVERLAP, start + 1)


def _file_text(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".pdf":
        from pypdf import PdfReader

        return "\n\n".join((page.extract_text() or "") for page in PdfReader(path).pages)
    if suffix == ".docx":
        from .documents import docx_text

        return docx_text(path)
    if suffix in {".xlsx", ".xlsm"}:
        from openpyxl import load_workbook

        wb = load_workbook(path, data_only=True, read_only=True)
        parts = []
        for ws in wb.worksheets:
            parts.append(f"# Sheet {ws.title}")
            for row in ws.iter_rows(values_only=True):
                parts.append("\t".join("" if v is None else str(v) for v in row))
        return "\n".join(parts)
    return path.read_text(encoding="utf-8", errors="replace")


class Knowledge:
    def __init__(self, workspace: Path, *, extract: Callable[[Path], str] | None = None) -> None:
        self.root = workspace / "knowledge.db"
        self.settings_path = workspace / "knowledge.json"
        self.extract = extract or _file_text
        self._lock = threading.Lock()

    # ---- folders ---------------------------------------------------------

    def folders(self) -> list[str]:
        try:
            data = json.loads(self.settings_path.read_text(encoding="utf-8-sig"))
            return [str(_norm(p)) for p in data.get("folders", []) if isinstance(p, str)]
        except (OSError, ValueError, TypeError, RuntimeError):
            return []

    def _save(self, folders: list[str]) -> None:
        self.settings_path.parent.mkdir(parents=True, exist_ok=True)
        self.settings_path.write_text(json.dumps({"folders": folders}, indent=1), encoding="utf-8")

    def add_folder(self, raw: str) -> str:
        path = _norm(raw)
        if not path.is_dir():
            raise KnowledgeError(f"{path} is not a folder.")
        if path.parent == path:
            raise KnowledgeError("Choose a folder, not a whole drive.")
        folders = self.folders()
        if str(path) not in folders:
            folders.append(str(path))
            self._save(folders)
        return str(path)

    def remove_folder(self, raw: str) -> bool:
        path = str(_norm(raw))
        folders = self.folders()
        if path not in folders:
            return False
        self._save([f for f in folders if f != path])
        with self._lock, self._db() as con:
            con.execute("DELETE FROM passages WHERE folder = ?", (path,))
            con.execute("DELETE FROM files WHERE folder = ?", (path,))
        return True

    # ---- index -----------------------------------------------------------

    @contextmanager
    def _db(self) -> Iterator[sqlite3.Connection]:
        self.root.parent.mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(self.root, timeout=20)
        try:
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, folder TEXT NOT NULL, mtime REAL, "
                        "size INTEGER, title TEXT, chunks INTEGER, chars INTEGER, indexed REAL)")
            con.execute("CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(path UNINDEXED, folder UNINDEXED, "
                        "title, n UNINDEXED, text)")
            yield con
            con.commit()
        finally:
            con.close()

    def _walk(self, folder: Path) -> Iterator[Path]:
        count = 0
        for base, dirs, names in os.walk(folder):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
            for name in sorted(names):
                if count >= MAX_FILES:
                    return
                p = Path(base) / name
                if p.suffix.lower() not in SUPPORTED or SKIP_FILE.match(name) or p.suffix.lower() in SKIP_SUFFIX:
                    continue
                try:
                    if p.is_symlink() or not p.is_file() or p.stat().st_size > MAX_FILE:
                        continue
                except OSError:
                    continue
                count += 1
                yield p

    def refresh(self, folder: str = "") -> dict[str, Any]:
        if folder:
            target = str(_norm(folder))
            if target not in self.folders():
                raise KnowledgeError("That folder isn't in Knowledge. Add it first.")
            wanted = [target]
        else:
            wanted = self.folders()
        started = time.time()
        stats: dict[str, Any] = {"files": 0, "indexed": 0, "unchanged": 0, "skipped": 0, "removed": 0,
                                 "chars": 0, "problems": []}
        with self._lock, self._db() as con:
            for raw in wanted:
                root = Path(raw)
                if not root.is_dir():
                    continue
                known = {row[0]: (row[1], row[2]) for row in
                         con.execute("SELECT path, mtime, size FROM files WHERE folder = ?", (raw,))}
                seen: set[str] = set()
                for path in self._walk(root):
                    key = str(path)
                    seen.add(key)
                    try:
                        st = path.stat()
                    except OSError:
                        continue
                    if known.get(key) == (st.st_mtime, st.st_size):
                        stats["unchanged"] += 1
                        continue
                    try:
                        text = self.extract(path)
                        if len(text) > MAX_CHARS:
                            text = text[:MAX_CHARS]
                        self._replace(con, key, raw, st.st_mtime, st.st_size, text)
                        stats["indexed"] += 1
                        stats["chars"] += len(text)
                    except Exception as e:  # noqa: BLE001 - one unreadable file must not stop the folder
                        stats["skipped"] += 1
                        if len(stats["problems"]) < 5:
                            stats["problems"].append(f"{path.name}: {e}")
                        con.execute("DELETE FROM passages WHERE path = ?", (key,))
                        con.execute("DELETE FROM files WHERE path = ?", (key,))
                for stale in set(known) - seen:
                    con.execute("DELETE FROM passages WHERE path = ?", (stale,))
                    con.execute("DELETE FROM files WHERE path = ?", (stale,))
                    stats["removed"] += 1
                stats["files"] += len(seen)
            con.commit()
        stats["seconds"] = round(time.time() - started, 1)
        stats["updated"] = time.time()
        return stats

    def _replace(self, con: sqlite3.Connection, path: str, folder: str, mtime: float, size: int,
                 text: str) -> None:
        con.execute("DELETE FROM passages WHERE path = ?", (path,))
        title = _title(text, Path(path))
        rows = [(path, folder, title, n, piece) for n, piece in enumerate(_chunks(text))]
        if rows:
            con.executemany("INSERT INTO passages (path, folder, title, n, text) VALUES (?, ?, ?, ?, ?)", rows)
        con.execute("INSERT OR REPLACE INTO files (path, folder, mtime, size, title, chunks, chars, indexed) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (path, folder, mtime, size, title, len(rows), len(text), time.time()))

    # ---- search and views -------------------------------------------------

    def search(self, query: str, *, limit: int = 8, folder: str = "") -> list[dict[str, Any]]:
        terms = _terms(query)
        if not terms:
            raise KnowledgeError("Type a word to search for.")
        if not self.root.exists():
            return []
        limit = max(1, min(MAX_RESULTS, int(limit)))
        rows: list[Any] = []
        with self._db() as con:
            for op in (" AND ", " OR "):
                sql = ("SELECT path, title, n, snippet(passages, 4, '[', ']', ' … ', 64) AS snip "
                       "FROM passages WHERE passages MATCH ?")
                args: list[Any] = [_match(terms, op)]
                if folder:
                    try:
                        sql += " AND folder = ?"
                        args.append(str(_norm(folder)))
                    except (OSError, RuntimeError):
                        pass
                sql += " ORDER BY bm25(passages) LIMIT ?"
                args.append(limit * 4)
                rows = con.execute(sql, args).fetchall()
                if rows:
                    break
        # One long file should not crowd out every other source: at most two passages per file.
        out: list[dict[str, Any]] = []
        per_file: dict[str, int] = {}
        for path, title, n, snip in rows:
            if per_file.get(path, 0) >= 2:
                continue
            per_file[path] = per_file.get(path, 0) + 1
            out.append({"path": path, "title": title, "part": int(n) + 1, "excerpt": snip})
            if len(out) >= limit:
                break
        return out

    def file_count(self) -> int:
        if not self.root.exists():
            return 0
        with self._db() as con:
            return int(con.execute("SELECT COUNT(*) FROM files").fetchone()[0])

    def view(self) -> dict[str, Any]:
        counts: dict[str, tuple[int, int, float]] = {}
        passages = 0
        if self.root.exists():
            with self._db() as con:
                for row in con.execute("SELECT folder, COUNT(*), COALESCE(SUM(chars), 0), MAX(indexed) "
                                       "FROM files GROUP BY folder"):
                    counts[row[0]] = (int(row[1]), int(row[2]), float(row[3] or 0))
                passages = int(con.execute("SELECT COUNT(*) FROM passages").fetchone()[0])
        folders = []
        for path in self.folders():
            files, chars, updated = counts.get(path, (0, 0, 0.0))
            folders.append({"path": path, "name": Path(path).name or path, "files": files, "chars": chars,
                            "updated": updated, "exists": Path(path).is_dir()})
        return {"folders": folders, "files": sum(c[0] for c in counts.values()), "chars": sum(c[1] for c in counts.values()),
                "passages": passages, "supported": sorted(SUPPORTED), "limits": {"max_files": MAX_FILES,
                "max_file_mb": MAX_FILE // (1024 * 1024)}}


def knowledge_tools(knowledge: Knowledge) -> list[Tool]:
    s = {"type": "string"}

    def ask(a: dict[str, Any]) -> ToolResult:
        query = str(a.get("query") or "").strip()
        if not query:
            raise ToolError("Give the words to look for.")
        if not knowledge.folders():
            raise ToolError("No folders are in Knowledge yet. The user adds them on the Knowledge screen; "
                            "don't guess a folder path.")
        try:
            hits = knowledge.search(query, limit=int(a.get("max_results") or 8), folder=str(a.get("folder") or ""))
        except KnowledgeError as e:
            raise ToolError(str(e)) from e
        if not hits:
            return ToolResult(f"Nothing in the {knowledge.file_count()} indexed files matches “{query}”. "
                              "Try other words, or ask the user to refresh the index.")
        lines = [f"From {h['path']} (part {h['part']}):\n{h['excerpt']}" for h in hits]
        return ToolResult("Passages from the user's own indexed files. Cite the file path for each point; "
                          "if the answer isn't here, say so rather than guessing:\n\n" + "\n\n".join(lines))

    return [
        Tool("ask_my_files",
             "Search the user's own documents: folders they added to Knowledge (notes, contracts, PDFs, Word, "
             "Excel, text). Returns passages with the file they came from. Use it for questions about the "
             "user's files instead of guessing, and cite the file path in the answer.",
             {"query": {**s, "description": "Words or a short question, e.g. 'cancellation deadline'."},
              "folder": {**s, "description": "Optional: only this indexed folder, exactly as added."},
              "max_results": {"type": "integer", "description": "How many passages (default 8, max 12)."}},
             ["query"], ActionKind.READ, ask,
             lambda a: f"Search your files for “{a.get('query', '')}”"),
    ]
