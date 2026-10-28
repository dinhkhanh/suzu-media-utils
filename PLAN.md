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
- Two lanes (2026-10-26): log passes every 2 s and at once on a user change (`pushSoon`); face passes (summaries,
  face records, crops) every 5 s on their own queue, so a backlog of faces never holds a name or a pin back.
  Teammates' logs are sized from the open file, not the folder listing (macOS caches SMB listings). Status (reachable, Macs, last sync) is
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

## v0.6.5 (2026-10-23): skip similar and blurry shots in Batch Export
- `ShotCuller` (FaceCore): per photo capture time (EXIF, else mtime), Vision feature print, main-face sharpness
  (aligned-crop Laplacian variance, the library's measure) and a whole-frame blur index (Crete et al. re-blur
  metric on the 1500 px detection decode). Blurry = main face < 60, or no usable face and frame index > 0.58
  (1,046 sharp library photos read ≤ 0.52; a 5×5 box blur at 1500 px reads 0.56–0.73). Similar = same rule as
  `BurstGrouper` (≤ 2 s apart, print distance ≤ 0.48), neighbours in the folder when times are missing; the best
  by library score, else face sharpness, else frame. Blurry go first so a group keeps a sharp one.
- Batch Export: two checkboxes under the photos; the check runs when they or the photos change, unticks the losers
  (reason on hover) and the user can tick any back. Library-known photos come from `Selection.measures` (no
  decode); the rest are read in parallel (~0.1 s each with faces).
- Copy/Move (ExportSheet) and `Exporter.Options.skipBlurry`: leaves out photos whose biggest face is soft.
- Whole-frame blur alone cannot tell a blurry subject from a sharp background (tested: no separation against face
  sharpness on 1,046 photos), hence the face-first rule.

## v0.6.6 (2026-10-23): rules skip similar and blurry shots; RAW files
- `MediaQuery.skipBlurry` (SQL: the biggest face ≥ 4% wide has sharpness < 60 → out; no measurement = in), with a
  tolerant `init(from:)` so saved albums, rules and team logs without the newer keys still decode. The query's
  existing `collapseBursts` is the rules' "skip similar"; `maintain()` now defers deliveries for such rules until
  new photos have feature prints and bursts are regrouped, or every shot of a burst would be delivered.
- RAW: `ImageLoader.rawExtensions` joins `extensions`; `decode` uses the RAW's embedded preview when it is at least
  ¾ of the size wanted (else develops at that size, which ImageIO does at reduced resolution quickly). Edited RAW
  exports develop at full size. `Metadata.rewrite` already refuses non-JPEG/HEIC/PNG/TIFF. Bytes read into memory
  need `kCGImageSourceTypeIdentifierHint` (`ImageLoader.sourceOptions`): without it a Sony ARW decodes as an empty
  TIFF. Checked on ILCE-7M4 ARW: preview decode 0.03 s, faces found, full-size edited export 0.5 s.
- RAW+JPEG pairs (`ImageLoader.pairKey`: folder + stem, case-insensitive): the scan inserts JPEGs first and makes the
  RAW `duplicateOf` its JPEG (status done, never processed); a RAW that arrived first is paired when its JPEG comes
  if it is still pending; one already processed stays on its own. Batch Export's file list drops RAWs whose JPEG is
  in the list.


## v0.6.7 (2026-10-23): zoomable crops
- `CropPlacements.Edit.zoom` (1…`maxZoom` = 4, to a hundredth; 1 is stored as nil): the crop is 1/zoom of the largest
  that fits. It rides along in `FocusHint.zoom`; `EditPipeline.cropRatio` crops a zoomed photo without a preset to its
  own shape, `cropRect` shrinks the crop, and `decode` keeps `zoom` times less detail. A focus with only a zoom (no
  faces, no centre) means the faces are unknown: `apply` detects them, so a zoomed crop still keeps the people in.
- Preview: pinch (MagnifyGesture) zooms about the crop's centre and saves zoom + centre; the Zoom button's slider saves
  the zoom only, so the faces place the smaller crop until it is dragged. The drag/zoom overlay scales the whole photo
  by the gesture's crop, so a pinch shows live. The top overlays wrap in narrow previews (ViewThatFits) instead of the
  before/after switch covering the crop tools.
- Keyboard in the preview: the whole EditPreview is `.focusable()` (focus taken on appear with several photos, and on
  any click on the preview, strip or grid); ← → ↑ ↓ step (↑ ↓ by a row in the grid, from the grid's measured width),
  Home/End jump, Space ticks or unticks the shown photo, Return opens a grid photo large. No wrapping at the ends.
- Right-click menus flashing: `tick()` published `rate` every second even when unchanged (every published change
  redraws every screen, and a redraw while a context menu is open rebuilds the menu, so its "This Is ▸ name"
  submenu couldn't be clicked). Now published only on change. The People grid's cells are `PersonGridCell`
  (`Equatable` on person, selection, known names, editing) so background updates during ingest don't rebuild
  their menus either; `ThisIsMenu` and `FaceAssignItems` take the known people as plain data instead of watching
  the model.

## v0.6.8 (2026-10-23): session bar everywhere; ⇧-click ranges
- `SessionBar` shows whenever the open project has capture times (one session included) and takes `divider:`.
  It sits on Files, Search (not albums), person pages and Batch Export (not the Edit & Export window, whose photos
  are the ones asked for). Files filters by `takenAt` within the session; the batch tools' Files & Folders source
  reads capture times (EXIF, else mtime, as the library does) off the main thread and keeps only the session's files,
  with a "n of m in <session>" line; People source already followed the session.
- `Set.click(_:in:)` takes the grid's order: ⇧-click selects from the selection to the clicked item (⇧⌘ adds the
  range), `extend(to:in:)` for the face grids whose plain click toggles. Used by People, person pages, Search, Files
  (grid; the table has it natively) and face grids.

## v0.6.9 (2026-10-23): named people are remembered when their faces leave the library
- Removing a folder, or files deleted or changed on disk, kept the names but dropped every face of them, so the
  same photos added again came back as unnamed groups. `PersonMemory.remember` runs in the transaction that deletes
  the faces: a named person's mean face and unit count go into `personMemory` (migration `v11-person-memory`,
  cascades with the person). `GroupingEngine.addMemory` counts it like a teammate's summary (weight capped the same
  way); `PersonNames.merge` carries it onto the target.
- Picking a name in the known-name suggestions saves it at once (`knownNameSuggestions(for:onPick:)`): a change
  that replaces the text with a suggested name is a pick, typing one more letter is not.

