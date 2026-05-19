#!/bin/bash
# Apply a 3D LUT to D-Log M photos and videos from the DJI Osmo Action under
# ~/Desktop/ai.videospeed/OsmoAction/{photos,videos}/log/, saving graded
# copies under ~/Desktop/ai.videospeed/OsmoAction/Graded/<LUT>/{photos,videos}/.
# Originals are not modified.
#
# Source:  ~/Desktop/ai.videospeed/OsmoAction/{photos,videos}/log/
# Dest:    ~/Desktop/ai.videospeed/OsmoAction/Graded/<LUT>[_polish]/{photos,videos}/
# LUTs:    DaVinci Resolve user LUT folder, "myDJI dlogm luts"
# Deps:    ffmpeg with lut3d filter + hevc_videotoolbox (default on macOS builds)
#
# Videos are re-encoded with HEVC via Apple VideoToolbox (hardware) — 10-bit
# main10 / p010le pixel format because D-Log M is a 10-bit format and crushing
# it to 8-bit in the output causes visible banding in skies and skin tones.
# Encoder is tuned for delivery (Google Photos / QuickTime), not editing.

set -euo pipefail

LUT_DIR="$HOME/Library/Containers/com.blackmagic-design.DaVinciResolveLite/Data/Library/Application Support/LUT/myDJI dlogm luts"
# Override AI_VIDEOSPEED_ROOT in your shell to point this at any drive
# (e.g. export AI_VIDEOSPEED_ROOT=/Volumes/External/ai.videospeed).
ROOT="${AI_VIDEOSPEED_ROOT:-$HOME/Desktop/ai.videospeed}"
SRC="$ROOT/OsmoAction"
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

# Discover available LUTs. Process-substitution + while loop instead of
# mapfile/readarray so this runs on macOS system bash 3.2.
luts=()
while IFS= read -r line; do
  luts+=("$line")
done < <(find "$LUT_DIR" -maxdepth 1 -name '*.cube' -type f -exec basename {} .cube \; | sort)

if [ "${#luts[@]}" -eq 0 ]; then
  echo "No .cube LUTs found in $LUT_DIR"
  exit 1
fi

selected=""
polish=0
polish_pro=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lut) selected="${2:-}"; shift 2 ;;
    --lut=*) selected="${1#--lut=}"; shift ;;
    --polish) polish=1; shift ;;
    --polish-pro) polish_pro=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--lut <name>] [--polish | --polish-pro]

Applies a 3D LUT (.cube) to D-Log M photos and videos in:
  $PHOTOS_SRC
  $VIDEOS_SRC

Output goes to:
  $SRC/Graded/<LUT>[_polish|_polish-pro]/photos/
  $SRC/Graded/<LUT>[_polish|_polish-pro]/videos/

Options:
  --lut <name>    Apply the named LUT. Without this flag, prompts for selection.
  --polish        Light finishing pass after the LUT chain: gentle denoise
                  (hqdn3d) + light sharpen (unsharp) + small contrast & sat
                  boost (eq). Encoder stays at 10-bit q:v 65 (Google Photos
                  quality). Adds ~30% to encoding time, no size impact.
  --polish-pro    Comprehensive overcast/tropical + skin-safe + IG/YT delivery:
                  pre-LUT denoise + WB warm-up (in log space, more latitude),
                  stronger post-LUT polish, HEVC 10-bit Main10 at 70 Mbps
                  target with explicit Rec.709 tagging for IG/YouTube.
                  Skin-friendly (Caucasian + East-Asian skin both preserved).
                  ~40% slower encode, ~2x file size vs default.

