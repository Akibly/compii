"""Documents Compii writes: tidy Markdown, and real Word files with no extra dependencies.

Compii hands people things they open in Word and send to colleges, so the output has to look
made rather than dumped: styled headings, working lists, bordered tables with a shaded header
row, clickable links. All of it is written straight as Office Open XML with the standard
library, so there is nothing to install and nothing to go wrong at build time.
"""

from __future__ import annotations

import re
import zipfile
from datetime import datetime
from io import BytesIO
from xml.sax.saxutils import escape

_W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

_ACCENT = "1F3864"       # headings and table headers: a print-safe dark blue
_HEADER_FILL = "DCE6F1"  # table header row
_BORDER = "BFBFBF"

# ---------------------------------------------------------------- Markdown clean-up

_HEADING = re.compile(r"^(#{1,6})(\s*)(.*)$")
_RULE = re.compile(r"^\s*([-*_])\s*(?:\1\s*){2,}$")
_LIST_ITEM = re.compile(r"^(\s*)(?:([-*+])|(\d+)[.)])\s+(.*)$")
_PARA_BREAK = re.compile(r"^(#{1,6}\s|```|>|\||\s*[-*+]\s|\s*\d+[.)]\s|\s*$)")


def tidy_markdown(text: str) -> str:
    """Make hand-written Markdown consistent, so it reads well raw and converts cleanly.

    Spacing around headings, rules and tables, one kind of bullet, "setext" headings (a line
    underlined with === or ---) turned into real ones, lined-up table rows, no trailing
    blanks, no doubled blank lines, and unclosed ``**`` dropped - one of them prints as two
    stars instead of bold.
    """
    lines = text.replace("\r\n", "\n").replace("\r", "\n").expandtabs(4).split("\n")
    out: list[str] = []
    i = 0
    in_code = False
    while i < len(lines):
        line = lines[i].rstrip()
        if line.lstrip().startswith("```"):
            if not in_code:
                _blank(out)
            in_code = not in_code
            out.append("```")
            i += 1
            continue
        if in_code:
            out.append(line)
            i += 1
            continue
        if not line.strip():
            _blank(out)
            i += 1
            continue
        nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
        underline = len(nxt) >= 3 and not set(nxt) - set("=-") and line.strip() and not line.startswith("|")
        if _HEADING.match(line):
            hashes, body = _HEADING.match(line).group(1), _HEADING.match(line).group(3).strip()
            _blank(out)
            out.append(f"{hashes} {body or nxt}")
            out.append("")
            i += 2 if not body else 1
            continue
        if underline and nxt[0] == "=":
            _blank(out)
            out.append(f"# {line.strip()}")
            out.append("")
            i += 2
            continue
        if underline and nxt[0] == "-" and not _LIST_ITEM.match(line):
            _blank(out)
            out.append(f"## {line.strip()}")
            out.append("")
            i += 2
            continue
        if _RULE.match(line):
            _blank(out)
            out.extend(["---", ""])
            i += 1
            continue
        if line.startswith("|"):
            if out and _LIST_ITEM.match(out[-1]):
                out.append("")
            out.append(_table_row(line))
            i += 1
            continue
        item = _LIST_ITEM.match(line)
        if item:
            out.append(f"{item.group(1)}{item.group(3) + '.' if item.group(3) else '-'} {item.group(4)}")
            i += 1
            continue
        # A paragraph written straight under a list would read as part of the last item.
        if out and _LIST_ITEM.match(out[-1]) and not _indent(line):
            out.append("")
        out.append(_fix_emphasis(line))
        i += 1
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out) + "\n" if out else ""


def _table_row(line: str) -> str:
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if all(c and not set(c) - set(":- ") for c in cells):  # the |:---|:--:| separator row
        return "| " + " | ".join(["---"] * len(cells)) + " |"
    return "| " + " | ".join(cells) + " |"


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _blank(out: list[str]) -> None:
    """End the block that is open with exactly one blank line."""
    if out and out[-1] != "":
        out.append("")


def _fix_emphasis(line: str) -> str:
    return line.replace("**", "") if line.count("**") % 2 else line


