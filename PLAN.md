# Face Grouping for Photo Folders — Plan

Target: Mac Studio M1 Max, 64 GB. All processing local.

The app works on **any folder you pick**: a NAS share mounted under /Volumes, an external drive, a local directory, iCloud Drive, anything the filesystem exposes. Storage type only changes how the app watches and reads; it never changes the pipeline, the database, or the UI. One library can contain several source folders of mixed types.

## Recommendation: native Swift/SwiftUI app, Vision for detection, ArcFace (ONNX Runtime, CoreML EP) for embeddings, SQLite for state

Why this and not a Python + web UI:
- Vision.framework face detection/landmarks/quality run on the Neural Engine with zero setup and zero model shipping.
- ONNX Runtime has an official Swift package with a CoreML execution provider, so the InsightFace ArcFace model (`w600k_r50.onnx`, 512-d) runs without converting to .mlmodel.
- ImageIO can decode a downscaled thumbnail straight from JPEG/HEIC/RAW, which is the single biggest speed win when files are large and come over the network.
- One binary, no Python env, no Electron, proper macOS file access (security-scoped bookmarks for NAS folders).

Python (insightface + onnxruntime) is faster for a 1-day prototype but slower to turn into a usable app. Use it only in Phase 0 if you want to sanity-check thresholds first.

## Pipeline

1. Scan: walk selected NAS folders (FileManager enumerator). Key each file by path + size + mtime. Skip unchanged. Bounded concurrency (6–8 readers) because SMB, not CPU, is the bottleneck.
2. Decode: `CGImageSourceCreateThumbnailAtIndex` with max pixel ~1600. Never decode full-res RAW.
3. Detect: `VNDetectFaceRectanglesRequest` + `VNDetectFaceLandmarksRequest` + `VNDetectFaceCaptureQualityRequest`. Drop faces < 40 px or quality < threshold.
4. Align: derive 5 points (eyes, nose, mouth corners) from Vision landmarks, similarity-transform to 112×112 ArcFace template.
5. Embed: ArcFace via ONNX Runtime (CoreML EP). Batch 16–32 faces. L2-normalize.
6. Store: SQLite (GRDB.swift). Tables: `photo`, `face` (bbox, landmarks, quality, embedding BLOB 2048 bytes, person_id nullable), `person` (name, cover_face_id, hidden). Face crops cached as small JPEGs in Application Support.
7. Cluster: cosine similarity on normalized vectors (Accelerate vDSP/BLAS). Initial pass: agglomerative/HDBSCAN with threshold ~0.55–0.65 (tune on your data). Incremental: new face joins an existing person if max similarity to that person's centroid/top-k > T, else goes to "unassigned"; recluster unassigned on demand.
8. UI: People grid (cover face, count), Person detail (faces, photos, merge/split/rename/hide), Photo browser filtered by person(s) with AND/OR/NOT, "Unnamed" and "Low quality" buckets, suggestions ("Is this also X?").
9. Export: XMP sidecar keywords / IPTC PersonInImage, copy or symlink to folders, CSV. Optionally push albums to Apple Photos via PhotoKit later.

## Expected throughput (M1 Max)

| Stage | Cost |
|---|---|
| Vision detection @1600px | ~20–40 ms/photo |
| ArcFace embed | ~3–8 ms/face |
| NAS read, 5 MB JPEG @1GbE | ~45 ms (dominates) |
| NAS read, 30 MB RAW @1GbE | ~270 ms (dominates) |

Rough: 100k JPEGs ≈ 1.5–3 h on 1 GbE; RAW-heavy ≈ 5–8 h. 10 GbE roughly halves it. 100k faces × 512 floats = 200 MB in RAM, fine on 64 GB.

## Phases

