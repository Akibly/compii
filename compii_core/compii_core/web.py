"""Web search and reading for any AI (Claude has its own; NVIDIA, Groq, Gemini and
local models use these). Free and keyless: DuckDuckGo's HTML results, then the
page text itself. Everything read here is untrusted data for the AI."""

from __future__ import annotations

import html
import re
import urllib.parse
from typing import Any

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
PAGE_CHARS = 14_000


def _clean(s: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def search(query: str, limit: int = 8, client: Any = None) -> list[dict[str, str]]:
    import httpx

    c = client or httpx.Client(timeout=15, follow_redirects=True, headers={"User-Agent": UA})
    try:
        r = c.post("https://html.duckduckgo.com/html/", data={"q": query})
    finally:
        if client is None:
            c.close()
    if r.status_code != 200:
        raise ToolError(f"Web search didn't answer ({r.status_code}). Try again in a moment.")
    results = []
    blocks = re.split(r'<div class="result results_links', r.text)[1:]
    for b in blocks:
        m = re.search(r'class="result__a" href="([^"]+)"[^>]*>(.*?)</a>', b, re.S)
        if not m:
            continue
        url = html.unescape(m.group(1))
        if "duckduckgo.com/l/?" in url:  # unwrap the redirect link
            q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            url = q.get("uddg", [url])[0]
        if "duckduckgo.com/y.js" in url:  # ads
            continue
        snip = re.search(r'class="result__snippet"[^>]*>(.*?)</a>', b, re.S)
        results.append({"title": _clean(m.group(2)), "url": url, "snippet": _clean(snip.group(1)) if snip else ""})
        if len(results) >= limit:
            break
    return results


def page_text(url: str, client: Any = None) -> tuple[str, str]:
    """(title, readable text) of a web page."""
    import httpx

    if not url.startswith(("http://", "https://")):
        raise ToolError("Give a full web address starting with https://")
    c = client or httpx.Client(timeout=20, follow_redirects=True, headers={"User-Agent": UA})
    try:
        r = c.get(url)
    finally:
        if client is None:
            c.close()
    if r.status_code >= 400:
        raise ToolError(f"That page answered {r.status_code}.")
    body = r.text
    title = _clean((re.search(r"<title[^>]*>(.*?)</title>", body, re.S | re.I) or [None, ""])[1])
    body = re.sub(r"(?is)<(script|style|noscript|svg|nav|footer|header|form)[^>]*>.*?</\1>", " ", body)
    body = re.sub(r"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr|section|article)>", "\n", body)
    text = _clean(body)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text).strip()
    return title, text


def web_tools(client_factory=None) -> list[Tool]:
    s = {"type": "string"}

    def client():
        return client_factory() if client_factory else None

    def run_search(a: dict[str, Any]) -> ToolResult:
        results = search(a["query"], client=client())
        if not results:
            return ToolResult("No results. Try different words.")
        lines = [f"{i}. {r['title']} — {r['url']}\n   {r['snippet']}" for i, r in enumerate(results, 1)]
        return ToolResult("\n".join(lines))

    def run_read(a: dict[str, Any]) -> ToolResult:
        title, text = page_text(a["url"], client=client())
        more = f"\n[… {len(text) - PAGE_CHARS} more characters not shown]" if len(text) > PAGE_CHARS else ""
        # The page was really opened and read: record it as a source the user can check.
        return ToolResult(f"{title}\n{a['url']}\n\n{text[:PAGE_CHARS]}{more}",
                          sources=[{"title": title or a["url"], "url": a["url"]}])

    return [
        Tool("search_web", "Search the web (free). Returns titles, links and snippets. Use for current facts, prices, "
             "news, how-tos and research; then read_web_page on the best results.",
             {"query": s}, ["query"], ActionKind.READ, run_search, lambda a: f"Search the web for “{a['query']}”"),
        Tool("read_web_page", "Read the text of a web page (quick, no browser window). Use after search_web.",
             {"url": s}, ["url"], ActionKind.READ, run_read,
             lambda a: f"Read {urllib.parse.urlparse(a['url']).netloc or a['url']}"),
    ]
