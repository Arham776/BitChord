package com.music.bitchord.data.remote

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.RawHttpText

/**
 * A minimal WebDAV client: `PROPFIND` listings with HTTP Basic auth.
 *
 * Port of upstream `data/webdav/WebDavClient.kt`.
 *
 * ## Depth 1, and the recursion that goes with it
 *
 * One directory at a time, never `Depth: infinity`. That is not a simplification
 * for its own sake: Nextcloud — the most common server — refuses an infinite
 * `PROPFIND` outright, and a server that answers one can take minutes deciding. So
 * the traversal is explicit, and it costs one round trip per folder, which is also
 * what lets a listing that hits a permission error in one branch say so rather than
 * hanging on the whole share.
 *
 * ## What is parsed
 *
 * Only three properties are asked for, and classification is by **filename
 * extension** rather than by content type. A server that reports
 * `application/octet-stream` for a `.flac` is reporting the truth and is extremely
 * common; one that reports `audio/flac` for a `.txt` is rarer, and listening to it
 * would be worse.
 *
 * ## Statuses that are answers rather than failures
 *
 * `207` is a successful multistatus, not a 2xx range member that happens to be odd.
 * `405` from `MKCOL` means something is already there, which is the happy path
 * wearing an error code. `412` from a `PUT` means the conditional write lost a race.
 * All three are handled as outcomes; only a genuine refusal is an error.
 *
 * An `object`, as upstream has it, and for the reason upstream's shape implies: it
 * holds no state — every call is given the address and the credential it needs — so
 * an instance would be a thing a caller could hold for no reason and get wrong twice.
 */
object WebDavClient {
    /**
     * One thing a `PROPFIND` returned.
     *
     * [url] is absolute and [displayName] is whatever the server called it — which is
     * not the same as the last path segment on every server, and a Nextcloud share
     * full of `track-1.flac` is a worse library than the same share with the names its
     * uploader chose.
     */
    data class Entry(
        val url: String,
        val displayName: String,
        val isCollection: Boolean,
        val contentType: String? = null,
    )

    /**
     * Everything a library view needs: the audio, and the pictures filed beside it.
     *
     * Both from one traversal. A second pass for the pictures would pay for the whole
     * walk again over files already in hand, and on a share of a few thousand tracks
     * that is the difference between a library that opens and one that does not.
     */
    data class Listing(val audio: List<Entry>, val images: List<Entry>)

    /** What a `PUT` did. */
    sealed interface PutResult {
        /** The bytes are on the server. */
        data object Uploaded : PutResult

        /** The server refused a non-overwriting `PUT` because the file is there. */
        data object AlreadyExists : PutResult
    }

    /**
     * Whether a server is a WebDAV server this client can read.
     *
     * Depth 0, so it costs one round trip and reads nothing: the question is whether
     * the address and the credential work, not what is on it.
     */
    suspend fun testConnection(
        url: String,
        username: String,
        password: String,
    ): WebDavFailure? {
        val root = WebDavConfig.normalizeUrl(url)
        if (!WebDavConfig.isConfigured(root)) {
            return WebDavFailure.Address("That is not a server address.")
        }
        val response = Http.requestRaw(
            url = root,
            method = "PROPFIND",
            body = PROP_FIND_BODY,
            headers = headersFor(username, password, depth = "0"),
        )
        // 207 is the multistatus a real WebDAV server answers with. A plain 200 is
        // accepted because some proxies rewrite it, and a proxy in front of a
        // WebDAV server is not unusual.
        if (response.status == 207 || response.status in 200..299) return null
        return WebDavFailure.describe(response, "Server answered")
    }

