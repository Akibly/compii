# Compii — Technical Architecture

Version 1.0 · 15 October 2026 · Proposed implementation decisions

## Platform strategy

Flutter/Dart provides shared presentation, character rendering, settings and typed domain logic. Native plugins provide OS integration. Windows is the first execution host; Android is the first paired phone. macOS/iOS follow with platform-specific build and QA infrastructure. Linux is gated on X11/Wayland capability tests; no universal parity promise. Apple builds require Apple tooling.

Reference: [Flutter platform integration](https://docs.flutter.dev/platform-integration), [platform channels](https://docs.flutter.dev/platform-integration/platform-channels), [supported platforms](https://docs.flutter.dev/reference/supported-platforms).

## Proposed repository organization

Create the new implementation in `compii_flutter/` after planning. Keep current Bluey Swift source untouched as a reference until a deliberate migration decision.

```text
compii_flutter/
  apps/desktop/             Flutter desktop shell
  apps/mobile/              Flutter phone shell
  packages/domain/          Tasks, lessons, events, capabilities
  packages/companion/       Wisp painter, expressions, presentation settings
  packages/design_system/   Tokens and accessible shared widgets
  packages/ai/              Provider and speech adapters
  packages/storage/         SQLite repositories, migrations, retrieval
  packages/pairing/          Authenticated transport and device identity
  packages/agent/           Planner, policy, executor, verifier, scheduler later
  packages/platform_bridge/ Typed native interfaces and implementations
  tests/scenarios/          End-to-end fixtures and benchmark tasks
```

Select package versions during the bootstrap spike, pin lockfiles and avoid claiming untested plugin compatibility. Recommended state management: Riverpod; typed immutable domain models; SQLite for durable records; OS credential stores for secrets. Final plugin choices depend on overlay, capture and audio spikes.

## Runtime responsibilities

| Component | Responsibility |
|---|---|
| Desktop shell | Tray, workspace, overlays, shortcuts, device status |
| Mobile shell | Face/full-body rendering, explicit mic source, captions, pairing and presentation choice |
| Context service | Scoped capture, OCR, accessibility tree, app/window identity, observation freshness |
| Conversation service | Voice/text turns, interruption, model routing and response streaming |
| Task coordinator | Mode, goal, budgets, step state, cancellation and recovery |
| Policy service | Capability checks, action scope, approval validity, blocked fields and sources |
| Executor | Native, browser or connector actions; no arbitrary model-to-OS dispatch |
| Verifier | Fresh observation or tool evidence; classify success, failure or uncertainty |
| Storage | Sessions, selected memories, research sources, action journal and artifact references |

Data path: user input -> scoped context -> selected provider -> proposed tool call -> schema/policy validation -> native/API execution -> fresh result -> verification -> response. The model proposes; the host enforces. Prompt wording alone is not an action boundary.

## Native bridge

Initial typed operations: enumerate displays/windows, capture selected target, read accessible controls, read focus, move/click, type, key combination, scroll, open application/URL, overlay positioning, hotkeys and stop. Use a native helper only if isolation or responsiveness requires it; expose a narrow authenticated interface rather than an unrestricted local command endpoint.

Windows: investigate Windows Graphics Capture, UI Automation, supported input APIs and transparent non-activating overlays. macOS: reuse architectural knowledge from ScreenCaptureKit, Vision, accessibility and AppKit, not an assumption that Swift UI transfers to Flutter. Linux: evaluate portals and compositor restrictions before promising input injection. Mobile apps control the paired host; they are not general-purpose controllers of unrelated phone apps.

Coordinates include display identifier, logical bounds, pixel bounds and scale. Accessibility element IDs are scoped to an observation. Revalidate after window movement, scrolling, resolution change or navigation. Support multi-monitor mixed-DPI tests before claiming multi-monitor control.

## Wisp and overlays

Use Flutter paths, gradients and pupil/brow transforms. The generated concept is a visual target, not a shipped sprite or executable specification. Share expression state across desktop and phone; compute presentation locally. Desktop defaults to a small 48–72 logical-pixel character; phone defaults to large-eye Face View. Full-body View renders the complete silhouette, floating or resting within the mobile app.

An animation tick never requires an LLM call. Limit gaze updates, discard stale animation packets, interpolate locally and respect reduced motion. The visual overlay does not move the real pointer until an authorized action is executed. Overlay windows are click-through except explicit controls.

## Voice pipeline

V1 baseline: selected microphone -> speech recognition -> reasoning/vision adapter -> caption -> optional speech generation. Native realtime speech sessions are an optional adapter path, not a dependency for every provider. Route tools through the same policy service in both paths. On barge-in stop speech promptly, cancel/interrupt response generation where supported, and pause uncommitted actions.

No double capture: exactly one active microphone owner per session. Clear audio state when devices switch. Phone backgrounding pauses phone audio in V1; desktop may continue only with an explicitly selected local microphone.

## Pairing and transport

Use local discovery only to locate a host. Establish trust through a short-lived pairing challenge and mutual confirmation. Use a reviewed secure transport implementation with authenticated encrypted connections and pinned paired identities; do not invent cryptography. Bind listener to intended local interfaces and do not expose unauthenticated commands or long-lived API keys.

Desktop owns provider secrets and tool execution. Phone is a thin client: it sends bounded audio/control events and receives presentation/output. Raw microphone audio uses bounded binary frames; do not place large base64 media in unbounded JSON lines. Keep control, audio and visual update channels logically distinct. Internet relay and off-network control are outside V1.

## Storage and continuity

Persist task transitions transactionally. Recover interrupted tasks as paused, then re-observe before resuming. Never replay an external write simply because its acknowledgement was lost. Files and research artifacts live under an application-managed project directory; database holds metadata. Semantic indexing can follow local full-text search; any embedding provider use is disclosed and configured separately.

No mandatory Compii cloud account in V1. Cloud model/search calls still require internet. Credential storage is OS-backed; do not copy Bluey's plaintext key-file approach. If local history is not encrypted, disclose that accurately; do not equate keychain storage with full database encryption.

## Constraints and engineering gates

Foreground automation is serialized and yields to user input. Parallel API/research tasks share explicit cost/concurrency limits. UI actions generally cannot run invisibly while the same user controls the same desktop. Android overlays above other apps and iOS equivalents are not baseline features. Measure overlay responsiveness, battery impact, secure pairing and native control feasibility before broad feature implementation.
