"""Compii thinking ahead: routines on a schedule, watches that tell you when
something happens, a daily brief, a nightly journal entry, and an inbox of updates.

Everything here is stored in the workspace (`proactive.json`) and checked by a
background loop in Core. Folder and web watches and the brief are computed
locally (free); routines and "AI check" watches run the agent (uses Claude).
"""

from __future__ import annotations

import datetime as dt
import fnmatch
import hashlib
import html.parser
import json
import threading
import time
import urllib.request
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
MIN_EVERY = {"folder": 1, "web": 15, "ai": 30}  # minutes between checks
MAX_INBOX = 200


# ---- schedules ---------------------------------------------------------------------


def _at(spec: dict[str, Any]) -> dt.time:
    h, m = (spec.get("at") or "09:00").split(":")
    return dt.time(int(h), int(m))


def validate_schedule(spec: dict[str, Any]) -> dict[str, Any]:
    kind = spec.get("kind")
    if kind not in ("daily", "weekdays", "weekly", "every", "once"):
        raise ValueError("Schedule kind must be daily, weekdays, weekly, every or once.")
    if kind != "every":
        # Raises on a bad time. Written back as HH:MM so a schedule the model sent without a
        # time reads "Every weekday at 09:00", not "at ." with the default hidden.
        spec = {**spec, "at": _at(spec).strftime("%H:%M")}
    if kind == "weekly":
        days = [d[:3].lower() for d in spec.get("days", [])]
        if not days or any(d not in DAYS for d in days):
            raise ValueError("Weekly schedules need days like mon, wed, fri.")
        spec = {**spec, "days": days}
    if kind == "every":
        minutes = int(spec.get("minutes", 0))
        if minutes < 5:
            raise ValueError("Repeat at most every 5 minutes.")
        spec = {**spec, "minutes": minutes}
    if kind == "once":
        dt.date.fromisoformat(spec["date"])
    return spec


def next_run(spec: dict[str, Any], after: dt.datetime) -> dt.datetime | None:
    """The first time strictly after `after` (local time) the schedule fires."""
    kind = spec["kind"]
    if kind == "every":
        return after + dt.timedelta(minutes=spec["minutes"])
    if kind == "once":
        when = dt.datetime.combine(dt.date.fromisoformat(spec["date"]), _at(spec))
        return when if when > after else None
    at = _at(spec)
    for offset in range(0, 8):
        day = after.date() + dt.timedelta(days=offset)
        when = dt.datetime.combine(day, at)
        if when <= after:
            continue
        weekday = DAYS[day.weekday()]
        if kind == "daily" or (kind == "weekdays" and day.weekday() < 5) or (
            kind == "weekly" and weekday in spec["days"]
        ):
            return when
    return None


def describe(spec: dict[str, Any]) -> str:
    kind = spec["kind"]
    at = spec.get("at", "")
    if kind == "daily":
        return f"Every day at {at}"
    if kind == "weekdays":
        return f"Every weekday at {at}"
    if kind == "weekly":
        return f"Every {', '.join(d.capitalize() for d in spec['days'])} at {at}"
    if kind == "every":
        m = spec["minutes"]
        return f"Every {m // 60} hour{'s' if m >= 120 else ''}" if m % 60 == 0 else f"Every {m} minutes"
    return f"Once on {spec['date']} at {at}"


# ---- records -------------------------------------------------------------------------


@dataclass
class Routine:
    title: str
    instruction: str
    schedule: dict[str, Any]
    id: str = field(default_factory=lambda: "r" + uuid.uuid4().hex[:8])
    enabled: bool = True
    next_run: str | None = None
    last_run: str | None = None
    last_task: str | None = None
    # The teammate who owns this routine; empty means Compii itself.
    bot_id: str | None = None
    # Recent runs, newest first: {"at", "task_id", "status"}.
    runs: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class Watch:
    title: str
    kind: str  # folder | web | ai
    spec: dict[str, Any]
    every_minutes: int
    id: str = field(default_factory=lambda: "w" + uuid.uuid4().hex[:8])
    enabled: bool = True
    last_check: str | None = None
    last_triggered: str | None = None
    state: dict[str, Any] = field(default_factory=dict)  # baseline: files seen, page hash…
    error: str | None = None


@dataclass
class Update:
    kind: str  # brief | watch | routine | needs_you | journal
    title: str
    body: str
    id: str = field(default_factory=lambda: "u" + uuid.uuid4().hex[:8])
    at: float = field(default_factory=time.time)
    read: bool = False
    task_id: str | None = None
    sections: list[dict[str, Any]] = field(default_factory=list)


