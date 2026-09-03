#!/bin/sh
# Regenerate docs/screens/*.png from the code.
#
# Each screen is built through the widget's own layout against the recording
# LVGL mock, then drawn at true resolution with EdgeTX's font line heights.
# Run this after any layout change, or the pictures in the README start lying.
#
#   tools/make_screens.sh
#
# Needs lua and python3 with Pillow.
set -e
cd "$(dirname "$0")/.."
out=docs/screens
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"

# width height kind name
set -- \
  "800 480 dash    tx16s-dashboard"  \
  "800 480 sensors tx16s-sensormap"  \
  "800 480 empty   tx16s-notelemetry" \
  "800 480 safe    tx16s-safemode"   \
  "480 320 dash    tx15-dashboard"   \
  "480 320 sensors tx15-sensormap"

for spec in "$@"; do
  # shellcheck disable=SC2086
  set -- $spec
  lua tools/dump_screen.lua "$1" "$2" "$3" > "$tmp/$4.txt"
  python3 tools/render_screen.py "$tmp/$4.txt" "$out/$4.png"
done