## v0.7.0 / v0.7.1 (2026-10-24): Copy from Cards
- `CardCopier` (FaceLibrary): a card is known by its volume UUID (a plain folder by a hidden `.suzu-card` marker,
  since its volume UUID would be the disk's); `card` rows carry label, volume name and the camera's make, model and
  body serial from the first photo's EXIF. `plan` lists the card's media and sidecars, marks files whose path, size
  and mtime (±2 s, FAT) match this card's `cardFile` ledger as copied without reading them, reads the content key of
  the rest and matches it against every card's ledger and `media.contentKey` (copied by hand), and the remainder is
  new. `copy` streams each new file through SHA-256 to a temporary name, checks size (and reads it back with
  `verify`), keeps the mtime, renames it, and records it as it lands; same-name-other-contents gets `_1`, same
  contents already there is recorded, not copied; files matched by contents while planning are recorded too.
  Destination: `<dest>/<card name>/<yyyy-MM-dd HH.mm>/` (a folder per hand-over, optional), flat or with the card's
  folders. The ledger travels with the team: `TeamSync` publishes `card` ops (label, volume name, camera; newest
  label wins by `labelAt`) and `cardFile` ops for entries made here (`device IS NULL`, past the `pub:cardFiles`
  cursor); a teammate's entries are inserted with their `device`, so they are counted ("copied on a teammate's
  Mac") but never republished. The Cards screen runs a sync pass before planning, so a card copied on another Mac
  a minute ago is known here.
- `CardCopyTool` lists mounted removable/ejectable volumes with DCIM/PRIVATE (or media at the root), looks again on
  mount/unmount, plans each card off the main thread, copies one card at a time with progress and Cancel, checks the
  destination's free space, and can add the card's folder to the open project (`addCopiedFolder`, skipped when a
  library folder already holds it). Cards seen before can be named or forgotten. `SUZU_CARD_VOLUMES=/a:/b` stands
  folders in for cards when testing.
- A card pulled in the middle of a copy (or a destination that goes away) stops the copy at once
  (`Outcome.interruption`): the file under way is dropped with its temporary name, what landed is recorded, the rest
  stays new, and nothing is listed as failed. A volume counts as reachable only while something is mounted at its
  path (a pulled card's mount point lingers for a moment), checked again after half a second on any error. The Cards
  screen keeps the pulled card's row with the result, and when the card is back `Options.folder` continues the same
  hand-over's folder instead of starting another.
- Files on a card are photos or videos (`File.kind`); a sidecar (.xmp, .xml) takes the kind of the file it goes
  with. The plan counts new photos and new videos apart; `Options.videoDestination` sends videos to their own
  place (their own card folder and hand-over folder there, `Outcome.videoFolder`), the photos' destination
  otherwise. Both card folders can join the project.

## v0.7.2 (2026-10-24): Edit & Export shows its photos again
- `ToolInputView`'s task (session range, project, chosen people) ran on appear too and, in Files mode, set the
  items from its own empty file list, wiping the photos `BatchExportTool(initial:)` was given from the library. It
  only rebuilds the items from files when some are chosen there. `SUZU_START_EDIT=/a.jpg:/b.jpg` (testing) opens
  the Edit & Export window on launch.

## v0.7.3 (2026-10-24): a destination per card, cards copying side by side
- `CardCopyModel.ownDestinations` (UserDefaults `cardCopyOwnDestinations`, by volume UUID: this Mac's paths, not
  part of the team's ledger): a card's own place instead of the screen's destination, picked from a folder menu in
  its row and kept for its next hand-over. Videos still go to the screen's video destination when they have one.
  Free space and the interrupted hand-over's folder are checked against the card's own place.
- Copy New Files no longer waits for the other cards: cards to different disks copy at full speed side by side,
  cards to the same disk share it. `ToolWork.begin/end` count the jobs under way so the library's extras stay paused
  until the last one is done.

## v0.8.0 (2026-10-25): the redesign — Overview, workflow sidebar, appearance, People/Person/Files/Cards/Export
- `App/OverviewView.swift`: the start screen. `OverviewStats` (picks/rejects/★3+, deliveries + last delivery, photos
  with unassigned faces) is read in the model's background tick beside `LibraryStats`; the `delivery` table joins the
  region observation. `ActivityItem` feed (`FaceGroupingModel.log`): names, merges, deliveries (`onDelivered`), folders
  added, scans finished, folders offline/online, new sessions; capped at 60, this Mac only.
- `AppShell`: `AppRoute.overview`, `FaceRoute.toName` (People filtered to unnamed), `AppRoute(key:)`/`key` shared by
  `SUZU_START_ROUTE` and the "where I left off" start screen (`lastRoute`). Sidebar: Overview · Files, People (People,
  To Name, Unassigned Faces, Search, Auto Rules), Smart Albums, collapsible Folders / Known People, Tools.
  `FaceGroupingStatus` is a pill (rate, time left, team sync) with an activity popover.
- `App/Appearance.swift`: `appearance` (system/light/dark → `.preferredColorScheme` on every scene, also View →
  Appearance), `accent` (coral or the Mac's → `.tint`; `Color.accent` replaces `Color.accentColor` in custom
  drawings), `startScreen`. Dynamic `NSColor`s for coral/amber/good/panel so both modes come from one definition.
- `App/Chrome.swift`: `Chip`, `FaceChip`, `SelectionBar`, `ChipRow`, `SectionLabel` shared by the screens.
- People: 150-px tiles, dashed Add name, ⏎ to the next unnamed, ⇥ skips (`onKeyPress(.tab)`), banner with Start
  Naming, floating bar (Merge into One, This Is…, Open). Person: hero header, `companions(of:)` query ("often with",
  toggles `alsoWith`), tab row, Best N / Hide bursts chips, `PersonMediaTile` (score, burst, time, session).
- Files: `FolderColumn` (sources, subfolders of the open folder, offline flag, source context menu), `filterRow`
  chips, `selectionBar`. Cards: `CardRow` as a panel with a status pill, sentence, destination line, `DestinationBox`
  column, Copy New Files from All. Batch Export: cull switches and count live in the bottom bar.
- Found while verifying: a `Text + Text` with `.fixedSize` inside the People banner blanked the whole
  `NavigationSplitView` on macOS 15; plain `Text`s in a `VStack` instead.

## v0.8.1 (2026-10-25): lists and pins; redesign follow-ups
- Lists of people (`FaceLibrary/PersonGroups.swift`, migration `v13-lists-pins`): `personGroup`, `personGroupMember`,
  `person.pinnedAt`. `PersonSummary` carries `pinned` and `groups`; `PersonGroupSummary` is read in the tick and the
  two tables join the region observation. Routes `FaceRoute.pinned` / `.group(id)` (keys `pinned`, `group.<id>`);
  `PeopleGrid(scope:)`; `ListsMenu` is the shared "Add to List" menu (lists ticked, New List…, suggested names);
  new/rename-list alerts live on `AppShell` (`askNewGroup` / `askRenameGroup`). `PersonNames.merge` moves lists and the
  pin onto the survivor. Not synced to the team (local to the Mac, like marks).
- People grid: the name field is always present again (the dashed "Add name" is the empty field), so a click lands in
  it directly; tiles are top-aligned so a list line under one doesn't shift its neighbours.
- `.focusEffectDisabled()` on the team/project menus and the appearance cards (first-responder ring at launch).
- `LabeledSwitch` (`App/Chrome.swift`): label left, switch right; used by Copy from Cards' options column.
- Settings › Watermarks: the fields column is a fixed-height scroll view, so Banner no longer resizes the window;
  banner Opacity/Margin sit side by side.
- Edit & Export (was Batch Export) as a photo editor. `MediaKit/EditRecipe.swift`: `Adjustments` (light, colour,
  detail, quarter turns, flips) on the recipe and, per photo, on `CropPlacements.Edit`; `FocusHint.rect` /
  `Edit.rect` is a crop drawn by hand in any shape. `EditPipeline.apply` = orient → tone (auto + adjust) → level →
  crop → resize → watermark; `previewLongSide` scales the cropped photo to the screen before the watermark so previews
  are sharp at any zoom. `EditPreview`: view zoom/pan (⌘+ ⌘− ⌘0 ⌘1, ⌥-scroll, pinch, Space-drag via `EventCatcher`'s
  local event monitor), renders at `renderLongSide` screen pixels (detail decode up to 5000 px when zoomed or
  cropped tight), crop tool (C) with handles / move / rotate-outside / straighten line, live level, Zoom and Level
  buttons with fixed-width labels so their popovers stay put. `EditControls`: Light/Colour/Detail/Orientation sliders
  (`AdjustSlider`), `Look` presets, "All photos | This photo only" (`photo`/`photoCount`, reported by the preview's
  `shown` binding). Settings › Watermarks: list the full pane height, bigger preview.
- Tone curve (`Adjustments.curve`, five outputs for CIToneCurveAdjust's fixed inputs) and HSL (`HSLAdjust`, applied
  as a 32³ `CIColorCubeWithColorSpace` cube built in `EditPipeline.hslCube`, cached by value). `UserLooks` saves
  looks in UserDefaults ("looks"); `EditHistory` registers recipe and per-photo edit snapshots with the window's
  UndoManager, coalescing changes of one kind within 0.8 s (a slider drag is one step).


## v0.8.2 (2026-10-25): recognition across looks; People grid responsiveness
Problem reported from an event: the same artist in a new outfit, make-up, accessories or a turned head was split
into several groups, or left in Unassigned Faces, although the faces are plainly the same person.

Measured on the dev library (4,466 faces, 169 people, 96 hand merges) before changing anything:
- Replaying its faces in arrival order through the old flow (batches of 5–100 photos) split only 2 people, so a
  single average-linkage threshold is not the weak spot: the people the user merged by hand cluster as one at 0.45
  when clustered together.
- Among named people, leave-one-out: a face's mean similarity to its own person's other faces ≥ 0.50 in 99.2% of
  cases, the mean of its 3 nearest ≥ 0.50 in 100%; to any *other* named person the centroid never exceeds 0.30 and
  the 3-nearest never 0.32. There is a lot of margin below 0.50.
- 327 faces of usable quality (≥ 0.3, ≥ 40 px) were unassigned. Nearly all (310) resemble nobody at 0.40 and are
  people with 1–2 photos (32 such pairs in the event; groups need 3 faces). The rest are profiles, goggles, hands
  over the mouth, a cap: 0.39–0.49 to their person's centroid, 0.50–0.64 to their person's nearest faces. Checked
  by eye on contact sheets: nearest-3 ≥ 0.50 was right in every row; low-quality (< 0.3) faces at ≥ 0.55 too.
- A person's mean vector is a poor stand-in for a person photographed many ways: the centroid of 50 frontal shots
  is 0.4 from their profile even though their 5 profile shots are 0.6–0.7 from each other.

Changes (`GroupingEngine`):
- **Exemplars**: each person keeps up to 32 unit vectors chosen for diversity (a face joins the set when it is
  < 0.80 similar to every exemplar so far; best quality first on rebuild), so profiles, hats, glasses and make-up
  each get a representative. Teammates' and remembered summaries add their raw mean as an exemplar (normalizing
  it inflated every score by 1/‖mean‖ and made a diverse 213-face person on another Mac the near match of an
  unrelated group, found in the first run on the real library; raw, a score against it is exactly the mean
  similarity to those faces).
- **Assignment** takes a face when its centroid score ≥ 0.50 *or* the mean of its 2 nearest exemplars ≥ 0.50
  (`nearestThreshold`); low-quality faces need 0.55 / 0.56. On the dev library this names 41 more faces (profiles,
  goggles, eyes shut, hand over mouth), all right by eye.
- **Consolidation** (`consolidate`, replaces `autoName`): after every recluster, each person that gained units is
  compared with every person. Two merge when their mean pairwise similarity reaches the clustering threshold
  (0.45: the clustering they would have formed together) or when most (and ≥ 2) of the smaller group's exemplars
  have a near match (≥ 0.50) among the larger's exemplars. Never merged: two people with different names, and two
  people the user told apart ("Not this person", or faces moved between them: `LibraryService.assign` now marks
  moved faces as rejected from the person they left). Unnamed groups join named people as before, and now also
  each other; the named one survives, else the larger, else the older.
- **Speed**: every person's mean and every exemplar live in two flat Float matrices (`Rows`) scored with one
  `cblas_sgemv` each; dead rows of rebuilt or merged people are compacted when they outnumber the live ones.
  `Vector.dot` is `vDSP_dotpr`. Assigning the dev library's 738 waiting faces: 32 s → 0.33 s in a debug build.
  Consolidation at launch (everyone is a candidate) scores candidates in chunks of 256 against all means.
- Replay of the dev library with the new flow, batches of 5: 0 people split, 0 wrong merges (the two "mixed"
  groups it reported were the same man in profile vs frontal, and the same poster, that the user had not merged).
- Tests: `GroupingTests` (new look joins through exemplars, groups formed apart merge, user decisions kept,
  exemplars cover looks and survive rebuild/merge).

Not changed, worth knowing: groups still need 3 faces (an event has dozens of guests with exactly two photos, each
would become a tile); faces below quality 0.3 are never clustered, only matched (≈ 19% of units; posters and
blurred background faces live there); faces are embedded from the 1500 px detection decode (a 40 px face is a
40 px face). Teammates share only a mean per person; sharing exemplars would let a profile seen on one Mac match a
profile on another.

People grid: clicking into a name field now selects that tile (the click lands in the field, not the tile, so the
old selection stayed highlighted); clicking another tile while typing moves the typing there (⌘/⇧-click ends it).
Lag: every tile was handed its own filtered copy of the known-people array and `shown` was recomputed per tile
(people² work per click); tiles now share the array (`==` is O(1) on shared storage) and the order is computed
once. Face crops not yet in memory load off the main thread (`FaceImage.task`), so a long grid scrolls without a
disk read per tile.

## v0.8.3 (2026-10-25): one Mac processes faces for the team; auto tone as dials; measured non-changes
**Shared processing (`FaceLibrary/SharedFaces.swift`).** At an event one strong Mac recognises faces while the Macs
that copy cards and edit only use the results. The team menu has "This Mac processes faces for the team" / "Every
Mac processes its own files"; the choice lives in `team.json` (`processor`), read by every Mac each pass, and in
`team.processorId/processorName`. With no Mac chosen nothing changes from before.
- The processing Mac appends one record per processed file to `faces/<its id>/media-NNNN.jsonl` (rotated at 64 MB):
  content key, project, size, duration, taken time, feature print, and per face the box, quality, embedding
  (base64), best-shot measures, person (stable id), assignment and rejected person; crops go to
  `faces/<id>/crops/<content key>/<n>.jpg`. `facePublish` (filled by the Processor) says which files are new; a
  trigger (`faceChangeLog` → `faceChange`) catches every change of a face's person, by any code path, and the
  file's record is written again, at most every 20 s per file. 150 files per pass.
- Other Macs read the records in order (cursor per file in `syncState`), remember each by content key in
  `faceIndex`, and take the ones whose file is waiting here: faces inserted in record order (so a face's position
  in the file identifies it on every Mac), people created by stable id when unknown (unnamed groups included),
  crops copied, `media.importedFrom` set. Waiting files get their content key computed (300 per pass) and are
  matched against the index, so it doesn't matter whether the file or its record turns up first. A record for a
  file already taken from the same Mac updates the faces' people in place; files processed locally are left alone.
- `Processor.processesLocally` (set by `LibraryService` from `TeamSync.processesLocally(sourceId:)`) keeps the
  other Macs from processing a team project's files; Known-People folders are always processed locally. The engine
  gets `passiveProjects` (never reclustered or assigned here) and `processesAnything` (a Mac that processes nothing
  merges nobody). `localSummary`/`localExemplars` publish own faces only (`importedFrom IS NULL`).
- Edits on a non-processing Mac ("Not this person", "Move to…", "New Person…") go into `faceEditPublish` and
  travel as `face` ops in its log (content key, face index, person, assignment, rejected); every Mac applies them to
  the same face, the processing Mac's trigger republishes, and everyone converges. Names and merges travel as before.
- Status: the pill and the Overview say "Waiting for <Mac>: N files"; the team bar caption says who does the faces.
- Tests: `SharedFacesTests` (faces appear on the other Mac whether the file or the record came first, with the same
  people by stable id and the crops; grouping changes follow; a rejection on the laptop reaches the processing
  Mac and holds; without a chosen Mac nothing is published and the queues stay empty).
- A person's picture picked by hand travels too: `person.coverAt` (migration v15), a `cover` op in the log naming
  the face by its file's content key and position (or none: back to automatic), newest wins, deferred until the
  Mac has that file.
- Not done: a Mac that was the processor keeps its own faces when the role moves (the new processor's records are
  taken only for files still waiting).

**Exemplars travel with team summaries.** `summaries/<id>.json` entries gain `e`: up to 8 exemplar faces as
Float16 rows (`Vector.encodeHalfRows`), kept in `personRemote.exemplars` and added to the person's exemplars on
the reading Mac, so a profile seen on one Mac matches a profile on another. Older summaries without `e` still work.

**Faces of quality 0.2–0.3 are units.** `minQuality` 0.3 → 0.2: they are matched at the normal bars and clustered;
exemplars still need 0.3 (`exemplarMinQuality`); a new group made only of such faces needs mean similarity 0.55
(`lowQualityGroupThreshold`). Measured on the dev library: 206 such faces, clustered alone at 0.45 and 0.55, every
cluster of ≥ 3 was one person (or one poster); the labelled ones match their person at p10 0.63, no other person
above 0.32.

**Unassigned Faces: "Seen twice".** `FaceGroupingModel.likelyPairs` clusters the project's clear unassigned faces
(≤ 3000) with the engine's own linkage and shows the pairs (two photos, not two faces in one) above the grid, each
with a Name menu (new person / someone known) and click-to-select. The dev event had 32 such guests.

**Measured and not changed** (`scratchpad` scripts `evalmodels.py`, facescan `--flip`; 9 named people / 257 faces
from the dev library, leave-one-out against the user's own labels):
- Flip test-time augmentation (average of the face and its mirror): own-person scores +0.01–0.02, other-person max
  unchanged, margin p1 0.437 → 0.441. Doubles Neural Engine time per face. Not shipped; facescan keeps `--flip`.
- 3000 px crops for small faces: only faces under 60 px gain (nearest +0.012), 60–112 px nothing; the detect stage
  took 1.5–3× longer (SUZU 02: 11.8 s → 36.7 s). Not shipped.
- InsightFace GlintR100 (antelopev2, Glint360K) converted the same way as ArcFaceR50 (`convert_models.py` pattern,
  mean/std 127.5): profile p5 0.661 → 0.675 nearest, but other-person max 0.30 → 0.32 and margin p1 0.437 → 0.394;
  with flip, margin p1 0.437, p5 0.531 (+0.02) at 3.3× the embedding time and 3× the model size. ArcFaceR50 stays;
  any model change would also mean re-embedding every library and recalibrating every bar.

**Editor.** Auto tone no longer runs Core Image's opaque filter chain: `EditPipeline.autoAdjustments` reads what
`autoAdjustmentFilters` would do (CIToneCurve → the five curve points, CIHighlightShadowAdjust → highlights/shadows,
CIVibrance, CIExposureAdjust; CIFaceBalance has no dial and is dropped) as `Adjustments`, scaled by Strength, and
`tone()` applies `look.composed(over: auto)`: sliders add, the user's curve composes over auto's (`compose`),
black & white / HSL / detail are the user's. The preview keeps each photo's auto values (`AutoToneValues`) and the
controls show `shown = look.composed(over: auto)`; moving a dial sets `look = shown.subtracting(auto)` (curve by
inverting the monotone auto curve, `unwind`), so what is shown is what is applied, per photo, with the user's
changes as a delta that also applies to the other photos' own auto values. "Reset All Dials" and double-click on a
slider (an NSSlider, `DialSlider`; SwiftUI's swallows the click) reset. Tests: `AutoToneTests` (dials non-empty on
a dark gradient, strength halves them, compose/subtract round trip, pipeline output identical to the dials).
Crash fixed: Edit & Export with "All" people listed a photo of two people twice and
`Dictionary(uniqueKeysWithValues:)` trapped (`CropPlacements.edits`, `EditHistory`, `culled`); the tool's list is
deduplicated by path and the dictionaries tolerate repeats.

**People/person pages.** Session chips no longer take the focus ring on a new page (`focusEffectDisabled`); the
person page's photo tiles are `Equatable` and the grid order is computed once, so a click highlights at once.

**Thumbnails like the Finder's.** Grids used to ask Quick Look for each file as it came into view: a full read and
decode per file, slow on a NAS and not kept. Now every file has a thumbnail file (`thumbs/m<id>.jpg`, long side
400, `media.thumbAt`): made from the 1500 px decode the Processor already has (a scale, ~free), by the idle-time
pass for the rest (`enqueueThumbnails`: embedded preview or a reduced ImageIO decode, never a full one, videos a
frame a moment in), shared with the team next to the face crops (`crops/<key>/thumb.jpg`) so Macs that don't
process never read the file, and remade when a file changes on disk. `Thumbnails.media(url, id:, time:, side:)`
reads memory, then that file (six at a time off the main thread), then makes and keeps one; files outside the
library (a tool given files) get a reduced decode, not Quick Look. The video frame at a person's time still comes
from the video.

**Bursts keep the RAW.** Of near-identical shots, the one kept is a RAW file before a JPEG/PNG, then the best by
score: `ImageLoader.rawSQL` in the search and selection queries, `ShotCuller.best`, the person page's Hide bursts.

**Copy File Path** under Show in Finder (person page, selection bars, search, Files, Unassigned): one path per line.

**Responsiveness.** Three things made a click feel late during ingest: the processing rate was a `@Published` on
the model, so every screen redrew every second (now `ProcessingStatus`, observed by the status pill only); every
database commit marked the model dirty and the 1 s tick re-read people, stats, sessions, albums, rules and
overview each time (now at most every 3 s while files are queued; a user's own change still refreshes at once,
`refresh()` → `urgent`); and grids rebuilt every tile on a selection change (People, person page and Files tiles
are `Equatable` + `.equatable()`, orders computed once per redraw). Thumbnail decoding measured on 33 MP JPEGs:
ImageIO straight to 400 px 105–123 ms (it decodes most of the image), to 1500 px 71 ms (quarter-scale DCT) + a
medium-quality scale to 400 px ~2 ms (high: 9 ms), the camera's EXIF thumbnail 0 ms at 160–256 px. So kept
thumbnails come from the 1500 px decode, and a grid that finds none yet shows the EXIF one at once while the idle
pass makes the real one.

## v0.8.4 (2026-10-25): everything at once at an event; hybrid processing; three kinds of team folders

**Three kinds of folders in a team (`SourceShare`: mac / team / edited; migration v16).** `source` gains `uuid`
(stable across Macs), `share`, `shareAt` (newest wins), `fromDevice` (the Mac it came from through the team, nil =
added here) and `removedAt`. Team and edited folders travel as `folder` ops in the device log (`FolderPayload`:
the sharer's path, the path relative to the team folder when both are on the same volume, the kind; `deleted` for
a removal, from `sourceGone`, filled by `LibraryService.removeSource`). Applying (`applyFolderOp`): the project by
stable id (deferred until known); a known uuid follows the newer kind (out of the team: dropped here when it came
through the team, kept as this Mac's own when it was added here); an unknown uuid is added at
`TeamSync.resolvePath` (relative to the team folder first, the sharer's path second, whichever is likelier when
offline), adopts a per-Mac folder already at that path (two Macs sharing the same folder independently keep the
smaller uuid), and waits (`.deferred`) while it would overlap another folder. `TeamSync.onSourcesChanged` →
`LibraryService.reconcileMonitors` starts, restarts (new path) or stops watchers and deletes `removedAt` folders in
the background. UI: three sidebar sections when the project is in a team, the Files column grouped likewise,
"In the Team" in the folder menus, File → Add Team Folder… / Add Edited Folder…. Tests in `TeamSyncTests`.

**Cards show while processing.** `CardCopyModel.refresh` ran `syncNow()` before listing volumes: a sync pass
under load (crops and content keys over the NAS) held the list for seconds and `looking` turned every new mount
into a flag. Now the cards list at once; `TeamSync.syncSoon(then:)` runs one pass in the background and the
plans are redone only when it brought copies teammates made (`CardCopier.teammateCopies`).

**Everything at once.** `LibraryStore`: `maximumReaderCount` 12, `PRAGMA synchronous = NORMAL` (WAL; a commit no
longer fsyncs; consistent through a crash). `Processor`: thumbnail and result in one transaction; `setForeground`
halves the workers while a `ToolWork` job runs; `enqueue(first:)`. `Exporter.run(workers:)`: copies and edited
exports a few at a time, destinations reserved under a lock (`Tally`) so colliding names stay apart (test).
`TeamSync.pull` / `pullFaces` apply a teammate's log in chunks of 200 ops / 100 records, cursor per chunk. Card
progress throttled (`ProgressThrottle`); Files re-lists on a structural change of the folders, not every tick.

**Faces from the card as each file lands.** The card is pulled the moment its copy ends, so waiting for the scan
meant the card was gone. `CardCopier.Options.onCopied(Landed)` reports each landed file (path on the share, path
on the card, size, content key, RAW-with-JPEG flag); `LibraryService.fileLanded` registers the row (the share's
own mtime, so the scan sees it unchanged; `INSERT OR IGNORE` against a scan that got there first), tells the
`Processor` to `prefer` the card path, and enqueues it first. `process()` analyses the preferred URL and falls back
to the library path when the card is gone. The card's folder joins the project before the first file lands. A RAW
whose JPEG came along is left to the scan, which pairs them. The bytes are still in the file cache from the copy.

**Hybrid processing (migration v17: `media.localWork`, `media.seenAt`).** A copying Mac processes the files it
copies even when another Mac is the team's processor: `fileLanded` sets `localWork`; `Processor.process` accepts
`localWork || processesLocally`, and does not call `engine.mediaProcessed` for them (the processor groups).
`publishFaces` on a non-processor publishes `facePublish` rows of `localWork` files once and drops `faceChange`
(edits travel as ops); on the processor the `changed` query no longer requires `importedFrom IS NULL`, so files
taken from copiers are republished once grouped. `take()`: the processor keeps its own work and takes any
record for a waiting file; everyone else treats the processor's record as authoritative, updating people in place
when the face count matches (`importedFrom` becomes the processor), replacing otherwise; records taken on the
processor with ungrouped faces go to `engine.mediaProcessed` after the transaction (`takenToGroup`). The waiting
loop now runs on the processor too, for fresh files only (`seenAt` within 10 min). `processingGrace(sourceId:)`:
on the processor, while another Mac's records were read in the last 10 min (`foreignFacesAt`), a fresh file waits
30 s for a copier's record before being read from the share (`Processor.graceFor`; re-enqueued, not counted).
Status pill: a copier's own queued files show as processing. Test: `SharedFacesTests`
`testACopyingMacsOwnWorkReachesTheProcessingMacAndComesBackGrouped`.

**UI.** Person page: header and tabs fixed, grid scrolls. People grid: `MarqueeText` (Chrome.swift) scrolls a
long name at ~40 pt/s on hover with an edge fade, driven by the tile's hover so the name field keeps the click.
Editor: Strength slider and Reset All Dials keep their place (disabled / faded) so the dials below don't move.

**Known.** `AutoToneTests.testUserChangesSitOnTopAndComeBackOff` fails on a clean checkout (before this release).

## v0.8.5 (2026-10-25): a card stuck at "Looking at the card…"; the sidebar hairline

**Regression in 0.8.4.** `CardCopyModel.Card.planning` defaults to true (the spinner shows the moment a card is
listed), and the guard added to `plan()` in 0.8.4 read it as "a plan is running" and returned, so a fresh card's
plan never started. Plans in flight are now tracked apart from the display state (`inFlight`). A request while
one runs, and the check after a background sync pass brought teammates' copies, no longer redo the plan (a read of
1 MB per new file off the card): `CardCopier.refine` moves the plan's new files against the ledger and the
library from the fingerprints it already holds (`Plan.keys`), in milliseconds, card pulled or not (test).

**Sidebar.** The team and project boxes were the list's top `safeAreaInset`, so the list scrolled under the window
toolbar and the toolbar's scroll-edge hairline was drawn across the project box. The header, the list
(`.listStyle(.sidebar)`) and the status pill are now a `VStack` in the sidebar column.

## v0.8.6 (2026-10-25): the card plan, done right; the editor's info strip; team folder icons

**Copy from Cards, after review of 0.8.5.** The review found the `inFlight` set and `refine` path fragile: the
set outlived a pulled card (a card put back could adopt a stale or empty plan, or sit at "Looking…" for good
when its plan task wedged), `refine` wrote the old `plan.card` back (a name typed or synced meanwhile reverted),
a failed plan was never tried again, a refine landing late could overwrite a fresher plan, "Copy New Files from
All" could start a card whose plan was still being made, and every mount or unmount planned every card again.
There is now one path: `CardCopier.plan(_:store:previous:)` takes the card's earlier plan and reuses its
fingerprints for files unchanged since (same path, size and time), so planning again after a copy or a sync
pass is a listing of the card and one lookup; the card's record is re-read at the end so a name is current; and
the ledger and library lookups are one read for all files (keys in chunks of 500) instead of one per file.
In the model each card carries its own `Look` token: a result lands only if it is still the card's current
look, so a card pulled and put back, an eject, or Look Again can never be answered by an older look; a request
during a look sets `lookAgain` and one more look follows from the fresh fingerprints; `planning` is derived
from the token; a card keeps its plan when another card mounts or unmounts, and only a fresh look (Look Again,
another library) or a failed one plans it again. A card being looked at can't be copied, by its button or by
"Copy New Files from All".

**Editor.** The info strip (name, size, zoom, export state) floated over the bottom of the photo, covering it and
any watermark placed there. It is a row of its own under the preview now, the photo fitting above it.

**Team folder icons.** Folder-shaped symbols (`folder.badge.person.crop`, `photo.badge.checkmark`) instead of
`person.3`, which was wide enough to run into the folder's name.

## v0.8.7 (2026-10-25): folder looks at two paces; unnamed people by their picture; editor odds and ends

**Folder watching at two paces.** Network folders were polled every 5 s all night; local ones had FSEvents and a
60 s safety net. `SourceMonitor` now polls every 30 s (`slowPoll`) when nothing is happening and every 5 s
(`fastPoll`) while files are arriving: a look that found new, changed or missing files, or unsettled ones, keeps
the fast pace (`pace(busy:)`), and `LibraryService.fileLanded` tells the destination's watcher `expectFiles()`
as a card copies in. Six quiet fast looks in a row (30 s of nothing) bring the slow pace back. Local folders
poll at the same paces as their safety net.

**Unnamed people in order of their picture.** Every people list (`fetchPeople`) orders the unnamed by the
cover-order score of their picture (`BestShot.coverOrderSQL` evaluated on the cover face: facing the camera,
sharp, eyes open), in five bands, then by how often they appear. A person whose best face is turned away or
blurred was in the background and is rarely worth naming, so they sink; the people worth a name are at the top.
Named people are still by how often they appear; pinned first.

**Editor.** "Straighten tilted photos" sits above "Auto tone & enhance". A Copy Path button at the right end of
the info strip puts the photo's full path on the clipboard. Sidebar folder symbols get a fixed 20 pt column and
4 pt before the name.

**Copy from Cards layout.** The card panel's header was one row (volume name, name field, camera, capacity,
pill) that broke apart in a normal window: "Untitled" wrapped a syllable per line, the pill a word per line, the
camera truncated. Now two lines: the volume name (one line, truncating) with the name field and the pill
(`fixedSize`) on the right; under it camera · serial · capacity · free. The buttons share one width. "Cards
seen before" rows are columns (name 130 pt, field 200 pt, camera, counts right-aligned) so they line up.

**Choosing the team folder again.** Locate Team Folder… or Join with the folder the team already uses reset the
team's status (Macs, "synced") and forced a full sync pass; Join also waited for that pass before opening the
project. `TeamSync.relocate` now returns early when the canonical path is unchanged (a pass only if the folder
was unreachable), and `FaceGroupingModel.joinTeam` recognises a team already joined through that folder
(`TeamSync.member(of:)`) and just opens its project (test).

## v0.8.8 (2026-10-25): a team stuck at "Connecting…"; Copy Path says it copied

**"Connecting…" with the team folder reachable.** Sampled on the processing Mac: the team queue sat in
`publishFaces` for minutes, copying face crops and thumbnails to the share with `FileManager.copyItem`, one by
one. Over SMB each copy also sets owner, mode, flags and extended attributes, each a round trip; with a backlog
(1,846 files queued, ~96,000 face changes) one pass ran for minutes, and the team's status was only stored at
the end of a pass, so the header said "Connecting…" (no status) and every other team change waited behind it.
Now: the status is stored as soon as `team.json` is found (reachable, the Macs), before the pass's work; crops
are written as plain bytes, `cropCopyLanes` (8) at a time (`SharedFaces.copyCrops`); and a pass publishes for
at most `facePublishTimeBox` (20 s), deleting only what it handled from the queues, the rest left for the next.

**Copy Path** shows "Copied" with a checkmark for 1.5 s; both labels share one frame so the strip doesn't move.

## v0.8.9 (2026-10-25): folders a 0.8.3 Mac skipped; the Team Sync Folder; editor thumbnails from the library

**Team and edited folders missing on a teammate's Mac.** The Mac Studio's log held the three `folder` entries
(written 2026-10-24 23:16 UTC, 20 minutes after 0.8.4 was published); the MacBook Pro was syncing minutes later,
most likely still on 0.8.3, whose `apply` returns `.ignored` for kinds it doesn't know while the cursor moves
past them, so after updating it never read them again. `TeamSync.lateKinds` lists kinds added after the first
team release with a reader version (`folder` is 2); `syncState "reader"` holds the version that read the team so
far, and when it is older, `replayLateKinds` reads each log up to its cursor again, applying only those kinds
(newest-wins makes a repeat harmless). A future kind goes in the list with the next version (test).

**"Team Sync Folder".** The folder that holds `team.json`, the logs and the faces is called the Team Sync Folder
everywhere it is shown (Locate…, Show in Finder, Copy Path, the sheets, errors, docs), so it is not confused
with Team Folders (shared sources).

**Editor thumbnails.** The strip and grid called `Thumbnails.media` without a library id, so every photo was
read off the NAS and decoded at 1,500 px (`MediaAnalyzer.thumbnail` decodes at the detection size), about 0.7 s
each for a 2 MB JPEG, six at a time, again for each size and each time the editor opened. A path without an id
is now looked up (`COALESCE(duplicateOf, id)`) and the library's local thumbnail file used; files outside the
library get `MediaAnalyzer.displayThumbnail` (the embedded thumbnail when big enough, else a decode at the
shown size); a still thumbnail is cached once for every size.

## v0.8.10 (2026-10-25): the editor's spinner in the middle

The render spinner sat in the preview's top-left corner, small, and was hard to see. It is now in the middle of
the preview, regular size, on a dark disc, and takes no clicks.

## v0.8.11 (2026-10-25): edited folders skip face work; a fast Files search

- **Edited folders are never read for faces.** They hold finished work, mostly edits of photos already in the
  library, so reading them found everyone twice. Their files are listed (with thumbnails) and marked
  `media.skippedAsEdited`; they skip face detection, bursts and session counts, and are neither published to nor
  taken from the team's face records. `LibraryService.settleEditedFolders` runs at launch, after scans, on share
  changes (here or from a teammate) and every maintenance tick. A folder that becomes an edited one loses its
  files' faces: to an identical copy outside it when there is one (that copy becomes the original), else dropped
  with named people remembered (PersonMemory). A folder that stops being one is processed again. A skipped file is
  never the original of a copy elsewhere, so the copy is processed itself.
- **Files search without lag.** The list was rebuilt on the main thread for every letter, every visible icon's
  right-click menu went through every file, the folder column recounted every file per row, and comparing
  tens of thousands of accented paths (Unicode normalization) cost seconds per reload during scans. Now: the
  search applies when typing pauses and a keystroke redraws nothing; the list, its id index and per-folder counts
  are built in the background; the list is compared by build version; Quick Look's file list is made only while
  it is open. On a 16,906-file project: a keystroke 0.02 ms, a reload during a scan 0.2 s (was 0.9–2.8 s).
- **Copy a folder's path.** "Save to" rows (the editor's Output, video tools, Copy Verifier) have a copy button
  beside Choose…, with the same "Copied" check as the editor strip's Copy Path (one shared `CopyPathButton`).
- **One line under the header.** With the sessions bar, the toolbar no longer draws its own line above it.

## v0.8.12 (2026-10-25): smooth People scrolling; Regroup after a wrong merge

- **People grid scrolls smoothly.** Every tile had a real name field (an AppKit control each, slow to make), so
  scrolling made a dozen per row. Now only the tile under the mouse, the one being named and the one naming moved
  to (`fieldFor`) have one; the others draw the same look as text. Naming moves the cursor with `focusName`, which
  gives the tile its field first and asks for focus again on the next pass. On 786 people, a 5.8 s scroll took
  9.4 s with ~40 late frames; now 6.8 s with 4–5.
- **Regroup.** On a person's Faces tab, selected faces can be let go (`LibraryService.regroup` / `letGo`): each is
  placed again with whoever it looks most like, this person included, else clustered or left unassigned. Faces
  placed by hand stay, so after a wrong merge a few faces moved to each right name steer the rest. The bar also has
  Select All.

## v0.8.13 (2026-10-26): Space for a closer look; text with logos and banners; RAW in Edit & Export

- **Space peeks** (`Peek.swift`): `Peek<ID>` keeps the tile under the mouse and the last clicked one outside SwiftUI
  state (hover redraws nothing); space opens the hovered tile, else the clicked one, else the first selected.
  `PeekState` is the tile the popover hangs from plus the one shown: ← → change the shown one while the popover stays
  put (moving a popover tile to tile closes and reopens it, and quick steps lost it). `FacePeek` shows the cached
  crop at once, then `MediaAnalyzer.faceContext` (the crop's framing, pad 0.35, cut from a decode just big enough,
  ≤ 3000 px) via `Thumbnails.closeUp`. `MediaPeek` (photos: library thumbnail, then a 1600 px decode; videos: an
  AVPlayer from the person's time) has Edit and Copy Path; it replaced Quick Look in the media grids, Files (where
  stepping moves the selection) and the tools' list (which takes space only while the list has the keyboard: space
  ticks photos in Edit & Export). The popover's own window gets the keys too (`onWindowKeys` inside it).
