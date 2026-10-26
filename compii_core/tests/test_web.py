import asyncio

import httpx

from compii_core.web import page_text, search, web_tools

from test_core import ScriptBrain, home, opened, toolbox  # noqa: F401 - fixtures

RESULTS = """
<div class="result results_links results_links_deep web-result ">
  <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Flaptops&amp;rut=x">Best <b>laptops</b> 2026</a>
  <a class="result__snippet" href="#">Our <b>top</b> picks under $500.</a>
</div>
<div class="result results_links results_links_deep web-result ">
  <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad=1">Sponsored</a>
</div>
"""
PAGE = "<html><head><title>Laptops</title><script>evil()</script></head><body><nav>menu</nav><p>The Acer Swift Go is best.</p><p>Second line</p></body></html>"


def client():
    def handle(request: httpx.Request) -> httpx.Response:
        if "duckduckgo" in str(request.url):
            return httpx.Response(200, text=RESULTS)
        return httpx.Response(200, text=PAGE)

    return httpx.Client(transport=httpx.MockTransport(handle))


def test_search_unwraps_links_and_skips_ads():
    r = search("laptops", client=client())
    assert r == [{"title": "Best laptops 2026", "url": "https://example.com/laptops", "snippet": "Our top picks under $500."}]


def test_page_text_keeps_the_words_not_the_code():
    title, text = page_text("https://example.com/laptops", client=client())
    assert title == "Laptops" and "Acer Swift Go" in text and "evil" not in text and "menu" not in text


def test_tools_are_read_only():
    tools = {t.name: t for t in web_tools(client)}
    assert tools["search_web"].kind_for({}).value == "read"
    assert "example.com/laptops" in tools["search_web"].run({"query": "x"}).text


def test_a_read_page_is_a_source_but_a_result_list_is_not():
    """Only a page Compii actually opened counts as a source; candidates it merely saw don't."""
    tools = {t.name: t for t in web_tools(client)}
    read = tools["read_web_page"].run({"url": "https://example.com/laptops"})
    assert read.sources == [{"title": "Laptops", "url": "https://example.com/laptops"}]
    assert tools["search_web"].run({"query": "x"}).sources == []


async def test_web_sources_reach_the_conversation_as_events(toolbox, home, tmp_path):
    from compii_core.agent import Agent
    from compii_core.journal import Journal
    from compii_core.policy import Policy

    brain = ScriptBrain([("read_web_page", {"url": "https://example.com/laptops"})], final="The Acer Swift Go is best.")
    events: list[dict] = []

    async def emit(e):
        events.append(e)

    agent = Agent(brain, toolbox, Policy(), Journal(tmp_path / "j.jsonl"), emit)
    agent.toolbox.tools.update({t.name: t for t in web_tools(client)})
    task = agent.start("best laptop?")
    await asyncio.wait_for(task.runner, 5)
    sources = [e for e in events if e["type"] == "sources"]
    assert sources and sources[0]["items"][0]["url"] == "https://example.com/laptops"


LITE = """<table><tr><td><a rel="nofollow" href="https://kumasi.example/weather" class='result-link'>Kumasi weather</a></td></tr>
<tr><td class='result-snippet'>Warm and dry in December.</td></tr></table>"""
BING = """<rss><channel><item><title>Kumasi in December</title><link>https://bing.example/k</link>
<description>33°C by day.</description></item></channel></rss>"""


def _engines(answers):
    """A web where each engine answers as given: (status, body) by host."""
    asked = []

    def handle(request: httpx.Request) -> httpx.Response:
        host = request.url.host
        asked.append(host)
        status, body = answers.get(host, (404, ""))
        return httpx.Response(status, text=body)

    return httpx.Client(transport=httpx.MockTransport(handle)), asked


def test_a_refusing_duckduckgo_falls_through_to_lite():
    c, asked = _engines({"html.duckduckgo.com": (202, ""), "lite.duckduckgo.com": (200, LITE)})
    assert search("kumasi", client=c) == [
        {"title": "Kumasi weather", "url": "https://kumasi.example/weather", "snippet": "Warm and dry in December."}]
    assert asked == ["html.duckduckgo.com", "lite.duckduckgo.com"]


def test_when_both_duckduckgos_refuse_bing_answers():
    c, _ = _engines({"html.duckduckgo.com": (202, ""), "lite.duckduckgo.com": (202, ""), "www.bing.com": (200, BING)})
    assert search("kumasi", client=c) == [
        {"title": "Kumasi in December", "url": "https://bing.example/k", "snippet": "33°C by day."}]


def test_only_when_every_engine_refuses_is_it_an_error():
    import pytest

    from compii_core.tools import ToolError

    c, _ = _engines({"html.duckduckgo.com": (202, ""), "lite.duckduckgo.com": (503, ""), "www.bing.com": (429, "")})
    with pytest.raises(ToolError) as e:
        search("kumasi", client=c)
    assert "DuckDuckGo: 202" in str(e.value) and "Bing: 429" in str(e.value)


def test_a_blocked_page_says_what_to_do_instead():
    import pytest

    from compii_core.tools import ToolError

    c, _ = _engines({"blocked.example": (403, "")})
    with pytest.raises(ToolError) as e:
        page_text("https://blocked.example/x", client=c)
    assert "use another result" in str(e.value)
