"""Action journal: an append-only record of everything Compii did, with undo for file moves."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from typing import Any


@dataclass
class Entry:
    task_id: str
    tool: str
    kind: str
    input: dict[str, Any]
    ok: bool
    summary: str
    undo: dict[str, Any] | None = None  # e.g. {"op": "move", "src": ..., "dst": ...}
    at: float = field(default_factory=time.time)
    # Lines written before ids existed simply have none: they are still found by time and tool.
    id: str = field(default_factory=lambda: "e" + uuid.uuid4().hex[:8])


def _reversible(e: Entry) -> bool:
    return bool(e.ok and e.undo and not e.undo.get("done"))


_FIELD_NAMES = {f.name for f in fields(Entry)}


def _entry_from(d: dict[str, Any]) -> Entry:
    """A line written by a newer build may carry keys this one doesn't know: keep what fits."""
    return Entry(**{k: v for k, v in d.items() if k in _FIELD_NAMES})


class Journal:
    def __init__(self, path: Path) -> None:
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        # Putting something back rewrites the whole file while other threads append to it.
        self._lock = threading.RLock()

    def record(self, entry: Entry) -> None:
        line = json.dumps(asdict(entry), default=str) + "\n"
        with self._lock, self.path.open("a", encoding="utf-8") as f:
            f.write(line)
            f.flush()

    def entries(self, task_id: str | None = None) -> list[Entry]:
        if not self.path.exists():
            return []
        with self._lock:
            text = self.path.read_text(encoding="utf-8", errors="replace")
        out = []
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                d = json.loads(line)
                if not isinstance(d, dict):
                    continue
                if not d.get("id"):
                    # Lines written before ids existed get a stand-in worked out from when and what
                    # they were, so the undo centre can point at them again on the next read.
                    d["id"] = "l" + hashlib.sha1(f"{d.get('at')}:{d.get('tool')}".encode()).hexdigest()[:8]
                e = _entry_from(d)
            except (ValueError, TypeError, KeyError):
                # One torn line from a power loss must not take the whole journal — and every
                # task that reads it — down with it.
                continue
            if task_id is None or e.task_id == task_id:
                out.append(e)
        return out

    def entry(self, entry_id: str) -> Entry | None:
        want = (entry_id or "").strip()
        return next((e for e in self.entries() if e.id == want), None)

    def reversible(self, since: float | None = None, limit: int = 30) -> list[dict[str, Any]]:
        """What can be put back, newest first.

        Only the latest undone change of each conversation is listed. Pulling an
        earlier one out would leave whatever Compii built on top of it pointing at
        something that no longer exists, so those are left alone on purpose.
        """
        rows: list[dict[str, Any]] = []
        seen: set[str] = set()
        # Sorted by when it happened, not by the order the lines were written: "newest first" is
        # what the centre promises, and the newest change of a task is the safe one to offer.
        for e in sorted(self.entries(), key=lambda e: e.at, reverse=True):
            if since is not None and e.at < since:
                continue
            if not _reversible(e) or e.task_id in seen:
                continue
            seen.add(e.task_id)
            rows.append({"id": e.id, "task_id": e.task_id, "tool": e.tool, "kind": e.kind,
                         "summary": e.summary, "at": e.at, "what": dict(e.undo or {})})
            if len(rows) >= limit:
                break
        return rows

    def undo_last(self, task_id: str) -> str:
        """Reverse the most recent undoable action of a task."""
        for e in reversed(self.entries(task_id)):
            if _reversible(e):
                return self._reverse(e)
        return "Nothing to undo for this task."

    def undo_by_id(self, entry_id: str) -> str:
        """Reverse one listed action, chosen by the id the undo centre gave it."""
        e = self.entry(entry_id)
        if e is None:
            return "I can't find that action in the journal any more; it may be from a day I've already trimmed."
        if not e.ok:
            return f"That step didn’t work in the first place (“{e.summary}”), so there is nothing to put back."
        if not e.undo:
            return f"“{e.summary}” can't be reversed: Compii never recorded a way back for it."
        if e.undo.get("done"):
            return "That one is already put back."
        return self._reverse(e)

    def _reverse(self, e: Entry) -> str:
        op = dict(e.undo or {})
        if op["op"] == "move":
            shutil.move(op["dst"], op["src"])
            msg = f"Moved {op['dst']} back to {op['src']}"
        elif op["op"] == "created":
            p = Path(op["path"])
            trash = self.path.parent / "undone" / f"{int(time.time())}-{p.name}"
            trash.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(p), trash)
            msg = f"Removed {p} (kept a copy in {trash})"
        else:
            return f"“{e.summary}” has no way back recorded (I only know how to undo moves and files I made)."
        self.record(Entry(e.task_id, "undo", "change", op, True, msg))
        self._mark_done(e)
        return msg

    def _mark_done(self, target: Entry) -> None:
        with self._lock:
            lines = self.path.read_text(encoding="utf-8", errors="replace").splitlines()
            changed = False
            for i, line in enumerate(lines):
                try:
                    d = json.loads(line)
                except ValueError:
                    continue  # a torn line stays exactly as it is; rewriting it would lose it twice
                # Prefer the id; a line written before ids existed is matched by when and what it was.
                same = d.get("id") == target.id if d.get("id") else (d.get("at") == target.at and d.get("tool") == target.tool)
                if same and d.get("undo"):
                    d["undo"]["done"] = True
                    lines[i] = json.dumps(d, default=str)
                    changed = True
            if not changed:
                return
            tmp = self.path.with_name(f"{self.path.name}.{os.getpid()}.tmp")
            tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
            # Windows can refuse the swap for a moment when a scanner, the indexer or a
            # just-closed reader still holds the journal; retry instead of losing the mark.
            for attempt in range(5):
                try:
                    os.replace(tmp, self.path)
                    break
                except PermissionError:
                    if attempt == 4:
                        raise
                    time.sleep(0.02)
