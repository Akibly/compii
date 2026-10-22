# Compii UI/UX audit — 21 October 2026

## Scope and evidence

Read-only investigation of the current working tree, including uncommitted work authorized by the user. The active product is the Flutter Windows/Android app under `compii_flutter/apps/companion`, backed by the Python Core service. The original Swift Mac/iOS implementation remains in the repository. This pass targets the active Flutter experience; it is not a backend correctness or security audit.

Inspected shared tokens/chrome, desktop shell, conversation stage/history, approval flows, voice dock, onboarding, phone shell, settings/provider setup, safety, automation, clipboard, timeline, command palette, API entry points, and existing tests. Inspected existing v4 Home and Settings captures; an independent flow review also inspected the Needs-you and onboarding captures. Captures are historical widget renders, not proof of current native behavior. The current code contains newer changes than those images. Product/adoption documents also describe an earlier implementation stage; current code is the implementation evidence.

`flutter analyze` passed with no issues. Initial tests could not invoke Rust; adding the existing installation at `C:/Users/badem/.cargo/bin` to the command environment resolved that PATH problem. All 14 targeted baseline tests passed across console capture, phone home, onboarding, tokens, and thread suites. These renders check layout exceptions at their existing sizes; they do not invalidate the uncovered edge cases below. No Android device/emulator is connected. Native interaction and phone hardware validation are not claimed.

## Direction

Preserve warm paper, night-indigo surfaces, the existing character, custom glyphs, semantic status colors, and voice-first interaction. Premium quality here means deliberate hierarchy, balanced spacing, readable long responses, visible actions, complete feedback, and consistent mouse/keyboard/touch behavior. Avoid introducing a competing palette or replacing the character.

## Findings, ordered by impact

1. **Desktop navigation changes or disappears with window size.** `ConsoleScreen` selects FaceStage based only on shortest side; `Workspace` removes its sidebar below 760px without a menu replacement. Preserve desktop workspace identity while resizing and offer compact navigation using the same destinations.
2. **Custom actions lack consistent keyboard access.** Several shell navigation/conversation/send controls, caption buttons, and answer chips use GestureDetector without keyboard activation or button semantics. Retain their visual identity while adding focus, keyboard activation, labels, selected/disabled states, and sufficient hit areas.
3. **Approval presentation overuses vertical space.** Stage puts the hero and repeated waiting text before the approval card. Historical capture evidence shows actions below the viewport; current structure retains that risk. Compact the pending state, wrap action groups, and keep all decision details scrollable and reachable.
4. **Responsive settings are inconsistent.** PageScaffold uses fixed 36px gutters; headers and OptionRow keep trailing actions inline. Autonomy segments, theme controls, voice controls, shortcut labels, provider fields, and safety audit columns need adaptive stacking, including at enlarged text sizes.
5. **Failed loads can look permanently busy.** Memory, Clips, and Timeline only replace nullable data after successful fetches. Add explicit failed-load states with retry; preserve last successful content on refresh failure. Apply the same pattern to provider/policy, routines, skills, and updates where investigation confirms the pattern.
6. **Safety shows unverified defaults during loading.** Null safety data is rendered as lockdown off and empty rules/history. Distinguish unknown/loading/error from confirmed state; retain access to emergency stop.
7. **Palette assumes a fixed text height.** Result rows and scroll reveal assume 58px; Shift+Tab advances forward. Make text scaling and keyboard navigation coherent, with selected results reliably scrolled into view.
8. **Phone feedback can overlap.** Transcript and error overlays share bottom:84. Multiple sibling banners each apply a top SafeArea. Stack feedback and apply insets once at the appropriate boundary.
9. **Motion preferences are not applied consistently.** Workspace, Stage, and voice transitions use fixed durations. Use a shared reduced-motion convention and preserve functionality without movement.
10. **Long responses lose reading quality.** Stage centers long replies in title typography and flattens Markdown. Keep short conversational replies expressive; present longer content with readable alignment and the existing rich-text rendering where appropriate.
11. **Onboarding becomes cramped.** Card controls and five progress labels are laid out horizontally. Adapt the controls/progress layout, clarify directional copy, and reserve busy indicators for actual work.
12. **Visual patterns have drifted.** Secondary pages mix manual headings and card patterns. Reuse shared headers, spacing, shapes, and interaction treatments to make every surface feel part of one product.

## Verification plan

Add targeted widget regressions for compact desktop navigation, text scaling, approval actions, keyboard access, failed-load retry, safety unknown state, and phone feedback composition. Run analysis and the existing Flutter suite. Capture representative light/dark desktop and phone widget renders, explicitly labeled as such; use native devices where available. Inspect one batched visual pass and at most one correction pass. Keep backend contracts and user data unchanged.

## Outcomes — 23 October 2026

Work was carried out against `spec-premium-ui-ux-polish` on top of the same uncommitted tree the audit read. Part of the twelve findings had already been closed by that in-flight work (the drawer navigation, `Space.gutter`, `LoadFailure`, the compact approval card); this pass finished the rest, unified the remaining surfaces onto the shared components, and added the missing regression coverage. Nothing here changed backend contracts, permissions, approvals, or user data.

