# HeyClicky and competitors: what makes them work, and what Compii takes

Date: 2026-10-19. Sources:
- [HeyClicky try page](https://www.heyclicky.com/try)
- [HeyClicky changelog](https://www.heyclicky.com/changelog), v1.0 to v1.0.53
- [Clicky open source](https://github.com/farzaa/clicky)
- [XDA review](https://www.xda-developers.com/someone-built-tiny-ai-that-lives-next-to-your-cursor-the-most-useful-thing-ive-tried-this-year/)
- [The Rundown](https://www.therundown.ai/tools/clicky)
- [hokai review](https://hokai.io/hub/tools/heyclicky)
- [Copilot Vision with Highlights](https://www.tomsguide.com/ai/copilot-vision-just-launched-on-windows-heres-what-it-actually-does)
- [How-To Geek](https://www.howtogeek.com/copilot-on-windows-can-now-see-your-screen/)
- [Vorec on Copilot Vision](https://vorec.ai/blog/copilot-vision)
- [Grok Bot](https://www.digitalapplied.com/blog/grok-bot-ai-teammates-launch-cloud-computer-2026)
- [MausBot](https://mausbot.com/)

## HeyClicky in one paragraph

You hold a shortcut and talk. It sees your screen only at that moment, answers out loud and draws on your screen
to show the way. Highlights fade after 2 s, and drawings stay while it speaks. Walkthroughs of up to 15 steps
**advance when it detects you clicked where it pointed**, remember progress across pauses, and wait for slow
pages. You can **draw or circle on screen to tell it what you mean** ("spatial context"). Saying "agent" hands
the same context to a background agent. The agent asks once ("Allow once / Always allow / Not now"), waits 5 s
so you can cancel, and clicks without moving your real pointer. Other features:
- Hold-to-dictate into any app, plus screen-aware dictation that drafts a reply from what's on screen.
- An always-on mode (press Control three times).
- A small face on the buddy that reacts while listening, thinking and talking, and dozes off when idle.
- A router that sends quick questions to a fast model and hard ones to a frontier model.
- Memory files for your profile and your current project.

It's Mac-only, cloud-only, and costs $20 to $100 a month above the free tier.

## Others

| | Strength | Gap Compii fills |
|---|---|---|
| **Copilot Vision + Highlights** (Windows) | Numbered on-screen pointers; voice | Never clicks or types; shares the whole screen while on |
| **Clicky (open source)** | `[POINT:x,y]` tags; streaming STT/LLM/TTS | Mac, paid APIs, guesses pixels |
| **Grok Bot** | *Teach a task*: record yourself once (up to 10 min), it repeats it | Cloud computer, not your desktop |
| **MausBot** | Approval cards, decision log, phone app | No screen buddy |
| **Gemini Live** | Screen and camera sharing on phones | Not on the Windows desktop |

## What Compii now does (and how)

| Idea | Compii |
|---|---|
| Buddy beside the cursor, with a face | A tiny original character (not a pointer): a glowing droplet with eyes that react while listening, thinking and speaking, and doze when idle |
| Show it what you mean (spatial context) | While you hold Ctrl+Alt, **circle or wave at things with the mouse**: a paint trail follows and the items under it become the focus (no clicking needed, so nothing underneath is pressed) |
| Watch me (teach a task) | Say "watch me", do the task, say "done". Compii records the clicks (item names, not pixels), shortcuts and window changes (never what you type) and saves a reusable skill |
| Show me (it demonstrates) | Walkthroughs: the buddy flies to each item, rings it with a hand-drawn circle, says the step, and **moves on when you click it** (or when the screen changes) |
| Dictation anywhere | Hold Ctrl + Win and speak: cleaned-up text is typed where your cursor is. Never into password fields |
| Agent vs talk | From the buddy, Compii answers and points by default and only acts when you clearly ask it to do something; approvals as before |
| Fast feel | Instant spoken acknowledgement; yes/no/stop handled locally; whole-sentence speech |
