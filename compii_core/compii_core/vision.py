"""Seeing apps that don't describe themselves (Blender, games, design tools, video).

Most Windows apps list their buttons and labels for screen readers, and Compii reads
those. Some draw everything themselves, so that list is nearly empty. Then, and only
when you ask about the screen, Compii takes a picture of the window you're in (never
password managers) and asks a free vision model what's relevant and where it is.
Those spots become items Compii can point at, circle and teach with.
"""

from __future__ import annotations

import base64
import functools
import json
import re
import struct
import sys
import zlib
from typing import Any

import numpy as np

VISION_URL = "https://integrate.api.nvidia.com/v1/chat/completions"
VISION_MODEL = "nvidia/nemotron-3.5-super-vl-120b-a12b"  # free; points within ~15 px in tests
MAX_WIDTH = 1600
# Windows OCR cannot read small UI text once a picture is scaled down: at 1600 px wide a
# 1936 px window came back with zero lines, and 66 lines at its real size. OCR gets its own,
# much larger cap; the vision model keeps the small one for a fast, readable payload.
OCR_MAX_WIDTH = 4096
# A window that lists fewer readable items than this is mostly drawn pixels: look at it.
THIN = 15
# Apps known to draw their own interface.
DRAWN_APPS = ("blender", "unity", "unreal", "godot", "krita", "gimp", "figma", "photoshop", "illustrator", "davinci",
              "resolve", "premiere", "afterfx", "obs", "steam", "minecraft", "javaw", "fusion360", "sketchup", "zbrush",
              "filmora", "wondershare", "capcut", "canva", "audacity", "fl studio", "ableton")


BROWSERS = ("brave", "chrome", "msedge", "microsoft edge", "firefox", "opera", "vivaldi", "arc")
# The browser's own frame: what a Chromium window reports when it keeps the page to itself.
_FRAME = re.compile(r"^(?:minimi[sz]e|maximi[sz]e|restore|close|back|forward|reload|refresh|home|new tab|"
                    r"address and search bar|search tabs|extensions|bookmarks?|downloads|side ?panel|"
                    r"customi[sz]e and control.*|view site information|untitled\b.*|.*\bchrome legacy window)$", re.I)
_FRAME_ROLES = {"button", "tabitem", "tab", "pane", "titlebar", "menubar", "toolbar", "window", "group", "menuitem"}


def _page_items(elements: list[dict[str, Any]]) -> int:
    """How many things a browser reported from the page itself, not its frame."""
    return sum(1 for e in elements
               if str(e.get("role", "")).replace(" ", "").lower() not in _FRAME_ROLES
               and not _FRAME.match(str(e.get("name", "")).strip()))


def needs_picture(snap: dict[str, Any] | None) -> bool:
    if not snap or snap.get("blocked"):
        return False
    app = f"{snap.get('app', '')} {snap.get('title', '')}".lower()
    elements = snap.get("elements", [])
    # Chromium browsers don't hand their pages to UI Automation unless a screen reader asks, so
    # a Brave window read as 57 items was all frame: Minimize, tabs, the address bar. Counting
    # every item called that "readable" and the page went unseen.
    if any(b in app for b in BROWSERS) and _page_items(elements) < THIN:
        return True
    return len(elements) < THIN or any(a in app for a in DRAWN_APPS) or _mostly_code_names(elements)


def _mostly_code_names(elements: list[dict[str, Any]]) -> bool:
    """Apps that label their buttons with internal names ("Tab_Effect", "FFPlayerToolBarBase")
    are as good as unlabelled: what you see isn't what they report."""
    names = [e.get("name", "") for e in elements if e.get("name")]
    if len(names) < 8:
        return False
    code = sum(1 for n in names if " " not in n and ("_" in n or re.search(r"[a-z][A-Z]", n) or n.endswith(("Base", "Widget"))))
    return code / len(names) > .3


def blocked_foreground() -> bool:
    """Password managers and the like are never captured, and neither is an empty desktop."""
    if sys.platform != "win32":
        return True
    from .screen import user_foreground

    return not user_foreground()[0] or private_foreground()


