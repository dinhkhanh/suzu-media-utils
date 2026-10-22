<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt=""></p>

# SuZu Media Utils

A native macOS app (Apple Silicon, macOS 15+) with tools for SuZu Media's photo and video work. Everything runs
locally; nothing leaves the Mac unless you opt into celebrity naming.

## Tools

### Face Grouping
Point it at any folders — NAS share, external drive or local disk — and it finds every face in the photos and videos,
groups them by person, keeps up as new files arrive, and files each person's media into a folder named after them.

- Photos (JPEG, HEIC, PNG, TIFF) and videos (MP4/MOV natively; AV1, WebM, MKV, AVI… via ffmpeg). Videos are sampled
  at 1 frame per second; a person counts once per video.
- Groups form automatically; known people are recognised as soon as a file finishes copying.
- Name people right in the grid, merge groups, fix mistakes ("Not this person", "Move to…"); pick any face as a
  person's picture, or let the best shot be chosen automatically (sharp, eyes open, facing the camera).
- **Best shots:** every face is scored (Vision capture quality, sharpness, eyes open, head angle, smile, size).
  Person pages sort Best First, show Best 10/20/50, hide near-identical burst shots and filter by shooting session.
- **Search & smart albums:** people (all together / any), solo or group shots, photos/videos, dates, folder, best
  shots only; save as a smart album that keeps updating.
- **Export:** Copy/Move to Folder per person or Export All (`<folder>/<Person Name>/`, never overwriting). Optional
  edits (auto tone, face-aware social crop 1:1 · 4:5 · 9:16 · 16:9 · 1.91:1, logo watermark, resize — auto tone
  turns on with crops and watermarks), Top N, best of each burst, and people's names written into the files
  (IPTC/XMP, read by Lightroom, Photo Mechanic, Bridge and Photos).
- **Delivery rules:** new photos of a person (or anyone named) are copied — optionally edited — into a folder (put
  it inside Google Drive or Dropbox to share automatically) with a notification on the Mac. Runs only while no new
  file is waiting, so it never slows recognition.
- **Video moments:** per person, a clip of each appearance (cut without re-encoding), a highlight reel of the best
  moments, or the best still frames.
- **Web gallery:** export a self-contained gallery folder, or share a live gallery on the local network (secret link,
  Bonjour) to browse, play, download and rename people from a MacBook, iPad or phone.
- **Auto-naming:** a Known-People folder (`<folder>/<Name>/<photos>`) names matching groups offline; optional Amazon
  Rekognition celebrity lookup ("Suggest Names…").
- Files are tracked by content, so moving/renaming in Finder or copying never loses names or duplicates work.

### Batch Export
Auto tone, face-aware social crops, logo watermark and resize for any photos, no library needed.

### Batch Rename
Patterns like `{event}_{date}_{person}_{seq:3}` with a live preview; people come from Face Grouping, and renamed
library files keep their faces and names.

### Copy Verifier
Checks that a copy (memory card → NAS, NAS → backup) is complete — missing, truncated or (with checksums) damaged
files — and repairs it.

### Video Tools
720p proxies and contact sheets for many videos at once.

Extras never slow the core: scoring reuses data the recognizer already has (A/B: same speed), burst fingerprints and
upgrades of older libraries run only when no new file is waiting, and tools run at lower priority.
Speed on an M2 dev Mac: ~40–70 photos/s from local disk, NAS-bound (~110 MB/s) over 1 GbE; 4K video at ~100× real time.
Details and measurements: [PLAN.md](PLAN.md).

## Setup

Requirements: Xcode (Swift 6), macOS 15+, Homebrew.

```sh
brew install ffmpeg           # optional, for AV1/WebM/MKV/AVI video
```

### Models
The face-recognition model is not in the repository (it's large, and InsightFace's weights are licensed for
non-commercial use only and may not be redistributed). Build it once:

```sh
mkdir -p ~/fg-models && cd ~/fg-models
curl -LO https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip && unzip buffalo_l.zip -d buffalo_l
curl -L -o sface.onnx https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
brew install uv && uv venv --python 3.12 venv
VIRTUAL_ENV=venv uv pip install torch onnx onnx2torch coremltools onnxruntime numpy
cd -  # back to the repo
~/fg-models/venv/bin/python tools/convert_models.py ~/fg-models models
for m in ArcFaceR50 SFace; do xcrun coremlcompiler compile models/$m.mlpackage models/compiled; done
```

### Build and run

```sh
scripts/build-app.sh          # -> dist/SuZu Media Utils.app (model and icon bundled)
open "dist/SuZu Media Utils.app"
swift test                    # library tests (no model needed)
```

To use it on another Mac, copy `dist/SuZu Media Utils.app` over (and `brew install ffmpeg` there for web video formats).

### Celebrity naming (optional)
1. AWS console → IAM → Users → Create user (e.g. `suzu-media-utils`), inline policy allowing only
   `rekognition:RecognizeCelebrities`.
2. Security credentials → Create access key.
3. App → Settings → Face Grouping: paste the keys, region Singapore, Test Connection.

About $1 per 1,000 faces; up to 3 face crops per unnamed group are sent, each face only once.

## Command line

```sh
.build/release/SuZuMediaUtils --headless <folder> [--reference <known-people folder>] [--library <dir>] \
    [--extras] [--suggest-names [--apply]] [--gallery <dir>] [--reel <dir>] [--serve <seconds>]
    # full pipeline without UI, prints the people found; the flags exercise the extras
.build/release/facescan scan <folder> --out runs/x && .build/release/facescan cluster runs/x --sweep   # research CLI
```

## Project layout

| Path | What |
|---|---|
| `Sources/FaceCore` | Detection (Vision), alignment, Core ML embeddings, clustering, video sampling, ffmpeg fallback |
| `Sources/MediaKit` | Edit pipeline (auto tone, crops, watermark), metadata, video clips/reels/proxies/contact sheets, rename, verifier |
| `Sources/FaceLibrary` | SQLite library (GRDB), folder monitor, processor, grouping, best shots, bursts, search, delivery, export, gallery, Rekognition |
| `Sources/SuZuMediaUtils/App` | App shell: window, sidebar, settings, headless mode |
| `Sources/SuZuMediaUtils/FaceGrouping` | Face Grouping UI |
| `Sources/SuZuMediaUtils/Tools` | Batch Export, Batch Rename, Copy Verifier, Video Tools |
| `Sources/facescan` | Research CLI used to benchmark and tune thresholds |
| `Tests/FaceLibraryTests`, `Tests/MediaKitTests` | Tests (28) |
| `tools/` | Model conversion, icon, evaluation scripts |

### Adding a tool
1. Put the tool's logic in its own library target (like `FaceLibrary`) with tests.
2. Add a case to `AppRoute` in `Sources/SuZuMediaUtils/App/AppShell.swift`.
3. Add a sidebar section view whose rows are tagged with that case, list it in `AppShell`'s sidebar, and add a branch in
   its `detail` switch.
4. Settings go in a new tab in `SuZuMediaUtilsApp`.

## Data
Library: `~/Library/Application Support/SuZu Media Utils/Face Grouping` (SQLite database and face thumbnails).
AWS keys: login Keychain. Source photos and videos are only read, except when you choose Move.
