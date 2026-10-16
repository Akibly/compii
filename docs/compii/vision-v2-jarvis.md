# Compii v2 — From tutor to Jarvis

Draft · 15 October 2026 · Replaces the "learning companion" direction once approved

## What changed

You rejected the tutor framing. Compii's main job is no longer *teaching*. It is a **very capable personal operator that does what you ask**, across your computer, your accounts and your phone, the way J.A.R.V.I.S. runs Tony Stark's workshop. Teaching survives only as one skill ("show me how"), not a mode on the front page.

The six planning documents and the benchmark were written for the old direction. They will be rewritten after you approve this one.

## What the market looks like (October 2026)

| Product | What it does well | Where it falls short of Jarvis |
|---|---|---|
| **Claude desktop (Cowork + computer use)** | Operates your real desktop and local files; background mode on Mac | Lives inside a chat app; no voice-first presence; Anthropic models only |
| **ChatGPT Work** | Broadest all-round agent; computer use on Mac/PC; Chrome extension | Chat-window centric; message caps; OpenAI only |
| **Gemini Spark + Daily Brief** | Truly proactive: works 24/7 in the cloud across 30+ apps, morning briefings | Cloud and Google-account centric; weak on your local PC |
| **Windows Copilot Actions + agent workspace** | OS-level: agents run in a separate sandboxed desktop session with their own account; native MCP connectors for Files and Settings | Preview; Microsoft's own docs call it risky; Copilot only |
| **Manus "My Computer"** | Local files, terminal and apps on Windows 11 and Mac; "Allow once / Always allow" | Credit pricing is unpredictable |
| **Perplexity Comet** | Background assistant grinds through a to-do list in the browser | Browser only; reported failure rate near a third on hard delegated jobs |
| **OpenClaw** (open source) | Self-hosted; reachable from 20+ messaging apps with shared memory; plain-language scheduled jobs; any model | Developer setup; security is on you |
| **Clicky / OpenClicky** | Lovable cursor buddy that points at things and talks | Mostly a guide, not a doer |
| **Fazm** (open source, Mac) | Voice-first desktop agent; uses accessibility APIs instead of screenshots | Mac only, small community |
| **Screenpipe / Omi** | Memory of everything on screen and in conversations; feeds agents via MCP | Memory, not action; privacy debates |
| **Windows-MCP** (open source) | Controls Windows through the UI Automation tree, so any model can click by element, not pixel | Apps with poor accessibility expose little |
| **Open-source "Jarvis" repos** | Wake word, local Whisper/Kokoro/Piper, Iron-Man HUDs, dozens of tools, undo | Hobby quality; no trust model |
| **Humane AI Pin, Rabbit R1** | — | Failed: slow, wrong answers, demoed features that didn't work, no reason to exist beyond the phone |

## Ten lessons from others

1. **Hands beat eyes.** Tools that use APIs, connectors, the accessibility tree and the browser DOM are faster and far more reliable than clicking on screenshots. Vision clicking is the last resort (Fazm, Windows-MCP, Gemini/Mariner).
2. **Don't steal the mouse.** The best agents now work *behind* you: a background desktop session, a headless browser, or direct API calls (Claude background mode, Windows agent workspace, Comet).
3. **Proactive is the new frontier.** Briefings, watches and scheduled jobs are what make an assistant feel like Jarvis instead of a chatbot (Gemini Spark, Pulse, OpenClaw).
4. **Be reachable everywhere.** Jarvis talks to you wherever you are. OpenClaw's biggest draw is talking to it from WhatsApp or Telegram with the same memory.
5. **Voice must be instant and interruptible.** Realtime speech models now answer in about 300–600 ms. Anything slower feels broken (the Humane lesson).
6. **Memory is what makes it personal.** Knowing your projects, people and preferences is the difference between an assistant and a search box (Screenpipe, Omi).
7. **Verify every step.** Agents that assume an action worked fail silently. A fresh check after each action measurably improves success.
8. **Prompt injection is real.** Web agents followed planted instructions in 16–86% of benchmark cases. Text on screen or in a page must never be allowed to widen what the agent is permitted to do.
9. **Graduated trust, not constant nagging.** "Allow once / Always allow" per kind of action (Manus) keeps it fast without being reckless.
10. **Never demo what doesn't work.** Rabbit and Humane died on the gap between the keynote and reality. Ship fewer things that always work.

## The opportunity

The big labs build agents that live inside *their* chat app and *their* model. Nobody owns **"Jarvis for your PC"**: one always-present, voice-first operator that

