"""Bots: named teammates with their own role, memory and a thread that survives restarts."""

import asyncio
import re
import time

from fastapi.testclient import TestClient

from compii_core.agent import BrainReply, ToolCall
from compii_core.bots import Bots
from compii_core.chats import load as load_chats, restore as restore_chats, save as save_chats
from compii_core.keys import MemoryKeyStore
from compii_core.server import build_app

from test_core import ScriptBrain, home, quiet_voice  # noqa: F401 - fixtures


class SystemSpy(ScriptBrain):
    def __init__(self, calls=None, final="Done."):
        super().__init__(calls or [], final)
        self.systems: list[str] = []

    async def step(self, system, messages, tools):
        self.systems.append(system)
        return await super().step(system, messages, tools)


def _app(home, brain, token="tok"):
    return build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]], token=token,
                     keys=MemoryKeyStore(), voice=quiet_voice(home["workspace"]))


def test_registry_starts_with_compii_and_keeps_its_primary(home):
    bots = Bots(home["workspace"] / "bots.json")
    primary = bots.primary()
    assert primary is not None and primary.primary and primary.name == "Compii"
    try:
        bots.delete(primary.id)
    except ValueError as e:
        assert "primary" in str(e).lower()
    else:
        raise AssertionError("the primary bot must not be removable")


def test_bots_are_created_from_a_template_and_remember_facts(home):
    bots = Bots(home["workspace"] / "bots.json")
    inbox = bots.create("Inbox Manager", template="inbox")
    assert inbox.job and "mail" in inbox.instructions.lower()
    bots.add_fact(inbox.id, "Only surfaces mail that needs a reply today.")
    bots.add_fact(inbox.id, "Only surfaces mail that needs a reply today.")
    reloaded = Bots(home["workspace"] / "bots.json")
    again = reloaded.get(inbox.id)
    assert again is not None
    assert again.facts == ["Only surfaces mail that needs a reply today."]
    assert "Inbox Manager" in again.prompt() and "reply today" in again.prompt()
    assert reloaded.forget_fact(inbox.id, 0)
    assert reloaded.get(inbox.id).facts == []


def test_a_teammate_keeps_the_category_of_the_role_it_came_from(home):
    bots = Bots(home["workspace"] / "bots.json")
    inbox = bots.create("Inbox Manager", template="inbox")
    made_up = bots.create("Night Auditor")
    by_id = {b["id"]: b for b in bots.view()}
    assert by_id[inbox.id]["template"] == "inbox"
    assert by_id[inbox.id]["category"] == "Personal", "a directory groups by the role it was built from"
    assert by_id[made_up.id]["category"] == "", "a role the user wrote themselves belongs to no group"
    again = {b["id"]: b for b in Bots(home["workspace"] / "bots.json").view()}
    assert again[inbox.id]["category"] == "Personal", "the category survives a restart, so the grouping is stable"


def test_duplicate_bot_names_are_refused(home):
    bots = Bots(home["workspace"] / "bots.json")
    bots.create("Researcher")
    try:
        bots.create("researcher")
    except ValueError as e:
        assert "already" in str(e).lower()
    else:
        raise AssertionError("two bots with the same name would make @mentions ambiguous")


def test_the_bot_role_and_its_memory_reach_the_model(home):
    brain = SystemSpy([])
    app = _app(home, brain)
    bot = app.state.bots.create("Inbox Manager", template="inbox")
    app.state.bots.add_fact(bot.id, "Drafts stay under 80 words.")

    async def go():
        task = app.state.agent.start("triage today's mail", bot_id=bot.id)
        await asyncio.wait_for(task.runner, 10)
        return task

    task = asyncio.run(go())
    assert task.bot_id == bot.id
    assert "Inbox Manager" in brain.systems[0]
    assert "Drafts stay under 80 words." in brain.systems[0]
    assert all(e.get("bot_id") == bot.id for e in task.events)