Available LUTs:
$(printf '  - %s\n' "${luts[@]}")
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --polish-pro implies --polish (it's the strictly-more-comprehensive variant).
if [ "$polish_pro" -eq 1 ]; then
  polish=0
fi

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

# ffmpeg's lut3d filter has fragile escaping for paths with spaces, colons and
# backslashes; the DaVinci Resolve container path has all three. Copy the
# chosen LUT (and the base LUT, if we chain) to a no-spaces temp path under
# /tmp and reference that. $$ in the name avoids collisions between concurrent
# runs.
safe_lut="/tmp/osmo-grade-$$.cube"
safe_base="/tmp/osmo-grade-base-$$.cube"
# Clean up both temp LUTs on any exit path (success, error, or Ctrl-C).
trap 'rm -f "$safe_lut" "$safe_base"' EXIT
cp "$lut_path" "$safe_lut"

# Auto-chain logic. DJI ships their D-Log M LUT pack as a two-stage system:
#   DJI_Base_DLogM-Rec709.cube  — the technical D-Log M -> Rec.709 conversion.
#   DJI_Look_*.cube             — creative looks that ASSUME Rec.709 input.
# Applying a DJI_Look_* directly to raw D-Log M produces wrong colors (black
# crush, broken saturation), so we always prepend the base LUT for those.
#
# Other LUTs are applied directly:
#   - DJI_Base_DLogM-Rec709 itself (it IS the conversion).
#   - Third-party packs like Alister Chapman's D-LOG-M_* — these include their
#     own D-Log M -> Rec.709 conversion baked in, just with a different
#     transfer-curve assumption than the Action 6 actually records. Kept
#     around for A/B comparison, but we never chain them with the DJI base
#     (would double-apply the conversion and crush the image).
case "$selected" in
  DJI_Look_*)
    base_lut_path="$LUT_DIR/DJI_Base_DLogM-Rec709.cube"
    if [ ! -f "$base_lut_path" ]; then
      echo "Base LUT not found: $base_lut_path"
      echo "DJI_Look_* LUTs require DJI_Base_DLogM-Rec709.cube to chain from."
      exit 1
    fi
    cp "$base_lut_path" "$safe_base"
    # Filter chain: D-Log M -> Rec.709 (base) -> creative look.
    lut_filter="lut3d=$safe_base,lut3d=$safe_lut"
    chain_note="chained: DJI_Base_DLogM-Rec709 -> $selected"
    ;;
  *)
    lut_filter="lut3d=$safe_lut"
    chain_note="direct (no chain)"
    ;;
esac

# Two polish levels:
#   --polish      : light post-LUT pass. Calibrated for the Action 6's small
#                   sensor (ISO 800+ grain) and the inherent log-tape softness.
#                   Conservative values so it's safe across a batch unattended.
#   --polish-pro  : pre-LUT denoise + WB warm in log space (more latitude),
#                   then LUT, then stronger post-LUT polish. Tuned for the
#                   overcast tropical scenario (Khao Sok-like: cool light,
#                   low contrast, lush greens) and mixed Caucasian +
#                   East-Asian skin (saturation kept ≤1.08, no red/yellow
#                   selectivecolor pushes that would shift skin orange).
#
# Output suffix in the folder name keeps polish vs no-polish vs polish-pro
# variants from overwriting each other in `Graded/<LUT>[_suffix]/`.
output_suffix=""
chain_pre=""
if [ "$polish_pro" -eq 1 ]; then
  #   Pre-LUT (log space):
  #     hqdn3d=4:3:6:4.5  : ffmpeg defaults; aggressive enough on log noise.
  #     colortemperature=5500 mix=0.2 : ~20% pull toward 5500K warm, undoing
  #                                     the cool cast of overcast tropical light.
  #   Post-LUT (Rec.709 space):
  #     colortemperature=5600 mix=0.15 pl=0.5 : tiny extra warmth, luminance-aware.
  #     eq=contrast=1.05:saturation=1.08:gamma=1.0 : skin-safe boundaries.
  #                                                 Above sat 1.10 starts pushing
  #                                                 East-Asian skin orange.
  #     unsharp=3:3:0.4:3:3:0.0 : small 3x3 luma sharpen, chroma off.
  chain_pre="hqdn3d=4:3:6:4.5,colortemperature=temperature=5500:mix=0.2,"
  lut_filter="${chain_pre}${lut_filter},colortemperature=temperature=5600:mix=0.15:pl=0.5,eq=contrast=1.05:saturation=1.08:gamma=1.0,unsharp=3:3:0.4:3:3:0.0"
  chain_note="$chain_note + polish-pro (pre+post LUT, skin-safe)"
  output_suffix="_polish-pro"