def docx_text(path) -> str:
    """Read a .docx back as Markdown, so Compii can check what it wrote or quote a letter.

    Uses the XML inside the package rather than a Word install, so it works headless.
    """
    import xml.etree.ElementTree as ET
    from pathlib import Path

    with zipfile.ZipFile(Path(path)) as z:
        root = ET.fromstring(z.read("word/document.xml"))
    body = root.find(f"{{{_W}}}body")
    lines: list[str] = []
    if body is None:
        return ""

    def para(el) -> str:
        text = ""
        for node in el.iter():
            tag = node.tag.split("}")[-1]
            if tag == "t":
                text += node.text or ""
            elif tag == "br":
                text += "\n"
        style = el.find(f"{{{_W}}}pPr/{{{_W}}}pStyle")
        val = style.get(f"{{{_W}}}val", "") if style is not None else ""
        if val.startswith("Heading"):
            return "#" * min(int(val[7:] or 1), 4) + " " + text
        if val == "Title":
            return "# " + text
        if val == "Quote":
            return "> " + text
        num = el.find(f"{{{_W}}}pPr/{{{_W}}}numPr/{{{_W}}}numId")
        if num is not None and num.get(f"{{{_W}}}val") == "1":
            return "- " + text
        return text

    for child in body:
        tag = child.tag.split("}")[-1]
        if tag == "p":
            lines.append(para(child))
        elif tag == "tbl":
            for tr in child.findall(f"{{{_W}}}tr"):
                cells = [para(tc.find(f"{{{_W}}}p")) if tc.find(f"{{{_W}}}p") is not None else ""
                         for tc in tr.findall(f"{{{_W}}}tc")]
                lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines).strip() + "\n"


# ---------------------------------------------------------------- Spreadsheets


def style_worksheet(ws) -> None:
    """Make an Excel sheet read as made, not dumped: a solid header, no wrapped-off columns,
    the labels frozen at the top and a filter on the first row."""
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

    head_fill = PatternFill("solid", fgColor=_ACCENT)
    bottom = Side(style="thin", color=_BORDER)
    for cell in ws[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = head_fill
        cell.alignment = Alignment(vertical="center", wrap_text=True)
        cell.border = Border(bottom=bottom)
    ws.row_dimensions[1].height = 22
    for col in ws.columns:
        width = max(len(str(c.value or "")) for c in col)
        ws.column_dimensions[col[0].column_letter].width = min(max(10, width + 2), 60)
    if ws.max_row > 1:
        ws.auto_filter.ref = ws.dimensions
    ws.freeze_panes = "A2"


# ---------------------------------------------------------------- Markdown -> Word

def docx_bytes(markdown: str, title: str | None = None) -> bytes:
    """Render Markdown as the bytes of a .docx. Markup that isn't recognised stays as text."""
    rels: dict[str, str] = {}
    blocks: list[str] = []
    lines = tidy_markdown(markdown).split("\n")
    heading_seen = any(_HEADING.match(l) for l in lines)
    doc_title = (title or "").strip()
    if doc_title and not heading_seen:
        blocks.append(_para(_run(doc_title, {"b": True}), style="Title"))
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.lstrip().startswith("```"):
            code, i = [], i + 1
            while i < len(lines) and not lines[i].lstrip().startswith("```"):
                code.append(lines[i])
                i += 1
            for row in code:
                blocks.append(_para(_run(row or " ", {"mono": True}),
                                    extra='<w:shd w:val="clear" w:fill="F5F5F5"/>'
                                          '<w:spacing w:before="0" w:after="20" w:line="240" w:lineRule="auto"/>'
                                          '<w:ind w:left="284"/>'))
            i += 1
            continue
        m = _HEADING.match(line)
        if m:
            level = min(len(m.group(1)), 4)
            blocks.append(_para(_runs(m.group(3), rels), style=f"Heading{level}"))
            i += 1
            continue
        if line.startswith(">"):
            blocks.append(_para(_runs(line.lstrip("> ").strip(), rels), style="Quote"))
            i += 1
            continue
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|$", lines[i + 1].strip()):
            rows, i = [], i
            while i < len(lines) and lines[i].startswith("|"):
                raw = lines[i].strip().strip("|")
                if not re.match(r"^[\s:|-]+$", raw):  # skip the |:---|:---| separator row
                    rows.append([c.strip() for c in raw.split("|")])
                i += 1
            blocks.append(_table(rows, rels))
            continue
        item = _LIST_ITEM.match(line)
        if item:
            depth = min(_indent(line) // 2, 2)
            rest = item.group(4)
            box = re.match(r"^\[([ xX])\]\s*(.*)$", rest)
            if box:
                rest = ("☐ " if box.group(1) == " " else "☑ ") + box.group(2)
            blocks.append(_para(_runs(rest, rels), extra=(
                f'<w:numPr><w:ilvl w:val="{depth}"/><w:numId w:val="{2 if item.group(3) else 1}"/></w:numPr>')))
            i += 1
            continue
        para, i = [], i
        while i < len(lines) and lines[i].strip() and not _PARA_BREAK.match(lines[i]):
            para.append(lines[i].strip())
            i += 1
        # Lines the model wrote one under the other (an address, a signature) stay one under
        # the other in Word instead of running into a single sentence.
        blocks.append(_para(_runs("\n".join(para), rels)))
    body = "".join(blocks) or _para(_run(" ", {}))
    now = datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ")
    hyperlinks = "".join(
        f'<Relationship Id="{rid}" Type="{_REL}/hyperlink" Target="{escape(url, {chr(34): "&quot;"})}" '
        f'TargetMode="External"/' + ">"
        for rid, url in rels.items()
    )
    parts = {
        "[Content_Types].xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/word/document.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            '<Override PartName="/word/styles.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
            '<Override PartName="/word/numbering.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
            '<Override PartName="/docProps/core.xml" '
            'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
            "</Types>"
        ),
        "_rels/.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{_REL}/officeDocument" Target="word/document.xml"/>'
            '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships'
            '/metadata/core-properties" Target="docProps/core.xml"/>'
            "</Relationships>"
        ),
        "word/_rels/document.xml.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="r1" Type="{_REL}/styles" Target="styles.xml"/>'
            f'<Relationship Id="r2" Type="{_REL}/numbering" Target="numbering.xml"/>'
            f"{hyperlinks}</Relationships>"
        ),
        "word/document.xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<w:document xmlns:w="{_W}" xmlns:r="{_REL}"><w:body>{body}'
            '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
            '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" '
            'w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>'
            "</w:body></w:document>"
        ),
        "word/styles.xml": _STYLES,
        "word/numbering.xml": _NUMBERING,
        "docProps/core.xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<cp:coreProperties '
            'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            f"<dc:title>{escape(doc_title or _first_heading(markdown))}</dc:title>"
            "<dc:creator>Compii</dc:creator>"
            "<cp:lastModifiedBy>Compii</cp:lastModifiedBy>"
            f"<dcterms:created xsi:type=\"dcterms:W3CDTF\">{now}</dcterms:created>"
            f"<dcterms:modified xsi:type=\"dcterms:W3CDTF\">{now}</dcterms:modified>"
            "</cp:coreProperties>"
        ),
    }
    buf = BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, xml in parts.items():
            z.writestr(name, xml)
    return buf.getvalue()


