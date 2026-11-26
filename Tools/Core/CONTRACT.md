# v2 core input contract

Contract version 1. App version 2.0.0, FFI contract, data schema, fingerprint,
decision signature and decoding pipeline versions are independent.

IDs are opaque `(source_id, item_id)` strings. The core never parses an item ID
as a path. Hosts allocate persistent v2 source IDs, deduplicate directory
registrations using native identity and keep display paths separate. Revision
strings and namespaced native identity bytes retain full native precision,
including nanoseconds. Access/revision checks belong before and after reads.
Dates are optional finite Unix seconds; unknown is `None`, not zero. The host
interprets calendar/time zone selections into half-open `[start,end)` bounds.

`NormalizedPixels` / `PixelInput` contains width, height, byte stride, RGBA bytes
and a nonempty decoding pipeline identifier. Its **fixed** interpretation is
RGBA8, sRGB, premultiplied alpha, top row first, effective orientation already
applied. Row padding is allowed and excluded from image calculations. There is
no implicit Android BGRA/ARGB reinterpretation. No compressed image decoder or
platform object is stored in Rust. Different native decoders are compared
separately; identical normalized bytes must produce identical business results.

Decoded buffers are limited to 2048 per side and 16 MiB, and byte length must
match stride × height exactly with checked wide arithmetic. Fingerprinting
requires the existing 128 × 128 comparison grid and computes the same 32 × 32
pHash/edge grid, 9 × 8 dHash grid and rounded per-channel means as v1. Source
metadata retains original oriented dimensions, bit depth and wide-color fact,
with the existing 150,000,000 source-pixel ceiling. No full-resolution library
pixel collection is accepted.

Apple decoding retains ImageIO/CoreImage thumbnail generation (256 for initial
fingerprinting, up to 2048 for verification) and existing sRGB CoreGraphics
rendering. The decoding pipeline identifier must change if orientation, color,
alpha or resampling changes. Preview and Vision payloads retain separate limits
and provider namespaces; Apple Vision archives are opaque, never portable model
vectors.

Raw image bytes are fed in chunks to Rust BLAKE3. A chunk is bounded to 4 MiB
(the Apple reader uses 1 MiB). Digest snapshots do not consume the streaming
hasher; cancellation makes further updates and snapshots fail. Cancellation has
an independent atomic entry point and does not wait on the hasher lock. Hash and
pixel loops check it between bounded chunks/rows. A core failure is not a
negative match and cannot authorize cleanup.

Errors cross the bridge as stable codes. The host must attach the actual failing
asset and any native domain/code/detail when mapping read errors. Core code does
not produce localized user-facing sentences. Invalid dimensions/strides/lengths
and nonfinite dates return typed errors rather than panicking.
Known native cleanup failures retain their typed reason in the Apple receipt,
including failed preflight, so the UI can localize them without parsing diagnostic
strings. Unknown system errors retain their original detail. This presentation
metadata does not change core authorization or failed/skipped classification.

The shared reference corpus in `Tests/CoreFixtures` records v1 commit and
original Apple-produced normalized buffers. Integer hashes, means and categories
must match exactly; continuous edge metrics use absolute tolerance `1e-10`.
No tolerance permits a category/edge/protection decision to flip.

The v2 scan cache uses SQLite application ID `0x41574332`, schema 1. It stores
Rust-encoded fingerprint metadata and bounded raw LZ4 blocks. A comparison sample
always decodes into a preallocated 65,536-byte buffer; compressed input is limited
to 66,048 bytes. Cache integrity covers metadata and sample; scene integrity also
binds the resource/revision and complete provider namespace. Native archives stay
opaque and limited to 16,384 bytes. Only a successful full scan prunes entries.
Malformed cache records are discarded; corrupt dedicated cache databases are
quarantined before reconstruction. Foreign/unknown schemas are rejected. This
policy must never be used for the independent protection/review database.

