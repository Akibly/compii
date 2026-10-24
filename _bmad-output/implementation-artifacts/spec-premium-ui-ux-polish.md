---
title: 'Premium UI/UX polish'
type: 'feature'
created: '2026-10-21'
status: 'done'
baseline_commit: '0c758ace6bda4626bfd86cf3790ffddec4fd465b'
route: 'dispatch'
review_loop_iteration: 1
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

Review loop 1, 23 October 2026. Three independent reads of the same work: keyboard and semantics, layout at 2.0 text and narrow widths, and a fact-check of the audit's Outcomes table against the code. Triage rule: fix what is a live defect on an active surface and provable in one or two lines; correct the record where a claim outran the code; write down what needs a restructure instead of absorbing it here.

| Reviewer claim | Verdict | Action |
|---|---|---|
| `Keyable` enforces a 44px minimum height but not width, so icon targets can be under 44px wide | Not a live defect — all seven wrapped controls are already ≥44px wide (text chips, a 44×44 mic, a 150px ember). Forcing a narrow child wider would draw the focus ring around empty space | Documented the floor as height-only (`ui/chrome.dart:382-383`); the audit's "44px minimum target" now says height |
| The focus ring shows on any focus, not only keyboard focus | Cannot happen today: every wrapped child is a `GestureDetector` that never requests focus on tap | No change; noted as fragile if a focusable child is ever wrapped |
| `Semantics(selected: false)` is announced on plain buttons | Real noise | `Keyable.selected` is now `bool?` and off by default; only the teammate nav row passes it. The regression asserts `hasSelectedState: false` |
| Holding Space on a `Keyable` scrolls the page behind it | Real, minor | `KeyRepeatEvent` is now consumed (`ui/chrome.dart:414`) |
| The timeline's End key jumps to the **oldest** moment when nothing is selected | Real | `step()` honours the direction when `selectedId` is absent (`ui/timeline.dart:731`) |
| The “still working” breathe and the loading skeleton repeat an `AnimationController` even when reduced motion has already frozen what they draw | Real, and their own doc comments promised the opposite: a vsync callback ticking all frame for a picture nobody is shown | Both gated on `context.still` in `didChangeDependencies` (`ui/chrome.dart:584`, `:658`) |
| `Pressable` sits in the same file as `Keyable`, does the pointer half only, and is referenced by nothing | Dead code, and a trap: the next person wraps a control in it and reintroduces finding 2 | Removed with its state class |
| "It was the last pointer-only control on an active desktop surface" | Overclaim — `overlay/buddy_layer.dart:1116`, `:1417` and the phone's screenshot preview are pointer-driven | Claim bounded in the audit: the buddy window is `WS_EX_NOACTIVATE`/`WS_EX_TRANSPARENT` (`windows/runner/win32_window.cpp:148`), so it cannot hold keyboard focus at all; the phone preview answers touch and reader actions |
| Palette "Shift+Tab reverse traversal" is selection movement, and there is no explicit focus trap | Both true | Wording corrected; the modal route is the trap and is now named as such rather than implied |
| The palette's Shift+Tab regression passes even if both keys are inert | Real test bug | Rewritten to walk two rows down and one back, so an inert key fails (`test/ui_polish_test.dart`) |
| Chat header status strip is a `Row` of up to six non-flex `Pill`s | Real overflow at 2.0 text | Now a `Wrap` (`ui/shell.dart:1562`) |
| The voice dropdown cap in setup was never propagated to Voice settings | Real | One shared `ScrollCapped` (`ui/chrome.dart`), used by setup and both Voice settings dropdowns |
| Three hard-coded durations bypass `context.motion`; the palette trigger chip is fixed at 30px; two `Text`s overflow their row | Real | `ui/pages.dart:36`, `:80`, `:163`, `ui/proactive.dart:1935`, `ui/palette.dart:735`, `ui/thread.dart:734`, `ui/trust.dart:1206` |
| Finding 1 was marked Closed while `ConsoleScreen`'s shortest-side routing was untouched | True, and it was a dead end: under 600px on desktop the Presence View had `onExit: null` and the destinations live in the workspace | Fixed — the narrow fallback is a default the user can leave (`console/console_screen.dart:23-44`). Finding 1's row now says what was still open |
| Finding 5's "routine toggle failure reports as a toast" understates it | True: the `catch` is silent (`ui/proactive.dart:1167`) | Audit row 5 and the gaps list corrected |
| Several regressions test helpers on bare widgets rather than wired surfaces | True, and worth knowing rather than rewriting: they pin the token and chrome contract the surfaces are built from | Recorded here so nobody reads them as end-to-end flow coverage |
| Phone "Do on the PC" grid fixes cell height by aspect ratio, so 2.0 labels outgrow it | Real, deferred — needs `mainAxisExtent`/intrinsic sizing, a restructure of a phone surface no device can verify | Follow-up, with line (`ui/phone_home.dart:985`) |
| Workspace breakpoints and panel widths ignore the text scaler | Real, deferred — changes which layout a window gets, i.e. behaviour, not polish | Follow-up (`ui/shell.dart:310`, `:444`, `:1656`) |
| `FaceStage` positions children with no `SafeArea`; the update toast is fixed 360px; `stage.dart` paints its own `EdgeInsets` | Real, deferred — notch behaviour and a re-tune of surfaces outside these twelve findings | Follow-ups, listed in the audit |

## Design Notes

Operate mode: clarity before ornament. Keep the companion expressive on arrival; reduce its footprint for decisions and dense reading. Reuse existing colors, discreet borders/shadows and shared components.

## Verification

- `flutter analyze` → `No issues found`. (Five lint hits left by work in flight were removed: curly-brace flow control in `pages.dart` and `trust.dart`, a redundant interpolation in `phone_home.dart`, a null-aware element in `thread.dart`, an unnecessary import in `timeline.dart`.)
- `flutter test` → 156 passed, 2 skipped, 0 failed (45 suites), including 16 new matrix regressions in `test/ui_polish_test.dart`.
- `flutter test --dart-define=CAPTURE=true test/ui_polish_test.dart` → renders in `docs/compii/build-previews/polish-2026-10/`, kept separate from the historical v4 images. One batched visual pass, one correction pass (the capture helper had not registered the Display font family, so headlines drew as boxes).
- `test/bots_capture_test.dart` needed `ensureVisible` before one tap: the routines list grew taller at 1440×900 and its tile now sits below the fold.
- Not verified: any Android device or emulator (none attached), real screen-reader output, a hardware keyboard pass on Windows, the actual Windows reduced-motion setting. Captures are widget renders; the test font is wider than Segoe UI Variable, so 2.0-text renders over-state the pressure.

Review round, same day, after the triage above:

- `flutter analyze` — `No issues found` (15.7s), with the review fixes in.
- `flutter test` — 170 passed, 2 skipped, 0 failed. The count is up from 156 because a second session was building the handover feature in this same tree while the review ran; its files were left alone and its tests are not claimed as this spec's coverage.
- One mid-round failure (`bots_capture_test`, a `RenderFlex` overflow in the team thread) was attributed by experiment, not assumption: this pass's own `Wrap` hunk was flipped back to a plain `Row` and the same test failed by **92** pixels instead of 8.5, so the narrowing came from concurrent work, not from this change. Restoring the `Wrap` and re-running left the suite green.

Outcomes per finding are recorded in `docs/compii/ui-ux-audit-2026-10-21.md`.

