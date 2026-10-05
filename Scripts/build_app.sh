#!/bin/zsh
# Builds build/Audio Input.app. Usage: Scripts/build_app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Audio Input.app"
BUNDLE_ID="local.audioinput"
# "-" = ad-hoc signature. Set SIGN_IDENTITY to a real certificate to keep permissions across rebuilds.
IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --product AudioInput
pkill -x AudioInput 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AudioInput "$APP/Contents/MacOS/AudioInput"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

if [[ "$IDENTITY" == "-" ]]; then
  # Each ad-hoc build looks like a new app to macOS, so old permission grants no longer match.
  # Clear them so the app asks cleanly on next launch.
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
