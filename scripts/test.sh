#!/bin/bash
# The unit tests on a simulator.
#   scripts/test.sh fast <sim-udid> <derived-data> [xcodebuild args]   the quick tier, about a minute of tests
#   scripts/test.sh full <sim-udid> <derived-data> [xcodebuild args]   everything: before a push, and after
#                                                                     any change to the keyboards' editing or typing
# Extra args go to xcodebuild, e.g. -only-testing:ProsperTests/ShareTests.
# The fast tier skips the exhaustive sweeps below: 23 tests that take ~460 s of the ~525 s.
set -euo pipefail
tier=${1:?fast or full}; sim=${2:?simulator udid}; dd=${3:?derived data path}; shift 3
cd "$(dirname "$0")/../app"

slow=(
    TypoRateTests/testProseWithAThumb
    KeyboardToolbarTests/testATapQueuedInAStallReachesNothingInTheNewField
    KeyboardToolbarTests/testAFieldSwitchMidEditReachesNothingInTheNewField
    TypoRateTests/testTheLiftCutsTheTypoRate
    KeyboardToolbarTests/testQAHostsDeleteAll
    KeyboardToolbarTests/testQAHostsTakeTheExtentOnly
    KeyboardToolbarTests/testLineEditsOnALongLineTakeEachCharacterOnce
    TypoRateTests/testRunOnsAndSlipsThroughAutocorrect
    TerminalKeyboardTests/testHostedKeyboardFollowsItsHeight
    SessionVerbTests/testLongWaitStillReturnsTheReply
    KeyboardToolbarTests/testATapQueuedInAStallReachesNothingAfterTheEditsOwnStepsThere
    KeyboardToolbarTests/testDeleteAllEmptiesALongTextOnARealHost
    KeyboardToolbarTests/testAPressBehindDeleteAllGoesOnceTheFieldIsEmpty
    KeyboardToolbarTests/testAFieldSwitchMidKeptEditOnASlowHostReachesNothingInTheNewField
    SessionConnectionDeliveryTests/testASecondRefusalRestartsTheNoticeTimer
    KeyboardToolbarTests/testDeleteAllTakesTheTextAfterTheCaretOnlyOnceAllBeforeWent
    KeyboardToolbarTests/testLineEditsFreeTheToolbarWithinASecondOfTheFieldShowingEmpty
    KeyboardToolbarTests/testAWalkUnderWayStopsAtAFieldSwitch
    SessionConnectionDeliveryTests/testLateHandBackIsClassifiedByThePasteOpenerNotSize
    RotationResizeTests/testRepairAfterRotationStatesTheSizeAndSkipsTheMirror
    KeyboardToolbarTests/testDeleteLineTakesTheLineAndABreak
    ImagePasteTests/testOnceModifierRaisesKeyboardOnlyAfterDoubleTapWindow
    RotationResizeTests/testSnapshotWaitsForOutputToGoQuiet
)
skip=()
[ "$tier" = fast ] && for t in "${slow[@]}"; do skip+=("-skip-testing:ProsperTests/$t"); done

exec /usr/bin/xcodebuild test -project Prosper.xcodeproj -scheme Prosper -destination "id=$sim" \
    -derivedDataPath "$dd" -skipPackagePluginValidation -collect-test-diagnostics never \
    CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO ${skip[@]+"${skip[@]}"} "$@"
