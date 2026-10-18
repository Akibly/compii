"""Tamper-evident audit log: append-only, each line chained to the one before by SHA-256.

Editing or deleting any earlier line breaks the chain, and `verify` says where.
Arguments are redacted before they are written.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
from pathlib import Path
from typing import Any

from .guard import redact

GENESIS = "0" * 64


def _digest(prev: str, body: dict[str, Any]) -> str:
    return hashlib.sha256((prev + json.dumps(body, sort_keys=True, ensure_ascii=False, default=str)).encode()).hexdigest()


class AuditLog:
    def __init__(self, path: Path) -> None:
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._last = self._tail_hash()

    def _tail_hash(self) -> str:
        if not self.path.exists():
            return GENESIS
        last = GENESIS
        with self.path.open(encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    try:
                        last = json.loads(line)["hash"]
                    except (ValueError, KeyError):
                        pass
        return last

    def record(self, event: str, **data: Any) -> None:
        clean = {}
        for k, v in data.items():
            if isinstance(v, (dict, list)):
                v = json.dumps(v, ensure_ascii=False, default=str)
            if isinstance(v, str):
                v = redact(v)[0][:400]
            clean[k] = v
        with self._lock:
            body = {"at": round(time.time(), 3), "event": event, **clean}
            h = _digest(self._last, body)
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps({**body, "prev": self._last, "hash": h}, ensure_ascii=False, default=str) + "\n")
            self._last = h

    def entries(self, limit: int = 200) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        lines = [ln for ln in self.path.read_text(encoding="utf-8").splitlines() if ln.strip()]
        out = []
        for ln in lines[-limit:]:
            try:
                out.append(json.loads(ln))
            except ValueError:
                out.append({"event": "unreadable line"})
        return out[::-1]

    def verify(self) -> dict[str, Any]:
        if not self.path.exists():
            return {"ok": True, "count": 0}
        prev = GENESIS
        n = 0
        for n, line in enumerate((ln for ln in self.path.read_text(encoding="utf-8").splitlines() if ln.strip()), 1):
            try:
                d = json.loads(line)
                h, p = d.pop("hash"), d.pop("prev")
            except (ValueError, KeyError):
                return {"ok": False, "count": n, "broken_at": n, "why": "a line is unreadable"}
            if p != prev or _digest(prev, d) != h:
                return {"ok": False, "count": n, "broken_at": n, "why": "a line was changed or removed"}
            prev = h
        return {"ok": True, "count": n}
