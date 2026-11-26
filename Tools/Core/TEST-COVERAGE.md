# Regression coverage map

This maps preserved behavior to its current Rust, Apple and Kotlin tests.
Production SwiftUI uses the native actor, bounded pages and lazy group details;
recognition, state, storage and cleanup authority have one Rust owner. The former
Swift business/store implementations and GRDB are removed. Tests use v2 APIs,
explicit source identities and isolated single-owner lifetimes.

The map describes assertions and test locations, not a claim that every suite
ran on every commit. Per-run commands, failures and results belong in local
validation records. Test-count equality alone does not establish coverage.

| Existing coverage | v2 coverage | Behavior retained |
| --- | --- | --- |
| DuplicateDetector / RecognitionRegression | Existing Apple tests; `fingerprint_reference.rs`, `matching_candidate.rs`; Swift/Kotlin PixelContract | Native decode plus fixed normalized pixels; exact/visual/similar classification and original thresholds |
| ComparisonValidation / ScanEngine / ScanPolicy | Existing Apple tests; `scan_session.rs`; Swift/Kotlin ScanSession | Source policy, revisions, issue attribution, deterministic preparation/results, A/B edges, cancellation and final facts |
| Swift candidate implementation (removed) | `matching_candidate.rs` exhaustive comparison | Candidate retrieval equals exhaustive threshold search without full-library pair enumeration |
| SceneSimilarity / SceneScale | Existing Apple tests; `scene_reference.rs`; Swift/Kotlin SceneDifference | Native Vision/archive; provider isolation; bounded candidates/groups; clique consistency; recommendations and controlled distances |
| PhotoDifference | Existing Apple tests; `difference_reference.rs`; Swift/Kotlin SceneDifference | Native previews; exact fixed regions, unchanged unavailable reasons, geometry, cancellation |
| Cleanup / FolderCompanion / Hardening / RemovalPreflight / PhotoScope / SourcePolicy | Existing Apple suites retained; Rust `cleanup_plan.rs`; Swift/Kotlin CleanupProtocol; Apple RustNativeSource/RustNativeCleanup | Protection, aliases, companion resources, source scope, cancellation and recoverable native removal |
| SceneReview / DifferenceReview / SceneQueue UI | SceneReview, DifferenceReview and SceneQueue application/UI suites | Manual decisions, preview lifecycle, queue behavior and accessibility identifiers remain required |
| ReviewState / ReviewModel | ReviewState/ReviewModel, Rust storage/command and Swift/Kotlin ReviewStorage tests | v2 restart, transaction failures, protection failure and incremental updates |
| ReviewEvidence recommendation reasons | Same named Core test, now using RustReviewSession/groupDetail | Missing bit depth stays unknown; resolution/depth reasons and absent evidence |
| ReviewEvidence date/count ordering | Same named Core test, now using Rust queryPage | Unknown dates last in both directions; stable count ties |
| ReviewEvidence space estimates | Same named Core test, now using Rust summary estimates | Partial/negative unknown sizes, protected members, empty retained selection and Int64 saturation |
| ReviewEvidence query/decision isolation | Same named Core test, now using Rust settings/commands/pages | Known lower bounds, stable zero estimates, status/source filters and committed decisions unchanged by queries |
| ReviewState restart/reset and signatures | Same XCTest methods using RustReviewSession; signature construction is test-only | One owner closed before reopening; committed choices/locks/position survive; reset removes choices/position and retains locks; changed members/revisions/categories invalidate signatures |
| Hardening damaged lock/revision tests | Hardening v2 payload corruption tests, ReviewState alias test, native revision parser parameter cases | Malformed native identity rejected atomically; corrupt saved lock prevents reopening; missing original path cannot unlock surviving hard link |
| Hardening incremental choices/settings | Same named Hardening tests using core commands/header | Independent decisions, explicit empty albums/user cancellation, reset retaining protection, rejected commands cannot publish partial changes |
| Old review schema migration | Hardening legacyStateFilesAreNotMigratedOrModified; ScanPolicy unknownV2SchemaFailsClosedWithoutResettingSavedLocks | Intentional v2 no-migration scope: old valid/damaged files untouched; fresh v2 has no sources/locks/choices; unsupported v2 schema cannot erase protection |
| ScanPolicy malformed read-only state | Same named test using core snapshot and offline corrupted v2 payload | Invalid native identity cannot commit; damaged saved protection cannot load as usable state |
| GRDB-driven cache fault injection | Existing CacheRecovery and SceneSimilarity tests, test-only FixtureDatabase | Same damaged fingerprint/sample/provider/archive/quality, inactive-source pruning and compaction assertions through SQLite3 |
| Cleanup partial outcomes/missing keep | Same named Cleanup tests through Rust plans/AppleCleanupExecutor | Changed resource and deliberately mismatched scan evidence cannot pass native verification; independent valid removal returns real Trash receipt and restores bytes; missing keep leaves candidate intact |
| Cleanup sole copy/whole group/cancel | Same named Cleanup tests; existing CleanupProtocol preflight/ticket gate | Overlapping roots yield no group/authority; every whole-group member must pass current checks; successful all-copy recovery is restored; cancelled native availability preflight cannot proceed |
| FolderCompanion cases | Same named tests through Rust plans and native executor | MOV/MP4/AAE/image-XMP/RAW additions after planning prevent movement; ordinary cross-format copies stay removable and nested companions remain local |
| Similar-photo manual cleanup | RecognitionRegression same named test using actual native scan/core kind/manual intent | Similar warning kind is retained; scan creates no decision; explicit saved keep authorizes actual recoverable removal/restoration |
| Scene final revalidation | SceneSimilarity same named test and existing native scene tests | Changed visual content, read-only policy and unknown provider prevent execution; compatible current native measurements permit recoverable removal and byte restoration |
| ScanPolicy cross-side/aliases | Same named tests via core decisions/plans, fixtureRemovals only remaps readable IDs | No same-side transitive removal, bounded star evidence, associated-resource retention; saved read-only physical identity protects surviving alias after original disappears |
| Legacy revision parser / full-scan JSON | Hardening invalidProtectionMetadataCannotPartiallyCommit; ScanEngine coreGroupsWithoutEvidenceKeepPreviewDimensionsUnknown; PhotoRequest issue roundtrip | Obsolete v1 parsing/serialization is removed; malformed core identity/link count/oversized revision cannot commit; absent core evidence stays unknown; native issue diagnostics remain codable |