Review signatures use `AlbumWinnow.v2.review-signature\0`, uint16 format 1 and
semantics 1, little-endian fixed integers, uint32 UTF-8 byte lengths, and explicit
nullable tags. Members and undirected edges have deterministic ordering. Native
property flags distinguish unknown from known false. Exact transitive groups
omit representative-star edges after checking connectivity; scoped groups retain
real edges. Recommendations, localized text and display order do not participate.
SHA-256 digests and canonical bytes have an independent fixed protocol vector in
`Tests/CoreFixtures/signature/v2.json`.

Cache fingerprint metadata crosses the bridge in ordered pages of1–256 records,
never as one whole-library buffer. Empty pages mark the end. The first read still
validates stored metadata and its sample checksum before permitting reuse.

During a cache owner's lifetime, previously validated metadata may be retained
without retaining pixel samples. SQLite `data_version` is compared on that same
connection; another connection's commit invalidates the metadata index. Index
changes follow successful database commits. Samples are still checked when read,
and external corruption/pipeline replacement tests exercise an already primed
index. See SQLite's [data_version contract](https://www.sqlite.org/pragma.html#pragma_data_version).

The independent review database uses application ID `0x41575232`, schema 1.
Initialization requires an explicit host initialized-state input; missing data in
an initialized workspace is an error. Required singleton rows, table/foreign-key
integrity, protection-row integrity and the open database file's identity are
validated. The review owner rejects outside writes or live file replacement; it
never applies the scan-cache reconstruction policy. Persistence reads use one
SQLite snapshot. Typed review commands commit before acknowledgement; the Apple
presentation model acknowledges saved choices only after the actor returns.

The direct detection-to-review API stages `CoreScanReviewAsset` native metadata
in batches of at most16. `finishDetectedScan` receives references to completed
Rust detection sessions and returns only committed review metadata. Group
assembly, real edges, provider/quality evidence, signatures and the transaction
stay inside Rust. Native metadata must match prepared identities, revisions,
resource flags and measured fingerprint fields; metadata batches validate fully
before changing the stage. Imported test groups cannot be mixed into that stage.

The staged operation/revision and current sides/source preference must match.
Normal scans may use the available subset of active registered sources; the host
must report unavailable sources. A/B scans require both selected registered
sources, and neither path can add an unregistered/inactive source. Scene outputs
cannot overlap duplicate groups or use a different operation/provider context.
Completed duplicate detection exposes scene-candidate ID pages of at most16.
Rust derives these from the final validated groups, excluding their members in
both ordinary and A/B scans. Preparation or missing final facts rejects the read.
The candidate list is cached per validation state, invalidated by new final facts,
and cancellation rejects cached reads too. Page reads do not rebuild all groups.
Apple does not export groups to decide scene eligibility.
Both detection sessions expose final-validation ID pages of at most16. Scene
handoff requires every grouped member's current accessible revision; missing,
changed, duplicate or late facts cannot publish a partial result or repair an
already failed scene check.

One `CancellationHandle` belongs to the whole bridged operation. Detection,
optional scene session and handoff must share that same handle; an unrelated
handle is rejected. Cancellation remains atomic without taking a state lock.
Cross-session handoff locks detection, then scene, then review, with no inverse
path. Native image/Vision work and callbacks run outside these locks. The direct
API is a cutover boundary; passing its tests alone does not prove the production
SwiftUI application has adopted it.

### Apple scan commit boundary

`ScanEngine.scan` requires one `AppleAssetSources` native catalog plus the
existing `RustReviewSession`; the removed source-array/settings overload is not
retained as a production compatibility path. Native available sources must match
the current registered catalog, native namespace/identity and current PhotoScope.
The provided native source order is preserved. Normal scans report missing active
source IDs in `AppleScanReceipt`; A/B requires both sides. Root identity is checked
again before commit. Settings/catalog edits during work invalidate the staged
operation rather than publishing a partial review.

Native asset/evidence batches are16 entries, with the same operation and
cancellation handle for duplicate detection, native-driven scene detection and
review commit. ScanEngine never fetches all detection groups or reimports Swift
groups. The receipt contains committed metadata, counts/issues, unavailable source
IDs and an explicit cache-maintenance result; gallery/detail reads belong to the
Rust owner. Cancellation/error before commit discards staging and leaves the last
committed review and manual decisions intact.

