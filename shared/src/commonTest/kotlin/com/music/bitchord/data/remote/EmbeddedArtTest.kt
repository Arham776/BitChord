package com.music.bitchord.data.remote

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Finding a cover inside a file, through ranged reads.
 *
 * Every fixture here is a real tag built byte by byte, because the alternative — a
 * fixture of bytes that only looks like a tag — is how a parser passes its tests and
 * then reads nothing at all. The builders below write the same structure a tagger
 * writes, in the same byte order, and the assertions are about the *picture* that
 * comes out rather than about the parser taking a branch.
 *
 * The reader is a fake that records what was asked of it, so the "never reads the
 * whole file" claim is checked rather than asserted in a comment.
 */
class EmbeddedArtTest {

    // ---- A reader over a fixed file ---------------------------------------

    private class FakeReader(override val size: Long, private val bytes: ByteArray) : EmbeddedArt.Reader {
        val requests = mutableListOf<Pair<Long, Int>>()

        override suspend fun read(offset: Long, length: Int): ByteArray {
            requests += offset to length
            if (offset >= bytes.size || offset < 0 || length <= 0) return ByteArray(0)
            val from = offset.toInt()
            val to = minOf(from + length, bytes.size)
            return if (to <= from) ByteArray(0) else bytes.copyOfRange(from, to)
        }
    }

    private fun reader(bytes: ByteArray) = FakeReader(bytes.size.toLong(), bytes)

    private fun at(bytes: ByteArray, offset: Int, vararg values: Int) =
        values.forEachIndexed { i, v -> bytes[offset + i] = v.toByte() }

    // ---- Fixtures ---------------------------------------------------------

    /** A FLAC file whose `PICTURE` block is the only metadata block. */
    private fun flacWithPicture(
        mime: String,
        image: ByteArray,
        afterComment: Boolean = false,
        description: String = "",
    ): ByteArray {
        val mimeBytes = mime.encodeToByteArray()
        val descriptionBytes = description.encodeToByteArray()
        // A PICTURE block: type, mime+len, description+len, then 16 bytes of
        // width/height/depth/colours, then the length and the image.
        val pictureBody = buildList {
            add(3); add(0); add(0); add(0) // picture type: front cover
            add((mimeBytes.size shr 24).toInt()); add((mimeBytes.size shr 16).toInt())
            add((mimeBytes.size shr 8).toInt()); add(mimeBytes.size.toInt())
            addAll(mimeBytes.toList())
            add((descriptionBytes.size shr 24).toInt()); add((descriptionBytes.size shr 16).toInt())
            add((descriptionBytes.size shr 8).toInt()); add(descriptionBytes.size.toInt())
            addAll(descriptionBytes.toList())
            repeat(16) { add(0) }
            add((image.size shr 24).toInt()); add((image.size shr 16).toInt())
            add((image.size shr 8).toInt()); add(image.size.toInt())
            addAll(image.toList())
        }.map { it.toByte() }.toByteArray()

        val blocks = buildList {
            if (afterComment) {
                val comment = "a fairly long Vorbis comment, padded out to be worth walking past".encodeToByteArray()
                add(byteArrayOf(0x04) + u24(comment.size) + comment)
            }
            add(byteArrayOf(0x86.toByte()) + u24(pictureBody.size) + pictureBody)
            add(byteArrayOf(0x81.toByte()) + u24(4) + byteArrayOf(1, 2, 3, 4))
        }
        return "fLaC".encodeToByteArray() + blocks.fold(byteArrayOf()) { acc, b -> acc + b }
    }

    private fun u24(value: Int) = byteArrayOf(
        ((value shr 16) and 0xFF).toByte(),
        ((value shr 8) and 0xFF).toByte(),
        (value and 0xFF).toByte(),
    )

    private fun u32be(value: Int) = byteArrayOf(
        ((value shr 24) and 0xFF).toByte(),
        ((value shr 16) and 0xFF).toByte(),
        ((value shr 8) and 0xFF).toByte(),
        (value and 0xFF).toByte(),
    )

