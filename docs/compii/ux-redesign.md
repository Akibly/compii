# Compii — UX Redesign (v3)

16 October 2026 · Replaces the first console layout, which the user rejected ("designs, UIs, workflows and how it works").

## What the best assistants do

| Product | What they get right | Source |
|---|---|---|
| **Claude Cowork** | Chat in the middle, a **Progress panel** (numbered plan, ticks, current step highlighted) and an **Artifacts** list of every file touched, on the right | [DataCamp](https://www.datacamp.com/tutorial/claude-cowork-tutorial), [Camp Claude](https://camp-claude.github.io/learn/cowork-task-anatomy/) |
| **ChatGPT desktop** | **Alt+Space companion window**: a small floating chat that stays beside your apps, remembers its spot, and syncs with the main history | [OpenAI help](https://help.openai.com/en/articles/9982051) |
| **ChatGPT agent** | On-screen narration of each step; **pauses for confirmation** before purchases, sending, deleting; take over / stop any time | [OpenAI](https://openai.com/index/introducing-chatgpt-agent/), [help](https://help.openai.com/en/articles/11752874-chatgpt-agent) |
| **Raycast AI** | Keyboard-first: one hotkey, type, Enter; result actions (copy, paste into app) under a shortcut | [Raycast manual](https://manual.raycast.com/windows/raycast-ai) |
| **HeyClicky** | Mostly invisible UI: hotkey, speak, a pointer **lands beside** the thing; replies are **1–2 spoken-style sentences**; follow-ups remember context | [How Clicky works](https://isaacflath.com/writing/how-clicky-works) |
| **Gemini / Siri 2026** | Clean, conversation-first; pill prompt box; voice on the right | [9to5Google](https://9to5google.com/2026/05/03/gemini-full-redesign/) |
| **Copilot** | **Retired its Mico avatar** from default voice mode for a plainer, conversation-first screen | [TechBuzz](https://www.techbuzz.ai/articles/microsoft-retires-mico-avatar-from-copilot-voice-mode) |

Agent-UX practice ([setproduct](https://www.setproduct.com/blog/ai-agent-ui-design-patterns), [Smashing](https://www.smashingmagazine.com/2026/02/designing-agentic-ai-practical-ux-patterns/)): editable/visible plan; live step ledger collapsed to one line; tool cards; tiered permission badges with a destructive dialog that *looks different*; diff-first result summary; per-action undo; a background pill that separates "working" from "waiting on you".

## Decisions

1. **Conversation first, character as companion.** The Orbling stays, smaller: avatar in the header and thread, large only on the empty Home and the phone Face View. (Copilot's Mico retirement is the warning.)
2. **Three surfaces, one brain**
   - **Quick Bar** — `Alt+Space` from anywhere: a floating pill with the Orbling, type and go; the answer appears under it; *Open in Compii* continues in the full window.
   - **Buddy** — the pointing overlay beside your cursor's target (built).
   - **Workspace** — sidebar · conversation · Progress panel.
3. **Conversations, not one-shot tasks.** Follow-ups continue the same thread with full context.
4. **Plan first.** For anything over two actions, Compii shows its plan (checklist) before and during work.
5. **Steps stay quiet.** One line ("Working · 4 steps") that expands into tool cards.
6. **Approvals stand out** by tier: *change* (amber), *send* (indigo), *delete / spend* (red, different layout). They show exactly what will happen.
7. **Results lead with what changed** ("Created 1 spreadsheet · Drafted 1 email") and file chips with *Open* and *Show in folder*.
8. **Short replies.** One to three sentences, written to be read in a bubble or heard.
9. **Settings you can see:** the autonomy dial, memory you can review and delete, theme.
10. **Dark and light themes,** calm neutrals, one indigo accent, Segoe UI Variable.

## Built (16 October 2026)

| Area | What shipped | Verified |
|---|---|---|
| Design system | `lib/src/ui/tokens.dart`: light and dark themes, Segoe UI Variable, one indigo accent, risk colours | Rendered previews; live in dark mode |
| Workspace | Sidebar (conversations with Working / Needs you / Done, Memory, Settings) · conversation · Progress panel (plan, files, activity) | Live on Windows |
| Conversations | Follow-ups continue the same thread with full context (`POST /tasks/{id}/messages`) | Live + tests |
| Plan first | `update_plan` tool; checklist in the Progress panel and the quick bar | Live + tests |
| Quiet steps | One-line ledger ("Worked for 18s · 4 steps") that expands into steps with risk badges | Previews |
| Approvals | Tiered cards (change / send / delete-spend with a different layout); file names before full paths; compact layout on phones | Live click on Approve |
| Results | "1 file created" summary, file chips with Open and Show in folder, Undo | Previews; Core endpoints tested |
| Quick bar | `Alt+Space` turns the window into a floating, always-on-top bar; answers grow under it; Esc closes; Open in Compii continues | Rendered; **hotkey not yet tried live** |
| Memory | Review and delete what Compii remembers | Core tests; page rendered |
| Settings | Autonomy dial per action kind (spending can't be set to "just do it"), theme, shortcuts | Page rendered |

Previews: `build-previews/v3/`.

## Voice and interactivity (16 October 2026)

- **Free, local speech:** faster-whisper for listening, Kokoro (or the built-in Windows voice) for speaking. No accounts or per-use costs; audio stays on the PC. Optional downloads (145 MB + 120 MB) start only from Settings → Voice.
- **Talk to it:** click the Orbling, the mic (tap to start and tap to send, or hold and release), or press **Ctrl + Alt + Space** anywhere. Your words appear live in the message box with a level meter; release sends them to the open conversation or starts a new one.
- **It talks back:** answers and approval questions are spoken. Clicking it, the mic or Stop interrupts at once (measured 0.36 s on the Windows voice).
- **Alive:** eyes follow the mouse; it leans in and listens while you type; listening (mittens cupped, sound waves, motes pulsing with your voice) and speaking (mouth moving, gesture) moods.
