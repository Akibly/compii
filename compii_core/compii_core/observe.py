"""One honest look at the user's screen.

Controls first (exact labels, values and actions), then a picture of the window read
with the OCR engine Windows already has. Both are local. A vision model, when the user
has a key, is an extra layer on top — never the only way to see.

The snapshot this returns is the same shape `screen.snapshot_foreground` makes, with
OCR lines added as t1, t2… items in screen pixels, so pointing and clicking can use
them like any other item.
"""

from __future__ import annotations

import re
from typing import Any

# Explicit references to what is in front of the user. Deliberately narrower than
# buddy.SCREEN_WORDS: "open Notepad" should not cost a screen capture; "what's this?"
# and "read this page" should.
_REFERS = re.compile(
    r"("
    r"\bwhat(?:'s| is) (?:this|that|on my screen|on the screen)\b|"
    r"\bwhat am i looking at\b|"
    r"\b(?:can|could) you see\b|\bdo you see\b|"
    r"\blook at (?:this|my screen|the screen|this window|this page|this app)\b|"
    r"\b(?:on|at) (?:my|the) screen\b|"
    r"\b(?:this|the current) (?:screen|window|page|tab|app|button|menu|error|dialog|pop-?up|field|box|link|"
    r"image|picture|chart|spreadsheet|document|email|code|text|line|file|folder)\b|"
    r"\bthat (?:screen|window|page|tab|app|button|menu|error|dialog|pop-?up|field|box|link|image|picture|chart)\b|"
    r"\bread (?:this|the screen|my screen|the window|this page)\b|"
    r"\bwhat does (?:this|the screen|this page) (?:say|mean)\b|"
    r"\bwhere (?:is|are) (?:it|this|that|the (?:[\w-]+ )?(?:button|menu|tab|option|setting|field|thing|item|link|"
    r"icon|panel|window|error))\b|"
    r"\bwhere (?:do i|should i|can i) (?:click|find|go|type|look)\b|"
    r"\bsummari[sz]e (?:this|the screen|this page)\b|"
    r"\btranslate (?:this|the screen|this page)\b|"
    r"\bhelp me (?:with|on) (?:this|the screen)\b"
    r")",
    re.I,
)


def refers_to_screen(text: str) -> bool:
    return bool(_REFERS.search(text or ""))


def observe(question: str = "", *, picture: bool = True) -> dict[str, Any] | None:
    """The window in front, with its controls and the words a local OCR pass can read.

    Returns None when only Compii's own windows are in front. Never raises: screen
    awareness is best effort, and the labels alone are still a useful answer.
    """
    from concurrent.futures import ThreadPoolExecutor

    from . import screen, vision

    # The privacy check comes before any pixels are taken, and the picture itself is quick:
    # reading its words then runs alongside the slower walk of the app's controls.
    take = picture and not vision.blocked_foreground()
    shot = None
    if take:
        try:
            shot = vision.grab_foreground()
        except Exception:  # noqa: BLE001 - a picture that fails is no picture
            shot = None

    def controls() -> dict[str, Any] | None:
        try:
            return screen.snapshot_foreground()
        except Exception:  # noqa: BLE001 - no screen is better than a broken turn
            return None

    def words() -> dict[str, Any] | None:
        if shot is None:
            return None
        try:
            from .ocr import read_png_boxes

            return read_png_boxes(vision.ocr_png(shot[0]))
        except Exception:  # noqa: BLE001 - the controls are still there
            return None

    with ThreadPoolExecutor(max_workers=2) as pool:
        snap_job, words_job = pool.submit(controls), pool.submit(words)
        snap, boxes = snap_job.result(), words_job.result()
    if not snap or snap.get("blocked") or not boxes:
        return snap
    return vision.merge_ocr(snap, boxes, shot[1], max_items=90)


def read_window_words(window: str = "") -> str:
    """The visible words in a window (or the one in front), read locally with Windows OCR.

    For apps whose accessibility tree says almost nothing (Electron, canvas, games).
    Returns "" when there is nothing to read or the window is private.
    """
    from . import ocr, screen, vision

    try:
        if window:
            hwnd, title = screen.find_window(window)
            if not hwnd or screen.private_window(hwnd, title):
                return ""
            shot = vision.grab_foreground(hwnd)
        else:
            shot = vision.grab_foreground()
        if shot is None:
            return ""
        boxes = ocr.read_png_boxes(vision.ocr_png(shot[0]))
    except Exception:  # noqa: BLE001 - a picture that fails is simply no words
        return ""
    lines: list[str] = []
    for line in (boxes or {}).get("lines", []):
        text = " ".join(str(line.get("text") or "").split())
        if text and (not lines or lines[-1] != text):
            lines.append(text)
    return "\n".join(lines)[:6000]
