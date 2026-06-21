#!/usr/bin/env bash
# App Store screenshots: boot each device, install the built app, deep-link to
# each screen via PROSPER_UI_SCREEN, capture at native device resolution.
#   ./screenshots.sh            # iPhone + iPad
set -euo pipefail
cd "$(dirname "$0")"

APP=".build-xcode/Build/Products/Debug-iphonesimulator/Prosper.app"
BID="eu.illegible.prosperios"
OUT="../store/screenshots"
mkdir -p "$OUT"

# device label : simulator name
DEVICES=(
  "iphone67:iPhone 17 Pro Max"
  "ipad13:iPad Pro 13-inch (M5)"
)
# file suffix : env value (empty = home)
SCREENS=(
  "1-home:"
  "2-connect:connect"
  "3-terminal:demo-terminal"
)

build_for() { # $1 = sdk
  xcodebuild -project Prosper.xcodeproj -scheme Prosper -configuration Debug \
    -destination "platform=iOS Simulator,name=$2" \
    -derivedDataPath "$PWD/.build-xcode" CODE_SIGNING_ALLOWED=NO build \
    >/dev/null 2>&1
}

for d in "${DEVICES[@]}"; do
  label="${d%%:*}"; name="${d#*:}"
  echo "==> $name"
  build_for sim "$name"
  xcrun simctl boot "$name" 2>/dev/null || true
  xcrun simctl bootstatus "$name" -b >/dev/null 2>&1 || true
  xcrun simctl install "$name" "$BID" >/dev/null 2>&1 || true
  xcrun simctl install "$name" "$APP"
  # Clean, store-friendly status bar (9:41, full battery/wifi).
  xcrun simctl status_bar "$name" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi 2>/dev/null || true
  # Pre-warm: launch once and let first-boot system banners (Apple Intelligence,
  # etc.) expire before capturing, so they don't overlay the shots.
  xcrun simctl launch "$name" "$BID" >/dev/null 2>&1 || true
  sleep 12
  xcrun simctl terminate "$name" "$BID" 2>/dev/null || true
  for s in "${SCREENS[@]}"; do
    suffix="${s%%:*}"; env="${s#*:}"
    xcrun simctl terminate "$name" "$BID" 2>/dev/null || true
    if [ -n "$env" ]; then
      SIMCTL_CHILD_PROSPER_UI_SCREEN="$env" xcrun simctl launch "$name" "$BID" >/dev/null
    else
      xcrun simctl launch "$name" "$BID" >/dev/null
    fi
    sleep 5                                  # let SwiftUI settle / demo script play
    xcrun simctl io "$name" screenshot "$OUT/${label}_${suffix}.png" >/dev/null
    echo "   $OUT/${label}_${suffix}.png"
  done
done
echo "done."
