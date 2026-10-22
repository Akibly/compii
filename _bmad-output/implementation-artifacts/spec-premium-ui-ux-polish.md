---
title: 'Premium UI/UX polish'
type: 'feature'
created: '2026-10-21'
status: 'review'
baseline_commit: '0c758ace6bda4626bfd86cf3790ffddec4fd465b'
route: 'dispatch'
review_loop_iteration: 0
context: ['docs/compii/design-v4.md', 'docs/compii/ui-ux-audit-2026-10-21.md']
---

<frozen-after-approval reason="human-owned intent">

## Intent

**Problem:** Inconsistent responsive layouts, inaccessible custom controls, incomplete recovery states, and visual drift prevent the active Flutter app from feeling premium.

**Approach:** Polish shared components, then affected desktop, phone, onboarding, conversation, and utility flows. Preserve the warm-paper/night-indigo identity, character, functionality, and voice-first interaction.

## Boundaries & Constraints

**Always:** Preserve uncommitted work as authorized. Support light/dark themes, keyboard access, text scaling, platform insets, reduced motion, truthful status, and existing approval rules. Keep all destinations and emergency stop reachable.

**Never:** Replace the identity, change backend policy/contracts, enable permissions, send communications, execute user tasks, alter user data/storage, publish, or rework legacy Swift. Never present widget captures as hardware verification.

## I/O & Edge-Case Matrix

| State | Expected behavior | Recovery |
|---|---|---|
| Narrow desktop | Desktop navigation remains available | Stack/scroll rather than clip |
| Text scale 2.0 | Readable labels and reachable actions | Flexible sizing |
| Long pending decision | Clear hierarchy and reachable buttons | Scroll details; preserve semantics |
| Failed fetch | Error with retry | Retain successful content on refresh failure |
| Unknown safety status | Explicit loading/error | Emergency stop stays available |
| Keyboard/reduced motion | Focus, activation, reverse traversal, quiet transitions | No inaccessible controls |
| Phone transcript plus error | Stacked feedback within safe area | No overlap/repeated insets |

</frozen-after-approval>

## Code Map

Paths below are under `compii_flutter/apps/companion/lib/src/`.

- `ui/tokens.dart`, `chrome.dart`: reuse semantic colors, typography, shapes and shared page/row patterns.
- `console/console_screen.dart`, `ui/shell.dart`: viewport routing, sidebar, home, composer and custom controls.
- `ui/stage.dart`, `thread.dart`, `voice_dock.dart`, `reply_text.dart`: decisions, conversation and reading; preserve cancellation/approval contracts.
- `ui/pages.dart`, `trust.dart`: settings, memory, provider and safety states.
- `ui/proactive.dart`, `clips.dart`, `timeline.dart`, `automation.dart`: utility flows and fetch states.
- `ui/phone_home.dart`, `first_run.dart`, `palette.dart`: phone feedback, onboarding, navigation.
- App `test/`: existing behavior tests and capture fixtures. Repository `docs/compii/design-v4.md` supplies incumbent visual direction.

## Tasks & Acceptance

Execute in order; paths share the Code Map prefix.

- [x] `ui/tokens.dart`, `chrome.dart`: adaptive spacing/rows, consistent controls and reduced-motion convention.
- [x] `console/console_screen.dart`, `ui/shell.dart`: compact navigation, desktop identity under resize, keyboard-accessible controls, refined home/composer hierarchy.
- [x] `ui/stage.dart`, `thread.dart`, `voice_dock.dart`: compact decisions, wrapping actions, readable long responses and constrained file widths.
- [x] `ui/pages.dart`, `trust.dart`: adaptive settings/provider/safety rows, unified hierarchy, honest loading/error/retry.
- [x] `ui/proactive.dart`, `clips.dart`, `timeline.dart`, `automation.dart`: consistent headers/actions and confirmed recovery/empty-state gaps.
- [x] `ui/phone_home.dart`, `first_run.dart`, `palette.dart`: inset/feedback fixes, onboarding wrapping, palette scaling and reverse traversal.
- [x] App `test/ui_polish_test.dart` and affected tests: deterministic matrix regressions and new captures separate from historical v4 images.
- [x] Repository audit document: record outcomes, evidence and device limitations.

