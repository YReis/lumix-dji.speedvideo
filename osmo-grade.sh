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
while [ $# -gt 0 ]; do
  case "$1" in
    --lut) selected="${2:-}"; shift 2 ;;
    --lut=*) selected="${1#--lut=}"; shift ;;
    --polish) polish=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--lut <name>] [--polish]

Applies a 3D LUT (.cube) to D-Log M photos and videos in:
  $PHOTOS_SRC
  $VIDEOS_SRC

Output goes to:
  $SRC/Graded/<LUT>[_polish]/photos/
  $SRC/Graded/<LUT>[_polish]/videos/

Options:
  --lut <name>    Apply the named LUT. Without this flag, prompts for selection.
  --polish        Add a finishing pass after the LUT chain: light denoise
                  (hqdn3d) + light sharpen (unsharp) + small contrast & sat
                  boost (eq). Helps Action 6 footage (small sensor noise +
                  log softness). Adds ~30% to encoding time, no size impact.

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

# --polish: post-LUT finishing pass. Approximates the typical "node 5"
# polish step from a DaVinci Resolve workflow — gentle denoise to clean
# small-sensor grain, gentle sharpen to compensate the inherent log+HEVC
# softness, and a small contrast/saturation lift to fight the Rec.709
# flatness the LUT alone leaves behind.
#
# Values are deliberately CONSERVATIVE so this is safe to apply across an
# entire batch unattended. Aggressive denoise eats detail in well-lit clips;
# aggressive sharpen amplifies HEVC artifacts on the noisy low-light ones;
# heavy eq crushes already-saturated looks. The picked numbers below help
# the worst clips visibly without damaging the best ones.
output_suffix=""
if [ "$polish" -eq 1 ]; then
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
  # Encoder settings — calibrated once, do not tweak casually:
  #   hevc_videotoolbox    : Apple HW HEVC encoder, real-time+ on Apple Silicon.
  #   -profile:v main10    : 10-bit HEVC profile. REQUIRED for D-Log M sources;
  #   -pix_fmt p010le        falling back to 8-bit main / yuv420p produces
  #                          visible banding in skies and skin gradients after
  #                          the log->Rec.709 stretch.
  #   -q:v 65              : VideoToolbox quality (0-100). 65 is calibrated
  #                          for Google Photos delivery — higher numbers
  #                          inflate file size with no perceivable gain on
  #                          phone/QuickTime playback. Not for editing.
  #   -tag:v hvc1          : QuickTime/Apple Photos need 'hvc1' (not 'hev1')
  #                          or they refuse to play the file.
  #   -c:a copy            : Osmo audio is already AAC, no need to re-encode.
  #   +faststart           : Move moov atom to the head for streaming.
  if ! ffmpeg -nostdin -loglevel error -stats -i "$src" \
        -vf "$lut_filter" \
        -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -q:v 65 -tag:v hvc1 \
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