Review and derived cache are separate databases. Cache pruning occurs only after
the review transaction succeeds. Once committed, the scan always acknowledges
that review transaction: cancelled/failed cache maintenance is reported separately
and cannot turn it into an apparent failed review commit. A new source snapshot
and fresh native validation remain required before another cleanup operation.

The production SwiftUI model now uses the native actor and receipt/page APIs.
The full application regression and delivery matrix remain pending.

### Native application owner

AppleReviewOwner privately retains the single Rust review session, native scan
and cleanup services, and actor-isolated security-scoped authorizations (including
inactive protected roots). Database/bookmark initialization is detached from the
caller MainActor; all state commands/pages subsequently execute on the actor.
Independent v2 preferences/root initialization requires an absent marker for a
fresh install or a true boolean marker for an initialized store. Missing DB and
malformed markers cannot become empty protection. No legacy data is read/deleted.
Native scope is reconstructed from the exact Rust range, without calendar
reinterpretation. Read-only directory snapshots are staged16 at a time; unknown
native facts produce incomplete protection rather than declaring it complete.
Full application acceptance remains P7 work.

### Bounded presentation and confirmation

`reviewPage` atomically returns the current header, overview and at most256
lightweight group summaries. Each summary carries up to2 preview assets and the
preferred evidence; full members are read only through a selected group detail.
Visible/pending pages follow the stored query. Cleanup-candidate pages and saved
removal totals include effective saved confirmed/deferred choices independently
of filters. A default estimate or a deferred group without a saved choice is
never deletion authority. Details include core-derived estimates, reasons and
lock/read-only flags. Lock owners are separately paged.

Apple can prepare a version-bound core cleanup operation for confirmation, page
its actual groups/items, then cancel it or execute that same operation following
explicit human confirmation. Preparing/cancelling performs no system deletion.
Native preview callbacks retain requested authorization leases across suspension,
validate resource revisions before/after, and reject any current scopeEpoch
change. scanScopeEpoch describes the last committed scan and is not a current
source-edit token. Query/navigation edits do not change scopeEpoch.

### SwiftUI presentation owner

ReviewModel now bootstraps AppleReviewOwner asynchronously, with no old database
open/history deletion, legacy preference read, automatic scan or old candidate
restoration. The existing bundle ID is retained per plan6.1. AppStorage uses the
v2 preference suite too. A one-time localized setup notice precedes scanning.
Normal v2 relaunch restores source/protection/settings records but exposes no
cleanup candidates until an explicit, successful native scan revalidates them.
Persisted background-interruption consent is v2-only; user cancellation clears
it and records the core cancelled-by-user setting.

The gallery/pager holds lightweight summaries, not full library groups. Current
and adjacent pages fetch at most3 single-group details. Status labels are cached
from committed core output across detail eviction, so a stable batch order can
show its actual completed decisions. Filters, counts, estimates, recommendations,
protection flags and cleanup pairs come from Rust. Only temporary keep/delete-all
drafts, presentation state and native cloud progress belong to SwiftUI. A prepared
plan is cancelled when the confirmation is dismissed; applying takes ownership
before dismissal can cancel it. Native image/preview/difference access uses the
owner's retained authorization callbacks, not separately restored UI bookmarks.

The unused Swift BLAKE3 package dependency was removed at application link cutover
because its C symbol collided with Rust BLAKE3. Remaining legacy Swift store/
business types and their tests still require P8 removal/API migration. Passing
new focused application tests does not establish the complete old AppTests/UI
matrix or five-target candidate build.

Cancellation policy writes are serialized after the active scan drains; busy
state remains set until the policy commits. Starting a new manual scan first
commits the cancellation-marker reset and acknowledges that header, then honors
background cancellation. This lets new consent supersede a previous cancelled
scan while explicit cancellation still clears pending resume/download consent.

Native source construction defaults network downloads off for preview, difference,
removability feedback and final cleanup reads. Only scan explicitly passes the
scan-download preference and requested download IDs. Allowing scan downloads does
not silently authorize network-backed previews. The generated opt-in PhotoKit
fixture asserts the callback's real source policy, without a real cloud transfer.