    /**
     * Everything under a share: the audio, and the pictures beside it.
     *
     * Breadth-first, with a visited set keyed on the *lower-cased* directory address
     * so a server that spells the same folder two ways — trailing slash, a percent
     * escape, a different case — cannot send this into a loop.
     *
     * @param maxFiles a ceiling on the *audio* found, and the reason one is needed
     *   at all: a share with a symlink cycle or a misconfigured client that mirrors
     *   itself will otherwise walk until the process dies. The pictures are not
     *   counted, because a folder with forty cover variants and two songs is
     *   ordinary and stopping at three files would be a library with no covers.
     */
    suspend fun listLibrary(
        baseUrl: String,
        username: String,
        password: String,
        maxFiles: Int = 10_000,
    ): Result<Listing> {
        val root = WebDavConfig.normalizeUrl(baseUrl)
        if (!WebDavConfig.isConfigured(root)) {
            return Result.failure(WebDavException("WebDAV is not configured"))
        }
        return try {
            val audio = LinkedHashMap<String, Entry>()
            val images = LinkedHashMap<String, Entry>()
            val visited = HashSet<String>()
            val queue = ArrayDeque<String>()
            queue.addLast(root)

            while (queue.isNotEmpty() && audio.size < maxFiles) {
                val dir = queue.removeFirst()
                if (!visited.add(dir.lowercase())) continue
                val response = Http.requestRaw(
                    url = dir,
                    method = "PROPFIND",
                    body = PROP_FIND_BODY,
                    headers = headersFor(username, password, depth = "1"),
                )
                if (response.status != 207 && response.status !in 200..299) {
                    // One unreadable folder fails the whole listing, and the reason is
                    // carried up. A share with one bad subfolder is otherwise a library
                    // that silently omits it, and a listener has no way to tell that
                    // from the folder being empty.
                    //
                    // The sentence is chosen *here*, where the status still is.
                    // "Listing failed with 401" reaches a person as a status code, and
                    // the one thing worth saying about a 401 is that the password was
                    // not accepted.
                    return Result.failure(
                        WebDavException(WebDavFailure.describe(response, COULD_NOT_READ).message()),
                    )
                }
                for (entry in parseMultistatus(response.body.orEmpty(), dir)) {
                    val name = entry.displayName.ifBlank { entry.url }
                    // `putIfAbsent` is a JVM-only method on `MutableMap`; the same
                    // "first one wins" in two lines. It is first-wins rather than
                    // last-wins because a server that lists a file twice has answered
                    // the same question twice, and the earlier answer is the one that
                    // matched the depth of the walk that found it.
                    when {
                        WebDavConfig.isAudioFile(name) -> { if (entry.url !in audio) audio[entry.url] = entry }
                        WebDavConfig.isImageFile(name) -> { if (entry.url !in images) images[entry.url] = entry }
                    }
                    if (entry.isCollection && !visited.contains(entry.url.lowercase())) {
                        queue.addLast(entry.url)
                    }
                }
            }
            Result.success(Listing(audio.values.toList(), images.values.toList()))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            // The sentence rather than `e.message`: this one is shown to a person, and
            // a transport failure's own message is a URL, a host name and a framework
            // stack. A share's address is not something to put in front of a listener
            // because their network dropped.
            Result.failure(WebDavException(WebDavFailure.Unreachable(COULD_NOT_READ).message()))
        }
    }

    /** Just the audio, for a caller that does not draw covers. */
    suspend fun listAudioFiles(
        baseUrl: String,
        username: String,
        password: String,
        maxFiles: Int = 10_000,
    ): Result<List<Entry>> = listLibrary(baseUrl, username, password, maxFiles).map { it.audio }

