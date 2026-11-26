package org.albumwinnow.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ReviewStorageTest {
    private fun fixture(session: RustReviewSession): CoreReviewGroup {
        val source = session.registerSource(session.header().metadata.revision,
            CoreSourceInput(CoreSourceKind.CONTROLLED_TEST, "bridge.fixture", byteArrayOf(1), byteArrayOf(2), "Fixture"))
        fun asset(item: String) = CoreReviewAsset(CoreAssetKey(source.id, item), item, "opaque-nanosecond-revision",
            CoreSourceKind.CONTROLLED_TEST, null, 100uL, 1795000000.123, null, null, null)
        val a = asset("a"); val b = asset("b")
        return CoreReviewGroup(a.id, listOf(a, b), listOf(CoreReviewDuplicate(b.id, CoreMatch.EXACT_DUPLICATE)),
            null, null, null, null, true, null, emptyList(), emptyList(), emptyList())
    }
    @Test fun presentationPagesKeepSavedChoicesSeparateFromEstimates() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "presentation-${System.nanoTime()}")
        try {
            RustReviewSession(File(root, "review.sqlite").absolutePath, false).use { session ->
                val group = fixture(session)
                CancellationHandle().use { cancel ->
                    session.beginScan(session.header().metadata.revision, "scan")
                    session.appendScanGroups("scan", listOf(group), cancel)
                    session.finishScan("scan", cancel)
                }
                val page = session.reviewPage(CoreReviewPageMode.VISIBLE, 0uL, 1u)
                val summary = page.groups.single()
                assertEquals(1uL, page.total)
                assertEquals(0uL, page.overview.savedRemovals)
                assertEquals(listOf(group.members[0]), summary.previewAssets)
                assertEquals(100uL, summary.estimate.knownBytes)
                session.applyIntent(page.header.metadata.revision, summary.signature, "keep", CoreReviewIntent.ConfirmKeep(group.members[1].id))
                session.applyIntent(session.header().metadata.revision, summary.signature, "saved-defer", CoreReviewIntent.SetStatus(CoreReviewStatus.DEFERRED))
                val settings = session.header().settings
                settings.query.status = CoreReviewStatusFilter.PENDING
                val revision = session.saveSettings(session.header().metadata.revision, settings)
                val candidates = session.reviewPage(CoreReviewPageMode.CLEANUP_CANDIDATES, 0uL, 1u)
                assertEquals(revision, candidates.header.metadata)
                assertEquals(1uL, candidates.overview.savedRemovals)
                assertEquals(1uL, candidates.overview.hiddenSavedRemovals)
                assertEquals(group.members, candidates.groups.single().previewAssets)
                assertEquals(1uL, candidates.groups.single().savedRemovalCount)
                assertEquals(0uL, session.reviewPage(CoreReviewPageMode.PENDING, 0uL, 1u).total)
                session.setLocked(session.header().metadata.revision, group.members[0], true)
                val detail = session.groupDetail(summary.signature)
                assertEquals(listOf(group.members[0].id), detail.locked)
                assertTrue(detail.readOnly.isEmpty())
                assertEquals(0uL, detail.summary.savedRemovalCount)
                assertEquals(listOf(group.members[0].id), session.lockOwnersPage(group.members[0], 0uL, 1u))
                assertEquals(0uL, session.reviewPage(CoreReviewPageMode.CLEANUP_CANDIDATES, 0uL, 1u).total)
                try { session.reviewPage(CoreReviewPageMode.VISIBLE, 0uL, 257u); fail("oversized presentation page accepted") }
                catch (_: BridgeException.InvalidBuffer) { }
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun reviewRestartAndProtectionRetriesNeverResurrectCandidates() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "review-v2-${System.nanoTime()}")
        val path = File(root, "v2/review.sqlite").absolutePath
        root.mkdirs()
        val old = File(root, "v1-sentinel").apply { writeText("old protection and candidates") }
        try {
            lateinit var signature: String
            lateinit var group: CoreReviewGroup
            var originalRevision = 0uL
            RustReviewSession(path, false).use { session ->
                assertEquals(0uL, session.header().metadata.sourceCount)
                assertEquals(0uL, session.queryCount())
                group = fixture(session)
                CancellationHandle().use { cancel ->
                    session.beginScan(session.header().metadata.revision, "scan")
                    session.appendScanGroups("scan", listOf(group), cancel)
                    originalRevision = session.finishScan("scan", cancel).revision
                }
                val summary = session.queryPage(0uL, 1u).single()
                signature = summary.signature
                assertEquals(0uL, summary.confirmedRemovalCount)
                assertEquals(100uL, summary.estimate.knownBytes)
                assertEquals(group.members[0].captureDate, summary.latestDate)
                val decision = session.applyIntent(originalRevision, signature, "confirm", CoreReviewIntent.ConfirmKeep(group.preferred))
                assertEquals(listOf(group.members[1].id), decision.decision.removals)
                session.savePosition(decision.metadata.revision, 1uL, signature, 0uL)
            }
            RustReviewSession(path, true).use { session ->
                assertEquals(signature, session.resumeSignature())
                val locked = session.setLocked(session.header().metadata.revision, group.members[1], true)
                val retry = session.applyIntent(originalRevision, signature, "confirm", CoreReviewIntent.ConfirmKeep(group.preferred))
                assertTrue(retry.replayed)
                assertTrue(retry.decision.removals.isEmpty())
                val unlocked = session.setLocked(locked.revision, group.members[1], false)
                assertTrue(session.groupDetail(signature).decision!!.removals.isEmpty())
                val all = session.applyIntent(unlocked.revision, signature, "all", CoreReviewIntent.ConfirmDeleteAll)
                val readOnly = CancellationHandle().use { cancel ->
                    session.beginReadOnlySnapshot(all.metadata.revision, "policy", group.preferred.sourceId)
                    session.appendReadOnlySnapshot("policy", group.members, cancel)
                    session.finishReadOnlySnapshot("policy", true, cancel)
                }
                assertFalse(session.groupDetail(signature).decision!!.deleteAll)
                assertTrue(session.groupDetail(signature).decision!!.removals.isEmpty())
                val reset = session.resetProgress(readOnly.revision)
                assertEquals(listOf(group.preferred.sourceId), session.header().readOnlySources)
                assertEquals(0uL, reset.decisionCount)
                try { session.savePosition(reset.revision, 1uL, signature, 0uL); fail("late navigation restored an old anchor") }
                catch (_: BridgeException.StaleOperation) { }
            }
            assertEquals("old protection and candidates", old.readText())
        } finally { root.deleteRecursively() }
    }
    @Test fun cancelledStagingAndMissingProtectionDatabaseFailClosed() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "review-v2-cancel-${System.nanoTime()}")
        val path = File(root, "v2/review.sqlite").absolutePath
        try {
            RustReviewSession(path, false).use { session ->
                val group = fixture(session)
                val before = session.header().metadata
                session.beginScan(before.revision, "cancel")
                CancellationHandle().use { cancel ->
                    session.appendScanGroups("cancel", listOf(group), cancel)
                    cancel.cancel()
                    try { session.finishScan("cancel", cancel); fail("cancelled scan was committed") }
                    catch (_: BridgeException.Cancelled) { }
                }
                assertEquals(before, session.header().metadata)
                session.discardScan("cancel")
                assertEquals(0uL, session.queryCount())
                try { RustReviewSession(path, true).close(); fail("a second owner acquired the live review database") }
                catch (_: BridgeException.ProtectionUnavailable) { }
                assertTrue(File(path).delete())
                try { session.queryCount(); fail("missing review database became empty protection") }
                catch (_: BridgeException.ProtectionUnavailable) { }
                assertFalse(session.isHealthy())
            }
            try { RustReviewSession(path, true).close(); fail("initialized protection was silently recreated") }
            catch (_: BridgeException.ProtectionUnavailable) { }
            assertFalse(File(path).exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun concurrentCommandsCommitExactlyOneAuthoritativeRevision() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "review-v2-threads-${System.nanoTime()}")
        val pool = java.util.concurrent.Executors.newFixedThreadPool(8)
        try {
            RustReviewSession(File(root, "review.sqlite").absolutePath, false).use { session ->
                val group = fixture(session)
                val before = CancellationHandle().use { cancel ->
                    session.beginScan(session.header().metadata.revision, "scan")
                    session.appendScanGroups("scan", listOf(group), cancel)
                    session.finishScan("scan", cancel)
                }
                val signature = session.queryPage(0uL, 1u).single().signature
                val results = (0..7).map { index -> pool.submit(java.util.concurrent.Callable {
                    try {
                        session.applyIntent(before.revision, signature, "parallel-$index", CoreReviewIntent.ConfirmKeep(group.preferred))
                        1
                    } catch (_: BridgeException.StaleOperation) { 0 }
                }) }.map { it.get(30, java.util.concurrent.TimeUnit.SECONDS) }
                assertEquals(1, results.count { it == 1 })
                assertEquals(7, results.count { it == 0 })
                assertEquals(before.revision + 1uL, session.header().metadata.revision)
                assertTrue(session.isHealthy())
            }
        } finally { pool.shutdownNow(); root.deleteRecursively() }
    }
}
