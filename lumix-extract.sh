#!/bin/bash
# Copy all photos/videos from the Lumix card into ~/Desktop/ai.videospeed/Lumix/,
# sorted by media type (photos/videos) and color profile (log/colored).
#
# Source:  /Volumes/LUMIX/DCIM/101_PANA  (mounted SD card)
# Dest:    ~/Desktop/ai.videospeed/Lumix/{photos,videos}/{log,colored}/
# Deps:    exiftool (brew install exiftool), BSD stat (macOS default)
#
# Classification is based on the Panasonic PhotoStyle MakerNote read by exiftool.
# Unlike DJI, Panasonic writes the PhotoStyle reliably into both JPG EXIF and
# MOV QuickTime metadata, so a single exiftool pass over the card gives us a
# trustworthy log/colored split for free — no visual inspection needed.
#   PhotoStyle == "V-Log"  -> log
#   anything else          -> colored

# Fail fast on errors, unset vars, and broken pipes — long copy loops should
# not silently continue past a problem.
set -euo pipefail

SRC="/Volumes/LUMIX/DCIM/101_PANA"
# Override AI_VIDEOSPEED_ROOT in your shell to point this at any drive
# (e.g. export AI_VIDEOSPEED_ROOT=/Volumes/External/ai.videospeed).
ROOT="${AI_VIDEOSPEED_ROOT:-$HOME/Desktop/ai.videospeed}"
DEST="$ROOT/Lumix"

if [ ! -d "$SRC" ]; then
  echo "Lumix card not found at $SRC. Is it mounted?"
  exit 1
fi

if ! command -v exiftool >/dev/null 2>&1; then
  echo "exiftool not found. Install with: brew install exiftool"
  exit 1
fi

mkdir -p "$DEST/photos/log" "$DEST/photos/colored" \
         "$DEST/videos/log" "$DEST/videos/colored"

echo "Scanning metadata on $SRC ..."
# One exiftool invocation handles the whole card — spawning per-file is ~10x
# slower because exiftool's Perl startup dominates each call.
# Output is tab-separated: <PhotoStyle><TAB><filename>
manifest="$(mktemp)"
# Clean up the manifest on any exit path (success, error, or Ctrl-C).
trap 'rm -f "$manifest"' EXIT
exiftool -q -q -T -PhotoStyle -filename "$SRC"/*.JPG "$SRC"/*.MOV > "$manifest"

total=$(wc -l < "$manifest" | tr -d ' ')
echo "Found $total files. Copying into $DEST ..."
echo

i=0
while IFS=$'\t' read -r style filename; do
  i=$((i+1))
  src_file="$SRC/$filename"
  [ -f "$src_file" ] || continue

  case "${filename##*.}" in
    JPG|jpg) media="photos" ;;
    MOV|mov) media="videos" ;;
    *)       continue ;;
  esac

  # Panasonic has written this tag as both "V-Log" and "VLog" across firmware
  # revisions; match either, and treat anything else (Natural, Standard, etc.)
  # as already-graded "colored" footage.
  case "$style" in
    *V-Log*|*VLog*) profile="log" ;;
    *)              profile="colored" ;;
  esac

  dst_dir="$DEST/$media/$profile"
  dst_file="$dst_dir/$filename"

  # Idempotent re-run: same-size file at destination is assumed identical and
  # skipped. `stat -f %z` is BSD stat (macOS) — GNU's `stat -c %s` would fail.
  if [ -f "$dst_file" ] && [ "$(stat -f %z "$src_file")" = "$(stat -f %z "$dst_file")" ]; then
    printf "[%3d/%d] skip (already copied): %s\n" "$i" "$total" "$filename"
    continue
  fi

  printf "[%3d/%d] %s -> %s/%s\n" "$i" "$total" "$filename" "$media" "$profile"
  # `cp -p` preserves mtime — important for chronological sorting later.
  cp -p "$src_file" "$dst_file"
done < "$manifest"

echo
echo "Done. Summary:"
for media in photos videos; do
  for profile in log colored; do
    dir="$DEST/$media/$profile"
    count=$(find "$dir" -maxdepth 1 -type f \( -iname '*.JPG' -o -iname '*.MOV' \) | wc -l | tr -d ' ')
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    printf "  %-7s / %-7s : %4s files, %s\n" "$media" "$profile" "$count" "$size"
  done
done
echo
echo "Total: $(du -sh "$DEST" | cut -f1) at $DEST"
