package com.music.bitchord.data.webdav

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.model.Song
import com.music.bitchord.data.remote.EmbeddedArt
import com.music.bitchord.data.remote.RemoteArtworkStore
import com.music.bitchord.data.remote.WebDavConfig
import com.music.bitchord.data.remote.WebDavException
import com.music.bitchord.data.settings.AppSettings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import platform.Foundation.NSData

/**
 * The remote file library, as Swift sees it.
 *
 * ## Why this is a bridge and not a Swift implementation
 *
 * Everything here is portable and separately tested: the settings that decide what a
 * credential may be attached to ([WebDavAuth]), the listing ([WebDavRepository]), the
 * multistatus reader, the cover picking and the tag parsers. A Swift implementation
 * would be a second copy of all of it, and the two would disagree about which of two
 * spellings of a folder is the same folder.
 *
 * ## Why the calls throw rather than return a `Result`
 *
 * The same reason as `PartyCoordinator`, and the same consequence. Kotlin/Native hands
 * Swift a boxed `Result` with no header and no way to get at it, so a `Result`-returning
 * suspend function is callable and useless from the only place that calls it. A
 * throwing suspend function arrives as `(T?, NSError?)` — the shape Swift already
 * understands — and the message is already a sentence a person can read, because
 * [WebDavFailure] is written in sentences.
 *
 * So `@Throws` here is not decoration either: a Kotlin function that throws without
 * declaring it lets the exception cross the Objective-C boundary as an *unexpected*
 * one, which terminates the process. A share that answers 401 is the single most
 * ordinary refusal this feature has, and it must arrive in a text field.
 */
object WebDavBridge {

    // ---- Settings ----------------------------------------------------------

    /** The share's address, normalized. Empty when none has been given. */
    fun url(): String = AppSettings.webDavUrl.value

    fun username(): String = AppSettings.webDavUsername.value

    /**
     * Whether a password is stored.
     *
     * A flag rather than the password, because a settings field that renders a stored
     * secret is a settings field that puts a credential in a screenshot, in a screen
     * recording and in a bug report. [save] takes a nil password to mean "leave it
     * alone" for the same reason.
     */
    fun hasPassword(): Boolean = AppSettings.webDavPassword.value.isNotEmpty()

    /** Whether there is an address this feature can dial. */
    fun isConfigured(): Boolean = WebDavRepository.isConfigured()

    /**
     * Store the share.
     *
     * @param password nil to keep whatever is stored, which is what a settings form
     *   that shows "••••" and leaves the field alone should do — writing the empty
     *   string back would forget the credential because the form did not have it.
     *
     * A changed address forgets the extracted covers, because that is a different
     * share; a changed password does not, because the pictures are the same ones and
     * re-extracting them would cost a ranged read per row for no difference.
     */
    fun save(url: String, username: String, password: String?) {
        val before = AppSettings.webDavUrl.value
        AppSettings.setWebDavUrl(url)
        AppSettings.setWebDavUsername(username)
        if (password != null) AppSettings.setWebDavPassword(password)
        if (AppSettings.webDavUrl.value != before) {
            scope.launch { RemoteArtworkStore.clear() }
        }
    }

    /** Forget the share and its credential together. */
    fun forget() {
        AppSettings.clearWebDav()
        scope.launch { RemoteArtworkStore.clear() }
    }

    // ---- The share ---------------------------------------------------------

    /**
     * Whether an address and a credential work.
     *
     * @throws WebDavException carrying the sentence for whatever went wrong, so a
     *   settings field can show it under itself as somebody types.
     */
    @Throws(WebDavException::class, CancellationException::class)
    suspend fun test(url: String, username: String, password: String?): String {
        val failure = WebDavRepository.testConnection(
            url = url,
            username = username,
            password = password ?: storedPassword(),
        ) ?: return url
        throw WebDavException(failure.message())
    }

    /**
     * Every track on the share.
     *
     * @throws WebDavException if the share refused or could not be reached. An empty
     *   share is **not** an error — it is an empty answer, and the caller says "no
     *   audio files" for it, which is a different sentence from "that server did not
     *   accept the password" and the reason somebody would otherwise go and look in
     *   Settings for a mistake that is not there.
     */
    @Throws(WebDavException::class, CancellationException::class)
    suspend fun library(): List<Song> = WebDavRepository.getSongs()

    // ---- Pictures ----------------------------------------------------------