- **AVKit linked by name** (`Package.swift`): `import AVKit` linked only `_AVKit_SwiftUI`, so a `VideoPlayer` crashed
  looking for `AVPlayerView` (the Cull window's video too).
- **Person page selection 690 ms → 16 ms**: `body` sorted every photo on each click (`ImageLoader.isRaw` making a
  URL per comparison). The grids are now `MediaLists`, worked out in `relist()` when media, sort, bursts or Top N
  change. Grid clicks use `onClick(_:double:)` (click count of the event) instead of `onTapGesture(count: 2)` beside a
  tap, which held every click for the double-click time.
- **Headers**: `screenHeader()` (toolbar background hidden) on every sidebar screen and on pushed ones (a person),
  which don't take it from the screen they were pushed from.
- **Watermarks**: the kind picker writes the spec once (field by field, each write started from the drawn spec on
  macOS 27, so only the margin stuck). `WatermarkSpec.extraText` (`TextMark`): text drawn as well as a logo or
  banner, kept while off (`off`), with its own look or a text preset's (`presetId`, `sameLook`); on the banner's
  edge its margin counts from the banner (`EditPipeline.mark(inset:)`). `font` (PostScript name, default
  HelveticaNeue-Medium) on text watermarks and `TextMark`, part of the text mark's cache key; `FontPicker` lists
  families and their styles.
- **RAW in Edit & Export**: `rawPairs` on `ToolInputView`/`FileInputList` keeps a pair's RAW (other tools keep the
  JPEG); people and library-opened photos swap to the RAW via `Selection.rawPartners` (the RAW `duplicateOf` its
  JPEG, same pair key).