- is native to Windows and controls the whole machine, not just a browser tab;
- works with any model (Claude, GPT, Gemini, local);
- has a face and personality on your desk and on your phone;
- remembers your life and work;
- acts on its own schedule and in the background;
- can be reached from anywhere.

That is Compii.

## Compii v2 — the concept

**One line:** *Compii is your personal Jarvis: tell it what you want, and it gets done.*

### 1. Always there
- **"Hey Compii"** wake word (local, offline detection) plus push-to-talk and a `Ctrl+Space` command bar.
- **Realtime voice:** answers in under a second, can be interrupted mid-sentence, holds a back-and-forth conversation while working.
- **Phone as remote:** speak to it from your phone, see live task progress, approve actions, get notified when work is done.
- **Messaging:** talk to it from Telegram or WhatsApp with the same memory.

### 2. Hands — does real work
A **tool ladder**: it tries the most reliable route first.

| Rung | Examples |
|---|---|
| 1. Direct connectors | Gmail, Outlook, Google/Microsoft calendar, Drive, OneDrive, Notion, Slack, GitHub, Spotify |
| 2. MCP servers | Any of thousands of MCP tools; Windows native MCP connectors |
| 3. Code and shell | Writes and runs scripts in a sandbox: files, data, conversions, batch jobs |
| 4. App control by element | Windows UI Automation tree (click "Save" by name, not by pixel) |
| 5. Browser control by page structure | Own browser profile, logged-in sessions, forms, downloads |
| 6. Vision clicking | Screenshot + click for apps nothing else can reach |

### 3. Works in the background
- Several tasks at once in a **Task Center** with live progress, logs and a Stop button.
- Uses its own browser profile and a separate desktop session where possible, so you keep your mouse and keyboard.
- Long jobs ("research these 40 companies and build a spreadsheet") keep running and report back.

### 4. Knows you
- **Memory:** people, projects, preferences, decisions, things you said. Viewable, editable, deletable.
- **Screen context on demand:** "what am I looking at?"; optional opt-in work memory of recent screens.
- **Files:** indexes chosen folders so it can find and use your documents.

### 5. Thinks ahead
- **Daily brief:** calendar, important mail, task status, anything it noticed — spoken or on screen.
- **Watches:** "tell me when this price drops", "when Sam replies, draft an answer".
- **Routines:** plain-language schedules ("every Friday at 5, tidy Downloads and send me the week's summary").
- **Suggestions:** offers help when it notices something, at the level you choose (off / suggest / do it).

### 6. Builds itself new skills
- When no tool exists, it writes one (a script or small MCP tool), tests it, and saves it as a **skill** you can reuse.
- **Learn by watching:** you do a task once while it records; it turns that into a repeatable skill.

### 7. Trust built in, not bolted on
- **Autonomy dial per kind of action:** read · create · change · send · spend · delete. Each set to *Ask every time*, *Ask once per task* or *Just do it*.
- Money, deleting and sending to new recipients always ask by default.
- **Action journal and undo** for files and settings it changed.
- Text in web pages, emails and documents is treated as information, never as orders.
- Visible indicators whenever it listens, sees or acts. One Stop word / hotkey halts everything.

### 8. Still teaches — when you ask
"Show me how to do this myself" switches to step-by-step guidance with pointing and checking. It's a skill, not the headline.

## Presence

Compii is a **character** with a personality, not a Jarvis-style HUD. "Jarvis" describes what it can *do*.
**Wisp is retired**, and a chameleon draft was rejected because it is a real animal (user decisions, 16 October 2026). Compii is now an **Orbling**: an invented creature with a gumdrop body, a signature curl, free-floating mitten hands, and golden motes orbiting it, one per running task. Full design, research and mood system: [Character Bible](character-bible.md).

- **Desktop:** the character is the centre of the app and speaks in bubbles; command bar below; Task Center beside it with live steps, approvals and Stop.
- **Phone:** large-face view by default, full-body optional; the phone is also the remote (talk, watch tasks, approve).

## Feature map

| Tier | Features |
|---|---|
| **Core (first release)** | Wake word + realtime voice + command bar · tool ladder rungs 1–5 · Task Center with background tasks · memory · daily brief · watches and routines · autonomy dial + journal + undo · phone remote · 2+ model providers |
| **Next** | Vision clicking · messaging channels (Telegram/WhatsApp) · self-built skills · learn by watching · meetings (record, summarise, follow up) · document/slide/spreadsheet creation · local models |
| **Later** | Ambient work memory · smart home · Mac/iPhone and Linux · multi-agent teams for big jobs · skill sharing between users |

