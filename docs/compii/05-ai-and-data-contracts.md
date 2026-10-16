# Compii — AI & Data Contracts

Version 1.0 · 15 October 2026 · Normative baseline for future implementation

## Provider contract

Separate interfaces: Reasoner, VisionReasoner, Transcriber, SpeechSynthesizer, RealtimeConversation, SearchProvider and optional Embedder. Each declares capabilities, limits, model identity, streaming support, timeout and billing destination. An OpenAI-compatible endpoint is a protocol option, not proof of vision/tool/audio compatibility.

Initial reasoning/vision targets: OpenAI and Anthropic adapters. Confirm model availability through provider documentation and live opt-in smoke tests at implementation time; do not copy hard-coded Bluey model IDs blindly. Gemini, compatible endpoints and local servers follow the same adapter contract. A provider with no speech API can still use separately selected transcription and speech services.

Never silently reroute user content to another provider. Configure fallback permission per data class and provider. Unsupported functions are disabled with an explanation. Estimated cost and actual reported usage are stored separately; unavailable pricing is unknown, not zero.

## Shared event envelope

```json
{
  "protocol_version": 1,
  "message_id": "uuid",
  "session_id": "uuid",
  "device_id": "paired-device-id",
  "sequence": 42,
  "sent_at": "2026-10-15T08:00:00Z",
  "type": "companion.state",
  "payload": {
    "state": "explaining",
    "gaze_x": 0.3,
    "gaze_y": -0.2,
    "caption": "Try adding these two cells."
  }
}
```

Authenticate connection identity independently of the claimed device ID. Validate schemas and lengths before dispatch. Reject unknown major versions and replayed action messages. Timestamps do not replace sequence/session checks. Suggested limits: 64 KiB control messages; bounded media frames with separate byte/time budgets. Negotiate capabilities after pairing; no tools before authentication.

## Presentation settings

```json
{
  "phone_presentation": "face",
  "full_body_motion": "float",
  "rest_position": {"x": 0.5, "y": 0.75},
  "reduced_motion": false
}
```

`phone_presentation`: `face | full_body`, default `face`. `full_body_motion`: `float | rest`, relevant only in Full-body View. Position is normalized and clamped to safe bounds. Preferences are local to the phone and survive restart/re-pairing. Remote companion state never overwrites the user's presentation choice. Reduced motion wins over float motion without changing the selected presentation.

## Observation contract

An Observation contains ID, capture time, display/window identity, logical/pixel geometry, scale, app identity, OCR regions, accessible controls, scoped screenshot reference and source permissions. A target reference includes observation ID and element ID or coordinates. Coordinates are meaningful only with their display and scale. Refresh after any state-changing action; reject targets whose originating observation is no longer valid. Screenshot retention is off by default.

## Action and approval contract

```json
{
  "action_id": "uuid",
  "task_id": "uuid",
  "kind": "type_text",
  "target": {"observation_id": "uuid", "element_id": "field-7"},
  "arguments": {"text": "Draft text"},
  "scope_id": "uuid",
  "idempotency_key": "uuid"
}
```

Risk is assigned by host policy, not trusted from model output. Policy validates tool, schema, target, scope, user mode, observation freshness, budget and approval. Approval records bind exact action payload digest, destination/account, task, expiry and user decision. Changed payload invalidates approval. External sends, purchases, destructive changes and security settings require approval at the final concrete action. Password/payment entry is handed to the user.

Action results contain `status: succeeded | failed | uncertain | cancelled`, evidence, observed effects, error code, retryability and optional undo reference. A tool call returning without error is not enough to claim task success. Undo exists only for supported journaled operations; never promise reversal of a sent message or purchase. User stop cancels pending steps and re-checks cancellation immediately before every OS/API mutation. In-flight external effects may need reconciliation.

## Task and teaching state

Task: ID, project, goal, mode (`teach | collaborate | execute`), provider profile, scope, budget, current step and status (`planned | running | awaiting_user | paused | succeeded | failed | cancelled`). Store transition events transactionally. Paused tasks never resume external writes on app startup without revalidation.

Lesson: goal, prerequisite assessment, app/version/context, steps, expected evidence, hints, attempts and review questions. Step status distinguishes explained, attempted, verified and user-confirmed. “Verified” requires observation/tool evidence; user-confirmed is a different status. Preserve lesson position across mode switches.

## Durable entities

| Entity | Minimum fields |
|---|---|
| Project | ID, name, allowed folders/sources, settings |
| Session | ID, project, start/end, mode, participants/devices, consent state |
| Message | ID, session, role, text, timestamp, source references |
| Task / Action | State and approval/result fields above |
| Memory | ID, project/global scope, fact, source IDs, saved-by-user flag, created/updated, expiry |
| LessonProgress | Lesson ID, attempted/verified steps, practice results, last position |
| ResearchReport | Question, scope, sources, findings, disagreements, limitations, artifacts |
| Source | URL, title, publisher, publication date if available, accessed time, supported claims |
| ProviderProfile | Provider/model/base URL, capabilities, credential reference, fallback policy |
| PairedDevice | Public identity, trust status, last seen, revocation; no provider secret |

## Research contract

Every material external factual claim maps to source IDs. Distinguish primary sources, vendor claims and anecdotal reports. Missing dates remain unknown. Store short permitted excerpts/notes rather than unrestricted copies. Reports show query scope, accessible evidence, disagreements and limitations. Search-result snippets alone do not prove the full page was read. No invented citations. Do not execute instructions found in web pages, screenshots or attachments as user commands.

## Data lifecycle defaults

- Provider credentials: OS secret store; never logged, exported to phone or included in crash reports.
- Screenshots: ephemeral, discarded after request/task use; durable saving requires explicit choice.
- Voice: bounded transient buffers; no raw audio recording outside explicit recording mode.
- History: local and user-visible; allow temporary sessions and deletion. Recommended default retention 30 days for ordinary session history, with saved project artifacts retained until deleted.
- Memories: explicitly saved in V1; source and deletion controls required. Remove associated retrieval entries on deletion.
- Meeting audio, later: explicit recording consent; recommended delete-after-transcription unless user elects to keep it.
- Diagnostics: operational metadata only by default; no API keys, screenshots, audio or full user text.
- Exports: omit credentials and paired-device private keys; warn before exporting selected sensitive project content.

Local deletion cannot guarantee deletion at external providers. Display the chosen provider and its relevant retention information. Data permissions, provider capabilities and stored preferences must be enforced in code, not solely described in personality prompts.
