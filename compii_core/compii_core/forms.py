"""Profile, forms and applications: the everyday "fill this in for me" work.

Compii keeps a profile of the details a person types into forms over and over, reads a
page's fields in one call, answers what it can from the profile, and asks about the rest.
A password or card number is refused by the profile and blocked from forms by guard.py.
"""

from __future__ import annotations

from typing import Any, Callable

from .guard import is_secret
from .policy import ActionKind
from .profile import Profile, SensitiveField, canonical
from .tools import Tool, ToolError, ToolResult

MAX_QUESTIONS = 12


def profile_form_tools(profile: Profile, browser: Callable[[], Any]) -> list[Tool]:
    s = {"type": "string"}

    def view(_a: dict[str, Any]) -> ToolResult:
        items = profile.view()
        if not items:
            return ToolResult("The profile is empty. Ask the user for the basics (name, email, phone, date of birth, "
                              "address, college or employer) and store them with set_profile.")
        return ToolResult("\n".join(f"- {i['field']}: {i['value'][:100]}" for i in items))

    def set_field(a: dict[str, Any]) -> ToolResult:
        try:
            if a.get("answers"):
                for question, text in a["answers"].items():
                    if is_secret(question, text):
                        raise SensitiveField("Compii never stores passwords, card numbers or one-time codes.")
                    profile.set_answer(question, text)
            if not a.get("value") and not a.get("answers"):
                raise ToolError("Give the detail's name and value, or a list of question answers.")
            key = profile.set_field(a["field"], a.get("value", "")) if a.get("value") else canonical(a["field"])
        except SensitiveField as e:
            raise ToolError(f"{e} Ask the user to enter those themselves on the form.") from e
        return ToolResult(f"Saved {key} in the profile." + (f" Also {len(a.get('answers') or {})} answer(s)."
                                                              if a.get("answers") else ""))

    def answer(a: dict[str, Any]) -> ToolResult:
        wanted = [q.strip() for q in a["questions"] if q.strip()][:MAX_QUESTIONS]
        got = {q: profile.match(q) for q in wanted}
        missing = [q for q in wanted if not got[q]]
        lines = [f"✓ {q}: {v[:200]}" for q, v in got.items() if v]
        back = "\n".join(lines) or "Nothing in the profile answers these."
        if missing:
            back += "\nStill needed (ask the user with ask_user, then save each answer with set_profile):\n" \
                    + "\n".join(f"- {q}" for q in missing)
        return ToolResult(back + f"\n\n{len(lines)} of {len(wanted)} answered from the profile.")

    def fields(_a: dict[str, Any]) -> ToolResult:
        items = browser().form_fields()
        if not items:
            return ToolResult("This page has no fields I can fill - it may need clicking, or a frame I can't read.")
        out = []
        for i, f in enumerate(items, 1):
            value = profile.match(f["label"]) if f["label"] else None
            hint = f" -> '{value[:60]}'" if value else ""
            options = f" (choices: {', '.join(f['options'][:12])})" if f.get("options") else ""
            out.append(f"{i}. {f['label'] or '(unlabelled)'} [{f['kind']}{', required' if f['required'] else ''}]"
                       f"{options}{' = ' + f['value'] if f['value'] else ''}{hint}")
        need = sum(1 for f in items if not profile.match(f.get("label", "")))
        return ToolResult("\n".join(out) + f"\n\n{len(items)} fields; {need} the profile can't answer yet.")

    def fill(a: dict[str, Any]) -> ToolResult:
        values = {k: str(v) for k, v in a["values"].items() if str(v).strip()}
        if not values:
            raise ToolError("Nothing to fill - give the field labels and their values.")
        secrets = [k for k in values if is_secret(k, values[k])]
        if secrets:
            raise ToolError(f"Compii never types passwords, card numbers or one-time codes ({', '.join(secrets)}). "
                            "Ask the user to fill those fields themselves, then carry on.")
        filled, missing, unverified, page = browser().fill_many(values, bool(a.get("submit")))
        if not filled and not unverified:
            raise ToolError("None of those fields are on the page. Call form_fields to get the exact labels.")
        said = "; ".join(f"{k} = {values[k][:40]}" for k in filled)
        back = "\n\nPage now says:\n" + page[:1500] if a.get("submit") else ""
        return ToolResult((f"Filled {len(filled)} field(s): {said}." if filled else "No field kept its answer.")
                          + (f"\nThe page doesn't show these as filled, so Compii can't confirm them: "
                             f"{', '.join(unverified)}." if unverified else "")
                          + (f"\nCouldn't find: {', '.join(missing)}." if missing else "")
                          + (" Submitted." if a.get("submit") else " Nothing submitted yet - tell the user what is "
                             "filled and ask before submitting."),
                          sources=[])

    return [
        Tool("view_profile", "The details and saved answers you hold for this person (name, email, address, "
             "answers to common application questions).", {}, [], ActionKind.READ, view,
             lambda a: "Read the profile"),
        Tool("set_profile", "Store a detail or a written answer so forms and applications can be filled without asking "
             "again. Never store passwords, card numbers or one-time codes.",
             {"field": {**s, "description": "What it is, e.g. 'email', 'date of birth', 'why this scholarship'."},
              "value": {**s, "description": "The detail, or the answer text for a question."},
              "answers": {"type": "object", "description": "Several at once: {question: answer}.",
                          "additionalProperties": s}},
             ["field"], ActionKind.CHANGE, set_field,
             lambda a: f"Save {canonical(a['field'])} in the profile"),
        Tool("answer_questions", "Answer form or application questions from the profile in one go; asks the user "
             "about the ones you don't have and saves what they say.",
             {"questions": {"type": "array", "items": s, "description": "Exact labels or questions."}},
             ["questions"], ActionKind.READ, answer,
             lambda a: f"Answer {len(a['questions'])} question(s) from the profile"),
        Tool("form_fields", "List every field on the page open in your browser: its exact label, type, choices and "
             "current value, and what the profile already answers. Call this before filling a form.",
             {}, [], ActionKind.READ, fields, lambda a: "Read the form on the page"),
        Tool("fill_form", "Fill many fields of the form open in your browser in one step, then read the page back: "
             "fields that don't show the answer are reported as unconfirmed instead of claimed. Ask before submitting.",
             {"values": {"type": "object", "description": "{exact field label: value to enter}.",
                         "additionalProperties": s},
              "submit": {"type": "boolean", "description": "true only after the user agreed to submit."},
              "url": {**s, "description": "The address of the page you are filling; use the one browse or "
                                          "form_fields reported."}},
             ["values", "url"], ActionKind.SEND, fill,
             lambda a: f"Fill {len(a['values'])} field(s) on {a['url'] or 'the open page'}"),
    ]
