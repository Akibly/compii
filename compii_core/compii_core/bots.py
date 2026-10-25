"""Bots: the user's named teammates, each with a job, a way of working and its own memory.

A bot is a role Compii wears for a conversation, not a separate AI. The first
one is Compii itself; the rest are specialists the user creates from a template
or from scratch. Bots keep their conversations (see chats.py) and remember
things that belong to their job, separate from what Compii knows about the user.
"""

from __future__ import annotations

import json
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

COLORS = ["#3F86FF", "#27C3E0", "#7A6BFF", "#FF9C3D", "#3DD68C", "#FF6FAE", "#B45CFF", "#F4D35E"]
# The glass forms the app knows how to paint, as `a3.<form>.<seed>`. Older
# `a1` and `a2` tokens still parse in the app, mapped onto these forms.
AVATAR_SHAPES = ["orb", "tile", "pill", "tower", "gem"]
MAX_FACTS = 200
MAX_NAME = 40
MAX_JOB = 120
MAX_INSTRUCTIONS = 4000
MAX_MODEL = 80
TRUST_LEVELS = ("probation", "trusted", "full")

# How a teammate works with the rest of the team. Compii itself is always "lead".
#   solo - one lane, one agent: nothing is handed to anyone else
#   team - can pull a specialist in for part of a job and review what comes back
#   lead - can also suggest new teammates when a role is missing
MODE_LABELS = {"solo": "Solo", "team": "Team player", "lead": "Team lead"}
MODE_NOTES = {
    "solo": "Works alone in its lane and never hands work to another teammate.",
    "team": "Can hand part of a job to another specialist, check the result, and send it back if it falls short.",
    "lead": "Coordinates the team and can suggest a new teammate when a role is missing.",
}

# What each teammate can actually touch. A bot stores pack keys, not tool names,
# so the packs can grow without any saved bot losing access. Empty = every tool.
TOOL_PACKS: dict[str, dict[str, Any]] = {
    "web": {
        "label": "Web & research",
        "description": "Search, read pages, use its own browser and cross-check sources.",
        "tools": ["search_web", "read_web_page", "browse", "read_page", "browser_click", "browser_fill",
                  "reach_research", "reach_platform", "reach_status", "second_opinion", "weather", "world_time"],
    },
    "files": {
        "label": "Files & documents",
        "description": "Find, read, write, move, zip, compare and convert files, PDFs, sheets and decks.",
        "tools": ["list_folder", "find_files", "read_file", "search_in_files", "compare_documents",
                  "find_duplicate_files", "write_text_file", "create_folder", "move_file", "move_to_trash",
                  "zip_files", "unzip", "merge_pdfs", "split_pdf", "read_pdf", "fill_pdf_form",
                  "create_document", "create_deck", "create_spreadsheet"],
    },
    "mail": {
        "label": "Mail & calendar",
        "description": "Read and draft mail, and read the calendar. Sending still asks first.",
        "tools": ["send_email", "read_outlook_mail", "read_outlook_message", "read_outlook_calendar",
                  "read_outlook_contacts", "create_outlook_event", "send_outlook_mail"],
    },
    "schedule": {
        "label": "Routines & watches",
        "description": "Create and manage routines, watches and reminders.",
        "tools": ["create_routine", "create_watch", "list_routines_and_watches", "remove_routine_or_watch",
                  "noticed_habits"],
    },
    "screen": {
        "label": "Screen & apps",
        "description": "See the screen, read windows, click, type, point and show what it means.",
        "tools": ["screenshot", "look_at_screen", "clipboard", "list_windows", "focus_window", "read_window",
                  "read_selection", "click_on", "type_into", "press_keys", "point_at", "draw_on_screen",
                  "start_walkthrough", "open_item"],
    },
    "code": {
        "label": "Code & data",
        "description": "Run Python for calculations, data work and conversions.",
        "tools": ["run_python"],
    },
    "knowledge": {
        "label": "Memory & knowledge",
        "description": "Remember, recall, search your own files, skills, snippets, projects and journal.",
        "tools": ["remember", "recall", "ask_my_files", "catch_me_up", "work_journal", "search_clips",
                  "search_screen_memory", "forget_screen_memory", "usage_report", "undo_action", "list_skills",
                  "use_skill", "save_skill", "replay_skill", "start_lesson", "update_lesson", "start_project",
                  "update_project", "project_status", "view_profile", "set_profile", "fill_form", "form_fields",
                  "answer_questions", "list_snippets", "save_snippet", "use_snippet", "delete_snippet",
                  "forget_memory", "activity_log"],
    },
    "system": {
        "label": "PC controls",
        "description": "Check the system, set volume and brightness, control media.",
        "tools": ["system_status", "set_volume", "set_brightness", "media_control", "world_time"],
    },
    "leads": {
        "label": "Leads & outreach",
        "description": "Keep a lead list and plan outreach. Nothing is sent.",
        "tools": ["list_leads", "save_leads", "plan_marketing"],
    },
}
PACK_KEYS = tuple(TOOL_PACKS)


