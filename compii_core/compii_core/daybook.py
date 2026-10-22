"""Catch me up: a local daybook of tasks, actions and (if on) screen moments.

Everything is read from stores already on this PC. The result can be spoken,
read in the app, or handed to the agent as a tool result.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from datetime import datetime
from typing import Any

from .policy import ActionKind
from .tools import Tool, ToolResult

MAX_ACTIONS = 40
MAX_DONE = 12
MAX_WAITING = 8
MAX_APPS = 8


def _when(ts: float, now: datetime) -> str:
    dt = datetime.fromtimestamp(ts)
    return f"{dt:%H:%M}" if dt.date() == now.date() else f"{dt:%d %b %H:%M}"


def _short(text: str, width: int = 160) -> str:
    line = " ".join(str(text).split())
    return line if len(line) <= width else line[: width - 1] + "…"


def _last_at(task: Any) -> float:
    return float(task.events[-1].get("at", 0)) if task.events else 0.0


def _request(task: Any) -> str:
    return _short(task.request, 120)


def build_daybook(*, tasks: list[Any], journal: Any, timeline: Any = None, hours: int = 24,
                  until: float | None = None, now: datetime | None = None) -> dict[str, Any]:
    """The day (or a past day, with `until`) read back from what this PC already keeps."""
    now = now or datetime.now()
    hours = max(1, min(168, int(hours)))
    since = time.time() - hours * 3600
    until = float(until) if until else time.time()

    done = []
    for t in sorted(tasks, key=_last_at, reverse=True):
        at = _last_at(t)
        if t.status == "done" and since <= at <= until:
            done.append({"id": t.id, "request": _request(t), "at": at, "bot_id": t.bot_id,
                         "origin": t.origin, "status": t.status})
        if len(done) >= MAX_DONE:
            break

    waiting = []
    for t in sorted((t for t in tasks if t.status in ("running", "waiting")), key=_last_at, reverse=True):
        if _last_at(t) > until:
            continue  # it started needing them after this record closes
        last = next((str(e.get("text") or "") for e in reversed(t.events) if e.get("text")), "")
        waiting.append({"id": t.id, "request": _request(t), "status": t.status, "at": _last_at(t),
                        "last": _short(last, 180)})
        if len(waiting) >= MAX_WAITING:
            break

    requests = {t.id: _request(t) for t in tasks}
    actions = []
    latest_undoable: dict[str, str] = {}
    for e in sorted(journal.entries(), key=lambda e: e.at, reverse=True):
        if e.at < since:
            continue
        if e.ok and e.undo and not e.undo.get("done") and e.task_id not in latest_undoable:
            latest_undoable[e.task_id] = e.id
    for e in sorted((e for e in journal.entries() if since <= e.at <= until), key=lambda e: e.at, reverse=True):
        can_undo = bool(e.ok and e.undo and not e.undo.get("done")
                        and latest_undoable.get(e.task_id) == e.id)
        actions.append({"id": e.id, "task_id": e.task_id, "tool": e.tool, "kind": e.kind,
                        "summary": _short(e.summary, 200), "at": e.at, "ok": e.ok, "can_undo": can_undo,
                        "about": requests.get(e.task_id, "")})
        if len(actions) >= MAX_ACTIONS:
            break

    screen: dict[str, Any] = {"enabled": False, "apps": []}
    if timeline is not None:
        try:
            enabled = bool(timeline.settings.enabled)
            if enabled:
                groups: dict[str, dict[str, Any]] = {}
                for row in timeline.search("", after=since, before=until, limit=200):
                    app = row.get("app") or "Other"
                    g = groups.setdefault(app, {"app": app, "moments": 0, "titles": [], "last": 0.0})
                    g["moments"] += 1
                    g["last"] = max(g["last"], float(row.get("started") or 0))
                    title = _short(row.get("title") or "", 70)
                    if title and title not in g["titles"] and len(g["titles"]) < 3:
                        g["titles"].append(title)
                apps = sorted(groups.values(), key=lambda g: (g["moments"], g["last"]), reverse=True)
                screen = {"enabled": True, "apps": apps[:MAX_APPS]}
        except Exception:  # noqa: BLE001 - a broken timeline must not break the daybook
            screen = {"enabled": False, "apps": []}

    undo = None
    for a in actions:
        if a["can_undo"]:
            undo = {"id": a["id"], "task_id": a["task_id"], "summary": a["summary"]}
            break

    left_off = None
    if waiting:
        left_off = {"task_id": waiting[0]["id"], "request": waiting[0]["request"], "status": waiting[0]["status"],
                    "last": waiting[0]["last"], "at": waiting[0]["at"]}
    elif actions:
        a = actions[0]
        left_off = {"task_id": a["task_id"], "request": a["about"], "status": "done", "last": a["summary"],
                    "at": a["at"]}

    parts = []
    if done:
        parts.append(f"{len(done)} {'task' if len(done) == 1 else 'tasks'} finished")
    if waiting:
        parts.append(f"{len(waiting)} still {'needs' if len(waiting) == 1 else 'need'} you")
    if actions:
        parts.append(f"{len(actions)} {'action' if len(actions) == 1 else 'actions'} taken")
    if screen["apps"]:
        parts.append(f"{len(screen['apps'])} {'app' if len(screen['apps']) == 1 else 'apps'} on screen")
    headline = ("In the last " + ("day" if hours == 24 else f"{hours} hours") + ": "
                + ", ".join(parts) + ".") if parts else (
        "A quiet stretch: nothing was finished, changed or recorded.")

    book = {"since": since, "until": until, "hours": hours, "headline": headline, "parts": parts,
            "counts": {"done": len(done), "waiting": len(waiting), "actions": len(actions),
                       "apps": len(screen["apps"])},
            "done": done, "waiting": waiting, "actions": actions, "undo": undo,
            "screen": screen, "left_off": left_off}
    book["markdown"] = format_daybook(book, now=now)
    return book


def format_daybook(book: dict[str, Any], *, now: datetime | None = None, heading: str | None = None,
                   show_titles: bool = True, undo_hints: bool = True) -> str:
    """Render the book. A journal entry on disk asks for a plain heading, no window titles
    (those stay in the rolling screen memory, not in a file that lasts), and no undo hints."""
    now = now or datetime.now()
    lines = [f"**{heading or book['headline']}**"]
    if book["done"]:
        lines += ["", "### Finished"]
        for t in book["done"]:
            via = ""
            origin = t.get("origin") or {}
            if isinstance(origin, dict) and origin.get("title"):
                via = f" (from {origin['title']})"
            lines.append(f"- {_when(t['at'], now)} · {t['request']}{via}")
    if book["waiting"]:
        lines += ["", "### Still open"]
        for t in book["waiting"]:
            detail = f" — {t['last']}" if t.get("last") else ""
            lines.append(f"- {t['request']}{detail}")
    if book["actions"]:
        lines += ["", "### What Compii did"]
        for a in book["actions"][:MAX_ACTIONS]:
            mark = "" if a["ok"] else " (failed)"
            about = f" · {a['about']}" if a.get("about") else ""
            undo = " · can be undone" if undo_hints and a["can_undo"] else ""
            lines.append(f"- {_when(a['at'], now)} · {a['summary']}{mark}{about}{undo}")
    if book["screen"]["enabled"]:
        lines += ["", "### On screen (your screen memory)"]
        if book["screen"]["apps"]:
            for g in book["screen"]["apps"]:
                titles = ", ".join(f"“{t}”" for t in g["titles"]) if show_titles else ""
                lines.append(f"- {g['app']} · {g['moments']} {'moment' if g['moments'] == 1 else 'moments'}"
                             + (f" · {titles}" if titles else ""))
        else:
            lines.append("- Screen memory is on, but nothing was recorded in this time.")
    if book["left_off"]:
        lines += ["", "### Where you left off"]
        left = book["left_off"]
        if left.get("request"):
            lines.append(f"- **{left['request']}**" + (f" — {left['last']}" if left.get("last") else ""))
        elif left.get("last"):
            lines.append(f"- {left['last']}")
        if left.get("status") == "waiting":
            lines.append("- This one is waiting for you; open Compii to answer.")
        elif left.get("status") == "running":
            lines.append("- This one is still running.")
    if len(lines) == 1:
        lines += ["", "Nothing has been done or recorded in this time. Ask Compii to start something, and it will "
                      "show up here."]
    return "\n".join(lines)


def daybook_tool(tasks: Callable[[], list[Any]], journal: Any, timeline: Any = None) -> Tool:
    def catch(a: dict[str, Any]) -> ToolResult:
        try:
            hours = int(a.get("hours") or 24)
        except (TypeError, ValueError):  # the model writes its own arguments
            hours = 24
        book = build_daybook(tasks=tasks(), journal=journal, timeline=timeline, hours=hours)
        return ToolResult("Here is the user's own local daybook. Treat it as fact; do not add things that are not in "
                          "it:\n\n" + book["markdown"])

    return Tool(
        "catch_me_up",
        "Catch the user up on their day from this PC: tasks finished, what Compii did, what was on screen (only if "
        "screen memory is on), and where they left off. Use it for 'catch me up', 'what did I do today?', 'where "
        "was I?', or when the user comes back after a while.",
        {"hours": {"type": "integer", "description": "How far back to look, 1–168 hours (default 24)."}},
        [], ActionKind.READ, catch, lambda a: f"Catch up on the last {a.get('hours') or 24} hours")