- **Stuck "Processing N files"**: a changed file in an edited folder went back to pending with `skippedAsEdited`
  kept, which `settleEditedFolders` skipped and the processor refuses. The scan now clears the flag, and the settle
  pass also takes `skippedAsEdited AND status = 'pending'` (36 such files in the event library).


## v0.8.14 (2026-10-26): Retouch (skin and auto masks); Whites and Blacks

- **Body parts** (`FaceCore/BodyParts.swift`): Meta's Sapiens 0.3B body-part segmentation (Goliath's 28 parts,
  CC BY-NC) converted by `tools/convert_sapiens.py` into five soft masks (face skin, body skin, lips, clothes, hair).
  The export only took 1024 x 768 and ran 4.5 s a tile: the position embedding is resized (bicubic) to 768 x 576, and
  the decoder's transposed convolutions are rewritten as four 2 x 2 sub-pixel convolutions each, which Core ML had
  left on the CPU; now 0.48 s a tile on the GPU (the Neural Engine takes minutes to prepare it). Photos are scaled
  to at most 768 high (never enlarged) and covered with overlapping tiles; faces get a closer pass when it gives at
  least twice the detail. Eyes and brows (Vision landmarks) are cut out of face skin. Without the model, Vision's
  person mask, landmarks and skin colour stand in. Results are cached by a 16 x 16 thumbnail (last 24 photos).