    private val JPEG = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 1, 2, 3, 4)
    private val PNG = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 1, 2, 3, 4)

    /** An ID3v2.3 tag with one APIC frame, preceded by any frames given. */
    private fun id3v23(frames: List<ByteArray>): ByteArray {
        val body = frames.fold(byteArrayOf()) { acc, f -> acc + f }
        val header = "ID3".encodeToByteArray() + byteArrayOf(3, 0, 0) + syncsafeOf(body.size)
        return header + body
    }

    /**
     * An ID3v2.2 tag, whose frames are three-character ids with three-byte sizes.
     *
     * Only the version byte differs from [id3v23] and that byte is the whole point:
     * a `PIC` frame in a v2.3 header is read with a ten-byte frame header and comes
     * out as a length four times too big.
     */
    private fun id3v22(frames: List<ByteArray>): ByteArray {
        val body = frames.fold(byteArrayOf()) { acc, f -> acc + f }
        val header = "ID3".encodeToByteArray() + byteArrayOf(2, 0, 0) + syncsafeOf(body.size)
        return header + body
    }

    private fun apicFrame(mime: String, description: String, image: ByteArray): ByteArray {
        val payload = buildList {
            add(0) // encoding: ISO-8859-1
            addAll(mime.encodeToByteArray().toList())
            add(0)
            add(3) // picture type: front cover
            addAll(description.encodeToByteArray().toList())
            add(0)
            addAll(image.toList())
        }.toByteArray()
        return "APIC".encodeToByteArray() + u32be(payload.size) + byteArrayOf(0, 0) + payload
    }

    private fun textFrame(id: String, text: String): ByteArray {
        val payload = byteArrayOf(0) + text.encodeToByteArray()
        return id.encodeToByteArray() + u32be(payload.size) + byteArrayOf(0, 0) + payload
    }

    private fun syncsafeOf(value: Int) = byteArrayOf(
        ((value shr 21) and 0x7F).toByte(),
        ((value shr 14) and 0x7F).toByte(),
        ((value shr 7) and 0x7F).toByte(),
        (value and 0x7F).toByte(),
    )

    // ---- FLAC -------------------------------------------------------------

    @Test
    fun `a flac picture is found`() {
        val file = reader(flacWithPicture("image/jpeg", JPEG))
        val picture = assertNotNull(extract(file))
        assertEquals("image/jpeg", picture.mime)
        assertTrue(JPEG.contentEquals(picture.bytes), "the wrong picture came out")
    }

    @Test
    fun `a flac picture is found after another block`() {
        // The walk has to step over a block it does not want, and a step is a seek
        // rather than a read.
        val file = reader(flacWithPicture("image/png", PNG, afterComment = true))
        val picture = assertNotNull(extract(file))
        assertTrue(PNG.contentEquals(picture.bytes))
    }

    @Test
    fun `a flac picture is found whatever its declared type says`() {
        // A tag that says PNG and holds a JPEG is common, and the declared type wins
        // because a tag is right more often than a sniffer is.
        val file = reader(flacWithPicture("image/png", JPEG))
        assertEquals("image/png", assertNotNull(extract(file)).mime)
    }

    @Test
    fun `a flac with no picture block is no picture`() {
        val file = "fLaC".encodeToByteArray() + byteArrayOf(0x81.toByte()) + u24(4) + byteArrayOf(1, 2, 3, 4)
        assertNull(extract(reader(file)))
    }

    // ---- ID3 --------------------------------------------------------------

    @Test
    fun `an id3v2 picture is found`() {
        val file = reader(id3v23(listOf(apicFrame("image/png", "cover", PNG))))
        val picture = assertNotNull(extract(file))
        assertEquals("image/png", picture.mime)
        assertTrue(PNG.contentEquals(picture.bytes))
    }

    @Test
    fun `a picture is found after other frames`() {
        // The frames before it are the reason the walk has to be exact: a length read
        // one byte off lands the next frame in the wrong place.
        val file = reader(
            id3v23(
                listOf(
                    textFrame("TIT2", "A Title"),
                    textFrame("TPE1", "An Artist"),
                    apicFrame("image/jpeg", "", JPEG),
                    textFrame("TALB", "An Album"),
                )
            )
        )
        val picture = assertNotNull(extract(file))
        assertTrue(JPEG.contentEquals(picture.bytes))
    }

    @Test
    fun `an id3v2 tag with a utf-16 description is read`() {
        // UTF-16 terminates on a two-byte zero, and the terminator is aligned to the
        // description's start — a scan that advanced one byte at a time would find a
        // zero in the middle of a character and cut the picture in half.
        val payload = buildList {
            add(1) // encoding: UTF-16, which is what makes the terminator two bytes
            addAll("image/jpeg".encodeToByteArray().toList())
            add(0)
            add(3)
            add(0xFF.toByte()); add(0xFE) // BOM
            add('A'.code.toByte()); add(0)
            add(0); add(0) // UTF-16 NUL
            addAll(JPEG.toList())
        }.map { it.toByte() }.toByteArray()
        val frame = "APIC".encodeToByteArray() + u32be(payload.size) + byteArrayOf(0, 0) + payload
        val picture = assertNotNull(extract(reader(id3v23(listOf(frame)))))
        assertTrue(JPEG.contentEquals(picture.bytes))
    }

    @Test
    fun `a picture in a v2 2 tag is read`() {
        // v2.2's PIC has no MIME string: three letters of format, and a one-byte
        // description.
        val payload = buildList {
            add(0)
            addAll("JPG".encodeToByteArray().toList())
            add(3)
            add(0)
            addAll(JPEG.toList())
        }.map { it.toByte() }.toByteArray()
        val frame = "PIC".encodeToByteArray() + u24(payload.size) + payload
        val picture = assertNotNull(extract(reader(id3v22(listOf(frame)))))
        assertEquals("image/jpeg", picture.mime)
        assertTrue(JPEG.contentEquals(picture.bytes))
    }

    @Test
    fun `an id3 tag with no picture is no picture`() {
        assertNull(extract(reader(id3v23(listOf(textFrame("TIT2", "A Title"))))))
    }

    // ---- MP4 --------------------------------------------------------------

    @Test
    fun `an mp4 cover is found`() {
        val file = reader(mp4Chain(cover = dataBox(13, JPEG)))
        val picture = assertNotNull(extract(file))
        assertEquals("image/jpeg", picture.mime)
        assertTrue(JPEG.contentEquals(picture.bytes))
    }

    @Test
    fun `an mp4 cover with no declared type is sniffed`() {
        val file = reader(mp4Chain(cover = dataBox(0, PNG)))
        assertEquals("image/png", assertNotNull(extract(file)).mime)
    }

    private fun mp4Chain(cover: ByteArray): ByteArray {
        val ilst = box("ilst", box("covr", cover))
        // `meta` is a full box: four version/flags bytes before its children.
        val meta = box("meta", byteArrayOf(0, 0, 0, 0) + box("hdlr", ByteArray(0)) + ilst)
        val udta = box("udta", meta)
        val moov = box("moov", box("mvhd", ByteArray(4)) + udta)
        return box("ftyp", "M4A ".encodeToByteArray()) + moov
    }

    private fun box(type: String, body: ByteArray): ByteArray {
        val size = 8 + body.size
        return u32be(size) + type.encodeToByteArray() + body
    }

    /**
     * A `data` box: four bytes of type indicator, four of locale, then the bytes.
     *
     * The type indicator is the version and flags word a full box carries, and it is
     * what says 13 for JPEG and 14 for PNG. A zero one is how "no declared type" is
     * written — the field is never left out.
     */
    private fun dataBox(kind: Int, image: ByteArray) = box("data", u32be(kind) + u32be(0) + image)

    // ---- The promises, checked -------------------------------------------

    @Test
    fun `a file with no recognisable header is no picture`() {
        assertNull(extract(reader(ByteArray(64) { it.toByte() })))
    }

    @Test
    fun `a file too short to identify is no picture rather than a failure`() {
        assertNull(extract(reader("fLaC".encodeToByteArray())))
        assertNull(extract(reader(ByteArray(0))))
    }

    @Test
    fun `a file that is nothing but a header is no picture`() {
        // A truncated upload, a server that answered 200 to a range it did not
        // honour, a file still being written to a share.
        assertNull(extract(reader("fLaC".encodeToByteArray() + ByteArray(4))))
    }

    @Test
    fun `a reader that throws does not take the caller with it`() {
        // A missing cover must never fail whatever asked for one.
        val broken = object : EmbeddedArt.Reader {
            override val size: Long = 1_000
            override suspend fun read(offset: Long, length: Int): ByteArray = throw IllegalStateException("gone")
        }
        assertNull(extract(broken))
    }

    @Test
    fun `a server that answers in small pieces still yields a cover`() {
        // A server that caps range responses, or a proxy in front of one. Short reads
        // are ordinary; what is not ordinary is treating one as a failure — so this
        // caps every answer at 32 bytes, which is not even enough for the fixed part
        // of a PICTURE block, and asks for a cover anyway.
        val whole = flacWithPicture("image/jpeg", JPEG, afterComment = true)
        val capped = object : EmbeddedArt.Reader {
            override val size: Long = whole.size.toLong()
            override suspend fun read(offset: Long, length: Int): ByteArray {
                if (offset < 0 || offset >= whole.size || length <= 0) return ByteArray(0)
                val from = offset.toInt()
                return whole.copyOfRange(from, minOf(from + minOf(length, 32), whole.size))
            }
        }
        assertTrue(JPEG.contentEquals(assertNotNull(extract(capped)).bytes))
    }

    @Test
    fun `a flac picture with a sentence for a description is found`() {
        // The description sits between the MIME string and the picture's length, so
        // a long one pushes the length out of the window this reads first. Taggers
        // write real sentences there, so the cost of one is a second request.
        val file = reader(flacWithPicture("image/jpeg", JPEG, description = "Cover art, front, please"))
        assertTrue(JPEG.contentEquals(assertNotNull(extract(file)).bytes))
    }

    @Test
    fun `the whole file is never read for a cover`() {
        // The claim that makes a remote library usable: a hundred-megabyte FLAC costs
        // a few kilobytes to find its cover, so a share of five hundred of them does
        // not cost a hundred gigabytes to browse.
        val file = reader(flacWithPicture("image/jpeg", JPEG, afterComment = true))
        assertNotNull(extract(file))
        val biggest = file.requests.maxOf { it.second.toLong() }
        assertTrue(biggest <= 64 * 1024, "asked for $biggest bytes at once")
        assertTrue(file.requests.size <= 4, "${file.requests.size} requests for one cover")
    }

    @Test
    fun `nothing is read past the end of the file`() {
        val file = reader(flacWithPicture("image/jpeg", JPEG))
        assertNotNull(extract(file))
        file.requests.forEach { (offset, length) ->
            assertTrue(offset <= file.size, "read at $offset of ${file.size}")
            assertTrue(offset + length <= maxOf(file.size, 64 * 1024), "read $length at $offset")
        }
    }

    // ---- The type --------------------------------------------------------

    @Test
    fun `a picture with no declared type is sniffed`() {
        assertEquals("image/jpeg", sniff(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0, 0)))
        assertEquals("image/png", sniff(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47)))
        assertEquals("image/gif", sniff("GIF8".encodeToByteArray()))
        assertEquals("image/bmp", sniff("BM".encodeToByteArray()))
        assertEquals("image/webp", sniff("RIFF\u0000\u0000\u0000\u0000WEBPVP8 ".encodeToByteArray()))
    }

    @Test
    fun `bytes that are not a picture at all are given the common default`() {
        // A tag that says nothing and bytes that are nothing recognisable: a JPEG is
        // far more often right than refusing, and an image loader copes either way.
        assertEquals("image/jpeg", sniff(byteArrayOf(9, 9, 9, 9)))
    }

    /**
     * [EmbeddedArt.extract] on a test runtime.
     *
     * The parser suspends — a read over a network is not something a byte array can
     * promise — and Kotlin/Native's `kotlin.test` will not run a suspending test
     * function, so every case goes through here rather than each one growing its own
     * `runTest`. `runTest` answers `Unit`, hence the variable.
     */
    private fun extract(reader: EmbeddedArt.Reader): EmbeddedArt.Picture? {
        var picture: EmbeddedArt.Picture? = null
        runTest { picture = EmbeddedArt.extract(reader) }
        return picture
    }

    private fun sniff(bytes: ByteArray): String {
        // Through a FLAC frame, since that is the only place the fallback is reachable.
        val file = reader(flacWithPicture("", bytes))
        return assertNotNull(extract(file)).mime
    }
}
