#!/bin/zsh
# Launches the harness build, drives it through a scenario and writes PNG captures of the window.
#
#   Scripts/snapshot.sh <name> "<scenario>"
#
# A scenario is a list of steps separated by " ;; ", for example:
#   Scripts/snapshot.sh editor "open:Kitchen Sink.md ;; shot:top ;; scroll:600 ;; shot:middle"
# The available steps are listed in Local Productivity/Debug/SnapshotHarness.swift.
#
# Output lands in .build/shots/<name>/. Environment knobs (all optional):
#   LP_SNAPSHOT_SIZE=1280x800   window size in points
#   LP_SNAPSHOT_SCREEN=retina   capture on the highest-density display
#   LP_SNAPSHOT_ACTIVATE=1      bring the app to the front (captures the active appearance)
#   LP_APPEARANCE=light|dark    force an appearance
#   LP_WORKSPACE=/path          workspace folder to open (defaults to the demo workspace;
#                               set it to an empty string for the welcome screen)
#
# Build first with:  Scripts/build.sh harness

ROOT="${0:A:h:h}"
APP="$ROOT/.build/DerivedDataHarness/Build/Products/Debug/LP.app/Contents/MacOS/LP"
NAME="${1:-shot}"
SCENARIO="${2:-shot:window}"
OUT="$ROOT/.build/shots/$NAME"
mkdir -p "$OUT"

if [[ -z "${LP_WORKSPACE+x}" ]]; then
  [[ -d "$ROOT/.build/demo-vault" ]] || "$ROOT/Scripts/make-demo-vault.sh" > /dev/null
  export LP_WORKSPACE="$ROOT/.build/demo-vault"
fi

LP_SNAPSHOT_DIR="$OUT" LP_SNAPSHOT_SCENARIO="$SCENARIO" "$APP" -ApplePersistenceIgnoreState YES 2>&1 \
  | grep -v -E "CoreSVG|IMKCFRunLoopWakeUpReliable|TSM AdjustCapsLockLED|error messaging the mach port|ApplePersistenceIgnoreState" \
  | head -${LP_SNAPSHOT_LINES:-80}
ls "$OUT"
