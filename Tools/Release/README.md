# Release tools

Run from a clean repository checkout at the exact intended release commit. These tools require the existing macOS toolchain, `ditto`, `codesign`, SSH/SCP and Python 3. They do not build remotely, create a GitHub Release, merge branches or grant publication permission.

## Version and source commit

Update the shared Cargo workspace version and its two lockfile entries, both
Apple marketing versions and build numbers, the Swift/Kotlin runtime version
assertions, current documentation and `CHANGELOG.md` together. App versions are
independent of database, signature, fingerprint and decoding-pipeline versions;
a patch release does not change those formats by itself.

Commit on `dev`, merge the intended source into `main` and verify that their
source trees match. Build and validate the exact release commit before creating
an annotated `v2.0.1` tag on it. Push the release branches and tag only when
publication is authorized. Do not invent a tag for an unpublished intermediate
version, move a published tag, or relabel old binaries as a new version.

## Build and package

Build locally with Xcode, using separate derived-data directories under `.local`:

```sh
Tools/Core/build-apple.sh release
Tools/Core/generate-bindings.sh --check
python3 Tools/Core/notices.py --check
xcodebuild -project AlbumWinnow.xcodeproj -scheme AlbumWinnow -configuration Release -derivedDataPath .local/release-mac ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AlbumWinnow.xcodeproj -scheme AlbumWinnowMobile -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .local/release-ios CODE_SIGNING_ALLOWED=NO build
python3 Tools/Release/package.py 2.0.1 .local/release-mac .local/release-ios
```

The package tool verifies matching versions, minimum iOS 26, device-platform input, no iOS signature and both macOS architectures. It copies the `.app`, applies a temporary ad hoc signature with the existing entitlements, verifies that signature, and creates the macOS ZIP and unsigned IPA. `.local/App/vVERSION` includes source commit/tree, toolchain, explicit signing status and SHA-256 manifests. It refuses an existing release directory. If interrupted, inspect and remove only the incomplete newly generated output before retrying; never delete historical releases to bypass this check. Build products must come from this exact clean source checkout; the tool cannot infer provenance from arbitrary supplied binaries.

Keep the published change summary in `CHANGELOG.md` and copy the version-specific
release body to `.local/docs/vVERSION-release-notes.md`. Preserve the upgrade
notice, signing status and verification limits in both channels.

## GitHub Release

Once the intended commit and required checks are verified, create an annotated
tag on that commit and push it without replacing any existing tag. Create the
GitHub Release from that tag, with the version-specific notes, macOS ZIP,
unsigned IPA and SHA-256 manifest. The optional Android smoke archive contains
the AAR, generated Kotlin binding, instrumentation APK and license resources;
it must be labeled as validation components rather than an Android photo client.
Verify the release tag's commit and download the uploaded assets to compare
their SHA-256 values against the local files.

## IPAes

Publication uses the existing deployment and requires authorization to connect
to its configured SSH host. Supply the deployment configuration explicitly:

```sh
python3 Tools/Release/publish_ipaes.py 2.0.1 --host SSH_ALIAS --upload-directory /absolute/host/ipa-directory --repository-url https://repository.example/
```

The existing server must run the `ipaes` container, with `/data/ipa` mapped to that host directory and the existing scanner/description modules. This is the established IPAes integration, not a server installer. The tool checks the local manifest, uploads a hidden temporary file, checks its server-side hash, and renames under the scanner lock. A differing existing release is never overwritten. It updates descriptions and scans, then verifies the public versions array, latest version, minimum OS, size, icon PNG header/dimensions and actual downloaded IPA hash. Verification evidence is saved beside the local artifacts. A failed public check is a failed release verification even when upload succeeded; rerun with the identical package to verify/reconcile rather than publishing different bytes under the same version.

Server retention remains the server's existing policy. The tools do not manually delete historical official artifacts. Temporary signatures and unsigned IPAs require appropriate signing for distribution/installation; the macOS artifact is not notarized.

## Release tooling checks

```sh
python3 -m unittest discover -s Tests/Release
```
