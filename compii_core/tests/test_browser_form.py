"""The real browser on a real page: reading a form and filling a whole form at once.

Skipped when Edge or Playwright isn't on this machine. A fake browser can't stand in
here: what the page reports back is what Compii then claims it did, and this is the
code that decides which control a label refers to.
"""
from __future__ import annotations

import pytest

from compii_core.browser import Browser

PAGE = """<!doctype html><body><h1>Scholarship application</h1>
<form onsubmit="document.getElementById('done').textContent='SUBMITTED';return false;">
  <label for="fn">Full name *</label><input id="fn" name="fn" required>
  <label for="ct">Country of residence</label><select id="ct" name="ct">
    <option value="">Choose one</option><option>India</option><option>Kenya</option><option>United Kingdom</option>
  </select>
  <p>Have you studied abroad?</p>
  <label><input type="radio" name="abroad" value="Yes"> Yes</label>
  <label><input type="radio" name="abroad" value="No"> No</label>
  <label for="ess">Why do you deserve this scholarship?</label><textarea id="ess" name="ess"></textarea>
  <label for="cap">Phone (the page keeps five digits)</label>
  <input id="cap" name="cap" oninput="this.value=this.value.slice(0,5)">
  <label for="pw">Password</label><input id="pw" name="pw" type="password">
  <label><input type="checkbox" id="terms" name="terms"> I accept the terms</label>
  <button type="submit">Submit application</button>
</form><p id="done"></p></body>"""


@pytest.fixture(scope="module")
def page(tmp_path_factory):
    browser = Browser(tmp_path_factory.mktemp("edge"), headless=True)
    try:
        browser._run(lambda: browser._page().set_content(PAGE))
    except Exception as e:  # noqa: BLE001 - no Edge on this machine
        pytest.skip(f"no browser to test against: {str(e)[:120]}")
    yield browser
    browser.close()


def test_a_radio_group_is_one_field_named_by_its_question(page):
    fields = page.form_fields()
    radios = [f for f in fields if f["kind"] == "radio"]
    assert len(radios) == 1, radios
    assert radios[0]["label"] == "Have you studied abroad?"  # not the internal name "abroad"
    assert radios[0]["options"] == ["Yes", "No"]
    assert {f["label"] for f in fields} >= {"Full name *", "Country of residence", "Password", "I accept the terms"}


def test_the_whole_form_fills_in_one_step_without_submitting(page):
    filled, missing, unverified, _ = page.fill_many({
        "Full name *": "Asha Patel", "Country of residence": "Kenya", "Have you studied abroad?": "No",
        "Why do you deserve this scholarship?": "I taught myself chemistry from a phone.",
        "I accept the terms": "on"})
    assert missing == [] and unverified == [] and len(filled) == 5
    got = page._run(lambda: {
        "name": page._page().input_value("#fn"), "country": page._page().input_value("#ct"),
        "abroad": page._page().eval_on_selector_all("input[name=abroad]:checked", "e => e.map(x => x.value)"),
        "essay": page._page().input_value("#ess"), "terms": page._page().is_checked("#terms"),
        "done": page._page().inner_text("#done")})
    assert got["name"] == "Asha Patel" and got["country"] == "Kenya" and got["terms"] is True
    assert got["abroad"] == ["No"] and got["essay"].startswith("I taught myself")
    assert got["done"] == ""  # nothing sent off without the user agreeing


def test_an_answer_the_page_throws_away_is_not_claimed(page):
    """The form looks filled, but the page itself keeps only part of the answer."""
    filled, missing, unverified, _ = page.fill_many({"Phone (the page keeps five digits)": "0700 123 456"})
    assert filled == [] and missing == [] and unverified == ["Phone (the page keeps five digits)"]
    assert page._run(lambda: page._page().input_value("#cap")).strip() == "0700"


def test_a_label_written_slightly_differently_still_finds_the_field(page):
    filled, missing, unverified, _ = page.fill_many({"Full name": "Asha P.", "country": "India"})
    assert filled == ["Full name", "country"] and missing == [] and unverified == []
    assert page._run(lambda: (page._page().input_value("#fn"), page._page().input_value("#ct"))) == ("Asha P.", "India")


def test_submit_only_happens_when_it_is_asked_for(page):
    filled, missing, unverified, _ = page.fill_many({"Full name *": "Asha Patel"}, submit=True)
    assert filled == ["Full name *"] and missing == [] and unverified == []
    assert page._run(lambda: page._page().inner_text("#done")) == "SUBMITTED"
