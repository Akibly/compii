"""Compii noticing a habit: when the same kind of ask keeps coming back, offer to make it a routine.

This reads the conversation archive kept on this PC (`chats.json`) and counts how
often the same request shape shows up. Nothing happens by itself: a suggestion is
an offer the user accepts or turns down, and a turn-down is remembered for a month
so the same card does not come back every restart.
"""

from __future__ import annotations

import datetime as dt
import json
import re
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from . import proactive as pro
from .skills import steps_from

MIN_TIMES = 3                 # an ask must come back this often before Compii mentions it
MIN_DAYS = 2                  # ...and on more than one day: one busy afternoon is not a habit
MAX_OPEN = 5                  # only the strongest few offers are shown
MAX_ITEMS = 60                # answered offers are kept for a while, then dropped
DECLINE_COOLDOWN = 30 * 86400  # a turned-down offer stays quiet for a month
RESCAN_SECONDS = 30 * 60      # the archive is re-read at most this often
SIMILAR = 0.55                # how alike two asks must be to count as the same habit
# A rhythm read off the clock is rounded to a repeat length a person would actually say out loud.
_EVERY = [60, 90, 120, 180, 240, 300, 360, 480, 600, 720]

# Words that start most asks and say nothing about which one it was.
_STOP = {
    "a", "an", "the", "and", "or", "to", "of", "in", "on", "at", "for", "from", "into", "with",
    "is", "are", "was", "be", "do", "does", "did", "can", "could", "will", "would", "should",
    "me", "my", "mine", "i", "you", "your", "yours", "it", "its", "this", "that", "these",
    "those", "please", "thanks", "thank", "just", "some", "any", "more", "again", "also",
    "what", "when", "where", "who", "how", "why", "about", "as", "by", "then", "so", "if",
    "today", "tomorrow", "yesterday", "now", "next", "last", "week", "day", "days", "morning",
    "evening", "night", "pm", "am", "monday", "tuesday", "wednesday", "thursday", "friday",
    "saturday", "sunday", "january", "february", "march", "april", "june", "july", "august",
    "september", "october", "november", "december",
}
_QUOTED = re.compile(r"[“\"'”][^“”\"']{1,160}[”\"'”]")
# A path or a named file is today's specific: what repeats is the ask around it, not the file.
_PATH = re.compile(r"[A-Za-z]:[\\/][^\s,;]+|\b[\w\-./\\]+\.(?:pdf|docx?|xlsx?|pptx?|csv|txt|md|png|jpe?g|gif|zip)\b")
_NUMBER = re.compile(r"\b\d[\d,.:/]*\b")
_MACHINE = ("routine", "watch", "delegated")  # asks Compii or a teammate started, not the user


def shape(text: str) -> str:
    """The skeleton of an ask: specifics (quotes, paths, numbers, dates) removed, filler dropped.

    "sort the invoices in D:\\Scan into 2026 folders" and "sort my invoices into the
    2025 folders" both become "sort invoices folders", so they count as one habit.
    """
    t = _QUOTED.sub(" ", str(text or "").lower())
    t = _PATH.sub(" ", t)
    t = _NUMBER.sub(" ", t)
    t = re.sub(r"[^\w\s]", " ", t)
    return " ".join(w for w in t.split() if w not in _STOP and len(w) > 1)


def _similar(a: set[str], b: set[str]) -> bool:
    if len(a) < 2 or len(b) < 2:
        return False
    return len(a & b) / len(a | b) >= SIMILAR


def _asked(record: dict[str, Any]) -> str:
    origin = record.get("origin") or {}
    if isinstance(origin, dict) and any(k in origin for k in _MACHINE):
        return ""
    return str(record.get("request") or "").strip()


def _date(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).strftime("%d %B").lstrip("0")


def _ago(ts: float, now: float) -> str:
    s = max(0, int(now - ts))
    if s < 5400:
        return "just now"
    if s < 86400:
        return f"{s // 3600} hours ago"
    d = s // 86400
    return "yesterday" if d == 1 else f"{d} days ago"