def test_remember_bot_tool_saves_the_fact_for_that_bot(home):
    brain = ScriptBrain([("remember_bot", {"fact": "Always close with a one-line summary."})], final="Noted.")
    app = _app(home, brain)
    bot = app.state.bots.create("Researcher")

    async def go():
        task = app.state.agent.start("research something", bot_id=bot.id)
        await asyncio.wait_for(task.runner, 10)
        return task

    asyncio.run(go())
    facts = next(b for b in app.state.bots.view() if b["id"] == bot.id)["facts"]
    assert facts == ["Always close with a one-line summary."]


def test_bot_api_creates_edits_and_deletes(home):
    app = _app(home, ScriptBrain([]))
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        view = client.get("/bots", headers=h).json()
        assert view["primary"] and len(view["bots"]) == 1
        created = client.post("/bots", json={"name": "Scheduler", "template": "scheduler"}, headers=h)
        assert created.status_code == 200
        bot = next(b for b in created.json()["bots"] if b["name"] == "Scheduler")
        edited = client.patch(f"/bots/{bot['id']}", json={"pinned": True, "job": "Owns my week"}, headers=h).json()
        assert next(b for b in edited["bots"] if b["id"] == bot["id"])["pinned"]
        with_fact = client.post(f"/bots/{bot['id']}/facts", json={"fact": "Fridays are meeting-free."}, headers=h).json()
        assert next(b for b in with_fact["bots"] if b["id"] == bot["id"])["facts"] == ["Fridays are meeting-free."]
        assert client.delete(f"/bots/{bot['id']}/facts/0", headers=h).status_code == 200
        assert client.delete(f"/bots/{bot['id']}", headers=h).status_code == 200
        assert len(client.get("/bots", headers=h).json()["bots"]) == 1


def test_conversations_keep_their_bot_after_a_restart(home):
    brain = ScriptBrain([], final="Mail triaged: 2 things need you.")
    app = _app(home, brain)
    bot = app.state.bots.create("Inbox Manager", template="inbox")

    async def go():
        task = app.state.agent.start("triage my mail", bot_id=bot.id)
        await asyncio.wait_for(task.runner, 10)
        return task

    task = asyncio.run(go())
    files = [t for t in app.state.agent.tasks.values()]
    save_chats(home["workspace"] / "chats.json", files)

    again = _app(home, ScriptBrain([]))
    records = load_chats(home["workspace"] / "chats.json")
    restore_chats(again.state.agent, records, set(again.state.bots.items), again.state.bots.primary().id)
    restored = again.state.agent.tasks[task.id]
    assert restored.bot_id == bot.id
    assert restored.status == "done"
    assert restored.request == "triage my mail"
    assert [e["type"] for e in restored.events][-1] == "task_finished"
    assert restored.messages[-1]["role"] == "assistant"


class SlowBrain(ScriptBrain):
    async def step(self, system, messages, tools):
        await asyncio.sleep(30)
        return await super().step(system, messages, tools)


def test_an_unfinished_thread_comes_back_stopped_not_forever_waiting(home):
    app = _app(home, SlowBrain([]))
    bot = app.state.bots.primary()

    async def go():
        task = app.state.agent.start("something long", bot_id=bot.id)
        await asyncio.sleep(.05)
        save_chats(home["workspace"] / "chats.json", [task])
        task.runner.cancel()
        return task.id

    task_id = asyncio.run(go())
    records = load_chats(home["workspace"] / "chats.json")
    fresh = _app(home, ScriptBrain([]))
    restore_chats(fresh.state.agent, records, set(fresh.state.bots.items), bot.id)
    got = fresh.state.agent.tasks[task_id]
    assert got.status == "stopped"
    assert got.events[-1]["type"] == "task_finished"
    assert "restarted" in got.events[-1]["text"]