**Acceptance Criteria:**
- Given either theme, when navigating all active surfaces, then typography, spacing, controls and semantic colors consistently follow the incumbent design.
- Given existing behavior, when UI changes ship, then pairing, queueing, voice, persistence, approvals and cancellation retain their contracts.
- Given completed changes, when analysis and relevant tests run, then no attributable new failures remain.
- Given previews, when reporting results, then tested states and device limitations are explicit.

## Implementation Notes

The tree already carried most of the shared vocabulary when this spec was picked up: `AdaptiveRow`, `LoadFailure`, `SectionHeader`, `PanelRows`, `EmptyState`, `Space.gutter`, drawer navigation, the compact `ApprovalCard`, and the short/long reply split. What was still open, and what this pass added:

- `Keyable` (`ui/chrome.dart`) — one wrapper for the pointer-only custom controls: focus tab stop, Enter/Space, 44px minimum target, accent focus ring drawn in a `Stack` so it costs no layout, `Semantics(button, selected, enabled, label)`, and skipped entirely when there is nothing to do. Applied to the talk button, mic, say-chips, teammate rows, answer chips, the console face, and routine day-chips.
- `VoiceController.statusFailed` (`ui/voice.dart`) — a failed status fetch is now distinguishable from "not ready", so Voice settings can offer a retry instead of claiming a state it never learned.
- The timeline scrubber takes Left/Right/Home/End with a focus ring (`ui/timeline.dart`); it was the last pointer-only control on an active desktop surface.
- The palette footer became a `Wrap` so the key hints and the result count fall to a second line at large text instead of overflowing.
- Setup: chip progress labels ellipsize, and the voice picker is width-capped inside a horizontal scroll view, matching how the settings `SegmentedButton`s were handled.
- Phone: the screenshot preview announces itself as a button.
- Duplicate helpers removed in favour of the shared ones: `_Page`, `_heading` (trust), `_section` (library), `_Card` and `_Empty` (proactive).

Deliberately not done: `pages.dart` keeps its own `_Card` (it clips children; `Panel`/`PanelRows` do not), the `_DayColumn` week grid still needs a scroll/wrap restructure before it is safe at 2.0 text, routine toggle/run-now failures still report as a toast rather than a persisted error state, and the legacy Swift app was left alone.

## Spec Change Log

## Review Triage Log

## Design Notes

Operate mode: clarity before ornament. Keep the companion expressive on arrival; reduce its footprint for decisions and dense reading. Reuse existing colors, discreet borders/shadows and shared components.

## Verification

- `flutter analyze` → `No issues found`. (Five lint hits left by work in flight were removed: curly-brace flow control in `pages.dart` and `trust.dart`, a redundant interpolation in `phone_home.dart`, a null-aware element in `thread.dart`, an unnecessary import in `timeline.dart`.)
- `flutter test` → 156 passed, 2 skipped, 0 failed (45 suites), including 16 new matrix regressions in `test/ui_polish_test.dart`.
- `flutter test --dart-define=CAPTURE=true test/ui_polish_test.dart` → renders in `docs/compii/build-previews/polish-2026-10/`, kept separate from the historical v4 images. One batched visual pass, one correction pass (the capture helper had not registered the Display font family, so headlines drew as boxes).
- `test/bots_capture_test.dart` needed `ensureVisible` before one tap: the routines list grew taller at 1440×900 and its tile now sits below the fold.
- Not verified: any Android device or emulator (none attached), real screen-reader output, a hardware keyboard pass on Windows, the actual Windows reduced-motion setting. Captures are widget renders; the test font is wider than Segoe UI Variable, so 2.0-text renders over-state the pressure.

Outcomes per finding are recorded in `docs/compii/ui-ux-audit-2026-10-21.md`.

