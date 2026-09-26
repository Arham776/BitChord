package com.music.bitchord.data.remote

/**
 * Cover pictures embedded in audio files, read through bounded ranged access
 * instead of downloading whole tracks.
 *
 * Port of upstream `data/remote/EmbeddedArt.kt`. This is the piece that makes a
 * remote library feel like a library rather than a list of filenames: a WebDAV share
 * is very often untagged, with the picture living inside the file, and without this
 * every row is a grey box.
 *
 * ## What it never does
 *
 * It never throws and never reads the whole file. Both are load-bearing:
 *
 * - **No throwing.** A missing cover must not fail whatever asked for one. Every
 *   path out of here is a null, including for a file that is encrypted, truncated,
 *   tagged in a dialect this does not know, or has a picture larger than
 *   [MAX_PICTURE_BYTES].
 * - **No whole-file reads.** A FLAC can be a hundred megabytes, and a library of
 *   five hundred of them is a few tens of gigabytes. Only tag regions are ever
 *   touched, through a [Cursor] that keeps one 64 KiB window, so the cost of a cover
 *   is a handful of ranged requests whatever the file's size.
 *
 * ## Formats
 *
 * ID3v2 (v2.2's `PIC` and v2.3/v2.4's `APIC`), FLAC's `PICTURE` metadata block,
 * MP4/M4A's `moov→udta→meta→ilst→covr`, and Vorbis/Opus comments carrying a
 * base64 FLAC picture block.
 *
 * WAV is deliberately unsupported: its metadata lives in RIFF chunks that a good
 * number of players ignore outright, so a cover found there would be found on this
 * device and nowhere else.
 */
object EmbeddedArt {

    /**
     * A picture, and what it claims to be.
     *
     * The claim is only a claim: [extract] sniffs the bytes and prefers what the tag
     * said, but a tag that lies gets a picture decoded as something it is not, and
     * the sniffing exists to stop a mislabelled PNG being drawn as a broken JPEG.
     */
    data class Picture(val bytes: ByteArray, val mime: String) {
        // ByteArray needs these said out loud, and the data class would otherwise
        // compare two pictures of the same bytes as different.
        override fun equals(other: Any?): Boolean =
            other is Picture && mime == other.mime && bytes.contentEquals(other.bytes)

        override fun hashCode(): Int = 31 * bytes.contentHashCode() + mime.hashCode()
    }

    /**
     * Random access into a file.
     *
     * HTTP ranges and shared file offsets are both just `(offset, length)` reads
     * here, which is what lets one parser serve every backend.
     *
     * [read] is **suspending** rather than blocking, and that is not decoration. A
     * backend that reads over the network has nothing synchronous to give: the only
     * alternatives are a blocking bridge on a thread this platform does not have, or
     * a parser split across a state machine so that every `await` is somebody else's
     * problem. `suspend` costs one keyword per walk step and keeps the parsers
     * readable, and the walks are four or five reads deep.
     */
    interface Reader {
        /** The file's length, or [UNKNOWN_SIZE] when the server will not say. */
        val size: Long

        /**
         * Up to [length] bytes from [offset], anchored at [offset].
         *
         * May return **fewer** bytes than asked for, and that is not an error: a
         * server that ignores `Range` answers 200 with the whole file, and the
         * backend has to cope with a short read rather than with a failure it cannot
         * distinguish from a truncated one.
         */
        suspend fun read(offset: Long, length: Int): ByteArray
    }

    const val UNKNOWN_SIZE: Long = Long.MAX_VALUE

    /**
     * The largest single picture kept.
     *
     * Phone screens do not need more, and a tag can claim a hundred megabytes of
     * picture that is really the audio.
     */
    const val MAX_PICTURE_BYTES: Int = 8 * 1024 * 1024

    /** The largest tag region walked before giving up on a file. */
    internal const val MAX_WALK_BYTES: Long = 16L * 1024 * 1024