The Android controlled scene provider is test-only. It does not implement Apple
Vision or advertise compatibility with Apple's live provider. Fixed Apple vectors
are arithmetic fixtures, not an Android scene-recognition capability claim.

Cache/signature coverage: `cache_storage.rs`, `review_signature.rs`, Swift and
Kotlin CacheStorage tests replace the old Swift storage/compression path. Existing
Apple CacheRecovery cases still verify damaged metadata/samples, invalid measured
bit depth, inactive-source pruning and clear-cache behavior. The v1 cache migration
case is intentionally replaced by `v2CacheLeavesOldWorkspaceUntouched`, following
the explicit no-migration scope; it asserts the old bytes stay unopened/unchanged.
Rust `review_domain.rs` covers retained edges, aliases, protection pruning and
Delete All. `review_store` initialization tests cover first install/restart,
missing/empty/corrupt/foreign/unknown data, missing required rows, live file
replacement and lost protection rows.
Review command coverage: `review_store/{tests,protection,settings}.rs` and
`review_session/tests.rs` cover opaque source registration, v2 restart, required
state integrity, atomic scan replacement, protection/decision pruning, stale and
idempotent intents, monotonic navigation, scope versus query epochs, reset,
query-only storage and SQLite capacity exhaustion. `review_domain.rs` also maps
recommendation explanations, size estimates and date fallback. The tracked
`review_storage_benchmark` example measures 100/1,000/10,000 saved groups and
saved decisions with incremental navigation/decision operations. Swift/Kotlin
ReviewStorage tests exercise actual native persistence, protection pruning,
cancelled staging, missing protection data and concurrent commands through both
bindings. Apple application tests additionally exercise the native owner and
production cleanup path.

