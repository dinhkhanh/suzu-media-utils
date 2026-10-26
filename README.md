<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt=""></p>

# SuZu Media Utils

A native macOS app (Apple Silicon, macOS 15+) with tools for SuZu Media's photo and video work. Everything runs
locally; nothing leaves the Mac unless you opt into celebrity naming.

## Tools

Full feature list (Vietnamese): [docs/FEATURES.md](docs/FEATURES.md).

### Face Grouping
Point it at any folders — NAS share, external drive or local disk — and it finds every face in the photos and videos,
groups them by person, keeps up as new files arrive, and files each person's media into a folder named after them.

- **Overview (the start screen):** the event at a glance — files, people, faces to review and deliveries as four
  counts; the night's workflow as five steps (Ingest → Recognise → Name → Cull → Deliver, each a link to the screen
  that does it); the sessions as a timeline (click one to see its files); what needs you (unnamed people, a card
  that was handed over, an offline folder, a rule waiting for its folder); and what happened on this Mac (names,
  merges, deliveries, folders). The sidebar follows the same order: Overview and Files, then People (People,
  To Name, Pinned, Unassigned Faces, Search, Auto Rules, Lists, Smart Albums), then Tools; folders fold away under Folders. The
  status pill at the bottom shows what the library is doing with a rate and time left, plus the team's sync; click it
  for tonight's activity.
