"""The profile: what Compii knows about the user, so forms and applications answer themselves.

Nothing here is sent anywhere and nothing is shown back in full; it lives in one JSON file
in Compii's workspace. Secrets (passwords, card numbers, one-time codes) are never accepted.
"""

from __future__ import annotations

import json
import re
import threading
import time
from pathlib import Path
from typing import Any

from .guard import is_secret

MAX_FACT = 4000

# Labels people actually type into forms, mapped onto one field name.
ALIASES: dict[str, tuple[str, ...]] = {
    "full_name": ("full name", "your name", "name and surname", "first and last name", "complete name"),
    "first_name": ("first name", "given name", "forename"),
    "last_name": ("last name", "surname", "family name"),
    "email": ("email", "e-mail", "email address", "electronic mail"),
    "phone": ("phone", "telephone", "mobile", "cell", "contact number", "whatsapp"),
    "dob": ("date of birth", "birth date", "dob", "day of birth", "birthday"),
    "gender": ("gender", "sex"),
    "nationality": ("nationality", "citizenship", "nationality/country of origin"),
    "address": ("address", "street address", "mailing address", "postal address", "home address"),
    "city": ("city", "town", "town/city"),
    "region": ("state", "province", "region", "county"),
    "postal_code": ("postal code", "zip", "zip code", "post code", "pin code"),
    "country": ("country", "country of residence", "nation"),
    "institution": ("school", "university", "college", "institution", "employer", "company", "organisation"),
    "course": ("course", "major", "field of study", "program", "degree", "position", "job title"),
    "year": ("year of study", "graduation year", "year", "class of"),
    "website": ("website", "url", "portfolio", "linkedin", "profile link"),
    "bio": ("about you", "bio", "personal statement", "short bio", "summary"),
    "why": ("why do you want", "motivation", "statement of purpose", "purpose", "reason"),
    "goals": ("goals", "career goals", "objectives", "future plans"),
    "references": ("references", "referee", "recommendation"),
    "emergency": ("emergency contact", "next of kin"),
}

# Questions in the profile that a form or application can be asked again and again.
TOPIC_WORDS: dict[str, tuple[str, ...]] = {
    "why": ("why", "motivation", "purpose", "interest", "reason"),
    "goals": ("goal", "career", "future", "plan", "objective", "ambition"),
    "bio": ("about you", "yourself", "bio", "background", "who are you"),
    "strengths": ("strength", "skill", "talent", "good at", "quality"),
    "challenge": ("challenge", "obstacle", "difficulty", "overcome", "failure"),
    "leadership": ("leader", "initiative", "organise", "team", "community", "volunteer"),
    "financial": ("financial", "income", "fee", "funding", "money", "scholarship need"),
    "interests": ("hobby", "interest", "free time", "spare time"),
    "availability": ("available", "start date", "notice", "when can you"),
    "salary": ("salary", "pay", "compensation", "rate"),
    "references": ("reference", "referee", "recommend"),
}


# Words that appear on every form and carry no meaning of their own.
STOPWORDS = {"what", "your", "you", "the", "and", "for", "are", "is", "please", "enter", "type", "provide",
             "from", "with", "tell", "us", "me", "about", "all", "any", "other", "if", "any", "that", "have",
             "has", "list", "state", "give", "name", "full", "complete", "indicate", "which", "when", "where"}


def _words(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z]{4,}", text.lower()) if w not in STOPWORDS}


class SensitiveField(ValueError):
    """A field Compii must never hold."""


