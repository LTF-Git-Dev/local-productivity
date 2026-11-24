#!/bin/zsh
# Builds LP's MCP server (lp-mcp) from LP's own Foundation-only code into .build/lp-mcp.
#   Scripts/build-mcp.sh            optimised build
# Then, to connect it (after review): see docs/MCP.md.
set -e
ROOT="${0:A:h:h}"
SRC="$ROOT/Local Productivity"
mkdir -p "$ROOT/.build"
swiftc -O -module-name lp_mcp \
  "$SRC/App/Day.swift" "$SRC/Markdown/"*.swift "$SRC/Workspace/PageTasks.swift" "$SRC/Workspace/Safety.swift" \
  "$SRC/Boards/Model/"*.swift "$ROOT/MCP/"*.swift \
  -o "$ROOT/.build/lp-mcp"
echo "Built $ROOT/.build/lp-mcp"
