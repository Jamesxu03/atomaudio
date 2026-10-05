#!/bin/zsh
# Packages Audio Input for friends and colleagues: dist/Audio-Input-<version>.dmg.
# The speech model is inside the app, so it works offline from the first launch and never
# needs Hugging Face. Usage: Scripts/make_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Audio Input.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" App/Info.plist)
DMG="dist/Audio-Input-$VERSION.dmg"
STAGING="dist/staging"

Scripts/build_app.sh --bundle-model

# Smoke test: the packaged app must load its own copy of the model and hear a known clip.
echo "Checking the packaged app…"
CHECK=$("$APP/Contents/MacOS/AudioInput" --check-models TestClips/synthetic/tts_001.wav)
echo "$CHECK"
if ! grep -q "from app bundle" <<< "$CHECK" || ! grep -qi "free for a quick call" <<< "$CHECK"; then
  echo "The packaged app didn't load its bundled model or transcribe the test clip." >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Audio Input.app"
ln -s /Applications "$STAGING/Applications"
cp App/DMG-ReadMe.txt "$STAGING/Read Me First.txt"

# ULMO = LZMA: the slowest to build but the smallest download.
hdiutil create -volname "Audio Input" -srcfolder "$STAGING" -fs HFS+ -format ULMO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
hdiutil verify "$DMG" >/dev/null

echo
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