    /**
     * The picture in this file, or null.
     *
     * Dispatched on the first twelve bytes: `ID3`, `fLaC`, an MP4 `ftyp` at offset 4,
     * or `OggS`. Twelve rather than four because the shortest of those magics sits at
     * offset four, and a file shorter than that cannot be any of them.
     */
    suspend fun extract(reader: Reader): Picture? = runCatching { extractOrNull(reader) }.getOrNull()

    private suspend fun extractOrNull(reader: Reader): Picture? {
        val magic = reader.read(0, 12)
        if (magic.size < 12) return null
        return when {
            magic[0] == 'I'.code.toByte() && magic[1] == 'D'.code.toByte() && magic[2] == '3'.code.toByte() ->
                id3(reader, magic)
            // `fLaC` is three bytes past the `f`, and an MP4's `ftyp` is four.
            magic[0] == 'f'.code.toByte() && string(magic, 1, 4) == "LaC" -> flac(reader)
            string(magic, 4, 8) == "ftyp" -> mp4(reader)
            string(magic, 0, 3) == "OggS" -> ogg(reader)
            else -> null
        }
    }

    // ---- ID3v2 ----------------------------------------------------------

    /**
     * `fLaC`, then a chain of metadata blocks until a `last` one.
     *
     * The picture is a metadata block like any other, so this is the same walk in
     * every format: read a four-byte header, and either handle the block or step over
     * it. The step is a *seek* rather than a read, so a file with a large comment
     * before its picture costs one request rather than one per block.
     */
    private suspend fun flac(reader: Reader): Picture? {
        val cursor = Cursor(reader)
        cursor.skip(4)
        var walked = 0L
        while (true) {
            val head = cursor.bytes(4)
            if (head.size < 4) return null
            val isLast = (head[0].toInt() and 0x80) != 0
            val type = head[0].toInt() and 0x7F
            val length = u24(head, 1).toLong()
            if (length < 0 || length > MAX_PICTURE_BYTES + 1024L) return null
            walked += 4
            if (walked > MAX_WALK_BYTES) return null
            if (type == 6) return flacPicture(reader, cursor.position, length.toInt())
            cursor.skip(length)
            if (isLast) return null
        }
    }

    /**
     * A `PICTURE` block body: a fixed header, then the image at a known extent.
     *
     * Only the first 64 bytes are read, because everything before the image is
     * lengths and four fixed fields — the description, width, height, depth and
     * colour count are read past without being kept, and a 60-character description
     * is not worth a whole block's worth of reading.
     */
    internal suspend fun flacPicture(reader: Reader, at: Long, length: Int): Picture? {
        val head = reader.read(at, minOf(length, 64))
        if (head.size < 8) return null
        var pos = 0
        pos += 4 // picture type
        val mimeLen = u32(head, pos); pos += 4
        if (mimeLen < 0 || pos + mimeLen > head.size) return null
        val declaredMime = string(head, pos, pos + mimeLen); pos += mimeLen
        val descLen = u32(head, pos); pos += 4
        if (descLen < 0) return null
        // The picture's own length sits sixteen bytes past the description — width,
        // height, depth and colour count in between — and the picture follows it.
        // A description longer than the window above therefore costs one extra read
        // rather than a refusal: taggers write real sentences there, and a sixty-
        // character description is not a broken tag.
        val lengthAt = at + pos + descLen + 16
        val dataLen = if (pos + descLen + 20 <= head.size) u32(head, pos + descLen + 16)
        else u32(reader.read(lengthAt, 4), 0)
        if (dataLen <= 0 || dataLen > MAX_PICTURE_BYTES) return null
        val bytes = reader.read(lengthAt + 4, dataLen)
        if (bytes.size != dataLen) return null
        return picture(bytes, declaredMime)
    }

