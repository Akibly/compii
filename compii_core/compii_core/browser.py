"""Compii's own browser: Microsoft Edge driven by Playwright.

It uses a separate profile in Compii's workspace, never the user's own
browser or logins. Playwright objects must stay on one thread, so a single
worker thread owns the browser and runs every action in order.
"""

from __future__ import annotations

import json
import os
import queue
import re
import threading
from collections.abc import Callable
from concurrent.futures import Future
from pathlib import Path
from typing import Any, TypeVar

MAX_TEXT = 12_000
T = TypeVar("T")


class BrowserError(Exception):
    """A page action failed in a way the agent can adapt to."""


class Browser:
    def __init__(self, profile: Path, headless: bool | None = None) -> None:
        self.profile = profile
        self.headless = headless if headless is not None else os.environ.get("COMPII_BROWSER_HEADLESS") == "1"
        self._jobs: queue.Queue[tuple[Callable[[], Any], Future] | None] = queue.Queue()
        self._thread: threading.Thread | None = None
        self._pw = None
        self._ctx = None

    # ---- worker -----------------------------------------------------------

    def _run(self, fn: Callable[[], T]) -> T:
        if self._thread is None or not self._thread.is_alive():
            self._thread = threading.Thread(target=self._loop, daemon=True, name="compii-browser")
            self._thread.start()
        fut: Future = Future()
        self._jobs.put((fn, fut))
        return fut.result(timeout=90)

    def _loop(self) -> None:
        while True:
            job = self._jobs.get()
            if job is None:
                break
            fn, fut = job
            try:
                fut.set_result(fn())
            except Exception as e:  # noqa: BLE001
                fut.set_exception(e)
        self._shutdown()

    def _page(self):
        if self._ctx is None:
            from playwright.sync_api import sync_playwright

            self._pw = sync_playwright().start()
            self.profile.mkdir(parents=True, exist_ok=True)
            self._ctx = self._pw.chromium.launch_persistent_context(
                str(self.profile), channel="msedge", headless=self.headless,
                viewport={"width": 1280, "height": 860},
            )
        pages = [p for p in self._ctx.pages if not p.is_closed()]
        return pages[-1] if pages else self._ctx.new_page()

    def _shutdown(self) -> None:
        try:
            if self._ctx is not None:
                self._ctx.close()
            if self._pw is not None:
                self._pw.stop()
        except Exception:  # noqa: BLE001
            pass
        self._ctx = self._pw = None

    def close(self) -> None:
        if self._thread and self._thread.is_alive():
            self._jobs.put(None)

    # ---- actions ------------------------------------------------------------

    def open(self, url: str) -> str:
        if not url.startswith(("http://", "https://")):
            url = "https://" + url

        def go() -> str:
            page = self._page()
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                page.wait_for_load_state("networkidle", timeout=5_000)
            except Exception as e:  # noqa: BLE001 - slow pages still have content
                if "Timeout" not in type(e).__name__ and "timeout" not in str(e).lower():
                    raise BrowserError(f"Couldn't open {url}: {e}") from e
            return _describe(page)

        return self._run(go)

    def read(self) -> str:
        return self._run(lambda: _describe(self._page()))

    def current_url(self) -> str:
        if self._thread is None or not self._thread.is_alive():
            return ""
        try:
            return self._run(lambda: self._page().url)
        except Exception:  # noqa: BLE001
            return ""

    def click(self, text: str) -> str:
        def press() -> str:
            page = self._page()
            for locate in (
                lambda: page.get_by_role("button", name=text),
                lambda: page.get_by_role("link", name=text),
                lambda: page.get_by_role("tab", name=text),
                lambda: page.get_by_role("menuitem", name=text),
                lambda: page.get_by_text(text, exact=False),
            ):
                loc = locate()
                if loc.count() > 0:
                    target = loc.first
                    try:
                        target.scroll_into_view_if_needed(timeout=3_000)
                        target.click(timeout=8_000)
                    except Exception as e:  # noqa: BLE001
                        raise BrowserError(f"Found “{text}” but couldn't click it: {e}") from e
                    try:
                        page.wait_for_load_state("domcontentloaded", timeout=8_000)
                    except Exception:  # noqa: BLE001
                        pass
                    return f"Clicked “{text}”.\n\n" + _describe(page)
            raise BrowserError(f"Nothing on the page is labelled “{text}”. Read the page to see the exact wording.")

        return self._run(press)

    def fill(self, field: str, value: str, submit: bool = False) -> str:
        def type_in() -> str:
            page = self._page()
            for locate in (
                lambda: page.get_by_label(field),
                lambda: page.get_by_placeholder(field),
                lambda: page.get_by_role("textbox", name=field),
                lambda: page.get_by_role("searchbox", name=field),
                lambda: page.get_by_role("combobox", name=field),
            ):
                loc = locate()
                if loc.count() > 0:
                    box = loc.first
                    box.fill(value, timeout=8_000)
                    kept, _dropped = _confirmed(page, [field], {field: value})
                    said = f"Filled “{field}”." if kept else \
                        f"Typed into “{field}”, but the page doesn't show that answer, so Compii can't confirm it."
                    if submit:
                        box.press("Enter")
                        try:
                            page.wait_for_load_state("domcontentloaded", timeout=10_000)
                        except Exception:  # noqa: BLE001
                            pass
                        return said + " And submitted.\n\n" + _describe(page)
                    return said
            raise BrowserError(f"No field labelled “{field}” on this page.")

        return self._run(type_in)

    def form_fields(self) -> list[dict[str, Any]]:
        """Every fillable control on the page: label, kind, current value and options."""

        def grab() -> list[dict[str, Any]]:
            page = self._page()
            try:
                return page.evaluate(_FIELDS_JS)
            except Exception as e:  # noqa: BLE001
                raise BrowserError(f"Couldn't read the form on this page: {e}") from e

        return self._run(grab)

    def fill_many(self, values: dict[str, str], submit: bool = False) -> tuple[list[str], list[str], list[str], str]:
        """Fill a whole form at once. Returns (filled, not found, not confirmed, page description)."""
        wanted = [(label, value) for label, value in values.items() if str(value).strip()]

        def do() -> tuple[list[str], list[str], list[str], str]:
            page = self._page()
            try:
                page.wait_for_load_state("domcontentloaded", timeout=5_000)
            except Exception:  # noqa: BLE001
                pass
            filled, missing = [], []
            for label, value in wanted:
                try:
                    _fill_one(page, label, str(value))
                    filled.append(label)
                except Exception:  # noqa: BLE001 - one odd field shouldn't lose the whole form
                    missing.append(label)
            filled, unverified = _confirmed(page, filled, values)
            if submit and filled:
                try:
                    button = page.get_by_role("button", name=re.compile(r"submit|next|continue|send|apply|finish", re.I))
                    (button.first if button.count() else page.locator("button[type=submit]").first).click(timeout=6_000)
                    try:
                        page.wait_for_load_state("domcontentloaded", timeout=8_000)
                    except Exception:  # noqa: BLE001
                        pass
                except Exception:  # noqa: BLE001
                    missing.append("(submit button)")
            return filled, missing, unverified, _describe(page)

        return self._run(do)


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def _landed(kind: str, want: str, got: str) -> bool:
    """Did the page really take this value? Fields decorate what they're given ("Nairobi, KE"),
    so shared wording counts - but a value cut short is the page refusing part of it, not taking it.
    """
    w, g = _norm(want), _norm(got)
    if kind in ("checkbox", "switch"):
        return (w in ("yes", "on", "true", "1", "checked")) == bool(g)
    if not g:
        return False
    return w == g or (len(w) > 2 and w in g) or (len(g) > 2 and w.endswith(g) and w != g)


