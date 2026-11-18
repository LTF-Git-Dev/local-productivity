#!/bin/zsh
# Builds the Debug configuration from the command line and prints only diagnostics.
#
#   Scripts/build.sh            Sandboxed build, exactly what Xcode produces.
#   Scripts/build.sh harness    Unsandboxed build used by Scripts/snapshot.sh so the
#                               app can read a demo workspace and write PNG files anywhere.
#
# Set LP_TEAM_ID to sign with your Apple ID team (Scripts/signing-team.sh finds it). Without a
# team LP is signed ad hoc, which works for everything except sharing data with its widgets.
#
# Xcode.app is used explicitly, so this works even when `xcode-select` points at the
# Command Line Tools.

set -o pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="${0:A:h:h}"
MODE="${1:-sandbox}"

if [[ "$MODE" == "harness" ]]; then
  DERIVED="$ROOT/.build/DerivedDataHarness"
  EXTRA=(ENABLE_APP_SANDBOX=NO)
else
  DERIVED="$ROOT/.build/DerivedData"
  EXTRA=()
fi

[[ -n "${LP_TEAM_ID:-}" ]] && EXTRA+=(DEVELOPMENT_TEAM="$LP_TEAM_ID" -allowProvisioningUpdates)

cd "$ROOT" || exit 1
xcodebuild -project "Local Productivity.xcodeproj" -scheme "Local Productivity" \
  -configuration Debug -derivedDataPath "$DERIVED" "${EXTRA[@]}" build 2>&1 \
  | grep -E "(error|warning):|\*\* BUILD|^ld: |Undefined symbols|duplicate symbol" \
  | grep -v "appintentsmetadataprocessor" \
  | sed "s|$ROOT/Local Productivity/||" \
  | awk '!seen[$0]++' \
  | head -${LP_BUILD_LINES:-70}