- **The model is downloaded, not bundled** (`BodyPartsModel.swift`): 627 MB zipped, its own GitHub release
  `models-bodyparts-1` (never latest: the update feed is releases/latest/appcast.xml), checked against its SHA-256 and
  unpacked into Application Support/SuZu Media Utils/Models, kept across updates. The Retouch section's Download
  button, or `--download-body-parts` from a script. `scripts/publish-model.sh` uploads a new one.
- **Retouch** (`EditRecipe.retouch`, `EditPipeline.retouch`): smooth (frequency separation: fine detail kept, the
  blotchy middle band evened), brighten, whiten (less saturation, cooler, a little magenta, lighter midtones), on face
  skin and optionally body skin; per-part exposure, contrast, saturation, temperature, tint and hue, with edge
  softness (blur) and grow/shrink (morphology) of the mask. "Show mask" tints the shaped mask red on the preview.
- **Whites / Blacks**: one curve each, `0.25·w·x³` at the top and `0.2·b·(1−x)³` at the bottom, so the midtones
  barely move.


## v0.8.40 (2026-10-29): the people learn from every edit

- **The problem**: two look-alikes (celebrities, say) grouped as one person. "Not this person" and "Move to…"
  only moved the selected faces and rebuilt the two people from what was left; the other look-alike faces stayed,
  the next photo of the look-alike joined the person again, and the new group the moved faces formed could be
  merged back.