0. Spike (1 day): Swift CLI `facescan <folder>` that decodes, detects, embeds, prints faces/sec and dumps embeddings. Run it on the Solina folder (NAS) and on a local copy of the same folder to confirm the pipeline is storage-agnostic and pick the similarity threshold.
1. Core (2–3 days): SQLite schema, incremental scanner, pipeline actors, progress UI.
2. Grouping (2 days): clustering, People grid, person detail, cover face picked by quality.
3. Labeling + filtering (2–3 days): rename, merge, split, hide, move face, photo browser with person filters, keyboard-driven review.
4. Polish (2 days): add/remove source folders, handle unmount/remount and moved files (rekey by content hash of the first 1 MB), pause/resume, export, settings for thresholds.

## Key decisions already made

- Detection: Vision (not SCRFD) — free, fast, ANE.
- Embedding: InsightFace ArcFace w600k_r50 ONNX via onnxruntime-swift. Fallback: convert to CoreML with coremltools via onnx2torch if the CoreML EP underperforms.
- DB: SQLite via GRDB, not Core Data/SwiftData (bulk inserts, BLOBs, raw SQL for similarity pre-filtering).
- Sources are folders. The app stores a security-scoped bookmark per source so it keeps access across launches; the folder's volume type is detected, not configured.
- App is not sandboxed in v1; the bookmark still works and makes a later sandboxed build easy.
- macOS 15+ deployment target.

## Open questions

- Approximate library size (photos, % RAW) to size the first full scan. Local SSD removes the read bottleneck entirely: the Solina folder would take ~3 s instead of ~16 s.
- Need video frames? (Out of scope for v1.)
- Write metadata back to originals on the NAS, or sidecars only? (Default: sidecars.)

## Measured 2026-10-22 (dev Mac, M2 8-core, 1 GbE to NAS_SKY, share //NAS_SKY/homes, SMB 3.1.1, no encryption)

- Cold parallel read (8 readers): 88 MB/s ≈ 12 s per GB. This is the bottleneck.
- Sample photos on the share are 7008×4672 (33 MP), ~12 MB each, not 4K.
- Decode thumbnail 1500 px + Vision detect/landmarks: ~60–65 img/s with 8 workers (compute only, warm cache). M1 Max 10-core should do 70–80 img/s.
- Using max pixel 1500 instead of 1600 is ~15% faster (ImageIO uses 1/4-scale JPEG decode for 6000 px wide images).
- Directory enumeration over SMB: ~0.37 s per 800 files, so poll only recently modified folders, do full rescans rarely.
- FSEvents does not fire on SMB mounts: new-file detection must poll.

## Incremental ingest design (per source folder, strategy chosen by volume type)

Detect volume type with `URLResourceValues.volumeIsLocal` / `volumeIsRemovable` and the mount's filesystem (smbfs, afpfs, nfs, apfs, exfat).

| Volume | New-file detection | Read concurrency | Settle wait |
|---|---|---|---|
| Local APFS / external SSD | FSEvents, near instant | 8–12 | 1 s |
| External HDD | FSEvents | 2–4 (avoid seek thrash) | 1 s |
| SMB / AFP / NFS mount | Poll every 5 s, only folders whose mtime changed | 6–8 | 2 polls with stable size |
| Volume unmounted | Pause source, keep its data, resume on remount | — | — |

- Poll the watched root every 5 s for folders with changed mtime; enumerate only those.
- A file is "settled" when size is unchanged for 2 consecutive polls and it is not a temp/partial name (.partial, ._*, ~$*, .tmp).
- Settled file → read → decode → detect → embed → assign. Latency per photo ≈ poll (≤5 s) + settle (2–5 s) + ~0.2 s processing.
- Face matched to a known person appears under that person immediately. A new person needs ≥3 similar faces before it surfaces as "New person"; recluster "unassigned" after each batch goes quiet for 30 s.

## Measured on "00 SUZU MEDIA/25 - Pickleball/2. Solina/SOLINA CUP/NGHỆ SĨ PHOTOS NO LOGO" (2026-10-22)

