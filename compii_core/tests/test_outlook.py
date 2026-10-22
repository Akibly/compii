"""Outlook as a tool: the user's real mailbox and calendar, read honestly, sent only with approval,
and a search string that can never become code."""

from __future__ import annotations

import base64
import json

import pytest

from compii_core import outlook
from compii_core.outlook import outlook_tools
from compii_core.tools import ToolError

TOOLS = {t.name: t for t in outlook_tools()}


def _stub(monkeypatch, answer):
    seen: list[dict] = []
    monkeypatch.setattr(outlook, "_run", lambda script, args=None: seen.append(args or {}) or answer)
    return seen


def test_arguments_travel_as_data_never_as_code(monkeypatch):
    ran: list[tuple[str, dict]] = []

    class Done(Exception):
        pass

    def fake_run(argv, **kw):
        ran.append((argv[-1], kw["env"]))
        raise Done

    monkeypatch.setattr(outlook.subprocess, "run", fake_run)
    with pytest.raises(Done):
        outlook.mail_items("'); Remove-Item C:\\ -Recurse #", 5)

    script, env = ran[0]
    payload = json.loads(base64.b64decode(env[outlook._ARGS_ENV]).decode("utf-8"))
    assert payload["query"] == "'); Remove-Item C:\\ -Recurse #"
    assert "Remove-Item" not in script, "the search must never be stitched into the script text"
    assert "$a.query" in script


def test_no_outlook_is_said_plainly_not_papered_over(monkeypatch):
    _stub(monkeypatch, {"error": "no_outlook"})
    with pytest.raises(ToolError) as e:
        TOOLS["read_outlook_calendar"].run({})
    assert "isn't installed" in str(e.value)


def test_not_signed_in_points_at_the_one_fix(monkeypatch):
    _stub(monkeypatch, {"error": "not_signed_in"})
    with pytest.raises(ToolError) as e:
        TOOLS["read_outlook_mail"].run({})
    assert "signed in" in str(e.value)


def test_the_calendar_is_listed_with_times_place_and_organiser(monkeypatch):
    _stub(monkeypatch, {"items": [
        {"subject": "Design review", "start": "2026-10-22T14:00:00", "end": "2026-10-22T15:00:00",
         "location": "Room 2", "organizer": "me@x.com", "all_day": False, "notes": ""},
        {"subject": "Focus block", "start": "2026-10-23T09:00:00", "end": "2026-10-23T11:00:00",
         "location": "", "organizer": "", "all_day": False, "notes": ""},
    ]})
    text = TOOLS["read_outlook_calendar"].run({"days_forward": 7}).text
    assert "2026-10-22 14:00 → 2026-10-22 15:00  Design review  @ Room 2  (me@x.com)" in text
    assert "Focus block" in text and "@ " not in text.split("Focus block")[1]


def test_a_mail_search_offers_the_full_read_by_id(monkeypatch):
    calls = _stub(monkeypatch, {"folder": "Inbox", "items": [
        {"entry_id": "ABCDEF0123456789XYZ", "subject": "Scholarship deadline", "from": "Aids <aids@uni.edu>",
         "unread": True, "at": "2026-10-21T08:12:00", "snippet": "Applications close on Friday…"},
    ]})
    text = TOOLS["read_outlook_mail"].run({"query": "scholarship"}).text
    assert "Scholarship deadline" in text and "new" in text and "read_outlook_message" in text
    assert calls[0]["query"] == "scholarship"

    _stub(monkeypatch, {"subject": "Scholarship deadline", "from": "Aids <aids@uni.edu>", "to": "me@x.com",
                        "cc": "", "at": "2026-10-21T08:12:00", "body": "Applications close on Friday at 17:00."})
    full = TOOLS["read_outlook_message"].run({"entry_id": "ABCDEF0123456789XYZ"}).text
    assert "Applications close on Friday at 17:00." in full and "From: Aids <aids@uni.edu>" in full


def test_contacts_carry_every_way_to_reach_them(monkeypatch):
    _stub(monkeypatch, {"items": [
        {"name": "Amara Okafor", "company": "Uni Aid", "emails": ["amara@uni.edu"], "phones": ["0700 111 222"]},
    ]})
    text = TOOLS["read_outlook_contacts"].run({"query": "amara"}).text
    assert "Amara Okafor (Uni Aid)  amara@uni.edu  0700 111 222" in text


def test_a_send_outlook_blocks_becomes_a_draft_and_the_truth(monkeypatch):
    _stub(monkeypatch, {"sent": False, "draft": True, "to": "a@b.c", "subject": "Hi",
                        "why": "Outlook stopped the send (guarded); the message is in Drafts, word for word, ready to send by hand."})
    text = TOOLS["send_outlook_mail"].run({"to": "a@b.c", "subject": "Hi", "body": "Hello"}).text
    assert "Drafts" in text and "word for word" in text


def test_sending_is_a_send_and_booking_is_a_create():
    assert TOOLS["send_outlook_mail"].kind_for({"to": "a@b.c"}) == "send"
    assert TOOLS["create_outlook_event"].kind_for({"subject": "x"}) == "create"
    assert TOOLS["read_outlook_mail"].kind_for({}) == "read"


def test_outlook_is_probed_once_a_minute_not_once_a_tool(monkeypatch):
    probes = []
    monkeypatch.setattr(outlook, "_run", lambda script, args=None: probes.append(1) or {"ok": True})
    monkeypatch.setattr(outlook, "_probed_at", 0.0)
    monkeypatch.setattr(outlook, "_probed_ok", None)
    assert outlook.installed() and outlook.installed()
    assert len(probes) == 1