def _now() -> dt.datetime:
    return dt.datetime.now().replace(second=0, microsecond=0)


class Proactive:
    """Holds routines, watches, brief settings and the inbox, saved to disk."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.RLock()
        self.routines: dict[str, Routine] = {}
        self.watches: dict[str, Watch] = {}
        self.inbox: list[Update] = []
        self.brief = {"enabled": True, "at": "08:00", "last": None}
        # Off by default: unlike the rolling stores it reads from, this keeps a day on disk for good.
        self.journal = {"enabled": False, "at": "21:00", "last": None}
        # The other end of the day: what landed, what didn't, what still waits on the user.
        self.recap = {"enabled": True, "at": "18:00", "last": None}
        # A look every few hours while the user is up, posting only when something really waits on
        # them; `told` keeps one nudge per thing instead of one per look.
        self.checkin = {"enabled": True, "every_hours": 3, "from": "08:00", "to": "21:00", "last": None,
                        "told": []}
        self._load()

    # ---- persistence ---------------------------------------------------------

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            d = json.loads(self.path.read_text(encoding="utf-8-sig"))  # tolerate a byte-order mark
        except ValueError:
            # Never refuse to start over a damaged file: keep a copy and start fresh.
            self.path.replace(self.path.with_suffix(f".broken-{int(time.time())}.json"))
            return
        self.routines = {r["id"]: Routine(**r) for r in d.get("routines", [])}
        self.watches = {w["id"]: Watch(**w) for w in d.get("watches", [])}
        self.inbox = [Update(**u) for u in d.get("inbox", [])]
        self.brief.update(d.get("brief", {}))
        self.journal.update(d.get("journal", {}))
        self.recap.update(d.get("recap", {}))
        self.checkin.update(d.get("checkin", {}))

    def save(self) -> None:
        with self._lock:
            d = {
                "routines": [asdict(r) for r in self.routines.values()],
                "watches": [asdict(w) for w in self.watches.values()],
                "inbox": [asdict(u) for u in self.inbox[-MAX_INBOX:]],
                "brief": self.brief,
                "journal": self.journal,
                "recap": self.recap,
                "checkin": self.checkin,
            }
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(d, indent=1), encoding="utf-8")
            tmp.replace(self.path)

    # ---- routines --------------------------------------------------------------

    def add_routine(self, title: str, instruction: str, schedule: dict[str, Any],
                    bot_id: str | None = None) -> Routine:
        spec = validate_schedule(schedule)
        nxt = next_run(spec, _now())
        if nxt is None:
            raise ValueError("That time has already passed.")
        r = Routine(title.strip() or instruction[:40], instruction.strip(), spec, next_run=nxt.isoformat(),
                    bot_id=bot_id or None)
        with self._lock:
            self.routines[r.id] = r
            self.save()
        return r

    def edit_routine(self, item_id: str, title: str, instruction: str, schedule: dict[str, Any],
                     bot_id: str | None = None) -> Routine:
        with self._lock:
            r = self.routines.get(item_id)
            if r is None:
                raise KeyError(item_id)
            spec = validate_schedule(schedule)
            nxt = next_run(spec, _now())
            if nxt is None:
                raise ValueError("That time has already passed.")
            r.title = title.strip() or instruction[:40]
            r.instruction = instruction.strip()
            r.schedule = spec
            r.bot_id = bot_id or None
            r.next_run = nxt.isoformat()
            self.save()
            return r

    def due_routines(self, now: dt.datetime) -> list[Routine]:
        with self._lock:
            return [r for r in self.routines.values()
                    if r.enabled and r.next_run and dt.datetime.fromisoformat(r.next_run) <= now]

    def note_run(self, r: Routine, task_id: str, now: dt.datetime | None = None) -> None:
        """Remember that a run started, without touching its schedule."""
        with self._lock:
            at = (now or _now()).isoformat()
            r.last_run, r.last_task = at, task_id
            r.runs = ([{"at": at, "task_id": task_id, "status": "running"}] + r.runs)[:20]
            self.save()

    def finish_run(self, task_id: str, status: str) -> None:
        """Mark the routine run that produced this task as finished."""
        changed = False
        with self._lock:
            for r in self.routines.values():
                for run in r.runs:
                    if run.get("task_id") == task_id and run.get("status") == "running":
                        run["status"] = status
                        changed = True
            if changed:
                self.save()

    def mark_ran(self, r: Routine, now: dt.datetime, task_id: str | None) -> None:
        with self._lock:
            if task_id:
                self.note_run(r, task_id, now)
            nxt = next_run(r.schedule, now)
            r.next_run = nxt.isoformat() if nxt else None
            if nxt is None:
                r.enabled = False  # a one-off is done
            self.save()

    def set_enabled(self, item_id: str, enabled: bool) -> bool:
        with self._lock:
            item = self.routines.get(item_id) or self.watches.get(item_id)
            if item is None:
                return False
            item.enabled = enabled
            if isinstance(item, Routine) and enabled:
                nxt = next_run(item.schedule, _now())
                item.next_run = nxt.isoformat() if nxt else None
            self.save()
            return True

    def remove(self, item_id: str) -> bool:
        with self._lock:
            found = self.routines.pop(item_id, None) or self.watches.pop(item_id, None)
            if found:
                self.save()
            return found is not None

    # ---- watches ----------------------------------------------------------------

    def add_watch(self, title: str, kind: str, spec: dict[str, Any], every_minutes: int | None = None) -> Watch:
        if kind not in MIN_EVERY:
            raise ValueError("Watch kind must be folder, web or ai.")
        if kind == "folder" and not spec.get("folder"):
            raise ValueError("A folder watch needs a folder.")
        if kind == "web" and not spec.get("url"):
            raise ValueError("A web watch needs a url.")
        if kind == "ai" and not spec.get("check"):
            raise ValueError("An AI watch needs something to check.")
        every = max(MIN_EVERY[kind], int(every_minutes or MIN_EVERY[kind] * (1 if kind == "folder" else 2)))
        w = Watch(title.strip() or kind, kind, spec, every)
        with self._lock:
            self.watches[w.id] = w
            self.save()
        return w

    def due_watches(self, now: dt.datetime) -> list[Watch]:
        with self._lock:
            out = []
            for w in self.watches.values():
                if not w.enabled:
                    continue
                last = dt.datetime.fromisoformat(w.last_check) if w.last_check else None
                if last is None or now - last >= dt.timedelta(minutes=w.every_minutes):
                    out.append(w)
            return out

    # ---- inbox -------------------------------------------------------------------

    def post(self, update: Update) -> Update:
        with self._lock:
            self.inbox.append(update)
            self.inbox = self.inbox[-MAX_INBOX:]
            self.save()
        return update

    def mark_read(self, update_id: str | None = None) -> None:
        with self._lock:
            for u in self.inbox:
                if update_id is None or u.id == update_id:
                    u.read = True
            self.save()

    def view(self) -> dict[str, Any]:
        with self._lock:
            return {
                "routines": [{**asdict(r), "when": describe(r.schedule)} for r in self.routines.values()],
                "watches": [asdict(w) for w in self.watches.values()],
                "inbox": [asdict(u) for u in reversed(self.inbox)],
                "unread": sum(1 for u in self.inbox if not u.read),
                "brief": dict(self.brief),
                "journal": dict(self.journal),
                "recap": dict(self.recap),
                "checkin": {k: v for k, v in self.checkin.items() if k != "told"},
            }

    def due_digests(self, now: dt.datetime, tasks: list[Any]) -> list[tuple[Update, bool]]:
        """The end-of-day recap and the "needs you" check, when either is due, as (update, speak).
        Built locally from the threads Compii already holds, so neither costs a model call. The
        caller announces them; they are already in the inbox."""
        out: list[tuple[Update, bool]] = []
        looked = False
        with self._lock:
            r = self.recap
            if r.get("enabled") and r.get("last") != now.date().isoformat() and now.time() >= _at(r):
                r["last"] = now.date().isoformat()
                out.append((compose_recap(tasks=tasks, proactive=self, now=now), False))
            c = self.checkin
            if c.get("enabled") and _checkin_due(c, now):
                c["last"] = now.isoformat()
                looked = True
                update = compose_checkin(tasks=tasks, told=c.setdefault("told", []), now=now)
                if update is not None:
                    out.append((update, True))
            for update, _ in out:
                self.inbox.append(update)
            self.inbox = self.inbox[-MAX_INBOX:]
            if out or looked:
                self.save()
        return out


def _checkin_due(c: dict[str, Any], now: dt.datetime) -> bool:
    start, end = _at({"at": c.get("from") or "08:00"}), _at({"at": c.get("to") or "21:00"})
    if not start <= now.time() <= end:
        return False  # never at night: a nudge at 3am is worse than one in the morning
    last = c.get("last")
    hours = max(1, min(12, int(c.get("every_hours") or 3)))
    return not last or now - dt.datetime.fromisoformat(last) >= dt.timedelta(hours=hours)


# ---- free, local watch checks -------------------------------------------------------------


def check_folder(w: Watch, resolve) -> list[str]:
    """New files matching the pattern since the last check. The first check
    only records what is already there."""
    folder: Path = resolve(w.spec["folder"])
    pattern = (w.spec.get("pattern") or "*").lower()
    now = {
        f.name: f.stat().st_mtime
        for f in folder.iterdir()
        if f.is_file() and fnmatch.fnmatch(f.name.lower(), pattern)
    }
    seen = w.state.get("seen")
    w.state["seen"] = sorted(now)
    if seen is None:
        return []
    return sorted(set(now) - set(seen))


class _Text(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self._skip = 0

    def handle_starttag(self, tag, attrs) -> None:
        if tag in ("script", "style", "noscript"):
            self._skip += 1

    def handle_endtag(self, tag) -> None:
        if tag in ("script", "style", "noscript") and self._skip:
            self._skip -= 1

    def handle_data(self, data) -> None:
        if not self._skip and data.strip():
            self.parts.append(data.strip())


def page_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Compii watch)"})
    with urllib.request.urlopen(req, timeout=20) as r:  # noqa: S310 - user-chosen page
        raw = r.read(2_000_000).decode(r.headers.get_content_charset() or "utf-8", errors="replace")
    p = _Text()
    p.feed(raw)
    return " ".join(p.parts)


def check_web(w: Watch, fetch=page_text) -> str | None:
    """A message when the page starts containing the text (or changes at all)."""
    text = fetch(w.spec["url"])
    wanted = (w.spec.get("contains") or "").strip()
    if wanted:
        present = wanted.lower() in text.lower()
        was = w.state.get("present")
        w.state["present"] = present
        if present and was is False:
            return f"The page now says “{wanted}”."
        if present and was is None:
            return f"The page already says “{wanted}”."
        return None
    digest = hashlib.sha256(text.encode()).hexdigest()
    before = w.state.get("hash")
    w.state["hash"] = digest
    return "The page changed." if before and before != digest else None


# ---- end of the day, and checking in ----------------------------------------------------


def _finished_at(task: Any) -> float:
    return next((float(e.get("at") or 0) for e in reversed(task.events) if e.get("type") == "task_finished"), 0.0)


def _waiting_since(task: Any) -> float:
    asks = ("approval_needed", "question", "takeover", "hiring")
    return next((float(e.get("at") or 0) for e in reversed(task.events) if e.get("type") in asks),
                float(getattr(task, "active", 0) or 0))


def _what(task: Any) -> str:
    return " ".join(str(task.request).split())[:90] or "A task"


def _join(bits: list[str]) -> str:
    return ", ".join(bits[:-1]) + (" and " if len(bits) > 1 else "") + bits[-1]


def compose_recap(*, tasks: list[Any], proactive: "Proactive", now: dt.datetime) -> Update:
    """What happened today, from the threads themselves: what landed, what stopped short, what still
    waits on the user, and what runs first tomorrow."""
    start = dt.datetime.combine(now.date(), dt.time(0, 0)).timestamp()
    today = [t for t in tasks if _finished_at(t) >= start]
    done = [t for t in today if t.status == "done"]
    short = [t for t in today if t.status in ("failed", "stopped")]
    waiting = [t for t in tasks if t.status == "waiting"]
    actions = sum(1 for t in tasks for e in t.events
                  if e.get("type") == "action_done" and e.get("ok") and float(e.get("at") or 0) >= start)
    caught = [u for u in proactive.inbox if u.kind == "watch" and u.at >= start]
    sections: list[dict[str, Any]] = []
    if done:
        sections.append({"title": "Finished today", "items": [_what(t) for t in done][:8]})
    if short:
        sections.append({"title": "Didn't finish", "items": [f"{_what(t)} ({t.status})" for t in short][:6]})
    if waiting:
        sections.append({"title": "Still waiting on you", "items": [_what(t) for t in waiting][:6]})
    if caught:
        sections.append({"title": "Your watches caught", "items": [f"{u.title}: {u.body}" for u in caught][:6]})
    tomorrow = now.date() + dt.timedelta(days=1)
    first = sorted((dt.datetime.fromisoformat(r.next_run), r.title) for r in proactive.routines.values()
                   if r.enabled and r.next_run and dt.datetime.fromisoformat(r.next_run).date() == tomorrow)
    if first:
        sections.append({"title": "Tomorrow", "items": [f"{w:%H:%M} · {t}" for w, t in first[:5]]})
    bits = []
    if done:
        bits.append(f"{len(done)} {'task' if len(done) == 1 else 'tasks'} finished")
    if actions:
        bits.append(f"{actions} {'action' if actions == 1 else 'actions'} taken")
    if short:
        bits.append(f"{len(short)} didn't finish")
    if waiting:
        bits.append(f"{len(waiting)} still {'waits' if len(waiting) == 1 else 'wait'} on you")
    summary = (_join(bits) + ".").capitalize() if bits else "A quiet day: Compii didn't do anything for you today."
    return Update("brief", "Your day, wrapped up", summary, sections=sections)


def compose_checkin(*, tasks: list[Any], told: list[str], now: dt.datetime) -> Update | None:
    """One nudge for what has waited on the user a while, or stopped short today, that they have not
    been told about yet. None when there is nothing: a check-in that finds nothing stays silent."""
    settle = now.timestamp() - 20 * 60  # an ask under 20 minutes old is still on their screen
    start = dt.datetime.combine(now.date(), dt.time(0, 0)).timestamp()
    seen = set(told)
    waiting = [t for t in tasks if t.status == "waiting" and _waiting_since(t) <= settle and t.id not in seen]
    short = [t for t in tasks if t.status == "failed" and _finished_at(t) >= start and t.id not in seen]
    if not waiting and not short:
        return None
    told.extend(t.id for t in waiting + short)
    del told[:-200]
    sections = []
    bits = []
    if waiting:
        sections.append({"title": "Waiting on you", "items": [_what(t) for t in waiting][:6]})
        bits.append(f"{len(waiting)} {'thing has' if len(waiting) == 1 else 'things have'} waited on you a while")
    if short:
        sections.append({"title": "Stopped short today", "items": [_what(t) for t in short][:6]})
        bits.append(f"{len(short)} {'task' if len(short) == 1 else 'tasks'} stopped short today")
    n = len(waiting) + len(short)
    body = _join(bits) + "."
    return Update("needs_you", "One thing needs you" if n == 1 else f"{n} things need you",
                  body[0].upper() + body[1:], task_id=(waiting or short)[0].id if n == 1 else None,
                  sections=sections)


# ---- daily brief --------------------------------------------------------------------------


def compose_brief(*, tasks: list[Any], proactive: Proactive, downloads: Path | None, now: dt.datetime) -> Update:
    """A morning summary built locally from what Compii already knows."""
    since = now.timestamp() - 24 * 3600
    sections: list[dict[str, Any]] = []

    waiting = [t for t in tasks if t.status == "waiting"]
    if waiting:
        sections.append({"title": "Needs you", "items": [t.request for t in waiting]})

    done = [t for t in tasks if t.status == "done" and t.events and t.events[-1].get("at", 0) >= since]
    if done:
        sections.append({"title": "Done since yesterday", "items": [t.request for t in done][:8]})

    caught = [u for u in proactive.inbox if u.kind == "watch" and u.at >= since]
    if caught:
        sections.append({"title": "Your watches caught", "items": [f"{u.title}: {u.body}" for u in caught][:8]})

    today = []
    end = dt.datetime.combine(now.date(), dt.time(23, 59))
    for r in proactive.routines.values():
        if r.enabled and r.next_run:
            when = dt.datetime.fromisoformat(r.next_run)
            if now <= when <= end:
                today.append((when, r.title))
    if today:
        sections.append({"title": "Coming up today", "items": [f"{w:%H:%M} · {t}" for w, t in sorted(today)]})

    if downloads and downloads.exists():
        fresh = sorted(
            (f for f in downloads.iterdir() if f.is_file() and f.stat().st_mtime >= since),
            key=lambda f: f.stat().st_mtime, reverse=True,
        )
        if fresh:
            sections.append({"title": "New in Downloads", "items": [f.name for f in fresh[:6]]
                             + ([f"…and {len(fresh) - 6} more"] if len(fresh) > 6 else [])})

    hour = now.hour
    hello = "Good morning" if hour < 12 else ("Good afternoon" if hour < 18 else "Good evening")
    bits = []
    if waiting:
        bits.append(f"{len(waiting)} {'thing needs' if len(waiting) == 1 else 'things need'} you")
    if done:
        bits.append(f"{len(done)} {'task' if len(done) == 1 else 'tasks'} finished")
    if caught:
        bits.append(f"{len(caught)} {'watch' if len(caught) == 1 else 'watches'} caught something")
    if today:
        bits.append(f"first routine at {sorted(today)[0][0]:%H:%M}")
    summary = f"{hello}. It's {now:%A, %d %B}. " + (
        (", ".join(bits[:-1]) + (" and " if len(bits) > 1 else "") + bits[-1] + ".").capitalize()
        if bits else "All quiet: nothing needs you."
    )
    return Update("brief", f"{hello} — your brief", summary, sections=sections)
