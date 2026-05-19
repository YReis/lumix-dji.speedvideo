#!/bin/bash
# Apply a 3D LUT to V-Log photos and videos under ~/Desktop/ai.videospeed/Lumix/{photos,videos}/log/,
# saving graded copies under ~/Desktop/ai.videospeed/Lumix/Graded/<LUT>/{photos,videos}/.
# Originals are not modified.
#
# Source:  ~/Desktop/ai.videospeed/Lumix/{photos,videos}/log/
# Dest:    ~/Desktop/ai.videospeed/Lumix/Graded/<LUT>/{photos,videos}/
# LUTs:    DaVinci Resolve user LUT folder, "myS1ii vlog luts"
# Deps:    ffmpeg with lut3d filter + hevc_videotoolbox (default on macOS builds)
#
# Videos are re-encoded with HEVC via Apple VideoToolbox (hardware) for
# fast, delivery-quality output suitable for Google Photos / QuickTime —
# not for editing.

set -euo pipefail

LUT_DIR="$HOME/Library/Containers/com.blackmagic-design.DaVinciResolveLite/Data/Library/Application Support/LUT/myS1ii vlog luts"
# Override AI_VIDEOSPEED_ROOT in your shell to point this at any drive
# (e.g. export AI_VIDEOSPEED_ROOT=/Volumes/External/ai.videospeed).
ROOT="${AI_VIDEOSPEED_ROOT:-$HOME/Desktop/ai.videospeed}"
SRC="$ROOT/Lumix"
PHOTOS_SRC="$SRC/photos/log"
VIDEOS_SRC="$SRC/videos/log"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found. Install with: brew install ffmpeg"
  exit 1
fi

if [ ! -d "$LUT_DIR" ]; then
  echo "LUT directory not found: $LUT_DIR"
  exit 1
fi

# Discover available LUTs (basename without .cube). Process substitution + while
# loop is used instead of `mapfile`/`readarray` so this works on the system bash
# 3.2 that ships with macOS.
luts=()
while IFS= read -r line; do
  luts+=("$line")
done < <(find "$LUT_DIR" -maxdepth 1 -name '*.cube' -type f -exec basename {} .cube \; | sort)

if [ "${#luts[@]}" -eq 0 ]; then
  echo "No .cube LUTs found in $LUT_DIR"
  exit 1
fi

selected=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lut) selected="${2:-}"; shift 2 ;;
    --lut=*) selected="${1#--lut=}"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--lut <name>]

Applies a 3D LUT (.cube) to V-Log photos and videos in:
  $PHOTOS_SRC
  $VIDEOS_SRC

Output goes to:
  $SRC/Graded/<LUT>/photos/
  $SRC/Graded/<LUT>/videos/

Without --lut, prompts you to pick from available LUTs.

Available LUTs:
$(printf '  - %s\n' "${luts[@]}")
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$selected" ]; then
  echo "Available LUTs:"
  idx=1
  for name in "${luts[@]}"; do
    printf "  %2d) %s\n" "$idx" "$name"
    idx=$((idx+1))
  done
  echo
  read -r -p "Pick a LUT (number or name): " choice
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    i=$((choice-1))
    if [ "$i" -lt 0 ] || [ "$i" -ge "${#luts[@]}" ]; then
      echo "Invalid number."
      exit 1
    fi
    selected="${luts[$i]}"
  else
    selected="$choice"
  fi
fi

lut_path="$LUT_DIR/$selected.cube"
if [ ! -f "$lut_path" ]; then
  echo "LUT not found: $lut_path"
  echo "Available: ${luts[*]}"
  exit 1
fi

# ffmpeg's lut3d filter has fragile escaping for paths with spaces, colons, and
# backslashes. The DaVinci Resolve container path contains all three, and
# escaping it inline (\:, \\, etc.) is unreliable across ffmpeg versions. Copy
# the chosen LUT to a no-spaces temp path and reference that instead.
# $$ in the filename keeps concurrent runs from stepping on each other.
safe_lut="/tmp/lumix-grade-$$.cube"
# Remove the temp LUT on any exit path (success, error, or Ctrl-C).
trap 'rm -f "$safe_lut"' EXIT
cp "$lut_path" "$safe_lut"

