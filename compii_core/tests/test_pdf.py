"""PDFs: join, take pages out, read honestly page by page, and fill a form into a copy."""

from pathlib import Path

import pytest
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject, DictionaryObject, NameObject, NumberObject, TextStringObject

from compii_core.tools import ToolError, Toolbox


@pytest.fixture
def home(tmp_path: Path) -> dict[str, Path]:
    downloads = tmp_path / "Downloads"
    downloads.mkdir()
    return {"downloads": downloads, "workspace": tmp_path / "Compii"}


@pytest.fixture
def toolbox(home) -> Toolbox:
    return Toolbox([home["downloads"]], home["workspace"], lambda s: None)


def _blank_pdf(path: Path, pages: int = 1) -> Path:
    writer = PdfWriter()
    for _ in range(pages):
        writer.add_blank_page(width=300, height=300)
    with path.open("wb") as f:
        writer.write(f)
    return path


def _form_pdf(path: Path) -> Path:
    writer = PdfWriter()
    page = writer.add_blank_page(width=300, height=300)
    field = DictionaryObject({
        NameObject("/FT"): NameObject("/Tx"),
        NameObject("/T"): TextStringObject("full_name"),
        NameObject("/Type"): NameObject("/Annot"),
        NameObject("/Subtype"): NameObject("/Widget"),
        NameObject("/Rect"): ArrayObject([NumberObject(50), NumberObject(50), NumberObject(250), NumberObject(80)]),
        NameObject("/F"): NumberObject(4),
    })
    ref = writer._add_object(field)
    page[NameObject("/Annots")] = ArrayObject([ref])
    writer._root_object[NameObject("/AcroForm")] = writer._add_object(
        DictionaryObject({NameObject("/Fields"): ArrayObject([ref])}))
    with path.open("wb") as f:
        writer.write(f)
    return path


def test_merging_joins_every_page_in_the_order_given(toolbox, home):
    a = _blank_pdf(home["downloads"] / "a.pdf", 2)
    b = _blank_pdf(home["downloads"] / "b.pdf", 3)
    res = toolbox.execute("merge_pdfs", {"inputs": [str(a), str(b)], "destination": "all.pdf"})
    out = home["workspace"] / "all.pdf"
    assert len(PdfReader(out).pages) == 5
    assert (str(out), "created") in res.files
    assert "5 pages" in res.text


def test_merging_wont_overwrite_and_needs_two_files(toolbox, home):
    a = _blank_pdf(home["downloads"] / "a.pdf")
    with pytest.raises(ToolError, match="at least two"):
        toolbox.execute("merge_pdfs", {"inputs": [str(a)], "destination": "one.pdf"})
    toolbox.execute("merge_pdfs", {"inputs": [str(a), str(a)], "destination": "x.pdf"})
    with pytest.raises(ToolError, match="already exists"):
        toolbox.execute("merge_pdfs", {"inputs": [str(a), str(a)], "destination": "x.pdf"})


def test_a_page_range_copies_only_those_pages_and_leaves_the_original(toolbox, home):
    src = _blank_pdf(home["downloads"] / "letter.pdf", 4)
    before = src.read_bytes()
    res = toolbox.execute("split_pdf", {"pdf": str(src), "pages": "2-3", "destination": "two.pdf"})
    out = home["workspace"] / "two.pdf"
    assert len(PdfReader(out).pages) == 2
    assert "pages 2-3" in res.text
    assert src.read_bytes() == before, "splitting must never touch the original"


def test_without_a_range_every_page_becomes_its_own_file(toolbox, home):
    src = _blank_pdf(home["downloads"] / "scan.pdf", 3)
    toolbox.execute("split_pdf", {"pdf": str(src), "destination": "pages"})
    made = sorted((home["workspace"] / "pages").glob("*.pdf"))
    assert [p.name for p in made] == ["scan - page 1.pdf", "scan - page 2.pdf", "scan - page 3.pdf"]
    assert all(len(PdfReader(p).pages) == 1 for p in made)


def test_a_page_outside_the_document_is_said_plainly(toolbox, home):
    src = _blank_pdf(home["downloads"] / "a.pdf", 2)
    with pytest.raises(ToolError, match="outside this PDF, which has 2 page"):
        toolbox.execute("split_pdf", {"pdf": str(src), "pages": "5"})


def test_reading_reports_a_blank_page_as_a_scan_not_as_text(toolbox, home):
    src = _blank_pdf(home["downloads"] / "scan.pdf", 2)
    text = toolbox.execute("read_pdf", {"pdf": str(src)}).text
    assert "2 page(s)" in text and "--- page 1 ---" in text and "--- page 2 ---" in text
    assert text.count("may be a scan") == 2


def test_reading_lists_the_form_fields_so_nothing_is_guessed(toolbox, home):
    src = _form_pdf(home["downloads"] / "form.pdf")
    text = toolbox.execute("read_pdf", {"pdf": str(src)}).text
    assert "full_name (text)" in text


def test_filling_writes_a_copy_and_the_original_stays_empty(toolbox, home):
    src = _form_pdf(home["downloads"] / "form.pdf")
    res = toolbox.execute("fill_pdf_form", {"pdf": str(src), "fields": {"full_name": "Amara Okafor"}})
    filled = home["downloads"] / "form - filled.pdf"
    assert filled.is_file() and (str(filled), "created") in res.files
    assert PdfReader(filled).get_fields()["full_name"]["/V"] == "Amara Okafor"
    assert "/V" not in PdfReader(src).get_fields()["full_name"], "the original is never changed"


def test_a_misspelt_field_fills_nothing_and_says_what_exists(toolbox, home):
    src = _form_pdf(home["downloads"] / "form.pdf")
    with pytest.raises(ToolError, match="no field named 'name'") as e:
        toolbox.execute("fill_pdf_form", {"pdf": str(src), "fields": {"name": "Amara"}})
    assert "full_name (text)" in str(e.value)
    assert not (home["downloads"] / "form - filled.pdf").exists()


def test_a_form_never_gets_passwords_or_card_numbers(toolbox, home):
    src = _form_pdf(home["downloads"] / "form.pdf")
    with pytest.raises(ToolError, match="password"):
        toolbox.execute("fill_pdf_form", {"pdf": str(src), "fields": {"password": "hunter2"}})