def _first_heading(markdown: str) -> str:
    for line in markdown.splitlines():
        m = _HEADING.match(line.strip())
        if m:
            return m.group(3)
    return "Document"


def _run(text: str, style: dict) -> str:
    """One styled piece of text; a newline in it is a line break the document keeps."""
    props = []
    if style.get("b"):
        props.append("<w:b/>")
    if style.get("i"):
        props.append("<w:i/>")
    if style.get("mono"):
        props.append('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="20"/>')
    rpr = f"<w:rPr>{''.join(props)}</w:rPr>" if props else ""
    pieces = text.split("\n")
    body = '<w:r><w:br/></w:r>'.join(
        f'<w:r>{rpr}<w:t xml:space="preserve">{escape(piece)}</w:t></w:r>' for piece in pieces)
    return body or f"<w:r>{rpr}</w:r>"


def _para(runs: str, *, style: str | None = None, extra: str = "") -> str:
    bits = [f'<w:pStyle w:val="{style}"/>' if style else ""] + ([extra] if extra else [])
    ppr = f"<w:pPr>{''.join(bits)}</w:pPr>" if any(bits) else ""
    return f"<w:p>{ppr}{runs}</w:p>"


_EMPHASIS = re.compile(r"(\*\*.+?\*\*|__.+?__|\*[^*\s][^*]*?\*|_[^_\s][^_]*?_|`[^`]+?`)")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")


def _runs(text: str, rels: dict[str, str], *, bold: bool = False) -> str:
    """One line of Markdown as the ``<w:r>`` elements it needs: bold, italic, code, links."""
    out: list[str] = []
    for piece in re.split(r"(\[[^\]\n]+\]\([^)\s]+\))", text):
        if not piece:
            continue
        link = _LINK.fullmatch(piece)
        if link:
            rid = f"r{len(rels) + 3}"
            rels[rid] = link.group(2)
            out.append(f'<w:hyperlink r:id="{rid}"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr>'
                       f'<w:t xml:space="preserve">{escape(link.group(1))}</w:t></w:r></w:hyperlink>')
            continue
        for bit in _EMPHASIS.split(piece):
            if not bit:
                continue
            style = {"b": bold}
            body = bit
            if (bit.startswith("**") and bit.endswith("**")) or (bit.startswith("__") and bit.endswith("__")):
                style, body = {"b": True}, bit[2:-2]
            elif len(bit) > 2 and bit[0] in "*_" and bit[-1] == bit[0]:
                style, body = {"b": bold, "i": True}, bit[1:-1]
            elif bit.startswith("`") and bit.endswith("`") and len(bit) > 2:
                style, body = {"mono": True}, bit[1:-1]
            if body:
                out.append(_run(body, style))
    return "".join(out) or _run("", {})


