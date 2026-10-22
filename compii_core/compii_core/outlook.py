"""Outlook mail, calendar and contacts, through the Outlook the user already runs.

Compii talks to the Outlook COM object the user's own session owns, so it sees exactly the
mailbox, calendar and contacts they see - never a copy, never a second login. Reading is a
read; sending mail and booking time go through the usual approvals like anything else that
leaves the machine or writes into the user's life.

Arguments reach PowerShell as base64 JSON in an environment variable, never stitched into the
script text: a mailbox search for `'); Remove-Item C:\\` stays a search string.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
from typing import Any

from .tools import Tool, ToolError, ToolResult

_ARGS_ENV = "COMPII_OUTLOOK_ARGS"
_TIMEOUT = 60  # Outlook's first COM start in a session is slow; a read must not look like a failure

_HEAD = """
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$a = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:{env})) | ConvertFrom-Json
function Say($o) {{ [Console]::Out.Write(($o | ConvertTo-Json -Depth 6 -Compress)) }}
function Clip($s, $n) {{ $t = "$s" -replace "`r", ' ' -replace "`n", ' '; if ($t.Length -gt $n) {{ $t.Substring(0, $n) + '…' }} else {{ $t }} }}
try {{ $app = New-Object -ComObject Outlook.Application }} catch {{ Say @{{ error = 'no_outlook'; why = "$_" }}; exit 0 }}
try {{ $ns = $app.GetNamespace('MAPI'); $null = $ns.Folders.Count }} catch {{ Say @{{ error = 'not_signed_in'; why = "$_" }}; exit 0 }}
""".format(env=_ARGS_ENV)

_PROBE = "$ErrorActionPreference='Stop'\n[Console]::OutputEncoding=[System.Text.Encoding]::UTF8\ntry { $app = New-Object -ComObject Outlook.Application; $ns = $app.GetNamespace('MAPI'); $null = $ns.Folders.Count; [Console]::Out.Write('{\"ok\":true}') } catch { [Console]::Out.Write((@{ ok = $false; why = \"$_\" } | ConvertTo-Json -Compress)) }"

_CALENDAR = _HEAD + """
$cal = $ns.GetDefaultFolder(9)
$from = [DateTime]::Now.AddDays(-[int]$a.days_back)
$to = [DateTime]::Now.AddDays([int]$a.days_forward)
$items = $cal.Items
$items.IncludeRecurrences = $true
$items.Sort('[Start]')
$fmt = 'MM/dd/yyyy HH:mm'
$found = $items.Restrict("[Start] <= '" + $to.ToString($fmt) + "' AND [End] >= '" + $from.ToString($fmt) + "'")
$out = @()
foreach ($i in $found) {
  if ($a.query -and -not (("$($i.Subject) $($i.Location) $($i.Organizer)" ) -like "*$($a.query)*")) { continue }
  $out += @{ subject = "$($i.Subject)"; start = $i.Start.ToString('o'); end = $i.End.ToString('o')
             location = "$($i.Location)"; organizer = "$($i.Organizer)"; all_day = [bool]$i.AllDayEvent
             where = "$($i.Location)"; notes = (Clip $i.Body 240) }
  if ($out.Count -ge 60) { break }
}
Say @{ items = @($out) }
"""

_MAIL = _HEAD + """
$folder = if ("$($a.folder)" -eq 'sent') { $ns.GetDefaultFolder(5) } else { $ns.GetDefaultFolder(6) }
$items = $folder.Items
$items.Sort('[ReceivedTime]', $true)
$out = @()
$seen = 0
foreach ($m in $items) {
  if ($seen -ge 300) { break }
  $seen++
  $who = "$($m.SenderName) <$($m.SenderEmailAddress)>"
  if ($a.unread_only -and -not $m.UnRead) { continue }
  if ($a.query -and -not ("$($m.Subject) $who" -like "*$($a.query)*")) { continue }
  $out += @{ entry_id = "$($m.EntryID)"; subject = "$($m.Subject)"; from = $who; unread = [bool]$m.UnRead
             at = $m.ReceivedTime.ToString('o'); snippet = (Clip $m.Body 260) }
  if ($out.Count -ge [int]$a.limit) { break }
}
Say @{ items = @($out); folder = "$($folder.Name)" }
"""

_MESSAGE = _HEAD + """
try { $m = $ns.GetItemFromID("$($a.entry_id)") } catch { Say @{ error = 'gone'; why = 'that message is no longer in this mailbox' }; exit 0 }
Say @{ subject = "$($m.Subject)"; from = "$($m.SenderName) <$($m.SenderEmailAddress)>"; to = "$($m.To)"
       cc = "$($m.CC)"; at = $m.ReceivedTime.ToString('o'); body = (Clip $m.Body 12000) }
