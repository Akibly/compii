# Design v5: the workspace

October 2026. **Aligned with the Halo canvas the user approved** (https://claude.ai/artifact/Dn4sj3gMELBSpxr9GCXiNJ, boards Home, Work, Team, Approval): where this page and the canvas differ, the canvas wins. Replaces the look of v4 (purple-tinted night, a glowing crystal on the home screen, thirteen destinations in the sidebar). The behaviour underneath is unchanged; this is about how Compii presents its work and how you reach it.

Reference: the editor-and-agent tools people now spend their day in (Cursor, Linear, Raycast). Not their branding: their discipline. The work is the interface, chrome is quiet, everything is one keystroke away.

## Principles

1. **The conversation is the product.** What Compii did appears in the thread as a readable record: the plan, each step with what it touched, the files it made, the approval it needs. Not a progress bar and a status word.
2. **Few places, one palette.** Four destinations instead of thirteen. Everything else is a tab inside one of them, or a command in Ctrl+K.
3. **Quiet surfaces, loud meaning.** Neutral greys with no hue. Colour appears only when it means something: blue is Compii acting, amber is "needs you", red is a failure or danger, green is done.
4. **Dense, not cramped.** 13 px body text in lists and chrome, 14 px in the thread, a 4 px grid, hairline borders, no drop shadows on resting surfaces.
5. **Keyboard first, pointer welcome.** Every destination and every frequent action has a shortcut, and the shortcut is shown where the action is.
6. **Nothing decorative moves.** Motion confirms a change and stops. The one glow is the halo itself, Compii's face, as the canvas draws it.

## Information architecture

The sidebar, as on the canvas: a search box (Ctrl+K), the chats grouped by day, and at its foot **Team** (faces of the teammates and how many are working), **Activity** and **Settings**. New chat is the + beside Compii's name. The four places below are what those lead to.

| Before (13) | After (4) |
| --- | --- |
| Home, Chat | **Chats**: every conversation, newest first, searchable; the new-chat composer is the empty state |
| Team | **Agents**: Compii and its teammates, each with its own chats, role, tools, trust and memory |
| Updates, Timeline, Clips | **Activity**: updates, the timeline of what happened, approvals waiting, clips |
| Routines, Skills, Library, Knowledge, Research, Memory, Safety, Settings | **Settings & tools** (one page with tabs): Routines · Skills · Library · Knowledge · Research · Memory · Safety · Settings |

The sidebar holds the four destinations, then the recent chats list (the thing you return to most), then the agents. Ctrl+K reaches every old destination by name, so nothing became harder to find for someone who knows its name.

## Layout

```
┌───────────── 248 ─────────────┬──────────────────── fluid ─────────────────────┬──── 320 (optional) ────┐
│ Compii            ⌘K  ⊕       │  Chat title · agent · status          ⋯        │ Plan · Files · Sources │
│ ▸ Chats      Ctrl+1           │                                                │                        │
│   Agents     Ctrl+2           │  You   Sort the receipts in Downloads          │  ✓ Find receipts       │
│   Activity   Ctrl+3   2       │                                                │  ● Build the sheet     │
│   Settings   Ctrl+,           │  ✓ Read 14 files in Downloads          ▸       │  ○ Total it            │
│ ─────────────                 │  ● Building receipts.xlsx …            ▸       │                        │
│ TODAY                         │  ┌ Needs you ─────────────────────────────┐   │  receipts.xlsx         │
│   Sort the receipts   ●       │  │ Send email to ama@…   [Allow] [Deny]   │   │                        │
│   Kumasi packing list         │  └────────────────────────────────────────┘   │                        │
│ YESTERDAY                     │                                                │                        │
│   …                           │  ┌──────────────────────────────────────────┐ │                        │
│                               │  │ Ask Compii…            @  ⎘  🎙  Compii ▾ │ │                        │
│ AGENTS  Compii · Scout · …    │  └──────────────────────────────────────────┘ │                        │
└───────────────────────────────┴────────────────────────────────────────────────┴────────────────────────┘
```

## Tokens (v5)

Night is the default. Both themes are neutral: no tinted greys.

| Token | Night | Light | Use |
| --- | --- | --- | --- |
| canvas | `#050507` | `#FFFFFF` | window, thread |
| surface | `#09090C` | `#F7F7F8` | sidebar, side panel |
| raised | `#0E0E12` | `#FFFFFF` | composer, cards, menus |
| sunken | `#0B0B0F` | `#F2F2F3` | inputs, code |
| hover | `#15151B` | `#EEEEF0` | rows under the pointer, selection |
| border | `#FFFFFF` 6% | `#000000` 8% | hairlines |
| text | `#F5F5F7` | `#18181B` | ink |
| muted | `#A9A9B3` | `#5B5B63` | secondary text |
| faint | `#8E8E99` | `#76767E` | captions, shortcut hints |
| accent | `#3D8BFF` (the halo blue) | `#2563EB` | Compii acting, focus, links |
| warning | `#FF9B3D` | `#9A4A06` | needs you |
| danger | `#FF5A4E` | `#DC2626` | failed, destructive |
| success | `#3BE08F` | `#15803D` | done |

Type: Segoe UI Variable. 12 caption, 13 UI, 14 thread body, 16 section title, 22 page title. Weights 400/500/600; no 700+ outside the page title. Radii: 6 for controls, 8 for cards and menus, 12 for the composer and dialogs.

## How the agent presents its work

- **Steps are rows, not bubbles.** Each tool call becomes one row: a status mark (✓ done, ● running, ✕ failed, ⏸ waiting), a plain sentence ("Read 14 files in Downloads"), and a chevron that opens the detail (what it read or changed, the exact result). Consecutive reads fold into one row ("Read 6 files").
- **Files are chips.** Anything Compii made or changed shows as a file chip under its step: name, folder, open and reveal.
- **Approvals are inline cards with the exact action**, the kind (send, change, delete), and Allow / Always for this / Deny on the keyboard (Enter, A, Esc).
- **The answer is the last thing**, in the thread's body type, never in a bubble. Your own messages sit in a quiet filled block, not a coloured bubble.
- **The plan lives in the side panel** while a task runs, and collapses into the thread when it ends.

## Shortcuts

| Keys | Does |
| --- | --- |
| Ctrl+K | command palette: any chat, agent, page or action |
| Ctrl+N | new chat |
| Ctrl+L | focus the composer |
| Ctrl+1 / 2 / 3 | Chats / Agents / Activity |
| Ctrl+, | Settings & tools |
| Ctrl+\ | show or hide the side panel |
| Esc | stop the running task (with the composer empty) |

## Rollout

1. Tokens and type scale (every screen changes at once). 
2. Shell: four destinations, the sidebar chat list, shortcuts.
3. Chats home: the composer as the empty state; drop the crystal and the glow.
4. Thread: step rows, file chips, inline approvals, quiet user blocks.
5. Side panel for plan, files and sources.
6. Island and buddy follow the same tokens (their own geometry stays).

Each step keeps the widget tests passing and updates the capture images, so the pictures in `build-previews/` stay true.
