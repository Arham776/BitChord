package com.music.bitchord.data.innertube

/**
 * SHA-1 in pure Kotlin, for the SAPISIDHASH `Authorization` header.
 *
 * commonMain has no `java.security.MessageDigest`, and pulling a crypto
 * dependency in for one digest is heavier than the digest itself. SHA-1 is
 * collision-broken for security purposes and perfectly fine for this one:
 * Google's header scheme specifies it, so it is not our algorithm to choose.
 */
internal object Sha1 {

    fun hex(input: ByteArray): String {
        val digest = digest(input)
        return digest.joinToString("") { byte ->
            val v = byte.toInt() and 0xFF
            HEX[v ushr 4].toString() + HEX[v and 0x0F].toString()
        }
    }

    private const val HEX = "0123456789abcdef"

    private fun digest(input: ByteArray): ByteArray {
        // Pre-processing: pad to a multiple of 64 bytes.
        val bitLen = input.size.toLong() * 8
        val padded = ArrayList<Byte>(input.size + 72)
        padded.addAll(input.toList())
        padded.add(0x80.toByte())
        while (padded.size % 64 != 56) padded.add(0)
        for (shift in 56 downTo 0 step 8) padded.add((bitLen ushr shift).toByte())

        var h0 = 0x67452301.toInt()
        var h1 = 0xEFCDAB89.toInt()
        var h2 = 0x98BADCFE.toInt()
        var h3 = 0x10325476
        var h4 = 0xC3D2E1F0.toInt()
        val w = IntArray(80)

        var offset = 0
        while (offset < padded.size) {
            for (i in 0 until 16) {
                w[i] = ((padded[offset + i * 4].toInt() and 0xFF) shl 24) or
                    ((padded[offset + i * 4 + 1].toInt() and 0xFF) shl 16) or
                    ((padded[offset + i * 4 + 2].toInt() and 0xFF) shl 8) or
                    (padded[offset + i * 4 + 3].toInt() and 0xFF)
            }
            for (i in 16 until 80) {
                val x = w[i - 3] xor w[i - 8] xor w[i - 14] xor w[i - 16]
                w[i] = (x shl 1) or (x ushr 31)
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            for (i in 0 until 80) {
                val (f, k) = when {
                    i < 20 -> ((b and c) or (b.inv() and d)) to 0x5A827999
                    i < 40 -> (b xor c xor d) to 0x6ED9EBA1
                    i < 60 -> ((b and c) or (b and d) or (c and d)) to 0x8F1BBCDC.toInt()
                    else -> (b xor c xor d) to 0xCA62C1D6.toInt()
                }
                val temp = ((a shl 5) or (a ushr 27)) + f + e + k + w[i]
                e = d
                d = c
                c = (b shl 30) or (b ushr 2)
                b = a
                a = temp
            }

            h0 += a
            h1 += b
            h2 += c
            h3 += d
            h4 += e
            offset += 64
        }

        val out = ByteArray(20)
        listOf(h0, h1, h2, h3, h4).forEachIndexed { i, h ->
            out[i * 4] = (h ushr 24).toByte()
            out[i * 4 + 1] = (h ushr 16).toByte()
            out[i * 4 + 2] = (h ushr 8).toByte()
            out[i * 4 + 3] = h.toByte()
        }
        return out
    }
}