- 159 JPEGs, 1.42 GB, avg 8.9 MB (1.3–23 MB), mixed crops from 1999×2999 to 7008×4672. Plus Thumbs.db and .DS_Store to ignore.
- Cold read, 8 readers: 15.6 s (91 MB/s).
- Detect at 1500 px thumb, 8 workers, warm cache: 2.1 s for all 159 (75 img/s on the M2).
- 273 faces (1.7/photo), every photo has at least one face. 272 are ≥40 px wide at thumb scale; 120 are 40–80 px, 124 are 80–160 px, 28 ≥160 px.
- Capture quality ≥0.4 on only 155/251 faces (sports action: blur, profile, caps). Expect fragmented clusters; plan for merge UI and quality-weighted centroids.
- Design consequence: detect on the 1500 px thumb, but cut embedding crops from a 3000 px decode (or full res for faces <80 px) so ArcFace gets ≥112 px input. Compute has 10× headroom over the NAS read, so the second decode is free.

## Measured on local SSD folder "~/Downloads/3. PHOTO" (2026-10-22, dev Mac M2)

- 542 JPEGs in 7 subfolders, 5.84 GB, avg 10.8 MB (1.3–27 MB). APFS on internal SSD.
- Read all files: 1.6 s (3.7 GB/s). Storage is no longer a factor.
- Full detect pass (read + 1500 px decode + Vision landmarks + quality, 8 workers): 9.4 s = 58 img/s. The same 5.84 GB over the NAS would take ~64 s just to read.
- 1,326 faces (2.4/photo), 10 photos with no face, 1,308 usable ≥40 px. 704 faces are 40–80 px at thumb scale (crowd/group shots), 444 are 80–160 px, 160 are ≥160 px.
- Capture quality ≥0.4 on 861/1,283 (67%).
- Confirms the pipeline is storage-agnostic: identical code, only the read stage changed.

## Phase 0 results (2026-10-22, dev Mac M2 16 GB)

Code: Swift package at the repo root. `FaceCore` library (loader, Vision detector, 5-point aligner, Core ML embedder,
average-linkage clustering) plus the `facescan` CLI. `tools/convert_models.py` builds the Core ML models,
`tools/evaluate.py` and `tools/simulate_incremental.py` score runs.

    swift build -c release
    .build/release/facescan scan <folder> --out runs/<name>          # detect, align, embed, cache
    .build/release/facescan cluster runs/<name> --sweep               # threshold table + HTML report + montages

Speed ("3. PHOTO", 542 photos, 5.84 GB, local SSD):
- Detect stage (read, 1500 px decode, Vision landmarks + quality, align), 8 workers: 7.4 s = 73 photos/s.
- ArcFace R50 on the Neural Engine: 490-510 faces/s (2.4 faces/photo -> ~200 photos/s, never the bottleneck).
  SFace: 1,100 faces/s.
- Same code over the NAS (Solina, 159 photos): 12.9 photos/s at 115 MB/s, read-bound. The NAS folder is a copy of a
  local subfolder; all 273 faces matched with embedding cosine >= 0.9993 between the two runs.

Core ML conversion pitfalls (both cost 8x speed, both now handled in convert_models.py):
- A RangeDim (flexible) batch input keeps the model off the Neural Engine. Use EnumeratedShapes [1, 16]; the
  embedder zero-pads short batches.
- `F.normalize` lowers to dynamic shape ops that push the whole graph to the CPU. L2-normalize with rsqrt instead.

Accuracy (ArcFace R50, no ground truth; reference clustering inspected by eye):
- 91 groups from 1,107 faces. Group montages are pure: same person across caps, sunglasses, profiles, smiling/serious.
- Same-person pairs: median similarity 0.73, 5th percentile 0.53. Different-person pairs: median 0.04,
  99.9th percentile 0.28. The closest two groups (0.34 centroid similarity) are different people.
