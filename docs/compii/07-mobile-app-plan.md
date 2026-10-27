# Compii mobile — plan and 100 features (2026-10-27)

## Where it stands

The phone app already exists inside `compii_flutter/apps/companion` (`lib/src/mobile/`, `lib/src/ui/phone_*.dart`, `pair.dart`). It pairs with the PC by QR code, then offers three tabs: **Talk** (hold to speak, the face view), **Chats** (follow and answer conversations, approve actions), and **PC** (glance at the PC's screen and act on it). Requests made while the PC is away wait in an outbox and are shown honestly. It reaches the PC on the same Wi-Fi or anywhere through Tailscale. Android permissions: internet, camera (QR), microphone, notifications.

What it is not yet: a companion that is useful on its own. Everything runs on the PC, so when the PC sleeps the phone is a remote control with nothing to control.

## What the best mobile agents do (research, October 2026)

- **Claude Duet** (iOS, Android, web; research preview 21 Oct): messages you first, and only when something needs you; a short ranked morning brief; hand it a bigger job by voice note; every send, payment, signature or deletion is an approval card listing the action, destination, content and every recipient; runs on its own cloud machine so it keeps working when your laptop is off. ([MacRumors](https://www.macrumors.com/2026/10/21/anthropic-claude-duet/), [Make Tech Easier](https://maketecheasier.com/claude-duet-research-preview/), [Drag](https://www.dragapp.com/blog/claude-duet/))
- **Meta Muse**: keeps working after the app closes and resurfaces when something changes or needs sign-off; connectors (Gmail, Calendar, OpenTable, Instagram, Plaid…); one-time card numbers for checkout; an audit log. ([Real Python](https://realpython.com/what-is-meta-muse/), [eesel](https://www.eesel.ai/blog/meta-muse-agent-review))
- **ChatGPT**: Home Screen widget per Dot with message and voice-call controls, Shortcuts actions, lock-screen voice. ([Let's Data Science](https://letsdatascience.com/news/chatgpt-adds-dot-widget-and-shortcut-controls-04979c0a), [Tom's Guide](https://www.tomsguide.com/ai/chatgpt/i-added-the-chatgpt-voice-widget-to-my-iphone-lock-screen-for-quick-access-to-advanced-voice-heres-how))
- **Gemini Live**: share the phone's screen or camera with the assistant from an overlay and talk about what it sees. ([Android Authority](https://www.androidauthority.com/gemini-live-camera-screen-sharing-features-rolling-out-3542168), [Tom's Guide](https://tomsguide.com/ai/gemini-live-video-and-screen-sharing-is-now-free-for-android-heres-how-to-use-it))

The pattern: the phone is where the agent **reaches you** (brief, alerts, approvals), **hears and sees** (voice, camera, screen), and **keeps going** without you watching.

## The plan, in four phases

1. **Reach you** — push notifications that matter, approvals from the lock screen, a morning brief, widgets. Cheapest, highest value; works with today's PC-side Core.
2. **See and hear** — camera and phone-screen sharing, voice notes, the Halo face as the home of the app.
3. **Work without the PC** — a small cloud Core (or a phone-side brain) so tasks continue when the PC sleeps; the PC becomes one of Compii's hands, not its only body.
4. **Live on the phone** — Android automation (accessibility service), share sheet, Shortcuts/App Actions, watch and car.

## 100 features, ranked within each group

### A. Reach you (notifications, brief, approvals)
1. Push notifications for "needs you", "done" and "failed" — real push, not polling.
2. Approve or deny from the notification itself, with the exact action shown.
3. Morning brief: three ranked items, not thirty.
4. Evening recap: what Compii did today, from the activity log.
5. Quiet hours and a "only what needs me" threshold you can tune.
6. Approval cards that list every recipient, amount and file, like Duet's.
7. "Hold to approve" for anything that can't be undone.
8. A single inbox of everything waiting on you, across teammates.
9. Snooze a request to later, or to "when I'm at my desk".
10. Critical-alert channel for things you marked urgent (Android notification channels).
11. Live Activity / ongoing notification while a job runs, with Stop.
12. Weekly digest of routines, watches and what they caught.
13. Read receipts for teammates: who saw the job, who is on it.
14. Notification grouping per conversation.
15. "Why did you notify me?" on every alert.

### B. Talk and listen
16. The Halo face as the app's home: eyes, halo, moods, your own eyes option.
17. Hold-to-talk with live words, like the PC cursor companion.
18. Hands-free "Hey Compii" while the app is open.
19. Voice notes: record a long brief, Compii turns it into a job.
20. Online neural voice on the phone (same Microsoft voices as the PC).
21. Interrupt Compii mid-sentence by speaking.
22. Talk mode that keeps going while the screen is off.
23. Transcripts of every voice exchange, searchable.
24. Language auto-detect, reply in the language you spoke.
25. "Say that again" and "shorter" voice commands.
26. Earbud button to start talking (media button handling).
27. Read long answers aloud with play/pause/skip.
28. Dictate into any text field via the Compii keyboard (later).
29. Voice confirmation for approvals ("yes, send it") with a spoken readback.
30. Accent and speed controls for the voice.

### C. See (camera and screen)
31. Point the camera: "what is this?", "read this", "translate this".
32. Live camera mode: talk about what the camera sees, continuously.
33. Share the phone's screen with Compii (Android MediaProjection).
34. Snap a document: OCR, summary, and file it on the PC.
35. Receipt capture straight into a spreadsheet on the PC.
36. Whiteboard capture with cleanup and a Word export.
37. Scan a QR or barcode and act on it.
38. Photo of a screen error → Compii diagnoses it.
39. Visual "show me how": Compii circles the button on your phone's screen.
40. Business-card scan to contacts.

### D. Work with the PC
41. See the PC's screen live, with Compii's pointer.
42. Send a file from the phone to the PC (and back).
43. "Continue on PC": open the conversation where you left it.
44. Wake the PC (Wake-on-LAN) to run a job.
45. Remote approvals for jobs running on the PC.
46. Clipboard sync between phone and PC (opt-in).
47. Control media on the PC: play, pause, volume.
48. Lock the PC from the phone.
49. Run a saved skill on the PC with one tap.
50. See the PC's battery, network and what is running.

### E. Work without the PC
51. Cloud Core: tasks continue when the PC is asleep.
52. Phone-side brain for quick answers when offline from the PC.
53. Web research from the phone alone.
54. Connectors: Gmail, Google Calendar, Outlook, Drive, Notion.
55. Calendar actions: find a slot, propose, book (with approval).
56. Email triage on the phone: sort, draft, never send without you.
57. Reminders and routines that live in the cloud.
58. Watches (a web page changes, a price drops) that run without the PC.
59. Shared memory between phone and PC, with "forget" from either.
60. Location-aware reminders ("when I get home").

### F. Android integration
61. Home-screen widget: talk, camera, latest result.
62. Lock-screen and Quick Settings tile to talk.
63. Share sheet: send anything to Compii ("summarise this link").
64. App Actions / Shortcuts: "Hey Google, ask Compii…".
65. Accessibility-service automation of phone apps (with per-app consent).
66. Read notifications on request ("what did I miss?"), opt-in.
67. Draft replies inside messaging apps via the share sheet.
68. Default assistant option (long-press power).
69. Wear OS tile: talk and approve from the watch.
70. Android Auto: voice-only, read-and-approve.

### G. Team and conversations
71. Every teammate's chat on the phone, with its Halo character.
72. Hand a job to a teammate from the phone.
73. Team chats with several teammates at once.
74. Delete, export and search conversations on the phone.
75. Pin conversations and teammates.
76. Per-teammate notification settings.
77. Outcome-first answers with the receipt line on mobile too.
78. Attachments: photos, PDFs, voice notes.
79. Edit and resend a message.
80. Conversation summaries for long threads.

### H. Trust, privacy, control
81. Kill switch on the phone: stop everything everywhere.
82. Activity log viewer (the tamper-evident audit chain).
83. Per-permission switches: mail, files, screen, camera, location.
84. Biometric lock for the app and for approvals.
85. "What leaves this phone" view for every request.
86. Local-only mode.
87. Device list and remote unpair.
88. Encrypted backup of settings and memory.
89. Data export (everything Compii knows) as a zip.
90. Clear history, memory and reset Compii from the phone.

### I. Delight and polish
91. Halo character reacts to touch (tap: blink, long-press: listen).
92. Haptics that match moods (done, needs you, problem).
93. Your colour and form synced from the PC.
94. Dark-first design matching the Halo canvas.
95. Onboarding in under a minute: scan, talk, done.
96. Offline-friendly: the outbox, retries, honest states.
97. Tablet layout with the three-pane workspace.
98. Accessibility: TalkBack labels, large text, reduced motion.
99. Localisation of the app UI.
100. In-app "what's new" written by Compii from the changelog.

## Start here (first sprint)

1. Real push notifications (FCM) with approve/deny actions — #1, #2, #6, #11.
2. Morning brief and evening recap on the phone — #3, #4 (Core already makes both).
3. The Halo face as the Talk tab, online voice on the phone — #16, #17, #20.
4. Camera "what is this?" and document snap — #31, #34. **Done:** camera button on Talk, "What is this?" and
   "Snap a document" on the PC tab; Core's `look_at_photo` reads photos with the free NVIDIA vision model
   (local OCR without a key).
5. Home-screen widget and share sheet — #61, #63. **Done:** Camera on the widget; photos, PDFs and Office files
   arrive from the share sheet (text and links already did).

Phase 3 (cloud Core) is the biggest decision: it changes Compii from "an app on my PC" to "an assistant that is always on". It needs hosting, accounts and a privacy story, so it deserves its own plan before any code.
