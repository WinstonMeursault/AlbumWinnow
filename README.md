# AlbumWinnow

English · [简体中文](README.zh-CN.md)

AlbumWinnow is a native photo organizer for macOS, iOS, and iPadOS. It is designed to find duplicates across the system photo library and user-selected folders, recommend which copies to keep, and let users review each group before cleanup.

## Project status

AlbumWinnow is in development for v1.0. Development builds target macOS 26, iOS 26, and iPadOS 26 or later. The app scans authorized photo libraries and folders, groups duplicates, and supports review and recoverable cleanup.

## Build and run

Open `AlbumWinnow.xcodeproj` in Xcode. Select **AlbumWinnow** for macOS or **AlbumWinnowMobile** for an iPhone or iPad simulator. Open **Settings** to enable Photos or add a folder under **Scan Sources**, then select **Scan** on the Duplicates screen.

The shared Swift package can also be built independently with `swift build --package-path Packages/AlbumWinnowCore`.

## v1.0 scope

- Scan accessible photos in the system library and user-selected folders, including duplicates across both sources.
- Detect exact duplicates and copies of the same image at different resolutions, compression levels, or in different formats such as HEIC, JPEG, and PNG.
- Group matches for side-by-side review and recommend a copy to keep based on image quality, resolution, and associated data such as a Live Photo video or the original version of an edited photo.
- Reuse scan results for unchanged assets and update the index when photos are added, edited, or removed.

Scans read locally available Photos assets and report cloud-only items under Scan Issues. Use **Download Pending Photos from iCloud** to authorize a download and retry those items. The Duplicates screen shows iCloud transfer progress separately from scan progress, with counts of available, failed, and pending photos. After a scan, Duplicates shows a photo gallery with one cover per group. Select a cover to inspect its copies in the group. **Show Filenames in Review** in Settings displays filenames on the review screen. Mark unwanted copies across groups, then choose **Confirm Cleanup** on the Duplicates screen to confirm the whole batch. Cleanup History shows the result for each item. On iOS and iPadOS, an interrupted scan resumes in the foreground using the saved sources and cached fingerprints. Grouping visually similar shots, such as distinct frames in a burst, is planned for v1.1.

## Matching and cleanup

| Category | Criteria | Cleanup behavior |
| --- | --- | --- |
| Exact duplicate | Identical file bytes or verified pixel equality. | Eligible for cleanup after review. |
| Possible same image | Pixel comparison suggests the same image across differences in resolution, compression, or encoding. | Compare the details before selecting copies to move. |
| Similar photo | A separate shot with a change in expression, motion, or composition. | Organization suggestions only. Planned for v1.1. |

Matching and indexing run on device, and locally available photos can be scanned offline. Every cleanup operation requires explicit confirmation. Confirmed items move to Photos’ Recently Deleted album or to the filesystem Trash when available. If a file provider has no Trash, the app keeps the file and records the failure.

## Technical design

`AlbumWinnowCore` is planned as a Swift package shared by the SwiftUI apps. PhotoKit and Foundation provide access to photos and files. BLAKE3 screens for identical files, and pHash and dHash retrieve visual candidates for a separate verification step using Vision feature prints and pixel comparisons. SQLite and GRDB persist fingerprints and scan state, while Swift Concurrency limits the number of images decoded at once.

## Development roadmap

1. Build a duplicate detection prototype and test it with labeled image pairs. The first acceptance test pairs a 4032 × 3024 image with a 1280 × 960 copy in a different format and checks that both are grouped as the same image. Distinct frames from a burst must stay out of duplicate cleanup results.
2. Build the macOS folder scanner, candidate index, and incremental cache.
3. Integrate PhotoKit, track library changes, and handle Live Photos and iCloud assets.
4. Build the macOS review and cleanup workflow in SwiftUI.
5. Adapt the app to iOS and iPadOS permissions, background execution limits, and layouts.
6. Measure scan time, peak memory use, and matching accuracy with 10,000, 50,000, and 100,000 photos. Verify cleanup on both sources before release.

The design target is 100,000 photos per scan. Performance validation is planned for the final milestone.

## License

GNU Affero General Public License, version 3. See [LICENSE](LICENSE).
