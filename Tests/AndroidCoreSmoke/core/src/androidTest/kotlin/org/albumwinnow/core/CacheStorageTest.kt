package org.albumwinnow.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class CacheStorageTest {
    @Test fun v2CacheSurvivesRestartAndCancellationWithoutTouchingIndependentState() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "core-v2-${System.nanoTime()}")
        val path = File(root, "v2/scan.sqlite").absolutePath
        val asset = CoreAssetKey("opaque-source", "opaque-item")
        val sample = ByteArray(65536) { 127 }
        val fingerprint = CoreFingerprint(ByteArray(32) { 1 }, 512u, 384u, 8u.toUShort(), false,
            42uL, 123uL, byteArrayOf(127, 127, 127, -1), 429.4753860339191)
        val metadata = CoreCachedFingerprint(asset, "nanosecond-revision", fingerprint, 8u.toUShort(), 1795000000.123)
        try {
            CancellationHandle().use { cancel ->
                RustCacheStore(path).use { store ->
                    store.store(listOf(CorePreparedCacheEntry(metadata, sample)), "test-decode.1", cancel)
                }
                val review = File(root, "v2/review-sentinel")
                review.writeText("independent protection data")
                RustCacheStore(path).use { store ->
                    val restored = store.signaturesPage("opaque-source", "test-decode.1", 0uL, 256u, cancel)
                    assertEquals(1, restored.size)
                    assertTrue(store.signaturesPage("opaque-source", "test-decode.1", 1uL, 256u, cancel).isEmpty())
                    try {
                        store.signaturesPage("opaque-source", "test-decode.1", 0uL, 257u, cancel)
                        fail("oversized metadata page accepted")
                    } catch (_: BridgeException.InvalidBuffer) { }
                    assertEquals(fingerprint.edgeDetail.toBits(), restored[0].fingerprint.edgeDetail.toBits())
                    assertEquals(metadata.captureDate, restored[0].captureDate)
                    assertArrayEquals(sample, store.sample(asset, "nanosecond-revision", "test-decode.1"))
                    assertNull(store.sample(asset, "changed", "test-decode.1"))
                    cancel.cancel()
                    try {
                        store.finish(emptyList(), emptyList(), cancel)
                        fail("cancelled finish pruned the cache")
                    } catch (_: BridgeException.Cancelled) { }
                    assertArrayEquals(sample, store.sample(asset, "nanosecond-revision", "test-decode.1"))
                    store.clear()
                    assertNull(store.sample(asset, "nanosecond-revision", "test-decode.1"))
                    assertEquals("independent protection data", review.readText())
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }
}
