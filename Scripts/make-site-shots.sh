#!/bin/zsh
# Captures the screenshots on LP's website with the harness, in LP's light and dark looks, and
# writes them cropped and compressed into the site's assets/shots/: AVIF for each look, plus a
# JPEG of the light look for browsers without AVIF. Run it when LP's look changes, then
# Scripts/make-site.py.
#
#   Scripts/build.sh harness                       # first
#   Scripts/make-site-shots.sh [site folder]       # default: ../LTF-Git-Dev.github.io
#
# The harness window comes to the front for a few seconds per look (LP_SNAPSHOT_ACTIVATE=1, so it
# looks like an active window). It works on a fresh demo workspace named "Notes" in
# .build/site-vault; outside .build it writes only the site's assets/shots/. Captures must be
# Retina (2560 × 1600): the crops below are in those pixels.

set -e
ROOT="${0:A:h:h}"
SITE="${${1:-$ROOT/../LTF-Git-Dev.github.io}:A}"
SHOTS="$SITE/assets/shots"
APP="$ROOT/.build/DerivedDataHarness/Build/Products/Debug/LP.app"
[[ -d "$APP" ]] || { echo "Build the harness first: Scripts/build.sh harness"; exit 1; }
[[ -d "$SITE" ]] || { echo "No site folder at $SITE"; exit 1; }

TOOL="$ROOT/.build/site-image"
rm -f "$TOOL"
swiftc -O -o "$TOOL" "$ROOT/Scripts/site-image.swift" 2>&1 | grep -E "error" | head -5 || true
[[ -x "$TOOL" ]] || { echo "Scripts/site-image.swift did not compile."; exit 1; }

SCENARIO='route:home ;; wait:900 ;; shot:home ;; open:Projects/Website Redesign.md ;; wait:700 ;; shot:editor ;; demo-calendar ;; route:calendar ;; wait:900 ;; shot:calendar ;; open:Projects/Launch Board.md ;; board-progress ;; wait:900 ;; shot:board ;; board-progress:off ;; wait:400 ;; shot:board-plain ;; route:home ;; wait:600 ;; palette:launch ;; wait:900 ;; shot:search ;; close-palette ;; open:Projects/Website Redesign.md ;; focus ;; find:spring launch. ;; type:\n/ ;; wait:800 ;; shot:slash'

for look in light dark; do
  rm -rf "$ROOT/.build/site-vault" "$ROOT/.build/shots/site-$look"
  mkdir -p "$ROOT/.build/site-vault"
  "$ROOT/Scripts/make-demo-vault.sh" "$ROOT/.build/site-vault/Notes" > /dev/null
  LP_WORKSPACE="$ROOT/.build/site-vault/Notes" LP_SNAPSHOT_ACTIVATE=1 LP_APPEARANCE=$look \
    LP_SNAPSHOT_SCREEN=retina LP_SNAPSHOT_SIZE=1280x800 \
    "$ROOT/Scripts/snapshot.sh" "site-$look" "$SCENARIO" > /dev/null
  for capture in home editor calendar board board-plain search slash; do
    file="$ROOT/.build/shots/site-$look/$capture.png"
    [[ -f "$file" ]] || { echo "The harness didn't capture $capture ($look)."; exit 1; }
    size=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ { printf "%s ", $2 }')
    [[ "$size" == "2560 1600 " ]] || { echo "$capture ($look) is ${size}pixels, not 2560 1600: capture on a Retina display."; exit 1; }
  done
done

mkdir -p "$SHOTS"
# name on the site | harness capture | crop x,y,w,h | output width | corner radius (AVIF only;
# the page rounds the JPEG). The progress panel ends between its two rows of numbers; the search
# palette and the slash menu are cut along their own borders.
SPECS=(
  "home|home|0,0,2560,1600|2240|0"
  "notes|editor|760,150,1600,1000|1360|0"
  "calendar|calendar|1136,110,1424,1260|960|0"
  "progress|board|1930,110,630,638|630|0"
  "board|board-plain|540,150,1420,860|1360|0"
  "search|search|660,272,1240,818|1240|24"
  "slash|slash|808,584,568,700|568|22"
)
for spec in $SPECS; do
  IFS='|' read -r name capture crop width radius <<< "$spec"
  for look in light dark; do
    "$TOOL" "$ROOT/.build/shots/site-$look/$capture.png" "$SHOTS/$name-$look.avif" crop=$crop width=$width quality=0.6 radius=$radius
  done
  "$TOOL" "$ROOT/.build/shots/site-light/$capture.png" "$SHOTS/$name-light.jpg" crop=$crop width=$width quality=0.8
done
echo "Wrote $SHOTS. Now run Scripts/make-site.py."
