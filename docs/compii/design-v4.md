# Compii design v4: "night ink & mitten cream"

Date: 2026-10-19. Screens: `build-previews/v4/` (rendered by `flutter test --dart-define=CAPTURE=true`).

## Why it changed

v3 used stock Material everywhere: Google's icon font, default switches, chips and underlined
fields, a cold grey-and-indigo palette, the Windows purple title bar, and weak hierarchy.
It looked like a template, not like Compii.

## Direction

The interface is built from the Orbling's own colours:
- **Light:** warm paper (`#F7F4EE`) with night-indigo ink (`#15122E`). Your own messages
  are ink bubbles with cream text.
- **Dark:** a deep night sky (`#0D0B1A`) with lifted indigo surfaces.
- **Colour means something:**
  - Indigo is Compii and the primary action.
  - Gold means "needs you".
  - Coral means danger.
  - Green means done.
  - Cyan means listening.
- **Type:** Segoe UI Variable. Display cut for headings (tight tracking, bold), Text cut
  for body.
- **Depth:** 16px rounded panels with a hairline border and a soft two-layer shadow (light)
  or a lifted surface (dark). Floating things (the message box, approval cards) get a
  bigger shadow and a focus halo.

## Compii's own icons (`lib/src/ui/glyphs.dart`)

There are 71 glyphs, drawn for Compii on one 24-unit grid. Each has 1.7-unit rounded strokes
and a soft second tone that fills the shape when it's active (selected nav item, page
header, status tiles). They are SVG-style path data rendered by a small built-in parser,
so no icon font or package is involved. `test/glyph_sheet_test.dart` renders the full sheet
(`build-previews/v4/glyphs.png`).

## Window and components (`lib/src/ui/chrome.dart`)

- **Own title bar:**
  - Drag anywhere along the top; double-click to maximise.
  - Compii-drawn minimise, maximise and close buttons; close turns red on hover.
- **Sidebar:**
  - Orbling with a live status dot, and a "New conversation" button with a Ctrl+N key cap.
  - Main pages, then recent conversations, each with a coloured status rail.
  - Safety and Settings at the bottom.
- **Pages share one header:** a tinted glyph tile, a big title and one line of description.
  Cards, option rows, pills, key caps and empty states are shared components.
- **Home:**
  - The Orbling on a soft aura that changes colour with its mood.
  - A large greeting and a large message box.
  - Suggestion cards that lift on hover.
- **Conversation:**
  - The header has a status pill.
  - Approval cards carry a "Needs your okay" pill and a tinted halo.
  - The plan marks steps with calm rings instead of spinners.
  - The progress panel has a progress bar and an activity count.
