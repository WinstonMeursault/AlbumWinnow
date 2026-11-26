package org.albumwinnow.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class ScanReviewHandoffTest {
    private class Fixture(scenes: Boolean = false) : AutoCloseable {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "handoff-${System.nanoTime()}")
        val review = RustReviewSession(File(root, "review.sqlite").absolutePath, false)
        val cancel = CancellationHandle()
        val items: List<ScanItemInput>
        val metadata: List<CoreScanReviewAsset>
        init {
            val source = review.registerSource(1uL, CoreSourceInput(CoreSourceKind.CONTROLLED_TEST, "native.fixture.v2", byteArrayOf(1), byteArrayOf(), "Generated"))
            if (scenes) {
                val settings = review.header().settings
                settings.similarScenesEnabled = true
                review.saveSettings(review.header().metadata.revision, settings)
            }
            items = listOf(1, 1, 2, 3).mapIndexed { index, hash ->
                ScanItemInput(CoreAssetKey(source.id, index.toString()), "ns-revision",
                    CoreFingerprint(ByteArray(32) { hash.toByte() }, 100u, 100u, 8u, false, 0uL, 0uL,
                        byteArrayOf(128.toByte(),128.toByte(),128.toByte(),255.toByte()), 0.1), false, null)
            }
            metadata = items.map { item -> CoreScanReviewAsset(
                CoreReviewAsset(item.asset, "${item.asset.itemId}.png", item.revision, CoreSourceKind.CONTROLLED_TEST,
                    null, 100uL, null, null, null, null),
                CoreReviewEvidence(item.asset, 100u, 100u, 8u, false, 0.1, 10.0)) }
        }
        fun prepare(): RustScanSession {
            review.beginScan(review.header().metadata.revision, "scan")
            try { review.appendScanAssets("scan", List(17) { metadata[0] }, cancel); fail("oversized native metadata batch accepted") }
            catch (_: BridgeException.InvalidBuffer) { }
            review.appendScanAssets("scan", metadata, cancel)
            val scan = RustScanSession("scan", listOf(items[0].asset.sourceId), null, null, cancel)
            try {
                scan.appendPrepared(items)
                scan.completePreparation()
                while (true) {
                    val batch = scan.nextBatch(16u)
                    if (batch.done) break
                    scan.submitResults("scan", batch.batchId, batch.tasks.map { CoreTaskResult(it.taskId,
                        CoreVerification.Matched(if (it.exactIdentity) CoreMatch.EXACT_DUPLICATE else CoreMatch.DISTINCT)) })
                }
                try { scan.finalValidationPage(0uL, 17u); fail("oversized final page accepted") }
                catch (_: BridgeException.InvalidBuffer) { }
                try { scan.sceneCandidatePage(0uL, 16u); fail("unvalidated scene candidates accepted") }
                catch (_: BridgeException.InvalidState) { }
                val ids = scan.finalValidationPage(0uL, 16u)
                assertEquals(2, ids.size)
                scan.submitFinalValidations("scan", ids.map { CoreAssetValidation(it, "ns-revision", true) })
                try { scan.sceneCandidatePage(0uL, 17u); fail("oversized scene candidate page accepted") }
                catch (_: BridgeException.InvalidBuffer) { }
                assertEquals(listOf(items[2].asset), scan.sceneCandidatePage(0uL, 1u))
                assertEquals(listOf(items[3].asset), scan.sceneCandidatePage(1uL, 16u))
                assertTrue(scan.sceneCandidatePage(ULong.MAX_VALUE, 16u).isEmpty())
                return scan
            } catch (error: Throwable) { scan.close(); throw error }
        }
        override fun close() { review.close(); cancel.close(); root.deleteRecursively() }
    }

    @Test fun detectionCommitsReviewDirectlyWithoutReturningGroupsToKotlin() {
        Fixture().use { f -> f.prepare().use { scan ->
            CancellationHandle().use { other ->
                try { f.review.finishDetectedScan("scan", scan, null, other); fail("unrelated cancellation handle accepted") }
                catch (_: BridgeException.InvalidValue) { }
            }
            assertEquals(1uL, f.review.finishDetectedScan("scan", scan, null, f.cancel).scanGeneration)
            val summary = f.review.queryPage(0uL, 1u).single()
            assertEquals(CoreMatch.EXACT_DUPLICATE, summary.kind)
            assertEquals(2uL, summary.memberCount)
            assertEquals(10.0, summary.latestDate)
            val detail = f.review.groupDetail(summary.signature)
            assertEquals(f.metadata.take(2).map { it.asset }, detail.group.members)
            assertEquals(f.metadata.take(2).map { it.evidence }, detail.group.evidence)
        } }
    }

    @Test fun nativeSceneHandoffRequiresFinalFactsThroughKotlin() {
        Fixture(true).use { f -> f.prepare().use { scan ->
            val provider = CoreSceneProvider("controlled.native", "2", "fixed", "fixture")
            RustSceneSession("scan", provider, null, null, f.cancel).use { scenes ->
                scenes.appendPrepared(f.items.takeLast(2).map { item -> CoreSceneAsset(item.asset, item.revision, provider,
                    CoreSceneQuality(0.5, 0.01, 0.1, 0.0, 0.0), listOf(0u,0u,0u,0u), 100u, 100u, 8u, false, 0.1,
                    false, null, null, 10.0) })
                scenes.completePreparation()
                while (true) {
                    val task = scenes.nextWork().request ?: break
                    scenes.submitDistance("scan", task.taskId, 0.1f)
                }
                val before = f.review.header().metadata
                try { f.review.finishDetectedScan("scan", scan, scenes, f.cancel); fail("unvalidated scene group committed") }
                catch (_: BridgeException.InvalidState) { }
                assertEquals(before, f.review.header().metadata)
                try { scenes.finalValidationPage(0uL, 17u); fail("oversized scene final page accepted") }
                catch (_: BridgeException.InvalidBuffer) { }
                scenes.submitFinalValidations("scan", scenes.finalValidationPage(0uL,16u).map { CoreAssetValidation(it, "ns-revision", true) })
                f.review.finishDetectedScan("scan", scan, scenes, f.cancel)
                val settings = f.review.header().settings
                settings.query.collection = CoreReviewCollection.SIMILAR_SCENES
                f.review.saveSettings(f.review.header().metadata.revision, settings)
                val group = f.review.groupDetail(f.review.queryPage(0uL,1u).single().signature).group
                assertEquals(provider, group.scene)
                assertEquals(1, group.sceneMatches.size)
                assertEquals(2, group.sceneQuality.size)
            }
        } }
    }

    @Test fun concurrentHandoffCommitsOnlyOnceThroughKotlin() {
        Fixture().use { f -> f.prepare().use { scan ->
            val executor = Executors.newFixedThreadPool(2)
            try {
                val futures = (0..1).map { executor.submit(Callable {
                    try { f.review.finishDetectedScan("scan", scan, null, f.cancel); true }
                    catch (_: BridgeException.InvalidState) { false }
                }) }
                assertEquals(1, futures.count { it.get(10, TimeUnit.SECONDS) })
                assertEquals(1uL, f.review.header().metadata.scanGeneration)
                assertEquals(1uL, f.review.queryCount())
            } finally { executor.shutdownNow() }
        } }
    }
}
