# AlbumWinnow

English · [简体中文](README.zh-CN.md)

AlbumWinnow is a native photo organizer for macOS, iOS, and iPadOS. It is designed to find duplicates across the system photo library and user-selected folders, recommend which copies to keep, and let users review each group before cleanup.

## Project status

AlbumWinnow is in development for v1.0. Development builds target macOS 26, iOS 26, and iPadOS 26 or later. The app scans authorized photo libraries and folders, groups duplicates, and supports review and recoverable cleanup.

## Build and run

Open `AlbumWinnow.xcodeproj` in Xcode. Select **AlbumWinnow** for macOS or **AlbumWinnowMobile** for an iPhone or iPad simulator. Open **Settings** to enable Photos or add a folder under **Scan Sources**, then select **Scan** on the Duplicates screen.

The shared Swift package can also be built independently with `swift build --package-path Packages/AlbumWinnowCore`.

## Tests

Run the core regression suite on macOS 26 or later with Xcode 26 or later selected.

```sh
swift test --package-path Packages/AlbumWinnowCore
```

The bundled images are generated test fixtures. Tests cover file identity, high-bit-depth images, cross-format and cross-resolution matches, localized changes, orientation, incremental scans, cancellation, cache recovery, and recoverable cleanup using temporary copies. GitHub Actions runs the suite on Apple Silicon and Intel macOS runners and builds the macOS and iOS/iPadOS targets.

## v1.0 scope

- Scan accessible photos in the system library and user-selected folders, including duplicates across both sources.
- Detect exact duplicates and copies of the same image at different resolutions, compression levels, or in different formats such as HEIC, JPEG, and PNG.
- Group matches for side-by-side review and recommend a copy to keep based on image quality, resolution, and associated data such as a Live Photo video or the original version of an edited photo.
- Reuse scan results for unchanged assets and update the index when photos are added, edited, or removed.

Scans read locally available Photos assets and report cloud-only items under Scan Issues. Use **Download Pending Photos from iCloud** to authorize a download and retry those items. The Duplicates screen shows iCloud transfer progress separately from scan progress, with counts of available, failed, and pending photos. After a scan, Duplicates shows a photo gallery with one cover per group. Select a cover to inspect its copies in the group. **Show Filenames in Review** in Settings displays filenames on the review screen. Swipe left to review the next group or right to return to the previous one. Choose Slide, Cover, Fade, or None under **Settings → Interaction → Group Transition**. Tap the photo you want to keep and confirm the group, or skip it. **Delete All** previews removal of the entire group. Under **Settings → Interaction → Review Button Layout**, choose the left- or right-hand layout to put Confirm within reach. Once the groups are reviewed, choose **Confirm Cleanup** on the Duplicates screen to review and confirm the whole batch. On iOS and iPadOS, an interrupted scan resumes in the foreground using the saved sources and cached fingerprints. Broader grouping of similar shots, such as distinct frames in a burst, is planned for v1.1.

## Matching and cleanup

| Category | Criteria | Cleanup behavior |
| --- | --- | --- |
| Exact duplicate | Identical file bytes with the same effective orientation. | Shown without an additional similarity label. Cleanup requires confirmation. |
| Possible same image | Candidate hashes and multi-scale pixel checks agree across differences in resolution, compression, or encoding. | Marked for review before selecting copies to move. |
| Highly similar candidate | The coarse comparison agrees, while higher-resolution checks find local differences. | Marked **Similar photos**. Users may inspect and confirm cleanup. |

Matching and indexing run on device, and locally available photos can be scanned offline. Every cleanup operation requires explicit confirmation. Confirmed items move to Photos’ Recently Deleted album or to the filesystem Trash when available. If a file provider has no Trash, the app keeps the file and reports the failure in the current operation result.

## Technical design

`AlbumWinnowCore` is a Swift package shared by the SwiftUI apps. PhotoKit and Foundation provide access to photos and files. BLAKE3 identifies matching file bytes, with streaming reads for folder resources. Bounded ImageIO thumbnails supply pHash and dHash candidates. Pixel checks at multiple resolutions distinguish possible same-image copies from candidates with local differences. Full source dimensions and bit depth are retained for recommendations. SQLite and GRDB store fingerprints and scan state, recover damaged cache entries, and discard inactive-source data after the next completed scan. Swift Concurrency limits parallel image preparation.

## Development roadmap

1. Build a duplicate detection prototype and test it with labeled image pairs. The first acceptance test pairs a 4032 × 3024 image with a 1280 × 960 copy in a different format and checks that both are grouped as the same image. Distinct frames from a burst must stay out of duplicate cleanup results.
2. Build the macOS folder scanner, candidate index, and incremental cache.
3. Integrate PhotoKit, track library changes, and handle Live Photos and iCloud assets.
4. Build the macOS review and cleanup workflow in SwiftUI.
5. Adapt the app to iOS and iPadOS permissions, background execution limits, and layouts.
6. Measure scan time, peak memory use, and matching accuracy with 10,000, 50,000, and 100,000 photos. Verify cleanup on both sources before release.

The design target is 100,000 photos per scan. Performance validation is planned for the final milestone.

## License

The public source code is available under the GNU Affero General Public License, version 3. See [LICENSE](LICENSE) and the [third-party notices](THIRD-PARTY-NOTICES.txt).

The [privacy policy](PRIVACY.md) describes photo access, iCloud downloads, and the data the app stores on the device.