- Group count is flat (91-95) for thresholds 0.30-0.55, so the threshold is not fragile.
- Blurry background faces form a junk cluster (all quality <= 0.20). Capture quality >= 0.3 removes it; 218 of 1,326
  faces fall below that and are kept but not clustered.
- Cutting small faces from a 3000 px decode changed nothing (ARI 0.999) and cost 40% of detect-stage speed: off.
- Incremental simulation (groups from first half of photos, classify second half): assign at mean similarity
  >= 0.50 names 98.3% of known-person faces instantly with 0 wrong assignments; 0 of 106 new-person faces were
  matched to an existing person.
- SFace (Apache-2.0) at 0.45: ARI 0.958 vs the ArcFace reference, separation margin +0.07 vs +0.25. Usable, visibly
  more merge/split mistakes.

Chosen defaults: detect at 1500 px, no hi-res crops, cluster faces with quality >= 0.3 and width >= 40 px,
average linkage at 0.45, groups need >= 3 faces, incremental assign at >= 0.50.

Open: ArcFace (InsightFace buffalo_l) weights are licensed for non-commercial research only. For commercial use
either license them from InsightFace or ship SFace (or another permissively licensed model) and accept lower accuracy.

## Scope update (2026-10-22, after Phase 0)

Decisions from the user:
- Personal, local, non-commercial use: keep ArcFace R50 (best accuracy). The licensing question is closed.
- Process videos as well as photos.
- UI to name people, plus a button that moves or copies a person's files into a subfolder named after them.

Video design (prototyped in facescan):
- Sample 1 frame per second with AVAssetImageGenerator (time tolerance ±0.5 s, so it grabs cheap frames), long side 1500 px,
  then the same detect -> align -> embed path as photos.
- Faces of one person inside one video are collapsed into a "track" (average linkage 0.45 within the video). The track,
  not each frame, is matched against people, so a 10-minute clip can't flood a group.
- A video belongs to every person with a track in it. Its thumbnail in the person view is the frame at the best face.
- Measured: 4 clips, 196 s of footage, sampled in 1.0 s (about 170 frames/s with 8 workers). The .mp4 and .mov copies
  of the same clip produced the same 6 people, with frames from both files in each group.
- AV1 cannot be decoded on M1/M2 (no decoder in AVFoundation); such files are flagged "unsupported codec". Camera
  footage (H.264/HEVC) is hardware decoded.

Move/copy to person folder:
- Person view has "Copy to Folder" and "Move to Folder". Default target is `<source folder>/<Person Name>/`; the user
  can pick another base folder. Photos and videos are both included.
- Name collisions: identical size -> skip; otherwise append " (2)", " (3)".
- Move updates the file's path in the library, so nothing is re-scanned or re-detected and the person keeps the file.
- Files that also contain other named people: the confirmation shows how many. Move puts the file in this person's
  folder; copy is the safe choice for group photos.
- Real event footage (Solina RECAP, Sony 4K HEVC, ~12 s clips): 20 clips copied locally, 206 s of footage processed in
  2.1 s, 21 people, groups as clean as photos. Over the NAS (15h folder, 93 clips, 13.3 GB, 20 min of footage):
  28 s, and only 818 MB crossed the network: 1 fps sampling reads only the frames it needs, about 6% of each file.
  The whole 147 GB RECAP folder should take about 5 minutes over the NAS.

## App v0.1 (2026-10-22)

Build: `scripts/build-app.sh` -> `dist/Face Grouping.app` (bundles the Core ML model, ad-hoc signed, not sandboxed).
Library: `~/Library/Application Support/FaceGrouping` (SQLite + face crops). `FACEGROUPING_LIBRARY` overrides it.
Headless run for testing: `.build/release/FaceGroupingApp --headless <folder> [--reference <folder>] [--library <dir>]`.

