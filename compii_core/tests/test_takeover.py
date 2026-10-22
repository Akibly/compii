"""Hand-off for secret fields: Compii pauses, the user types it, the task carries on."""

import asyncio

from test_core import ScriptBrain, home, opened, run_agent, toolbox  # noqa: F401 - fixtures


def test_secret_shapes_are_recognised_before_any_fill():
    from compii_core.agent import _page_summary, _secret_in

    assert _secret_in("fill_form", {"values": {"Email": "sam@example.com", "Password": "hunter2"}})
    assert not _secret_in("fill_form", {"values": {"Email": "sam@example.com"}})
    assert _secret_in("browser_fill", {"field": "CVV", "value": "123"})
    assert _secret_in("type_into", {"target": "", "text": "4111 1111 1111 1111"})
    assert not _secret_in("type_into", {"target": "Search", "text": "invoice"})
    page = _page_summary([{"label": "Password", "kind": "password", "value": "hunter2"},
                          {"label": "Email", "kind": "email", "value": "sam@example.com"}])
    assert "hunter2" not in page
    assert "Password [password]: filled" in page
    assert "sam@example.com" in page


async def test_a_password_step_hands_over_and_continues_when_the_user_is_done(toolbox, tmp_path):
    brain = ScriptBrain([("hand_to_user", {"what": "Type your password in the sign-in window.",
                                           "fields": ["Password"]})], final="Signed in.")
    handed = []

    async def user(e, agent):
        if e["type"] == "takeover":
            handed.append(e)
            assert e["status"] == "waiting" and e["fields"][0]["label"] == "Password"
            agent.finish_takeover(e["takeover_id"], "done")

    task, events, _ = await run_agent(toolbox, tmp_path, brain, user)
    assert task.status == "done"
    assert handed and handed[0]["what"].startswith("Type your password")
    done = next(e for e in events if e["type"] == "takeover_done")
    assert done["outcome"] == "done"
    sent = " ".join(str(m.get("content")) for m in brain.seen[-1])
    assert "did that step themselves" in sent


async def test_skipping_a_secret_step_is_told_honestly(toolbox, tmp_path):
    brain = ScriptBrain([("hand_to_user", {"what": "Enter the one-time code.", "fields": ["Code"]})],
                        final="Okay.")

    async def skip(e, agent):
        if e["type"] == "takeover":
            agent.finish_takeover(e["takeover_id"], "skip")

    _, events, _ = await run_agent(toolbox, tmp_path, brain, skip)
    assert next(e for e in events if e["type"] == "takeover_done")["outcome"] == "skip"
    sent = " ".join(str(m.get("content")) for m in brain.seen[-1])
    assert "skipped that step" in sent


async def test_a_fill_with_a_password_never_types_it_and_still_reports_the_rest(toolbox, tmp_path):
    brain = ScriptBrain([("fill_form", {"values": {"Email": "sam@example.com", "Password": "hunter2"},
                                        "url": "https://example.com/signup"})], final="Filled.")
    typed = []

    class FakeBrowser:
        def fill_many(self, values, submit=False):
            typed.append(dict(values))
            return list(values), [], [], "Email: sam@example.com"

        def form_fields(self):
            return [{"label": "Email", "kind": "email", "value": "sam@example.com", "options": [], "required": True},
                    {"label": "Password", "kind": "password", "value": "", "options": [], "required": True}]

        def focus(self):
            return True

    toolbox._browser = FakeBrowser()
    # The server adds the real fill_form tool; this test only needs its safe-values contract.
    from compii_core.policy import ActionKind
    from compii_core.tools import Tool, ToolResult

    def fake_fill(a):
        filled, missing, unverified, page = toolbox._browser.fill_many(a["values"], bool(a.get("submit")))
        return ToolResult(f"Filled {len(filled)} field(s).")

    toolbox.tools["fill_form"] = Tool(
        "fill_form", "Fill the form", {"values": {"type": "object"}, "submit": {"type": "boolean"},
                                       "url": {"type": "string"}}, ["values", "url"],
        ActionKind.SEND, fake_fill, lambda a: f"Fill {len(a['values'])} field(s)")

    async def user(e, agent):
        if e["type"] == "approval_needed":
            assert "hunter2" not in str(e["input"])  # the card stayed out of the audit trail too
            agent.decide(e["approval_id"], True)
        if e["type"] == "takeover":
            agent.finish_takeover(e["takeover_id"], "done")

    _, events, _ = await run_agent(toolbox, tmp_path, brain, user)
    assert typed == [{"Email": "sam@example.com"}], [(e["type"], e.get("tool"), e.get("detail")) for e in events]
    assert next(e for e in events if e["type"] == "takeover")["fields"][0]["label"] == "Password"
    exposed = str([e for e in events if e["type"] in ("approval_needed", "action_started", "action_done", "takeover")])
    assert "hunter2" not in exposed
    sent = " ".join(str(m.get("content")) for m in brain.seen[-1])
    assert "did that step themselves" in sent and "Password [password]" in sent
