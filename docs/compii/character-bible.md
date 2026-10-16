# Compii — Character Bible

Version 1 · 16 October 2026 · Replaces Wisp (retired) and the chameleon draft (rejected: based on a real animal)

![Character sheet](build-previews/compii-character-sheet.png)

## Who Compii is

Compii is an **Orbling**: a small invented creature that carries its own orbit. It doesn't exist anywhere else, it isn't a person, a robot, a ghost or a real animal.

- **Body:** a soft indigo gumdrop with one curl on top. The curl is its signature, so it's recognisable from the outline alone at any size (see the silhouette test on the sheet).
- **Hands:** cream mittens that float free of the body, tied to it only by an indigo cuff. Free hands can go and do things: point at a button, type, carry a file.
- **Motes:** golden specks that orbit it like a ring. **Each mote is a job Compii is doing.** Three tasks running means three motes. The front of the ring passes across its belly and the back passes behind its head, so the motes never cover the face.
- **Feet:** two small nubs. Compii stands on the ground; it doesn't drift like a ghost.

Personality: calm, curious, quietly witty, and very capable. It does the work and tells you plainly what happened.

## Where the idea comes from

| Reference | What we kept |
|---|---|
| **Bluey** (Riley Brown's open-source app at this repo's root) | Big expressive eyes filling the phone, coordinated with the desktop |
| **HeyClicky** | A buddy that points at what matters on your screen; the free mittens do the pointing |
| **J.A.R.V.I.S.** | Real capability and background work; the motes make that work visible |

## Research behind the design

| Lesson | Source | How Compii applies it |
|---|---|---|
| Invented non-human characters avoid the uncanny valley and give room for expression | Microsoft's Mico (Copilot, 2025); Tolan's alien companion | An invented creature, not a person or animal |
| Silhouette first: it must read as a solid black shape at thumbnail size | Character-design practice (80.lv, RocketBrush) | Gumdrop body and curl tested at 90, 48 and 24 px |
| Shape language: round = friendly; one point adds energy | Same | Rounded body, one pointed curl |
| The character should *be* the product loop, not decoration | Finch, Duolingo | Motes show live tasks; mood shows task state |
| Clippy failed on behaviour: interrupting, pointless idle animations, condescension | Clippy retrospectives (The New Stack, CIO) | Calm idle, no attention-seeking, never interrupts; speaks only when there is news or a question |
| Simple forms survive every context and medium | Kirby analysis | Built from a handful of shapes; drawn in code at any size |

## Moods

Colour is never the only signal: the face, hands and motes change together, and the label stays on screen.

| Mood | Face | Hands | Motes |
|---|---|---|---|
| Ready | relaxed smile, occasional blink | resting at its sides | one gold mote, slow |
| Thinking | eyes up and to the side, small "o" | one hand on its chin | three blue motes, fast, plus thought dots |
| Working | focused eyes, tongue-tip of concentration | both hands out, tapping like typing | one gold mote per running task |
| Needs you | wide eyes on you, inner brows raised | one hand raised, waving | amber, pulsing; a small question card |
| Done | happy closed eyes, open smile | both hands up | motes burst into sparkles |
| Problem | small pupils, worried brows, wobbly mouth | scratching its head | red mote; a sweat drop |
| Offline | eyes closed, asleep | tucked in | one grey mote resting on the ground; "z" |

## Palette

| Name | Hex | Use |
|---|---|---|
| Orbling indigo | `#4B3FE0` | Body (identity colour; never changes with mood) |
| Indigo deep / light | `#3226B8` / `#7468F0` | Volume and highlight |
| Mitten cream | `#FFF1DA` | Hands |
| Mote gold | `#FFC94D` | Motes, sparkles |
| Cheek coral | `#FF8FA3` | Cheeks, tongue |
| Ink | `#15122E` | Eyes, mouth, brows |

## Behaviour rules

1. Idle is calm: slow breathing and one slow mote. No bouncing for attention.
2. It speaks only when there's news (done, problem) or a question (needs you).
3. The hands point at the thing being discussed; they never cover text the user needs.
4. Motes always match the real number of running tasks; never decorative.
5. Reduced-motion setting freezes all movement but keeps every mood readable.

## Implementation

Drawn in code (no image files): `compii_flutter/apps/companion/lib/src/console/character.dart` (`Orbling`, `CharacterSlot(mood, jobs)`). Render the sheet with:

```bash
flutter test test/character_capture_test.dart --dart-define=CAPTURE=true
```

### Phone Face View (built)

On phones (shorter side under 600 px) the screen *is* Compii's head: curl peeking in at the top, eyes filling the middle, hands rising from the bottom edge when they say something, motes drifting across the front. Status, speech, approvals, the command box, mic and Stop float over it; tasks open in a sheet. Desktop can preview it with the phone button. Previews: `build-previews/phone-landscape-working.png`, `phone-landscape-needs-you.png`, `phone-portrait-done.png`.

### Desktop pointing overlay (working)

- **Works:** Core's `point_at` tool finds a button or menu by its visible label through Windows UI Automation (verified live on Notepad's File menu and an IDE's Help menu) and sends a `point` event; the overlay draws the Orbling beside the item with its mitten reaching out, a ring around the item and a bubble (verified in a rendered test, `build-previews/desktop-pointing-overlay.png`).
- **Window:** the overlay is a small borderless, always-on-top popup that never takes focus. It shows on the real desktop with transparency around the character, and clicks pass through it (verified live in Core's rehearsal mode via `POST /point`). Flutter draws through DirectComposition, which shows nothing in a window that is already layered when its surface is created. So the runner makes the popup layered and click-through (`WS_EX_LAYERED | WS_EX_TRANSPARENT`, alpha 255) only after the first frame is on screen (`Win32Window::Show`). The app starts the overlay automatically on Windows.