elif [ "$polish" -eq 1 ]; then
  #   hqdn3d=2:1:3:2  : spatial-luma=2, spatial-chroma=1, temporal-luma=3,
  #                     temporal-chroma=2. Below ffmpeg defaults (4:3:6:4.5);
  #                     enough to clean Action 6 ISO 800+ grain, light enough
  #                     to preserve foliage and skin texture.
  #   unsharp=5:5:0.3:5:5:0.0 : 5x5 luma kernel at strength 0.3 (default 1.0),
  #                     chroma off. Subtle acuity, no halos.
  #   eq=contrast=1.05:saturation=1.05 : 5% lift on each. Just enough to undo
  #                     the typical post-LUT flatness without making the
  #                     image look "AI-enhanced".
  lut_filter="${lut_filter},hqdn3d=2:1:3:2,unsharp=5:5:0.3:5:5:0.0,eq=contrast=1.05:saturation=1.05"
  chain_note="$chain_note + polish (denoise+sharpen+eq)"
  output_suffix="_polish"
fi

# Encoder selection. Default and --polish keep the Google-Photos-tuned q:v 65.
# --polish-pro upgrades to IG/YouTube max-bitrate VBR with explicit Rec.709
# color tagging so the platforms don't mis-detect as HDR.
if [ "$polish_pro" -eq 1 ]; then
  # YouTube 4K60 SDR recommends 53-68 Mbps; 70 Mbps gives headroom for their
  # VP9/AV1 re-encode. Instagram caps at ~25 Mbps but accepts higher source.
  # Main10/p010le preserves D-Log M's 10-bit precision through the chain.
  video_encoder=(-c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le \
                 -b:v 70M -maxrate 80M -bufsize 140M -tag:v hvc1 \
                 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv)
else
  video_encoder=(-c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -q:v 65 -tag:v hvc1)
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
# glob pattern (which would otherwise enter the loop as a fake "file").
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
        -vf "$lut_filter" \
        -q:v 2 \
        -y "$dst"; then
    # Remove partial output so a re-run retries this file.
    rm -f "$dst"
    echo "Failed on $name" >&2
    exit 1
  fi
done

# --- Videos ---
videos=("$VIDEOS_SRC"/*.MP4)
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
  # Encoder settings come from the $video_encoder array built above based on
  # which --polish flag (if any) was passed. Common to all variants:
  #   -tag:v hvc1     : QuickTime/Apple Photos/IG need 'hvc1' (not 'hev1').
  #   -c:a copy       : Osmo audio is already AAC, no need to re-encode.
  #   +faststart      : moov atom up front for streaming.
  if ! ffmpeg -nostdin -loglevel error -stats -i "$src" \
        -vf "$lut_filter" \
        "${video_encoder[@]}" \
        -c:a copy \
        -movflags +faststart \
        -y "$dst"; then
    # Drop partial output so a re-run retries this file cleanly.
    rm -f "$dst"
    echo "Failed on $name" >&2
    exit 1
  fi
done

echo
echo "Done. Summary:"
for dir in "$photos_dst" "$videos_dst"; do
  count=$(find "$dir" -maxdepth 1 -type f \( -iname '*.JPG' -o -iname '*.MP4' \) | wc -l | tr -d ' ')
  size=$(du -sh "$dir" 2>/dev/null | cut -f1)
  printf "  %-60s : %4s files, %s\n" "${dir/#$HOME/~}" "$count" "$size"
done