    /**
     * `ID3`, then frames.
     *
     * The whole tag is read in one go, which is a decision worth stating: it is
     * bounded by [MAX_WALK_BYTES], and a tag is small by construction — the ones
     * that are not are the ones this gives up on anyway. Reading it whole means every
     * frame boundary is exact, which is what stops a malformed frame from making this
     * walk the rest of a megabyte of nonsense looking for a picture.
     */
    private suspend fun id3(reader: Reader, magic: ByteArray): Picture? {
        val version = magic[3].toInt() and 0xFF
        if (version !in 2..4) return null
        val unsynchronised = (magic[5].toInt() and 0x80) != 0
        val tagSize = syncsafe(magic, 6)
        if (tagSize <= 0 || tagSize > MAX_WALK_BYTES) return null
        var tag = reader.read(10, tagSize)
        if (tag.size < tagSize) return null
        if (unsynchronised) tag = deunsync(tag)

        var pos = 0
        // An extended header's declared size counts itself on v2.3 and not on v2.4,
        // and both conventions ship in the wild — so try each, plus the two fixed
        // sizes, and take the first offset where what follows parses as frames.
        if ((magic[5].toInt() and 0x40) != 0) {
            val declared = if (version == 4) syncsafe(tag, 0) else u32(tag, 0)
            pos = listOf(declared, declared - 4, 6, 10)
                .firstOrNull { it in 0..tag.size && framesStart(tag, it, version) } ?: return null
        }

        val idLength = if (version == 2) 3 else 4
        val headLength = if (version == 2) 6 else 10
        while (pos + headLength <= tag.size) {
            val id = string(tag, pos, pos + idLength)
            if (id.isEmpty() || id.all { it == '\u0000' }) break
            val isPicture = if (version == 2) id == "PIC" else id == "APIC"
            val size = when {
                version == 2 -> u24(tag, pos + 3)
                version == 4 -> syncsafe(tag, pos + 4)
                else -> u32(tag, pos + 4)
            }
            // Padding, or a frame this walk cannot trust. Either way the tag has
            // nothing more to say from here.
            if (size <= 0 || pos + headLength + size > tag.size || !id.all { it.isLetterOrDigit() }) {
                if (!isPicture) break
                return null
            }
            if (isPicture) {
                // The first picture frame decides, and if it does not parse this
                // stops rather than scanning on: a second APIC in a valid tag is
                // rarer than a malformed first one, and a wrong answer is worse than
                // none.
                val payload = tag.copyOfRange(pos + headLength, pos + headLength + size)
                return pictureFromApic(payload, version)
            }
            pos += headLength + size
        }
        return null
    }

    /** Whether frames plausibly start at [at]. */
    private fun framesStart(tag: ByteArray, at: Int, version: Int): Boolean {
        if (at + 4 > tag.size) return false
        val next = tag.copyOfRange(at, at + 4)
        // All zeroes is padding; four alphanumerics is a frame id.
        if (next.all { it.toInt() == 0 }) return true
        return next.all { it.toInt().toChar().isLetterOrDigit() }
    }

    /**
     * Undo ID3 unsynchronisation: `FF 00` is a literal `FF`.
     *
     * Applied to the whole tag *before* the frame walk rather than to each payload,
     * and the reason is the order of those two operations. Frame sizes count stored
     * bytes, so boundaries stay exact only if the sizes are read from the unsynced
     * form; de-unsynchronising payloads as they are found instead drifts every frame
     * after the first stuffed byte.
     */
    private fun deunsync(bytes: ByteArray): ByteArray {
        if (bytes.size < 2) return bytes
        val out = ByteArray(bytes.size)
        var read = 0
        var written = 0
        while (read < bytes.size) {
            val byte = bytes[read]
            out[written++] = byte
            read++
            // 0xFF 0x00 was one 0xFF on the way in.
            if (byte.toInt() and 0xFF == 0xFF && read < bytes.size && bytes[read].toInt() == 0) read++
        }
        return out.copyOf(written)
    }

