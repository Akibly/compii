"""One query across everything Compii keeps on this PC.

Conversations, teammates, routines and watches, taught skills, remembered facts,
clips and screen moments are searched together and ranked inside each kind.
Nothing leaves the PC, and the response only ever goes to an authenticated app.
"""

from __future__ import annotations

import re
from typing import Any

MAX_QUERY = 120
MAX_TERMS = 8
MAX_PER_GROUP = 6


def search_everything(query: str, *, agent: Any, bots: Any, skills: Any, plans: Any,
                      toolbox: Any, clips: Any, timeline: Any,
                      limit: int = MAX_PER_GROUP) -> dict[str, Any]:
    """Search every local store. Empty queries return no groups: the app shows its own entries."""
    q = " ".join(query.split())[:MAX_QUERY]
    terms = _terms(q)
    limit = max(1, min(10, int(limit)))
    if not terms:
        return {"query": q, "groups": []}

    found = (
        ("conversations", "Conversations", _conversations(agent, terms, bots)),
        ("teammates", "Teammates", _bots(bots, terms)),
        ("routines", "Routines", _routines(plans, bots, terms)),
        ("skills", "Skills", _skills(skills, terms)),
        ("memory", "Memory", _memories(toolbox, terms)),
        ("clips", "Clips", _clips(clips, terms)),
        ("screen", "On screen", _moments(timeline, terms)),
    )
    groups = []
    for kind, label, (items, total) in found:
        if items:
            groups.append({"kind": kind, "label": label, "total": total, "items": items[:limit]})
    return {"query": q, "groups": groups}


def _terms(query: str) -> list[str]:
    return [t for t in re.split(r"\s+", query.strip().lower()) if t][:MAX_TERMS]


def _match(title: str, body: str, terms: list[str]) -> int:
    """How well a title and its details answer the query; -1 when any word is missing."""
    title_l, body_l = title.lower(), body.lower()
    score = 0
    for term in terms:
        in_title = term in title_l
        if not in_title and term not in body_l:
            return -1
        if in_title:
            score += 40
            at = title_l.find(term)
            if at == 0:
                score += 40
            elif title_l[at - 1] in " \t\n-—·:,;()[]/\\":
                score += 20
        else:
            score += 8
    return score


def _excerpt(text: str, terms: list[str], width: int = 150) -> str:
    """A single-line window around the first matching word, for the second line of a result."""
    low = text.lower()
    spots = [low.find(t) for t in terms if t in low]
    if not spots:
        return ""
    at = min(spots)
    start = max(0, at - 40)
    end = min(len(text), start + width)
    line = " ".join(text[start:end].split())
    return ("…" if start else "") + line + ("…" if end < len(text) else "")


def _ranked(hits: list[tuple[int, float, dict[str, Any]]]) -> tuple[list[dict[str, Any]], int]:
    hits.sort(key=lambda h: (-h[0], -h[1]))
    return [h[2] for h in hits], len(hits)


def _conversations(agent: Any, terms: list[str], bots: Any) -> tuple[list[dict[str, Any]], int]:
    hits = []
    for task in agent.tasks.values():
        body = "\n".join(
            str(e["text"]) for e in task.events
            if e.get("type") in ("user_message", "task_finished") and isinstance(e.get("text"), str)
        )
        who = _who(task, bots)
        score = _match(task.request, f"{body}\n{who}", terms)
        if score < 0:
            continue
        excerpt = "" if all(t in task.request.lower() for t in terms) else _excerpt(body, terms)
        hits.append((score, task.created, {
            "kind": "conversation",
            "id": task.id,
            "title": task.request or "A conversation",
            "subtitle": excerpt or f"{who} · {task.status}",
            "when": task.created,
        }))
    return _ranked(hits)


def _who(task: Any, bots: Any) -> str:
    names = [_bot_name(bots, bot_id) for bot_id in (task.team or []) if bot_id]
    if names:
        return " & ".join(names)
    return _bot_name(bots, task.bot_id) if task.bot_id else "Compii"


def _bot_name(bots: Any, bot_id: str | None) -> str:
    bot = bots.get(bot_id) if bot_id else None
    return bot.name if bot else "Compii"


def _bots(bots: Any, terms: list[str]) -> tuple[list[dict[str, Any]], int]:
    hits = []
    for bot in bots.items.values():
        facts = "\n".join(bot.facts)
        score = _match(bot.name, f"{bot.job}\n{bot.instructions}\n{facts}", terms)
        if score < 0:
            continue
        subtitle = bot.job or "Teammate"
        if facts and _match(bot.name, bot.job, terms) < 0:
            found = _excerpt(facts, terms, 110)
            if found:
                subtitle = f"Remembers: {found}"
        hits.append((score, bot.created, {
            "kind": "bot",
            "id": bot.id,
            "title": bot.name,
            "subtitle": subtitle,
            "when": bot.created,
        }))
    return _ranked(hits)


