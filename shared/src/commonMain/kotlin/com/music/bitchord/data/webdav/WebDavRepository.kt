package com.music.bitchord.data.webdav

import com.music.bitchord.data.model.Song
import com.music.bitchord.data.remote.RemoteArtwork
import com.music.bitchord.data.remote.RemoteSong
import com.music.bitchord.data.remote.WebDavClient
import com.music.bitchord.data.remote.WebDavConfig
import com.music.bitchord.data.remote.WebDavFailure
import com.music.bitchord.data.settings.AppSettings

/**
 * A WebDAV share as [Song] rows, shaped like the on-device library so the same
 * Songs / Artists / Albums view can draw it.
 *
 * Port of upstream `data/webdav/WebDavRepository.kt`.
 *
 * Stateless apart from [AppSettings]: every load re-lists the server. That is
 * upstream's arrangement and it is the right one for a remote library — the server is
 * the only thing that knows what is on it, and a cached listing is a listing that is
 * wrong the moment somebody uploads an album.
 *
 * ## The album is the parent folder
 *
 * Which groups a `Music/Artist/Album/track.flac` layout back into releases without
 * reading a single tag, and is right on the conventional share. It is also the reason
 * a share dumped flat — every track in the root — has no albums, and that is the
 * honest answer: there are none.
 */
object WebDavRepository {

    /** Whether there is an address to dial at all. */
    fun isConfigured(): Boolean = WebDavConfig.isConfigured(AppSettings.webDavUrl.value)

    /**
     * Every track on the share.
     *
     * **Throws** [WebDavException] if the server refused or could not be reached.
     *
     * That is a divergence from upstream, and it is the important one in this file.
     * Upstream's `getSongs` returns an empty list for all three ways this can go
     * wrong — unconfigured, refused, unreachable — and upstream gives `RemoteListing`
     * the job of saying that a share which answers with an error must not read as an
     * empty one. Upstream's own repository defeats that: the failure is swallowed, the
     * listing arrives as a *success* of zero tracks, and the sentence for a wrong
     * password comes out as "no audio files". A listener who has mistyped their
     * password is sent to look for a folder that is not there.
     *
     * So the distinction is made where the data is, and the only thing that is not a
     * failure is a share with nothing on it. An *unconfigured* share is still an empty
     * list rather than a throw: there is nothing to have refused, and a library page
     * closed by an error is worse than one that says it is not set up.
     *
     * The sentence is [WebDavFailure]'s — the same one the settings screen shows as
     * somebody types — so the two places a share can be refused say the same thing.
     */
    suspend fun getSongs(): List<Song> {
        val url = AppSettings.webDavUrl.value
        if (!WebDavConfig.isConfigured(url)) return emptyList()
        val listing = WebDavClient.listLibrary(
            baseUrl = url,
            username = AppSettings.webDavUsername.value,
            password = AppSettings.webDavPassword.value,
        ).getOrElse { throw it }
        // One pass over the images, keyed by the folder they sit in, so a cover is
        // one lookup per track rather than a scan of every picture on the share.
        val artByDir = listing.images.groupBy { WebDavConfig.dirKeyOf(it.url) }
        return listing.audio.map { entry ->
            val siblings = artByDir[WebDavConfig.dirKeyOf(entry.url)].orEmpty()
            entry.toSong(RemoteArtwork.pick(siblings.map { it.url }))
        }
    }

    /**
     * Whether an address and a credential work, as the reason they did not.
     *
     * Null is success. A [WebDavFailure] is not — it is the sentence for the status,
     * which is what makes this the right call for a settings field that reports as
     * somebody types rather than for a page that reports once it has loaded.
     */
    suspend fun testConnection(
        url: String,
        username: String,
        password: String,
    ): WebDavFailure? = WebDavClient.testConnection(url, username, password)

    /**
     * A row for a listed file.
     *
     * The server's own name for the file wins over the name decoded out of the URL,
     * and that is upstream's rule for a good reason: a Nextcloud share full of
     * `track-1.flac` is a worse library than the same share with the names its
     * uploader chose. The URL is the fallback, and the fallback still splits
     * `Artist - Title` — so a server that names its files with no display name at all
     * still gets a library with artists on it.
     *
     * @param artworkUrl a picture filed beside this file, or null. Embedded pictures
     *   are **not** read here: that is a ranged fetch per track at list time, which is
     *   the cost [RemoteArtworkStore] exists to pay lazily and only for the rows that
     *   are actually drawn.
     */
    fun WebDavClient.Entry.toSong(artworkUrl: String? = null): Song {
        val album = WebDavConfig.folderNameOf(url)
        val fromUrl = RemoteSong.build(
            videoId = WebDavConfig.idFor(url),
            streamUrl = url,
            fileName = WebDavConfig.fileNameOf(url),
            albumName = album,
        )
        val stem = displayName.substringBeforeLast('.').takeIf { it.isNotBlank() }
        val (artist, title) = if (stem == null) null to null else RemoteSong.splitArtistTitle(stem)
        return fromUrl.copy(
            title = title ?: fromUrl.title,
            artist = artist ?: fromUrl.artist,
            thumbnailUrl = artworkUrl,
        )
    }
}
