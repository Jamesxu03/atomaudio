#!/bin/zsh
# Builds build/Audio Input.app. Usage: Scripts/build_app.sh [--open] [--bundle-model]
#   --bundle-model  put the speech model (452 MB) inside the app, for sharing (see make_dmg.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Audio Input.app"
BUNDLE_ID="local.audioinput"
# "-" = ad-hoc signature. Set SIGN_IDENTITY to a real certificate to keep permissions across rebuilds.
IDENTITY="${SIGN_IDENTITY:--}"
MODEL="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
FLUIDAUDIO=".build/checkouts/FluidAudio"

OPEN=0
BUNDLE_MODEL=0
for arg in "$@"; do
  case "$arg" in
    --open) OPEN=1 ;;
    --bundle-model) BUNDLE_MODEL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if (( BUNDLE_MODEL )) && [[ ! -f "$MODEL/parakeet_vocab.json" ]]; then
  echo "The speech model isn't downloaded yet. Run the app once, or: swift run -c release Bench --engines parakeet-v2" >&2
  exit 1
fi

swift build -c release --product AudioInput
pkill -x AudioInput 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AudioInput "$APP/Contents/MacOS/AudioInput"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Licenses for what the app contains: our notes, then FluidAudio's license and its third-party notices.
{
  cat App/Acknowledgements.txt
  echo "=============================================================================="
  echo "FluidAudio — Apache License 2.0"
  echo "=============================================================================="
  cat "$FLUIDAUDIO/LICENSE"
  for notice in "$FLUIDAUDIO"/ThirdPartyLicenses/*; do
    echo
    echo "=============================================================================="
    echo "FluidAudio third-party notice: $(basename "$notice")"
    echo "=============================================================================="
    cat "$notice"
  done
} > "$APP/Contents/Resources/Acknowledgements.txt"

if (( BUNDLE_MODEL )); then
  mkdir -p "$APP/Contents/Resources/Models"
  # -c clones on APFS: instant, and no extra disk space until the copy changes.
  cp -Rc "$MODEL" "$APP/Contents/Resources/Models/"
fi

# Extended attributes (Finder info, download flags) on copied files make codesign refuse to sign.
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

if [[ "$IDENTITY" == "-" ]]; then
  # Each ad-hoc build looks like a new app to macOS, so old permission grants no longer match.
  # Clear them so the app asks cleanly on next launch.
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo "Built $APP"
if (( OPEN )); then open "$APP"; fi