class DelegatingBrain:
    """Compii hands a job to a named teammate, then reviews what comes back."""

    def __init__(self, worker: str) -> None:
        self.worker = worker
        self.seen: list[list[dict]] = []

    async def step(self, system, messages, tools):
        self.seen.append(messages)
        assistant = sum(1 for m in messages if m["role"] == "assistant")
        if "This is one job handed to you" in system:
            return BrainReply([{"type": "text", "text": "Summarised it."}], "Summarised it.", [], "end_turn")
        if assistant == 0:
            args = {"bot": self.worker, "objective": "Summarise the invoice",
                    "done_when": "a summary is written", "context": "It is in Downloads."}
            return BrainReply([{"type": "tool_use", "id": "d0", "name": "delegate", "input": args}], "",
                              [ToolCall("d0", "delegate", args)], "tool_use")
        job = ""
        for m in reversed(messages):
            if m["role"] != "user":
                continue
            for block in m["content"] if isinstance(m["content"], list) else []:
                found = re.search(r"Job (j[0-9a-f]{8})\.", str(block.get("content", "")))
                if found:
                    job = found.group(1)
        if job:
            args = {"job": job, "verdict": "accept", "note": "Checked it."}
            return BrainReply([{"type": "tool_use", "id": "r0", "name": "review_work", "input": args}], "",
                              [ToolCall("r0", "review_work", args)], "tool_use")
        return BrainReply([{"type": "text", "text": "Done and checked."}], "Done and checked.", [], "end_turn")


def _run(app, request, bot_id, team=None):
    async def go():
        task = app.state.agent.start(request, bot_id=bot_id, team=team)
        await asyncio.wait_for(task.runner, 20)
        return task

    return asyncio.run(go())


def test_a_handover_moves_who_answers_not_who_the_thread_belongs_to(home):
    brain = SystemSpy([], final="Two folders still need it.")
    app = _app(home, brain)
    compii = app.state.bots.primary()
    clerk = app.state.bots.create("File Clerk", template="clerk")

    async def go():
        task = app.state.agent.start("sort my downloads", bot_id=compii.id)
        await asyncio.wait_for(task.runner, 10)
        return app.state.agent.transfer(task.id, clerk.id, "finish the tidy-up")

    moved, event = asyncio.run(go())
    assert moved.bot_id == clerk.id and moved.owner_id == compii.id
    assert moved.probation, "the incoming teammate's trust, not the door it came in through"
    assert event["by"] == "user" and event["from"] == "Compii" and event["to"] == "File Clerk"
    assert event["shared"]["request"] == "sort my downloads"
    assert moved.events[-1]["bot_id"] == clerk.id

    async def follow():
        task = app.state.agent.reply(moved.id, "what is left?")
        await asyncio.wait_for(task.runner, 10)
        return task

    asyncio.run(follow())
    assert "You are File Clerk" in brain.systems[-1], "the clerk answers as itself, not as Compii"
    said = str(brain.seen[-1][-1])
    assert "handed this conversation to you" in said and "File Clerk" in said


def test_a_thread_still_working_refuses_to_be_handed_over(home):
    app = _app(home, SlowBrain([]))
    compii = app.state.bots.primary()
    coder = app.state.bots.create("Coder", template="coder")

    async def go():
        task = app.state.agent.start("a long job", bot_id=compii.id)
        await asyncio.sleep(.05)
        try:
            app.state.agent.transfer(task.id, coder.id)
            return "it let a running thread be handed over"
        except RuntimeError as e:
            return str(e)
        finally:
            task.runner.cancel()

    assert "still working" in asyncio.run(go()).lower()


