"""What the paired phone is told while its app is closed.

The phone keeps one quiet connection open to `GET /phone/signals` (a long poll):
it answers the moment something needs the user, a conversation finishes, or a
brief or recap lands, and otherwise after about a minute with nothing. The phone
turns each signal into a notification; approvals carry Approve and Deny buttons
that answer `POST /approvals/{id}` without opening the app.

Signals are derived from the conversations and the inbox themselves — nothing
is queued or duplicated — so a phone that was offline catches up by asking with
the time it last heard from the PC.
"""

from __future__ import annotations

from typing import Any

MAX_SIGNALS = 20


def _title(task: Any) -> str:
    origin = getattr(task, "origin", None) or {}
    title = origin.get("title") if isinstance(origin, dict) else None
    text = " ".join(str(title or getattr(task, "request", "") or "Conversation").split())
    return text if len(text) <= 70 else text[:69] + "…"


def _short(text: str, limit: int = 220) -> str:
    one = " ".join(str(text or "").split())
    return one if len(one) <= limit else one[: limit - 1] + "…"


def pending_approvals(tasks: list[Any]) -> dict[str, tuple[Any, dict[str, Any]]]:
    """Approvals still waiting for an answer, by id."""
    out: dict[str, tuple[Any, dict[str, Any]]] = {}
    for t in tasks:
        asked = {e.get("approval_id"): e for e in t.events if e.get("type") == "approval_needed"}
        for e in t.events:
            if e.get("type") == "approval_resolved":
                asked.pop(e.get("approval_id"), None)
        if t.status in ("running", "waiting"):
            for aid, e in asked.items():
                if aid:
                    out[str(aid)] = (t, e)
    return out


def signals(tasks: list[Any], inbox: list[Any], since: float) -> dict[str, Any]:
    """Everything newer than `since`, newest last, plus the approvals still pending
    (so the phone can clear a notification that was answered on the PC)."""
    found: list[dict[str, Any]] = []
    pending = pending_approvals(tasks)
    for aid, (t, e) in pending.items():
        at = float(e.get("at") or 0)
        if at > since:
            found.append({"kind": "needs_you", "id": aid, "task_id": t.id, "at": at, "title": _title(t),
                          "body": _short(e.get("label") or e.get("why") or "Compii wants to go ahead."),
                          "why": _short(e.get("why") or "", 160)})
    for t in tasks:
        for e in t.events:
            at = float(e.get("at") or 0)
            if at <= since:
                continue
            kind = e.get("type")
            if kind == "question":
                found.append({"kind": "question", "id": str(e.get("question_id") or ""), "task_id": t.id, "at": at,
                              "title": _title(t), "body": _short(e.get("question") or "Compii has a question.")})
            elif kind == "task_finished" and t.status != "waiting":
                ok = e.get("status", t.status) == "done"
                found.append({"kind": "done" if ok else "failed", "id": f"{t.id}:{at}", "task_id": t.id, "at": at,
                              "title": _title(t),
                              "body": _short(e.get("text") or ("Done." if ok else "It didn't finish."))})
    for u in inbox:
        at = float(getattr(u, "at", 0) or 0)
        if at > since:
            found.append({"kind": "update", "id": u.id, "update": u.kind, "task_id": u.task_id or "", "at": at,
                          "title": _short(u.title, 80), "body": _short(u.body)})
    found.sort(key=lambda s: s["at"])
    newest = max([since, *(s["at"] for s in found)])
    return {"now": newest, "signals": found[-MAX_SIGNALS:], "pending": sorted(pending)}
