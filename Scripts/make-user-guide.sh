#!/bin/zsh
# Builds "docs/LP User Guide.pdf" from docs/user-guide/guide.html and its screenshots.
#
#   Scripts/make-user-guide.sh
#
# Update the guide whenever something a user sees changes (the owner's documentation rule):
# edit docs/user-guide/guide.html, replace screenshots in docs/user-guide/images/ (capture them
# with Scripts/snapshot.sh, LP_SNAPSHOT_SCREEN=retina), then run this.

ROOT="${0:A:h:h}"
BIN="$ROOT/.build/make-user-guide"
mkdir -p "$ROOT/.build"
rm -f "$BIN"  # so a failed compile can't leave an old builder behind
swiftc -O -parse-as-library -o "$BIN" "$ROOT/Scripts/make-user-guide.swift" 2>&1 | grep -E "error" | head -20
[[ -x "$BIN" ]] || { echo "The guide builder did not compile."; exit 1; }
"$BIN" "$ROOT/docs/user-guide/guide.html" "$ROOT/docs/LP User Guide.pdf"