    /**
     * The image inside an `APIC` or `PIC` frame.
     *
     * v2.2's `PIC` names its format as three letters and has no MIME string; v2.3 and
     * v2.4 have a NUL-terminated MIME string. The description that follows is
     * terminated differently by the frame's text encoding, which is the byte before
     * it all in v2.2 and after the MIME in v2.4.
     */
    private fun pictureFromApic(payload: ByteArray, version: Int): Picture? {
        if (payload.size < 6) return null
        return if (version == 2) {
            // encoding(1) + format(3) + type(1) + description + data
            val format = string(payload, 1, 4).uppercase()
            val mime = if (format == "PNG") "image/png" else "image/jpeg"
            var at = 5
            at = skipNull(payload, at, 1) ?: return null
            picture(payload.copyOfRange(at, payload.size), mime)
        } else {
            var at = 1
            val mimeEnd = payload.indexOfFirstNul(from = at) ?: return null
            val mime = string(payload, at, mimeEnd)
            at = mimeEnd + 1
            if (at >= payload.size) return null
            at += 1 // picture type
            val encoding = payload[0].toInt() and 0xFF
            at = skipNull(payload, at, if (encoding == 1 || encoding == 2) 2 else 1) ?: return null
            picture(payload.copyOfRange(at, payload.size), mime)
        }
    }

    /**
     * Step over a NUL-terminated description.
     *
     * UTF-16 encodings (1 and 2) terminate on a two-byte zero, and their terminator
     * is aligned to the description's start — so the scan advances by two at a time
     * once it is past the first byte, or it would find a zero in the middle of a
     * character's second byte and cut the description in half.
     */
    private fun skipNull(bytes: ByteArray, from: Int, width: Int): Int? {
        var i = from
        while (i + width <= bytes.size) {
            var allZero = true
            for (k in 0 until width) {
                if (bytes[i + k].toInt() != 0) { allZero = false; break }
            }
            if (allZero) return i + width
            i += if (width == 2 && bytes[i].toInt() != 0) 2 else 1
        }
        return null
    }

    private fun ByteArray.indexOfFirstNul(from: Int): Int? {
        for (i in from until size) if (this[i].toInt() == 0) return i
        return null
    }

    // ---- MP4 / M4A --------------------------------------------------------

    /**
     * `moov → udta → meta → ilst → covr → data`.
     *
     * A box chain, and the walk is bounded three ways: eight levels deep, sixteen
     * megabytes of boxes examined, and sixty-four megabytes of file. The last is the
     * one that matters — a `size` of zero means "to the end of the file", and an
     * unbounded interpretation of that is how a parser ends up trying to read a whole
     * podcast as if it were a box tree.
     */
    private suspend fun mp4(reader: Reader): Picture? {
        val cursor = Cursor(reader)
        val moov = findBox(cursor, 0, reader.size.takeIf { it != UNKNOWN_SIZE } ?: MAX_WALK_BYTES * 4, setOf("moov"), 0)
            ?: return null
        val udta = findBox(cursor, moov.first, moov.second, setOf("udta"), 0) ?: return null
        val meta = findBox(cursor, udta.first, udta.second, setOf("meta"), 0) ?: return null
        // `meta` is a full box: four version/flags bytes before its children.
        val ilst = findBox(cursor, meta.first + 4, meta.second, setOf("ilst"), 0) ?: return null
        val covr = findBox(cursor, ilst.first, ilst.second, setOf("covr"), 0) ?: return null
        val data = findBox(cursor, covr.first, covr.second, setOf("data"), 0) ?: return null

        val head = cursor.bytesAt(data.first, 8)
        if (head.size < 8) return null
        // The payload of a `data` box is four bytes of type indicator — which is the
        // version and flags field, and is what says JPEG from PNG — then four bytes of
        // locale, then the bytes themselves. The box header is already behind us,
        // because `findBox` hands back the payload's bounds.
        val length = (data.second - data.first - 8).toInt()
        if (length <= 0 || length > MAX_PICTURE_BYTES) return null
        val mime = when (u32(head, 0)) {
            13 -> "image/jpeg"
            14 -> "image/png"
            27 -> "image/bmp"
            // 0 means "no declared type", and the sniffing below will work it out.
            else -> null
        }
        val bytes = reader.read(data.first + 8, length)
        if (bytes.size != length) return null
        return picture(bytes, mime)
    }