"""

_CONTACTS = _HEAD + """
$book = $ns.GetDefaultFolder(10)
$out = @()
foreach ($p in $book.Items) {
  $mails = @("$($p.Email1Address)", "$($p.Email2Address)", "$($p.Email3Address)") | Where-Object { $_ }
  $hay = "$($p.FullName) $($p.CompanyName) $($mails -join ' ')"
  if ($a.query -and -not ($hay -like "*$($a.query)*")) { continue }
  $out += @{ name = "$($p.FullName)"; company = "$($p.CompanyName)"; emails = @($mails)
             phones = @("$($p.MobileTelePhone)", "$($p.BusinessTelePhone)") | Where-Object { $_ } }
  if ($out.Count -ge [int]$a.limit) { break }
}
Say @{ items = @($out) }
"""

_SEND = _HEAD + """
$m = $app.CreateItem(0)
$m.To = "$($a.to)"
if ($a.cc) { $m.CC = "$($a.cc)" }
$m.Subject = "$($a.subject)"
$m.Body = "$($a.body)"
try {
  $m.Send()
  Say @{ sent = $true; to = "$($a.to)"; subject = "$($a.subject)" }
} catch {
  $m.Save()
  Say @{ sent = $false; draft = $true; to = "$($a.to)"; subject = "$($a.subject)"
         why = "Outlook stopped the send ($($_.Exception.Message)); the message is in Drafts, word for word, ready to send by hand." }
}
"""

_EVENT = _HEAD + """
$culture = [Globalization.CultureInfo]::InvariantCulture
$e = $app.CreateItem(1)
$e.Subject = "$($a.subject)"
$e.Start = [DateTime]::Parse("$($a.start)", $culture)
$e.End = [DateTime]::Parse("$($a.end)", $culture)
if ($a.location) { $e.Location = "$($a.location)" }
if ($a.body) { $e.Body = "$($a.body)" }
$e.Save()
Say @{ created = $true; subject = "$($a.subject)"; start = $e.Start.ToString('o'); end = $e.End.ToString('o') }
"""

_probed_at = 0.0
_probed_ok: bool | None = None


def _run(script: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = base64.b64encode(json.dumps(args or {}).encode("utf-8")).decode("ascii")
    env = {**os.environ, _ARGS_ENV: payload}
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                             capture_output=True, text=True, encoding="utf-8", timeout=_TIMEOUT, env=env,
                             creationflags=0x08000000 if sys.platform == "win32" else 0)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ToolError(f"Windows would not start Outlook for that ({type(e).__name__}).") from e
    raw = (out.stdout or "").strip()
    if out.returncode != 0 or not raw:
        raise ToolError(f"Outlook would not answer: {(out.stderr or out.stdout).strip()[:200] or 'no reply'}")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise ToolError("Outlook answered in a way Compii could not read.") from e


def _check(got: dict[str, Any]) -> dict[str, Any]:
    """Turn Outlook's own error replies into plain speech; pass good replies straight through."""
    if err := got.get("error"):
        raise ToolError({
            "no_outlook": "Outlook isn't installed on this PC, so there's no mailbox or calendar for Compii to read.",
            "not_signed_in": "Outlook is installed but isn't signed in right now. Open it once and Compii can read your mail and calendar.",
            "gone": f"{got.get('why', 'that item is gone.')}",
        }.get(err, f"Outlook said: {got.get('why', err)}"))
    return got


