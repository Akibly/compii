import json

import pytest

from compii_core.guard import UNTRUSTED_TOOLS
from compii_core.tools import Toolbox, ToolError

from test_core import home  # noqa: F401 - fixture


@pytest.fixture
def box(home) -> Toolbox:
    return Toolbox([home["downloads"]], home["workspace"], lambda s: None)


V1 = """# Agreement

The vendor delivers monthly.
Payment is due in 30 days.
Either side may end it with 60 days notice.
"""

V2 = """# Agreement

The vendor delivers monthly.
Payment is due in 15 days.
Either side may end it with 60 days notice.
A late fee of 5% applies.
"""


def _tools(box: Toolbox) -> dict:
    return box.tools


def test_compare_reports_what_actually_changed(box, home):
    a = home["downloads"] / "v1.md"
    b = home["downloads"] / "v2.md"
    a.write_text(V1, encoding="utf-8")
    b.write_text(V2, encoding="utf-8")

    out = json.loads(_tools(box)["compare_documents"].run({"path_a": str(a), "path_b": str(b)}).text)
    assert not out["identical"] and 0.6 < out["similarity"] < 1
    assert out["counts"] == {"only_in_first": 0, "only_in_second": 1, "changed": 1}
    text = json.dumps(out)
    assert "15 days" in text and "30 days" in text and "late fee" in text
    assert out["compared_lines"] == {"first": 5, "second": 6}

    same = json.loads(_tools(box)["compare_documents"].run({"path_a": str(a), "path_b": str(a)}).text)
    assert same["identical"] and same["differences"] == []


def test_compare_can_ignore_spacing_and_case(box, home):
    a = home["downloads"] / "notes-plain.txt"
    b = home["downloads"] / "notes-shouty.txt"
    a.write_text("Meeting at 10\nBring the deck\n", encoding="utf-8")
    b.write_text("  MEETING   AT 10  \nbring the DECK\n", encoding="utf-8")

    strict = json.loads(_tools(box)["compare_documents"].run({"path_a": str(a), "path_b": str(b)}).text)
    assert not strict["identical"]

    loose = json.loads(_tools(box)["compare_documents"].run(
        {"path_a": str(a), "path_b": str(b), "ignore": "all"}).text)
    assert loose["identical"], "the same words with different spacing is not a real change"


def test_compare_stays_inside_the_allowed_folders_and_says_when_a_file_is_missing(box, home):
    a = home["downloads"] / "v1.md"
    a.write_text(V1, encoding="utf-8")
    with pytest.raises(ToolError, match="outside"):
        _tools(box)["compare_documents"].run({"path_a": str(a), "path_b": str(home["outside"] / "v2.md")})
    with pytest.raises(ToolError, match="does not exist"):
        _tools(box)["compare_documents"].run({"path_a": str(a), "path_b": str(home["downloads"] / "nope.md")})


def test_duplicates_are_found_by_contents_not_name(box, home):
    docs = home["downloads"] / "photos"
    docs.mkdir()
    blob = b"\x01\x02\x03" * 2000
    other = b"\x09\x08\x07" * 2000
    (docs / "holiday.jpg").write_bytes(blob)
    (docs / "holiday copy.jpg").write_bytes(blob)
    (docs / "deep" / "keep").mkdir(parents=True)
    (docs / "deep" / "keep" / "same image.jpg").write_bytes(blob)
    (docs / "different.jpg").write_bytes(other)
    # same length, different bytes: must not be called a duplicate
    (docs / "sized-alike.jpg").write_bytes(b"\x02\x01\x03" * 2000)

    out = json.loads(_tools(box)["find_duplicate_files"].run({"folder": str(docs), "min_size_mb": 0}).text)
    assert out["duplicate_groups"] == 1 and out["files_checked"] == 5
    group = out["groups"][0]
    assert group["count"] == 3 and group["wasted"] == 2 * len(blob)
    assert len(group["paths"]) == 3 and "different.jpg" not in json.dumps(group)
    assert "Nothing was deleted" in out["note"]

    only = json.loads(_tools(box)["find_duplicate_files"].run(
        {"folder": str(docs), "min_size_mb": 0, "pattern": "*.jpg", "max_groups": 1}).text)
    assert only["groups"][0]["paths"] == group["paths"]

    # the big files are still on disk, untouched
    assert (docs / "holiday.jpg").read_bytes() == blob


def test_a_folder_of_only_unique_files_reports_nothing_to_clean(box, home):
    stuff = home["downloads"] / "stuff"
    stuff.mkdir()
    for i in range(4):
        (stuff / f"f{i}.bin").write_bytes(bytes([i]) * 5000)
    out = json.loads(_tools(box)["find_duplicate_files"].run({"folder": str(stuff), "min_size_mb": 0}).text)
    assert out["duplicate_groups"] == 0 and out["groups"] == [] and out["wasted_bytes"] == 0
    with pytest.raises(ToolError, match="not a folder"):
        _tools(box)["find_duplicate_files"].run({"folder": str(stuff / "f0.bin")})


def test_file_text_tools_are_labelled_as_data():
    assert {"compare_documents", "ask_my_files"} <= UNTRUSTED_TOOLS
