"""Everyday tools the personal agents ship with and Compii lacked.

* forget_memory — "forget that I…": the user can take back anything Compii saved
  about them, from the conversation, not only from a settings page (Meta's Muse).
* activity_log — "what have you done today?": read back the hash-chained safety
  log in plain words, so the record of what ran is something you can ask about
  (Muse's audit trail, Claude Duet's activity view).
* world_time — the time anywhere, and "3pm in London is what in Tokyo?".
* weather — current conditions and the next days, the line every morning brief
  opens with (Duet, Dots). Asks Open-Meteo, which needs no key; only the place
  name leaves the PC.
"""

from __future__ import annotations

import datetime as dt
import json
import time
import zoneinfo
from typing import Any, Callable

from .policy import ActionKind
from .tools import Tool, ToolError, ToolResult

GEOCODE = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST = "https://api.open-meteo.com/v1/forecast"
MAX_FORGET = 10

# WMO weather codes, as Open-Meteo reports them.
_SKY = {
    0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "freezing fog",
    51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
    61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
    71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains", 80: "showers", 81: "showers",
    82: "violent showers", 85: "snow showers", 86: "heavy snow showers", 95: "thunderstorm",
    96: "thunderstorm with hail", 99: "thunderstorm with hail",
}

# The places people name that the time zone database spells differently.
_ALIASES = {
    "new york": "America/New_York", "nyc": "America/New_York", "la": "America/Los_Angeles",
    "los angeles": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "sf": "America/Los_Angeles",
    "seattle": "America/Los_Angeles", "chicago": "America/Chicago", "dallas": "America/Chicago",
    "houston": "America/Chicago", "denver": "America/Denver", "toronto": "America/Toronto",
    "london": "Europe/London", "uk": "Europe/London", "paris": "Europe/Paris", "berlin": "Europe/Berlin",
    "madrid": "Europe/Madrid", "rome": "Europe/Rome", "amsterdam": "Europe/Amsterdam",
    "moscow": "Europe/Moscow", "istanbul": "Europe/Istanbul", "dubai": "Asia/Dubai", "india": "Asia/Kolkata",
    "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
    "beijing": "Asia/Shanghai", "china": "Asia/Shanghai", "hong kong": "Asia/Hong_Kong",
    "singapore": "Asia/Singapore", "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "seoul": "Asia/Seoul",
    "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne", "auckland": "Pacific/Auckland",
    "lagos": "Africa/Lagos", "nairobi": "Africa/Nairobi", "cairo": "Africa/Cairo",
    "johannesburg": "Africa/Johannesburg", "banjul": "Africa/Banjul", "dakar": "Africa/Dakar",
    "sao paulo": "America/Sao_Paulo", "mexico city": "America/Mexico_City", "utc": "UTC", "gmt": "UTC",
}

Fetch = Callable[[str, dict[str, Any]], dict[str, Any]]


def _http_json(url: str, params: dict[str, Any]) -> dict[str, Any]:
    import httpx

    r = httpx.get(url, params=params, timeout=12, headers={"User-Agent": "Compii"})
    r.raise_for_status()
    return r.json()


def _zone(place: str, fetch: Fetch | None) -> tuple[str, dt.tzinfo]:
    """A place name, city or IANA zone → (label, zone). Offline first; the
    geocoder only for places the zone database does not know by name."""
    raw = place.strip()
    if not raw:
        raise ToolError("Name a place or a time zone.")
    key = raw.lower()
    if key in ("here", "local", "my time", "me"):
        return "here", dt.datetime.now().astimezone().tzinfo or dt.timezone.utc
    if key in _ALIASES:
        return raw, zoneinfo.ZoneInfo(_ALIASES[key])
    try:
        return raw, zoneinfo.ZoneInfo(raw)
    except (zoneinfo.ZoneInfoNotFoundError, ValueError):
        pass
    want = key.replace(" ", "_")
    for z in sorted(zoneinfo.available_timezones()):
        if z.lower().rsplit("/", 1)[-1] == want:
            return raw, zoneinfo.ZoneInfo(z)
    if fetch is not None:
        try:
            hit = (fetch(GEOCODE, {"name": raw, "count": 1}).get("results") or [None])[0]
        except Exception as e:  # noqa: BLE001 - said plainly below
            raise ToolError(f"Couldn't look up “{raw}”: {e}") from e
        if hit and hit.get("timezone"):
            label = ", ".join(p for p in (hit.get("name"), hit.get("country")) if p)
            return label, zoneinfo.ZoneInfo(hit["timezone"])
    raise ToolError(f"I don't know which time zone “{raw}” is in. Try a city or a zone like Europe/Paris.")


