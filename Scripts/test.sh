#!/bin/zsh
# Compiles and runs the standalone test suites. No Xcode project or simulator needed.
#
#   Scripts/test.sh            all suites
#   Scripts/test.sh markdown   one suite: markdown | calendar | safety | widgets | reminders | tasks | search | updates | boards | ownership
#   LP_TEST_VERBOSE=1 Scripts/test.sh ownership   prints every ownership check (who may change what)

ROOT="${0:A:h:h}"
SRC="$ROOT/Local Productivity"
mkdir -p "$ROOT/.build"
ONLY="${1:-all}"
STATUS=0

run_suite() {
  local name="$1"; shift
  [[ "$ONLY" == "all" || "$ONLY" == "$name" ]] || return 0
  local binary="$ROOT/.build/tests-$name"
  rm -f "$binary"
  swiftc -Onone -module-name "LPTests_$name" "$@" -o "$binary" 2>&1 | grep -E "error|warning: var|warning: imm" | head -40
  if [[ -x "$binary" ]]; then
    printf "%-10s" "$name:"
    "$binary" || STATUS=1
  else
    echo "$name: did not compile"
    STATUS=1
  fi
}

run_suite markdown \
  "$SRC/Markdown/"*.swift "$ROOT/Tests/MarkdownTests/main.swift"

run_suite calendar \
  "$SRC/App/Day.swift" \
  "$SRC/Calendar/Sync/CalendarSyncModels.swift" \
  "$SRC/Calendar/Sync/OAuthCore.swift" \
  "$SRC/Calendar/Sync/GoogleCalendarMapping.swift" \
  "$SRC/Calendar/Sync/MicrosoftGraphMapping.swift" \
  "$ROOT/Tests/CalendarTests/main.swift"

run_suite safety \
  "$SRC/Workspace/Safety.swift" "$ROOT/Tests/SafetyTests/main.swift"

run_suite widgets \
  "$SRC/../Shared/WidgetSnapshot.swift" "$ROOT/Tests/WidgetTests/main.swift"

run_suite reminders \
  "$SRC/App/Day.swift" "$SRC/Reminders/ReminderPlanner.swift" "$ROOT/Tests/ReminderTests/main.swift"

run_suite tasks \
  "$SRC/App/Day.swift" "$SRC/Markdown/"*.swift "$SRC/Workspace/PageTasks.swift" "$ROOT/Tests/TaskTests/main.swift"

run_suite search \
  "$SRC/Search/SearchHit.swift" "$ROOT/Tests/SearchTests/main.swift"

run_suite updates \
  "$ROOT/UpdateCore/UpdateCore.swift" "$ROOT/Tests/UpdateTests/main.swift"

if [[ -d "$ROOT/Tests/BoardTests" ]]; then
  run_suite boards \
    "$SRC/App/Day.swift" \
    "$SRC/Markdown/"*.swift \
    "$SRC/Boards/Model/"*.swift \
    "$SRC/Workspace/Safety.swift" \
    "$ROOT/Tests/BoardTests/main.swift"
fi

# Person A makes something; person B (or a forged file, link or sign-in reply) tries to change it.
run_suite ownership \
  "$SRC/App/Day.swift" \
  "$SRC/Markdown/"*.swift \
  "$SRC/Boards/Model/"*.swift \
  "$SRC/Workspace/Safety.swift" \
  "$SRC/Calendar/Sync/CalendarSyncModels.swift" \
  "$SRC/Calendar/Sync/OAuthCore.swift" \
  "$SRC/../Shared/WidgetSnapshot.swift" \
  "$ROOT/Tests/OwnershipTests/main.swift"

exit $STATUS