def installed() -> bool:
    """Is there an Outlook on this PC that will actually open? Probed once a minute."""
    global _probed_at, _probed_ok
    if sys.platform != "win32":
        return False
    if _probed_ok is not None and time.monotonic() - _probed_at < 60:
        return _probed_ok
    try:
        _probed_ok = bool(_run(_PROBE).get("ok"))
    except ToolError:
        _probed_ok = False
    _probed_at = time.monotonic()
    return _probed_ok


def calendar_items(days_forward: int = 7, days_back: int = 0, query: str = "") -> list[dict[str, Any]]:
    got = _check(_run(_CALENDAR, {"days_forward": days_forward, "days_back": days_back, "query": query}))
    return got.get("items") or []


def mail_items(query: str = "", limit: int = 10, folder: str = "inbox", unread_only: bool = False) -> dict[str, Any]:
    got = _check(_run(_MAIL, {"query": query, "limit": limit, "folder": folder, "unread_only": unread_only}))
    return {"folder": got.get("folder", folder), "items": got.get("items") or []}


def message(entry_id: str) -> dict[str, Any]:
    return _check(_run(_MESSAGE, {"entry_id": entry_id}))


def contacts(query: str = "", limit: int = 10) -> list[dict[str, Any]]:
    return _check(_run(_CONTACTS, {"query": query, "limit": limit})).get("items") or []


def send_mail(to: str, subject: str, body: str, cc: str = "") -> dict[str, Any]:
    return _check(_run(_SEND, {"to": to, "subject": subject, "body": body, "cc": cc}))


def create_event(subject: str, start: str, end: str, location: str = "", body: str = "") -> dict[str, Any]:
    return _check(_run(_EVENT, {"subject": subject, "start": start, "end": end, "location": location, "body": body}))