Portable-plan coverage: `cleanup_plan.rs` and `review_session/tests.rs` cover
manual versus estimated choices, four authority epochs, current native facts,
cross-group/native aliases (including retained resources outside selected groups),
whole-group preflight, source/provider compatibility, current companions/link
counts, filesystem protection evidence versus independent PhotoKit items,
single-use execution tickets, blocked concurrent edits, cancellation/partial
completion, late reports and atomic completion failures. `review_store/tests.rs`
also requires one live owner, rejects database hardlinks/symlinks and detects a
lost owner-lock file. These are controlled facts and fake outcomes; native Apple
removal still requires separate native Apple evidence. Swift/Kotlin CleanupProtocol
tests exercise the actual exported protocol with controlled facts and fake outcomes.
Bounded read-only snapshot and whole-group preflight tests additionally require
16-record batches, duplicate/stale/cancel/failure isolation, revocation after a
failed recheck, paged cleanup outcomes, and Rust-owned final PhotoKit date-range
checks. Both bindings exercise these exports in native runtime tests.

Apple-native coverage: RustNativeSource/RustNativeCleanup use opaque registered
directory identities and generated files. They verify actual Trash recovery and
byte-preserving restoration, partial completion, new companions blocking the whole
group, atomic cancellation, a replaced locked path alias, unavailable inactive
protected roots, retargeted directory identity and native Vision provider/fresh
measurements. NativePhotosCleanupTests drives the explicit opt-in foreground
NativePhotosCleanupFixture host: each case creates its own exact Photos identifiers
and album, then checks retained versus Recently Deleted outcomes, scope-change
rejection or OS denial preserving both photos and the manual choice. CoreNativePermission
is the separate full-access UI setup/verification scheme. Missing opt-in or access
fails native Photos tests instead of silently skipping. Neither target authorizes
access to a user's physical-device library. Production application tests exercise
the same owner and native cleanup adapter.

Direct handoff coverage: `review_scan.rs` tests completed ordinary/A-B and
scene detection transferred directly to the Rust review owner, preserving native
metadata, actual edges, provider/quality measurements, dates and persisted
signatures. Incomplete/cancelled/stale/mixed stages, unrelated sources and missing
or failed final scene facts cannot commit. Native metadata and final-fact batches
are bounded to 16 and validate atomically. Swift/Kotlin ScanReviewHandoff tests call
this direct API (without fetching/reimporting detection groups), exercise both
optional scene-handle variants and require exactly one concurrent commit. All
sessions/handoff must use the operation's same cancellation handle. The Apple
scan driver and production SwiftUI owner use this handoff.

Scene-candidate coverage: `scan_session.rs` exercises multi-page ordinary/A-B
eligibility, validated duplicate exclusion, incomplete/revised final facts,
invalid limits, end/maximum offsets, repeat reads and cancellation. Swift/Kotlin
handoff tests exercise the bounded pages over the actual bridges. Apple
SceneSimilarityTests also drives real Vision observations into the retained
scene session and directly into the Rust review store, verifies provider/edge
persistence, and rejects changed final native facts. Production application tests separately exercise the native owner and queues.

