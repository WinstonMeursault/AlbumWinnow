# AlbumWinnow

English · [简体中文](README.zh-CN.md)

AlbumWinnow is a native photo organizer for macOS, iOS, and iPadOS. It finds duplicates across the system photo library and user-selected folders, recommends which copies to keep, and lets users review each group before cleanup.

## Project status

AlbumWinnow v1.1.0 adds persistent review decisions, photo locks, and explicit iCloud scan policies. It targets macOS 26, iOS 26, and iPadOS 26 or later. The app scans authorized photo libraries and folders, groups duplicates, and supports review and recoverable cleanup.

The previous formal v1.0.0 release remains available on the [GitHub Releases page](https://github.com/WinstonMeursault/AlbumWinnow/releases/tag/v1.0.0). The macOS package contains a universal Apple Silicon/Intel app with an ad hoc signature. The iOS/iPadOS IPA is unsigned and requires signing before installation.

## Build and run

Open `AlbumWinnow.xcodeproj` in Xcode. Select **AlbumWinnow** for macOS or **AlbumWinnowMobile** for an iPhone or iPad simulator. Open **Settings** to enable Photos or add a folder under **Scan Sources**, then select **Scan** on the Duplicates screen.

The shared Swift package can also be built independently with `swift build --package-path Packages/AlbumWinnowCore`.

## Tests

Run the core regression suite on macOS 26 or later with Xcode 26 or later selected.

```sh
swift test --package-path Packages/AlbumWinnowCore
```

The bundled images are generated test fixtures. Tests cover file identity, high-bit-depth images, cross-format and cross-resolution matches, localized changes, orientation, incremental scans, cancellation, cache recovery, and recoverable cleanup using temporary copies. GitHub Actions runs the suite on Apple Silicon and Intel macOS runners and builds the macOS and iOS/iPadOS targets.

The app regression suite covers review and cleanup layouts, large text, background removal checks, scan recovery, and current review interactions. It requires XcodeGen and an installed iOS Simulator. Run it against a dedicated simulator; the suite creates its own folder fixtures:

```sh
Tests/run-app-tests.sh SIMULATOR_UDID
```

Generated test projects stay under `.local`. The expected version is read from the app build settings. These tests do not use physical devices or an iCloud account.

## v1.1 review and cloud policy

Confirmed plans, kept groups, deferred groups, photo locks and the review position are stored separately from scan fingerprints. Reopening rebuilds scan results before restoring valid decisions; it never deletes photos. Temporary photo taps are not saved as deletion plans. **Skip** defers a group without cancelling an existing plan. **Group Actions** provides **Keep Entire Group** and **Undo Group Decision**. Long-press or right-click a photo to lock it. Locked photos remain alongside the selected copy; **Delete All** is unavailable for any protected group. Cleanup execution checks the same protection context, including overlapping folder paths and hard links.

Use **Continue Review** or **Review Ten Groups** in the overview. Kept groups are hidden by default and can be shown under Review Options. Changes to group membership, resource revisions or matching evidence invalidate old deletion decisions. **Reset Review Progress** clears decisions while preserving locks. Clearing the scan cache preserves all review state. If protection storage cannot be loaded or a decision cannot be saved, cleanup is disabled.

**Skip Photos Stored Only in iCloud** is enabled by default. Disabling it permits downloads during scanning. **Download Pending Photos from iCloud** authorizes only the requested photos for that scan, together with a fresh comparison against local photos. Cached fingerprints do not substitute for a current availability check. Processed, policy-skipped, failed and unfinished counts remain separate; cancelling does not turn unfinished photos into failures. Previews do not silently authorize downloads. Automated cloud validation uses controlled callbacks rather than a real account.

## v1.0 scope

- Scan accessible photos in the system library and user-selected folders, including duplicates across both sources.
- Detect exact duplicates and copies of the same image at different resolutions, compression levels, or in different formats such as HEIC, JPEG, and PNG.
- Group matches for side-by-side review and recommend a copy to keep based on image quality, resolution, and associated data such as a Live Photo video or the original version of an edited photo.
- Reuse fingerprints for unchanged assets and rebuild groups on each scan; detect changes before allowing cleanup.

Scans read locally available Photos assets and report cloud-only items under Scan Issues. Use **Download Pending Photos from iCloud** to authorize a download and retry those items. A download retry rereads the selected resources even when their fingerprints are cached. The Duplicates screen shows iCloud transfer progress separately from scan progress, with counts of available, failed, and pending photos. Partial downloads show **iCloud Download Incomplete** and prompt you to review Scan Issues. After a scan, Duplicates shows a photo gallery with one cover per group. Select a cover to inspect its copies in the group. **Show Filenames in Review** in Settings displays filenames on the review screen. Swipe left to review the next group or right to return to the previous one. Choose Slide, Cover, Fade, or None under **Settings → Interaction → Group Transition**. Tap the photo you want to keep and confirm the group, or skip it. **Delete All** previews removal of the entire group. Under **Settings → Interaction → Review Button Layout**, choose the left- or right-hand layout to put Confirm within reach. Once the groups are reviewed, choose **Confirm Cleanup** on the Duplicates screen to review and confirm the whole batch. On iOS and iPadOS, a scan interrupted by background suspension resumes in the foreground using saved sources, cached fingerprints, and the previously authorized set of pending downloads. User cancellation stops automatic resumption. Scan Issues retains the system error description, domain, and code when PhotoKit supplies them. Library changes during a scan require a fresh scan before cleanup. Broader grouping of similar shots, such as distinct frames in a burst, is planned for v1.4.

## Matching and cleanup

| Category | Criteria | Cleanup behavior |
| --- | --- | --- |
| Exact duplicate | Identical file bytes with the same effective orientation. | Shown without an additional similarity label. Cleanup requires confirmation. |
| Possible same image | Candidate hashes and multi-scale pixel checks agree across differences in resolution, compression, or encoding. | Marked for review before selecting copies to move. |
| Highly similar candidate | The coarse comparison agrees, while higher-resolution checks find local differences. | Marked **Similar photos**. Users may inspect and confirm cleanup. |

Matching and indexing run on device, and locally available photos can be scanned offline. Every cleanup operation requires explicit confirmation. Confirmed items move to Photos’ Recently Deleted album or to the filesystem Trash when available. If a file provider has no Trash, the app keeps the file and reports the failure in the current operation result. Photos assets with Live Photo video, edits, or alternate-photo resources are protected from cleanup. Folder images with same-basename MOV/MP4/M4V video, AAE/XMP sidecars, or RAW/rendered pairs are conservatively protected as well, including sidecars added after scanning. This filename-based safeguard does not identify every possible export naming convention. The completion screen shows previews and reasons for skipped or failed items in the current operation; it does not save cleanup history.

## Technical design

`AlbumWinnowCore` is a Swift package shared by the SwiftUI apps. PhotoKit and Foundation provide access to photos and files. BLAKE3 identifies matching file bytes, with streaming reads for folder resources. Bounded ImageIO thumbnails supply pHash and dHash candidates. Pixel checks at multiple resolutions distinguish possible same-image copies from candidates with local differences. Full source dimensions and bit depth are retained for recommendations. SQLite and GRDB store incremental fingerprints, recover damaged cache entries, and discard inactive-source data after the next completed scan. Swift Concurrency limits parallel image preparation. Detail and cleanup previews share a size-weighted queue with gallery thumbnails: up to four small requests, with large or unknown-size Photos previews running alone. Folder previews use safely mapped file data when supported by the provider, avoiding an additional full-file heap buffer. ImageIO limits decoded previews to 1024 pixels. **Settings → Storage → Clear Scan Cache** removes cached fingerprints and compacts the database to release disk space. Photos and source permissions are preserved; the next scan is a cold scan.

## Implementation and validation

The detection core, folder scanning, incremental cache, PhotoKit integration, SwiftUI review, recoverable cleanup, and iOS/iPadOS layouts are implemented. Candidate retrieval uses a multi-index of Hamming-distance hash bands. The current matcher uses perceptual hashes and multi-scale pixel checks; it does not use Vision feature prints.

`Tests/Performance` contains a deterministic full-resolution JPEG generator and an executable that calls the production scan engine. It checks cold scans, unchanged scans, changes to 1% of assets, and cache reuse after cancellation, including the exact membership of known duplicate pairs. Generate data in a fresh local directory:

```sh
python3 -m venv .local/performance-venv
.local/performance-venv/bin/pip install Pillow
.local/performance-venv/bin/python Tests/Performance/generate_photos.py --root .local/benchmark-10000 --count 10000
swift run --package-path Tests/Performance -c release ScanBenchmark .local/benchmark-10000 10000 .local/benchmark-10000/results.json
```

Use 50000 or 100000 for the larger runs, with a fresh directory and sufficient disk space. Each image is 4032 × 3072; 100,000 images and two fingerprint caches require approximately 50 GB. Reported RSS is the process lifetime peak. A cold scan starts with an empty application cache; filesystem caches are not flushed. These synthetic images validate scale and known exact pairs, not recognition accuracy on natural photos or end-to-end PhotoKit throughput.

Release regression tests use generated fixtures and simulators. Automated iCloud tests exercise request callbacks, cancellation races, error propagation, and library-change handling without an iCloud account. These tests do not establish accuracy across natural photo libraries or performance across all devices, accounts, and network conditions.

## License

The public source code is available under the GNU Affero General Public License, version 3. See [LICENSE](LICENSE) and the [third-party notices](THIRD-PARTY-NOTICES.txt).

The [privacy policy](PRIVACY.md) describes photo access, iCloud downloads, and the data the app stores on the device.