    /** A box's payload bounds, or null when the one wanted is not there. */
    private suspend fun findBox(cursor: Cursor, from: Long, until: Long, want: Set<String>, depth: Int): Pair<Long, Long>? {
        if (depth > 8 || from >= until) return null
        var at = from
        var walked = 0L
        while (at + 8 <= until && walked < MAX_WALK_BYTES) {
            val head = cursor.bytesAt(at, 8)
            if (head.size < 8) return null
            var size = u32(head, 0).toLong()
            val type = string(head, 4, 8)
            var headerLength = 8L
            if (size == 1L) {
                val ext = cursor.bytesAt(at + 8, 8)
                if (ext.size < 8) return null
                size = u64(ext, 0)
                headerLength = 16L
            } else if (size == 0L) {
                // To the end of the file — bounded like any other walk.
                size = MAX_WALK_BYTES
            }
            if (size < headerLength || size > MAX_WALK_BYTES * 4) return null
            val payloadEnd = at + size
            if (type in want) return (at + headerLength) to payloadEnd
            walked += payloadEnd - at
            at = payloadEnd
        }
        return null
    }

    // ---- Ogg --------------------------------------------------------------

    /**
     * Vorbis and Opus comments, which carry a picture as a base64 FLAC block.
     *
     * Only the first four packets are searched, and 64 pages are read at most. Both
     * bounds are the same judgement: the comment header is at the front of the file
     * by specification, so a packet that far in is audio, and a page count that high
     * means this is not a file worth reading further.
     */
    private suspend fun ogg(reader: Reader): Picture? {
        val cursor = Cursor(reader)
        var packet = ByteArray(0)
        var pages = 0
        while (pages++ < 64) {
            if (cursor.position > MAX_WALK_BYTES) return null
            val head = cursor.bytes(27)
            if (head.size < 27 || string(head, 0, 3) != "OggS") return null
            val continued = (head[5].toInt() and 0x01) != 0
            val segmentCount = head[26].toInt() and 0xFF
            val table = cursor.bytes(segmentCount)
            if (table.size < segmentCount) return null
            var bodyLength = 0
            for (segment in table) bodyLength += segment.toInt() and 0xFF
            val body = cursor.bytes(bodyLength)
            packet = if (continued) packet + body else body

            // A packet ends here when the last segment is short. Comment packets name
            // themselves up front, which is the only reason this works.
            if (table.isNotEmpty() && (table[table.size - 1].toInt() and 0xFF) < 255) {
                if (packet.size > 7 && packet[0] == 0x03.toByte() && string(packet, 1, 3) == "vorbis") {
                    return vorbisPicture(packet, opus = false)
                }
                if (packet.size > 8 && string(packet, 0, 8) == "OpusTags") {
                    return vorbisPicture(packet, opus = true)
                }
                packet = ByteArray(0)
                if (pages > 4) return null
            }
        }
        return null
    }

    /**
     * `[type/magic][vendor length + vendor][count][length + field]…`
     *
     * Little-endian, unlike every other format here, and the fields are a list of
     * `KEY=value` strings — the one that matters being
     * `METADATA_BLOCK_PICTURE=<base64 of a FLAC PICTURE block>`.
     */
    private fun vorbisPicture(packet: ByteArray, opus: Boolean): Picture? {
        var pos = if (opus) 8 else 7
        val vendorLength = u32le(packet, pos); pos += 4
        if (vendorLength < 0 || pos + vendorLength > packet.size) return null
        pos += vendorLength
        val count = u32le(packet, pos); pos += 4
        if (count < 0 || count > 10_000) return null
        repeat(count) {
            if (pos + 4 > packet.size) return null
            val length = u32le(packet, pos); pos += 4
            if (length < 0 || pos + length > packet.size) return null
            val field = string(packet, pos, pos + length)
            pos += length
            if (field.startsWith(METADATA_BLOCK_PICTURE, ignoreCase = true)) {
                return flacPictureBytes(field.substringAfter('='))
            }
        }
        return null
    }

