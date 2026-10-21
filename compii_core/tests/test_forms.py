"""Profile, forms, projects and lead lists: the "fill it in for me" work."""

import asyncio
import json
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from compii_core.agent import Agent, BrainReply, ToolCall
from compii_core.forms import profile_form_tools
from compii_core.journal import Journal
from compii_core.leads import lead_tools
from compii_core.policy import ActionKind, Policy
from compii_core.profile import Profile, canonical
from compii_core.projects import Projects, project_tools
from compii_core.server import build_app
from compii_core.tools import Toolbox, ToolError

from test_core import ScriptBrain, home, opened, quiet_voice, toolbox  # noqa: F401 - fixtures

H = {"X-Compii-Token": "tok"}


class FakeBrowser:
    """A page with three fields; remembers what was typed."""

    def __init__(self) -> None:
        self.typed: dict[str, str] = {}
        self.submitted = False
        self.refuses: set[str] = set()  # labels the page drops after being given an answer

    def form_fields(self):
        return [{"label": "Full name *", "kind": "text", "value": "", "required": True},
                {"label": "Date of birth", "kind": "text", "value": "", "required": False},
                {"label": "Country of residence", "kind": "select", "value": "", "required": False,
                 "options": ["India", "Kenya", "United Kingdom"]},
                {"label": "Password", "kind": "password", "value": "", "required": True}]

    def fill_many(self, values, submit=False):
        filled, unverified = [], []
        for label, value in values.items():
            self.typed[label] = value
            (unverified if label in self.refuses else filled).append(label)
        self.submitted = bool(submit)
        return filled, [], unverified, "Page: Application\nAddress: https://uni.example/apply\n"

    def current_url(self):
        return "https://uni.example/apply"


@pytest.fixture
def forms(home):
    profile = Profile(home["workspace"] / "profile.json")
    browser = FakeBrowser()
    tools = {t.name: t for t in profile_form_tools(profile, lambda: browser)}
    return profile, browser, tools


def execute(tools, name, args):
    return tools[name].run(args)


# ---- profile -------------------------------------------------------------------


def test_the_profile_answers_the_labels_forms_actually_use():
    p = Profile(Path("nowhere.json"))
    p.fields = {"full_name": "Asha Patel", "email": "asha@example.com", "dob": "14 March 2003",
                "country": "India"}
    assert p.match("First and last name") == "Asha Patel"
    assert p.match("E-mail address*") == "asha@example.com"
    assert p.match("Date of Birth") == "14 March 2003"
    assert p.match("Country of residence") == "India"
    assert p.match("Shoe size") is None
    assert canonical("Phone number (mobile)") == "phone"


def test_passwords_and_card_numbers_never_reach_the_profile(home):
    p = Profile(home["workspace"] / "profile.json")
    with pytest.raises(Exception, match="never stores"):
        p.set_field("password", "hunter2")
    with pytest.raises(Exception, match="never stores"):
        p.set_field("passport", "5555 5555 5555 5555")
    assert p.set_field("City", "Nairobi") == "city" and p.get("town") == "Nairobi"


def test_written_answers_are_found_by_topic(home):
    p = Profile(home["workspace"] / "profile.json")
    p.set_answer("why", "I want to study public health because my town lost its clinic.")
    assert "public health" in p.match("Why do you want this scholarship?")
    assert "public health" in p.match("Motivation for applying")


# ---- forms ---------------------------------------------------------------------


def test_one_call_reads_the_form_and_says_what_the_profile_can_answer(forms):
    profile, _browser, tools = forms
    profile.fields = {"full_name": "Asha Patel", "dob": "14 March 2003", "country": "India"}
    out = execute(tools, "form_fields", {}).text
    assert "Full name" in out and "'Asha Patel'" in out and "India" in out
    assert "1 the profile can't answer yet" in out  # only the password is left


def test_the_whole_form_is_filled_in_one_step_but_secrets_are_refused(forms):
    profile, browser, tools = forms
    profile.fields = {"full_name": "Asha Patel", "dob": "14 March 2003", "country": "Kenya"}
    out = execute(tools, "fill_form", {"values": {"Full name *": "Asha Patel", "Date of birth": "14 March 2003",
                                                  "Country of residence": "Kenya"},
                                       "url": "https://uni.example/apply"}).text
    assert "Filled 3 field(s)" in out and browser.typed["Country of residence"] == "Kenya"
    assert not browser.submitted and "ask before submitting" in out
    assert tools["fill_form"].kind_for({}) is ActionKind.SEND
    with pytest.raises(ToolError, match="never types passwords"):
        execute(tools, "fill_form", {"values": {"Password": "hunter2"}, "url": "x"})


