"""Search everything: one query across the stores Compii keeps on this PC."""

from types import SimpleNamespace

from fastapi.testclient import TestClient

from compii_core.agent import Task
from compii_core.bots import Bot
from compii_core.keys import MemoryKeyStore
from compii_core.proactive import Routine, Watch
from compii_core.search import search_everything
from compii_core.server import build_app
from compii_core.skills import Skill

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures


class _Bots:
    def __init__(self, *bots):
        self.items = {b.id: b for b in bots}

    def get(self, bot_id):
        return self.items.get(bot_id)


class _Skills:
    def __init__(self, *skills):
        self.items = {s.id: s for s in skills}


class _Toolbox:
    def __init__(self, memories=()):
        self._memories = list(memories)

    def memories(self):
        return self._memories


class _Clips:
    def __init__(self, clips=(), snippets=()):
        self._clips, self._snippets = list(clips), list(snippets)
        self.snippets = SimpleNamespace(search=lambda q: self._snippets)

    def search(self, q, limit=100):
        return self._clips[:limit]


class _Timeline:
    def __init__(self, moments=()):
        self._moments = list(moments)

    def search(self, q, limit=50):
        return self._moments[:limit]


def _task(task_id, request, events=(), created=1.0, bot_id=None, team=()):
    return Task(id=task_id, request=request, created=created, events=list(events), bot_id=bot_id, team=list(team))


def _search(query, *, tasks=(), bots=(), skills=(), routines=(), watches=(), memories=(), clips=(),
            snippets=(), moments=(), limit=5):
    return search_everything(
        query,
        agent=SimpleNamespace(tasks={t.id: t for t in tasks}),
        bots=_Bots(*bots),
        skills=_Skills(*skills),
        plans=SimpleNamespace(routines={r.id: r for r in routines}, watches={w.id: w for w in watches}),
        toolbox=_Toolbox(memories),
        clips=_Clips(clips, snippets),
        timeline=_Timeline(moments),
        limit=limit,
    )


def _by_kind(got):
    return {g["kind"]: g for g in got["groups"]}


def _titles(group):
    return [i["title"] for i in group["items"]]


def test_one_query_finds_every_kind_of_thing_compii_keeps():
    bot = Bot(name="Finance", job="Chases invoices", id="b1")
    routine = Routine(title="Weekly invoice check", instruction="Check the invoice folder",
                      schedule={"kind": "weekly", "days": ["mon"], "at": "09:00"}, id="r1")
    watch = Watch(title="Invoice inbox", kind="folder", spec={"folder": r"C:\Users\me\Invoices", "pattern": "*.pdf"},
                  every_minutes=30, id="w1")
    skill = Skill(name="Invoice chase", instruction="Find unpaid invoices",
                  about="Chase late invoices", id="s1")
    got = _search(
        "invoice",
        tasks=[
            _task("t1", "Find the Acme invoice", events=[{"type": "task_finished", "text": "Found it."}]),
            _task("t2", "Make a deck", events=[{"type": "user_message", "text": "Use the invoice totals"}]),
        ],
        bots=[bot],
        routines=[routine],
        watches=[watch],
        skills=[skill],
        memories=[{"id": 0, "fact": "The Acme invoices go to accounts@acme.test", "at": 2.0}],
        clips=[{"id": 4, "preview": "Invoice INV-88 for 320", "app": "Outlook", "at": 3.0}],
        snippets=[{"id": "n1", "name": "Invoice reply", "body": "Thanks, paying today.", "created": 1.0}],
        moments=[{"id": 9, "app": "Excel", "title": "Invoices.xlsx", "excerpt": "Invoice list for October",
                  "text": "Invoice list", "started": 4.0}],
    )
    groups = _by_kind(got)
    assert list(groups) == ["conversations", "teammates", "routines", "skills", "memory", "clips", "screen"]
    assert _titles(groups["conversations"]) == ["Find the Acme invoice", "Make a deck"]
    # A hit inside the conversation shows where it was, instead of the bot name.
    assert groups["conversations"]["items"][1]["subtitle"].startswith("Use the invoice totals")
    assert groups["teammates"]["items"][0]["id"] == "b1"
    assert groups["teammates"]["items"][0]["subtitle"] == "Chases invoices"
    assert {i["kind"] for i in groups["routines"]["items"]} == {"routine", "watch"}
    assert groups["skills"]["items"][0]["subtitle"] == "Chase late invoices"
    assert groups["memory"]["items"][0]["id"] == 0
    assert [i["kind"] for i in groups["clips"]["items"]] == ["snippet", "clip"]
    assert groups["screen"]["items"][0]["subtitle"] == "Invoice list for October"


def test_every_word_must_appear_and_a_title_hit_beats_a_body_hit():
    got = _search(
        "invoice february",
        tasks=[
            _task("t1", "Invoice notes", events=[{"type": "task_finished", "text": "For February."}], created=1),
            _task("t2", "Q3 notes", events=[{"type": "user_message", "text": "The February invoice is late"}],
                  created=99),
            _task("t3", "Invoice March", events=[{"type": "task_finished", "text": "Sent."}], created=50),
        ],
        memories=[{"id": 0, "fact": "Invoices are due in February", "at": 1}],
    )
    groups = _by_kind(got)
    assert _titles(groups["conversations"]) == ["Invoice notes", "Q3 notes"]
    assert _titles(groups["memory"]) == ["Invoices are due in February"]
    # "Invoice March" has only one of the two words, so it is not a result.
    assert "Invoice March" not in _titles(groups["conversations"])


def test_results_are_capped_and_say_how_many_there_were():
    routines = [Routine(title=f"Invoice sweep {n}", instruction="x",
                        schedule={"kind": "daily", "at": "09:00"}, id=f"r{n}") for n in range(8)]
    got = _search("invoice", routines=routines, limit=3)
    group = _by_kind(got)["routines"]
    assert len(group["items"]) == 3
    assert group["total"] == 8


def test_teammates_explain_why_they_matched_from_their_own_memory():
    bot = Bot(name="Calendar", job="Keeps the week", id="b1")
    bot.facts = ["The quarterly invoice lands on the 28th"]
    got = _search("invoice", bots=[bot])
    assert _by_kind(got)["teammates"]["items"][0]["subtitle"].startswith("Remembers: The quarterly invoice")


def test_an_empty_query_returns_no_groups_so_the_app_can_show_its_own_entries():
    assert _search("   ")["groups"] == []


def test_the_endpoint_needs_the_token_and_searches_conversations(home):
    app = build_app(brain=ScriptBrain([], final="Done."), workspace=home["workspace"], roots=[home["downloads"]],
                    token="tok", keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))
    with TestClient(app) as client:
        assert client.get("/search", params={"q": "deadline"}).status_code == 401
        h = {"X-Compii-Token": "tok"}
        task_id = client.post("/tasks", json={"request": "Move the deadline to Friday"}, headers=h).json()["id"]
        for _ in range(100):
            task = next(t for t in client.get("/tasks", headers=h).json() if t["id"] == task_id)
            if task["status"] != "running":
                break
        got = client.get("/search", params={"q": "deadline"}, headers=h).json()
        conversation = next(g for g in got["groups"] if g["kind"] == "conversations")
        assert conversation["items"][0]["id"] == task_id
        assert conversation["items"][0]["title"] == "Move the deadline to Friday"
