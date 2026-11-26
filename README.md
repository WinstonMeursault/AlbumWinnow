# AlbumWinnow

English · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

AlbumWinnow is a native photo organizer for macOS, iOS, and iPadOS. It finds duplicates across the system photo library and user-selected folders, recommends which copies to keep, and lets users review each group before cleanup.

[Release notes](CHANGELOG.md)

## Architecture and platforms

AlbumWinnow v2.0.1 uses Rust Core with Swift/SwiftUI for its native Apple applications. English, Simplified Chinese and Japanese are supported on macOS 26, iOS 26 and iPadOS 26 or later. The repository also includes Kotlin bindings and a minimal Android validation host; this version does not include a complete Android client or Windows/Linux applications.

v2 starts with separate source/asset identities, review/cache databases, signatures and preferences. After upgrading, configure sources and protection again and rescan. v1 data is neither migrated nor automatically deleted, and its deletion candidates are not restored. The existing application bundle identifier is retained.

On an ordinary relaunch, start a scan manually to restore confirmed v2 plans that still match the current resources. Relaunching does not start a scan or delete photos automatically. Background-interrupted scans can resume with their saved consent; explicitly cancelling a scan stops automatic recovery.

Download release artifacts from [GitHub Releases](https://github.com/WinstonMeursault/AlbumWinnow/releases). The macOS package contains a universal Apple Silicon/Intel app with an ad hoc signature. The iOS/iPadOS IPA is unsigned and requires signing before installation.

## Build and run

Install the pinned Rust toolchain with rustup and select a full Xcode installation. Prepare the native library before resolving Swift packages or opening the project:

```sh
Tools/Core/build-apple.sh debug
```

Then open `AlbumWinnow.xcodeproj` in Xcode. Select **AlbumWinnow** for macOS or **AlbumWinnowMobile** for an iPhone or iPad simulator. Open **Settings** to enable Photos or add a folder under **Scan Sources**, then select **Scan** on the Duplicates screen.

After native preparation, build the Swift platform package independently with `swift build --package-path Packages/AlbumWinnowApple`. See [Core build instructions](Tools/Core/README.md) for Apple slices, generated bindings and Android smoke validation.

## Tests

Run the core regression suite on macOS 26 or later with Swift 6 and Xcode selected, after native preparation. During development, select only checks affected by a change; run the complete matrix and clean builds at candidate delivery.

```sh
cargo test --workspace --locked
swift test --package-path Packages/AlbumWinnowRust
swift test --package-path Packages/AlbumWinnowApple
```

The bundled images are generated test fixtures. Tests cover file identity, high-bit-depth images, cross-format and cross-resolution matches, localized changes, orientation, incremental scans, cancellation, cache recovery, and recoverable cleanup using temporary copies. GitHub Actions runs the suite on Apple Silicon and Intel macOS runners and builds the macOS and iOS/iPadOS targets.

The app regression suite covers review and cleanup layouts, large text, background removal checks, scan recovery, and current review interactions. It requires XcodeGen and an installed iOS Simulator. Run it against a dedicated simulator; the suite creates its own folder fixtures:

```sh
Tests/run-app-tests.sh SIMULATOR_UDID
```

Generated test projects stay under `.local`. The expected version is read from the app build settings. These tests do not use physical devices or an iCloud account. The optional Photos album-scope test requires `TEST_RUNNER_ALBUMWINNOW_PHOTOS_FIXTURE=1` on a dedicated simulator; it requests simulated Photos access and leaves generated photo/album fixtures there. Default regressions skip that test.

## Reliability and release tooling

Unavailable folder records survive relaunch. Settings offers retry, reselect and explicit removal; these actions preserve existing locks and read-only policies. Saved Protection lists individual lock records, including paths outside current results. Unlocking an inherited file lock requires confirmation of the affected paths. Removing protection never reinstates cancelled cleanup candidates. Invalidated decisions can be explicitly removed without clearing valid choices or protection.

Unavailable or corrupt v2 protection disables cleanup. Rust stores review decisions, source policies and navigation transactionally in its v2 database; navigation uses an independent sequence. Resetting review progress retains v2 locks and source protection. v1 databases and signatures are not opened or migrated.

Run native macOS regressions with `Tests/run-macos-tests.sh`. Simulator regressions support standard iPhone and iPad. Packaging and atomic IPAes upload/download verification are versioned under [Tools/Release](Tools/Release/README.md). A release build does not imply a notarized macOS app or a signed IPA.

## languages

The app follows system language preferences and the operating system’s per-app language setting. Choose English, Simplified Chinese or Japanese, then restart the app. Unsupported languages fall back to English. Changing language preserves manual keep choices, locks, scope and pending cleanup; reopening never deletes photos automatically.

**Selected** identifies your chosen keeper; **Recommended** is an algorithm suggestion; **Locked** requires retaining a protected photo. Confirmed removal candidates are separately labeled **pending cleanup**. User filenames and album titles retain their original text. Official license documents and explicitly marked original diagnostics may remain in their original language.

Translations live in a platform-neutral message table and are exported to native Apple catalogs. See [Localization](Localization/README.md) for editing and validation. This prepares the wording workflow for a future Android app; Android support is not included.

## difference previews

Open **Review Evidence → Show Differences**, explicitly choose a reference and comparison, then select **Show Differences**. The original previews remain available through **Original / Differences**, with adjustable highlight opacity. Reference photos are comparison inputs and do not change your selected keeper, recommendation, duplicate category or cleanup plan.

The comparison uses fresh, orientation-corrected previews up to 512 pixels and compensates for compression, resizing and global color balance before marking approximate local changes. It supports stable framing and matching proportions. Crops, changed viewpoints, insufficient detail or inconsistent alignment produce **Cannot reliably show differences**. Small details can be missed; return to the group for synchronized zoom. An empty overlay is not proof that two originals are identical.

Changing the pair, leaving the view or backgrounding clears the temporary result. Returning requires an explicit comparison. Photos previews never authorize iCloud downloads. Source revisions and active scope are checked again; a changed or inaccessible resource blocks stale cleanup until rescan. Generated calibration covers compression, size, color, orientation, local digit and expression-shape changes; it does not establish natural-photo or real-expression accuracy.

## burst and similar scenes

Enable **Find Burst and Similar Scenes** in Settings, or choose **Similar Photos → Scan Similar Photos** after a scan. Analysis is off by default. **Duplicates** retains the existing duplicate matcher; stronger duplicate groups take priority over the separate **Similar Photos** queue. Confirmed cleanup candidates remain global across both queues. Valid manual choices survive analysis being disabled, cache clearing and reopening, but must be revalidated against current resources before cleanup.

Vision feature distances supply similarity evidence, not a confidence percentage or proof of identical content. Real burst identifiers and known capture dates help retrieve candidates; dates alone never establish a match. Retrieval is capped at 64 candidates per photo. Groups require every member to agree with every other member and have at most 24 photos, so similarity chains and large scenes can split. Low-texture scenes may be omitted. Feature caches are isolated by algorithm configuration, operating system and architecture.

Measured thumbnail focus and exposure signals may suggest a keeper only when the measured advantage is clear; otherwise there is no recommendation. These signals do not judge expressions, artistic blur or aesthetic merit. This release has not been evaluated against an annotated natural-photo benchmark; natural precision and recall are unmeasured. Review all differences manually. Cleanup rereads the actual retained/removal pair, rechecks scene similarity and applies the existing resource, lock and source protections. Active Photos album membership, album identity and date bounds are checked again before deletion.

## sources and scope

**Settings → Comparison Scope** selects all accessible Photos or an album union, intersected with an optional capture-date range. Civil days use the current calendar and time zone when applied; exact bounds survive recovery. Unknown capture dates are excluded unless explicitly included. Missing, renamed or inaccessible albums require scope review and never expand the scan to the whole library. Limited Photos permission cannot enumerate user albums.

**Compare Two Sides Only** scans the two selected sources and records only cross-source matches. Same-side members are not assumed identical through a shared neighbor. A manual keep choice can leave extra members retained when no verified match supports their removal. **Confirm Cleanup** shows the actual retained photos and removal pairs.

**Source Policy** can prefer Photos or another source only when the existing quality-ranking signals tie. Recommendation changes preserve valid manual choices. Read-only sources participate in comparison but are protected at deletion, including overlapping folder paths and known hardlink identities. Enabling protection cancels affected pending removals immediately; disabling it does not reinstate them. Source protection survives scan-cache clearing, source removal and review-progress resets. If a protected folder is inaccessible, cleanup fails closed. Folder hardlinks can be retained conservatively while any folder is read-only.

## review tools

Open **Review Evidence** in a group for measured recommendation reasons, each member’s actual match to the reference, and source metadata. Unknown sizes, capture dates and bit depths remain unknown. Size estimates describe candidate resources, not immediately released device space.

Double-tap or double-click to zoom, pinch to adjust, and drag to pan while zoomed. **Group Actions** offers **Zoom In**, **Reset Zoom** and independent zoom. Synchronization uses relative image position, not pixel alignment across crops. Visible photos request bounded detail previews up to 2560 pixels; available pixels limit enlargement. Reset, navigation and backgrounding release detail images. Previews never silently authorize iCloud downloads.

**Filter and Sort** supports review status, match category and source, plus stable, capture-date, count and candidate-size ordering. Unknown dates stay last in both directions. Filters preserve confirmed choices; **Confirm Cleanup** includes candidates outside the filter. Entering a group freezes the review queue. Cancelling a supplemental scan preserves saved choices for review but requires a manual rescan before cleanup; reopening does not restart a user-cancelled scan.

## review and cloud policy

Confirmed plans, kept groups, deferred groups, photo locks and the review position are stored separately from scan fingerprints. After reopening, a manual scan rebuilds results before restoring valid decisions; it never deletes photos automatically. Temporary photo taps are not saved as deletion plans. **Skip** defers a group without cancelling an existing plan. **Group Actions** provides **Keep Entire Group** and **Undo Group Decision**. Long-press or right-click a photo to lock it. Locked photos remain alongside the selected copy; **Delete All** is unavailable for any protected group. Cleanup execution checks the same protection context, including overlapping folder paths and hard links.

Use **Continue Review** or **Review Ten Groups** in the overview. Kept groups are hidden by default and can be shown under Review Options. Changes to group membership, resource revisions or matching evidence invalidate old deletion decisions. **Reset Review Progress** clears decisions while preserving locks. Clearing the scan cache preserves all review state. If protection storage cannot be loaded or a decision cannot be saved, cleanup is disabled.

**Skip Photos Stored Only in iCloud** is enabled by default. Disabling it permits downloads during scanning. **Download Pending Photos from iCloud** authorizes only the requested photos for that scan, together with a fresh comparison against local photos. Cached fingerprints do not substitute for a current availability check. Processed, policy-skipped, failed and unfinished counts remain separate; cancelling does not turn unfinished photos into failures. Previews do not silently authorize downloads. Automated cloud validation uses controlled callbacks rather than a real account.

## scope

- Scan accessible photos in the system library and user-selected folders, including duplicates across both sources.
- Detect exact duplicates and copies of the same image at different resolutions, compression levels, or in different formats such as HEIC, JPEG, and PNG.
- Group matches for side-by-side review and recommend a copy to keep based on image quality, resolution, and associated data such as a Live Photo video or the original version of an edited photo.
- Reuse fingerprints for unchanged assets and rebuild groups on each scan; detect changes before allowing cleanup.

Scans read locally available Photos assets and report cloud-only items under Scan Issues. Use **Download Pending Photos from iCloud** to authorize a download and retry those items. A download retry rereads the selected resources even when their fingerprints are cached. The Duplicates screen shows iCloud transfer progress separately from scan progress, with counts of available, failed, and pending photos. Partial downloads show **iCloud Download Incomplete** and prompt you to review Scan Issues. After a scan, Duplicates shows a photo gallery with one cover per group. Select a cover to inspect its copies in the group. **Show Filenames in Review** in Settings displays filenames on the review screen. Swipe left to review the next group or right to return to the previous one. Choose Slide, Cover, Fade, or None under **Settings → Interaction → Group Transition**. Tap the photo you want to keep and confirm the group, or skip it. **Delete All** previews removal of the entire group. Under **Settings → Interaction → Review Button Layout**, choose the left- or right-hand layout to put Confirm within reach. Once the groups are reviewed, choose **Confirm Cleanup** on the Duplicates screen to review and confirm the whole batch. On iOS and iPadOS, a scan interrupted by background suspension resumes in the foreground using saved sources, cached fingerprints, and the previously authorized set of pending downloads. User cancellation stops automatic resumption. Scan Issues retains the system error description, domain, and code when PhotoKit supplies them. Library changes during a scan require a fresh scan before cleanup.

## Matching and cleanup

| Category | Criteria | Cleanup behavior |
| --- | --- | --- |
| Exact duplicate | Identical file bytes with the same effective orientation. | Shown without an additional similarity label. Cleanup requires confirmation. |
| Possible same image | Candidate hashes and multi-scale pixel checks agree across differences in resolution, compression, or encoding. | Marked for review before selecting copies to move. |
| Highly similar candidate | The coarse comparison agrees, while higher-resolution checks find local differences. | Marked **Similar photos**. Users may inspect and confirm cleanup. |

Matching and indexing run on device, and locally available photos can be scanned offline. Every cleanup operation requires explicit confirmation. Confirmed items move to Photos’ Recently Deleted album or to the filesystem Trash when available. If a file provider has no Trash, the app keeps the file and reports the failure in the current operation result. Photos assets with Live Photo video, edits, or alternate-photo resources are protected from cleanup. Folder images with same-basename MOV/MP4/M4V video, AAE/XMP sidecars, or RAW/rendered pairs are conservatively protected as well, including sidecars added after scanning. This filename-based safeguard does not identify every possible export naming convention. The completion screen shows previews and reasons for skipped or failed items in the current operation; it does not save cleanup history.

## Technical design

Rust owns fingerprints and byte identity, classification, duplicate and scene grouping, recommendations, review state, source/alias protection, SQLite storage and transient cleanup authorization. UniFFI supplies the Swift and Kotlin bindings. `AlbumWinnowApple` retains PhotoKit/Foundation access, ImageIO/Core Image decoding, Vision measurements, bookmarks and native recoverable operations. SwiftUI displays bounded core summaries and loads individual details as needed. Native callbacks retain source authorization across suspension; only a current core ticket can authorize an OS recovery operation. BLAKE3, perceptual hashes, multiscale pixel checks and the existing scene rules are preserved. Swift Concurrency limits parallel image preparation. Detail and cleanup previews share a size-weighted queue with gallery thumbnails: up to four small requests, with large or unknown-size Photos previews running alone. Folder previews use safely mapped file data when supported by the provider, avoiding an additional full-file heap buffer. ImageIO limits ordinary decoded previews to 1024 pixels and visible zoom details to 2560 pixels. **Settings → Storage → Clear Scan Cache** removes cached fingerprints and compacts the database to release disk space. Photos and source permissions are preserved; the next scan is a cold scan.

## Implementation and validation

The production Apple flow is connected to Rust. Candidate retrieval uses a multi-index of Hamming-distance hash bands; duplicate classification uses perceptual hashes and multiscale pixel checks, while optional scene grouping uses native Vision measurements. [Migration coverage](Tools/Core/TEST-COVERAGE.md) maps preserved assertions to their v2 locations.

`Tests/Performance` contains a deterministic full-resolution JPEG generator and an executable that calls the production scan engine. It checks cold scans, unchanged scans, changes to 1% of assets, and cache reuse after cancellation, including the exact membership of known duplicate pairs. Generate data in a fresh local directory:

```sh
python3 -m venv .local/performance-venv
.local/performance-venv/bin/pip install Pillow
.local/performance-venv/bin/python Tests/Performance/generate_photos.py --root .local/benchmark-10000 --count 10000
swift run --package-path Tests/Performance -c release ScanBenchmark .local/benchmark-10000 10000 .local/benchmark-10000/results.json
```

Start with a small set and 10,000 images. Use 50,000 or 100,000 only to investigate an observed scale issue, with a fresh directory and sufficient disk space. Each image is 4032 × 3072; 100,000 images and two fingerprint caches require approximately 50 GB. Reported RSS is the process lifetime peak. A cold scan starts with an empty application cache; filesystem caches are not flushed. These synthetic images validate scale and known exact pairs, not recognition accuracy on natural photos or end-to-end PhotoKit throughput.

Release regression tests use generated fixtures and simulators. Automated iCloud tests exercise request callbacks, cancellation races, error propagation, and library-change handling without an iCloud account. These tests do not establish accuracy across natural photo libraries or performance across all devices, accounts, and network conditions.

## License

The public source code is available under the GNU Affero General Public License, version 3. See [LICENSE](LICENSE) and the [third-party notices](THIRD-PARTY-NOTICES.txt). Regenerate/check the locked Rust dependency notices with `python3 Tools/Core/notices.py` / `python3 Tools/Core/notices.py --check`.

The [privacy policy](PRIVACY.md) describes photo access, iCloud downloads, and the data the app stores on the device.
