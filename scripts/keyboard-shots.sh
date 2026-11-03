#!/bin/bash
# The keyboard screenshots (#670): the README's gallery and the App Store's slides,
# drawn from the real views (the app's on its offline demo) by ScreenshotTests with made-up sample data.
#   scripts/keyboard-shots.sh <sim-udid> <derived-data>
# On an iPhone Pro Max simulator (440 pt wide, 3x): store/keyboard/keyboard-*.png (1320 px wide) and
# fastlane/screenshots/en-US/iphone67_1..7-*.png (1320x2868).
# On an iPad Pro 13" simulator (1032 pt, 2x): fastlane/screenshots/en-US/ipad13_1..7-*.png (2064x2752)
# and iphoneduo_1..7-*.png (2007x2853, the iPhone Duo's inner display, drawn in a 669x951 pt window at 3x).
# Slides are opaque PNGs: the app's screens, then the keyboard's.
set -euo pipefail
sim=${1:?simulator udid}; dd=${2:?derived data path}
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$out"' EXIT

TEST_RUNNER_PROSPER_SHOTS="$out" "$root/scripts/test.sh" fast "$sim" "$dd" -only-testing:ProsperTests/ScreenshotTests

shopt -s nullglob
shots=("$out"/keyboard-*.png) phone=("$out"/iphone67_*.png) pad=("$out"/ipad13_*.png) duo=("$out"/iphoneduo_*.png)
if [ ${#phone[@]} -eq 7 ] && [ ${#shots[@]} -gt 0 ] && [ ${#pad[@]} -eq 0 ]; then
    slides=("${phone[@]}")
    /bin/mkdir -p "$root/store/keyboard"
    /bin/cp "${shots[@]}" "$root/store/keyboard/"
elif [ ${#pad[@]} -eq 7 ] && [ ${#duo[@]} -eq 7 ] && [ ${#phone[@]} -eq 0 ]; then
    slides=("${pad[@]}" "${duo[@]}") shots=()
else
    echo "no full set in $out: did the test skip, or is this neither an iPhone Pro Max nor an iPad Pro 13\"?" >&2; exit 1
fi
/bin/cp "${slides[@]}" "$root/fastlane/screenshots/en-US/"
for f in ${shots[@]+"${shots[@]}"} "${slides[@]}"; do echo "   $(/usr/bin/basename "$f")"; done
echo "done."