class Profile:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self.fields: dict[str, str] = {}
        self.answers: dict[str, str] = {}
        self.updated: float | None = None
        if path.exists():
            try:
                data = json.loads(path.read_text(encoding="utf-8-sig"))
                self.fields = {str(k): str(v) for k, v in (data.get("fields") or {}).items()}
                self.answers = {str(k): str(v)[:MAX_FACT] for k, v in (data.get("answers") or {}).items()}
                self.updated = data.get("updated")
            except (ValueError, TypeError, AttributeError):
                path.replace(path.with_suffix(f".broken-{int(time.time())}.json"))

    def save(self) -> None:
        with self._lock:
            self.updated = time.time()
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"fields": self.fields, "answers": self.answers, "updated": self.updated},
                                      indent=1, ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.path)

    # ---- details ---------------------------------------------------------------

    def set_field(self, name: str, value: str) -> str:
        key = canonical(name)
        if is_secret(key, value):
            raise SensitiveField("Compii never stores passwords, card numbers or one-time codes.")
        value = value.strip()[:MAX_FACT]
        if not value:
            self.fields.pop(key, None)
        else:
            self.fields[key] = value
        self.save()
        return key

    def get(self, name: str) -> str | None:
        return self.fields.get(canonical(name))

    def set_answer(self, topic: str, text: str) -> str:
        key = re.sub(r"[^a-z]+", "_", topic.strip().lower()).strip("_")[:40] or "answer"
        self.answers[key] = text.strip()[:MAX_FACT]
        self.save()
        return key

    def view(self) -> list[dict[str, str]]:
        return [{"field": k, "value": v} for k, v in self.fields.items()] + [
            {"field": f"answer:{k}", "value": v} for k, v in self.answers.items()]

    def missing(self, wanted: list[str]) -> list[str]:
        return [w for w in wanted if not self.match(w)]

    def forget(self, name: str) -> bool:
        key = canonical(name)
        found = self.fields.pop(key, None) is not None or self.answers.pop(key, None) is not None
        if found:
            self.save()
        return found

    # ---- answering -------------------------------------------------------------

    def match(self, question: str) -> str | None:
        """The stored answer for a form label or a question, or None."""
        q = question.strip().lower()
        key = canonical(question)
        if key in self.fields and not is_secret(key):
            return self.fields[key]
        for topic, text in self.answers.items():
            if topic.replace("_", " ") in q:
                return text
        words = _words(q)
        best, score = None, 0
        for field_name, aliases in ALIASES.items():
            for alias in (field_name, *aliases):
                aw = _words(alias) or {alias.lower()}
                s = len(words & aw)
                if s > score:
                    best, score = field_name, s
        if best and score and self.fields.get(best):
            return self.fields[best]
        for alias, value in self.fields.items():
            if alias in self.answers:  # a written answer saved under a detail's name
                if alias.replace("_", " ") in q or any(w in q for w in alias.split("_") if len(w) > 4):
                    return value
        for topic, hints in TOPIC_WORDS.items():
            if self.answers.get(topic) and any(h in q for h in hints):
                return self.answers[topic]
        return None

    def context(self) -> str:
        """A short block for the system prompt: what Compii can already answer about you."""
        if not self.fields and not self.answers:
            return ""
        details = ", ".join(f"{k.replace('_', ' ')}: {v[:60]}" for k, v in list(self.fields.items())[:30])
        topics = ", ".join(self.answers)
        out = "What you already know about the user (their profile; use it instead of asking, " \
              "and never print it in full):\n"
        if details:
            out += f"Details: {details}\n"
        if topics:
            out += f"Saved answers for questions about: {topics}\n"
        out += "When a form or application needs one of these, fill it from the profile. " \
               "When it needs something you don't have, use ask_user once and save the answer with set_profile."
        return out.strip()


def canonical(label: str) -> str:
    """'Date of Birth:' -> 'dob' - so the same detail is never stored twice."""
    q = re.sub(r"[^a-z0-9 ]+", " ", label.lower()).strip()
    if q in ("dob", "date of birth", "birth date", "day of birth"):
        return "dob"
    best, score = None, 0
    for field_name, aliases in ALIASES.items():
        for alias in (field_name.replace("_", " "), *aliases):
            if alias == q:
                return field_name
            s = len(set(alias.split()) & set(q.split()))
            if q.startswith(alias) and s > score:
                best, score = field_name, s
    if best:
        return best
    return re.sub(r"[^a-z0-9]+", "_", q).strip("_")[:40] or "field"
