# videoscripts

> macOS shell scripts for offloading and LUT-grading footage from a Panasonic Lumix S1 II (V-Log) and a DJI Osmo Action 6 (D-Log M).

A small, opinionated pipeline that copies card footage to a working folder, sorts it by color profile, and bakes a 3D LUT into delivery-grade HEVC. Idempotent — re-running after adding more clips only processes the new files.

## Why this exists

Two cameras, two log formats, one workflow:

- **Panasonic Lumix DC-S1M2 (S1 II)** — V-Log, classified per-file via the `PhotoStyle` EXIF MakerNote.
- **DJI Osmo Action 6** (AC006) — D-Log M, with no reliable color-profile tag in the container (see [D-Log M detection](#d-log-m-detection-dji-osmo-action) below).

Output is HEVC via Apple VideoToolbox so grading a card runs at real-time-plus on Apple Silicon and the resulting `.mp4`/`.jpg` files drop straight into Google Photos / QuickTime / Final Cut without further conversion.

## Quick start

```bash
# 1. Install dependencies
brew install exiftool ffmpeg

# 2. Place .cube LUTs in DaVinci Resolve's user LUT folder
#    (see Dependencies for full paths)

# 3. Mount your camera card, then:
./lumix-extract.sh           # or: ./osmo-extract.sh
./lumix-grade.sh --lut s709  # or: ./osmo-grade.sh --lut s709
```

Extract is non-destructive — it `cp`s from the card and leaves the original files in place.

### Configuration

By default the scripts read from and write to `~/Desktop/ai.videospeed/`. Set `AI_VIDEOSPEED_ROOT` to redirect the working folder anywhere — typically an external drive, to keep 50+ GB of footage off the internal disk or to share a project across machines on the same volume. Only the working data root moves; the DaVinci Resolve LUT folders are unchanged. Add the export to your `~/.zshrc` (or `~/.bashrc`) to make it persistent.

```bash
export AI_VIDEOSPEED_ROOT=/Volumes/MyExternal/ai.videospeed
```

## Scripts

| Script | Reads from | Writes to | Notes |
| --- | --- | --- | --- |
| `lumix-extract.sh` | `/Volumes/LUMIX/DCIM/101_PANA` | `Lumix/{photos,videos}/{log,colored}/` | Sorts by `PhotoStyle` MakerNote (V-Log vs. anything else) |
| `lumix-grade.sh` | `Lumix/{photos,videos}/log/` | `Lumix/Graded/<LUT>/{photos,videos}/` | Applies `.cube` from `myS1ii vlog luts` |
| `osmo-extract.sh` | `/Volumes/OsmoAction/DCIM/DJI_001` | `OsmoAction/{photos,videos}/log/` | Everything routed to `log/`; skips `.LRF`/`.SCR`/`.THM` |
| `osmo-grade.sh` | `OsmoAction/{photos,videos}/log/` | `OsmoAction/Graded/<LUT>/{photos,videos}/` | Applies `.cube` from `myDJI dlogm luts` |

### Common behavior

- All four scripts are **idempotent**: a destination file with matching name+size is skipped on re-run.
- Grade scripts encode video to HEVC with `-q:v 65`, `-tag:v hvc1`, `-movflags +faststart`, audio copied. Photos are JPG at `-q:v 2`.
- Partial outputs from a failed `ffmpeg` run are deleted so the next run retries that file.
- Pass `--lut <name>` (no `.cube` extension) to the grade scripts to apply a LUT non-interactively; omit it to be prompted.

### Quality presets

Both grade scripts accept optional flags that swap the encoder settings and add pre/post-LUT filters:

| Flag | Scripts | Encoder | Use for |
| --- | --- | --- | --- |
| (none) | both | HEVC VideoToolbox, `-q:v 65` (Lumix 8-bit / Osmo 10-bit) | Default. Direct LUT only. Google Photos / QuickTime. |
| `--polish` | osmo-grade.sh | same as default, plus a light post-LUT pass | Modest cleanup on Osmo footage. |
| `--polish-pro` | both | HEVC Main10 p010le, `-b:v 70M -maxrate 80M -bufsize 140M`, explicit Rec.709 tagging | Instagram / YouTube delivery. |

`--polish-pro` is tuned for overcast tropical footage (Khao Sok, Thailand) with mixed Caucasian + East-Asian skin tones. It chains a pre-LUT denoise (`hqdn3d=4:3:6:4.5`) and warm shift (`colortemperature=5500:mix=0.2`) in log space, the chosen LUT (plus Osmo's auto `DJI_Base → DJI_Look_*` chain), then a small luminance-aware warm bump, skin-safe `eq=contrast=1.05:saturation=1.08`, and a light chroma-off `unsharp` in Rec.709. Output is 10-bit Main10 at ~70 Mbps (YouTube 4K60 SDR recommends 53-68 Mbps; the extra headroom survives YouTube's VP9/AV1 re-encode). Rec.709 is tagged explicitly so Instagram and YouTube don't mis-detect the file as HDR.

```bash
./lumix-grade.sh --lut s709 --polish-pro
./osmo-grade.sh  --lut s709 --polish-pro
```

## Project layout

```
~/Desktop/ai.videospeed/
├── Lumix/
│   ├── photos/{log,colored}/
│   ├── videos/{log,colored}/
│   └── Graded/<LUT>/{photos,videos}/
├── OsmoAction/
│   ├── photos/{log,colored}/
│   ├── videos/{log,colored}/
│   └── Graded/<LUT>/{photos,videos}/
└── videoscripts/         # this repo
```

The base path defaults to `~/Desktop/ai.videospeed/` and can be overridden via `AI_VIDEOSPEED_ROOT` (see [Configuration](#configuration)).

## D-Log M detection (DJI Osmo Action)

If you found this repo searching for **DJI Osmo Action D-Log M detection** or **how to tell if Osmo Action footage is D-Log M**, here is what I found:

DJI does **not** write any reliable color-profile tag in the MP4. `exiftool` reports `BT.709/BT.709/BT.709` for D-Log M *and* Normal recordings, and unlike the drones there is no `.SRT` sidecar. The `MISC/THM/DJI_001/` folder only contains `.SCR` (720p JPEG preview) and `.THM` (256-px thumbnail) files, both rendered straight from the recorded buffer with no display LUT applied.

Reliable methods, in order of usefulness:

1. **Visual inspection.** D-Log M out of camera looks flat, low-contrast, and desaturated. Normal looks like a regular video.
2. **`signalstats` on a sampled frame or on the `.SCR` preview:**

   ```bash
   ffmpeg -i <file> -vf signalstats,metadata=mode=print -f null -
   ```

   Look at:
   - `SATAVG` — typically 5–15 for D-Log M, 25+ for Normal in daylight (8-bit JPEG scale).
   - `YMAX` — D-Log M peaks lower; Normal hits near 255 (8-bit) / 1015 (10-bit).

   Single-frame stats are scene-dependent. A cluster of clips with `SATAVG < ~13` is a robust signal of log footage; a clear outlier above 25 is almost always Normal.
3. **Apply the D-Log M → Rec.709 LUT and look.** "If it looks like shit after converting to Rec.709 it wasn't D-Log M" — Reddit, and also the universal truth here.

In practice `osmo-extract.sh` skips all of that and routes everything into `log/`. If you remember shooting some clips in Normal, spot-check the `.SCR` previews in `MISC/THM/DJI_001/` (or the extracted files) and move those into `colored/` before grading.

## Dependencies

| Tool | Install | Used by | Why |
| --- | --- | --- | --- |
| `exiftool` | `brew install exiftool` | `lumix-extract.sh` | Reads Panasonic `PhotoStyle` MakerNote |
| `ffmpeg` | `brew install ffmpeg` | both `*-grade.sh` | Needs `hevc_videotoolbox` and `lut3d` (default on macOS builds) |
| Bash 3.2+ | system | all | `set -euo pipefail`, no GNU-isms |
| BSD `stat` | macOS default | all | `stat -f` size check for idempotency |
| DaVinci Resolve (free) | [blackmagicdesign.com](https://www.blackmagicdesign.com/products/davinciresolve) | both `*-grade.sh` | Provides the user LUT folder the scripts read from |

LUT folders (`.cube` files go here):

- Lumix: `~/Library/Containers/com.blackmagic-design.DaVinciResolveLite/Data/Library/Application Support/LUT/myS1ii vlog luts/`
- Osmo Action: `~/Library/Containers/com.blackmagic-design.DaVinciResolveLite/Data/Library/Application Support/LUT/myDJI dlogm luts/`

## Conventions

If you fork or extend these:

- One script per task, self-contained, no shared lib.
- `set -euo pipefail` at the top.
- Default source path is the camera card mount; fail fast with a clear message if not mounted.
- Never delete from the SD card without an explicit flag.
- Re-encoded video defaults to HEVC VideoToolbox, `-q:v 65`, `-tag:v hvc1`, `-movflags +faststart`, audio `copy`.

## Acknowledgments

- **Alister Chapman** — free D-Log M creative LUT pack (9 looks, including the neutral `s709` D-Log M → Rec.709 conversion) used by `osmo-grade.sh`. See [xdcam-user.com](https://www.xdcam-user.com/).
- **DJI** — official D-Log M LUTs (also drop-in compatible with `osmo-grade.sh`).
- **Panasonic** — V-Log LUTs for the S1 II line.

These LUT packs are not redistributed here. Download them from their respective sources and drop the `.cube` files into the folders listed under [Dependencies](#dependencies).

## License

MIT (pending confirmation). The scripts are small, opinionated, and intended to be copied and modified — treat them as a starting point rather than a library.
