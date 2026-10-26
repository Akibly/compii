"""Read the words in a picture with the OCR engine Windows already has.

Nothing leaves the PC: the picture is decoded and read in memory, and the words come back as
plain text. Windows' OCR runtime and the ONNX runtime behind Compii's natural voice cannot
share a process (loading one makes the other crash), so each read happens in a short-lived
worker process. Core itself never loads WinRT, and a bad picture cannot take the app down.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import subprocess
import sys
import threading
from pathlib import Path

MAX_CHARS = 20_000
MAX_LINES = 240
_lock = threading.Lock()
_probe_lock = threading.Lock()
_ready: bool | None = None
_root = Path(__file__).resolve().parent.parent


def _run(args: list[str], data: bytes = b"", timeout: float = 20.0) -> subprocess.CompletedProcess:
    flags = {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}
    return subprocess.run(
        [sys.executable, "-m", "compii_core.ocr", *args],
        input=data,
        capture_output=True,
        cwd=str(_root),
        timeout=timeout,
        **flags,
    )


def available() -> bool:
    """Is there a Windows OCR engine for the user's languages on this PC?"""
    global _ready
    if _ready is None:
        with _probe_lock:
            if _ready is None:
                _ready = _probe()
    return _ready


def _probe() -> bool:
    try:
        if importlib.util.find_spec("winrt.windows.media.ocr") is None:
            return False
        return _run(["--probe"]).stdout.strip() == b"ready"
    except Exception:  # noqa: BLE001 - not Windows, or WinRT is missing
        return False


def read_png(png: bytes) -> str:
    """The words in a PNG, line by line, or "" when this PC can't read it."""
    if not png or not available():
        return ""
    try:
        with _lock:
            done = _run([], png)
        if done.returncode != 0:
            return ""
        return done.stdout.decode("utf-8", "replace")[:MAX_CHARS]
    except Exception:  # noqa: BLE001 - no picture read is better than a broken recorder
        return ""


def read_png_boxes(png: bytes) -> dict | None:
    """The words in a PNG with the pixels they occupy, or None when this PC can't read it.

    `{"width", "height", "lines": [{"text", "x", "y", "w", "h"}]}`. Coordinates are in
    image pixels; the caller scales them to the window's screen rectangle.
    """
    if not png or not available():
        return None
    try:
        with _lock:
            done = _run(["--boxes"], png, timeout=25.0)
        if done.returncode != 0 or not done.stdout.strip():
            return None
        data = json.loads(done.stdout.decode("utf-8", "replace"))
        if not isinstance(data, dict) or not data.get("width") or not data.get("height"):
            return None
        lines = [
            line for line in data.get("lines", [])
            if isinstance(line, dict) and str(line.get("text", "")).strip()
        ][:MAX_LINES]
        data["lines"] = lines
        return data
    except Exception:  # noqa: BLE001 - local reading is a fallback, never a failure
        return None


# ---- worker -------------------------------------------------------------------


def _engine():
    from winrt.windows.media.ocr import OcrEngine

    return OcrEngine.try_create_from_user_profile_languages()


def _main() -> int:
    if "--probe" in sys.argv:
        try:
            ready = _engine() is not None
        except Exception:  # noqa: BLE001
            ready = False
        print("ready" if ready else "unavailable")
        return 0
    png = sys.stdin.buffer.read()
    if not png:
        return 0
    boxes = "--boxes" in sys.argv
    try:
        data = asyncio.run(_read_boxes(png) if boxes else _read(png))
    except Exception:  # noqa: BLE001
        return 1
    if boxes:
        sys.stdout.buffer.write(json.dumps(data, ensure_ascii=False).encode("utf-8", "replace"))
    else:
        sys.stdout.buffer.write(str(data)[:MAX_CHARS].encode("utf-8", "replace"))
    return 0


# Windows' OCR misreads screen-sized text: a synthetic test of 11-15 px lines scored 0.85-0.98 at
# the picture's own size and 0.96-0.99 read from a copy twice as large. Reads use that copy; the
# word boxes are mapped back, so pointing still lands on the real pixels.
SCALE = 2.0
MAX_SIDE = 9600  # under the engine's own limit (OcrEngine.max_image_dimension, 10000)


async def _bitmap(png: bytes):
    """The picture as an OCR-ready bitmap, enlarged where that fits; (bitmap, decoder, scale)."""
    from winrt.windows.graphics.imaging import (BitmapAlphaMode, BitmapDecoder, BitmapInterpolationMode,
                                                BitmapPixelFormat, BitmapTransform, ColorManagementMode,
                                                ExifOrientationMode)
    from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream

    stream = InMemoryRandomAccessStream()
    writer = DataWriter(stream)
    writer.write_bytes(png)
    await writer.store_async()
    await writer.flush_async()
    stream.seek(0)
    decoder = await BitmapDecoder.create_async(stream)
    w, h = int(decoder.pixel_width), int(decoder.pixel_height)
    scale = min(SCALE, MAX_SIDE / max(w, h, 1))
    if scale <= 1.05:
        return await decoder.get_software_bitmap_async(), decoder, 1.0
    t = BitmapTransform()
    t.scaled_width, t.scaled_height = int(w * scale), int(h * scale)
    t.interpolation_mode = BitmapInterpolationMode.FANT
    bitmap = await decoder.get_software_bitmap_transformed_async(
        BitmapPixelFormat.BGRA8, BitmapAlphaMode.PREMULTIPLIED, t,
        ExifOrientationMode.IGNORE_EXIF_ORIENTATION, ColorManagementMode.DO_NOT_COLOR_MANAGE)
    return bitmap, decoder, scale


async def _read(png: bytes) -> str:
    engine = _engine()
    if engine is None:
        return ""
    bitmap, _, _ = await _bitmap(png)
    result = await engine.recognize_async(bitmap)
    return result.text or ""


async def _read_boxes(png: bytes) -> dict:
    engine = _engine()
    if engine is None:
        return {"width": 0, "height": 0, "lines": []}
    bitmap, decoder, k = await _bitmap(png)
    result = await engine.recognize_async(bitmap)

    lines: list[dict] = []
    for line in result.lines:
        words = list(line.words or [])
        boxes = [w.bounding_rect for w in words if w.text and w.text.strip()]
        if not boxes:
            continue
        x = min(b.x for b in boxes)
        y = min(b.y for b in boxes)
        right = max(b.x + b.width for b in boxes)
        bottom = max(b.y + b.height for b in boxes)
        lines.append({
            "text": " ".join(w.text.strip() for w in words if w.text and w.text.strip()),
            "x": round(x / k), "y": round(y / k), "w": round((right - x) / k), "h": round((bottom - y) / k),
            "words": [
                {"text": w.text.strip(), "x": round(w.bounding_rect.x / k), "y": round(w.bounding_rect.y / k),
                 "w": round(w.bounding_rect.width / k), "h": round(w.bounding_rect.height / k)}
                for w in words if w.text and w.text.strip()
            ],
        })
    return {"width": int(decoder.pixel_width), "height": int(decoder.pixel_height), "lines": lines}


if __name__ == "__main__":
    raise SystemExit(_main())
