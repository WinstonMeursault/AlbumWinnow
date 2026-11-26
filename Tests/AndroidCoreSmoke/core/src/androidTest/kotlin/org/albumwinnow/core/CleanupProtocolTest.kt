package org.albumwinnow.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

// Fake facts/outcomes only: this host never deletes real library media.
@RunWith(AndroidJUnit4::class)
class CleanupProtocolTest {
    private fun root() = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "cleanup-v2-${System.nanoTime()}")
    private fun scanned(root: File): Triple<RustReviewSession, CoreReviewGroup, String> {
        val session = RustReviewSession(File(root, "review.sqlite").absolutePath, false)
        try {
            val source = session.registerSource(1uL, CoreSourceInput(CoreSourceKind.CONTROLLED_TEST, "bridge.fixture", byteArrayOf(1), byteArrayOf(2), "Fixture"))
            fun asset(item: String) = CoreReviewAsset(CoreAssetKey(source.id, item), item, "opaque-nanosecond-revision",
                CoreSourceKind.CONTROLLED_TEST, null, 100uL, 1795000000.123, null, null, null)
            val a = asset("a"); val b = asset("b")
            val group = CoreReviewGroup(a.id, listOf(a, b), listOf(CoreReviewDuplicate(b.id, CoreMatch.EXACT_DUPLICATE)),
                null, null, null, null, true, null, emptyList(), emptyList(), emptyList())
            CancellationHandle().use { cancel ->
                session.beginScan(session.header().metadata.revision, "scan")
                session.appendScanGroups("scan", listOf(group), cancel)
                session.finishScan("scan", cancel)
            }
            return Triple(session, group, session.queryPage(0uL, 1u).single().signature)
        } catch (error: Throwable) { session.close(); throw error }
    }
    private fun facts(asset: CoreReviewAsset, source: CoreSourceRecord) = CoreRemovalFacts(asset, source.nativeNamespace,
        source.nativeIdentity, true, true, true, false, false, true)
    private fun validation(item: CoreCleanupItem, source: CoreSourceRecord, all: Boolean) = CoreCleanupValidation(item.key,
        CorePairFacts(item.pair.keep?.let { facts(it, source) }, facts(item.pair.remove, source),
            if (all) CoreComparisonProof.WholeGroup else CoreComparisonProof.Pixels(CoreMatch.EXACT_DUPLICATE)))

    @Test fun controlledWholePreflightTicketsAndPartialCancellationCrossKotlin() {
        val root = root()
        try {
            val (session, group, signature) = scanned(root)
            session.use {
                CancellationHandle().use { cancel ->
                    val source = session.sourcesPage(0uL, 1u).single()
                    val confirmed = session.applyIntent(session.header().metadata.revision, signature, "all", CoreReviewIntent.ConfirmDeleteAll)
                    val plan = session.startCleanup(confirmed.metadata.revision)
                    assertEquals(2uL, plan.itemCount)
                    assertTrue(session.cleanupGroupsPage(plan.operation, 0uL, 1u).single().deleteAll)
                    val items = session.cleanupItemsPage(plan.operation, 0uL, 0uL, 16u)
                    val first = validation(items[0], source, true)
                    assertEquals(CoreCleanupReason.INVALID_SELECTION, session.authorizeCleanup(plan.operation, listOf(first), cancel).rejection)
                    assertNull(session.beginCleanupPreflight(plan.operation, 0uL))
                    assertNull(session.appendCleanupPreflight(plan.operation, 0uL, listOf(facts(group.members[0], source)), cancel))
                    assertEquals(CoreCleanupReason.INVALID_SELECTION, session.finishCleanupPreflight(plan.operation, 0uL))
                    assertNull(session.appendCleanupPreflight(plan.operation, 0uL, listOf(facts(group.members[1], source)), cancel))
                    assertNull(session.finishCleanupPreflight(plan.operation, 0uL))
                    val ticket = session.authorizeCleanup(plan.operation, listOf(first), cancel).ticket!!
                    assertNull(session.validateCleanupTicket(ticket))
                    try { session.setLocked(confirmed.metadata.revision, group.members[1], true); fail("in-flight edit was acknowledged") }
                    catch (_: BridgeException.InvalidState) { }
                    assertTrue(session.reportCleanup(ticket, listOf(CoreCleanupOutcome.MovedToTrash)).recorded)
                    assertFalse(session.reportCleanup(ticket, listOf(CoreCleanupOutcome.MovedToTrash)).recorded)
                    assertNull(session.cancelCleanup(plan.operation))
                    assertEquals(CoreCleanupReason.CANCELLED, session.authorizeCleanup(plan.operation, listOf(validation(items[1], source, true)), cancel).rejection)
                    assertEquals(0uL, session.finishCleanup(plan.operation).decisionCount)
                    assertEquals(0uL, session.queryCount())
                    assertEquals(listOf(CoreCleanupOutcome.MovedToTrash, CoreCleanupOutcome.Skipped(CoreCleanupReason.CANCELLED)),
                        session.cleanupResultsPage(plan.operation, true, 0uL, 256u).map { it.outcome })
                    assertEquals(CoreCleanupReason.STALE_PLAN, session.validateCleanupTicket(ticket))
                }
            }
        } finally { root.deleteRecursively() }
    }
    @Test fun lockingAfterPlanningRejectsTheOldCleanupPlan() {
        val root = root()
        try {
            val (session, group, signature) = scanned(root)
            session.use {
                CancellationHandle().use { cancel ->
                    val source = session.sourcesPage(0uL, 1u).single()
                    val confirmed = session.applyIntent(session.header().metadata.revision, signature, "keep", CoreReviewIntent.ConfirmKeep(group.preferred))
                    val plan = session.startCleanup(confirmed.metadata.revision)
                    val item = session.cleanupItemsPage(plan.operation, 0uL, 0uL, 1u).single()
                    session.setLocked(confirmed.metadata.revision, group.members[1], true)
                    assertEquals(CoreCleanupReason.STALE_PLAN, session.authorizeCleanup(plan.operation, listOf(validation(item, source, false)), cancel).rejection)
                    assertNull(session.cancelCleanup(plan.operation))
                    session.finishCleanup(plan.operation)
                    assertEquals(1uL, session.header().lockedCount)
                    assertTrue(session.groupDetail(signature).decision!!.removals.isEmpty())
                }
            }
        } finally { root.deleteRecursively() }
    }
    @Test fun boundedReadOnlyCancellationNeverPublishesPartialProtection() {
        val root = root()
        try {
            val (session, group, _) = scanned(root)
            session.use {
                CancellationHandle().use { cancel ->
                    val before = session.header().metadata
                    session.beginReadOnlySnapshot(before.revision, "policy", group.preferred.sourceId)
                    try { session.appendReadOnlySnapshot("policy", List(17) { group.members[0] }, cancel); fail("oversized batch accepted") }
                    catch (_: BridgeException.InvalidBuffer) { }
                    session.appendReadOnlySnapshot("policy", group.members, cancel)
                    try { session.appendReadOnlySnapshot("policy", listOf(group.members[0]), cancel); fail("duplicate snapshot member accepted") }
                    catch (_: BridgeException.InvalidValue) { }
                    cancel.cancel()
                    try { session.finishReadOnlySnapshot("policy", true, cancel); fail("cancelled snapshot committed") }
                    catch (_: BridgeException.Cancelled) { }
                    assertEquals(before, session.header().metadata)
                    assertTrue(session.header().readOnlySources.isEmpty())
                    session.discardReadOnlySnapshot("policy")
                }
            }
        } finally { root.deleteRecursively() }
    }
    @Test fun reportedOutcomesRemainReadableWhenProtectionStorageIsLost() {
        val root = root()
        try {
            val (session, group, signature) = scanned(root)
            session.use {
                CancellationHandle().use { cancel ->
                    val source = session.sourcesPage(0uL, 1u).single()
                    val confirmed = session.applyIntent(session.header().metadata.revision, signature, "keep", CoreReviewIntent.ConfirmKeep(group.preferred))
                    val plan = session.startCleanup(confirmed.metadata.revision)
                    val item = session.cleanupItemsPage(plan.operation, 0uL, 0uL, 1u).single()
                    val ticket = session.authorizeCleanup(plan.operation, listOf(validation(item, source, false)), cancel).ticket!!
                    assertTrue(File(root, "review.sqlite").delete())
                    assertTrue(session.reportCleanup(ticket, listOf(CoreCleanupOutcome.MovedToTrash)).recorded)
                    try { session.finishCleanup(plan.operation); fail("missing protection storage acknowledged completion") }
                    catch (_: BridgeException.ProtectionUnavailable) { }
                    assertFalse(session.isHealthy())
                    assertEquals(CoreCleanupOutcome.MovedToTrash, session.cleanupResultsPage(plan.operation, false, 0uL, 1u).single().outcome)
                }
            }
        } finally { root.deleteRecursively() }
    }
    @Test fun unexecutedNativeFailureDoesNotGrantATicketOrDiscardTheChoice() {
        val root = root()
        try {
            val (session, group, signature) = scanned(root)
            session.use {
                CancellationHandle().use { cancel ->
                    cancel.check()
                    val confirmed = session.applyIntent(session.header().metadata.revision, signature, "keep", CoreReviewIntent.ConfirmKeep(group.preferred))
                    val plan = session.startCleanup(confirmed.metadata.revision)
                    val item = session.cleanupItemsPage(plan.operation, 0uL, 0uL, 1u).single()
                    assertNull(session.failCleanupItem(plan.operation, item.key))
                    assertEquals(1uL, session.finishCleanup(plan.operation).decisionCount)
                    assertEquals(CoreCleanupOutcome.Failed, session.cleanupResultsPage(plan.operation, true, 0uL, 1u).single().outcome)
                    cancel.cancel()
                    try { cancel.check(); fail("atomic cancellation ignored") }
                    catch (_: BridgeException.Cancelled) { }
                }
            }
        } finally { root.deleteRecursively() }
    }
}