- **Appearance:** Settings → General: System (follows macOS, Auto included), Light or Dark, also under View →
  Appearance; the accent (SuZu coral or the Mac's), and which screen the app opens on.
- **Projects:** one project per event, each with its own folders. Switch at the top of the sidebar (or File → Open
  Project); people, search, albums, auto rules, exports, the gallery and the batch tools follow the open project.
  People are shared: name someone once and they are recognised in every later project (typing a name suggests
  people named before, and picking a suggestion saves it; "This Is…" merges a group into them). A named person
  stays recognised after their folder is removed or their files are deleted or changed on disk.
- Photos (JPEG, HEIC, PNG, TIFF) and videos (MP4/MOV natively; AV1, WebM, MKV, AVI… via ffmpeg). Videos are sampled
  at 1 frame per second; a person counts once per video.
- Groups form automatically; known people are recognised as soon as a file finishes copying. A person is
  remembered by several exemplar faces (frontal, profile, hat, glasses, another make-up), not just an average, so a
  shot only has to resemble their earlier shots taken that way. Groups that formed at different moments but are one
  person merge by themselves; two people you named differently, or told apart, never do.
- Name people right in the grid, built for a run: click a tile, type, ⏎ — the cursor moves to the next unnamed
  person; ⇥ skips one; names from every project are suggested as you type; "Start Naming" on the banner begins
  with the first unnamed. Select several (⌘-click, ⇧-click) for a floating bar: Merge into One, This Is…, Open.
  Fix mistakes ("Not this person", "Move to…"); pick any face as a person's picture, or let the best shot be
  chosen automatically (sharp, eyes open, facing the camera).
- **Find by Photo** (People toolbar): drop a photo, paste one (⌘V) or choose one, and every face in it lists the
  people it looks most like, the best match marked Likely when it clears the bar the library names faces by; click
  one to open them. The photo is only looked at, never added.
- A person's page: their picture, name (click to rename), counts and when they were shot, who they are **often
  with** (click a face chip to see only the photos together), then Photos / Videos / Faces with Best first, Best
  N and Hide bursts as chips; each photo carries its best-shot score, burst count, time and session. Select photos
  for Open in Edit & Export; the toolbar opens the best shots shown.
- **Sessions:** each project splits itself into sessions wherever nobody shot for 30 minutes (adjustable): the
  opening, each match, the awards. The session bar sits above People, person pages, Unassigned Faces, Files, Search
  and Edit & Export (even with a single session): click a session to see, or export, only that stretch of the event;
  Copy/Move follows it too. Right-click a session to name it.
- **Selecting:** in every grid, ⌘-click adds one item and ⇧-click selects a range. Right-click: Show in Finder, Copy
  File Path.
- **Thumbnails** are made once (while a file is processed, or in idle time) and kept with the library, so folders on
  the NAS open as fast as in the Finder; the Macs that don't process faces get them from the team folder too.
- **Best shots:** every face is scored (Vision capture quality, sharpness, eyes open, head angle, smile, size).
  Person pages sort Best First, show Best 10/20/50 and hide near-identical burst shots.
- **Search & smart albums:** people (all together / any), solo or group shots, photos/videos, dates, folder, best
  shots only; save as a smart album that keeps updating.
- **Export:** Copy/Move to Folder per person or Export All (`<folder>/<Person Name>/`, never overwriting). Optional
  edits (auto tone, face-aware social crop 1:1 · 4:5 · 9:16 · 16:9 · 1.91:1 — one for every photo, or one for portraits
and one for landscapes — logo, text or banner watermark, resize — auto tone
  turns on with crops and watermarks), Top N, best of each burst, skip blurry shots, and people's names written
  into the files (IPTC/XMP, read by Lightroom, Photo Mechanic, Bridge and Photos).
- **Auto rules:** when new files match a smart-album-style query — photos of one person, everyone with a name, best
  solo shots of anyone, group shots, skipping similar and blurry shots… — they are copied into a folder (on the NAS, or inside Google Drive or Dropbox
  to share automatically), either a folder per person or straight into one folder, optionally levelled, auto-toned,
  cropped, watermarked and resized, with names in the metadata and a notification on the Mac. Edit a rule any time.
  Runs only while no new file is waiting, so it never slows recognition.
- **Teams (several Macs, many events):** a team is a folder every Mac can reach (the NAS share, Dropbox, iCloud
  Drive) and holds every project you share with it. File → Share Project with Team… creates the team or adds the
  project to one you are in; teammates pick the same folder once with File → Join a Team…, and the team's projects
  appear on their Mac by themselves. From then on a person named on any Mac is recognised on every Mac (projects,
  names, merges, pins, people's pictures, session names and auto rules are shared; photos, faces and crops stay
  where they are), within seconds, with no account or server. Each Mac appends to its own log in the folder and
  reads the others', so a Mac that was offline catches up, the newest change wins, and the same name given on two
  Macs becomes one person. Everyone named on a Mac travels (a Known-People folder prepared before the event, people
  from earlier events). The sidebar shows the team above the project, with its Macs and the last sync; the project
  menu groups projects by team. Rename Team, Locate Team Sync Folder… (when the NAS address changes), Stop Sharing a
  project, Leave Team (keeps projects and names).
- **Three kinds of folders in a team:** *Team Folders* are the sources every Mac works on (the card folders on the
  NAS): added on one Mac, they appear on every Mac of the team. *Edited Folders* are where the Mac in charge of
  editing / selecting puts its results, and travel the same way. *Folders on This Mac* stay on that Mac, as before.
  The sidebar and Files show the three groups; right-click a folder → In the Team to change its kind. A shared
  folder is found on each Mac at the same distance from the team folder, so the share may be mounted under another
  name; one taken out of the team leaves the Macs that only had it through the team and stays on those that added
  it themselves.
- **One Mac processes for the team:** in the team menu, "This Mac processes faces for the team" makes the strong
  Mac do the recognition while the Macs copying cards or editing only read its results from the team folder, for the
  files they have: faces, people, groups and crops, with no CPU or GPU spent. Edits made anywhere travel back and
  everyone converges; the status pill says "Waiting for <Mac>" meanwhile. **Hybrid:** a Mac copying cards still
  processes the files it copies, from the card as each one lands, and sends the faces ungrouped; the processing Mac
  takes them for the files it has waiting instead of reading them back from the share, groups them, and sends the
  file again with the people, which every Mac (the copier included) takes as the truth for the very faces it found.
  The processing Mac remembers what it sent for each file and keeps checking it against its library, sending again
  any file that drifted however it happened, so the other Macs never keep stale faces or crops.
  While copiers are sending, the processing Mac gives a fresh file 30 s for their record to arrive before reading it
  itself; otherwise it reads at once as before.
- **Video moments:** per person, a clip of each appearance (cut without re-encoding), a highlight reel of the best
  moments, or the best still frames.
- **Web gallery:** export a self-contained gallery folder, or share a live gallery on the local network (secret link,
  Bonjour) to browse, play, download and rename people from a MacBook, iPad or phone.
- **Auto-naming:** a Known-People folder (`<folder>/<Name>/<photos>`) names matching groups offline; optional Amazon
  Rekognition celebrity lookup ("Suggest Names…").
- Files are tracked by content, so moving/renaming in Finder or copying never loses names or duplicates work. A whole
  event folder renamed or moved in Finder shows as Offline: right-click → **Locate Folder…** (or add it again) and it
  is relinked with every face and name.
- One name, one person: names match in any case or Unicode form (a name typed in the app and the same name from a
  Finder folder), and "New Person…" with a name in use adds to that person.

### Edit & Export
A quick photo editor and batch exporter in one, for any photos or people's photos. The preview behaves like any editor:
⌘+ and ⌘− zoom, ⌘0 fits, ⌘1 is 100% (one photo pixel per screen pixel), ⌥-scroll or pinch zooms about the cursor,
scrolling or Space-drag pans, double-click toggles 100% and fit. The preview is rendered at the screen's resolution
however far it is zoomed, so the watermark stays sharp. C opens the crop tool: handles to resize (in the export's
shape, the photo's own, a preset, or free), drag inside to move, drag outside to turn the photo, Straighten to draw a
line along anything that should be level; Return applies, Esc cancels, the arrow keys nudge. Level turns a photo by a
slider with the result shown live. The crop is remembered per photo for every screen, with Reset crop to go back to
the automatic one that keeps the people in frame.

Auto tone & enhance measures each photo and sets its tone curve, shadows, highlights, vibrance and exposure on the
dials themselves, so you see what it did and go on from there (your changes sit on top, and apply to every photo's
own auto values); Reset All Dials, or double-click a slider or its name, puts things back.
Light (exposure, contrast, highlights, shadows), Colour (temperature, tint, vibrance, saturation, black & white),
Detail (sharpen, clarity, vignette) and Orientation (turn, flip) sit beside Auto tone, with a five-point tone curve
and an HSL panel (hue, saturation and luminance for eight colours) folded under them. Looks are a starting point:
seven built in, plus your own saved from the sliders (Save Current Look…), and Copy Look / Paste Look between photos;
double-click a slider's name to zero it. With several photos the sliders set every photo, or "This photo only". ⌘Z
undoes any of it, a slider drag at a time.
Tick or untick photos in the strip or in a grid of all of them (⇧-click for a range, Select All / None; arrow keys
step through them, Space ticks the shown one, Return opens a grid photo large) to export only some; save as JPEG or
as lossless PNG (the photo's own colour space, 16-bit when the original is). It remembers what it exported (a green
tick on the thumbnail, the date in the preview): exporting a photo into a folder that already has it asks, photo by
photo or for all, whether to skip it or overwrite it. Originals are never overwritten, and another camera's photo of
the same name gets " (2)".

Camera RAW files (Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Pentax, Leica, Hasselblad, Phase One, Sigma, DNG…)
are photos like any other: recognised, searched, exported and edited (an edited RAW comes out as a JPEG). The camera's
embedded preview is used wherever it is big enough, so RAW files are not slower to process. A RAW file next to its
JPEG (RAW+JPEG shooting, same name) is the JPEG's companion: it shows the JPEG's people and is never processed or
exported on its own, so a person's folder gets one file per shot. Edit & Export is the exception: there a pair comes in
as its RAW (from files and folders, from people, or opened from the library), which holds the most to edit.

Skip similar shots and Skip blurry shots (under the photos) check the photos before the export and untick the ones to
leave out, with the reason on hover, so any can be ticked back. Similar shots are taken within a couple of seconds of
each other and look the same (the library's burst rule); the best one stays. A photo is blurry when its main face is
soft (out of focus or moved) or, without a usable face, when the whole frame is smeared. Photos the library has
processed are judged from what it already measured; others are read on the spot, about a tenth of a second each.

Straighten tilted photos (Look) levels photos turned 0.3°–10° off by their vertical lines — pillars, door frames, screen
and banner edges — and trims the corners; it only turns a photo when many lines agree (on event photos turned ±3°, it
was never more than 0.2° off), and leaves the rest alone. Level in the preview turns any photo by hand.

Right-click → Open on any photo in the library (a person's photos or faces, unassigned faces, search, smart albums)
opens it in an Edit & Export window with just that photo — or every ⌘-click-selected one — and the
faces the library already knows, so crops keep everyone in frame.

### Watermarks
Save any number of watermark presets — logos, text credits or full-width banners — in Settings → Watermarks. A banner
is a bar stretched across the whole width of the photo (top, middle or bottom), with one image for landscape photos
and another for portrait ones. You set its height (by default 112 px for every 2048 px of the long side), so it is the same
height on every photo shape; it is centred and its sides are trimmed to the photo's width (one too narrow for the photo is
stretched sideways, never made taller). Make
banners a little wider than any photo and keep text and logos in a safe zone in the middle. Every editing screen (Batch
Export, Copy/Move, delivery rules, web gallery, video stills) picks its own preset and position, edits it in place,
and remembers its choices; edits can be saved back to the preset or as a new one.

### Batch Rename
Patterns like `{event}_{date}_{person}_{seq:3}` with a live preview; people come from Face Grouping, and renamed
library files keep their faces and names.

### Copy from Cards
Each mounted card is a panel: its name, camera and room; what is new as a sentence ("312 new photos · 14 new
videos · 9.8 GB · 1,208 copied before"), a status pill (New since 14:05 · Copying · Up to date), where its files
will land, and one button. The destination and the options sit in a column on the right; Copy New Files from All
starts every card that has something new, side by side.

Photographers hand their cards over again and again during an event without erasing them. The tool knows each card
by its volume UUID (the serial the camera wrote when it formatted the card; no renaming needed) and keeps a ledger
of every file copied from it, so the next hand-over copies only what was shot since, however the earlier copies were
moved, filtered or edited in the meantime. Files renamed on the card, or already in the library from a copy made by
hand, are matched by contents and not copied twice. Each card gets its own folder at the destination (name the card
"Nam R5 card 1"; the camera and body serial come from EXIF), with a folder per hand-over if you like; copies are
streamed through SHA-256 and read back, keep the original's times, and the card's folder can be added to the open
project so faces are found as the files land. A card seen before can be forgotten (right-click) to copy it all again.

Everything runs at once at an event, and the app is arranged for it: the card's folder joins the project before the
first file lands, and each file is taken up **the moment it lands**, ahead of everything else waiting, with its
faces read **from the card** (local, USB) while it is still in the slot, rather than back from the share minutes
later when the folder scan gets to it and the card has long been swapped for the next one. The network carries each
photo once, the faces are known about when the copy finishes, and a card pulled early just means the rest is read
from the share. The folder scan finds those files already registered and leaves them alone; a RAW that came with
its JPEG is left to the scan, which pairs the two as usual. While a copy, export or batch tool the user is waiting for runs, face work goes on with half
the workers so the transfer gets the disk and network first, and resumes at full speed after. Copy and Move to
person folders run several files at a time (several streams fill a share's link where one doesn't; an edited export
renders one photo while the next is read), with colliding names kept apart. The library commits without waiting for
the disk (WAL, synchronous=NORMAL, consistent through an app crash) and allows more concurrent readers, so a card
copy, the processor, an export and the team sync never queue behind each other's commits. The team sync applies a
teammate's changes and face records in short transactions (a backlog of thousands, as on joining, used to hold the
writer for seconds), so card A's files can still be scanned and processed while card B is copying, and neither
waits on the other. Progress reaches the screen a few times a second, not per 8 MB piece, and Files re-lists only
when a folder comes or goes, not on every tick of a scan.
In a team the ledger travels with the shared folder: a card copied on one Mac is known on every teammate's Mac, so
the next hand-over can go to whichever Mac is free, through any reader or adapter (the card's own UUID is what
counts). A card pulled in the middle of a copy stops it at once: what landed is kept and recorded, nothing half
written is left behind, and when the card is back the copy goes on in the same folder. New photos and new videos
are counted apart, and videos can go to their own destination (an editor's drive), each with its own card folder.
Several cards at once: each card can be sent to a folder of its own (one to the Mac, one to a portable SSD, one to
the NAS; the card remembers it for its next hand-over), and the cards copy side by side, each disk at its own speed.

### Copy Verifier
Checks that a copy (memory card → NAS, NAS → backup) is complete — missing, truncated or damaged files (contents are
compared with SHA-256 checksums unless you turn that off) — and repairs it. A repair copies to a temporary file and
checks it before it replaces the broken copy.

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

Edit & Export's retouch finds people's face skin, body skin, lips, clothes and hair with Meta's Sapiens body-part
segmentation (0.3B, CC BY-NC 4.0: personal use). Without it the app falls back to Apple Vision (rougher: hair can
count as clothes, skin-coloured clothes as skin). Build it once (1.4 GB download, 645 MB model):

```sh
curl -L -o ~/fg-models/sapiens_seg_0.3b.pt2 https://huggingface.co/facebook/sapiens-seg-0.3b-torchscript/resolve/main/sapiens_0.3b_goliath_best_goliath_mIoU_7673_epoch_194_torchscript.pt2
~/fg-models/venv/bin/python tools/convert_sapiens.py ~/fg-models/sapiens_seg_0.3b.pt2 ~/fg-models/sapiens
xcrun coremlcompiler compile ~/fg-models/sapiens/BodyParts.mlpackage models/compiled
```

It isn't put inside the app (600 MB in every update): `N=1 scripts/publish-model.sh` puts it on GitHub as a release
of its own, and the app downloads it once into `~/Library/Application Support/SuZu Media Utils/Models` (the
Download button in the Retouch section, or `"SuZu Media Utils.app/Contents/MacOS/SuZu Media Utils" --download-body-parts`
for setting up several Macs). A development build also finds it in `models/compiled`.

### Build and run

```sh
scripts/build-app.sh          # -> dist/SuZu Media Utils.app (face model, icon and Sparkle bundled)
open "dist/SuZu Media Utils.app"
swift test                    # library tests (no model needed)
```

To use it on another Mac, install the `.dmg` from the [latest release](https://github.com/dinhkhanh/suzu-media-utils/releases/latest)
(drag to Applications; `brew install ffmpeg` there for web video formats). Installed apps check for updates once a
day (Settings → Updates, or SuZu Media Utils → Check for Updates…) and install them with one click.

### Releasing

```sh
VERSION=0.7.0 scripts/release.sh                 # signed, notarized zip + dmg + appcast.xml in dist/
VERSION=0.7.0 NOTES=notes.md scripts/publish.sh  # tag, push, GitHub release with the three files
```

Installed apps read `releases/latest/download/appcast.xml`, so publishing the release is the update. Updates are
signed with the Sparkle key in the login keychain (`generate_keys`; back it up with `generate_keys -x`); its public
half is in `scripts/build-app.sh`. Notarization needs the `suzu-notary` keychain profile (see `scripts/release.sh`).

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
| `Sources/SuZuMediaUtils/App` | App shell: window, sidebar, Overview, appearance settings, headless mode |
| `Sources/SuZuMediaUtils/FaceGrouping` | Face Grouping UI |
| `Sources/SuZuMediaUtils/Tools` | Copy from Cards, Edit & Export, Batch Rename, Copy Verifier, Video Tools |
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
