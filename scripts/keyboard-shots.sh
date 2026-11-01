#!/bin/bash
# The keyboard screenshots (#670): the README's gallery and the App Store's keyboard slides,
# drawn from the real keyboard views by ScreenshotTests with made-up sample data.
#   scripts/keyboard-shots.sh <sim-udid> <derived-data>    an iPhone Pro Max simulator: 440 pt wide, 3x
# Writes store/keyboard/keyboard-*.png (1320 px wide) and
# fastlane/screenshots/en-US/iphone67_7..10-*.png (1320x2868, no alpha).
set -euo pipefail
sim=${1:?simulator udid}; dd=${2:?derived data path}
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$out"' EXIT

TEST_RUNNER_PROSPER_SHOTS="$out" "$root/scripts/test.sh" fast "$sim" "$dd" -only-testing:ProsperTests/ScreenshotTests

shopt -s nullglob
shots=("$out"/keyboard-*.png) slides=("$out"/iphone67_*.png)
[ ${#shots[@]} -gt 0 ] && [ ${#slides[@]} -eq 4 ] || { echo "no shots in $out: did the test skip?" >&2; exit 1; }
/bin/mkdir -p "$root/store/keyboard"
/bin/cp "${shots[@]}" "$root/store/keyboard/"
/bin/cp "${slides[@]}" "$root/fastlane/screenshots/en-US/"
for f in "${shots[@]}" "${slides[@]}"; do echo "   $(/usr/bin/basename "$f")"; done
echo "done."