def packs_view() -> list[dict[str, Any]]:
    """The catalogue the app shows when choosing a teammate's lane."""
    return [{"key": key, "label": pack["label"], "description": pack["description"],
             "count": len(pack["tools"]), "tools": pack["tools"]}
            for key, pack in TOOL_PACKS.items()]


def tools_for(packs: list[str] | None) -> set[str] | None:
    """Every tool those packs allow, or None when the bot uses everything."""
    keys = [k for k in (packs or []) if k in TOOL_PACKS]
    if not keys:
        return None
    return {name for key in keys for name in TOOL_PACKS[key]["tools"]}

# Ready-made roles, shown when the user makes a bot. Each brief stays inside
# Compii's safety rules: drafts, not sends; approvals stay on.
TEMPLATES: list[dict[str, str]] = [
    {
        "key": "chief", "category": "Personal", "name": "Chief of Staff", "avatar": "a3.pill.7", "color": "#FF9C3D",
        "job": "Keeps the whole team pointed at what matters today",
        "instructions": "You coordinate the user's other bots and their own work. Keep a short view of what is "
                        "running, what is waiting on the user, and what can be handed to a specialist. Break big "
                        "requests into clear owners, and check that the result actually landed. Only bring the user "
                        "in for a judgement call or an approval.",
    },
    {
        "key": "inbox", "category": "Personal", "name": "Inbox Manager", "avatar": "a3.tower.12", "color": "#27C3E0",
        "job": "Triage mail and leave replies ready to send",
        "instructions": "Read the user's mail, sort what needs them from what can wait, and draft replies in their "
                        "voice. Never send, accept or delete anything yourself: leave drafts and a short list for "
                        "approval. Flag anything with a deadline or money in it first.",
    },
    {
        "key": "researcher", "category": "Research", "name": "Researcher", "avatar": "a3.orb.31", "color": "#3F86FF",
        "job": "Turns a question into a sourced brief",
        "instructions": "Research with search_web and read_web_page, prefer official and recent sources, and keep a "
                        "real link for every important claim. Separate what is verified from what is inferred. "
                        "Deliver a short summary first, then findings with sources; save longer work as a document.",
    },
    {
        "key": "scheduler", "category": "Personal", "name": "Scheduler", "avatar": "a3.tile.5", "color": "#3DD68C",
        "job": "Owns the calendar, routines and reminders",
        "instructions": "Turn the user's words into exact schedules, create routines and watches, and check for "
                        "clashes before proposing a time. Confirm every schedule in one sentence. Never accept an "
                        "invite or send one without the user's approval.",
    },
    {
        "key": "clerk", "category": "Personal", "name": "File Clerk", "avatar": "a3.tower.19", "color": "#3DD68C",
        "job": "Keeps files and folders in order",
        "instructions": "Sort, rename and file things in the folders Compii may use. Use move_to_trash rather than "
                        "deleting, show a short list of what changed, and check the folder afterwards so the answer "
                        "is true. Ask before touching anything outside the usual folders.",
    },
    {
        "key": "coder", "category": "Engineering", "name": "Coder", "avatar": "a3.gem.11", "color": "#7A6BFF",
        "job": "Writes, runs and fixes small programs",
        "instructions": "Read the surrounding code before changing it, keep changes small, and run the result to "
                        "check it. Explain failures plainly instead of guessing. Never run anything destructive or "
                        "expose secrets; ask before installing packages.",
    },
    {
        "key": "analyst", "category": "Engineering", "name": "Data Analyst", "avatar": "a3.orb.42", "color": "#FF6FAE",
        "job": "Answers questions from spreadsheets and data",
        "instructions": "Inspect the sheet's headers and sample rows before computing anything, use run_python for "
                        "the maths, and keep the original file unchanged. Show the numbers that matter, say how they "
                        "were calculated, and save a clean spreadsheet or document when the user will reuse it.",
    },
    {
        "key": "sales", "category": "Sales", "name": "Sales Outbound", "avatar": "a3.gem.9", "color": "#FF5A5A",
        "job": "Finds prospects and drafts outreach for approval",
        "instructions": "Research accounts from public sources, score them against what the user sells, and draft "
                        "short, specific outreach in their voice. Everything stays a draft: never send, post or "
                        "contact anyone. Leave a review list with the evidence behind each pick.",
    },
    {
        "key": "ops", "category": "Operations", "name": "Ops Manager", "avatar": "a3.pill.23", "color": "#FF9C3D",
        "job": "Handles invoices, expenses and recurring operations",
        "instructions": "Process documents end to end: read them, extract the details, put them in the right sheet "
                        "or folder, and flag anything unusual. Payments and submissions always wait for the user's "
                        "approval. Keep a checklist for multi-step jobs and close every step.",
    },
    {
        "key": "travel", "category": "Personal", "name": "Travel Planner", "avatar": "a3.gem.3", "color": "#27C3E0",
        "job": "Plans trips down to the booking links",
        "instructions": "Ask for dates and budget only if they are missing, then research routes, stays and prices "
                        "with real links. Build a day-by-day plan with travel time between stops. Never book or pay: "
                        "present the options and the links.",
    },
    {
        "key": "coach", "category": "Learning", "name": "Study Coach", "avatar": "a3.tile.17", "color": "#3F86FF",
        "job": "Teaches things step by step and checks you did them",
        "instructions": "Teach one small step at a time, show it on screen when the app is open, and use "
                        "watch_for_step to notice when the user has done it so you can move on. Adapt to what they "
                        "already know, and celebrate real progress briefly.",
    },
    {
        "key": "critic", "category": "Design", "name": "Design Critic", "avatar": "a3.gem.29", "color": "#FF6FAE",
        "job": "Gives direct, useful feedback on visuals and decks",
        "instructions": "Look at the actual screen or file before commenting. Name what works, what does not, and "
                        "the smallest change that would fix it. Be specific about spacing, hierarchy, contrast and "
                        "copy; avoid vague taste talk.",
    },
]
TEMPLATE_BY_KEY = {t["key"]: t for t in TEMPLATES}