## How it's built

```
 Flutter app (Windows + Android)          Compii Core (local service)
 ┌──────────────────────────────┐   ws   ┌───────────────────────────────────┐
 │ HUD / character · command bar│◄──────►│ Agent loop (model-agnostic)        │
 │ Task Center · approvals      │        │ Tool ladder: connectors, MCP host,  │
 │ Phone remote                 │        │   sandboxed code, Windows UIA,      │
 └──────────────────────────────┘        │   browser (Playwright), vision      │
                                         │ Voice: wake word, realtime S2S      │
                                         │ Memory: SQLite + vector index       │
                                         │ Scheduler: watches, routines, brief │
                                         │ Policy: autonomy dial, journal, undo│
                                         └───────────────────────────────────┘
```

- **Flutter stays** for the interface (Windows desktop + Android phone), since you chose it.
- **Compii Core** is a separate local service, recommended in **Python**: the strongest ecosystem for Windows UI Automation (Windows-MCP, pywinauto), Playwright, local wake word and speech, and every model SDK.
- Models: Claude as the default agent brain; OpenAI and Gemini adapters; realtime voice from OpenAI or Gemini; optional local models via Ollama.

## First build slice (proposed)

"Hey Compii, find last month's invoices in my Downloads, total them in a spreadsheet, and email it to me."

1. Compii Core service with the agent loop and one model provider.
2. Tools: files, sandboxed Python, web search, browser, Windows app launch and UIA control.
3. Command bar + voice (push-to-talk first, wake word next) in the Flutter app.
4. Task Center showing the steps live, with approval for sending email and a Stop button.
5. Journal of every action.

This proves the core promise — *say it, and it gets done* — before anything else.

## Decisions

Decided 16 October 2026: Compii is an Orbling, an invented character (Wisp and the chameleon draft retired) · Python for Compii Core · Claude as default brain · name stays Compii.

## Sources

[Computer-use agents 2026 compared](https://fast.io/resources/best-computer-use-ai-agents-2026/) · [Claude vs OpenAI vs Gemini agents](https://www.digitalapplied.com/blog/computer-use-agents-2026-claude-openai-gemini-matrix) · [Windows agent workspace & Copilot Actions](https://windowsforum.com/news/windows-11-agent-workspace-and-copilot-actions-preview-explained.397580/) · [Windows native MCP](https://windowsforum.com/threads/windows-11-native-ai-agents-via-mcp-in-insider-preview.392914/) · [Gemini Spark & Daily Brief](https://blog.google/innovation-and-ai/products/gemini-app/next-evolution-gemini-app/) · [ChatGPT Pulse](https://www.datamation.com/artificial-intelligence/openai-chatgpt-pulse/) · [Manus My Computer](https://gigazine.net/gsc_news/en/20260317-manus-my-computer) · [Comet background assistant](https://techcrunch.com/2025/10/02/perplexitys-comet-ai-browser-now-free-max-users-get-new-background-assistant/) · [OpenClaw](https://www.digitalocean.com/resources/articles/what-is-openclaw) · [Clicky Windows port](https://github.com/Bitshank-2338/clicky-windows) · [Fazm](https://www.sourcepulse.org/projects/31217102) · [Screenpipe](https://screenpipe.com/blog/screen-assistant-ai-2026) · [Omi proactivity PR](https://github.com/BasedHardware/omi/pull/11804) · [Windows-MCP](https://themenonlab.blog/blog/windows-mcp-ai-agents-windows-os-control) · [Open-source Jarvis (PanPenek)](https://github.com/PanPenek/JarvisAi) · [Open-source Jarvis (ONEPUNCHMAN411)](https://github.com/ONEPUNCHMAN411/Jarvis/tree/main) · [Realtime voice APIs compared](https://inworld.ai/resources/best-speech-to-speech) · [Prompt injection in computer-use agents (OS-Harm)](https://arxiv.org/pdf/2506.14866) · [CSA note on agent blind spots](https://labs.cloudsecurityalliance.org/research/csa-research-note-computer-use-agent-safety-blindspots-20260/) · [Why Humane and Rabbit failed](https://www.techradar.com/computing/artificial-intelligence/from-the-ai-pin-to-microsoft-tay-5-ai-products-that-ended-in-disaster-and-why-they-failed)

Most market details come from secondary write-ups and vendor pages; product names and availability change fast and should be rechecked before any public claim.
