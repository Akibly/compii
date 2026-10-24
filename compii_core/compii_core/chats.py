"""The conversation archive: bots keep their threads when Core restarts.

Only what the user would see again is kept: the request, the events that
describe what happened, and a compact user/assistant history for follow-ups.
Live deltas (still-being-written words) are never stored.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

KEEP_TASKS = 300
KEEP_EVENTS = 280
KEEP_HISTORY = 24
SKIP_EVENTS = {"answer_delta"}


def _history(task: Any) -> list[dict[str, str]]:
    """The conversation as plain user/assistant text, enough to continue it."""
    out: list[dict[str, str]] = [{"role": "user", "content": task.request}]
    for e in task.events:
        kind = e.get("type")
        if kind == "user_message" and e.get("text"):
            out.append({"role": "user", "content": str(e["text"])[:4000]})
        elif kind == "task_finished" and e.get("text"):
            out.append({"role": "assistant", "content": str(e["text"])[:8000]})
    compact: list[dict[str, str]] = []
    for m in out:
        if compact and compact[-1]["role"] == m["role"]:
            compact[-1]["content"] = f"{compact[-1]['content']}\n{m['content']}"
        else:
            compact.append(dict(m))
    return compact[-KEEP_HISTORY:]


def _record(task: Any) -> dict[str, Any]:
    events = [e for e in task.events if e.get("type") not in SKIP_EVENTS][-KEEP_EVENTS:]
    return {
        "id": task.id,
        "request": task.request,
        "status": task.status,
        "created": task.created,
        "active": task.active,
        "origin": task.origin,
        "bot_id": getattr(task, "bot_id", None),
        "owner_id": getattr(task, "owner_id", None),
        "team": list(getattr(task, "team", [])),
        "events": events,
        "history": _history(task),
    }


def save(path: Path, tasks: Any) -> None:
    """Write the newest conversations. Called off the agent's critical path, so it only
    ever sees finished or in-flight snapshots; a crash costs the last turn, not the thread."""
    ordered = sorted(tasks, key=lambda t: t.active)[-KEEP_TASKS:]
    data = {"tasks": [_record(t) for t in ordered], "at": time.time()}
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)


def load(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        return list(data.get("tasks", []))
    except (OSError, ValueError, TypeError):
        path.replace(path.with_suffix(f".broken-{int(time.time())}.json"))
        return []


def restore(agent: Any, records: list[dict[str, Any]], valid_bots: set[str], fallback_bot: str | None) -> int:
    """Put the saved threads back into the agent so they open where they left off."""
    from .agent import Task

    now = time.time()
    restored = 0
    for r in records[-KEEP_TASKS:]:
        task_id = str(r.get("id") or "").strip()
        if not task_id or task_id in agent.tasks:
            continue
        created = float(r.get("created") or now)
        active = float(r.get("active") or created)
        history = [h for h in r.get("history", []) if isinstance(h, dict) and h.get("content")]
        bot_id = r.get("bot_id")
        if bot_id not in valid_bots:
            bot_id = fallback_bot
        # An archive written before threads tracked their owner keeps the speaker as the
        # owner; a deleted teammate falls back to whoever is left holding the thread.
        owner_id = r.get("owner_id") or bot_id
        if owner_id not in valid_bots:
            owner_id = bot_id
        team = [b for b in r.get("team", []) if b in valid_bots]
        if bot_id and bot_id not in team:
            team.insert(0, bot_id)
        if len(team) < 2:
            team = []  # a deleted teammate leaves a normal one-to-one thread
        status = str(r.get("status") or "done")
        events = [dict(e) for e in r.get("events", []) if isinstance(e, dict)]
        if status in ("running", "waiting"):
            status = "stopped"
            said = "Compii restarted before this finished. Ask again and I'll pick it up."
            events.append({"type": "note", "task_id": task_id, "at": now, "text": said, "bot_id": bot_id})
            events.append({"type": "task_finished", "task_id": task_id, "at": now, "status": "stopped",
                           "text": said, "bot_id": bot_id})
            while history and history[-1].get("role") == "user":
                history.pop()  # a turn that never answered: don't leave two user roles in a row
        task = Task(id=task_id, request=str(r.get("request") or ""), origin=r.get("origin"), status=status,
                    created=created, active=active, events=events, bot_id=bot_id, owner_id=owner_id, team=team,
                    messages=[{"role": h["role"], "content": h["content"]} for h in history])
        agent.tasks[task_id] = task
        restored += 1
    return restored