# Each ready-made role comes with the lane it needs, not the whole toolbox.
_TEMPLATE_LANES: dict[str, tuple[str, list[str]]] = {
    "chief": ("lead", []),
    "inbox": ("team", ["mail", "schedule", "knowledge"]),
    "researcher": ("team", ["web", "files", "knowledge"]),
    "scheduler": ("team", ["schedule", "mail", "knowledge"]),
    "clerk": ("team", ["files", "knowledge"]),
    "coder": ("team", ["code", "files"]),
    "analyst": ("team", ["code", "files"]),
    "sales": ("team", ["web", "leads", "knowledge"]),
    "ops": ("team", ["files", "mail", "code", "knowledge"]),
    "travel": ("team", ["web", "knowledge"]),
    "coach": ("team", ["screen", "web", "knowledge"]),
    "critic": ("team", ["screen", "files", "knowledge"]),
}
for _t in TEMPLATES:
    _mode, _tools = _TEMPLATE_LANES.get(_t["key"], ("team", []))
    _t["mode"], _t["tools"] = _mode, list(_tools)

DEFAULT_INSTRUCTIONS = (
    "Do the task, don't describe how the user could do it. Carry it through to the end, verify what you changed, "
    "and say briefly what landed and where. Ask only when a decision or an approval is genuinely needed."
)


