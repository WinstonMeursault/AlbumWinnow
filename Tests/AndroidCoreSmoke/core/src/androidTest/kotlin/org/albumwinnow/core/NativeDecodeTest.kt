package org.albumwinnow.core

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeDecodeTest {
    // Test-only adapter. getPixels returns unpremultiplied ARGB values; convert
    // each component explicitly instead of treating Bitmap storage as RGBA.
    private fun normalized(bitmap: Bitmap): ByteArray {
        val argb = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(argb, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val rgba = ByteArray(argb.size * 4)
        argb.forEachIndexed { index, value ->
            val alpha = value ushr 24
            rgba[index * 4] = (((value ushr 16 and 255) * alpha + 127) / 255).toByte()
            rgba[index * 4 + 1] = (((value ushr 8 and 255) * alpha + 127) / 255).toByte()
            rgba[index * 4 + 2] = (((value and 255) * alpha + 127) / 255).toByte()
            rgba[index * 4 + 3] = alpha.toByte()
        }
        return rgba
    }

    @Test fun bundledPngAndJpegDecodeIntoExplicitNormalizedPixels() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        CancellationHandle().use { handle ->
            for (name in listOf("decode/alpha.png", "decode/color.jpg")) {
                val options = BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                    inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
                    inPremultiplied = true
                }
                val bitmap = assets.open(name).use { BitmapFactory.decodeStream(it, null, options) }!!
                try {
                    assertEquals(128, bitmap.width)
                    assertEquals(128, bitmap.height)
                    val bytes = normalized(bitmap)
                    if (name.endsWith("alpha.png")) {
                        assertEquals(128, bytes[3].toInt() and 255)
                        assertEquals(100, bytes[0].toInt() and 255)
                        assertEquals(40, bytes[1].toInt() and 255)
                        assertEquals(10, bytes[2].toInt() and 255)
                        assertEquals(255, bytes[127 * 4 + 3].toInt() and 255)
                    }
                    val input = PixelInput(128u, 128u, 512u, bytes, "android.bitmap.srgb.premul.v1")
                    val first = handle.fingerprintPixels(input)
                    val repeated = handle.fingerprintPixels(input)
                    assertEquals(first.perceptualHash, repeated.perceptualHash)
                    assertEquals(first.differenceHash, repeated.differenceHash)
                    assertArrayEquals(first.meanRgba, repeated.meanRgba)
                    assertEquals(first.edgeDetail, repeated.edgeDetail, 0.0)
                } finally {
                    bitmap.recycle()
                }
            }
        }
    }
}
