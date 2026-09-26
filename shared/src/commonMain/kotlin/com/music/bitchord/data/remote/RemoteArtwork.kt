package com.music.bitchord.data.remote

/**
 * A track's cover, when it is a picture filed beside it.
 *
 * Port of upstream `data/remote/RemoteArtwork.kt`. Shared by every remote file
 * library, because the question is the same everywhere: given the pictures in one
 * folder, which one is this album's cover?
 */
object RemoteArtwork {

    /**
     * The cover for a folder, from the pictures in it.
     *
     * The preferred names win over a stray `IMG_1234.jpg`, because a folder a
     * download manager drops is full of exactly those. With nothing filed that
     * looks like a cover, the answer is **none** rather than the alphabetically
     * first image — a wrong cover is worse than no cover, because a listener who
     * sees one has no way to know it is wrong.
     *
     * @param siblingUrls the pictures in the same folder; grouping is the caller's
     *   job, since only it knows what a "folder" is on its protocol
     */
    fun pick(siblingUrls: List<String>): String? {
        if (siblingUrls.isEmpty()) return null
        return siblingUrls.sortedWith(
            compareBy(
                // Rank by how much the stem looks like a deliberate cover name, and
                // then alphabetically, so the answer does not depend on the order the
                // server happened to list the folder in.
                { stem(it).let { s -> preferredStems.indexOfFirst { s.startsWith(it) }.takeIf { i -> i >= 0 } ?: Int.MAX_VALUE } },
                { stem(it) },
            )
        ).firstOrNull()
    }

    /**
     * The filename at the end of a picture's address, without its extension.
     *
     * Percent-decoded, because a server will escape a space in the name it hands
     * back and a `cover%20art.jpg` has to be recognisable as `cover art`.
     */
    fun stem(fileUrl: String): String {
        val path = fileUrl.substringBefore('?').substringBefore('#').trimEnd('/')
        val segment = path.substringAfterLast('/')
        return Percent.decode(segment).substringBeforeLast('.').lowercase()
    }

    /**
     * The names a cover is conventionally given.
     *
     * Matched as a *prefix* rather than for equality, so `cover-front.jpg` and
     * `AlbumArt2.png` are recognised. A prefix over-matches in one direction and not
     * the other — `coverstory.jpg` is read as a cover, `the cover.jpg` is not — which
     * is the safer of the two mistakes: a cover shown in place of another is a
     * cosmetic annoyance, and a real cover that goes unrecognised is a grey box.
     */
    private val preferredStems = listOf("cover", "folder", "front", "albumart", "album", "artwork")
}