def test_a_field_the_page_drops_is_not_reported_as_filled(forms):
    profile, browser, tools = forms
    browser.refuses = {"Country of residence"}
    out = execute(tools, "fill_form", {"values": {"Full name *": "Asha Patel",
                                                  "Country of residence": "Kenya"}}).text
    assert "Filled 1 field(s)" in out and "can't confirm" in out and "Country of residence" in out
    assert "Submitted" not in out


def test_answer_questions_lists_what_is_still_needed(forms):
    profile, _browser, tools = forms
    profile.fields = {"full_name": "Asha Patel"}
    out = execute(tools, "answer_questions",
                  {"questions": ["Full name", "What is your career goal?"]}).text
    assert "Asha Patel" in out and "Still needed" in out and "career goal" in out
    assert "ask_user" in out and "set_profile" in out


# ---- projects ------------------------------------------------------------------


def test_a_project_carries_its_steps_over_days(home):
    projects = Projects(home["workspace"] / "projects.json")
    tools = {t.name: t for t in project_tools(projects)}
    start = json_start = execute(tools, "start_project", {
        "title": "Scholarship applications 2027", "goal": "Three applications in before the deadlines",
        "steps": [{"title": "Find scholarships"}, {"title": "Write the essay", "due": "2026-12-01"},
                  {"title": "Get a reference letter"}]}).text
    assert "3 steps" in start and "Write the essay (due 2026-12-01)" in start
    again = execute(tools, "update_project", {"title": "scholarship applications 2027",
                                              "steps": [{"title": "Find scholarships", "status": "done"},
                                                        {"title": "Book the English test", "due": "January"}]}).text
    assert "3 step(s) left" in again and "added “Book the English test”" in again
    assert "Find scholarships" not in again.split("left:")[1]  # a finished step isn't listed as still to do
    assert "Scholarship applications 2027" in projects.context()
    # Reload from disk: the next run of Compii still knows about it.
    again_projects = Projects(home["workspace"] / "projects.json")
    assert again_projects.find("scholarship").steps[3].due == "January"
    assert execute(tools, "project_status", {}).text.count("[x]") == 1


def test_a_project_can_be_closed_off(home):
    projects = Projects(home["workspace"] / "projects.json")
    tools = {t.name: t for t in project_tools(projects)}
    execute(tools, "start_project", {"title": "Bakery launch", "steps": [{"title": "Menus"}]})
    execute(tools, "update_project", {"title": "Bakery launch", "status": "done"})
    assert projects.active() == []
    with pytest.raises(ToolError, match="No project"):
        execute(tools, "update_project", {"title": "nothing like that"})


# ---- leads ---------------------------------------------------------------------


def test_leads_land_in_one_file_without_duplicates(home):
    box = Toolbox([home["downloads"]], home["workspace"], None)
    tools = {t.name: t for t in lead_tools(home["workspace"], box.path)}
    first = execute(tools, "save_leads", {"list": "Bakery customers", "leads": [
        {"name": "Meera", "email": "meera@example.com", "interest": "wedding cake"},
        {"name": "Tom", "company": "Cafe Nine", "phone": "+44 7700 900123"}]}).text
    assert "2 new lead(s)" in first and "3 in" not in first
    again = execute(tools, "save_leads", {"list": "Bakery customers", "leads": [
        {"name": "Meera", "email": "MEERA@example.com", "next_step": "send the price list"},
        {"name": "New person", "email": "new@example.com"}]}).text
    assert "1 new lead(s)" in again and "filled in 1 detail" in again
    csv_file = home["workspace"] / "leads" / "Bakery customers.csv"
    rows = csv_file.read_text(encoding="utf-8").strip().splitlines()
    assert len(rows) == 4 and "send the price list" in rows[1]
    assert "3 leads, 3 still open" in execute(tools, "list_leads", {}).text


@pytest.mark.skipif(sys.platform == "darwin", reason="openpyxl is fine anywhere")
def test_a_lead_list_can_be_an_excel_file(home):
    box = Toolbox([home["downloads"]], home["workspace"], None)
    tools = {t.name: t for t in lead_tools(home["workspace"], box.path)}
    execute(tools, "save_leads", {"list": "Fair", "path": "leads/fair.xlsx",
                                  "leads": [{"name": "Ada", "email": "ada@example.com"}]})
    execute(tools, "save_leads", {"list": "Fair", "path": "leads/fair.xlsx",
                                  "leads": [{"name": "Ada", "email": "ada@example.com", "role": "Buyer"}]})
    from openpyxl import load_workbook

    ws = load_workbook(home["workspace"] / "leads" / "fair.xlsx").active
    assert ws.max_row == 2 and ws.cell(2, 3).value == "Buyer"  # filled in, not added twice