    /**
     * The picture filed beside a track, as bytes.
     *
     * Not a `UIImage` and not a URL: the fetch needs the share's credential, and
     * `AsyncImage` has nowhere to put one. The caller decodes and caches, and the
     * cache is the platform's (`NSCache`) rather than a second eviction policy written
     * here.
     *
     * Null for a status that is not a success — a cover that has been deleted off the
     * share is a missing cover, not a failure worth telling anybody about. A
     * transport failure throws, because a listener on a train deserves to know the
     * difference between "this folder has no picture" and "the server is not
     * answering"; every caller in this app treats both as "no cover" rather than
     * refusing to draw a row.
     */
    @Throws(WebDavException::class, CancellationException::class)
    suspend fun coverImage(fileUrl: String): CoverImage? {
        val header = WebDavAuth.headerFor(fileUrl)
        val response = try {
            Http.getBytesRaw(
                fileUrl,
                if (header == null) emptyMap() else mapOf("Authorization" to header),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            throw WebDavException(e.message ?: "Could not fetch the cover")
        }
        if (response.status !in 200..299) return null
        val bytes = response.body ?: return null
        if (bytes.isEmpty()) return null
        return CoverImage(bytes = bytes.asNSData(), mime = imageMime(fileUrl, bytes))
    }

    /**
     * The picture inside the track's own file, or null when it has none.
     *
     * Read lazily, on the rows that are actually drawn, and cached: a listing never
     * touches audio bytes, and a share of untagged files would otherwise cost a ranged
     * read per track per list.
     */
    @Throws(WebDavException::class, CancellationException::class)
    suspend fun embeddedCover(fileUrl: String): CoverImage? {
        val picture = RemoteArtworkStore.resolveArt(fileUrl, WebDavAuth.headerFor(fileUrl)) ?: return null
        return CoverImage(bytes = picture.bytes.asNSData(), mime = picture.mime)
    }

    /**
     * The headers a track at [fileUrl] has to be streamed with.
     *
     * Empty for anything that is not on the configured share, which is the rule in
     * [WebDavAuth] and is asked for here rather than reimplemented at the call site.
     */
    fun playbackHeaders(fileUrl: String): Map<String, String> {
        val header = WebDavAuth.headerFor(fileUrl) ?: return emptyMap()
        return mapOf("Authorization" to header)
    }

    /** Whether a row's id is one of ours, for a queue that mixes libraries. */
    fun isRemoteId(videoId: String): Boolean = WebDavConfig.isWebDavId(videoId)

    /** The address a track id plays from, or nil when the id is not one of ours. */
    fun fileUrlOf(videoId: String): String? = WebDavConfig.fileUrlOf(videoId)

    // ---- Plumbing ----------------------------------------------------------

    /**
     * Somewhere to run the cache clear.
     *
     * A settings edit is a synchronous call from Swift and the clear is a suspending
     * one, and the only reason it is suspending at all is the lock that guards the
     * cache. Firing and forgetting is right: nothing waits on it, and the next read
     * after it runs finds an empty cache either way.
     */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private fun storedPassword(): String = AppSettings.webDavPassword.value

    /**
     * What a whole picture's bytes are, for the label that goes with them.
     *
     * The bytes rather than what the server said: a WebDAV server that reports
     * `application/octet-stream` for a `.jpg` is reporting the truth and is extremely
     * common, and a complete JPEG, PNG, GIF, BMP or WebP identifies itself. The
     * extension is the fallback for the formats that do not — HEIC above all, which is
     * what an iPhone photographs in and which no magic number covers.
     */
    private fun imageMime(fileUrl: String, bytes: ByteArray): String =
        EmbeddedArt.sniff(bytes) ?: EXTENSION_MIME[extensionOf(fileUrl)] ?: "image/jpeg"

    private fun extensionOf(fileUrl: String): String {
        val name = fileUrl.substringBefore('?').substringBefore('#').substringAfterLast('/')
        return name.substringAfterLast('.', "").lowercase()
    }

    private val EXTENSION_MIME = mapOf(
        "heic" to "image/heic",
        "heif" to "image/heif",
        "avif" to "image/avif",
        "tiff" to "image/tiff",
        "tif" to "image/tiff",
    )
}

/**
 * An image, as bytes and a type.
 *
 * `NSData` rather than a `ByteArray` because this is the one type in the bridge whose
 * only consumer is Foundation: a Kotlin `ByteArray` arrives in Swift as an opaque
 * `KotlinByteArray` with no `Data` conversion, and every row of a library would pay to
 * unwrap it.
 *
 * No value semantics on purpose. Nothing compares two of these — the cache keys on the
 * URL it fetched from, not on the bytes that came back — and an `NSData` `isEqual` on
 * a megabyte of pixels on every access is not something to add for a comparison nobody
 * makes.
 */
class CoverImage(val bytes: NSData, val mime: String) {
    override fun toString(): String = "CoverImage($mime, ${bytes.length} bytes)"
}