Targets: `FaceCore` (detect/align/embed/cluster, video sampling), `FaceLibrary` (GRDB store, SourceMonitor,
Processor, GroupingEngine, Exporter, LibraryService), `FaceGroupingApp` (SwiftUI), `facescan` (Phase 0 CLI),
`FaceLibraryTests` (8 tests: moves, copies, deletes, settling, share hiccups, export, grouping, reference copies).

What works:
- Add any folder (local, external, NAS). Local folders are watched live (FSEvents); network shares are polled every
  5 s, re-listing only folders whose mtime changed. Files still being copied wait until their size is stable.
- Files are identified by content (size + SHA-256 of the first 1 MB): a file moved or renamed in Finder keeps its
  faces and names; a copy is recorded as a duplicate and never processed or shown twice; deleting an original hands
  its faces to a surviving copy.
- People grid (named first), search, Named/Unnamed filter, ⌘-click to select and Merge. Person view: rename (typing
  an existing name merges), Photos & Videos grid (videos show the frame where the person is), Faces grid with
  "Not this person" and "Move to…", "Also with…" filter (files where several people appear together).
- Unassigned Faces view: clear faces not in any group; select and name them.
- Copy to Folder / Move to Folder: `<source>/<Name>/` or a chosen base folder; collisions get " (2)"; identical files
  are skipped; moved files stay in the library under their new path; copies are registered as duplicates.
- Known-people (reference) folders: `<folder>/<Person Name>/*.jpg`. Each photo's largest face teaches that name;
  any group that matches (mean similarity >= 0.50) is named automatically, now and for future imports.

Measured with the app pipeline (M2): 542 photos -> 92 people in 15 s; with a 2-person reference folder the two
largest groups were named automatically (59 and 46 photos). 20 4K clips -> 525 frame faces -> 69 tracks -> 20 people
in 6 s.