def _clock(t: dt.datetime) -> str:
    return t.strftime("%a %d %b, %H:%M").replace(" 0", " ")


def everyday_tools(toolbox: Any, audit: Any = None, *, fetch: Fetch | None = _http_json,
                   now: Callable[[], dt.datetime] | None = None) -> list[Tool]:
    """`toolbox` gives memories and their deletion; `audit` is the safety log;
    `fetch` reaches the internet (None keeps every tool offline)."""
    clock = now or (lambda: dt.datetime.now(dt.timezone.utc))

    def forget_memory(a: dict[str, Any]) -> ToolResult:
        words = [w for w in str(a.get("about", "")).lower().split() if len(w) > 1]
        if not words:
            raise ToolError("Say what to forget, in a few words from the fact.")
        hits = [m for m in toolbox.memories() if all(w in m["fact"].lower() for w in words)]
        if not hits:
            return ToolResult("Nothing saved matches that, so there is nothing to forget.")
        if len(hits) > MAX_FORGET:
            raise ToolError(f"That matches {len(hits)} saved facts. Ask the user to be more specific; "
                            f"nothing was deleted.")
        gone = [m["fact"] for m in hits if toolbox.forget(m["id"])]
        return ToolResult(f"Forgot {len(gone)} fact(s):\n" + "\n".join(f"- {f}" for f in gone))

    labels = {
        "done": "did", "failed": "tried and failed", "declined": "was told no", "blocked": "was stopped from",
        "stopped": "stopped", "asked": "asked to", "approved": "was allowed to",
    }

    def activity_log(a: dict[str, Any]) -> ToolResult:
        if audit is None:
            raise ToolError("The activity log isn't available on this PC.")
        hours = max(.1, min(float(a.get("hours") or 24), 24 * 31))
        since = time.time() - hours * 3600
        rows = [e for e in audit.entries(limit=2000) if float(e.get("at") or 0) >= since]
        if not rows:
            return ToolResult(f"Nothing was recorded in the last {hours:g} hour(s).")
        counts: dict[str, int] = {}
        lines = []
        for e in rows:
            ev = str(e.get("event", ""))
            counts[ev] = counts.get(ev, 0) + 1
            if len(lines) >= int(a.get("limit") or 30):
                continue
            tool = str(e.get("tool") or "")
            what = tool
            t = toolbox.tools.get(tool) if tool else None
            if t is not None:
                try:
                    args = json.loads(e["args"]) if isinstance(e.get("args"), str) else (e.get("args") or {})
                    what = t.describe(args)
                except Exception:  # noqa: BLE001 - an old entry still lists by its tool name
                    what = tool
            when = dt.datetime.fromtimestamp(float(e.get("at") or 0)).strftime("%a %H:%M")
            if ev in labels and what:
                lines.append(f"- {when} · {labels[ev]}: {what}"
                             + (f" ({str(e['error'])[:120]})" if ev == "failed" and e.get("error") else ""))
            elif ev == "delegated":
                lines.append(f"- {when} · handed a job to a teammate: {str(e.get('objective', ''))[:120]}")
            elif ev not in ("voice_answer",):
                lines.append(f"- {when} · {ev.replace('_', ' ')}")
        tally = ", ".join(f"{n} {labels.get(k, k.replace('_', ' '))}" for k, n in sorted(counts.items(), key=lambda kv: -kv[1]))
        chain = audit.verify()
        seal = "The log's chain checks out." if chain.get("ok") else "Warning: the log's chain does not verify."
        return ToolResult(f"From the safety log, last {hours:g} hour(s), newest first ({tally}):\n"
                          + "\n".join(lines) + f"\n{seal}")

    def world_time(a: dict[str, Any]) -> ToolResult:
        places = [str(p) for p in (a.get("places") or []) if str(p).strip()] or ["here"]
        if len(places) > 12:
            raise ToolError("At most 12 places at once.")
        base = clock()
        at, src = str(a.get("at") or "").strip(), str(a.get("from_place") or "").strip()
        if at:
            try:
                hh, mm = (int(x) for x in at.split(":"))
            except ValueError as e:
                raise ToolError("Give the time as 24-hour HH:MM, e.g. 15:00.") from e
            label, tz = _zone(src or "here", fetch)
            local = base.astimezone(tz)
            base = local.replace(hour=hh, minute=mm, second=0, microsecond=0)
            head = f"{at} in {label} ({_clock(base)}) is:"
        else:
            head = "Right now:"
        out = []
        for p in places:
            label, tz = _zone(p, fetch)
            t = base.astimezone(tz)
            off = t.utcoffset() or dt.timedelta()
            sign = "+" if off >= dt.timedelta() else "-"
            mins = abs(int(off.total_seconds())) // 60
            out.append(f"- {label}: {_clock(t)} (UTC{sign}{mins // 60:02d}:{mins % 60:02d})")
        return ToolResult(head + "\n" + "\n".join(out))

    def weather(a: dict[str, Any]) -> ToolResult:
        if fetch is None:
            raise ToolError("Weather needs the internet, which is off for Compii here.")
        place = str(a.get("place", "")).strip()
        if not place:
            raise ToolError("Which place?")
        days = max(1, min(int(a.get("days") or 3), 7))
        try:
            hit = (fetch(GEOCODE, {"name": place, "count": 1}).get("results") or [None])[0]
            if not hit:
                raise ToolError(f"I couldn't find a place called “{place}”.")
            f = fetch(FORECAST, {
                "latitude": hit["latitude"], "longitude": hit["longitude"], "timezone": "auto",
                "current": "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,precipitation",
                "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code",
                "forecast_days": days,
            })
        except ToolError:
            raise
        except Exception as e:  # noqa: BLE001 - the service being down is said, not hidden
            raise ToolError(f"The weather service didn't answer: {e}") from e
        name = ", ".join(p for p in (hit.get("name"), hit.get("admin1"), hit.get("country")) if p)
        cur = f.get("current") or {}
        lines = [f"{name}, now: {cur.get('temperature_2m')}°C (feels {cur.get('apparent_temperature')}°C), "
                 f"{_SKY.get(int(cur.get('weather_code', -1)), 'unknown sky')}, wind {cur.get('wind_speed_10m')} km/h."]
        d = f.get("daily") or {}
        for i, day in enumerate(d.get("time") or []):
            label = dt.date.fromisoformat(day).strftime("%a %d %b").replace(" 0", " ")
            rain = (d.get("precipitation_probability_max") or [None] * 8)[i]
            lines.append(f"- {label}: {d['temperature_2m_min'][i]}–{d['temperature_2m_max'][i]}°C, "
                         f"{_SKY.get(int(d['weather_code'][i]), 'mixed')}"
                         + (f", {rain}% chance of rain" if rain is not None else ""))
        return ToolResult("\n".join(lines) + "\n(Open-Meteo forecast.)")

    s = {"type": "string"}
    return [
        Tool("forget_memory",
             "Delete facts Compii saved about the user, when they ask you to forget something. Matches saved facts "
             "containing all the given words. Tell the user exactly what was forgotten.",
             {"about": {**s, "description": "A few words from the fact to forget, e.g. 'sister birthday'."}},
             ["about"], ActionKind.DELETE, forget_memory, lambda a: f"Forget what was saved about “{a.get('about', '')}”"),
        Tool("activity_log",
             "Read back what Compii actually did, from its tamper-evident safety log: actions taken, failed, "
             "declined or blocked, and jobs handed to teammates. Use for 'what did you do today?' or to check a claim.",
             {"hours": {"type": "number", "description": "How far back to look (default 24)."},
              "limit": {"type": "integer", "description": "Most lines to list (default 30)."}},
             [], ActionKind.READ, activity_log, lambda a: "Read the activity log"),
        Tool("world_time",
             "The current time in one or more places, or convert a time from one place to others "
             "(e.g. at=15:00, from_place=London, places=[Tokyo, New York]).",
             {"places": {"type": "array", "items": s, "description": "Cities, countries or zones like Europe/Paris."},
              "at": {**s, "description": "Optional 24-hour HH:MM to convert instead of now."},
              "from_place": {**s, "description": "Where 'at' is; defaults to the user's own time."}},
             [], ActionKind.READ, world_time, lambda a: f"Check the time in {', '.join(a.get('places') or ['here'])}"),
        Tool("weather",
             "Current weather and the forecast for a place (up to 7 days). Only the place name is sent, to Open-Meteo.",
             {"place": {**s, "description": "City or town, e.g. 'Banjul' or 'Paris, France'."},
              "days": {"type": "integer", "description": "Days of forecast, 1-7 (default 3)."}},
             ["place"], ActionKind.READ, weather, lambda a: f"Check the weather in {a.get('place', '')}"),
    ]