def test_the_marketing_plan_writes_real_files(home):
    box = Toolbox([home["downloads"]], home["workspace"], None)
    tools = {t.name: t for t in lead_tools(home["workspace"], box.path)}
    out = execute(tools, "plan_marketing", {
        "file": str(home["downloads"] / "Marketing" / "deep" / "launch"),
        "plan": "# Bakery launch\n\nPost three times a week.",
        "calendar": [{"when": "Mon", "channel": "Instagram", "idea": "the oven", "call_to_action": "order a box"}]})
    assert (home["downloads"] / "Marketing" / "deep" / "launch.md").read_text(encoding="utf-8").startswith("# Bakery launch")
    assert "calendar.xlsx" in out.text and "Written:" in out.text
    with pytest.raises(ToolError, match="plan text"):
        execute(tools, "plan_marketing", {"file": str(home["downloads"] / "nothing")})


# ---- asking the user -----------------------------------------------------------


def test_a_task_stops_and_asks_when_it_lacks_an_answer(home):
    calls = [("ask_user", {"question": "Which passport number should I use?", "choices": ["None", "I'll type it"]})]
    brain = ScriptBrain(calls, final="Filled everything but that.")
    app = build_app(brain=brain, workspace=home["workspace"], roots=[home["downloads"]],
                    token="tok", voice=quiet_voice(home["workspace"]), keys=None)
    agent: Agent = app.state.agent
    with TestClient(app) as c, c.websocket_connect("/events?t=tok") as ws:
        tid = c.post("/tasks", json={"request": "fill this application"}, headers=H).json()["id"]
        question = {}
        while question.get("type") != "question":
            question = ws.receive_json()
        assert question["question"].startswith("Which passport") and question["choices"]
        assert question["task_id"] == tid and agent.questions[question["question_id"]].done() is False
        assert c.post("/questions/%s/answer" % question["question_id"], json={"text": "the older one"},
                      headers=H).status_code == 200
        while ws.receive_json().get("type") != "task_finished":
            pass
        asked = json.dumps([m for m in agent.tasks[tid].messages if m["role"] != "assistant"])
        assert "the older one" in asked
    assert agent.questions == {}


def test_answering_a_question_that_is_finished_is_a_clean_no(home):
    app = build_app(brain=ScriptBrain([], final="ok"), workspace=home["workspace"], roots=[home["downloads"]],
                    token="tok", voice=quiet_voice(home["workspace"]), keys=None)
    with TestClient(app) as c:
        assert c.post("/questions/nope/answer", json={"text": "x"}, headers=H).status_code == 404


def test_a_stopped_task_doesnt_hang_on_its_question(home):
    class Asking(ScriptBrain):
        async def step(self, system, messages, tools):
            if any(m["role"] == "tool" for m in messages):
                return await super().step(system, messages, tools)
            args = {"question": "What size?"}
            return BrainReply([{"type": "tool_use", "id": "q1", "name": "ask_user", "input": args}], "",
                              [ToolCall("q1", "ask_user", args)], "tool_use")

    app = build_app(brain=Asking([], final="ok"), workspace=home["workspace"], roots=[home["downloads"]],
                    token="tok", voice=quiet_voice(home["workspace"]), keys=None)
    agent: Agent = app.state.agent
    with TestClient(app) as c, c.websocket_connect("/events?t=tok") as ws:
        tid = c.post("/tasks", json={"request": "buy a rug"}, headers=H).json()["id"]
        while ws.receive_json().get("type") != "question":
            pass
        c.post(f"/tasks/{tid}/stop", headers=H)
        while ws.receive_json().get("type") != "task_finished":
            pass
    assert agent.questions == {}


# ---- context -------------------------------------------------------------------


def test_profile_and_projects_reach_the_model(home):
    profile = Profile(home["workspace"] / "profile.json")
    profile.fields = {"full_name": "Asha Patel"}
    projects = Projects(home["workspace"] / "projects.json")
    projects.add("Scholarship applications", "Three in before the deadline", [{"title": "Essay"}], [])
    seen: list[str] = []

    class Note(ScriptBrain):
        async def step(self, system, messages, tools):
            seen.append(system)
            names.extend(t["name"] for t in tools)
            return await super().step(system, messages, tools)

    names: list[str] = []

    app = build_app(brain=Note([], final="ok"), workspace=home["workspace"], roots=[home["downloads"]],
                    token="tok", voice=quiet_voice(home["workspace"]), keys=None)
    app.state.profile = profile
    app.state.projects = projects
    agent: Agent = app.state.agent
    agent.extra_context = lambda: "\n".join(x for x in (profile.context(), projects.context()) if x)
    with TestClient(app) as c, c.websocket_connect("/events?t=tok") as ws:
        c.post("/tasks", json={"request": "help me apply"}, headers=H)
        while ws.receive_json().get("type") != "task_finished":
            pass
    assert "full name: Asha Patel" in seen[0] and "Scholarship applications" in seen[0]
    assert {"ask_user", "fill_form", "form_fields", "save_leads", "start_project"} <= set(names)
