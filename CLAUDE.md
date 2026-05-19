# ai.videospeed — videoscripts

Personal shell scripts for offloading and grading footage on macOS from two cameras:

- **Panasonic Lumix DC-S1M2 (S1 II)** — V-Log color profile
- **DJI Osmo Action 6** (model AC006) — D-Log M color profile

Output lives under `~/Desktop/ai.videospeed/` with one subfolder per camera. The `videoscripts/` folder sits at the top level and is shared between cameras.

All four scripts resolve their working root as `${AI_VIDEOSPEED_ROOT:-$HOME/Desktop/ai.videospeed}`. If a user reports unexpected paths or "missing" files, check `echo $AI_VIDEOSPEED_ROOT` in their shell first — it commonly points at an external drive (e.g. `/Volumes/<name>/ai.videospeed`). The DaVinci Resolve LUT folders under `~/Library/Containers/com.blackmagic-design...` are not affected by the env var.

## Project layout

```
~/Desktop/ai.videospeed/
├── Lumix/
│   ├── photos/{log,colored}/    # originals from card (V-Log vs everything else)
│   ├── videos/{log,colored}/
│   └── Graded/<LUT>/{photos,videos}/   # LUT-applied copies
├── OsmoAction/
│   ├── photos/{log,colored}/    # originals from card (D-Log M assumed by default)
│   ├── videos/{log,colored}/
│   └── Graded/<LUT>/{photos,videos}/
└── videoscripts/
    ├── CLAUDE.md
    ├── lumix-extract.sh
    ├── lumix-grade.sh
    ├── osmo-extract.sh
    └── osmo-grade.sh
```

Each camera has the same shape: card → `<Camera>/photos/{log,colored}/` and `<Camera>/videos/{log,colored}/` for originals, then `<Camera>/Graded/<LUT>/{photos,videos}/` for graded outputs.

## Scripts

### `lumix-extract.sh`
Copies all `.JPG` and `.MOV` files from a mounted Lumix SD card into `~/Desktop/ai.videospeed/Lumix/`, sorted by media type and color profile.

- **Source:** `/Volumes/LUMIX/DCIM/101_PANA`
- **Destination:** `~/Desktop/ai.videospeed/Lumix/{photos,videos}/{log,colored}/`
- **Copies** (does not move) — the card is left untouched.
- **Idempotent:** files already present at destination with the same size are skipped, so re-runs after adding new shots only copy the delta.
- **Classification** is driven by the Panasonic `PhotoStyle` MakerNote read via `exiftool` — `V-Log` (or `VLog`) → `log/`, anything else → `colored/`. This applies to both photos and videos.

### `lumix-grade.sh`
Applies a 3D LUT (`.cube`) from the DaVinci Resolve user LUT folder (`myS1ii vlog luts`) to V-Log files under `Lumix/{photos,videos}/log/` and writes graded copies into `Lumix/Graded/<LUT>/{photos,videos}/`.

- **Output:**
  - Photos: JPG, `-q:v 2`, high quality.
  - Videos: HEVC via Apple VideoToolbox HW (`-q:v 65`, `hvc1` tag, faststart) — delivery-grade, fast, sized for Google Photos / QuickTime.
- **Selection:** `--lut <name>` (no `.cube` extension) to apply directly, or no arg to be prompted.
- **Idempotent:** if the destination file exists it is skipped. Partial outputs from a failed ffmpeg run are deleted so re-runs retry that file.
- **`--polish-pro` flag** — comprehensive preset for overcast/tropical footage (Khao Sok) with mixed Caucasian + East-Asian skin tones, output sized for IG/YouTube delivery. Filter chain and rationale:
  - Pre-LUT (log space, more latitude for denoise + temperature shifts):
    - `hqdn3d=4:3:6:4.5` — temporal+spatial denoise. Stronger spatial chroma (6) because overcast/log footage shows the most noise in chroma midtones.
    - `colortemperature=temperature=5500:mix=0.2` — warm 20% toward 5500K to undo the cool cast of overcast skies. Done in log so highlights don't clip.
  - LUT chain — the user's chosen LUT (V-Log → Rec.709 for Lumix).
  - Post-LUT (Rec.709):
    - `colortemperature=temperature=5600:mix=0.15:pl=0.5` — small extra warmth, `pl=0.5` makes it luminance-aware so highlights don't go orange.
    - `eq=contrast=1.05:saturation=1.08:gamma=1.0` — saturation capped at 1.08 because anything ≥1.10 pushes Asian skin tones orange; contrast 1.05 is the gentle nudge that still leaves room for IG/YT's own re-compression.
    - `unsharp=3:3:0.4:3:3:0.0` — 3×3 light sharpen, **chroma amount = 0.0** so we don't sharpen color noise.
  - Encoder differs from the default `-q:v 65`:
    - HEVC Main10 with `p010le` pixel format (preserve 10-bit log latitude through the chain).
    - `-b:v 70M -maxrate 80M -bufsize 140M` — YouTube 4K60 SDR recommends 53-68 Mbps; 70 gives headroom for their VP9/AV1 re-encode.
    - Explicit Rec.709 tagging: `-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv` so IG/YT don't mis-detect the file as HDR.
    - `-tag:v hvc1`, `-movflags +faststart`, audio `copy` — same as default.