def _routines(plans: Any, bots: Any, terms: list[str]) -> tuple[list[dict[str, Any]], int]:
    from .proactive import describe

    hits = []
    for routine in plans.routines.values():
        owner = _bot_name(bots, routine.bot_id) if routine.bot_id else ""
        score = _match(routine.title, f"{routine.instruction}\n{owner}", terms)
        if score < 0:
            continue
        when = describe(routine.schedule)
        hits.append((score, 0.0, {
            "kind": "routine",
            "id": routine.id,
            "title": routine.title,
            "subtitle": f"{when} · {owner}" if owner else when,
            "when": None,
        }))
    for watch in plans.watches.values():
        what = _watch_what(watch)
        details = " ".join(str(v) for v in (watch.spec or {}).values())
        score = _match(watch.title, f"{what}\n{details}", terms)
        if score < 0:
            continue
        hits.append((score, 0.0, {
            "kind": "watch",
            "id": watch.id,
            "title": watch.title,
            "subtitle": f"{what} · every {watch.every_minutes} min",
            "when": None,
        }))
    return _ranked(hits)


def _watch_what(watch: Any) -> str:
    spec = watch.spec or {}
    if watch.kind == "folder":
        pattern = spec.get("pattern") or "files"
        folder = str(spec.get("folder") or "")
        name = re.split(r"[\\/]", folder.rstrip("\\/"))[-1] or folder
        return f"New {pattern} in {name}"
    if watch.kind == "web":
        return f"Changes to {spec.get('url') or 'a page'}"
    return str(spec.get("check") or "Something to watch")


def _skills(skills: Any, terms: list[str]) -> tuple[list[dict[str, Any]], int]:
    hits = []
    for skill in skills.items.values():
        score = _match(skill.name, f"{skill.about}\n{skill.instruction}\n{' '.join(skill.steps)}", terms)
        if score < 0:
            continue
        hits.append((score, skill.created, {
            "kind": "skill",
            "id": skill.id,
            "title": skill.name,
            "subtitle": skill.about or "A skill you taught Compii",
            "when": skill.created,
        }))
    return _ranked(hits)


def _memories(toolbox: Any, terms: list[str]) -> tuple[list[dict[str, Any]], int]:
    hits = []
    for memory in toolbox.memories():
        fact = str(memory.get("fact") or "")
        score = _match(fact, "", terms)
        if score < 0:
            continue
        hits.append((score, float(memory.get("at") or 0), {
            "kind": "memory",
            "id": memory.get("id"),
            "title": fact,
            "subtitle": "Saved memory",
            "when": memory.get("at"),
        }))
    return _ranked(hits)


def _clips(clips: Any, terms: list[str]) -> tuple[list[dict[str, Any]], int]:
    query = " ".join(terms)
    hits: list[tuple[int, float, dict[str, Any]]] = []
    for snippet in clips.snippets.search(query):
        score = _match(str(snippet.get("name") or ""), str(snippet.get("body") or ""), terms)
        if score < 0:
            continue
        hits.append((score + 5, float(snippet.get("created") or 0), {
            "kind": "snippet",
            "id": snippet.get("id"),
            "title": snippet.get("name") or "A snippet",
            "subtitle": "A snippet you saved",
            "when": snippet.get("created"),
        }))
    for clip in clips.search(query, limit=40):
        preview = " ".join(str(clip.get("preview") or "").split())[:160]
        score = _match(preview, str(clip.get("app") or ""), terms)
        if score < 0:
            continue
        app = str(clip.get("app") or "").strip()
        hits.append((score, float(clip.get("at") or 0), {
            "kind": "clip",
            "id": clip.get("id"),
            "title": preview or "A copied clip",
            "subtitle": f"Copied from {app}" if app else "Copied",
            "when": clip.get("at"),
        }))
    return _ranked(hits)


def _moments(timeline: Any, terms: list[str]) -> tuple[list[dict[str, Any]], int]:
    hits = []
    for moment in timeline.search(" ".join(terms), limit=40):
        app = str(moment.get("app") or "").strip()
        title = str(moment.get("title") or "").strip() or app or "A moment on screen"
        excerpt = str(moment.get("excerpt") or "").strip()
        score = _match(title, f"{app}\n{excerpt}\n{moment.get('text') or ''}", terms)
        if score < 0:
            continue
        hits.append((score, float(moment.get("started") or 0), {
            "kind": "moment",
            "id": moment.get("id"),
            "title": title,
            "subtitle": excerpt or app or "Seen on screen",
            "when": moment.get("started"),
        }))
    return _ranked(hits)