| Existing scan fixture coverage | Current location and verification |
| --- | --- |
| ScanEngine / CacheRecovery | Same test functions via test-only FixtureScanEngine: registered v2 IDs, real native scan commit, paged Rust summaries/details, incremental/rebuilt cache, cancellation and recovery |
| RecognitionRegression / ComparisonValidation / Hardening / Cleanup | Same assertions and generated sources; fixture-only ID projection preserves readable expectations and validates the new owner output, including aliases, actual failed-asset attribution and protected resources |
| SourceHandling / PhotoRequest / ScanPolicy | Same cloud/retry/accounting/A-B/unselected-source assertions; controlled source proxy forwards image orientation, availability and download policy |
| SceneSimilarity / SceneScale | Existing scene/scale/cancel assertions; only test code projects complete scene groups. Production native driver returns a retained Rust session and final facts |
| Native scan transaction integration | RustScanPipelineTests: committed native metadata, independent cache clear/protection, cancellation preserving choices, stale settings, unavailable sources/A-B, root retargeting before/during work, broader PhotoScope rejection, explicit postcommit cache-failure receipt, failed review commit rolling back decisions/metadata and preserving obsolete derived entries |

FixtureScanEngine is test-target-only, opens/closes one review owner per call,
registers opaque source IDs and reads summaries/pages plus one detail at a time.
It supplies no alternate production engine or persisted compatibility snapshot.
RustScanPipelineTests also runs in the iOS CoreBridge target with bundled,
project-generated images. ScanBenchmark uses the production receipt API and
validates committed Rust pages/details; its timing includes the review commit
and paged result verification. Performance comparisons must report this boundary.

AppleReviewOwnerTests covers isolated v2 bootstrap/legacy sentinels, lost DB and
invalid initialization markers, registered bookmark/identity restoration without
auto-scan, replacement roots, command/cache separation, lock/readonly pruning,
inactive unavailable protected roots, setup/cloud preferences, and macOS-only
recoverable generated Trash plus restored bytes. The PhotoKit foreground fixture
now uses this owner and actual native scan/manual intent rather than injected
review groups. Both paths remain opt-in/generated fixtures only.

During development, select checks affected by a change. Release acceptance adds
the required platform matrix and clean builds; compilation alone is not a test pass.

Presentation: five focused Rust tests cover bounded previews, saved-vs-estimated
removals, pending/filter/global counts, scene/duplicate categories, alias owners,
limits and nonmutating reads. A focused Swift owner test covers real native reads,
source deactivation across await, core protection flags, prepared plan paging and
cancellation without system deletion. A focused Android instrument validates the
records, limits and saved choices over actual Kotlin/native bindings.

V2ApplicationTests adds real native scan → lightweight gallery → lazy group
detail → manual intent → hidden saved candidates → prepared/cancelled confirmation
coverage. It verifies native previews, lock/reset/cache behavior, fresh setup and
legacy sentinels, plus unavailable roots/reconnect/new identity while preserving
old protection. The focused detail-eviction regression first reproduced a stale
status label and then passed after storing committed presentation labels. These
checks do not replace the older lifecycle, restart, scene, difference, source and
recoverable-execution scenarios. Those test sources are retained and now use v2 APIs and single-owner lifetimes,
without compatibility shims. V2SetupUITests exercises the actual
one-time notice and relaunch; its exact executed result belongs to validation.

Retained AppTests now use ModelWorkspace (test-only isolated v2 suites), explicit
bootstrap/scan, bounded summaries/details and actual core-prepared previews.
Reopen tests close the previous owner. Queries, source ties/A-B retention, scene
queues, stale evidence, alias locks, unavailable sources, cancellation and reset/
cache assertions are preserved. The old history-deletion expectation was changed
to byte-for-byte preservation, as explicitly required for v2. A controlled SQLite
trigger installed while the owner is closed proves a failed real decision
transaction publishes no selection/revision and disables cleanup. macOS native
cleanup additionally requires actual Trash movement, a returned native location,
restoration and byte equality; simulator provider failures are not reported as
Trash success. Per-run validation records distinguish targeted checks from complete suites.

iOS lifecycle regressions cover cancellation settings being serialized after the
scan drains, and a new manual scan superseding an old cancelled marker before
background cancellation. The cached header is updated only after that core
setting commits. Existing generated PhotoKit fixtures additionally verify that
preview callbacks still skip cloud reads after scan downloads are allowed, then
exercise actual retained-ID-safe native recovery. No real cloud transfer is
claimed by that policy assertion.

