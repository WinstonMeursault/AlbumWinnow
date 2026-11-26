package org.albumwinnow.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SceneDifferenceTest {
    @Test fun frozenDifferenceRegionsAndUnavailableReasonsMatch() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val reference = JSONObject(assets.open("difference/reference.json").bufferedReader().use { it.readText() })
        fun pixels(name: String) = PixelInput(256u, 256u, 1024u, assets.open("difference/$name").use { it.readBytes() }, "apple-reference-v1")
        CancellationHandle().use { cancel ->
            val cases = reference.getJSONArray("cases")
            repeat(cases.length()) { index ->
                val pair = cases.getJSONObject(index)
                val result = cancel.photoDifference(pixels(pair.getString("first")), pair.getInt("first_width").toUInt(), pair.getInt("first_height").toUInt(),
                    pixels(pair.getString("second")), pair.getInt("second_width").toUInt(), pair.getInt("second_height").toUInt())
                val reason = when (result.unavailable) {
                    CoreDifferenceUnavailable.GEOMETRY -> "geometry"
                    CoreDifferenceUnavailable.INSUFFICIENT_DETAIL -> "insufficientDetail"
                    CoreDifferenceUnavailable.ALIGNMENT -> "alignment"
                    null -> null
                }
                assertEquals(if (pair.isNull("unavailable")) null else pair.getString("unavailable"), reason)
                val expected = pair.getJSONArray("regions")
                assertEquals(expected.length(), result.regions.size)
                result.regions.forEachIndexed { i, actual ->
                    val row = expected.getJSONObject(i)
                    assertEquals(row.getDouble("x"), actual.x, 0.0)
                    assertEquals(row.getDouble("y"), actual.y, 0.0)
                    assertEquals(row.getDouble("width"), actual.width, 0.0)
                    assertEquals(row.getDouble("height"), actual.height, 0.0)
                }
            }
        }
    }

    // This supplies controlled distances, not an Android implementation of Apple Vision.
    @Test fun controlledProviderKeepsCliqueAndRejectsStaleCallbacks() {
        assertNull(SmokeCapabilities.sceneProvider)
        val provider = CoreSceneProvider("controlled-test", "1", "fixed", "tests-only")
        fun item(id: String) = CoreSceneAsset(CoreAssetKey("controlled", id), "revision", provider,
            CoreSceneQuality(0.5, 0.1, 0.01, 0.0, 0.0), listOf(1u.toUShort(), 2u.toUShort(), 3u.toUShort(), 4u.toUShort()),
            512u, 384u, 8u.toUShort(), false, 1.0, false, null, null, null)
        CancellationHandle().use { cancel ->
            RustSceneSession("scene", provider, null, null, cancel).use { session ->
                session.appendPrepared(listOf(item("c"), item("a"), item("b")))
                session.completePreparation()
                while (true) {
                    val request = session.nextWork().request ?: break
                    try {
                        session.submitDistance("old", request.taskId, 0f)
                        fail("stale operation accepted")
                    } catch (_: BridgeException.StaleOperation) { }
                    val distance = if (request.first.itemId == "c" && request.second.itemId == "a") 0.25f else 0.1f
                    session.submitDistance("scene", request.taskId, distance)
                    try {
                        session.submitDistance("scene", request.taskId, distance)
                        fail("duplicate callback accepted")
                    } catch (_: BridgeException.StaleOperation) { }
                }
                val groups = session.groups()
                assertEquals(1, groups.size)
                assertEquals(listOf("a", "b"), groups[0].members.map { it.itemId })
                session.cancel()
                try {
                    session.nextWork()
                    fail("cancel ignored")
                } catch (_: BridgeException.Cancelled) { }
            }
        }
    }
}