| # | Finding | State | Where it landed |
|---|---|---|---|
| 1 | Navigation disappears with window size | Closed | `Workspace` keeps the sidebar at ≥760px and below it puts the same destinations in a `Drawer` opened by an "Open navigation" title-bar button (`ui/shell.dart:284`, `:303`). |
| 2 | Custom actions lack keyboard access | Closed | New shared `Keyable` (`ui/chrome.dart`) gives a focus tab stop, Enter/Space activation, a 44px minimum target, a focus ring that costs no layout, and `Semantics(button, selected, enabled, label)`. Applied to the talk button, mic, say-chips, teammate rows, answer chips, the console face, and routine day-chips. The timeline scrubber takes Left/Right/Home/End (`ui/timeline.dart`). |
| 3 | Approvals overuse vertical space | Closed | `ApprovalCard(compact: true)` now leads the Stage column instead of following the hero (`ui/stage.dart:88`); decision buttons share one `Wrap` (`ui/thread.dart:652`) and the detail block scrolls inside a bounded box. |
| 4 | Responsive settings inconsistent | Closed | `Space.gutter` gives the margin back at ≥1.4 text or under 700px; rows use `AdaptiveRow`; the autonomy, theme, and answer-mode `SegmentedButton`s are width-capped inside a horizontal scroll view (`ui/pages.dart:231`). |
| 5 | Failed loads look permanently busy | Closed | `LoadFailure` with Retry across Memory, Clips, Timeline, provider/policy, models, Library, Knowledge, routines, and Voice settings. `VoiceController.statusFailed` now distinguishes "the fetch failed" from "the model is not ready" (`ui/voice.dart`). Last good content survives a failed refresh. |
| 6 | Safety shows unverified defaults | Closed | Unknown status renders "Safety status is not yet verified. Emergency stop is available." (`ui/trust.dart:930`) rather than "off"; failed fetches retry instead of showing empty rule lists. |
| 7 | Palette assumes fixed text height | Closed | Rows measure `56/28 × textScale` and each carries a `GlobalKey`, so reveal scrolls by real geometry; Shift+Tab moves backwards; the footer is a `Wrap` so hints and the result count fall to a second line at large text. |
| 8 | Phone feedback overlaps | Closed | One `SafeArea(bottom: false)` at the body edge; the live caption and `_VoiceProblem` share a single positioned column so they stack rather than paint over each other. |
| 9 | Motion preference applied unevenly | Closed | `context.motion(ms)`/`context.still` on page, switch and dock transitions; the character's mood blend snaps to the new mood instead of animating when the platform asks for no motion (`console/character.dart`). |
| 10 | Long responses lose reading quality | Closed | Short replies stay centered in title type; over 220 characters or with a newline the bubble renders `ReplyText` (markdown, body type, left-aligned) inside a 720px column (`ui/stage.dart:197`). |
| 11 | Onboarding cramped | Closed | Progress becomes pill chips below 420×scale with `Now/Done/Upcoming` in words plus `Semantics(selected:, label: 'Step i of 5: …')`; card controls use `AdaptiveRow`; the spinner only appears while work runs, with "Your turn" when setup is waiting; the voice picker is width-capped and scrollable. |
| 12 | Visual patterns drifted | Closed | Duplicate `_Page`, `_heading`, `_section`, `_Card`, `_Empty` helpers deleted in favour of `PageScaffold`, `SectionHeader`, `Panel`, `PanelRows`, `EmptyState`. |

### Evidence

- `flutter analyze` — no issues. The audit's baseline was already clean; work in flight had added five lint hits (curly-brace flow control in `pages.dart`/`trust.dart`, a redundant interpolation in `phone_home.dart`, a null-aware element in `thread.dart`, an unnecessary import in `timeline.dart`), all removed.
- `flutter test` — 156 passed, 2 skipped, 0 failed across 45 suites.
- New `test/ui_polish_test.dart` — 16 matrix regressions: Tab→Enter and Tab→Space activation, a disabled control skipped in traversal, `matchesSemantics` on the announced button, the focus ring not changing size, gutter and duration behaviour at 1.0/2.0 text with reduced motion on and off, `AdaptiveRow` stacking, `LoadFailure` retry, Shift+Tab reversing in the palette, palette rows growing with text, phone caption and failure not sharing pixels, the notch consumed once, and all five setup steps at 360×760 with 2.0 text.
- `test/bots_capture_test.dart` needed one line: the routines list is now taller at 1440×900, so the tile the test clicked sits below the fold. It calls `ensureVisible` before tapping. Layout shift, not behaviour.
- Renders for eye check: `docs/compii/build-previews/polish-2026-10/` (setup voice step at 1.0 and 2.0, palette at 2.0, phone with caption plus failure in dark). Regenerate with `flutter test --dart-define=CAPTURE=true test/ui_polish_test.dart`.

### What is *not* verified

- No Android device or emulator is attached. The phone results are widget renders at 400×860 with simulated 47/34px insets; pairing, microphone, speech, and notification behaviour on real hardware are untouched by this pass and remain unproven here.
- No screen reader ran against these controls. Announcements are asserted through `Semantics` flags in tests, not observed in NVDA or TalkBack.
- No hardware keyboard pass on Windows: focus order is exercised through synthetic key events.
- Reduced motion was verified by `MediaQuery.disableAnimations`, not by toggling the Windows setting.
- Captures use the test font, whose glyphs are wider than Segoe UI Variable, so the 2.0 text renders over-state the pressure rather than understate it.
- Known gaps left deliberately: the `_DayColumn` week grid still clips its time labels at 2.0 text (making it safe needs a scroll/wrap restructure, not a row change); `pages.dart` keeps its own `_Card` because it clips children and `Panel`/`PanelRows` do not; routine toggle/run-now failures still report only as a toast rather than a persisted error state; the legacy Swift app was not touched.
- Seen in the visual pass, not changed: the palette's "Go to" heading counts only its own rows while the always-present "Ask Compii" row sits under it, so a screenshot reads as 4 vs 5. The footer count is the honest one. Left alone as pre-existing and outside these twelve findings.