### `osmo-extract.sh`
Copies all `.JPG` and `.MP4` files from a mounted DJI Osmo Action card into `~/Desktop/ai.videospeed/OsmoAction/`, by media type.

- **Source:** `/Volumes/OsmoAction/DCIM/DJI_001`
- **Destination:** `~/Desktop/ai.videospeed/OsmoAction/{photos,videos}/log/`
- **Skips** `.LRF`, `.SCR`, `.THM` — those are DJI's proxy preview/thumbnail files that only matter on the card.
- **All files are routed into `log/`** because DJI does not expose the color profile in any readable metadata (see the **D-Log M detection** note below). The `colored/` folders are created empty for future use if you want to sort Normal-mode footage there manually.
- **Idempotent** (same name+size skip rule as the Lumix extract).

### `osmo-grade.sh`
Identical structure to `lumix-grade.sh`, but reads from `OsmoAction/{photos,videos}/log/` and uses LUTs from `myDJI dlogm luts` (Alister Chapman's free D-Log M creative LUT pack — 9 looks including `s709` for the neutral D-Log M → Rec.709 conversion). Encoder settings are the same (HEVC VideoToolbox, `-q:v 65`).

- **`--polish` flag** — light post-LUT cleanup pass. Lower-overhead than `--polish-pro`.
- **`--polish-pro` flag** — same comprehensive preset as `lumix-grade.sh --polish-pro` (see above for the full filter rationale: pre-LUT `hqdn3d` + 5500K warm shift in log, post-LUT luminance-aware warmth + `eq` capped at saturation 1.08 to keep Asian skin tones from going orange, chroma-off `unsharp`, HEVC Main10 p010le, `-b:v 70M -maxrate 80M -bufsize 140M`, explicit Rec.709 tagging). The Osmo variant runs after Osmo's auto LUT chain (`DJI_Base → DJI_Look_*`), so the polish chain sees Rec.709 pixels at the same stage as the Lumix variant.

## D-Log M detection (DJI Osmo Action)

DJI does **not** write any reliable color-profile tag in the MP4 container — `exiftool` shows `BT.709/BT.709/BT.709` for D-Log M *and* Normal recordings. There is also no `.SRT` telemetry file like the drones produce; the Osmo Action's `MISC/THM/DJI_001/` only holds `.SCR` (720p JPEG preview) and `.THM` (256-px thumbnail) files, both rendered straight from the recorded buffer (no display LUT applied).

The reliable methods for telling D-Log M from Normal apart, in order of usefulness:

1. **Visual inspection** — D-Log M out of the camera looks flat, low-contrast, and desaturated. Normal looks like a regular video.
2. **`signalstats` on a sampled frame or on the `.SCR` preview.** Run `ffmpeg -i <file> -vf signalstats,metadata=mode=print -f null -` and look at:
   - `SATAVG` — typically 5-15 for D-Log M, 25+ for Normal in daylight (8-bit JPEG scale).
   - `YMAX` — D-Log M usually peaks lower; Normal hits near 255 / 1015 (10-bit).
   The single-frame stats are scene-dependent — a strong cluster in `SATAVG < ~13` across many clips is a robust signal of mostly-log footage; a clear outlier above 25 is almost always Normal.
3. **Apply the D-Log M → Rec.709 LUT and look** ("if it looks like shit after converting to Rec709 it wasn't D-Log M" — Reddit, and also the universal truth here).

In practice `osmo-extract.sh` skips all of that and dumps everything into `log/`. If you remember shooting some clips in Normal, you can spot-check the SCRs in `MISC/THM/DJI_001/` (or the extracted JPGs/MP4s) and move those into `colored/` manually before running the grade step.

## Dependencies

- **exiftool** — `brew install exiftool`. Required by `lumix-extract.sh` for reading the Panasonic `PhotoStyle` MakerNote.
- **ffmpeg** — `brew install ffmpeg`. Required by both `*-grade.sh` scripts. Must include `hevc_videotoolbox` (default on macOS builds) and the `lut3d` filter (default).
- **bash 3.2+** (system bash is fine), **rsync**-free (uses plain `cp`), and macOS `stat -f` (BSD stat — not GNU).
- **DaVinci Resolve** (free or Studio) for the LUT folders. The scripts read `.cube` files from:
  - `~/Library/Containers/com.blackmagic-design.DaVinciResolveLite/Data/Library/Application Support/LUT/myS1ii vlog luts/` (Lumix)
  - `~/Library/Containers/com.blackmagic-design.DaVinciResolveLite/Data/Library/Application Support/LUT/myDJI dlogm luts/` (Osmo Action — Alister Chapman's free pack)

## Conventions for new scripts in this folder

- Keep scripts self-contained; no shared lib.
- Use `set -euo pipefail`.
- Default source path is the camera card mount; fail fast with a clear message if not mounted.
- Default destination is somewhere under `${AI_VIDEOSPEED_ROOT:-$HOME/Desktop/ai.videospeed}` so output is visible — honor the env var instead of hard-coding `~/Desktop/...`.
- Never delete from the SD card without an explicit flag.
- Re-encoded video defaults to HEVC VideoToolbox with `-q:v 65`, `-tag:v hvc1`, `-movflags +faststart`, audio `copy` — delivery-quality, Google-Photos-ready, real-time+ on Apple Silicon.