def _confirmed(page, filled: list[str], values: dict[str, str]) -> tuple[list[str], list[str]]:
    """Split the fields just filled into the ones the page now shows and the ones it doesn't.

    The page's own readout is the only witness: a form that quietly drops an answer (a limit, a
    script that clears the box) must not be reported to the user as filled in.
    """
    if not filled:
        return filled, []
    try:
        rows = page.evaluate(_FIELDS_JS)
    except Exception:  # noqa: BLE001 - the page changed while we looked
        return filled, []
    live: dict[str, tuple[str, str]] = {}
    for f in rows or []:
        key = _norm(str(f.get("label", "")))
        if key and key not in live:
            live[key] = (str(f.get("kind", "")), str(f.get("value", "")))
    kept, unverified = [], []
    for label in filled:
        row = live.get(_norm(label))
        if row is None or _landed(row[0], str(values[label]), row[1]):
            kept.append(label)
        else:
            unverified.append(label)
    return kept, unverified


def _locate(page, label: str):
    """Find the control a form label refers to, allowing for the star and wording sites add."""
    want = re.sub(r"\s*\*+\s*$", "", label.strip())
    exact = _norm(want)
    for make in (lambda: page.get_by_label(want),
                 lambda: page.get_by_placeholder(want),
                 lambda: page.get_by_role("textbox", name=want),
                 lambda: page.get_by_role("searchbox", name=want),
                 lambda: page.get_by_role("combobox", name=want),
                 lambda: page.get_by_role("spinbutton", name=want),
                 lambda: page.get_by_role("radio", name=want),
                 lambda: page.get_by_role("checkbox", name=want)):
        try:
            loc = make()
            if loc.count():
                return loc.first
        except Exception:  # noqa: BLE001
            continue
    try:  # last resort: a control near text that looks like the label
        for el in page.locator("input, textarea, select").all():
            text = " ".join(filter(None, [el.get_attribute("aria-label") or "", el.get_attribute("name") or "",
                                           el.get_attribute("id") or "", el.get_attribute("placeholder") or ""]))
            n = _norm(text)
            if n and (n == exact or exact in n or (len(exact) > 4 and n in exact)):
                return el
    except Exception:  # noqa: BLE001
        pass
    return None


