# Compii Core

The local service that does the work behind Compii's character. The Flutter app (`compii_flutter/apps/companion`) is the face; Core is the hands.

- **Agent loop** on Claude (`claude-opus-5-5`, adaptive thinking, server-side refusal fallback), with web search.
- **Tools:** list/find/read files (text, PDF, Excel), write files, create folders, move (undoable), create Excel spreadsheets with formulas, run Python scripts in the workspace, open files/URLs/known apps, send email, remember/recall facts, and point at a button or menu on screen by its label (Windows UI Automation).
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
- **Speaking:** [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) (Apache-2.0 open voice model, 120 MB) when downloaded; otherwise the voice built into Windows. Replies and approval questions are spoken; the mic, Stop, or `/voice/quiet` interrupt immediately.
- Models download only when you press the buttons in the app's Settings → Voice (`POST /voice/download`), into `~/Compii/models`.

## Point at something

`POST /point` with `{"target": "File", "message": "..."}` (or exact `x`, `y`, `w`, `h` in screen pixels) makes the character point at it. The app's desktop overlay draws this on Windows.

## Test

```powershell
uv run pytest
```