- **What the user teaches** (`GroupingEngine`): each person keeps, besides the mean and the exemplars, their
  *confirmed* faces (placed with them by hand: "Move to…", "New Person…", first in line as exemplars whatever their
  quality) and their *counter* faces (taken from them: "Not this person", or moved to someone else), both diverse
  and capped like exemplars, in two more `Rows`. A person with no face left keeps what they were taught.
- **Held off** (`heldOff`): a face is kept from a person when it resembles one of their counter faces at least
  `counterThreshold` (0.45) and more, by `counterMargin` (0.05), than it resembles the person (its mean similarity
  to them or its similarity to a confirmed face, whichever is higher). In `bestPerson` (assignment, low-quality
  matches), `nearestPeople` (Find by Photo: not "likely"), and `consolidate` (`heldApart`: a group whose mean
  looks like what the user took from the other is not merged into it; the mean against a counter face is the
  group's mean similarity to it, the same measure as the link).
- **Review** (`review`, from `corrected`): after an edit the faces the app had placed with the people the faces
  left are weighed again, each without its own weight in the person (`leaveOneOut`: mean of the others, nearest
  exemplars but itself). One held off goes to whoever takes it at the usual bars, else waits to be grouped again;
  one that fits the person the user's faces went to clearly better (margin + 0.05) goes there. Faces placed by
  hand stay. Up to four rounds, since every round sharpens both people; then waiting faces are matched again
  (`assignAllPending`) and groups consolidated.
- **Every manual change goes through `corrected`**: `reject`, `assign` (so `newPerson` too), `merge`, and
  teammates' face edits arriving in `TeamSync`. `assign` clears the rejection of a face brought back to the person
  it was taken from, and `PersonNames.merge` clears rejections that a merge turns onto the face's own person, so a
  face is never its own person's counter face.
- Numbers on the synthetic look-alike (0.64 to the person, faces 0.73 to each other, 0.47 across): the look-alike's
  faces in the mixed person score 0.57 to it and 0.73 to the counter faces, the person's own 0.60 and 0.47.
- Tests: `GroupingTests` (faces taken from a person take their look-alikes along, a new one stays away and is not
  likely, the group they form stays apart; faces moved to a name take their look-alikes along, a new one joins
  the name, through `corrected`).
