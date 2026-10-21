---
name: Flutter APK target
description: The intended app platform and delivery format for this project.
---

The intended deliverable is the Flutter Android app packaged as an APK for installation on a phone. Treat the React/Vite web app as the reference for expected workflows and features; adjust Flutter to match it rather than changing the web app.

**Why:** the user said the web app is the correct version and Flutter should be adjusted, while retaining the Android APK as the deliverable.

**How to apply:** treat Flutter as the app being discussed and changed; use the React app only as a feature reference when useful. Keep Flutter's layout responsive to phones, and do not answer Flutter questions by describing web-only behavior unless the user asks about the web app.

The Replit environment currently provides Flutter 3.32.0 / Dart 3.8.0, below this project's Dart >=3.10.3 constraint, and its configured Android SDK path is absent. `scripts/flutter.sh` falls back to the system Flutter when its project-local SDK is missing, so analyze/build attempts can fail at dependency resolution before checking app code.

**Why:** APK verification on 2026-10-20 was blocked by the installed toolchain version and missing Android SDK.

**How to apply:** provision a compatible Flutter SDK and Android SDK before claiming an APK build or device test passed; do not lower the app's SDK constraint just to match the stale system Flutter.