    /**
     * A FLAC `PICTURE` struct, in memory, without its four-byte block header.
     *
     * The same layout as the on-disk block, so the two readers differ only in where
     * their bytes come from.
     */
    private fun flacPictureBytes(payload: String): Picture? {
        val bytes = decodeBase64Lenient(payload) ?: return null
        if (bytes.size < 32) return null
        var pos = 4 // picture type
        val mimeLen = u32(bytes, pos); pos += 4
        if (mimeLen < 0 || pos + mimeLen > bytes.size) return null
        val declaredMime = string(bytes, pos, pos + mimeLen); pos += mimeLen
        val descLen = u32(bytes, pos); pos += 4
        if (descLen < 0 || pos + descLen + 16 > bytes.size) return null
        pos += descLen + 16
        val dataLength = u32(bytes, pos); pos += 4
        if (dataLength <= 0 || dataLength > MAX_PICTURE_BYTES || pos + dataLength > bytes.size) return null
        return picture(bytes.copyOfRange(pos, pos + dataLength), declaredMime)
    }

    // ---- Finishing --------------------------------------------------------

    /**
     * A picture, with its type settled.
     *
     * A declared MIME wins over a sniffed one, because a tag that says PNG is right
     * far more often than a sniffer is wrong; the sniff is there for the tags that say
     * nothing, and the hard default is last because a picture with no type at all is
     * far more often a JPEG than anything else.
     */
    private fun picture(bytes: ByteArray, mime: String?): Picture? {
        if (bytes.isEmpty() || bytes.size > MAX_PICTURE_BYTES) return null
        return Picture(bytes, mime?.takeIf { it.isNotBlank() } ?: sniffMime(bytes) ?: "image/jpeg")
    }

    /**
     * What these bytes claim to be, from their first few bytes, or null for nothing
     * recognisable.
     *
     * Public because a caller holding a *whole* picture — a `cover.jpg` fetched to be
     * drawn rather than extracted from a tag — needs the same judgement this makes
     * internally, and there is no reason for it to be a second implementation.
     */
    fun sniff(bytes: ByteArray): String? = sniffMime(bytes)

    private fun sniffMime(bytes: ByteArray): String? {
        // Two bytes is the shortest of these magics — `BM` is exactly that — and only
        // WebP needs more, which its own branch asks for.
        if (bytes.size < 2) return null
        return when {
            bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() -> "image/jpeg"
            bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte() -> "image/png"
            bytes[0] == 'G'.code.toByte() && bytes[1] == 'I'.code.toByte() -> "image/gif"
            bytes[0] == 'B'.code.toByte() && bytes[1] == 'M'.code.toByte() -> "image/bmp"
            // WebP is "RIFF????WEBP", so the tag is at offset 8.
            bytes.size >= 12 && bytes[8] == 'W'.code.toByte() && bytes[9] == 'E'.code.toByte() -> "image/webp"
            else -> null
        }
    }

    /**
     * Base64 decoded leniently: whitespace dropped, and an unusable tail ignored.
     *
     * Lenient because the field is a *comment* — a server or a tagger that wrapped a
     * long line is not making the picture wrong, and a strict decoder would throw away
     * a perfectly good cover over a newline.
     */
    private fun decodeBase64Lenient(value: String): ByteArray? {
        val cleaned = StringBuilder(value.length)
        for (ch in value) if (!ch.isWhitespace()) cleaned.append(ch)
        return runCatching { kotlin.io.encoding.Base64.Default.decode(cleaned.toString()) }.getOrNull()
    }

    private const val METADATA_BLOCK_PICTURE = "METADATA_BLOCK_PICTURE"

    // ---- Reading bytes -----------------------------------------------------