def private_foreground() -> bool:
    """A password manager or similar is what Compii would be looking at."""
    if sys.platform != "win32":
        return False
    from .screen import private_window, user_foreground

    hwnd, title = user_foreground()
    return bool(hwnd) and private_window(hwnd, title)


def _ask(png: bytes, prompt: str, key: str, transport: Any = None, max_tokens: int = 900, timeout: float = 8,
         mime: str = "image/png") -> str:
    import httpx

    body = {
        "model": VISION_MODEL, "max_tokens": max_tokens, "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64," + base64.b64encode(png).decode()}},
        ]}],
    }
    with httpx.Client(timeout=timeout, transport=transport) as c:  # never stall Compii
        for _attempt in range(2):  # the free endpoint sometimes hiccups with a 500
            r = c.post(VISION_URL, json=body, headers={"Authorization": f"Bearer {key}"})
            if r.status_code < 500:
                break
    r.raise_for_status()
    return r.json()["choices"][0]["message"].get("content") or ""


def _json(text: str) -> dict[str, Any]:
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return {}
    try:
        return json.loads(re.sub(r",\s*([}\]])", r"\1", m.group(0)))
    except ValueError:
        return {}


def locate(png: bytes, window: tuple[int, int, int, int], target: str, key: str,
           transport: Any = None) -> dict[str, Any] | None:
    """Where `target` is in the picture, as a box in screen pixels, or None if it isn't visible."""
    data = _json(_ask(png, (
        f"Find \"{target}\" in this app window (a button, menu, tab, panel, field or object; match by meaning if "
        "the exact words differ). Reply only with JSON: {\"found\": true/false, \"label\": \"what it says\", "
        "\"x\": centre x, \"y\": centre y, \"w\": width, \"h\": height}, all on a 0-1000 grid of the image."),
        key, transport, max_tokens=300))
    if not data.get("found"):
        return None
    left, top, w, h = window
    try:
        cx, cy = float(data["x"]) / 1000 * w + left, float(data["y"]) / 1000 * h + top
        bw = max(24.0, float(data.get("w") or 40) / 1000 * w)
        bh = max(18.0, float(data.get("h") or 30) / 1000 * h)
    except (KeyError, TypeError, ValueError):
        return None
    return {"name": str(data.get("label") or target)[:80], "x": round(cx - bw / 2), "y": round(cy - bh / 2),
            "w": round(bw), "h": round(bh)}