def _table(rows: list[list[str]], rels: dict[str, str]) -> str:
    cols = max(len(r) for r in rows)
    width = max(9026 // cols, 600)
    edges = "".join(f'<w:{side} w:val="single" w:sz="4" w:space="0" w:color="{_BORDER}"/>'
                    for side in ("top", "left", "bottom", "right", "insideH", "insideV"))
    grid = "".join(f'<w:gridCol w:w="{width}"/>' for _ in range(cols))
    out = []
    for n, row in enumerate(rows):
        header = n == 0
        cells = []
        for cell in row:
            shading = f'<w:shd w:val="clear" w:fill="{_HEADER_FILL}"/>' if header else ""
            runs = _run(re.sub(r"\*\*|__|`", "", cell), {"b": True}) if header else _runs(cell, rels)
            cells.append(f'<w:tc><w:tcPr><w:tcW w:w="{width}" w:type="dxa"/>{shading}'
                         f'<w:vAlign w:val="center"/></w:tcPr>{_para(runs)}</w:tc>')
        trpr = "<w:trPr><w:tblHeader/></w:trPr>" if header else ""
        out.append(f"<w:tr>{trpr}{''.join(cells)}</w:tr>")
    # A table is never left standing alone: Word wants a paragraph after it.
    return (f'<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>'
            f"<w:tblBorders>{edges}</w:tblBorders>"
            '<w:tblCellMar><w:left w:w="85" w:type="dxa"/><w:right w:w="85" w:type="dxa"/></w:tblCellMar>'
            '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0"/></w:tblPr>'
            f"<w:tblGrid>{grid}</w:tblGrid>{''.join(out)}</w:tbl><w:p/>")


def _style(size: int, before: int, after: int, level: int) -> str:
    return (f'<w:style w:type="paragraph" w:styleId="Heading{level + 1}"><w:name w:val="heading {level + 1}"/>'
            '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>'
            f'<w:pPr><w:keepNext/><w:spacing w:before="{before}" w:after="{after}"/>'
            f'<w:outlineLvl w:val="{level}"/></w:pPr>'
            f'<w:rPr><w:b/><w:color w:val="{_ACCENT}"/><w:sz w:val="{size}"/></w:rPr></w:style>')


def _bullet_level(n: int, char: str) -> str:
    return (f'<w:lvl w:ilvl="{n}"><w:start w:val="1"/><w:numFmt w:val="bullet"/>'
            f'<w:lvlText w:val="{char}"/><w:lvlJc w:val="left"/>'
            f'<w:pPr><w:ind w:left="{720 + 720 * n}" w:hanging="360"/></w:pPr>'
            '<w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/></w:rPr></w:lvl>')


def _number_level(n: int) -> str:
    return (f'<w:lvl w:ilvl="{n}"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
            f'<w:lvlText w:val="%{n + 1}."/><w:lvlJc w:val="left"/>'
            f'<w:pPr><w:ind w:left="{720 + 720 * n}" w:hanging="360"/></w:pPr></w:lvl>')


_STYLES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    f'<w:styles xmlns:w="{_W}">'
    "<w:docDefaults><w:rPrDefault><w:rPr>"
    '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>'
    '<w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-GB"/></w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
    "</w:docDefaults>"
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
    '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>'
    '<w:next w:val="Normal"/><w:uiPriority w:val="10"/><w:qFormat/>'
    '<w:pPr><w:spacing w:after="240"/><w:outlineLvl w:val="0"/></w:pPr>'
    f'<w:rPr><w:b/><w:color w:val="{_ACCENT}"/><w:sz w:val="48"/></w:rPr></w:style>'
    + _style(32, 320, 120, 0)
    + _style(26, 260, 100, 1)
    + _style(24, 220, 80, 2)
    + _style(22, 200, 60, 3)
    + '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>'
      '<w:next w:val="Normal"/><w:uiPriority w:val="1"/><w:qFormat/>'
      '<w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="10" w:color="8EAADB"/></w:pBdr>'
      '<w:spacing w:before="120" w:after="120"/><w:ind w:left="340"/></w:pPr>'
      '<w:rPr><w:i/><w:color w:val="404040"/></w:rPr></w:style>'
      '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:uiPriority w:val="99"/>'
      '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>'
      "</w:styles>"
)

_NUMBERING = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    f'<w:numbering xmlns:w="{_W}">'
    '<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>'
    + _bullet_level(0, "•") + _bullet_level(1, "○") + _bullet_level(2, "▪")
    + "</w:abstractNum>"
    '<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>'
    + _number_level(0) + _number_level(1) + _number_level(2)
    + "</w:abstractNum>"
    '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
    '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>'
    "</w:numbering>"
)