    /**
     * Whether a file is already on the server.
     *
     * Any answer other than 200 or 404 is a **failure**, not a guess. Treating a 500
     * as "absent" is how an upload silently eats a file it was told not to touch,
     * and a 401 is how an upload overwrites a file whose name collided.
     */
    suspend fun exists(
        fileUrl: String,
        username: String,
        password: String,
    ): Result<Boolean> = try {
        val response = Http.requestRaw(
            url = fileUrl,
            method = "HEAD",
            headers = authHeaders(username, password),
        )
        when (response.status) {
            200 -> Result.success(true)
            404 -> Result.success(false)
            else -> Result.failure(WebDavException("Exists check failed with ${response.status}"))
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        Result.failure(WebDavException(e.message ?: "Exists check failed"))
    }

    /**
     * Put bytes at an address.
     *
     * Without [overwrite], `If-None-Match: *` makes the absence check atomic: a `412`
     * comes back instead of a clobbered file when something else won the race between
     * [exists] and this call. The buffered-body form is here for what the port can
     * offer — a downloaded file, a staged copy — and a hundred-megabyte upload reads
     * the whole thing into memory, which is why the *streaming* form below is the one
     * the upload path uses where it can.
     */
    suspend fun putFile(
        fileUrl: String,
        body: ByteArray,
        mimeType: String,
        username: String,
        password: String,
        overwrite: Boolean,
    ): Result<PutResult> = try {
        val headers = authHeaders(username, password).toMutableMap()
        if (!overwrite) headers["If-None-Match"] = "*"
        val response = Http.requestBytes(
            url = fileUrl,
            method = "PUT",
            body = body,
            contentType = mimeType,
            headers = headers,
        )
        when {
            response.status in 200..299 -> Result.success(PutResult.Uploaded)
            response.status == 412 -> Result.success(PutResult.AlreadyExists)
            else -> Result.failure(WebDavException("Upload failed with ${response.status}"))
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        Result.failure(WebDavException(e.message ?: "Upload failed"))
    }

    /**
     * Create a collection, if it is not one already.
     *
     * `405` means something is already there, which is the happy path wearing an
     * error code. Anything else outside 2xx is a real failure.
     */
    suspend fun ensureCollection(
        dirUrl: String,
        username: String,
        password: String,
    ): Result<Unit> = try {
        val response = Http.requestRaw(
            url = dirUrl,
            method = "MKCOL",
            headers = authHeaders(username, password),
        )
        if (response.status in 200..299 || response.status == 405) {
            Result.success(Unit)
        } else {
            Result.failure(WebDavException("Could not create folder (${response.status})"))
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        Result.failure(WebDavException(e.message ?: "Could not create folder"))
    }

    // ---- The wire --------------------------------------------------------

    private fun authHeaders(username: String, password: String): Map<String, String> {
        val header = WebDavConfig.basicAuthHeader(username, password) ?: return emptyMap()
        return mapOf("Authorization" to header)
    }

    private fun headersFor(username: String, password: String, depth: String): Map<String, String> =
        authHeaders(username, password) + mapOf("Depth" to depth)

    /**
     * The prefix on a refusal that is not one of the statuses with a sentence of its
     * own — a 500, or a status nobody has thought about.
     *
     * A prefix rather than a whole sentence because [WebDavFailure.describe] reads the
     * status first and only falls back to this; the ones that matter (401, 403, 404,
     * 405) all say exactly what happened without it.
     */
    private const val COULD_NOT_READ = "Could not read that share"

    /**
     * The three properties this client asks for.
     *
     * Asking for more would be tidier and slower: a `PROPFIND` for everything
     * returns sizes, modification times and etags for every file in a folder, none
     * of which this reads.
     */
    const val PROP_FIND_BODY: String =
        """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
<d:displayname/>
<d:resourcetype/>
<d:getcontenttype/>
  </d:prop>
</d:propfind>"""

    /**
     * The entries in a multistatus response.
     *
     * A pure function of the XML and the directory it was asked about, and it
     * returns nothing rather than throwing on anything it cannot read — because a
     * folder with one odd entry in it should still contribute its other files, and
     * a server that answers with something this does not recognise is a server this
     * cannot read at all, which the caller reports from an empty listing.
     */
    fun parseMultistatus(xml: String, dirUrl: String): List<Entry> {
        if (xml.isBlank()) return emptyList()
        val entries = mutableListOf<Entry>()
        for (response in responsesOf(xml)) {
            val href = response.textOf(HREF)?.trim().orEmpty()
            if (href.isEmpty()) continue
            val url = resolveHref(dirUrl, href)
            // The server echoes the directory back, and a directory is not a track.
            if (isSameUrl(url, dirUrl)) continue
            val name = response.textOf(DISPLAY_NAME)?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: WebDavConfig.fileNameOf(url)
            entries += Entry(
                url = url,
                displayName = name,
                isCollection = response.hasChild(RESOURCE_TYPE, COLLECTION),
                contentType = response.textOf(GET_CONTENT_TYPE)?.trim()?.takeIf { it.isNotEmpty() },
            )
        }
        return entries
    }

    /**
     * An `href` from a response, as an absolute address.
     *
     * Three shapes, and all three are in real listings:
     *
     * - **Absolute** — used as it is. Deliberately *not* re-rooted onto our own
     *   host: a server that hands back another host is telling us where the file
     *   is, and rewriting it would send the credential somewhere it does not
     *   belong.
     * - **Root-relative** — resolved against the scheme, host and port only.
     * - **Relative** — resolved against the whole directory we asked about, which
     *   is the right base here because this is only ever called with a full
     *   directory address and the answers are its direct children.
     */
    fun resolveHref(baseUrl: String, href: String): String {
        val trimmed = href.trim()
        val lower = trimmed.lowercase()
        if (lower.startsWith("http://") || lower.startsWith("https://")) return trimmed
        val base = WebDavConfig.normalizeUrl(baseUrl)
        val schemeEnd = base.indexOf("://")
        if (schemeEnd < 0) return trimmed
        val afterScheme = base.substring(schemeEnd + 3)
        val schemeHost = if (afterScheme.contains('/')) {
            base.substring(0, schemeEnd + 3) + afterScheme.substringBefore('/')
        } else {
            base
        }
        return if (trimmed.startsWith("/")) "$schemeHost$trimmed" else "${base.trimEnd('/')}/$trimmed"
    }

    /** Two addresses for the same place, as a server might spell them. */
    private fun isSameUrl(a: String, b: String): Boolean =
        a.trim().trimEnd('/').lowercase() == b.trim().trimEnd('/').lowercase()

    // ---- A very small XML reader -------------------------------------
    //
    // Hand-rolled rather than a DOM parser, and the reason is worth stating: the
    // port has no DOM in commonMain, and a WebDAV multistatus is a fixed handful
    // of elements with a namespace prefix that is *not* always `d:`. A reader that
    // looks elements up by local name and ignores the prefix handles every server
    // rather than the subset that spells it the way the RFC's example does.

    private const val RESPONSE = "response"
    private const val HREF = "href"
    private const val DISPLAY_NAME = "displayname"
    private const val RESOURCE_TYPE = "resourcetype"
    private const val COLLECTION = "collection"
    private const val GET_CONTENT_TYPE = "getcontenttype"

    /**
     * The bodies of every `<response>` element, in document order.
     *
     * A flat scan for one element rather than a parser, and deliberately so. A
     * multistatus has a fixed shape — a list of `<response>` elements, each with a
     * few leaf properties and one nested `<resourcetype>` — and the two things a
     * real parser would have to get right here (the namespace prefix, which is `d:`
     * on some servers and `D:` or none on others, and self-closing tags) are both
     * things a scan that ignores prefixes handles for free.
     *
     * What it gives up is generality: this reads a multistatus and nothing else,
     * which is exactly what is asked of it.
     */
    private fun responsesOf(xml: String): List<String> {
        val bodies = mutableListOf<String>()
        var index = 0
        while (index < xml.length) {
            val open = xml.indexOfOpeningTag(RESPONSE, index) ?: break
            val close = xml.indexOf('>', open)
            if (close < 0) break
            // A self-closing `<response/>` has no body and describes nothing.
            if (xml[close - 1] == '/') {
                index = close + 1
                continue
            }
            val bodyEnd = xml.indexOfClosingTag(RESPONSE, close + 1) ?: break
            bodies += xml.substring(close + 1, bodyEnd)
            index = bodyEnd
        }
        return bodies
    }

    /**
     * The offset of `<prefix:name` or `</prefix:name`, whichever [closing] says.
     *
     * The name is compared **without** its prefix, because the prefix is whatever
     * the server chose — `d:` on Nextcloud, `D:` on others, none at all on a few —
     * and a parser that expects the RFC's example reads a real share as empty.
     */
    private fun String.indexOfTag(name: String, from: Int, closing: Boolean): Int? {
        var index = from
        while (index < length) {
            val open = indexOf('<', index)
            if (open < 0) return null
            val close = indexOf('>', open)
            if (close < 0) return null
            val tag = substring(open + 1, close).trim()
            // A declaration, a comment and a doctype are not elements.
            if (!tag.startsWith("?") && !tag.startsWith("!")) {
                val isClosingTag = tag.startsWith("/")
                val local = tag.removePrefix("/")
                    .substringBefore(' ')
                    .substringBefore('/')
                    .substringAfterLast(':')
                // A closing tag only matches a closing search and the other way
                // round, so looking for `href` never lands on `</href>`.
                if (isClosingTag == closing && local.equals(name, ignoreCase = true)) return open
            }
            index = close + 1
        }
        return null
    }

    private fun String.indexOfOpeningTag(name: String, from: Int): Int? = indexOfTag(name, from, closing = false)

    private fun String.indexOfClosingTag(name: String, from: Int): Int? = indexOfTag(name, from, closing = true)

    /** The text of the first `<name>` inside this body, or null. */
    private fun String.textOf(name: String): String? {
        val open = indexOfOpeningTag(name, 0) ?: return null
        val close = indexOf('>', open)
        if (close < 0 || this[close - 1] == '/') return null
        val bodyStart = close + 1
        val bodyEnd = indexOfClosingTag(name, bodyStart) ?: return null
        return substring(bodyStart, bodyEnd).trim()
    }

    /** Whether a `<parent>` inside this body contains a `<child>`. */
    private fun String.hasChild(parent: String, child: String): Boolean {
        val open = indexOfOpeningTag(parent, 0) ?: return false
        val close = indexOf('>', open)
        if (close < 0 || this[close - 1] == '/') return false
        val inner = indexOfClosingTag(parent, close + 1) ?: return false
        return substring(close + 1, inner).indexOfOpeningTag(child, 0) != null
    }
}

/** A refusal from a WebDAV server, in the terms a person can act on. */
class WebDavException(message: String) : Exception(message)

/**
 * Why a connection attempt did not work, as a sentence.
 *
 * Distinct from [WebDavException] because it answers a different question. A listing
 * failure is about the server; this is about the *credentials or the address*, and it
 * is what a settings field shows under itself as somebody types.
 */
sealed interface WebDavFailure {
    fun message(): String

    data class Address(val problem: String) : WebDavFailure {
        override fun message(): String = problem
    }

    data class Refused(val status: Int, val detail: String) : WebDavFailure {
        override fun message(): String = when (status) {
            401 -> "That server did not accept the username and password."
            403 -> "That account is not allowed to read this folder."
            404 -> "There is nothing at that address."
            405 -> "That address is not a WebDAV share."
            in 500..599 -> "The server had a problem ($status). It is the server's, not yours."
            else -> "The server answered $status."
        }
    }

    data class Unreachable(val detail: String) : WebDavFailure {
        override fun message(): String = "Couldn’t reach that server."
    }

    companion object {
        /** A failure read off a response, mapped to the sentence for its status. */
        fun describe(response: RawHttpText, prefix: String): WebDavFailure = when (val status = response.status) {
            401, 403, 404, 405 -> Refused(status, prefix)
            in 500..599 -> Refused(status, prefix)
            else -> Unreachable(prefix)
        }
    }
}