def outlook_tools() -> list[Tool]:
    s, i, b = {"type": "string"}, {"type": "integer"}, {"type": "boolean"}

    def read_calendar(a: dict[str, Any]) -> ToolResult:
        items = calendar_items(int(a.get("days_forward", 7)), int(a.get("days_back", 0)), a.get("query", ""))
        if not items:
            return ToolResult("Nothing in the Outlook calendar for those days.")
        lines = [f"- {x['start'][:16].replace('T', ' ')} → {x['end'][:16].replace('T', ' ')}  {x['subject']}"
                 + (f"  @ {x['location']}" if x.get("location") else "")
                 + (f"  ({x['organizer']})" if x.get("organizer") else "") for x in items]
        return ToolResult(f"{len(items)} item(s) in the Outlook calendar:\n" + "\n".join(lines))

    def read_mail(a: dict[str, Any]) -> ToolResult:
        got = mail_items(a.get("query", ""), int(a.get("limit", 10)), a.get("folder", "inbox"),
                         bool(a.get("unread_only", False)))
        if not got["items"]:
            return ToolResult(f"No mail matched in {got['folder']}.")
        lines = [f"- [{ 'new' if x['unread'] else 'read' }] {x['at'][:16].replace('T', ' ')}  {x['from']}\n"
                 f"    {x['subject']}\n    {x['snippet']}\n    (id {x['entry_id'][:18]}…)" for x in got["items"]]
        return ToolResult(f"{len(got['items'])} message(s) in {got['folder']} (read one fully with read_outlook_message):\n"
                          + "\n".join(lines))

    def read_message(a: dict[str, Any]) -> ToolResult:
        m = message(a["entry_id"])
        head = f"From: {m['from']}\nTo: {m['to']}" + (f"\nCc: {m['cc']}" if m.get("cc") else "") + f"\nAt: {m['at']}\n\n"
        return ToolResult(f"{m['subject']}\n{head}{m['body']}")

    def read_contacts(a: dict[str, Any]) -> ToolResult:
        items = contacts(a.get("query", ""), int(a.get("limit", 10)))
        if not items:
            return ToolResult("No Outlook contact matched.")
        lines = [f"- {x['name']}" + (f" ({x['company']})" if x.get("company") else "")
                 + f"  {', '.join(x['emails'])}" + (f"  {', '.join(x['phones'])}" if x.get("phones") else "")
                 for x in items]
        return ToolResult(f"{len(items)} contact(s):\n" + "\n".join(lines))

    def send(a: dict[str, Any]) -> ToolResult:
        got = send_mail(a["to"], a["subject"], a["body"], a.get("cc", ""))
        if got.get("sent"):
            return ToolResult(f"Sent from the user's Outlook to {got['to']}: “{got['subject']}”.")
        return ToolResult(got.get("why", "The mail is saved in Drafts."))

    def book(a: dict[str, Any]) -> ToolResult:
        got = create_event(a["subject"], a["start"], a["end"], a.get("location", ""), a.get("body", ""))
        return ToolResult(f"Booked in the Outlook calendar: “{got['subject']}” {got['start'][:16].replace('T', ' ')}"
                          f" → {got['end'][:16].replace('T', ' ')}.")

    return [
        Tool("read_outlook_calendar", "Read the user's real Outlook calendar: upcoming (or past) appointments with "
             "times, place and organiser. Use this, not guesses, for anything about their schedule.",
             {"days_forward": {**i, "description": "how many days ahead to look (default 7)"},
              "days_back": {**i, "description": "how many days back to include (default 0)"},
              "query": {**s, "description": "only items whose subject, place or organiser contains this"}},
             [], "read", read_calendar,
             lambda a: f"Read the Outlook calendar ({a.get('days_forward', 7)} days ahead)"),
        Tool("read_outlook_mail", "Search the user's real Outlook mailbox (inbox or sent). Returns subject, sender, "
             "time and a snippet plus an id; read one fully with read_outlook_message.",
             {"query": {**s, "description": "words to look for in subject or sender (empty = newest first)"},
              "limit": {**i, "description": "how many messages (default 10, max 30)"},
              "folder": {**s, "enum": ["inbox", "sent"], "description": "which folder (default inbox)"},
              "unread_only": {**b, "description": "only messages not yet read"}},
             [], "read", read_mail, lambda a: f"Search the Outlook {a.get('folder', 'inbox')}"),
        Tool("read_outlook_message", "Read one Outlook message in full, by the id read_outlook_mail returned.",
             {"entry_id": {**s, "description": "the message id from read_outlook_mail"}},
             ["entry_id"], "read", read_message, lambda a: "Read one Outlook message in full"),
        Tool("read_outlook_contacts", "Look up people in the user's Outlook contacts: names, companies, emails, phones.",
             {"query": {**s, "description": "name, company or email to look for (empty = first contacts)"},
              "limit": {**i, "description": "how many (default 10)"}},
             [], "read", read_contacts, lambda a: f"Look up Outlook contacts{': ' + a['query'] if a.get('query') else ''}"),
        Tool("send_outlook_mail", "Send an email from the user's own Outlook account. If Outlook's own guard stops "
             "the send, the message is saved to Drafts word for word and Compii says so.",
             {"to": {**s, "description": "recipient addresses, separated by ;"},
              "subject": s, "body": s,
              "cc": {**s, "description": "cc addresses, separated by ;"}},
             ["to", "subject", "body"], "send", send,
             lambda a: f"Email {a['to']}: “{a['subject']}”"),
        Tool("create_outlook_event", "Book time in the user's real Outlook calendar. Times are ISO, e.g. "
             "2026-10-22T14:00:00.",
             {"subject": s, "start": s, "end": s,
              "location": {**s, "description": "where, or a meeting link"},
              "body": {**s, "description": "notes or an agenda for the invite"}},
             ["subject", "start", "end"], "create", book,
             lambda a: f"Book “{a['subject']}” {a['start'][:16].replace('T', ' ')} in the Outlook calendar"),
    ]