def test_core_lists_each_teammate_s_own_conversations(home):
    app = _app(home, DelegatingBrain("Coder"))
    compii = app.state.bots.primary()
    coder = app.state.bots.create("Coder", template="coder")
    researcher = app.state.bots.create("Researcher", template="researcher")

    boss = _run(app, "Summarise the invoice and write a report", compii.id)
    lent = _run(app, "tidy my folders", coder.id)

    async def go():
        return app.state.agent.transfer(lent.id, researcher.id)[0]

    asyncio.run(go())

    def ids(client, bot_id):
        return {t["id"] for t in client.get(f"/bots/{bot_id}/conversations",
                                            headers={"X-Compii-Token": "tok"}).json()["conversations"]}

    with TestClient(app) as client:
        compii_ids, coder_ids, researcher_ids = ids(client, compii.id), ids(client, coder.id), \
            ids(client, researcher.id)
        missing = client.get("/bots/nosuchbot/conversations", headers={"X-Compii-Token": "tok"})

    child = next(t for t in app.state.agent.tasks.values() if t.parent_id == boss.id)
    assert child.bot_id == coder.id, "the coder ran the job Compii handed down"
    assert boss.id in compii_ids
    assert child.id not in compii_ids, "a job Compii assigned is not a conversation the user had"
    assert lent.id in coder_ids, "a chat opened with the coder stays in its history"
    assert lent.id in researcher_ids, "and shows for whoever is answering it now"
    assert coder_ids == {lent.id}, "each agent's history is its own, not everyone's"
    assert missing.status_code == 404


def test_a_handed_over_thread_keeps_its_owner_and_speaker_through_a_restart(home):
    app = _app(home, ScriptBrain([], final="Sorted."))
    compii = app.state.bots.primary()
    clerk = app.state.bots.create("File Clerk", template="clerk")

    async def go():
        task = app.state.agent.start("sort my downloads", bot_id=compii.id)
        await asyncio.wait_for(task.runner, 10)
        return app.state.agent.transfer(task.id, clerk.id)[0]

    moved = asyncio.run(go())
    save_chats(home["workspace"] / "chats.json", list(app.state.agent.tasks.values()))

    again = _app(home, ScriptBrain([]))
    restore_chats(again.state.agent, load_chats(home["workspace"] / "chats.json"),
                  set(again.state.bots.items), again.state.bots.primary().id)
    restored = again.state.agent.tasks[moved.id]
    assert restored.owner_id == compii.id and restored.bot_id == clerk.id


# ---- each teammate's own AI: a role is not a model --------------------------------

def test_a_teammate_answers_with_the_ai_the_user_gave_it(home):
    shared = SystemSpy([], final="Answered by Compii's AI.")
    ana_brain = SystemSpy([], final="Answered by Ana's AI.")
    ana_brain.provider, ana_brain.model = "groq", "openai/gpt-oss-120b"
    app = _app(home, shared)
    ana = app.state.bots.create("Ana", template="researcher")
    app.state.agent.brain_for = lambda bot_id: ana_brain if bot_id == ana.id else None

    async def go():
        hers = app.state.agent.start("what is worth reading today", bot_id=ana.id)
        await asyncio.wait_for(hers.runner, 10)
        its = app.state.agent.start("what is worth reading today", bot_id=None)
        await asyncio.wait_for(its.runner, 10)
        return hers, its

    hers, its = asyncio.run(go())
    assert len(ana_brain.seen) == 1 and len(shared.seen) == 1, "each turn went to the AI that answers it"
    assert "You are Ana" in ana_brain.systems[0], "and still in her role, not the model's own words"

    used = [line for line in (home["workspace"] / "usage.jsonl").read_text(encoding="utf-8").splitlines()
            if "openai/gpt-oss-120b" in line]
    assert used, "what Ana's AI cost is counted against Ana's AI, not Compii's"

    with TestClient(app) as client:
        by_id = {t["id"]: t for t in client.get("/tasks", headers={"x-compii-token": "tok"}).json()}
        assert by_id[hers.id]["answers_with"] == "groq · openai/gpt-oss-120b"
        assert by_id[its.id]["answers_with"] == "", "Compii's own AI isn't named by a test brain"


def test_a_handed_over_thread_starts_answering_with_the_new_teammate_s_ai(home):
    shared = SystemSpy([], final="Not mine.")
    ana_brain = SystemSpy([], final="Mine.")
    app = _app(home, shared)
    ana = app.state.bots.create("Ana", template="researcher")
    app.state.agent.brain_for = lambda bot_id: ana_brain if bot_id == ana.id else None

    async def go():
        task = app.state.agent.start("find the invoice", bot_id=None)
        await asyncio.wait_for(task.runner, 10)
        moved = app.state.agent.transfer(task.id, ana.id)[0]
        again = app.state.agent.reply(moved.id, "you take it from here")
        await asyncio.wait_for(again.runner, 10)
        return moved

    moved = asyncio.run(go())
    assert not shared.seen[1:], "Compii answered the first turn and nothing after the handover"
    assert len(ana_brain.seen) == 1, "the thread follows the teammate, and so does its AI"
    assert ana_brain.systems[0].count("You are Ana") == 1


