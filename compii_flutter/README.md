# Compii Flutter

First vertical slice: a shared Windows/Android application in `apps/companion` implements the Wisp presentation and local appearance preferences. The planned desktop/mobile split will follow when device roles and pairing require separate shells; keeping one app now avoids duplicated presentation logic.

Run from `apps/companion`:

```powershell
C:/flutter/bin/flutter.bat pub get
C:/flutter/bin/flutter.bat run -d windows
C:/flutter/bin/flutter.bat test
```

The first slice is a **local character preview**, with no microphone capture, AI requests, screen capture, pairing, desktop overlay or computer actions. Mode selection previews the intended interaction style. Appearance is persisted locally. Full-body movement is inside the app window.

See `../../../docs/compii/` from the app directory for the product specification.
