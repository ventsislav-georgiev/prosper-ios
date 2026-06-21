#!/usr/bin/env bash
# Build + run Prosper. Default target is Mac Catalyst (real Mac app — gives
# end-to-end against the Prosper dch-server over Tailscale/loopback with no
# device or simulator). Pass `ios` to run in the iOS Simulator instead.
#
#   ./run.sh           # build + launch Mac Catalyst app
#   ./run.sh ios       # build + boot simulator + install + launch
#   ./run.sh device    # sign + build + install on connected iPhone + launch
#   ./run.sh build     # Catalyst build only, no launch
set -euo pipefail
cd "$(dirname "$0")/app"

DERIVED="$PWD/.build-xcode"
SCHEME=Prosper
PROJ=Prosper.xcodeproj
TEAM="${DEVELOPMENT_TEAM:-V5XV3994L8}"

echo "==> xcodegen"
# ponytail: OMC hooks drop .omc/ state dirs inside Sources/; xcodegen bundles them
# as duplicate resources and the build fails. Strip them before generating.
find Sources -name .omc -type d -prune -exec rm -rf {} + 2>/dev/null || true
xcodegen generate

MODE="${1:-catalyst}"

case "$MODE" in
  ios)
    DEST='platform=iOS Simulator,name=iPhone 16'
    echo "==> build (iOS Simulator)"
    xcodebuild -project "$PROJ" -scheme "$SCHEME" \
      -destination "$DEST" -derivedDataPath "$DERIVED" \
      -quiet build
    APP="$DERIVED/Build/Products/Debug-iphonesimulator/Prosper.app"
    BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
    echo "==> boot simulator + install + launch"
    xcrun simctl boot 'iPhone 16' 2>/dev/null || true
    open -a Simulator
    xcrun simctl install booted "$APP"
    xcrun simctl launch booted "$BUNDLE"
    ;;
  device)
    # macOS awk lacks {n} intervals and device "state" flips (connected/paused);
    # grab the first device UUID from the list and let install fail loudly if the
    # phone is locked/unplugged.
    DEVID=$(xcrun devicectl list devices 2>/dev/null \
      | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
      | head -1)
    [ -n "$DEVID" ] || { echo "no connected device" >&2; exit 1; }
    echo "==> build + sign (iOS device $DEVID, team $TEAM)"
    xcodebuild -project "$PROJ" -scheme "$SCHEME" \
      -destination "platform=iOS,id=$DEVID" -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES \
      -quiet build
    APP="$DERIVED/Build/Products/Debug-iphoneos/Prosper.app"
    BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
    echo "==> install + launch on device"
    xcrun devicectl device install app --device "$DEVID" "$APP"
    xcrun devicectl device process launch --device "$DEVID" "$BUNDLE" || true
    ;;
  build|catalyst)
    echo "==> build (Mac Catalyst)"
    xcodebuild -project "$PROJ" -scheme "$SCHEME" \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      -derivedDataPath "$DERIVED" -quiet build
    APP="$DERIVED/Build/Products/Debug-maccatalyst/Prosper.app"
    [ "$MODE" = build ] && { echo "built: $APP"; exit 0; }
    echo "==> launch"
    open "$APP"
    ;;
  *)
    echo "usage: $0 [catalyst|ios|build]" >&2; exit 2;;
esac
