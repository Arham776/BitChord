package com.music.bitchord.data.remote

import com.music.bitchord.data.model.Song

/**
 * What every remote file library names a track, and the row itself.
 *
 * Port of upstream `data/remote/RemoteSong.kt`. Shared deliberately rather than
 * written twice: a WebDAV file and an SMB file are the same problem, and two copies
 * of "split `Artist - Title`" are two copies to keep in step.
 */
object RemoteSong {

    /**
     * `Artist - Title`, or just the title when there is no artist worth naming.
     *
     * Split on the **first** separator and only the first, so a title that contains
     * one — `Symphony - No. 5 - Allegro` — keeps its own second half. Either half is
     * null when it is blank, which is what makes `- Title` a title and `Artist - ` a
     * track with no title rather than a track with a separator in its name.
     */
    fun splitArtistTitle(base: String): Pair<String?, String?> {
        val separator = base.indexOf(" - ")
        if (separator < 0) return null to base
        val artist = base.substring(0, separator).trim().takeIf { it.isNotEmpty() }
        val title = base.substring(separator + 3).trim().takeIf { it.isNotEmpty() }
        return artist to title
    }

    /**
     * A row for a remote file.
     *
     * No `source` parameter, and its absence is a divergence from upstream rather than
     * an omission. Upstream's [Song] carries `playbackSource` / `playbackSourceType` /
     * `playbackSourceId` because its row has to say which of several interchangeable
     * backends produced it, and the engine reads that field to choose. This port's
     * [Song] has no such field and the engine resolves by the address instead —
     * [com.music.bitchord.playback.PlaybackController.resolveSource] passes anything
     * that is not a `yt:` stream straight through, and the id already says where a
     * remote file lives, since [WebDavConfig.idFor] prefixes it. A string that
     * duplicates the id and that nothing reads is a second thing to keep in step.
     *
     * @param streamUrl the address the audio is fetched from — this *is* the play
     *   address, and it is the only place a remote file's location is recorded
     * @param fileName the filename, already percent-decoded
     */
    fun build(
        videoId: String,
        streamUrl: String,
        fileName: String,
        albumName: String?,
    ): Song {
        val base = fileName.substringBeforeLast('.').takeIf { it.isNotBlank() } ?: fileName
        val (artist, title) = splitArtistTitle(base)
        return Song(
            videoId = videoId,
            title = title ?: base,
            artist = artist ?: WebDavConfig.UNKNOWN_ARTIST,
            // Never a placeholder: a remote row with an invented thumbnail renders as
            // a picture of nothing, which is worse than the empty box it replaces.
            thumbnailUrl = null,
            durationText = null,
            // The parent folder is the album. That is what groups a
            // `Music/Artist/Album/track.flac` layout back into releases without
            // reading a single tag, and on a conventional share it is right.
            albumName = albumName?.trim()?.takeIf { it.isNotEmpty() },
            // The address to stream from, in the field the player reads for a local
            // path. A remote file is a local file as far as playback is concerned: it
            // has one address and the engine reads it.
            localPath = streamUrl,
        )
    }
}
