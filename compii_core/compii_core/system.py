"""The PC itself: battery, disks, network, volume, brightness and media keys.

Status is read from the machine and never guessed. Changes are small, reversible and read
back before Compii says they happened: volume, mute, screen brightness, and the media keys
whatever app is playing already listens for. Power, network and security settings are not
touched, and nothing here can turn the machine off.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
from typing import Any

from .tools import Tool, ToolError, ToolResult

_ARGS_ENV = "COMPII_SYSTEM_ARGS"
_TIMEOUT = 25

_HEAD = """
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$a = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:{env})) | ConvertFrom-Json
function Say($o) {{ [Console]::Out.Write(($o | ConvertTo-Json -Depth 6 -Compress)) }}
""".format(env=_ARGS_ENV)

_STATUS = _HEAD + """
$os = Get-CimInstance Win32_OperatingSystem
$battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
$power = Get-CimInstance -Namespace root/WMI -ClassName BatteryStatus -ErrorAction SilentlyContinue | Select-Object -First 1
$disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'
$net = Get-NetConnectionProfile -ErrorAction SilentlyContinue
$ips = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway } | ForEach-Object { $_.IPv4Address.IPAddress }
$screen = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue | Select-Object -First 1
Say @{
  os = "$($os.Caption)"; version = "$($os.Version)"
  uptime_min = [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes
  ram_free_mb = [math]::Round($os.FreePhysicalMemory / 1024)
  ram_total_mb = [math]::Round($os.TotalVisibleMemorySize / 1024)
  battery = if ($battery) { @{ percent = [int]$battery.EstimatedChargeRemaining
                               on_ac = if ($power) { [bool]$power.PowerOnline } else { $null } } } else { $null }
  disks = @($disks | ForEach-Object { @{ drive = "$($_.DeviceID)"
                                         free_gb = [math]::Round($_.FreeSpace / 1GB, 1)
                                         total_gb = [math]::Round($_.Size / 1GB, 1) } })
  networks = @($net | ForEach-Object { @{ name = "$($_.Name)"; adapter = "$($_.InterfaceAlias)"
                                          internet = "$($_.IPv4Connectivity)" } })
  ipv4 = @($ips)
  brightness = if ($screen) { [int]$screen.CurrentBrightness } else { $null }
}
"""

_BRIGHTNESS = _HEAD + """
$method = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $method) { Say @{ error = 'no_brightness' }; exit 0 }
$method.WmiSetBrightness(1, [int]$a.level) | Out-Null
$now = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue | Select-Object -First 1
Say @{ brightness = if ($now) { [int]$now.CurrentBrightness } else { [int]$a.level } }
"""

_MEDIA = _HEAD + """
$keys = @{ play_pause = 179; next = 176; previous = 177; stop = 178 }
$key = $keys["$($a.action)"]
if (-not $key) { Say @{ error = 'bad_action' }; exit 0 }
(New-Object -ComObject WScript.Shell).SendKeys([char]$key)
Say @{ pressed = "$($a.action)" }
"""

MEDIA_ACTIONS = ("play_pause", "next", "previous", "stop")

_MEDIA_NAMES = {"play_pause": "play/pause", "next": "next track", "previous": "previous track", "stop": "stop"}


def _run(script: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = base64.b64encode(json.dumps(args or {}).encode("utf-8")).decode("ascii")
    env = {**os.environ, _ARGS_ENV: payload}
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                             capture_output=True, text=True, encoding="utf-8", timeout=_TIMEOUT, env=env,
                             creationflags=0x08000000 if sys.platform == "win32" else 0)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ToolError(f"Windows would not answer that ({type(e).__name__}).") from e
    raw = (out.stdout or "").strip()
    if out.returncode != 0 or not raw:
        raise ToolError(f"Windows would not answer: {(out.stderr or out.stdout).strip()[:200] or 'no reply'}")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise ToolError("Windows answered in a way Compii could not read.") from e


def _volume():
    """The speaker endpoint's volume control, opened through the same session the user hears."""
    try:
        from pycaw.pycaw import AudioUtilities

        return AudioUtilities.GetSpeakers().EndpointVolume
    except Exception as e:  # noqa: BLE001 - no audio device and COM refusals are the same story
        raise ToolError("Windows wouldn't open the speaker volume control (there may be no audio device).") from e


def volume_state() -> dict[str, Any]:
    volume = _volume()
    return {"level": round(volume.GetMasterVolumeLevelScalar() * 100), "muted": bool(volume.GetMute())}


def set_volume(level: int | None = None, mute: bool | None = None) -> dict[str, Any]:
    volume = _volume()
    if level is not None:
        volume.SetMasterVolumeLevelScalar(max(0, min(100, int(level))) / 100, None)
        if mute is None and volume.GetMute():
            volume.SetMute(False, None)  # asking for a level means wanting to hear it
    if mute is not None:
        volume.SetMute(bool(mute), None)
    return volume_state()


def set_brightness(level: int) -> dict[str, Any]:
    got = _run(_BRIGHTNESS, {"level": max(0, min(100, int(level)))})
    if got.get("error") == "no_brightness":
        raise ToolError("This screen can't be dimmed from here — external monitors usually can't. "
                        "Use the monitor's own buttons, or ask about the laptop screen.")
    return got


