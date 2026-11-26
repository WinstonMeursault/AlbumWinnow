package org.albumwinnow.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BridgeSmokeTest {
    @Test fun cancellationRunsConcurrentlyWithHashing() {
        CancellationHandle().use { handle ->
            val started = java.util.concurrent.CountDownLatch(1)
            val observed = java.util.concurrent.atomic.AtomicBoolean(false)
            val worker = Thread {
                try {
                    val bytes = ByteArray(4 * 1024 * 1024) { 19 }
                    repeat(10000) {
                        handle.hashBuffer(bytes)
                        started.countDown()
                    }
                } catch (_: BridgeException.Cancelled) {
                    observed.set(true)
                } finally {
                    started.countDown()
                }
            }
            worker.start()
            assertTrue(started.await(10, java.util.concurrent.TimeUnit.SECONDS))
            val start = System.nanoTime()
            handle.cancel()
            worker.join(500)
            assertFalse("cancel did not stop worker", worker.isAlive)
            assertTrue(observed.get())
            assertTrue(System.nanoTime() - start < 500_000_000L)
        }
    }

    @Test fun typesHashErrorsCancellationAndRelease() {
        assertEquals("2.0.0", coreVersion())
        assertTrue(sqliteProbe().isNotEmpty())
        val probe = BridgeProbe(ULong.MAX_VALUE, null, BridgeIdentity("source-v2", "opaque:照片/é", null))
        assertEquals(probe, roundTrip(probe))
        assertEquals(BridgeProbe(0u, -0.25, BridgeIdentity("", "", "nanoseconds:123456789")),
            roundTrip(BridgeProbe(0u, -0.25, BridgeIdentity("", "", "nanoseconds:123456789"))))
        CancellationHandle().use { handle ->
            assertEquals("6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
                handle.hashBuffer("abc".toByteArray()))
            try {
                handle.hashBuffer(ByteArray(4 * 1024 * 1024 + 1))
                fail("oversized buffer accepted")
            } catch (_: BridgeException.InvalidBuffer) { }
            handle.cancel()
            handle.cancel()
            try {
                handle.hashBuffer(byteArrayOf())
                fail("cancelled operation succeeded")
            } catch (_: BridgeException.Cancelled) { }
        }
        repeat(1000) {
            CancellationHandle().use { assertEquals(64, it.hashBuffer(byteArrayOf()).length) }
        }
    }
}