Celebrity naming options (user's photos are mostly celebrities):
- Built: reference folder (offline, free, works for any Vietnamese artist; one clear photo per person is enough).
- Optional, not built: Amazon Rekognition RecognizeCelebrities. Would send 1-3 face crops per unnamed group (not
  whole photos), so an event costs cents. Coverage of Vietnamese celebrities is unknown and likely partial;
  needs the user's AWS account. General vision LLMs (including Claude) do not identify people from faces.

## v0.2 (2026-10-22)
- Videos macOS can't decode (AV1 on M1/M2, WebM, MKV, AVI, WMV, FLV, MTS) go through Homebrew ffmpeg
  (`brew install ffmpeg`, includes the dav1d AV1 decoder). VLC doesn't help: its codecs are private to VLC.
  Tested: the AV1 clip now yields 37 faces; a VP9 WebM decodes.
- People grid: click a name to rename in place; Return jumps to the next unnamed person.
- Person page: separate Photos / Videos / Faces tabs; video thumbnails have a play button and the timestamp.
- Export All (People toolbar): copy or move every named person's files in one go. Same-name files are skipped by
  default (never overwritten); "keep both" is an option. In Move All, a group photo moves to the folder of the
  person shown largest and is copied into the other people's folders.
- Amazon Rekognition "Suggest Names…": SigV4-signed calls without the AWS SDK (verified against the AWS test
  vector, and live against the endpoint with a fake key). Up to 3 head-and-shoulders crops per unnamed group,
  majority vote, results cached per face (`celebrityLookup`) so nothing is paid twice. Keys in the Keychain;
  Settings has region (default Singapore), minimum confidence, Test Connection. Headless:
  `FaceGroupingApp --headless <folder> --suggest-names [--apply]` with AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.

## v0.3 (2026-10-22): SuZu Media Utils
The app is now "SuZu Media Utils" (bundle id dk.dinhkhanh.suzumediautils), a shell for several tools with Face
Grouping as the first. Executable target `SuZuMediaUtils` (was `FaceGroupingApp`); `--headless` unchanged. Library moved
to `~/Library/Application Support/SuZu Media Utils/Face Grouping` (the old `FaceGrouping` folder is copied on first
launch and kept). Env overrides: `SUZU_FACE_LIBRARY`, `SUZU_FACE_MODEL`. Icon drawn by `tools/make_icon.swift`.

## v0.4 (2026-10-22)
Rule from the user: no feature may slow face recognition and grouping. A/B on "3. PHOTO" (542 photos): 14–15 s before
and after every feature below; same 92 people.

- MediaKit: Core Image auto tone/enhance (strength blend), face-aware crops (largest rect of the ratio, main face at
  40% height, whole group when it fits; saliency when no faces), logo watermark (size relative to the short side,
  9 positions, opacity), Lanczos resize, JPEG with EXIF kept and IPTC/XMP PersonInImage + keywords, lossless in-place
  name tagging, video clips (passthrough), HEVC highlight reels, 720p proxies, contact sheets, rename patterns,
  folder verifier.
- Best shots: per face eyes-open (eye contour aspect), smile (mouth width / eye distance), sharpness (Laplacian
  variance on the aligned crop), yaw/pitch; score = 0.45 quality + 0.20 sharp + 0.12 eyes + 0.13 frontal + 0.05 smile
  + 0.05 size, ×0.6 with closed eyes. First weighting (more sharpness/size/smile) picked laughing, eyes-shut, looking-up
  covers; the reweighted one matched or beat Vision-quality covers on the 12 largest groups.
- Covers: user-picked face, else best by score gated on yaw < 0.35, pitch < 0.3, eyes >= 0.5, sharpness >= 120,
  photos over video frames.
- Bursts: same folder, <= 2 s apart, Vision feature-print distance <= 0.48 (checked by eye: 0.37/0.45 near-identical,
  0.55 same person different pose, 0.65+ different shots). The feature print cost 46% of ingest when computed inline,
  so it is computed from the JPEG's embedded preview in an idle-time pass (542 photos: 7 s).
- Sessions: 30-minute gaps.
- Search (people all/any, solo/group, kind, dates, folder, best only, bursts) and smart albums.
- Delivery rules (folder per person, optional edits/names, macOS notifications; idle-time only). Zalo/Telegram
  dropped at the user's request.
- Per-person video export: 20 s of 4K HEVC reel from 7 appearances in 20 s; clips cut without re-encoding.
- Web gallery: static export (11 s for 3 people/150 photos) and LAN server (token URL, Bonjour, Range streaming,
  chunked downloads, rename by POST).
- Tools: Batch Export, Batch Rename (updates library paths), Copy Verifier (+repair), Video Tools.

## v0.4.2 (2026-10-22): freezes
- Search froze: video thumbnails called a synchronous frame grab that waited on a Swift Task from inside the
  cooperative pool; with enough videos on screen every pool thread waited and nothing else (search, person pages,
  video ingest) could run. Synchronous video helpers now use AVFoundation callbacks; thumbnails are async, 4 at a
  time. A task-executor wrapper was tried first and still deadlocked (continuations resume through the pool).
- Person search: 24.6 s → 0.08 s on a library where one person has 12,778 faces; SQLite used the person index for the
  per-file best-face subquery (`+bf.personId` keeps it on the media index). Smart albums hit the same query.

## v0.5 (2026-10-22): projects, watermark presets, edit layout
- Projects (table `project`, `source.projectId`; `smartAlbum`/`deliveryRule.projectId`, nil = all). Existing folders
  became "First Project". Every query takes a project scope (`ProjectScope.sql`); ingest is unchanged.
- People stay global. New groups are clustered per project (newest faces first, pool capped per project), then
  leftovers are matched against every person, so the same artist at two events is one person and a name given once
  carries over. This also fixed a latent loop: a capped pool that formed no groups was reclustered forever.
- A folder can be in one project only; nested/overlapping folders are refused (their files would be listed twice).
- Watermarks: presets (logo or text with shadow) in Settings; each screen keeps its own copy and remembers its edits.
- Edit layout: large preview (1600 px decode cache, before/after, output size, click-to-place watermark), film strip
  of 96 pt thumbnails, inspector with crop shapes and a 3×3 alignment grid.
- Sessions per project (`EventSessions`): split at gaps in capture time (default 30 min), names stored as a moment
  inside the session (table `sessionLabel`) so they survive the session growing. One selected session filters People,
  faces, person pages, search, exports and the batch tools. 21 sessions for 7,170 files in 8 ms. Times are camera
  clocks: a camera set to the wrong time lands its photos in odd sessions.
- Batch Export picks photos with tick circles (whole top-right corner is the hit area, one click handler per
  thumbnail; v0.5's circle was a nested button that lost clicks to the thumbnail), a grid of all photos, and PNG.

## v0.5.2 (2026-10-22): review fixes (data safety, privacy, correctness)
- Nothing is overwritten: Batch Export, Video Tools and video moments reserve unique names (`OutputNames`, " (2)").
- Batch Rename renames files and records together while every folder watcher waits (`holdingMonitors`); records move
  through temporary paths so swaps and shifted numbers don't hit the unique path. A file that can't be renamed goes
  back to its old name.
- Renamed/moved event folder: "Locate Folder…" relinks it (`relinkSource`); adding it again relinks automatically
  when a sample of its files matches by size and content key (names alone are not enough: cameras reuse DSC_0001).
- Delivery marks only copies that landed (`Exporter.Result.handled`); an unmounted target is skipped without marking,
  failed pairs wait 5 min, same-named files from two cameras are both kept.
- One name, one person (`PersonNames`): NFC + case-insensitive in Swift (SQLite NOCASE only folds ASCII). Migration
  v7 merges duplicates, moving faces, rules, delivery history and album queries. Export ranks and crops by person id.
- LAN gallery: file/thumb/view/face routes and renames are limited to the shown project's event files.
- Search filters (best shots, one per burst via a window function) run in SQL; no 5,000-file cap. Same speed.
- Copy Verifier: checksums on by default, unreadable files count as damaged, repairs go through a checked temp file.
- Move All re-runs keep a photo already in someone's folder; files seen growing settle for 5 s (15 s on NAS); a
  folder offline at launch is polled every 5 s until its volume is known; copies are only duplicates within a project.

## v0.6.1 (2026-10-23): teams (several Macs, one event) and auto rules
- **Team sync** (`TeamSync`): a project is shared through a folder every Mac can reach (NAS share, Dropbox, iCloud
  Drive). Chosen over CloudKit/Bonjour for now: nothing to sign up for, works at the venue with no internet, and it
  is testable here end to end. The folder holds `team.json`, `devices/<deviceId>.jsonl` (each Mac appends only its
  own log: person, merge, session, rule changes with the time they were made) and `summaries/<deviceId>.json` (the
  mean ArcFace embedding and face count per person, rewritten at most once a minute). No locking is needed because
  nobody writes anyone else's file; readers consume whole lines only, so a half-appended line is read next pass.
- Stable ids: `person.uuid`, `deliveryRule.uuid`; `person.nameAt`, `deliveryRule.updatedAt`, `sessionLabel.updatedAt`
  give last-writer-wins. Merges are tombstoned in `personMerge` (chains rewritten) so every Mac merges the same
  people; the same name given on two Macs independently converges on the smaller uuid. Rules travel with people as
  uuids and wait in `syncDeferred` until those people are known. Deleted rules and cleared session names are kept as
  rows (`deletedAt`, empty name) so the deletion travels.
- Recognition across Macs: `personRemote` rows feed the grouping engine as weighted units (`addRemote`, capped at
  30 per teammate's Mac), so a face on Mac B matches a person named only on Mac A, and autoName merges B's unnamed
  group into them. The published centroid is computed from local faces only (`localSummary`).
- Scope: a person travels to a team when they have faces in the team's project (or a rule of it names them). People
  named elsewhere stay private to the Mac until they appear in the event. Leaving a team keeps names, drops summaries.
- Passes every 5 s; a user change (`pushSoon`) publishes on the next pass. Status (reachable, Macs, last sync) is
  shown under the project switcher. 9 tests (`TeamSyncTests`) run two libraries against one folder.
- Known limits, for later: rule target folders are shared as paths (works when every Mac mounts the same share at
  the same path; otherwise the rule waits and the list says so); two Macs ingesting the same card both export (plain
  copies dedupe by content key, edited copies don't); embeddings are only comparable within one model (`model` tag).
  Next transport candidates on the same files: CloudKit (join by link with the Apple ID; needs the iCloud entitlement
  and a provisioning profile in `build-app.sh`) and Bonjour for venues without a NAS.
- **Auto rules** generalise delivery rules: the trigger is a `MediaQuery` (people all/any, solo/group, photos/videos,
  best shots, one per burst), the layout is per-person folders or flat, and rules can be edited. Older rules keep
  working (the person becomes a one-person query). `DeliveryService.pending` runs the query and subtracts the
  `delivery` ledger; flat rules use `delivery.personId = 0`. 3 tests (`RuleTests`).

## v0.6.2 (2026-10-23): Known-People faces travel to teams
- A person travels to a team when they have faces in the team's project or in any Known-People folder (those
  are for every project). Before, a person enrolled only from Known People stayed private until they appeared in an
  event photo, so a teammate's Mac grouped them unnamed; a Known-People enrolment now also publishes at once
  (`Processor.onReferenceEnrolled` → `pushSoon`). Summaries are checked every pass by a per-person face count and
  written when they changed (at most once a minute while faces keep arriving).

## v0.6.3 (2026-10-23): updates, dmg, team folder moves, everyone travels
- Sparkle 2 (SwiftPM binary) embedded by `build-app.sh` (framework in Contents/Frameworks, rpath added with
  install_name_tool, nested XPC services/Autoupdate/Updater.app re-signed inside out with entitlements kept). Feed:
  `releases/latest/download/appcast.xml` on the (now public) GitHub repo; `release.sh` also makes a notarized dmg and
  the appcast (`generate_appcast`, EdDSA key in the login keychain); `publish.sh` tags and uploads all three.
- Team folder relocation (`TeamSync.relocate`): same team uuid at a new path; another team's folder is refused. A
  team folder is one event's: joining it from a second project is refused with an explanation.
- Every named person on a Mac travels to its teams (not only the project's), so Known-People prepared before the
  event and people from earlier events reach every Mac. Summary signatures are checked every 15 s, written at most
  once a minute while faces keep arriving.

## v0.6.4 (2026-10-23): a team holds many projects; rename team; sidebar
- `project.uuid`, `project.teamId`, `project.updatedAt`; `team` no longer points at one project (table recreated in
  migration v10). The project a team held before gets the id `<team uuid>-project` on every Mac of that team, and
  session/rule changes logged without a project (0.6.x logs) land there, so existing team folders keep working.
- Log gains `project {uuid, name, at}` (LWW on the name); session and rule ops carry `project`. Joining a team
  brings its projects (created locally by uuid; teammates add their own folders). Unknown project → the change
  waits in `syncDeferred`; a project deleted on this Mac is remembered (`gone:project:<uuid>`) so it never comes
  back. Stop Sharing removes the project from the team on this Mac only; Leave Team keeps the projects as local ones.
- Rename Team writes `team.json`; every Mac re-reads it each pass.
- Sidebar: team card (tinted, "TEAM") above the project card ("PROJECT"); the project menu groups projects by team
  and "Only on this Mac"; the team menu lists the team's projects, Macs and actions.