def _schedule_for(stamps: list[float]) -> tuple[dict[str, Any], str] | None:
    """When this habit seems to want to run, read off the times it actually happened at.

    Returns the schedule spec and a phrase for it, or None when the asks are scattered
    with no pattern worth putting on a clock.
    """
    local = [dt.datetime.fromtimestamp(s) for s in stamps]
    hours = [d.hour + d.minute / 60 for d in sorted(local, key=lambda d: d.hour)]
    span = max(hours) - min(hours)
    if len(hours) >= 2 and span <= 3.5:
        at = f"{min(23, max(0, round(sum(hours) / len(hours)))):02d}:00"
        days = {d.date() for d in local}
        named = {d.strftime("%a").lower() for d in local}
        if len(named) == 1 and len(days) >= 2:
            return {"kind": "weekly", "days": [next(iter(named))], "at": at}, \
                f"usually on a {next(iter(named)).capitalize()} around {at[:2]}:00"
        if all(d.weekday() < 5 for d in local) and len(days) >= MIN_DAYS:
            return {"kind": "weekdays", "at": at}, f"usually on weekdays around {at[:2]}:00"
        return {"kind": "daily", "at": at}, f"usually around {at[:2]}:00"
    if len(stamps) >= 4:
        ordered = sorted(stamps)
        gaps = [(b - a) / 60 for a, b in zip(ordered, ordered[1:])]
        gaps = [g for g in gaps if g > 0]
        if gaps:
            gaps.sort()
            median = gaps[len(gaps) // 2]
            if 45 <= median <= 720:
                minutes = min(_EVERY, key=lambda c: (abs(c - median), c))
                n_hours = round(minutes / 60)
                every = "every hour" if n_hours == 1 else \
                    f"every {n_hours} hours" if minutes % 60 == 0 else f"every {minutes} minutes"
                return {"kind": "every", "minutes": minutes}, f"about {every}"
    return None


def habits(records: list[dict[str, Any]], *, exclude: list[str] | None = None,
           now: float | None = None) -> list[dict[str, Any]]:
    """Repeated asks found in saved conversations, strongest habit first.

    `exclude` is text that is already scheduled or already a skill: a habit Compii
    already does on a clock is not news.
    """
    now = now or time.time()
    clusters: list[dict[str, Any]] = []
    for rec in records:
        ask = _asked(rec)
        if not ask or str(rec.get("status")) == "running":
            continue
        words = set(shape(ask).split())
        placed = next((c for c in clusters if _similar(words, c["words"])), None)
        if placed is None:
            placed = {"words": words, "asks": []}
            clusters.append(placed)
        placed["asks"].append({"at": float(rec.get("created") or now), "ask": ask,
                               "ok": str(rec.get("status")) == "done", "events": rec.get("events") or []})
    out = []
    for c in clusters:
        asked = sorted(c["asks"], key=lambda a: a["at"])
        days = {_day(a["at"]) for a in asked}
        if len(asked) < MIN_TIMES or len(days) < MIN_DAYS:
            continue
        newest = next((a for a in reversed(asked) if a["ok"]), asked[-1])
        when = _schedule_for([a["at"] for a in asked])
        steps = steps_from(newest["events"], limit=12)
        if when is None and len(steps) < 2:
            continue  # no clock pattern and nothing that worked to remember: nothing to offer
        text = " ".join(sorted(c["words"]))
        if _already_known(text, exclude or []):
            continue
        spec, phrase = when if when else ({}, "")
        out.append({
            "key": text, "kind": "routine" if when else "skill", "schedule": spec, "phrase": phrase,
            "count": len(asked), "since": _date(asked[0]["at"]), "last": newest["at"],
            "title": _title(newest["ask"]), "instruction": newest["ask"],
            "steps": steps, "why": _why(len(asked), asked[0]["at"], newest["at"], phrase, now),
        })
    out.sort(key=lambda h: (-h["count"], -h["last"]))
    return out


def _day(ts: float) -> dt.date:
    return dt.datetime.fromtimestamp(ts).date()


def _title(ask: str) -> str:
    line = " ".join(str(ask).split())[:60].strip()
    return line[:1].upper() + line[1:] if line else "This again"


def _why(count: int, first: float, last: float, phrase: str, now: float) -> str:
    head = f"You've asked for this {count} times since {_date(first)}"
    if phrase:
        head += ", " + phrase
    return (f"{head}. Last asked {_ago(last, now).lower()}. Compii only counted the conversations "
            "saved on this PC — it hasn't done any of this by itself yet.")


def _already_known(key: str, exclude: list[str]) -> bool:
    """Is this habit something Compii is already told to do?"""
    mine = set(key.split())
    if not mine:
        return False
    for text in exclude:
        other = set(shape(text).split())
        if _similar(mine, other) or (other and other <= mine) or mine <= other:
            return True
    return False


@dataclass
class Suggestion:
    id: str
    kind: str  # routine | skill
    key: str
    title: str
    instruction: str
    why: str
    count: int
    schedule: dict[str, Any] = field(default_factory=dict)
    steps: list[str] = field(default_factory=list)
    created: float = field(default_factory=time.time)
    seen_last: float = 0.0
    status: str = "open"  # open | accepted | declined | expired
    resolved: float = 0.0
    target_id: str = ""  # the routine or skill this offer became

    def view(self) -> dict[str, Any]:
        # The card says the time in words; the raw schedule is what accepting sends back.
        return {**asdict(self), "when": pro.describe(self.schedule) if self.schedule else ""}


class Suggestions:
    """Offers Compii has noticed, kept with the workspace so an answer is remembered."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.RLock()
        self.items: dict[str, Suggestion] = {}
        self.last_scan = 0.0
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            self.path.replace(self.path.with_suffix(f".broken-{int(time.time())}.json"))
            return
        for d in data.get("items", []):
            s = Suggestion(**{k: v for k, v in d.items() if k in Suggestion.__dataclass_fields__})
            self.items[s.id] = s
        self.last_scan = float(data.get("last_scan") or 0.0)

    def save(self) -> None:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"items": [s.view() for s in self.items.values()],
                                       "last_scan": self.last_scan}, indent=1, ensure_ascii=False),
                           encoding="utf-8")
            tmp.replace(self.path)

    def by_key(self, key: str) -> Suggestion | None:
        return next((s for s in self.items.values() if s.key == key), None)

    def get(self, suggestion_id: str) -> Suggestion | None:
        return self.items.get((suggestion_id or "").strip())

    def scan(self, records: list[dict[str, Any]], *, exclude: list[str] | None = None,
             now: float | None = None) -> list[Suggestion]:
        """Look through the archive again and merge what's repeated into the offers."""
        now = now or time.time()
        changed = False
        for habit in habits(records, exclude=exclude, now=now):
            found = self.by_key(habit["key"])
            if found and found.status == "accepted":
                continue
            if found and found.status in ("declined", "expired") and now - (found.resolved or found.created) \
                    < DECLINE_COOLDOWN:
                continue
            if found is None:
                found = Suggestion(id="g" + uuid.uuid4().hex[:8], key=habit["key"], created=now,
                                   kind=habit["kind"], title=habit["title"], instruction=habit["instruction"],
                                   why=habit["why"], count=habit["count"])
                self.items[found.id] = found
                changed = True
            found.kind = habit["kind"]
            found.title = habit["title"]
            found.instruction = habit["instruction"]
            found.why = habit["why"]
            found.count = habit["count"]
            found.schedule = habit["schedule"]
            found.steps = habit["steps"]
            found.seen_last = habit["last"]
            if found.status != "open":
                found.status, found.resolved, found.target_id = "open", 0.0, ""
            changed = True
        # Only the few strongest offers are worth a card; the rest go quiet rather than queue up.
        open_items = sorted((s for s in self.items.values() if s.status == "open"),
                            key=lambda s: (-s.count, -s.created))
        for s in open_items[MAX_OPEN:]:
            s.status, s.resolved = "expired", now
            changed = True
        if len(self.items) > MAX_ITEMS:
            done = sorted((s for s in self.items.values() if s.status != "open"),
                          key=lambda s: s.resolved or s.created)
            for s in done[:len(self.items) - MAX_ITEMS]:
                self.items.pop(s.id, None)
                changed = True
        self.last_scan = now
        if changed or not self.path.exists():
            self.save()
        return self.open()

    def refresh(self, records: list[dict[str, Any]], *, exclude: list[str] | None = None,
                now: float | None = None) -> list[dict[str, Any]]:
        """Scan only when the archive could have changed much — this runs on a page load."""
        if (now or time.time()) - self.last_scan >= RESCAN_SECONDS:
            self.scan(records, exclude=exclude, now=now)
        return self.view()

    def open(self) -> list[Suggestion]:
        with self._lock:
            return sorted((s for s in self.items.values() if s.status == "open"),
                          key=lambda s: (-s.count, -s.created))

    def view(self) -> list[dict[str, Any]]:
        return [s.view() for s in self.open()]

    def resolve(self, suggestion_id: str, status: str, *, target_id: str = "") -> Suggestion | None:
        with self._lock:
            s = self.get(suggestion_id)
            if s is None:
                return None
            s.status = status
            s.resolved = time.time()
            s.target_id = target_id
            self.save()
        return s

    def accept(self, suggestion_id: str, *, plans: Any, skills: Any, bot_id: str | None = None,
               schedule: dict[str, Any] | None = None) -> dict[str, Any]:
        """Turn an offer into the routine or skill it proposed, and mark it answered."""
        s = self.get(suggestion_id)
        if s is None:
            raise KeyError(suggestion_id)
        if s.status != "open":
            raise ValueError("That offer has already been answered.")
        spec = schedule if schedule is not None else s.schedule
        if s.kind == "skill" and schedule is None:
            if not s.steps:
                raise ValueError("There's nothing that worked to remember for that one.")
            skill = skills.add(s.title, s.instruction, s.steps, about="Noticed from a habit you repeat.")
            self.resolve(s.id, "accepted", target_id=skill.id)
            return {"kind": "skill", "id": skill.id, "name": skill.name, "steps": len(skill.steps)}
        if not spec:
            raise ValueError("Say when it should run.")
        routine = plans.add_routine(s.title, s.instruction, dict(spec), bot_id=bot_id)
        self.resolve(s.id, "accepted", target_id=routine.id)
        return {"kind": "routine", "id": routine.id, "title": routine.title,
                "when": pro.describe(routine.schedule)}
