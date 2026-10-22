# Compii Core

The local service that does the work behind Compii's character. The Flutter app (`compii_flutter/apps/companion`) is the face; Core is the hands.

- **Agent loop** on Claude (`claude-opus-5-5`, adaptive thinking, server-side refusal fallback, web search) or a free local model (see Brain below).
- **Tools:** list/find/read files (text, PDF, Excel), write files, create folders, move (undoable), create Excel spreadsheets with formulas, run Python scripts in the workspace, open files/URLs/known apps, send email, remember/recall facts, and point at a button or menu on screen by its label (Windows UI Automation).
- **Hands in your apps:** list and switch windows, read a window's text and controls, click buttons and menus by name, type into fields, press shortcuts (Windows UI Automation; uses the control itself, leaving your mouse alone where possible). Before clicking or typing on screen, the character points at the spot.
- **Its own browser:** Microsoft Edge driven by Playwright with a separate profile in `~/Compii/browser-profile` (never your logins): open, read, click, fill. Submitting a form counts as *sending* and always asks.
- **Never types secrets:** passwords, PINs, card or bank numbers and one-time codes are refused; Compii asks you to enter them yourself.
- **Autonomy dial:** each action is `read`, `create`, `change`, `send`, `spend` or `delete`. Defaults: reads and creates just happen; changes ask once per task; sending, spending and deleting ask every time. Spending can never be set to "just do it".
- **Journal + undo** of every action in `~/Compii/journal.jsonl`.
- **Stop** a task or everything at any moment; nothing else runs after Stop.
- **Safety:** binds to `127.0.0.1` only and requires a per-install token (`~/Compii/core-token`). File tools are limited to Downloads, Documents, Desktop, Pictures and `~/Compii`.

## Run

```powershell
cd compii_core
$env:ANTHROPIC_API_KEY = "..."   # or an `ant auth login` profile
uv run compii-core
```

Then start the app (`flutter run -d windows` in `compii_flutter/apps/companion`). It connects automatically and reconnects if Core restarts.

**Email:** without SMTP settings, Compii opens a ready draft in your mail app and says it was *not* sent. To let it send, set `COMPII_SMTP_HOST`, `COMPII_SMTP_PORT`, `COMPII_SMTP_USER`, `COMPII_SMTP_PASSWORD` and optionally `COMPII_SMTP_FROM`.

**Rehearsal mode** (`$env:COMPII_BRAIN = "rehearsal"`) replaces Claude with a scripted invoice run for testing the app without credentials. The app labels it clearly as not AI.

## Voice (free, local)

No paid voice service. Everything runs on this PC and audio never leaves it:

- **Listening:** [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (`base.en`, 145 MB). Push-to-talk with a live transcript (`/voice/listen/start`, `/voice/listen/stop`, events `voice_partial`, `voice_final`).
- **Speaking:** [Piper](https://github.com/OHF-Voice/piper1-gpl) (64 MB) is the fast voice: it synthesizes faster than real time on a CPU, so speech keeps up with the answer. [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) (Apache-2.0, 120 MB) is the warmer, more expressive voice. Without either, the voice built into Windows is used. Speech starts from the first finished sentences while the rest of the answer is still being written; approval questions are spoken, and the mic, Stop, or `/voice/quiet` interrupt immediately.
- Models download only when you press the buttons in the app's Settings → Voice (`POST /voice/download`), into `~/Compii/models`.
- **Hands-free "Hey Compii"** (off until you turn it on in Settings → Voice): while idle only the microphone's loudness is measured; short bursts of speech are read by the same local Whisper model, primed for the name, and loosely matched ("hey / hi / ok Compii", "Compy"…). Say the request in one go ("Hey Compii, tidy my Downloads") or wait for "Yes?" and talk; it sends when you stop. Nothing is recorded or stored, and it pauses while Compii speaks. Measured here: 5 of 5 wake phrases, 0 of 12 look-alike sentences, about 3% of one CPU core while idle.

## Thinking ahead

Stored in `~/Compii/proactive.json` and checked every 20 seconds:

- **Routines:** plain-language schedules ("every weekday at 8:30, …"). Compii turns your words into a schedule (`create_routine`, which asks your OK like any standing change) and runs the instruction on time. Normal approvals still apply; a routine that needs you posts an update.
- **Watches:** *folder* (new files matching a pattern) and *web* (a page starts saying something, or changes) are checked locally for free; *AI* watches use Claude and run at most every 30 minutes, reporting only when the answer is YES.
- **Daily brief:** at your chosen time, a local summary of what needs you, what got done, what watches caught, what's on today and what's new in Downloads.
- **Updates inbox:** everything above lands in `/proactive` → `inbox`, is pushed to the app as an `update` event and, with spoken replies on, is said out loud.

## The cursor buddy (main way to use Compii)

Like Clicky: **hold Ctrl + Alt in any app and talk; let go to send.** Or tap Ctrl + Alt once and just talk; Compii
sends when you pause. A small Orbling appears beside your mouse pointer, shows your words as you speak, says
"On it." right away, then answers out loud in a speech bubble and points at what it's talking about. The Compii
window can stay closed (closing it only hides it; Quit is in Settings). The app starts Core by itself.

- **Screen-aware:** the moment you press, Core notes the window you're in (items, labels and positions, never
  password fields or password managers). The AI answers about it and points by item id, so it never guesses
  pixels. Nothing is stored after the turn.
- **Hears you better:** a quick live preview while you talk, then a careful pass primed with words from your screen.
  Words the two passes disagree on are flagged, so Compii asks "did you mean X or Y?" instead of guessing.
- **Natural voice:** whole sentences with a breath between them; markdown, links and paths are never read out.
- **Research:** `search_web` and `read_web_page` work with every AI (free, keyless). "Deep research" plans
  sub-questions, reads several sources and saves a report with sources to Documents.
- Ctrl + Fn can't be used: on most laptops Fn never reaches Windows. Ctrl + Alt is the same idea.

## Brain: free local AI or your own key

Settings → Brain (`GET/PUT /brain`) picks who thinks: **Claude**, a **free local model** through
[Ollama](https://ollama.com) or LM Studio (nothing leaves the PC, no cost), or OpenRouter, OpenAI or any
OpenAI-compatible server. **Test** (`POST /brain/test`) sends one tiny request and reports whether the model can
use tools (small models that can't still chat, but can't do tasks). A **backup AI** is used only if you turn it on;
Compii never silently moves from a local model to a cloud one.

API keys go to **Windows Credential Manager** (`PUT /keys/{anthropic|openrouter|openai|custom}`), are
write-only (never sent back to the app or written to Compii's files), and only the app on this PC can set them.
`ANTHROPIC_API_KEY` in the environment still works too.

## Safety outside the model

- **Never, whatever anyone says** (enforced in code): pressing lock/sign-out/shutdown shortcuts, installing
  software or editing the registry, opening security settings, pressing pay/checkout buttons, typing secrets.
- **Untrusted text:** whatever Compii reads from files, windows and web pages is wrapped as data for the AI.
  Text that looks like instructions to an AI is reported once, and sending, deleting or paying in that task then
  need a fresh okay even if a rule or the dial would allow them.
- **Redaction:** card numbers (Luhn-checked), API keys, private keys and ID numbers are hidden before tool output
  reaches the AI; the conversation says when this happened.
- **Always allow:** approval cards offer it (from this PC only). A rule covers one tool on one folder, site, window
  or set of recipients, never payments, and is listed and removable in Safety (`/safety`, `DELETE /rules/{id}`).
- **Kill switch:** Ctrl+Alt+Shift+S (or `POST /killswitch`, also from a paired phone) stops every task, silences
  Compii and puts it in lockdown: every action asks and rules are paused until you lift it on this PC.
- **Activity record:** `~/Compii/audit/audit.jsonl` is append-only and SHA-256 hash-chained, with redacted
  arguments; `GET /audit` shows it and says whether the chain is intact.

## Skills and walkthroughs

- **Skills** ("teach once, repeat"): save any finished conversation (`POST /tasks/{id}/skill`) or ask Compii to
  "remember how to do this". Skills are listed to the AI by name (`use_skill`), can be run now, and promoted to a
  routine once they work (`POST /skills/{id}/routine`). Stored in `~/Compii/skills.json`.
- **Walkthroughs** ("teach me to…"): `start_walkthrough` points at each step on your screen, says it, waits while you
  do it, checks with UI Automation (an item appears/disappears or a window opens), gives a hint if you're stuck, and
  moves on. Progress is saved in `~/Compii/walkthrough.json`; it pauses rather than guessing when an item isn't there.

## Point at something

`POST /point` with `{"target": "File", "message": "..."}` (or exact `x`, `y`, `w`, `h` in screen pixels) makes the character point at it. The app's desktop overlay draws this on Windows.

## Test

```powershell
uv run pytest
```
