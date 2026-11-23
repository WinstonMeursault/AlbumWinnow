# Release tools

Run from a clean repository checkout at the exact intended release commit. These tools require the existing macOS toolchain, `ditto`, `codesign`, SSH/SCP and Python 3. They do not build remotely, create a GitHub Release, merge branches or grant publication permission.

Build locally with Xcode, using separate derived-data directories under `.local`:

```sh
xcodebuild -project AlbumWinnow.xcodeproj -scheme AlbumWinnow -configuration Release -derivedDataPath .local/release-mac ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AlbumWinnow.xcodeproj -scheme AlbumWinnowMobile -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .local/release-ios CODE_SIGNING_ALLOWED=NO build
python3 Tools/Release/package.py 1.7.0 .local/release-mac .local/release-ios
```

The package tool verifies matching versions, minimum iOS 26, device-platform input, no iOS signature and both macOS architectures. It copies the `.app`, applies a temporary ad hoc signature with the existing entitlements, verifies that signature, and creates the macOS ZIP and unsigned IPA. `.local/App/vVERSION` includes source commit/tree, toolchain, explicit signing status and SHA-256 manifests. It refuses an existing release directory. If interrupted, inspect and remove only the incomplete newly generated output before retrying; never delete historical releases to bypass this check. Build products must come from this exact clean source checkout; the tool cannot infer provenance from arbitrary supplied binaries.

Write the release notes in `.local/docs/vVERSION-release-notes.md`. Once publication is authorized, supply the deployment configuration explicitly:

```sh
python3 Tools/Release/publish_ipaes.py 1.7.0 --host SSH_ALIAS --upload-directory /absolute/host/ipa-directory --repository-url https://repository.example/
```

The existing server must run the `ipaes` container, with `/data/ipa` mapped to that host directory and the existing scanner/description modules. This is the established IPAes integration, not a server installer. The tool checks the local manifest, uploads a hidden temporary file, checks its server-side hash, and renames under the scanner lock. A differing existing release is never overwritten. It updates descriptions and scans, then verifies the public versions array, latest version, minimum OS, size, icon PNG header/dimensions and actual downloaded IPA hash. Verification evidence is saved beside the local artifacts. A failed public check is a failed release verification even when upload succeeded; rerun with the identical package to verify/reconcile rather than publishing different bytes under the same version.

Server retention remains the server's existing policy. The tools do not manually delete historical official artifacts. Temporary signatures and unsigned IPAs require appropriate signing for distribution/installation; the macOS artifact is not notarized.

```sh
python3 -m unittest discover -s Tests/Release
```