def test_only_an_ai_compii_knows_can_be_a_teammate_s_own(home):
    app = _app(home, ScriptBrain([], final="ok"))
    with TestClient(app) as client:
        head = {"x-compii-token": "tok"}
        made = client.post("/bots", headers=head, json={"name": "Ana", "template": "researcher",
                                                        "provider": "Groq", "model": "openai/gpt-oss-120b"}).json()
        ana = next(b for b in made["bots"] if b["name"] == "Ana")
        assert ana["provider"] == "groq" and ana["model"] == "openai/gpt-oss-120b"
        # The app's own brain is a test one here, so no page may claim a model that isn't speaking.
        assert ana["answers_with"] == "" and ana["model_note"] == ""

        unknown = client.post("/bots", headers=head, json={"name": "Bo", "provider": "hallucinated"})
        assert unknown.status_code == 400 and "Settings" in unknown.json()["detail"]

        orphan = client.patch(f"/bots/{ana['id']}", headers=head, json={"provider": ""})
        assert orphan.status_code == 400, "a model id with no AI offering it is not a configuration"

        cleared = client.patch(f"/bots/{ana['id']}", headers=head, json={"model": "", "provider": ""})
        back = next(b for b in cleared.json()["bots"] if b["id"] == ana["id"])
        assert back["provider"] == "" and back["model"] == "", "a teammate can be put back on Compii's AI"

    primary = app.state.bots.primary().id
    with TestClient(app) as client:
        refused = client.patch(f"/bots/{primary}", headers={"x-compii-token": "tok"}, json={"provider": "groq"})
        assert refused.status_code == 400, "Compii answers with the AI chosen in Settings"


def test_a_chosen_ai_is_built_once_and_a_missing_key_is_said_out_loud(monkeypatch):
    from compii_core import providers as prov

    monkeypatch.delenv("MISTRAL_API_KEY", raising=False)
    keys = MemoryKeyStore()
    brains = prov.BotBrains(keys)
    view = {"provider": "mistral", "model": "mistral-small-latest"}

    brain, problem = brains.resolve(view)
    assert brain is None and problem and "Mistral" in problem, "no key: name the fix, never swap the model"
    keys.set("mistral", "test-key")
    assert brains.resolve(view)[1] == problem, "a known problem is remembered, not retried on every read"

    brains.reset()  # saving a key does this, so the next read builds the real brain
    first, problem = brains.resolve(view)
    assert problem is None and first is not None and first.model == "mistral-small-latest"
    assert brains.resolve(view)[0] is first, "one AI, built once, kept for every teammate using it"
    assert brains.resolve({"provider": "", "model": ""}) == (None, None), "no choice means Compii's own brain"
    brains.reset()
    assert brains.resolve(view)[0] is not first, "a changed key rebuilds it"


def test_another_answer_repeats_the_ask_not_the_message(home):
    brain = ScriptBrain([], final="First answer.")
    app = _app(home, brain)
    compii = app.state.bots.primary()

    async def go():
        task = app.state.agent.start("what is in my downloads", bot_id=compii.id)
        await asyncio.wait_for(task.runner, 10)
        brain.final = "Second answer."
        again = await asyncio.wait_for(app.state.agent.again(task.id).runner, 10)
        return app.state.agent.tasks[task.id]

    asyncio.run(go())
    task = app.state.agent.tasks[list(app.state.agent.tasks)[0]]
    asked = [m for m in brain.seen[-1] if m.get("content") == "what is in my downloads"]
    assert len(asked) == 1, "a retry answers the same ask again; it does not ask it twice"
    assert [e["type"] for e in task.events].count("retry") == 1
    finals = [e["text"] for e in task.events if e["type"] == "task_finished"]
    assert finals == ["First answer.", "Second answer."], "the first answer stays in the record"


