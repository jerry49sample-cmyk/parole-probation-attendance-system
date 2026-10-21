#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_cache="$project_root/.build"
flutter_sdk="${FLUTTER_SDK:-$build_cache/flutter-3.47.7}"
android_sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$build_cache/android-sdk}}"

export PUB_CACHE="${PUB_CACHE:-$build_cache/pub-cache}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$build_cache/gradle}"
mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME"

if [[ -x "$flutter_sdk/bin/flutter" ]]; then
  flutter_bin="$flutter_sdk/bin/flutter"
elif command -v flutter >/dev/null 2>&1; then
  flutter_bin="$(command -v flutter)"
else
  echo "Flutter SDK not found. Set FLUTTER_SDK or install Flutter 3.38.4 or newer." >&2
  exit 1
fi

export PATH="$(dirname "$flutter_bin"):$PATH"
export ANDROID_SDK_ROOT="$android_sdk"
export ANDROID_HOME="$android_sdk"

exec "$flutter_bin" "$@"
