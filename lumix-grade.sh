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
polish_pro=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lut) selected="${2:-}"; shift 2 ;;
    --lut=*) selected="${1#--lut=}"; shift ;;
    --polish-pro) polish_pro=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--lut <name>] [--polish-pro]

Applies a 3D LUT (.cube) to V-Log photos and videos in:
  $PHOTOS_SRC
  $VIDEOS_SRC

Output goes to:
  $SRC/Graded/<LUT>[_polish-pro]/photos/
  $SRC/Graded/<LUT>[_polish-pro]/videos/

Options:
  --lut <name>    Apply the named LUT. Without this flag, prompts.
  --polish-pro    Comprehensive overcast/tropical + skin-safe + IG/YT delivery:
                  pre-LUT WB warm-up + denoise (in log space, more latitude),
                  post-LUT skin-friendly polish (curves/sat/sharpen tuned to
                  not push Caucasian or East-Asian skin too red/orange),
                  HEVC 10-bit Main10 at 70 Mbps target with explicit Rec.709
                  tagging for IG/YouTube. ~40% slower encode, ~2x file size
                  vs the default 8-bit q:v 65, but upload-quality ready.

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

# --polish-pro: comprehensive pipeline for overcast/tropical V-Log delivery
# to Instagram / YouTube. Pre-LUT denoise + WB warm in log space (more
# latitude), then LUT, then post-LUT polish (light skin-safe contrast/sat
# bump + sharpen). Encoder upgrades to 10-bit HEVC at IG/YT-friendly bitrate.
# Skin-safety: saturation stays ≤1.08, no red/yellow selectivecolor pushes,
# so neither Caucasian nor East-Asian skin shifts orange.
if [ "$polish_pro" -eq 1 ]; then
  pre_lut="hqdn3d=4:3:6:4.5,colortemperature=temperature=5500:mix=0.2"
  post_lut="colortemperature=temperature=5600:mix=0.15:pl=0.5,eq=contrast=1.05:saturation=1.08:gamma=1.0,unsharp=3:3:0.4:3:3:0.0"
  vf_video="${pre_lut},lut3d=$safe_lut,${post_lut}"
  vf_photo="lut3d=$safe_lut,${post_lut}"
  # IG/YT upload preset (per YouTube docs + Meta engineering blog):
  #   Main10 / p010le : preserve 10-bit V-Log latitude through the encoder.
  #   -b:v 70M        : YouTube 4K60 SDR recommended 53-68 Mbps; 70 gives
  #                     headroom for their VP9/AV1 re-encode.
  #   -maxrate/bufsize: VBR ceiling so peaks don't exceed bandwidth.
  #   Explicit Rec.709 color tagging prevents IG/YT mis-detecting as HDR.
  video_encoder=(-c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le \
                 -b:v 70M -maxrate 80M -bufsize 140M -tag:v hvc1 \
                 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv)
  output_suffix="_polish-pro"
  chain_note="polish-pro (pre+post LUT + 10-bit 70Mbps IG/YT)"
else
  vf_video="lut3d=$safe_lut"
  vf_photo="lut3d=$safe_lut"
  # Default: 8-bit HEVC at quality 65, calibrated for Google Photos delivery.
  video_encoder=(-c:v hevc_videotoolbox -q:v 65 -tag:v hvc1)
  output_suffix=""
  chain_note="direct"
fi

photos_dst="$SRC/Graded/${selected}${output_suffix}/photos"
videos_dst="$SRC/Graded/${selected}${output_suffix}/videos"
mkdir -p "$photos_dst" "$videos_dst"

echo
echo "LUT:    $selected ($chain_note)"
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
        -vf "$vf_photo" \
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
  # Encoder settings come from the $video_encoder array — see the
  # --polish-pro branch above for the IG/YT 10-bit variant. Common to both:
  #   -tag:v hvc1   : QuickTime/Apple Photos/IG need 'hvc1' (not 'hev1').
  #   -c:a copy     : Lumix LPCM/AAC audio is fine, no need to re-encode.
  #   +faststart    : moov atom up front so streaming services can begin
  #                   playback before the file finishes downloading.
  if ! ffmpeg -nostdin -loglevel error -stats -i "$src" \
        -vf "$vf_video" \
        "${video_encoder[@]}" \
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
