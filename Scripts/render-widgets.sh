#!/bin/zsh
# Renders LP's widgets with sample data into .build/shots/widgets (or the given folder), light
# and dark, without installing the extension.
#
#   Scripts/render-widgets.sh [folder [snapshot.json]]   (a snapshot the app wrote with
#                                                        LP_WIDGET_SNAPSHOT, instead of the sample)

ROOT="${0:A:h:h}"
OUT="${1:-$ROOT/.build/shots/widgets}"
BIN="$ROOT/.build/render-widgets"
mkdir -p "$ROOT/.build" "$OUT"
swiftc -parse-as-library -module-name RenderWidgets -o "$BIN" \
  "$ROOT/Shared/WidgetSnapshot.swift" \
  "$ROOT/LPWidgets/WidgetStyle.swift" "$ROOT/LPWidgets/TodayWidget.swift" \
  "$ROOT/LPWidgets/BoardWidget.swift" "$ROOT/LPWidgets/SampleSnapshot.swift" \
  "$ROOT/Scripts/render-widgets.swift" 2>&1 | grep -E "error" | head -20
[[ -x "$BIN" ]] && "$BIN" "$OUT" "${@:2}"