def send_media(action: str) -> dict[str, Any]:
    if action not in MEDIA_ACTIONS:
        raise ToolError(f"Unknown media action “{action}”. Use one of: {', '.join(MEDIA_ACTIONS)}.")
    got = _run(_MEDIA, {"action": action})
    if got.get("error"):
        raise ToolError("Windows wouldn't take that media key.")
    return got


def status() -> dict[str, Any]:
    got = _run(_STATUS)
    try:
        got["volume"] = volume_state()
    except ToolError:
        got["volume"] = None  # no audio device: the rest of the machine is still worth reporting
    return got


def _duration(minutes: int) -> str:
    minutes = max(0, int(minutes))
    days, rest = divmod(minutes, 1440)
    hours, mins = divmod(rest, 60)
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {mins}m"
    return f"{mins}m"


def _status_text(got: dict[str, Any]) -> str:
    lines = [f"{got.get('os', 'Windows')} ({got.get('version', '')})".replace(" ()", "")]
    battery = got.get("battery")
    if battery:
        where = "on mains" if battery.get("on_ac") else "on battery"
        percent = battery.get("percent")
        lines.append(f"Battery {percent}% ({where})" if percent is not None else f"Battery ({where})")
    lines.append(f"Screen brightness {got['brightness']}%" if got.get("brightness") is not None
                 else "Screen brightness: not readable on this display")
    volume = got.get("volume")
    if volume:
        lines.append(f"Volume {volume['level']}%" + (" (muted)" if volume["muted"] else ""))
    else:
        lines.append("Volume: no speaker volume control was available")
    if got.get("ram_total_mb"):
        lines.append(f"Memory {got['ram_free_mb'] / 1024:.1f} GB free of {got['ram_total_mb'] / 1024:.1f} GB")
    lines.append(f"Up {_duration(got.get('uptime_min', 0))}")
    disks = got.get("disks") or []
    if disks:
        lines.append("Disks: " + "; ".join(f"{d['drive']} {d['free_gb']} GB free of {d['total_gb']} GB"
                                          for d in disks))
    networks = got.get("networks") or []
    if networks:
        lines.append("Network: " + "; ".join(f"{n['name']} on {n['adapter']} ({n['internet']})"
                                            for n in networks))
    if got.get("ipv4"):
        lines.append("IPv4: " + ", ".join(got["ipv4"]))
    return "\n".join(lines)


def system_tools() -> list[Tool]:
    if sys.platform != "win32":
        return []
    i, b = {"type": "integer"}, {"type": "boolean"}

    def read_status(_a: dict[str, Any]) -> ToolResult:
        return ToolResult(_status_text(status()))

    def change_volume(a: dict[str, Any]) -> ToolResult:
        if a.get("level") is None and a.get("mute") is None:
            raise ToolError("Give a level (0-100) or mute (true/false).")
        now = set_volume(a.get("level"), a.get("mute"))
        return ToolResult(f"Volume is now {now['level']}%" + (" and muted." if now["muted"] else "."))

    def change_brightness(a: dict[str, Any]) -> ToolResult:
        got = set_brightness(int(a["level"]))
        actual = int(got.get("brightness", a["level"]))
        asked = int(a["level"])
        return ToolResult(f"Screen brightness is now {actual}%." + (f" (Asked for {asked}%.)" if actual != asked else ""))

    def change_media(a: dict[str, Any]) -> ToolResult:
        got = send_media(str(a["action"]))
        return ToolResult(f"Pressed the Windows {_MEDIA_NAMES[got['pressed']]} key. "
                          "Whether the app playing responded isn't visible from here.")

    return [
        Tool("system_status", "Read the PC's own state: battery and mains, screen brightness, volume, memory, "
             "disk space, network name and IP, and how long it has been on. Use this instead of asking the user "
             "or guessing.",
             {}, [], "read", read_status, lambda a: "Check the PC's status"),
        Tool("set_volume", "Set the speaker volume (0-100) and/or mute or unmute. Reads the volume back, so the "
             "result says what the speakers are really at. Setting a level while muted unmutes.",
             {"level": {**i, "description": "0-100; 50 is halfway. Leave out to keep the level."},
              "mute": {**b, "description": "true to mute, false to unmute. Leave out to keep as it is."}},
             [], "change", change_volume,
             lambda a: (f"Set the volume to {a['level']}%" if a.get("level") is not None else "")
             + (" and " if a.get("level") is not None and a.get("mute") is not None else "")
             + ("mute" if a.get("mute") is True else "unmute" if a.get("mute") is False else "")),
        Tool("set_brightness", "Set the built-in screen's brightness (0-100) and read it back. External monitors "
             "generally can't be dimmed this way; Compii says so rather than pretending.",
             {"level": {**i, "description": "0-100."}}, ["level"], "change", change_brightness,
             lambda a: f"Set the brightness to {a['level']}%"),
        Tool("media_control", "Press a Windows media key: play/pause, next, previous or stop. It goes to whatever "
             "app is playing (Spotify, YouTube, a video), and that app decides what to do with it.",
             {"action": {"type": "string", "enum": list(MEDIA_ACTIONS)}}, ["action"], "change", change_media,
             lambda a: f"Press {_MEDIA_NAMES.get(a['action'], a['action'])}"),
    ]
