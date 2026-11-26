package org.albumwinnow.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PixelContractTest {
    @Test fun fixedPixelsMatchTheFrozenSwiftReference() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val reference = JSONObject(assets.open("swift-v1-fingerprints.json").bufferedReader().use { it.readText() })
        val rows = reference.getJSONArray("images")
        CancellationHandle().use { handle ->
            repeat(rows.length()) { index ->
                val row = rows.getJSONObject(index)
                val pixels = assets.open(row.getString("pixels")).use { it.readBytes() }
                val result = handle.fingerprintPixels(PixelInput(128u, 128u, 512u, pixels, "apple.imageio.v1.reference"))
                assertEquals(row.getString("name"), row.getString("phash"), result.perceptualHash.toString())
                assertEquals(row.getString("name"), row.getString("dhash"), result.differenceHash.toString())
                val mean = row.getJSONArray("mean_rgba")
                repeat(4) { channel -> assertEquals(mean.getInt(channel), result.meanRgba[channel].toInt() and 255) }
                assertEquals(row.getDouble("edge_detail"), result.edgeDetail, reference.getDouble("metric_absolute_tolerance"))
            }
        }
    }

    @Test fun malformedInputsAndStreamingHash() {
        CancellationHandle().use { cancel ->
            try {
                cancel.fingerprintPixels(PixelInput(UInt.MAX_VALUE, UInt.MAX_VALUE, UInt.MAX_VALUE, byteArrayOf(0), "reference"))
                fail("invalid pixels accepted")
            } catch (_: BridgeException.InvalidPixels) { }
            try {
                roundTrip(BridgeProbe(0u, Double.NaN, BridgeIdentity("a", "b", null)))
                fail("NaN accepted")
            } catch (_: BridgeException.InvalidValue) { }
            ByteHasher(cancel).use { hasher ->
                hasher.update("a".toByteArray())
                hasher.update("bc".toByteArray())
                assertEquals("6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
                    hasher.digest().joinToString("") { "%02x".format(it.toInt() and 255) })
                cancel.cancel()
                try {
                    hasher.digest()
                    fail("cancelled digest accepted")
                } catch (_: BridgeException.Cancelled) { }
            }
        }
    }
}