@dataclass
class Bot:
    name: str
    job: str = ""
    instructions: str = ""
    color: str = "#3F86FF"
    avatar: str = ""
    id: str = field(default_factory=lambda: "b" + uuid.uuid4().hex[:8])
    created: float = field(default_factory=time.time)
    pinned: bool = False
    primary: bool = False
    # New teammates start on probation: they may read and prepare drafts, but every
    # change asks and sending, deleting or paying is off until the user trusts them.
    trust: str = "probation"
    facts: list[str] = field(default_factory=list)
    # How it works with the rest of the team, and which packs of tools it may use.
    mode: str = "team"
    tools: list[str] = field(default_factory=list)  # empty = everything
    # The AI this teammate answers with. Empty means Compii's own choice from Settings, so a
    # bot stays on the shared brain until the user names one: a role is not a model.
    provider: str = ""
    model: str = ""
    # Which ready-made role it was started from, so a directory can group it. "" = made from scratch.
    template: str = ""
    # Put away, not deleted: the role, what it learnt and its conversations stay, but it is out
    # of the team Compii can hand work to and takes no new conversation until it is brought back.
    archived: bool = False

    def view(self) -> dict[str, Any]:
        data = asdict(self)
        if self.primary:
            data["trust"] = "full"
            data["mode"] = "lead"
        data["category"] = TEMPLATE_BY_KEY.get(self.template, {}).get("category", "")
        return data

    def prompt(self) -> str:
        job = f"\nYour job: {self.job}" if self.job else ""
        how = f"\nHow you work, in the user's words: {self.instructions}" if self.instructions else ""
        facts = ""
        if self.facts:
            facts = ("\nWhat you have learned for this bot (use remember_bot to add more; these are yours, not "
                     "general facts about the user):\n" + "\n".join(f"- {f}" for f in self.facts[-60:]))
        if self.primary:
            return ("You are Compii, the user's assistant, and the lead of their team of bots. Stay in that role for "
                    "the whole conversation, and never claim work you did not verify. When the user asks for a new "
                    "teammate or agent, that is work only you can do: call propose_teammate in the same turn, with a "
                    "suggested name, the job in one line and why. The hiring card is what creates it - saying you'll "
                    "make one does nothing.")
        probation = (
            "\nThe user keeps you on probation: you may read and prepare drafts, but sending, deleting, paying and "
            "contacting anyone are off, and every change asks them first. Say plainly what they still need to do "
            "themselves."
            if self.trust == "probation" else
            "\nThe user trusts you with the normal approval rules: ordinary changes may go ahead, and anything that "
            "sends, spends or deletes still asks first."
        )
        teamwork = {
            "solo": "\nYou work alone in this lane: finish what you can yourself and never hand work to another teammate.",
            "team": ("\nYou may pull in another teammate with delegate when part of a job is clearly theirs, then check "
                     "what comes back and review it. You stay responsible for the whole result."),
            "lead": ("\nYou lead this team: split the work, delegate the parts that belong to a specialist, check and "
                     "review what comes back, and keep the user's picture in one place."),
        }.get(self.mode, "")
        return (f"You are {self.name}, one of Compii's teammates, working for this user. You run on Compii — the same "
                f"assistant underneath — but this thread is yours, in your lane, and the user comes back to you here.{job}"
                f"{how}{facts}{probation}{teamwork}\nWork inside your lane. If a request belongs to another teammate, say in "
                f"one sentence whose job it is; if it belongs to no one, say Compii should take it. Stay in this role for "
                f"the whole conversation, never pretend to be a different AI or a human, and never claim work you did "
                f"not verify.")


def avatar_for(name: str) -> str:
    """A character that only depends on the name, so a teammate looks the same
    every time before anyone has chosen one."""
    h = 2166136261
    for ch in name:
        h = ((h ^ ord(ch)) * 16777619) & 0xFFFFFFFF
    return f"a3.{AVATAR_SHAPES[h % len(AVATAR_SHAPES)]}.{h % 9973 + 1}"


def _clean(text: str, limit: int) -> str:
    return " ".join(str(text or "").split())[:limit].strip()


def _clean_mode(mode: str) -> str:
    mode = str(mode or "").strip().lower()
    if mode not in MODE_LABELS:
        raise ValueError("A teammate works either solo, as a team player, or as a team lead.")
    return mode