_FIELDS_JS = """() => {
  const textOf = n => ((n && (n.innerText || n.textContent) || '').replace(/\\s+/g, ' ').trim());
  const els = [...document.querySelectorAll('input, textarea, select')].filter(e => {
    if (e.disabled || e.readOnly || ['hidden','submit','button','reset','image'].includes(e.type)) return false;
    const r = e.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }).slice(0, 200);
  const out = [], taken = new Set();
  for (const e of els) {
    const id = e.id ? CSS.escape(e.id) : '';
    let label = id && document.querySelector(`label[for=${id}]`) ? textOf(document.querySelector(`label[for=${id}]`)) : '';
    if (!label && e.name) {
      const t = document.querySelector(`label[for=${CSS.escape(e.name)}]`);
      if (t) label = textOf(t);
    }
    if (!label) { const f = e.closest('label'); if (f) label = textOf(f); }
    if (!label) {
      let node = e.closest('div,td,li,p'), hops = 0;
      while (node && hops++ < 3 && !label) {
        const t = [...node.childNodes].filter(n => n !== e && !e.contains(n)).map(n => textOf(n)).join(' ').trim();
        if (t && t.length < 90) label = t;
        node = node.parentElement;
      }
    }
    let kind = e.tagName === 'SELECT' ? 'select' : e.type;
    let options = [];
    if (kind === 'select') options = [...e.options].slice(0, 40).map(o => o.text.trim()).filter(Boolean);
    let value = e.value || '';
    if (kind === 'radio') {
      const key = 'radio:' + (e.name || label);
      if (taken.has(key)) continue;
      taken.add(key);
      const group = [...document.querySelectorAll(`input[type=radio][name=${CSS.escape(e.name || '')}]`)];
      const use = group.length ? group : [e];
      const nameOf = r => textOf(r.labels && r.labels[0]) || (r.value || '').trim();
      let q = '';
      const fs = e.closest('fieldset');
      if (fs && fs.querySelector('legend')) q = textOf(fs.querySelector('legend'));
      for (let node = use[0].closest('label') || use[0], hops = 0; node && hops++ < 4 && !q;) {
        for (let p = node.previousElementSibling; p && !q; p = p.previousElementSibling) {
          const t = textOf(p);
          if (t && t.length < 90 && !t.includes('<input')) q = t;
        }
        if (!q) node = node.parentElement;
      }
      const on = use.find(r => r.checked);
      out.push({ label: (q || label || e.name || '').trim().slice(0, 90), kind: 'radio',
                 value: on ? nameOf(on) : '', options: use.map(nameOf).filter(Boolean), required: !!e.required });
      continue;
    }
    if (kind === 'checkbox') value = e.checked ? 'checked' : '';
    if (kind === 'select') value = e.selectedOptions?.[0]?.text?.trim() || '';
    out.push({ label: (label || e.placeholder || e.name || e.id || '').trim().slice(0, 90),
               kind, value: String(value).slice(0, 120), options, required: !!e.required });
  }
  return out;
}"""


def _fill_one(page, label: str, value: str) -> None:
    loc = _locate(page, label)
    if loc is None:
        raise BrowserError(f"No field for “{label}”.")
    kind = (loc.evaluate("e => e.tagName === 'SELECT' ? 'select' : (e.type || 'textarea')") or "text").lower()
    loc.scroll_into_view_if_needed(timeout=3_000)
    want = _norm(value)
    if kind == "select":
        loc.select_option(label=value, timeout=6_000)
    elif kind == "checkbox":
        (loc.uncheck if want in ("off", "no", "false", "0", "unchecked") else loc.check)(timeout=6_000)
    elif kind == "radio":
        # The label names the question and the value picks one choice, so the whole group is needed,
        # not only the control _locate happened to reach.
        name = loc.evaluate("e => e.name || ''")
        group = page.locator(f"input[type=radio][name={json.dumps(name)}]").all() if name else [loc]
        for opt in group:
            text = _norm(" ".join(filter(None, [opt.evaluate(
                "e => (e.labels?.[0]?.innerText || '') + ' ' + (e.value || '')")])))
            if want and (text == want or want in text):
                opt.check(timeout=6_000)
                return
        raise BrowserError(f"“{value}” isn't one of the choices for “{label}”.")
    elif kind == "file":
        loc.set_input_files(value, timeout=10_000)
    elif kind in ("number", "date", "time", "email"):
        loc.fill(value, timeout=6_000)
    else:
        loc.fill("", timeout=6_000)
        loc.type(value, delay=8, timeout=20_000)


def _describe(page) -> str:
    """Title, address, readable text and the main links, for the agent to read."""
    title = page.title()
    try:
        text = page.inner_text("body", timeout=5_000)
    except Exception:  # noqa: BLE001
        text = ""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    body = "\n".join(lines)
    if len(body) > MAX_TEXT:
        body = body[:MAX_TEXT] + "\n[… page continues]"
    links = []
    try:
        for a in page.locator("a[href]").all()[:40]:
            label = (a.inner_text(timeout=500) or "").strip()
            if label and len(label) < 80:
                links.append(label)
    except Exception:  # noqa: BLE001
        pass
    out = f"Page: {title}\nAddress: {page.url}\n\n{body}"
    if links:
        out += "\n\nLinks: " + " · ".join(dict.fromkeys(links))
    return out
