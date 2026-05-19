#!/bin/bash
# Copy all photos/videos from the DJI Osmo Action card into
# ~/Desktop/ai.videospeed/OsmoAction/, sorted by media type.
#
# Source:  /Volumes/OsmoAction/DCIM/DJI_001  (mounted card)
# Dest:    ~/Desktop/ai.videospeed/OsmoAction/{photos,videos}/{log,colored}/
# Deps:    BSD stat (macOS default) — no exiftool needed (see below)
#
# Unlike the Lumix workflow, we cannot reliably detect color profile here:
# the Osmo Action does NOT expose D-Log M vs Normal in any readable metadata
# field. DJI writes BT.709 to the container regardless of the recording
# profile (verified empirically with exiftool, mediainfo, and ffprobe on
# Action 6 firmware — every method reports identical tags for both modes).
# So we treat all footage as D-Log M and route it into log/ subfolders, and
# the grade step applies a D-Log M -> Rec.709 LUT uniformly. The colored/
# folders are created empty for the rare case of Normal-mode clips you want
# to sort there manually after spot-checking visually.
#
# .LRF (low-res H.264 proxy for in-camera playback), .SCR and .THM (preview
# JPEG + 256px thumbnail) are skipped — they only matter on the card itself,
# nothing on Mac uses them.

# Fail fast on errors, unset vars, and broken pipes.
set -euo pipefail

SRC="/Volumes/OsmoAction/DCIM/DJI_001"
# Override AI_VIDEOSPEED_ROOT in your shell to point this at any drive
# (e.g. export AI_VIDEOSPEED_ROOT=/Volumes/External/ai.videospeed).
ROOT="${AI_VIDEOSPEED_ROOT:-$HOME/Desktop/ai.videospeed}"
DEST="$ROOT/OsmoAction"

if [ ! -d "$SRC" ]; then
  echo "Osmo Action card not found at $SRC. Is it mounted?"
  exit 1
fi

mkdir -p "$DEST/photos/log" "$DEST/photos/colored" \
         "$DEST/videos/log" "$DEST/videos/colored"

# Build list of relevant files (JPG photos + MP4 videos). The glob naturally
# excludes .LRF/.SCR/.THM. nullglob makes an empty match expand to nothing
# instead of the literal pattern.
shopt -s nullglob
files=("$SRC"/*.JPG "$SRC"/*.MP4)
# Strip macOS resource-fork shadow files (._FOO.MP4) that appear when the card
# has previously been mounted on an HFS+/APFS-aware system. exFAT cards mostly
# avoid this but we filter defensively.
filtered=()
for f in "${files[@]}"; do
  name=$(basename "$f")
  [[ "$name" == ._* ]] && continue
  filtered+=("$f")
done
files=("${filtered[@]}")

total=${#files[@]}
echo "Found $total files (JPG + MP4). Copying into $DEST ..."
echo

i=0
for src_file in "${files[@]}"; do
  i=$((i+1))
  filename=$(basename "$src_file")

  case "${filename##*.}" in
    JPG|jpg) media="photos" ;;
    MP4|mp4) media="videos" ;;
    *)       continue ;;
  esac

  # Assume D-Log M for everything (see comment at top).
  dst_dir="$DEST/$media/log"
  dst_file="$dst_dir/$filename"

  # Idempotent re-run: skip if a same-size file already exists at the
  # destination. `stat -f %z` is BSD stat (macOS); GNU `stat -c %s` would
  # not work here.
  if [ -f "$dst_file" ] && [ "$(stat -f %z "$src_file")" = "$(stat -f %z "$dst_file")" ]; then
    printf "[%3d/%d] skip (already copied): %s\n" "$i" "$total" "$filename"
    continue
  fi

  printf "[%3d/%d] %s -> %s/log\n" "$i" "$total" "$filename" "$media"
  # -p preserves mtime so timeline-ordered tools see the original capture time.
  cp -p "$src_file" "$dst_file"
done

echo
echo "Done. Summary:"
for media in photos videos; do
  for profile in log colored; do
    dir="$DEST/$media/$profile"
    count=$(find "$dir" -maxdepth 1 -type f \( -iname '*.JPG' -o -iname '*.MP4' \) | wc -l | tr -d ' ')
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    printf "  %-7s / %-7s : %4s files, %s\n" "$media" "$profile" "$count" "$size"
  done
done
echo
echo "Total: $(du -sh "$DEST" | cut -f1) at $DEST"