photos_dst="$SRC/Graded/$selected/photos"
videos_dst="$SRC/Graded/$selected/videos"
mkdir -p "$photos_dst" "$videos_dst"

echo
echo "LUT:    $selected"
echo "Photos: $PHOTOS_SRC -> $photos_dst"
echo "Videos: $VIDEOS_SRC -> $videos_dst"
echo

# nullglob so empty source folders expand to nothing instead of the literal
# glob string (which would break the for loop below).
shopt -s nullglob

# --- Photos ---
photos=("$PHOTOS_SRC"/*.JPG)
total_photos=${#photos[@]}
echo "Photos: $total_photos files"
i=0
for src in "${photos[@]}"; do
  i=$((i+1))
  name=$(basename "$src")
  dst="$photos_dst/$name"
  if [ -f "$dst" ]; then
    printf "[photo %3d/%d] skip: %s\n" "$i" "$total_photos" "$name"
    continue
  fi
  printf "[photo %3d/%d] %s\n" "$i" "$total_photos" "$name"
  # -q:v 2 is near-max JPEG quality (mjpeg uses 1=best, 31=worst).
  if ! ffmpeg -nostdin -loglevel error -i "$src" \
        -vf "lut3d=$safe_lut" \
        -q:v 2 \
        -y "$dst"; then
    # Remove partial output so the next run retries this file.
    rm -f "$dst"
    echo "Failed on $name" >&2
    exit 1
  fi
done

# --- Videos ---
videos=("$VIDEOS_SRC"/*.MOV)
total_videos=${#videos[@]}
echo
echo "Videos: $total_videos files"
i=0
for src in "${videos[@]}"; do
  i=$((i+1))
  name=$(basename "$src")
  dst="$videos_dst/$name"
  if [ -f "$dst" ]; then
    printf "[video %3d/%d] skip: %s\n" "$i" "$total_videos" "$name"
    continue
  fi
  printf "[video %3d/%d] %s\n" "$i" "$total_videos" "$name"
  # Encoder settings — calibrated once, do not tweak casually:
  #   hevc_videotoolbox : Apple HW HEVC encoder, real-time+ on Apple Silicon.
  #   -q:v 65           : VideoToolbox quality (0-100). 65 = sweet spot
  #                       between size and quality for Google Photos delivery;
  #                       higher numbers balloon file size with no visible
  #                       gain on phone/QuickTime playback. Not for editing.
  #   -tag:v hvc1       : QuickTime/Apple Photos need 'hvc1' (not 'hev1') or
  #                       they refuse to play the file.
  #   -c:a copy         : Lumix LPCM/AAC audio is fine, no need to re-encode.
  #   +faststart        : Move moov atom to the head so streaming/upload
  #                       services can begin playback before full download.
  if ! ffmpeg -nostdin -loglevel error -stats -i "$src" \
        -vf "lut3d=$safe_lut" \
        -c:v hevc_videotoolbox -q:v 65 -tag:v hvc1 \
        -c:a copy \
        -movflags +faststart \
        -y "$dst"; then
    # Drop the partial file so a re-run retries cleanly.
    rm -f "$dst"
    echo "Failed on $name" >&2
    exit 1
  fi
done

echo
echo "Done. Summary:"
for dir in "$photos_dst" "$videos_dst"; do
  count=$(find "$dir" -maxdepth 1 -type f \( -iname '*.JPG' -o -iname '*.MOV' \) | wc -l | tr -d ' ')
  size=$(du -sh "$dir" 2>/dev/null | cut -f1)
  printf "  %-60s : %4s files, %s\n" "${dir/#$HOME/~}" "$count" "$size"
done