def _clean_model(text: str) -> str:
    """A provider or model id is a machine name: one line, no room for a sentence."""
    return " ".join(str(text or "").split())[:MAX_MODEL].strip()


def _clean_tools(tools: list[str] | None) -> list[str]:
    keys = [str(k).strip() for k in (tools or []) if str(k).strip()]
    unknown = [k for k in keys if k not in TOOL_PACKS]
    if unknown:
        raise ValueError(f"Unknown tool lane: {', '.join(unknown)}.")
    return list(dict.fromkeys(keys))


class Bots:
    """The bot registry, saved to the workspace."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.RLock()
        self.items: dict[str, Bot] = {}
        self._load()
        if not self.items:
            primary = self._primary()
            self.items[primary.id] = primary
            self.save()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8-sig"))
            for d in data.get("bots", []):
                bot = Bot(**{k: v for k, v in d.items() if k in Bot.__dataclass_fields__})
                bot.facts = [str(f) for f in bot.facts][-MAX_FACTS:]
                bot.tools = [k for k in bot.tools if k in TOOL_PACKS]
                if not bot.avatar:
                    bot.avatar = avatar_for(bot.name)
                if bot.primary:
                    bot.trust = "full"
                    bot.mode = "lead"
                    bot.tools = []
                elif bot.trust not in TRUST_LEVELS:
                    bot.trust = "probation"
                if bot.mode not in MODE_LABELS:
                    bot.mode = "team"
                self.items[bot.id] = bot
        except (OSError, ValueError, TypeError):
            self.path.replace(self.path.with_suffix(f".broken-{int(time.time())}.json"))

    def save(self) -> None:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"bots": [b.view() for b in self.items.values()]}, indent=1, ensure_ascii=False),
                           encoding="utf-8")
            tmp.replace(self.path)

    def _primary(self) -> Bot:
        return Bot("Compii", "Your right hand on this PC", DEFAULT_INSTRUCTIONS, COLORS[0],
                  avatar="a3.orb.1", primary=True, trust="full", mode="lead")

    def get(self, bot_id: str | None) -> Bot | None:
        if not bot_id:
            return self.primary()
        return self.items.get(bot_id)

    def primary(self) -> Bot | None:
        return next((b for b in self.items.values() if b.primary), None) or next(iter(self.items.values()), None)

    def view(self) -> list[dict[str, Any]]:
        # An archived teammate sorts last: the directory still knows it — its conversations have
        # to keep showing who answered — but it is not the team the user sees first.
        order = sorted(self.items.values(), key=lambda b: (not b.primary, not b.pinned, b.archived, -b.created))
        return [b.view() for b in order]

    def active(self) -> list[Bot]:
        """The team as it stands today: everyone who can be talked to or handed work."""
        return [b for b in self.items.values() if not b.archived]

    def create(self, name: str, *, job: str = "", instructions: str = "", color: str = "",
               template: str = "", avatar: str = "", mode: str = "", tools: list[str] | None = None,
               provider: str = "", model: str = "") -> Bot:
        named = TEMPLATE_BY_KEY.get(template, {})
        name = _clean(name or named.get("name", ""), MAX_NAME)
        if not name:
            raise ValueError("A bot needs a name.")
        # An archived teammate keeps its name out of the way: hiring "Ana" again while the old
        # Ana is put away is normal, and bringing the old one back is what causes a clash.
        if any(not b.archived and b.name.lower() == name.lower() for b in self.items.values()):
            raise ValueError(f"There is already a bot called “{name}”.")
        bot = Bot(
            name=name,
            job=_clean(job or named.get("job", ""), MAX_JOB),
            instructions=_clean(instructions or named.get("instructions", ""), MAX_INSTRUCTIONS),
            color=(color or named.get("color") or COLORS[0])[:9],
            avatar=(avatar or named.get("avatar") or avatar_for(name))[:48],
            mode=_clean_mode(mode or named.get("mode", "team")),
            tools=_clean_tools(tools if tools is not None else named.get("tools", [])),
            provider=_clean_model(provider),
            model=_clean_model(model),
            template=template if template in TEMPLATE_BY_KEY else "",
        )
        with self._lock:
            self.items[bot.id] = bot
            self.save()
        return bot

    def update(self, bot_id: str, **changes: Any) -> Bot:
        bot = self.items.get(bot_id)
        if bot is None:
            raise KeyError(bot_id)
        with self._lock:
            if "name" in changes and changes["name"] is not None:
                name = _clean(changes["name"], MAX_NAME)
                if not name:
                    raise ValueError("A bot needs a name.")
                if any(b.id != bot.id and not b.archived and b.name.lower() == name.lower()
                       for b in self.items.values()):
                    raise ValueError(f"There is already a bot called “{name}”.")
                bot.name = name
            if "job" in changes and changes["job"] is not None:
                bot.job = _clean(changes["job"], MAX_JOB)
            if "instructions" in changes and changes["instructions"] is not None:
                bot.instructions = _clean(changes["instructions"], MAX_INSTRUCTIONS)
            if "color" in changes and changes["color"]:
                bot.color = str(changes["color"])[:9]
            if "avatar" in changes and changes["avatar"] is not None:
                bot.avatar = str(changes["avatar"])[:48]
            if "pinned" in changes and changes["pinned"] is not None:
                bot.pinned = bool(changes["pinned"])
            if "archived" in changes and changes["archived"] is not None:
                if bot.primary:
                    raise ValueError("Compii is the team: it cannot be put away.")
                # Away, or back — and only a real yes/no reaches this, never a stray string.
                if not isinstance(changes["archived"], bool):
                    raise ValueError("Archive is a yes or a no.")
                away = changes["archived"]
                if not away and any(b.id != bot.id and not b.archived and b.name.lower() == bot.name.lower()
                                    for b in self.items.values()):
                    raise ValueError(f"There is already a bot called “{bot.name}”.")
                bot.archived = away
                if bot.archived:
                    bot.pinned = False
            if "trust" in changes and changes["trust"] is not None:
                if bot.primary:
                    raise ValueError("Compii always has full trust.")
                trust = str(changes["trust"]).strip().lower()
                if trust not in ("probation", "trusted"):
                    raise ValueError("Trust is either probation or trusted.")
                bot.trust = trust
            if "mode" in changes and changes["mode"] is not None:
                if bot.primary:
                    raise ValueError("Compii always leads the team.")
                bot.mode = _clean_mode(str(changes["mode"]))
            if "tools" in changes and changes["tools"] is not None:
                if bot.primary:
                    raise ValueError("Compii uses every tool; its lane can't be narrowed.")
                bot.tools = _clean_tools(changes["tools"])
            if "provider" in changes and changes["provider"] is not None:
                if bot.primary:
                    raise ValueError("Compii answers with the AI you chose in Settings.")
                bot.provider = _clean_model(str(changes["provider"]).strip().lower())
                if not bot.provider:
                    bot.model = ""
            if "model" in changes and changes["model"] is not None:
                if bot.primary:
                    raise ValueError("Compii answers with the AI you chose in Settings.")
                bot.model = _clean_model(str(changes["model"]))
                if bot.model and not bot.provider:
                    raise ValueError("Say which AI offers that model first.")
            self.save()
        return bot

    def delete(self, bot_id: str) -> bool:
        bot = self.items.get(bot_id)
        if bot is None:
            return False
        if bot.primary:
            raise ValueError("The primary bot can be renamed, but not removed.")
        with self._lock:
            self.items.pop(bot_id, None)
            self.save()
        return True

    def add_fact(self, bot_id: str, fact: str) -> str:
        bot = self.items.get(bot_id)
        if bot is None:
            raise KeyError(bot_id)
        text = _clean(fact, 300)
        if not text:
            raise ValueError("Nothing to remember.")
        with self._lock:
            if text not in bot.facts:
                bot.facts.append(text)
                bot.facts = bot.facts[-MAX_FACTS:]
                self.save()
        return text

    def forget_fact(self, bot_id: str, index: int) -> bool:
        bot = self.items.get(bot_id)
        if bot is None or not 0 <= index < len(bot.facts):
            return False
        with self._lock:
            bot.facts.pop(index)
            self.save()
        return True

    def titles(self) -> dict[str, str]:
        return {b.id: b.name for b in self.items.values()}
