"""Seeing apps that don't describe themselves (Blender, games, design tools, video).

Most Windows apps list their buttons and labels for screen readers, and Compii reads
those. Some draw everything themselves, so that list is nearly empty. Then, and only
when you ask about the screen, Compii takes a picture of the window you're in (never
password managers) and asks a free vision model what's relevant and where it is.
Those spots become items Compii can point at, circle and teach with.
"""

from __future__ import annotations

import base64
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
# A window that lists fewer readable items than this is mostly drawn pixels: look at it.
THIN = 15
# Apps known to draw their own interface.
DRAWN_APPS = ("blender", "unity", "unreal", "godot", "krita", "gimp", "figma", "photoshop", "illustrator", "davinci",
              "resolve", "premiere", "afterfx", "obs", "steam", "minecraft", "javaw", "fusion360", "sketchup", "zbrush",
              "filmora", "wondershare", "capcut", "canva", "audacity", "fl studio", "ableton")


def needs_picture(snap: dict[str, Any] | None) -> bool:
    if not snap or snap.get("blocked"):
        return False
    app = f"{snap.get('app', '')} {snap.get('title', '')}".lower()
    elements = snap.get("elements", [])
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
    """Password managers and the like are never captured."""
    if sys.platform != "win32":
        return True
    import ctypes

    from .screen import BLOCKED_APPS, _process_name, foreground_title

    pid = ctypes.c_ulong()
    ctypes.windll.user32.GetWindowThreadProcessId(ctypes.windll.user32.GetForegroundWindow(), ctypes.byref(pid))
    name = f"{_process_name(pid.value)} {foreground_title()}".lower()
    return any(b in name for b in BLOCKED_APPS) or "compii" in foreground_title().lower()


def _ask(png: bytes, prompt: str, key: str, transport: Any = None, max_tokens: int = 900) -> str:
    import httpx

    body = {
        "model": VISION_MODEL, "max_tokens": max_tokens, "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(png).decode()}},
        ]}],
    }
    with httpx.Client(timeout=8, transport=transport) as c:  # never stall Compii
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


def check(png: bytes, done_when: str, key: str, transport: Any = None) -> tuple[bool, str]:
    """Is the step done? True when the window now shows `done_when`."""
    data = _json(_ask(png, (
        "The user is following a lesson and was asked to do one step. The step is done when this is true: "
        f"\"{done_when}\". Look at this window. Is it true now? Be strict: only say yes when you can clearly see it. "
        "Reply only with JSON: {\"done\": true/false, \"why\": \"a few words\"}"), key, transport, max_tokens=200))
    return bool(data.get("done")), str(data.get("why", ""))[:160]


def capture_foreground(hwnd: int | None = None) -> tuple[bytes, tuple[int, int, int, int]] | None:
    """A PNG of the foreground window (or `hwnd`), scaled to at most MAX_WIDTH wide, and the
    window's rectangle in screen pixels. Only that window is drawn, not what overlaps it."""
    shot = grab_foreground(hwnd)
    if shot is None:
        return None
    pixels, window = shot
    step = max(1, -(-pixels.shape[1] // MAX_WIDTH))
    return encode_png(np.ascontiguousarray(pixels[::step, ::step])), window


def grab_foreground(hwnd: int | None = None) -> tuple[np.ndarray, tuple[int, int, int, int]] | None:
    """The foreground window's pixels (RGB, full size) and its rectangle in screen pixels."""
    if sys.platform != "win32":
        return None
    import ctypes
    from ctypes import wintypes

    user32, gdi32 = ctypes.windll.user32, ctypes.windll.gdi32
    hwnd = hwnd or user32.GetForegroundWindow()
    rect = wintypes.RECT()
    if not hwnd or not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return None
    left, top = rect.left, rect.top
    w, h = rect.right - left, rect.bottom - top
    if w < 40 or h < 40:
        return None
    screen = user32.GetDC(0)
    mem = gdi32.CreateCompatibleDC(screen)
    bmp = gdi32.CreateCompatibleBitmap(screen, w, h)
    try:
        gdi32.SelectObject(mem, bmp)
        # The window draws itself (works for modern GPU-drawn apps too); else copy the screen.
        if not user32.PrintWindow(hwnd, mem, 2):  # PW_RENDERFULLCONTENT
            gdi32.BitBlt(mem, 0, 0, w, h, screen, left, top, 0x00CC0020)  # SRCCOPY

        class BITMAPINFOHEADER(ctypes.Structure):
            _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                        ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                        ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
                        ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
                        ("biClrImportant", wintypes.DWORD)]

        info = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
        buf = (ctypes.c_ubyte * (w * h * 4))()
        if not gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(info), 0):
            return None
        pixels = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 4)[:, :, 2::-1]  # BGRA -> RGB
    finally:
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(mem)
        user32.ReleaseDC(0, screen)
    return pixels.copy(), (left, top, w, h)


def encode_png(rgb: np.ndarray) -> bytes:
    """Minimal PNG encoder (no image library needed)."""
    h, w, _ = rgb.shape
    raw = np.hstack([np.zeros((h, 1), dtype=np.uint8), rgb.reshape(h, w * 3)]).tobytes()

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def look(png: bytes, question: str, key: str, transport: Any = None) -> dict[str, Any]:
    """Ask the vision model what's relevant to the question and where it is (0-1000 grid)."""
    import httpx

    prompt = (
        f"The user is looking at this app window and asks: \"{question}\"\n"
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
        items.append({"id": f"v{i}", "role": "Seen", "name": str(it.get("label", ""))[:80],
                      "x": round(cx - iw / 2), "y": round(cy - ih / 2), "w": round(iw), "h": round(ih)})
    out["elements"] = items
    return out
