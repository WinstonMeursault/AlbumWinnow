package org.albumwinnow.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ScanSessionTest {
    private fun item(source: String, name: String, hash: Byte, distant: Boolean = false) = ScanItemInput(
        CoreAssetKey(source, name), "revision",
        CoreFingerprint(ByteArray(32) { hash }, 1000u, 1000u, 8u, false,
            if (distant) ULong.MAX_VALUE else 0u, if (distant) ULong.MAX_VALUE else 0u,
            byteArrayOf(if (distant) 0 else 128.toByte(), 128.toByte(), 128.toByte(), 255.toByte()), 0.0), false, null)

    @Test fun crossSideGroupsRequireFreshFactsAndRejectStaleCallbacks() {
        CancellationHandle().use { cancel ->
            RustScanSession("operation", listOf("left", "right"), CoreComparisonSides("left", "right"), "right", cancel).use { session ->
                val a = item("left", "a", 1)
                try {
                    session.appendPrepared(List(17) { a })
                    fail("oversized batch accepted")
                } catch (_: BridgeException.InvalidValue) { }
                session.appendPrepared(listOf(item("right", "d", 2, true), a, item("right", "c", 1), item("left", "b", 1)))
                session.completePreparation()
                val batch = session.nextBatch(16u)
                assertEquals(1, batch.tasks.size)
                assertTrue(batch.tasks[0].exactIdentity)
                assertEquals("revision", batch.tasks[0].firstRevision)
                val result = CoreTaskResult(batch.tasks[0].taskId, CoreVerification.Matched(CoreMatch.EXACT_DUPLICATE))
                try {
                    session.submitResults("old-operation", batch.batchId, listOf(result))
                    fail("stale operation accepted")
                } catch (_: BridgeException.StaleOperation) { }
                session.submitResults("operation", batch.batchId, listOf(result))
                assertTrue(session.nextBatch(16u).done)
                try {
                    session.groups()
                    fail("groups returned before native revalidation")
                } catch (_: BridgeException.InvalidState) { }
                val ids = session.finalValidationIds()
                assertEquals(setOf("a", "b", "c"), ids.map { it.itemId }.toSet())
                session.submitFinalValidations("operation", ids.map { CoreAssetValidation(it, "revision", true) })
                val groups = session.groups()
                assertEquals(1, groups.size)
                assertEquals("a", groups[0].preferred.itemId)
                assertEquals("c", groups[0].recommended?.itemId)
                assertEquals(setOf("b", "c"), groups[0].duplicates.map { it.asset.itemId }.toSet())
                assertEquals(2, groups[0].edges!!.size)
                assertTrue(groups[0].edges!!.all { it.first.sourceId != it.second.sourceId })
                try {
                    session.submitResults("operation", batch.batchId, listOf(result))
                    fail("duplicate callback accepted")
                } catch (_: BridgeException.StaleOperation) { }
                session.cancel()
                try {
                    session.groups()
                    fail("cancelled session returned results")
                } catch (_: BridgeException.Cancelled) { }
            }
        }
    }

    @Test fun runningScanSessionCancelsAcrossThreads() {
        CancellationHandle().use { cancel ->
            RustScanSession("operation", listOf("left"), null, null, cancel).use { session ->
                val started = java.util.concurrent.CountDownLatch(1)
                val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
                val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
                val worker = Thread {
                    try {
                        for (start in 0 until 1000 step 16) {
                            session.appendPrepared((start until minOf(start + 16, 1000)).map { item("left", "item$it", it.toByte()) })
                        }
                        session.completePreparation()
                        while (true) {
                            val batch = session.nextBatch(16u)
                            if (batch.done) break
                            session.submitResults("operation", batch.batchId, batch.tasks.map {
                                CoreTaskResult(it.taskId, CoreVerification.Matched(if (it.exactIdentity) CoreMatch.EXACT_DUPLICATE else CoreMatch.DISTINCT))
                            })
                            started.countDown()
                        }
                    } catch (_: BridgeException.Cancelled) {
                        cancelled.set(true)
                    } catch (error: Throwable) {
                        failure.set(error)
                    } finally {
                        started.countDown()
                    }
                }
                worker.start()
                assertTrue(started.await(10, java.util.concurrent.TimeUnit.SECONDS))
                val start = System.nanoTime()
                session.cancel()
                worker.join(500)
                assertFalse("candidate work did not stop within 500ms", worker.isAlive)
                assertNull(failure.get())
                assertTrue(cancelled.get())
                assertTrue(System.nanoTime() - start < 500_000_000L)
            }
        }
    }

    @Test fun classificationAndOrientedIdentityUseTheCore() {
        CancellationHandle().use { cancel ->
            assertTrue(coreVisualCandidate(item("left", "a", 1).fingerprint, item("right", "b", 2).fingerprint))
            val bytes = ByteArray(128 * 128 * 4) { if (it % 4 == 3) 255.toByte() else 128.toByte() }
            val pixels = PixelInput(128u, 128u, 512u, bytes, "test.srgb.premul.v1")
            val changed = bytes.copyOf()
            for (y in 0 until 8) for (x in 0 until 8) for (channel in 0 until 3) changed[(y * 128 + x) * 4 + channel] = 146.toByte()
            assertTrue(cancel.verifyPixels(pixels, pixels))
            assertEquals(CoreMatch.VISUAL_DUPLICATE, cancel.detailMatch(pixels, pixels))
            assertEquals(CoreMatch.SIMILAR_PHOTO, cancel.detailMatch(pixels, PixelInput(128u, 128u, 512u, changed, "test.srgb.premul.v1")))
            ByteHasher(cancel).use { hasher ->
                hasher.update("abc".toByteArray())
                val identities = (1..8).map { hasher.digestForOrientation(it.toUByte()).toList() }
                assertEquals(8, identities.toSet().size)
                assertNotEquals(identities[0], hasher.digest().toList())
                try {
                    hasher.digestForOrientation(0u)
                    fail("invalid orientation accepted")
                } catch (_: BridgeException.InvalidValue) { }
            }
        }
    }
}
