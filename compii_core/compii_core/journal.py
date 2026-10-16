"""Action journal: an append-only record of everything Compii did, with undo for file moves."""

from __future__ import annotations

import json
import shutil
import time
from dataclasses import asdict, dataclass, field
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


class Journal:
    def __init__(self, path: Path) -> None:
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)

    def record(self, entry: Entry) -> None:
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(asdict(entry), default=str) + "\n")

    def entries(self, task_id: str | None = None) -> list[Entry]:
        if not self.path.exists():
            return []
        out = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                e = Entry(**json.loads(line))
                if task_id is None or e.task_id == task_id:
                    out.append(e)
        return out

    def undo_last(self, task_id: str) -> str:
        """Reverse the most recent undoable action of a task."""
        for e in reversed(self.entries(task_id)):
            if e.ok and e.undo and not e.undo.get("done"):
                op = e.undo
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
                    continue
                self.record(Entry(task_id, "undo", "change", op, True, msg))
                self._mark_done(e)
                return msg
        return "Nothing to undo for this task."

    def _mark_done(self, target: Entry) -> None:
        lines = self.path.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            d = json.loads(line)
            if d["at"] == target.at and d["tool"] == target.tool and d.get("undo"):
                d["undo"]["done"] = True
                lines[i] = json.dumps(d, default=str)
        self.path.write_text("\n".join(lines) + "\n", encoding="utf-8")
