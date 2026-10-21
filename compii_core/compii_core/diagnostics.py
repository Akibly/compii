"""A diagnostic report you can save and send when something goes wrong.

One zip in ~/Compii/reports with Core's log, the app's crash log and basic facts (versions,
Windows, which AI is chosen, which keys are stored: yes/no only). Keys, tokens, card numbers
and your user name are removed before anything is written. Nothing is sent anywhere.
"""

from __future__ import annotations

import json
import os
import platform
import re
import sys
import time
import zipfile
from pathlib import Path
from typing import Any

from . import __version__
from .guard import redact

TAIL = 1_500_000  # bytes of each log to include


def clean(text: str, secrets: list[str]) -> str:
    """Remove secrets, API-key-shaped strings and the user's name from text."""
    for s in secrets:
        if s and len(s) >= 6:
            text = text.replace(s, "[secret removed]")
    text = re.sub(r"\b(gsk_|nvapi-|sk-|sk-ant-|AIza|mstrl_)[A-Za-z0-9_\-]{12,}", "[key removed]", text)
    text = re.sub(r"([?&]t=)[A-Za-z0-9_\-]{12,}", r"\1[token removed]", text)
    text, _ = redact(text)
    home = str(Path.home())
    user = Path.home().name
    text = text.replace(home, "~").replace(home.replace("\\", "/"), "~")
    if len(user) >= 3:
        text = re.sub(re.escape(user), "[user]", text, flags=re.I)
    return text


def _tail(path: Path) -> str:
    try:
        with open(path, "rb") as f:
            f.seek(max(0, path.stat().st_size - TAIL))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return f"(no {path.name})"


def _os_line() -> str:
    """Windows' version straight from the system. `platform.platform()` works out the same thing by
    running `cmd /c ver` on current Windows builds (the registry keys it used are gone), and a report
    about a sick PC shouldn't need a working shell."""
    if sys.platform == "win32":
        v = sys.getwindowsversion()
        return f"Windows {v.major}.{v.minor} build {v.build}" + (f" {v.service_pack}" if v.service_pack else "")
    return platform.platform()


def _arch() -> str:
    if sys.platform == "win32":
        return os.environ.get("PROCESSOR_ARCHITECTURE", "")
    return platform.machine()


def build_report(workspace: Path, facts: dict[str, Any], secrets: list[str]) -> Path:
    out = workspace / "reports"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"compii-report-{time.strftime('%Y%m%d-%H%M%S')}.zip"
    info = {
        "compii_core": __version__,
        "python": sys.version.split()[0],
        "windows": _os_line(),
        "machine": _arch(),
        "processors": os.cpu_count(),
        "made": time.strftime("%Y-%m-%d %H:%M:%S %z"),
        **facts,
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("info.json", clean(json.dumps(info, indent=1, default=str), secrets))
        z.writestr("core.log", clean(_tail(workspace / "core.log"), secrets))
        z.writestr("app.log", clean(_tail(workspace / "app.log"), secrets))
        z.writestr("README.txt", "Compii diagnostic report. Keys, tokens and your user name were removed.\n"
                                 "Send this file to whoever is helping you with Compii.\n")
    return path
