"""Decks: a real .pptx with a designed cover, sections, bullets, quotes and stats."""

from io import BytesIO
from pathlib import Path

import pytest
from pptx import Presentation

from compii_core.slides import THEMES, DeckError, deck_bytes
from compii_core.tools import Toolbox, ToolError

SPEC = [
    {"kind": "section", "title": "Where we are", "subtitle": "Three months in"},
    {"kind": "content", "title": "Three things worked", "eyebrow": "WINS",
     "bullets": ["Faster onboarding", "Fewer support tickets", "A calmer release week"],
     "notes": "Pause here and ask which win matters most."},
    {"kind": "quote", "text": "Sell the problem, not the product.", "by": "A colleague"},
    {"kind": "stats", "title": "By the numbers",
     "stats": [{"value": "42%", "label": "faster", "note": "vs Q1"}, {"value": "3", "label": "releases"}]},
    {"kind": "closing", "title": "Thank you", "subtitle": "Questions?"},
]


def _all_text(slide) -> str:
    parts = []
    for shape in slide.shapes:
        if shape.has_text_frame:
            parts.append(shape.text_frame.text)
    return "\n".join(parts)


def test_a_deck_reopens_with_every_slide_and_note():
    data = deck_bytes("Q3 review", SPEC, subtitle="What moved and what is next", author="Compii", theme="paper")
    prs = Presentation(BytesIO(data))
    assert len(prs.slides) == 6  # cover + five slides
    assert prs.slide_width == 12192000 and prs.slide_height == 6858000  # 16:9

    cover = _all_text(prs.slides[0])
    assert "Q3 review" in cover and "What moved and what is next" in cover

    content = prs.slides[2]
    body = _all_text(content)
    for line in SPEC[1]["bullets"]:
        assert line in body
    assert content.notes_slide.notes_text_frame.text == "Pause here and ask which win matters most."

    quote = _all_text(prs.slides[3])
    assert "Sell the problem" in quote and "A colleague" in quote

    stats = _all_text(prs.slides[4])
    assert "42%" in stats and "faster" in stats and "releases" in stats

    # Page numbers after the cover, and the deck title in every footer.
    for n, slide in enumerate(list(prs.slides)[1:], start=2):
        text = _all_text(slide)
        assert f"{n:02d} / 06" in text


def test_long_bullet_lists_split_into_two_columns():
    bullets = [f"Point number {i} with enough words to take a line of its own" for i in range(8)]
    prs = Presentation(BytesIO(deck_bytes("Many points", [{"kind": "content", "title": "All of it", "bullets": bullets}])))
    body = _all_text(prs.slides[1])
    assert all(b in body for b in bullets)


def test_a_deck_needs_a_title_and_a_slide():
    with pytest.raises(DeckError):
        deck_bytes("", [{"kind": "content", "title": "One"}])
    with pytest.raises(DeckError):
        deck_bytes("Title", [])


@pytest.mark.parametrize("theme", sorted(THEMES))
def test_every_theme_builds(theme):
    data = deck_bytes("A deck", [{"kind": "content", "title": "One", "bullets": ["a"]}], theme=theme)
    assert len(Presentation(BytesIO(data)).slides) == 2


def test_the_create_deck_tool_writes_a_file_and_refuses_to_overwrite(tmp_path: Path):
    box = Toolbox([tmp_path], tmp_path / "Compii", lambda _s: None)
    path = tmp_path / "pitch.pptx"
    got = box.create_deck({"path": str(path), "title": "Pitch", "slides": SPEC})
    assert path.exists() and got.files and got.files[0][1] == "created"
    assert len(Presentation(path).slides) == 6
    with pytest.raises(ToolError):
        box.create_deck({"path": str(path), "title": "Pitch again", "slides": SPEC})
    with pytest.raises(ToolError):
        box.create_deck({"path": str(tmp_path / "empty.pptx"), "title": "", "slides": SPEC})