The Swift recommendation, size accumulation and query implementations are
removed. These tests exercise the production Rust session through FFI;
their test fixture only constructs typed inputs, commits scans and reads pages.
An unrelated registered source returns no matching groups. An unregistered query
source is rejected without changing settings or decisions. Sources are registered
before the fixture scan, because changing the source scope invalidates old groups.
The native EXIF parsing regression stays in the same test file.

The removed ReviewStateStore is not retained as a test reference implementation.
FixtureReview builds typed inputs and commits to the real Rust store;
FixtureDatabase only injects/inspects faults in disposable databases. Protection
database payloads are changed only after the Rust owner has closed. The retained
native revision parser is tested locally; Rust revisions remain opaque.
ReviewStateBenchmark now measures the same navigation/decision operations over
the Rust bridge, with bounded input pages and a closed-owner reopen assertion.
Its compilation is not performance acceptance; run it to measure timings and
post-close memory for the current build.

AssetMutationService, CleanupProtection, CleanupPair and their old outcome types
are removed. Invalid single-member/partial whole-group submissions no longer
have a production API: the retained CleanupProtocol fixture explicitly checks
that authorization fails before complete preflight, then tests one-use tickets.
NativeCleanupFixture deliberately supplies scan labels in boundary tests so that
the real executor must reject unrelated bytes; RecognitionRegression separately
uses the production native scan before manual cleanup. No recognition thresholds
were changed. Explicit macOS Trash receipts/restored bytes are required in these
tests; no skipped/provider failure is treated as successful recovery.

DuplicateGroup/ScanResult projections exist only in the Apple test target. Their
category is copied from the core summary (or the scene detector), not recomputed
by a Swift grouping algorithm. Production uses AppleScanReceipt, CoreGroupSummary
and lazy CoreGroupDetail. The removed full-scan JSON format is not maintained.

Native source identity tests now compare static directory identity with registered
source identity, require the v2 physical-file token, and verify companion/link
changes through current native facts. Readable folder IDs exist only in the test
target's explicitly labelled fixture initializer. PhotoRequest explicitly supplies
its test source ID, retaining download opt-in and designated-retry checks.
SourcePolicy's app assertion checks actual core-planned keep/remove sides directly
instead of calling the deleted Swift side-policy helper.

The missing-keep cleanup fixture also requires a typed inaccessible diagnostic and
no Swift enum error string. The partial-outcome fixture still checks skipped
changed/nonmatching resources and actual recoverable movement. Cleanup failure UI
requires the localized cause, protected-companion reason and photo previews.
Relaunch UI tests require an explicit scan before restoring valid v2 decisions;
language changes retain the saved manual plan and locks without executing cleanup.

AboutTests checks the bundled version, AGPL text and the current locked Rust
notices, including UniFFI/MPL and BLAKE3/CC0, with removed Swift dependencies absent.
notices.py checks all supported-target normal Cargo trees plus generator templates,
selects explicit known license alternatives, retains AND-required Unicode text,
and includes bundled SQLite's public-domain notice. Pinned supplemental texts are
local, and regeneration runs Cargo offline after dependency preparation. This
checks the shared Rust/Apple notice list, including the pinned standard-library
distribution notices. Android main/test runtime graphs are locked; reviewed
framework license resources are copied during native preparation, and the APK
verifier requires their exact contents in the rebuilt artifact.

Cache metadata pages are covered by `cache_storage` across 273 persisted records,
including order, page boundaries, invalid limits and cancellation. Swift and
Kotlin cache roundtrips also assert page exhaustion and oversized-page rejection.
`review_scan` unit tests cover lossless packed staging with maximum bounded
strings and exact floating-point bits, plus corrupt payload/length rejection;
the retained direct handoff tests still check complete metadata coverage, source
binding, final scene facts, cancellation, stale operations and atomic publication.
