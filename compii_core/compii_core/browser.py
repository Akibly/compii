"""Compii's own browser: Microsoft Edge driven by Playwright.

It uses a separate profile in Compii's workspace, never the user's own
browser or logins. Playwright objects must stay on one thread, so a single
worker thread owns the browser and runs every action in order.
"""

from __future__ import annotations

import os
import queue
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
                    if submit:
                        box.press("Enter")
                        try:
                            page.wait_for_load_state("domcontentloaded", timeout=10_000)
                        except Exception:  # noqa: BLE001
                            pass
                        return f"Filled “{field}” and submitted.\n\n" + _describe(page)
                    return f"Filled “{field}”."
            raise BrowserError(f"No field labelled “{field}” on this page.")

        return self._run(type_in)


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