def test_answering_again_is_a_real_route_and_refuses_while_still_working(home):
    app = _app(home, ScriptBrain([], final="Sorted."))
    compii = app.state.bots.primary()

    async def go():
        task = app.state.agent.start("list my downloads", bot_id=compii.id)
        await asyncio.wait_for(task.runner, 10)
        busy = app.state.agent.start("and again later", bot_id=compii.id)
        return task.id, busy.id

    finished, running = asyncio.run(go())
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        done = client.post(f"/tasks/{finished}/again", headers=h)
        assert done.status_code == 200
        assert done.json()["id"] == finished
        # The retry turn really runs: its own ask, and a second answer on the same thread.
        for _ in range(40):
            thread = next(t for t in client.get("/tasks", headers=h).json() if t["id"] == finished)
            if [e for e in thread["events"] if e["type"] == "task_finished"]:
                break
            time.sleep(0.05)
        assert any(e["type"] == "retry" for e in thread["events"])
        assert sum(1 for e in thread["events"] if e["type"] == "user_message") == 0, \
            "answering again repeats the ask to the model, not a new message in the thread"
        assert client.post(f"/tasks/{running}/again", headers=h).status_code == 409
        assert client.post("/tasks/nope/again", headers=h).status_code == 404


def test_a_deleted_conversation_is_gone_from_the_live_set_and_the_archive(home):
    app = _app(home, ScriptBrain([], final="Sorted."))
    compii = app.state.bots.primary()

    async def go():
        keep = app.state.agent.start("sort these receipts", bot_id=compii.id)
        await asyncio.wait_for(keep.runner, 10)
        away = app.state.agent.start("find my keys", bot_id=compii.id)
        await asyncio.wait_for(away.runner, 10)
        busy = app.state.agent.start("a long errand", bot_id=compii.id)
        return keep.id, away.id, busy.id

    kept, away, busy = asyncio.run(go())
    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        refused = client.delete(f"/tasks/{busy}", headers=h)
        assert refused.status_code == 409, "a thread still working is never thrown away mid-answer"
        assert "stop" in refused.json()["detail"].lower()
        gone = client.delete(f"/tasks/{away}", headers=h)
        assert gone.status_code == 200 and gone.json()["id"] == away
        assert {t["id"] for t in client.get("/tasks", headers=h).json()} == {kept, busy}
        assert client.delete(f"/tasks/{away}", headers=h).status_code == 404

    # Deleted means gone: the archive rewritten on the way out holds no trace of it,
    # so a restart cannot bring the conversation back.
    fresh = _app(home, ScriptBrain([]))
    records = load_chats(home["workspace"] / "chats.json")
    restore_chats(fresh.state.agent, records, set(fresh.state.bots.items), compii.id)
    assert away not in {r["id"] for r in records}
    assert kept in {r["id"] for r in records}
    assert away not in fresh.state.agent.tasks
    assert kept in fresh.state.agent.tasks


# ---- putting a teammate away: off the team, its record kept ------------------------


