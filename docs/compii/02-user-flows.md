# Compii — User Flows

Version 1.0 · 15 October 2026 · Implements [requirements](01-product-requirements.md)

## Main navigation

Desktop surfaces: small companion; quick conversation panel; expanded workspace. Workspace destinations: Tasks, Learn, Research, History, Memory, Devices, Settings. Future features appear only when shipped, not as working controls. No phone is needed for desktop onboarding.

## F01 — First launch (C01, C03–C05)

1. Show Wisp and a short explanation of Compii's three modes.
2. Choose voice or text; text works without microphone permission.
3. Configure an AI provider, model and credentials in a secure settings form. Test credentials without logging them. Display supported capabilities and expected billing destination.
4. Select separate transcription/speech providers if required. A reasoning key does not imply speech support.
5. Request screen and action permissions only when demonstrating those features. Denial leaves chat available.
6. Offer a short practice task; show what screen context will be shared.
7. Offer optional phone pairing. Finish with no recording, schedule or durable personal memory silently enabled.

Failure paths: invalid key offers correction; unavailable model offers a tested alternative without silently changing provider; network failure preserves typed input; skipped permissions remain discoverable in settings.

## F02 — Pair a phone (C11)

Desktop opens Devices > Pair. A QR code contains a short-lived one-time pairing challenge and desktop identity. Phone scans, both devices confirm the identity, and authenticated keys are stored. Discovery alone is not authorization. Manual short code entry is available on the same network.

Choose the active microphone explicitly. Desktop and phone must not stream duplicate audio. Choose the output speaker. Show connected desktop name on phone and active phone on desktop. Multiple remembered phones are allowed; only one controls a live voice session at a time in V1.

On disconnect: indicate disconnection, discard stale remote action requests, and stop sending phone audio. Desktop task execution requiring phone confirmation pauses. Desktop-local use remains available. Reconnection restores presentation and session state, not previously queued clicks. Unpair revokes the device key.

## F03 — Choose phone appearance (C02)

Settings > Companion > Phone presentation has exactly two top-level choices:

| Choice | Presentation | Default |
|---|---|---|
| Face View | Large white eyes and expressive Wisp face fill the display, as in the supplied concept | Yes |
| Full-body View | Entire Wisp is visible inside the Compii scene | No |

Full-body View offers a subordinate motion setting: Float or Rest. Float drifts gently within safe bounds. Rest stays at a user-positioned location. These are behaviors of one presentation, not a third presentation option. Reduced-motion overrides drifting while preserving Full-body View.

Show a live preview. Apply instantly and persist per phone across sessions, app restarts and reconnection. Switching presentations never starts/stops the microphone, changes provider, clears history or creates a new AI conversation. Portrait and landscape both work; landscape is the hero Face View composition. Controls and status remain visible in either mode.

This feature does not mean floating above other mobile applications. Background/lock transitions stop active phone capture and show paused/disconnected status in V1.

## F04 — Ask about the screen (C03, C05)

Press push-to-talk or type > choose relevant window/display > capture > ask > receive a caption and optional speech. Wisp points near the referenced content without covering it. A label indicates when a screenshot is sent to the selected provider. Screen sharing lasts only for the active authorized task/session. New display, excluded application or sensitive context requires a fresh decision.

If a target is ambiguous, show the possible target and ask one concise question. If the screen changed, capture again. Never pretend to see content absent from the current observation.

## F05 — Teach me (C06)

1. Capture the learner's goal and existing level.
2. Establish a short sequence and identify the current application/version where possible.
3. Explain one useful step; highlight the current target and explain why it matters.
4. Wait for the user attempt. Inspect a fresh observation or ask the user to confirm if inspection cannot verify it.
5. Give a hint or alternate explanation on difficulty. Do not repeat the same failed instruction indefinitely.
6. Offer a related practice task and recap what was learned.
7. Save progress if history is enabled; offer to save a durable learning goal separately.

The user may ask for a full solution. Compii should explain it rather than rigidly refusing direct answers. Learning mode does not silently perform the user's steps. Mathematical examples should use calculation tools when results matter.

## F06 — Switch modes (C07)

Teach me > “Do this step with me” retains goal, observations and progress, but requests an action scope. With me presents the next action and explanation. For me executes within an agreed scope, pauses for consequential approval, and verifies the result. Switching back to Teach me cancels pending unexecuted actions. UI labels and mode state update on both devices.

## F07 — Delegate work (C07, C08)

Request > clarify missing essentials > show short task scope and budget > execute supported steps > verify > show result and artifacts. Pause and Stop are always reachable. A global stop shortcut must be configurable and checked for conflicts.

External sends, purchases, destructive changes and account/security changes require a concrete approval card describing target and effect. Approval belongs to that exact action, not all future actions. For ordinary reversible steps inside the agreed scope, do not repeatedly ask.

If the user takes over the mouse or keyboard, pause foreground UI automation. Show waiting status; do not fight for input. “Undo” is available only when a recorded compensating action exists, and its scope is shown before execution.

## F08 — Research (C09)

Question > brief scope/time/cost choice > research progress > report with source links and dates > export/save. Include contradictory findings and uncertain conclusions. If limited by budget, label the report partial and preserve useful findings. A broken page is listed as inaccessible, never cited as if read. Background research should not steal foreground browser focus.

## F09 — Memory and history (C10)

History contains sessions and task results. Memory contains selected reusable facts with their sources. Users can inspect why a fact was used, edit or delete it, export a project, or run a temporary session. Deletion shows local scope and any known external-provider retention limitations. Deleted facts must be removed from retrieval indexes too.

## F10 — Later releases

Meetings: explicitly start > recording indicator > transcript > speaker review > summary > suggested action items > approve any external follow-up. Routines: create > inspect schedule/source/scope/budget > opt in > observe history > pause/delete. Teaching by demonstration: record explicit example > review generated workflow > dry-run > save. None of these flows starts merely because the user mentioned a meeting or habit.