def locate_precise(pixels: np.ndarray, window: tuple[int, int, int, int], target: str, key: str,
                   transport: Any = None) -> dict[str, Any] | None:
    """Find `target` coarsely in the whole window, then again in a zoomed-in crop around that
    first guess. Small icons in dense toolbars land within a few pixels instead of a few dozen."""
    left, top, w, h = window
    step = max(1, -(-pixels.shape[1] // MAX_WIDTH))
    first = locate(encode_png(np.ascontiguousarray(pixels[::step, ::step])), window, target, key, transport)
    if first is None:
        return None
    sx, sy = pixels.shape[1] / w, pixels.shape[0] / h  # screen px -> picture px (DPI can differ)
    cw = min(w, max(360, first["w"] * 4))
    ch = min(h, max(260, first["h"] * 5))
    if cw > w * .6 and ch > h * .6:
        return first  # the window is already small: zooming wouldn't show more
    cx, cy = first["x"] + first["w"] / 2 - left, first["y"] + first["h"] / 2 - top
    x0 = int(min(max(0, cx - cw / 2), w - cw))
    y0 = int(min(max(0, cy - ch / 2), h - ch))
    crop = pixels[int(y0 * sy):int((y0 + ch) * sy), int(x0 * sx):int((x0 + cw) * sx)]
    if crop.shape[1] < 640:
        crop = crop.repeat(2, axis=0).repeat(2, axis=1)
    try:
        second = locate(encode_png(np.ascontiguousarray(crop)), (left + x0, top + y0, int(cw), int(ch)),
                        target, key, transport)
    except Exception:  # noqa: BLE001 - the first guess is still good
        second = None
    return second or first


def read(png: bytes, question: str, key: str, transport: Any = None, window: str = "") -> dict[str, Any]:
    """Read the picture closely: an answer to the question, the important text exactly as
    shown, and up to 8 items with positions (0-1000 grid) to point at."""
    where = f" The picture is of the window “{window}”." if window else ""
    data = _json(_ask(png, (
        f"The user asks about this screen:{where} \"{question}\"\n"
        "Look carefully. Reply only with JSON: {\"answer\": \"a direct answer in one to four sentences, based only on "
        "what is visible\", \"text\": \"the important visible text copied exactly (headings, error messages, numbers, "
        "names, field values), one item per line, at most 40 lines\", \"items\": [{\"label\": \"...\", \"x\": 0, \"y\": 0, "
        "\"w\": 0, \"h\": 0}]} with up to 8 items that matter for the question, each centre and size on a 0-1000 "
        "grid of the image (0,0 top left). If something isn't visible, say so in the answer rather than guessing."),
        key, transport, max_tokens=1400, timeout=20))
    return {"summary": str(data.get("answer", ""))[:800], "text": str(data.get("text", ""))[:4000],
            "items": list(data.get("items") or [])[:8]}


PHOTO_TYPES = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff"}


def is_photo(path: Any) -> bool:
    from pathlib import Path

    return Path(str(path)).suffix.lower() in PHOTO_TYPES


def photo_pixels(path: Any) -> np.ndarray:
    """A photo as upright RGB pixels, at most OCR_MAX_WIDTH wide (phones save them sideways)."""
    from PIL import Image, ImageOps

    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        if im.width > OCR_MAX_WIDTH:
            im = im.resize((OCR_MAX_WIDTH, round(im.height * OCR_MAX_WIDTH / im.width)))
        return np.asarray(im)


def photo_jpeg(pixels: np.ndarray, max_side: int = MAX_WIDTH) -> bytes:
    """The photo for the vision model: a JPEG small enough to send quickly, sharp enough to read."""
    import io

    from PIL import Image

    im = Image.fromarray(pixels)
    im.thumbnail((max_side, max_side))
    out = io.BytesIO()
    im.save(out, "JPEG", quality=85)
    return out.getvalue()


def photo(jpeg: bytes, question: str, key: str, transport: Any = None) -> dict[str, Any]:
    """Look at a photo the user took or sent: answer the question, copy every word in it
    exactly (a document, a receipt, a sign) and say what kind of thing it is."""
    data = _json(_ask(jpeg, (
        f"The user took or sent this photo and asks: \"{question}\"\n"
        "Look carefully. Reply only with JSON: {\"kind\": \"one or two words: document, receipt, screen, sign, "
        "whiteboard, label, object, place, person, food, plant, animal, other\", \"answer\": \"a direct answer to the "
        "question in one to five sentences, based only on what is visible\", \"text\": \"every word in the photo "
        "copied exactly, in reading order, keeping line breaks, at most 120 lines; empty if there is none\"}. "
        "If something can't be made out, say so rather than guessing. Never identify a real person by name."),
        key, transport, max_tokens=2600, timeout=40, mime="image/jpeg"))
    return {"kind": str(data.get("kind", ""))[:40], "answer": str(data.get("answer", ""))[:1200],
            "text": str(data.get("text", ""))[:12000]}


def check(png: bytes, done_when: str, key: str, transport: Any = None) -> tuple[bool, str]:
    """Is the step done? True when the window now shows `done_when`."""
    data = _json(_ask(png, (
        "The user is following a lesson and was asked to do one step. The step is done when this is true: "
        f"\"{done_when}\". Look at this window. Is it true now? Be strict: only say yes when you can clearly see it. "
        "Reply only with JSON: {\"done\": true/false, \"why\": \"a few words\"}"), key, transport, max_tokens=200))
    return bool(data.get("done")), str(data.get("why", ""))[:160]


def png_of(pixels: np.ndarray, max_width: int = MAX_WIDTH) -> bytes:
    """Pixels as a PNG no wider than `max_width` — small enough to OCR or send quickly."""
    step = max(1, -(-pixels.shape[1] // max_width))
    return encode_png(np.ascontiguousarray(pixels[::step, ::step]))


def ocr_png(pixels: np.ndarray) -> bytes:
    """A picture for local OCR: as close to the real pixels as the engine can take."""
    return png_of(pixels, OCR_MAX_WIDTH)


def capture_foreground(hwnd: int | None = None) -> tuple[bytes, tuple[int, int, int, int]] | None:
    """A PNG of the foreground window (or `hwnd`), scaled to at most MAX_WIDTH wide, and the
    window's rectangle in screen pixels. Only that window is drawn, not what overlaps it."""
    shot = grab_foreground(hwnd)
    if shot is None:
        return None
    pixels, window = shot
    return png_of(pixels), window


def _gated(fn):
    """One picture of the screen: only while the user allows Compii to look, and the app's
    indicator is told it's happening (the same switch that stops the label reading).

    A picture that fails is simply no picture: every caller already has the labels to fall back
    on, and the user is told the truth instead of being handed a stack trace."""

    @functools.wraps(fn)
    def inner(*args: Any, **kw: Any) -> Any:
        from . import sight

        if not sight.enabled():
            return None
        try:
            with sight.look("picture"):
                return fn(*args, **kw)
        except Exception:
            return None

    return inner


@_gated
def grab_foreground(hwnd: int | None = None) -> tuple[np.ndarray, tuple[int, int, int, int]] | None:
    """The window the user is looking at: its pixels (RGB, full size) and its screen rectangle.

    Compii's own overlay is usually the real foreground, so asking Windows for it would
    picture the character instead of the work.
    """
    if sys.platform != "win32":
        return None
    import ctypes
    from ctypes import wintypes

    from .screen import user_foreground

    user32, _ = _win_gdi()
    hwnd = hwnd or user_foreground()[0]
    rect = wintypes.RECT()
    if not hwnd or not user32.IsWindowVisible(hwnd) or user32.IsIconic(hwnd) \
            or not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return None
    left, top = rect.left, rect.top
    w, h = rect.right - left, rect.bottom - top
    # A minimized window sits at -32000 with a stub rect; photographing it would hand the
    # vision model a black or blank white frame and it would describe the wrong thing.
    if left <= -30000 or top <= -30000 or w < 80 or h < 60:
        return None
    pixels = _grab_rect(left, top, w, h, hwnd)
    return None if pixels is None else (pixels, (left, top, w, h))


@_gated
def grab_screen() -> tuple[np.ndarray, tuple[int, int, int, int]] | None:
    """The whole desktop, every monitor together, as RGB pixels and its screen rectangle."""
    if sys.platform != "win32":
        return None
    user32, _ = _win_gdi()
    left, top = user32.GetSystemMetrics(76), user32.GetSystemMetrics(77)  # SM_X/YVIRTUALSCREEN
    w, h = user32.GetSystemMetrics(78), user32.GetSystemMetrics(79)  # SM_CX/CYVIRTUALSCREEN
    if w < 40 or h < 40:
        return None
    pixels = _grab_rect(left, top, w, h)
    return None if pixels is None else (pixels, (left, top, w, h))


_gdi: tuple[Any, Any] | None = None


def _win_gdi() -> tuple[Any, Any]:
    """user32 and gdi32 with their handle types spelled out. Left to ctypes' guess a device
    context is a signed 32-bit int, and Windows hands out GDI handles above 2^31: the capture
    that worked all morning then dies with 'int too long to convert'."""
    global _gdi
    if _gdi is None:
        import ctypes
        from ctypes import wintypes

        user32, gdi32 = ctypes.windll.user32, ctypes.windll.gdi32
        HDC, HBMP, HWND, INT, UINT = wintypes.HDC, wintypes.HBITMAP, wintypes.HWND, ctypes.c_int, wintypes.UINT
        for fn, restype, args in (
            (user32.GetSystemMetrics, INT, [INT]),
            (user32.GetWindowRect, INT, [HWND, ctypes.c_void_p]),
            (user32.IsWindowVisible, INT, [HWND]),
            (user32.IsIconic, INT, [HWND]),
            (user32.GetDC, HDC, [HWND]),
            (user32.ReleaseDC, INT, [HWND, HDC]),
            (user32.PrintWindow, INT, [HWND, HDC, UINT]),
            (gdi32.CreateDCW, HDC, [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR, ctypes.c_void_p]),
            (gdi32.CreateCompatibleDC, HDC, [HDC]),
            (gdi32.CreateCompatibleBitmap, HBMP, [HDC, INT, INT]),
            (gdi32.SelectObject, wintypes.HGDIOBJ, [HDC, wintypes.HGDIOBJ]),
            (gdi32.BitBlt, INT, [HDC, INT, INT, INT, INT, HDC, INT, INT, wintypes.DWORD]),
            (gdi32.GetDIBits, INT, [HDC, HBMP, UINT, UINT, ctypes.c_void_p, ctypes.c_void_p, UINT]),
            (gdi32.DeleteObject, INT, [wintypes.HGDIOBJ]),
            (gdi32.DeleteDC, INT, [HDC]),
        ):
            fn.restype, fn.argtypes = restype, args
        _gdi = (user32, gdi32)
    return _gdi


def _grab_rect(left: int, top: int, w: int, h: int, hwnd: int | None = None) -> np.ndarray | None:
    """Pixels of a screen rectangle. With `hwnd`, that window draws itself instead, so what
    overlaps it is not captured (this is what makes "look at this app" reliable)."""
    import ctypes
    from ctypes import wintypes

    user32, gdi32 = _win_gdi()

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                    ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                    ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
                    ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
                    ("biClrImportant", wintypes.DWORD)]

    def bits() -> np.ndarray | None:
        info = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
        buf = (ctypes.c_ubyte * (w * h * 4))()
        if not gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(info), 0):
            return None
        return np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 4)[:, :, 2::-1].copy()  # BGRA -> RGB

    # The desktop DC covers every monitor at its real coordinates, including monitors left of
    # or above the main one. GetDC(NULL) only reaches the primary display, so a window on a
    # second monitor used to come out blank or show a wrapped-around piece of the first.
    screen = gdi32.CreateDCW("DISPLAY", None, None, None)
    borrowed = not screen
    if borrowed:
        screen = user32.GetDC(None)
    mem = gdi32.CreateCompatibleDC(screen)
    bmp = gdi32.CreateCompatibleBitmap(screen, w, h)
    drawn = None
    try:
        if not screen or not mem or not bmp:
            return None
        drawn = gdi32.SelectObject(mem, bmp)
        # The window draws itself (works for modern GPU-drawn apps too); else copy the screen.
        from_window = bool(hwnd and user32.PrintWindow(hwnd, mem, 2))  # PW_RENDERFULLCONTENT
        if not from_window:
            if not gdi32.BitBlt(mem, 0, 0, w, h, screen, left, top, 0x00CC0020):  # SRCCOPY
                return None
        pixels = bits()
        if pixels is None:
            return None
        # Some GPU-drawn and suspended windows answer PrintWindow with a solid black or white
        # frame. Sending that to the vision model makes it describe another app or invent one.
        if from_window and _blank(pixels):
            # Copying the screen is only a picture of this window while nothing covers it;
            # behind another window it would be a picture of that other window.
            if not _on_top_at(user32, hwnd, left, top, w, h):
                return None
            if not gdi32.BitBlt(mem, 0, 0, w, h, screen, left, top, 0x00CC0020):
                return None
            pixels = bits()
            if pixels is None or _blank(pixels):
                return None
        return pixels
    finally:
        # Windows refuses to free a bitmap that is still selected into a DC, so putting the plain
        # one back is what stops every peek from leaking a screen-sized object.
        if drawn:
            gdi32.SelectObject(mem, drawn)
        if bmp:
            gdi32.DeleteObject(bmp)
        if mem:
            gdi32.DeleteDC(mem)
        if screen:
            if borrowed:
                user32.ReleaseDC(None, screen)
            else:
                gdi32.DeleteDC(screen)


def _blank(rgb: np.ndarray) -> bool:
    """A frame with no picture in it: all black, all white, or one flat colour."""
    step = max(1, max(rgb.shape[:2]) // 64)
    sample = rgb[::step, ::step]
    return int(sample.max()) - int(sample.min()) < 6


def _on_top_at(user32: Any, hwnd: int, left: int, top: int, w: int, h: int) -> bool:
    """True when `hwnd` is what the user can see at the middle of its rectangle."""
    import ctypes
    from ctypes import wintypes

    user32.WindowFromPoint.argtypes = [wintypes.POINT]
    user32.WindowFromPoint.restype = wintypes.HWND
    user32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
    user32.GetAncestor.restype = wintypes.HWND
    at = user32.WindowFromPoint(wintypes.POINT(left + w // 2, top + h // 2))
    return bool(at) and int(user32.GetAncestor(at, 2)) == int(hwnd)  # GA_ROOT


def encode_png(rgb: np.ndarray) -> bytes:
    """Minimal PNG encoder (no image library needed)."""
    h, w, _ = rgb.shape
    raw = np.hstack([np.zeros((h, 1), dtype=np.uint8), rgb.reshape(h, w * 3)]).tobytes()

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def look(png: bytes, question: str, key: str, transport: Any = None, window: str = "") -> dict[str, Any]:
    """Ask the vision model what's relevant to the question and where it is (0-1000 grid)."""
    import httpx

    called = f" “{window}”" if window else ""
    prompt = (
        f"The user is looking at this app window{called} and asks: \"{question}\"\n"
        "1) In one or two sentences, say what app and what state this is, focusing on what matters for the question.\n"
        "2) List up to 8 visible items the user may need, starting with the exact item that answers the question "
        "(the button, menu, panel, tool or object to look at or click), with each item's "
        "centre on a 0-1000 grid (0,0 top left, 1000,1000 bottom right) and its approximate width and height on the "
        "same grid.\nReply only with JSON: {\"summary\": \"...\", \"items\": [{\"label\": \"...\", \"x\": 0, \"y\": 0, "
        "\"w\": 0, \"h\": 0}]}"
    )
    body = {
        "model": VISION_MODEL, "max_tokens": 900, "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(png).decode()}},
        ]}],
    }
    with httpx.Client(timeout=8, transport=transport) as c:  # never stall Compii; labels are the fallback
        for attempt in range(2):  # the free endpoint sometimes hiccups with a 500
            r = c.post(VISION_URL, json=body, headers={"Authorization": f"Bearer {key}"})
            if r.status_code < 500:
                break
    r.raise_for_status()
    return parse_look(r.json()["choices"][0]["message"].get("content") or "")


def parse_look(text: str) -> dict[str, Any]:
    """The model's answer as {summary, items}; tolerant of code fences, trailing commas and cut-off replies."""
    m = re.search(r"\{.*\}", text, re.S)
    if m:
        try:
            data = json.loads(re.sub(r",\s*([}\]])", r"\1", m.group(0)))
            return {"summary": str(data.get("summary", ""))[:400], "items": list(data.get("items") or [])[:8]}
        except ValueError:
            pass
    summary = re.search(r'"summary"\s*:\s*"((?:[^"\\]|\\.)*)"', text)
    items = []
    for it in re.finditer(r'\{[^{}]*"label"\s*:\s*"([^"]*)"[^{}]*\}', text):
        nums = dict(re.findall(r'"([xywh])"\s*:\s*(-?[\d.]+)', it.group(0)))
        if "x" in nums and "y" in nums:
            items.append({"label": it.group(1), **{k: float(v) for k, v in nums.items()}})
    return {"summary": summary.group(1)[:400] if summary else "", "items": items[:8]}


def merge(snap: dict[str, Any], seen: dict[str, Any], window: tuple[int, int, int, int]) -> dict[str, Any]:
    """Add what the vision model saw to the snapshot: a summary, and items v1..v8 in
    screen pixels that point_at and draw_on_screen can use by id."""
    left, top, w, h = window
    out = dict(snap)
    out["seen"] = seen.get("summary", "")
    items = list(snap.get("elements", []))
    for i, it in enumerate(seen.get("items", []), start=1):
        try:
            cx, cy = float(it["x"]) / 1000 * w + left, float(it["y"]) / 1000 * h + top
            iw = max(24.0, float(it.get("w") or 40) / 1000 * w)
            ih = max(18.0, float(it.get("h") or 30) / 1000 * h)
        except (KeyError, TypeError, ValueError):
            continue
        items.append({"id": f"v{i}", "role": "Seen", "src": "picture", "name": str(it.get("label", ""))[:80],
                      "x": round(cx - iw / 2), "y": round(cy - ih / 2), "w": round(iw), "h": round(ih)})
    out["elements"] = items
    return out


def _norm_line(text: Any) -> str:
    return re.sub(r"\s+", " ", str(text or "")).strip().lower()


def merge_ocr(snap: dict[str, Any], boxes: dict[str, Any] | None,
              window: tuple[int, int, int, int], max_items: int = 120) -> dict[str, Any]:
    """Add the words Windows OCR read from a picture of the window.

    Lines arrive as t1, t2… items in screen pixels, so Compii can point at text it
    can read but the app never exposed through its controls (Electron, canvas apps,
    games, remote desktops). The raw text is kept too, for reading and summarising.
    """
    if not boxes or not boxes.get("lines"):
        return snap
    left, top, w, h = window
    iw, ih = float(boxes.get("width") or 0), float(boxes.get("height") or 0)
    if iw <= 0 or ih <= 0 or w <= 0 or h <= 0:
        return snap
    sx, sy = w / iw, h / ih
    out = dict(snap)
    items = list(snap.get("elements", []))
    known = {_norm_line(e.get("name")) for e in items if e.get("name")}
    known |= {_norm_line(e.get("value")) for e in items if e.get("value")}
    added = 0
    texts: list[str] = []
    for line in boxes["lines"]:
        text = " ".join(str(line.get("text") or "").split())
        if len(text) < 2:
            continue
        texts.append(text)
        norm = _norm_line(text)
        if added >= max_items or norm in known:
            continue
        known.add(norm)
        added += 1
        items.append({
            "id": f"t{added}", "role": "Text", "src": "ocr", "name": text[:180],
            "x": round(left + float(line.get("x", 0)) * sx),
            "y": round(top + float(line.get("y", 0)) * sy),
            "w": max(8, round(float(line.get("w", 0)) * sx)),
            "h": max(8, round(float(line.get("h", 0)) * sy)),
        })
    out["elements"] = items
    out["ocr_text"] = "\n".join(texts)[:12000]
    out["ocr_lines"] = len(texts)
    return out


def locate_text(boxes: dict[str, Any] | None, window: tuple[int, int, int, int],
                target: str) -> dict[str, Any] | None:
    """The best OCR match for `target`, in screen pixels: exact word first, then line."""
    if not boxes or not boxes.get("lines"):
        return None
    left, top, w, h = window
    iw, ih = float(boxes.get("width") or 0), float(boxes.get("height") or 0)
    if iw <= 0 or ih <= 0 or w <= 0 or h <= 0:
        return None
    sx, sy = w / iw, h / ih
    wanted = _norm_line(target)
    if not wanted:
        return None
    best: tuple[float, dict[str, Any]] | None = None
    for line in boxes["lines"]:
        for word in line.get("words") or []:
            text = _norm_line(word.get("text"))
            if not text:
                continue
            score = 4.0 if text == wanted else (2.0 if wanted in text or text in wanted else 0.0)
            if not score:
                continue
            if best is None or score > best[0]:
                best = (score, word)
        text = _norm_line(line.get("text"))
        if text and (text == wanted or wanted in text):
            score = 3.0 if text == wanted else 1.0
            if best is None or score > best[0]:
                best = (score, line)
    if best is None:
        return None
    box = best[1]
    x, y = left + float(box.get("x", 0)) * sx, top + float(box.get("y", 0)) * sy
    bw, bh = max(8.0, float(box.get("w", 0)) * sx), max(8.0, float(box.get("h", 0)) * sy)
    return {"name": str(box.get("text") or target)[:120], "x": round(x), "y": round(y),
            "w": round(bw), "h": round(bh)}