def test_archiving_takes_a_teammate_off_the_team_and_keeps_its_record(home):
    path = home["workspace"] / "bots.json"
    bots = Bots(path)
    researcher = bots.create("Researcher", template="researcher")
    put_away = bots.create("Inbox Manager", template="inbox")
    bots.add_fact(put_away.id, "Fridays are meeting-free.")
    bots.update(put_away.id, pinned=True)
    bots.update(put_away.id, archived=True)

    away = bots.get(put_away.id)
    assert away.archived and away.job and away.instructions
    assert away.facts == ["Fridays are meeting-free."], "archiving forgets nothing"
    assert not away.pinned, "a teammate that is not on the team cannot sit at the top of it"
    assert put_away.id not in {b.id for b in bots.active()}
    assert researcher.id in {b.id for b in bots.active()}

    # The name is free again while the old role is away, and the old role can only come back
    # once that name is free: one name, one teammate.
    twin = bots.create("Inbox Manager")
    assert twin.id != put_away.id
    try:
        bots.update(put_away.id, archived=False)
    except ValueError as e:
        assert "already" in str(e).lower()
    else:
        raise AssertionError("bringing a teammate back onto a name someone else holds must be refused")

    reloaded = Bots(path)
    assert reloaded.get(put_away.id).archived, "being put away survives a restart"
    assert reloaded.get(put_away.id).facts == ["Fridays are meeting-free."]
    views = reloaded.view()
    first_away = next(i for i, b in enumerate(views) if b["archived"])
    assert all(not b["archived"] for b in views[:first_away]), \
        "a directory can page them apart: everyone on the team sorts before the put-away one"
    assert [b["name"] for b in views[first_away:]] == ["Inbox Manager"], \
        "the old role is the one away; the twin under the same name is on the team"


def test_compii_itself_cannot_be_put_away(home):
    bots = Bots(home["workspace"] / "bots.json")
    primary = bots.primary()
    try:
        bots.update(primary.id, archived=True)
    except ValueError as e:
        assert "team" in str(e).lower() or "primary" in str(e).lower()
    else:
        raise AssertionError("the primary bot must not be archivable")
    assert not bots.get(primary.id).archived


def test_a_put_away_teammate_takes_no_new_work_but_its_conversations_stay(home):
    brain = ScriptBrain([], final="Sorted.")
    app = _app(home, brain)
    clerk = app.state.bots.create("File Clerk", template="clerk")
    compii = app.state.bots.primary()

    before = _run(app, "sort my downloads", clerk.id)

    with TestClient(app) as client:
        h = {"X-Compii-Token": "tok"}
        edited = client.patch(f"/bots/{clerk.id}", json={"archived": True}, headers=h)
        assert edited.status_code == 200
        assert next(b for b in edited.json()["bots"] if b["id"] == clerk.id)["archived"]

        # The directory and the app still see who answered, with the fact that it is away.
        listed = client.get("/bots", headers=h).json()["bots"]
        assert next(b for b in listed if b["id"] == clerk.id)["archived"] is True
        team = client.get("/team", headers=h).json()["roster"]
        assert clerk.id in {b["id"] for b in team}
        # Compii's own roster — what it reads and may delegate to — does not offer it.
        assert clerk.id not in {b["id"] for b in app.state.agent.roster()}

        refused = client.post("/tasks", json={"request": "another stack", "bot_id": clerk.id}, headers=h)
        assert refused.status_code == 409 and "archived" in refused.json()["detail"].lower()
        on_team = client.post("/tasks", json={"request": "pair up", "team": [compii.id, clerk.id]}, headers=h)
        assert on_team.status_code == 409 and "File Clerk" in on_team.json()["detail"]
        moved = client.post(f"/tasks/{before.id}/transfer", json={"bot_id": clerk.id}, headers=h)
        assert moved.status_code == 409 and "archived" in moved.json()["detail"].lower()
        errand = client.post("/routines", json={"title": "Tidy", "instruction": "Tidy",
                                                "schedule": {"kind": "daily", "at": "07:00"},
                                                "bot_id": clerk.id}, headers=h)
        assert errand.status_code == 400 and "archived" in errand.json()["detail"].lower()

        # Its conversations are still the user's to read and continue.
        threads = client.get(f"/bots/{clerk.id}/conversations", headers=h).json()["conversations"]
        assert before.id in {t["id"] for t in threads}
        follow = client.post(f"/tasks/{before.id}/messages", json={"text": "and the photos?"}, headers=h)
        assert follow.status_code == 200

        # Bringing it back is a real yes/no and puts it on the team again.
        back = client.patch(f"/bots/{clerk.id}", json={"archived": False}, headers=h)
        assert back.status_code == 200
        assert clerk.id in {b["id"] for b in app.state.agent.roster()}
