"""Work journal: one plain-Markdown day file, written once a day has closed.

The daybook answers "what did I do today?" from live stores, which are trimmed as
Compii goes on. A journal entry is that same answer written down while the day is
still known, so a month later "what was I working on the 3rd?" still has an answer —
and so `ask_my_files` can find the day a thing happened.

Screen titles are deliberately left out: those stay in the rolling screen memory the
user controls, not in a file that lasts. The day records which apps were in use.
"""

from __future__ import annotations

import datetime as dt
import re
import time
from pathlib import Path
from typing import Any

from .daybook import build_daybook, format_daybook
from .policy import ActionKind
from .tools import Tool, ToolResult

MAX_DAYS = 14  # a fortnight of days is enough for the app to list
MAX_HITS = 8
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}$")


def _stamp(day: str) -> dt.date | None:
    try:
        return dt.date.fromisoformat((day or "").strip())
    except ValueError:
        return None


def _title(day: dt.date) -> str:
    return f"{day:%A} {day.day} {day:%B} {day.year}"


def _lead(book: dict[str, Any]) -> str:
    parts = [str(p) for p in book.get("parts") or []]
    return (", ".join(parts) + ".") if parts else "A quiet day: nothing was finished, changed or recorded."


class WorkJournal:
    """`folder` holds YYYY-MM-DD.md files, newest first when listed."""

    def __init__(self, folder: Path) -> None:
        self.folder = folder

    def path_for(self, day: str) -> Path | None:
        stamp = _stamp(day)
        return self.folder / f"{stamp.isoformat()}.md" if stamp else None

    def write(self, *, tasks: list[Any], journal: Any, timeline: Any = None, day: str | None = None,
              now: dt.datetime | None = None) -> dict[str, Any] | None:
        """Write one day's record and say where it went. A day with nothing in it gets no file."""
        now = now or dt.datetime.now()
        stamp = _stamp(day) if day else (now - dt.timedelta(days=1)).date()
        if stamp is None:
            return None
        start = dt.datetime.combine(stamp, dt.time(0, 0)).timestamp()
        end = dt.datetime.combine(stamp, dt.time(23, 59, 59)).timestamp()
        # The window has to reach back over the whole day; daybook works in hours from now.
        hours = int(max(1, min(168, (time.time() - start) / 3600 + 1)))
        book = build_daybook(tasks=tasks, journal=journal, timeline=timeline, hours=hours, until=end)
        path = self.folder / f"{stamp.isoformat()}.md"
        if not (book["done"] or book["actions"] or book["waiting"] or book["screen"]["apps"]):
            return None
        text = format_daybook(book, now=dt.datetime.combine(stamp, dt.time(12, 0)), heading=_lead(book),
                              show_titles=False, undo_hints=False)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(f"# Compii's journal for {_title(stamp)}\n\n{text}\n", encoding="utf-8")
        tmp.replace(path)
        return {"date": stamp.isoformat(), "title": _title(stamp), "path": str(path),
                "lead": _lead(book), "bytes": path.stat().st_size}

    def days(self, limit: int = MAX_DAYS) -> list[dict[str, Any]]:
        """The days already recorded, newest first, with the line that opens each one."""
        out = []
        if not self.folder.is_dir():
            return out
        for path in sorted(self.folder.glob("*.md"), reverse=True)[:limit]:
            stem = path.stem
            if not _DATE.fullmatch(stem):
                continue
            head = ""
            try:
                lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
                head = next((line for line in lines if line and not line.startswith("# ")), "")
            except OSError:
                continue
            out.append({"date": stem, "title": _title(_stamp(stem)) if _stamp(stem) else stem,
                        "lead": head.strip("* ").rstrip("."), "at": path.stat().st_mtime,
                        "bytes": path.stat().st_size})
        return out

    def read(self, day: str) -> str | None:
        path = self.path_for(day)
        if path is None or not path.is_file():
            return None
        try:
            return path.read_text(encoding="utf-8")
        except OSError:
            return None

    def search(self, query: str, *, limit: int = MAX_HITS) -> list[dict[str, Any]]:
        """Which days mention this, with the line that said it. A plain scan: the files are small."""
        words = " ".join(str(query or "").lower().split()).split()
        if not words:
            return []
        phrase = " ".join(words)
        strong = [w for w in words if len(w) > 2]
        hits: list[dict[str, Any]] = []
        for row in self.days(limit=200):
            for line in (self.read(row["date"]) or "").splitlines():
                if line.strip().startswith("#"):
                    continue
                text = " ".join(line.lower().split())
                if not text:
                    continue
                # The whole phrase, or every meaningful word of it: "invoice sort" still finds the day.
                if phrase in text or (strong and all(w in text for w in strong)):
                    hits.append({"date": row["date"], "title": row["title"], "line": line.strip()[:300]})
                    break  # one line per day is enough to point at it
            if len(hits) >= limit:
                break
        return hits


def journal_tool(work: WorkJournal) -> Tool:
    s = {"type": "string"}

    def look(a: dict[str, Any]) -> ToolResult:
        day = str(a.get("date") or "").strip()
        query = str(a.get("query") or "").strip()
        recorded = work.days(limit=200)
        if not recorded:
            return ToolResult("The work journal is empty: no day has been written down yet. It only holds "
                              "days recorded since the user turned it on.")
        if day:
            text = work.read(day)
            if text is None:
                return ToolResult(f"Nothing is recorded for “{day}”. Days on file: "
                                  + ", ".join(r["date"] for r in recorded[:MAX_DAYS]) + ".")
            return ToolResult("The user's own journal for that day, written by Compii from this PC. Treat it as "
                              "fact; do not add anything that is not in it:\n\n" + text)
        if query:
            hits = work.search(query)
            if not hits:
                return ToolResult(f"No journal day mentions “{query}”. The journal only reaches back to when the "
                                  "user turned it on, so an earlier day cannot be found here.")
            return ToolResult("Days that mention it, newest first:\n"
                              + "\n".join(f"- {h['date']} ({h['title']}): {h['line']}" for h in hits)
                              + "\nAsk for one of those dates to read the whole day.")
        return ToolResult("Days recorded so far:\n"
                          + "\n".join(f"- {r['date']} · {r['lead']}" for r in recorded[:MAX_DAYS]))

    return Tool(
        "work_journal", "Look back through the days Compii wrote down: pass a date (YYYY-MM-DD) for that whole "
                        "day, a query to find which day mentioned something, or nothing to list the days on file. "
                        "Use it for 'what was I working on last Tuesday?' or 'when did I sort the invoices?'. "
                        "It only knows days recorded after the user turned the journal on.",
        {"date": s, "query": s}, [], ActionKind.READ, look,
        lambda a: f"Reading the journal for {a['date']}" if a.get("date")
        else (f"Searching the journal for “{a['query']}”" if a.get("query") else "Listing the recorded days"))