    /**
     * A sliding window over a file, so a walk that looks at scattered offsets still
     * costs one request per 64 KiB rather than one per read.
     *
     * A short read is returned as-is rather than raised, because a server that ignores
     * `Range` answers 200 with the whole file and a caller cannot tell that from a
     * truncated one — and refusing to serve a short read would mean no covers at all
     * from a server without range support, rather than covers for the files small
     * enough to have arrived whole.
     */
    private class Cursor(private val reader: Reader) {
        var position: Long = 0
            private set

        private var windowStart = 0L
        private var window = ByteArray(0)

        suspend fun bytes(length: Int): ByteArray {
            if (length <= 0) return ByteArray(0)
            val from = (position - windowStart).toInt()
            if (position < windowStart || from + length > window.size) {
                // One window, at least as large as asked for and at least 64 KiB, and
                // never larger than what is left of the file.
                val wanted = maxOf(length.toLong(), 64L * 1024)
                    .coerceAtMost((reader.size - position).coerceAtLeast(0L))
                window = reader.read(position, wanted.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                windowStart = position
            }
            val start = (position - windowStart).toInt()
            if (start < 0 || start >= window.size) return ByteArray(0)
            val end = (start + length).coerceAtMost(window.size)
            position += (end - start)
            return window.copyOfRange(start, end)
        }

        suspend fun bytesAt(offset: Long, length: Int): ByteArray {
            val here = position
            position = offset
            val result = bytes(length)
            position = here
            return result
        }

        /** A seek, not a read: a large block costs nothing to step over. */
        fun skip(length: Long) {
            position += length
        }
    }

    // ---- Byte readers -----------------------------------------------------

    /**
     * ID3's syncsafe integer: seven bits per byte, so a size never contains a byte
     * that looks like the start of an MPEG frame.
     */
    private fun syncsafe(bytes: ByteArray, at: Int): Int {
        if (at + 4 > bytes.size) return -1
        return ((bytes[at].toInt() and 0x7F) shl 21) or
            ((bytes[at + 1].toInt() and 0x7F) shl 14) or
            ((bytes[at + 2].toInt() and 0x7F) shl 7) or
            (bytes[at + 3].toInt() and 0x7F)
    }

    /**
     * Unsigned 32-bit big-endian, saturated.
     *
     * Saturated because every caller wants an array index or a length out of it, and
     * a value past 2 GB has to fail the range check below rather than overflow into
     * one that passes.
     */
    private fun u32(bytes: ByteArray, at: Int): Int {
        if (at + 4 > bytes.size) return -1
        val value = ((bytes[at].toLong() and 0xFF) shl 24) or
            ((bytes[at + 1].toLong() and 0xFF) shl 16) or
            ((bytes[at + 2].toLong() and 0xFF) shl 8) or
            (bytes[at + 3].toLong() and 0xFF)
        return if (value > Int.MAX_VALUE) Int.MAX_VALUE else value.toInt()
    }

    private fun u24(bytes: ByteArray, at: Int): Int {
        if (at + 3 > bytes.size) return -1
        return ((bytes[at].toInt() and 0xFF) shl 16) or
            ((bytes[at + 1].toInt() and 0xFF) shl 8) or
            (bytes[at + 2].toInt() and 0xFF)
    }

    private fun u64(bytes: ByteArray, at: Int): Long {
        if (at + 8 > bytes.size) return -1L
        var value = 0L
        for (i in 0 until 8) value = (value shl 8) or (bytes[at + i].toLong() and 0xFF)
        return value
    }

    private fun u32le(bytes: ByteArray, at: Int): Int {
        if (at + 4 > bytes.size) return -1
        val value = ((bytes[at + 3].toLong() and 0xFF) shl 24) or
            ((bytes[at + 2].toLong() and 0xFF) shl 16) or
            ((bytes[at + 1].toLong() and 0xFF) shl 8) or
            (bytes[at].toLong() and 0xFF)
        return if (value > Int.MAX_VALUE) Int.MAX_VALUE else value.toInt()
    }

    private fun string(bytes: ByteArray, from: Int, to: Int): String {
        if (from < 0 || to > bytes.size || to <= from) return ""
        return bytes.copyOfRange(from, to).decodeToString()
    }
}
