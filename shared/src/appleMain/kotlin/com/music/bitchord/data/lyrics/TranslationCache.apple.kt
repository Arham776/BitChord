@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.music.bitchord.data.lyrics

import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileModificationDate
import platform.Foundation.NSString
import platform.Foundation.NSURL
import platform.Foundation.NSUserDomainMask
import platform.Foundation.create
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.writeToFile

/**
 * The translation cache on disk: one file per translation, in the caches
 * directory.
 *
 * ## Why the caches directory and not preferences
 *
 * A translation of a whole lyric is a few kilobytes and there are hundreds of
 * them. That is files, not preferences — `UserDefaults` is a property list, it
 * is loaded whole, and a few hundred kilobytes of JSON in it would be paid on
 * every settings read and would then travel in every backup.
 *
 * Upstream uses the Android cache directory, and that is the right answer on
 * Apple too: the OS may reclaim it under pressure without the app's help, which
 * is exactly the contract a cache wants and exactly what a preferences key does
 * not offer.
 *
 * ## The name
 *
 * A digest of the cache key rather than the key itself. A track id is arbitrary
 * text from a remote catalogue and can contain slashes, so using it as a filename
 * would be a path-traversal hazard; a hex digest cannot.
 *
 * Paths are handled as `String` rather than `NSURL` throughout. `NSURL`'s resource
 * accessors are awkward across the Kotlin/Native bridge, and the one thing this
 * needs from the file system — a modification date, for the prune — is available
 * on `NSFileManager` directly.
 */
private const val MAX_ENTRIES = 200

private const val CACHE_DIRECTORY = "lyrics-translation"

private const val UTF8 = 4uL // NSUTF8StringEncoding

internal actual fun read(key: String): String? {
    val path = entryPath(key) ?: return null
    if (!NSFileManager.defaultManager.fileExistsAtPath(path)) return null
    return NSString.stringWithContentsOfFile(path, UTF8, null)?.toString()
}

/**
 * Write, then make room.
 *
 * Order matters: the entry is written first so a failure to prune leaves a
 * slightly large cache rather than a missing one, and the new file's own
 * modification date is what makes it the *newest* under the prune — so the thing
 * just computed is never the thing thrown away.
 */
internal actual fun write(key: String, document: String) {
    val path = entryPath(key) ?: return
    NSString.create(string = document).writeToFile(path, true, UTF8, null)
    prune()
}

internal actual fun removeAll() {
    directory()?.let { NSFileManager.defaultManager.removeItemAtPath(it, null) }
    directory()
}

private fun prune() {
    val root = directory() ?: return
    val manager = NSFileManager.defaultManager
    val names = manager.contentsOfDirectoryAtPath(root, null) as? List<*> ?: return
    if (names.size <= MAX_ENTRIES) return

    // Oldest first. The modification date is the only ordering available without
    // writing an index of our own, and for a cache written almost entirely in
    // play order it is the right ordering anyway.
    val dated = names.filterIsInstance<String>()
        .mapNotNull { name ->
            val modified = manager.attributesOfItemAtPath("$root/$name", null)
                ?.get(NSFileModificationDate) as? Double
            name to (modified ?: 0.0)
        }
        .sortedBy { it.second }
    dated.take(names.size - MAX_ENTRIES).forEach { (name, _) ->
        manager.removeItemAtPath("$root/$name", null)
    }
}

/** The caches subdirectory, created on demand. Null if it cannot be made. */
private fun directory(): String? {
    val base = NSFileManager.defaultManager.URLsForDirectory(
        NSCachesDirectory,
        NSUserDomainMask,
    ).firstOrNull() as? NSURL ?: return null
    val path = base.path ?: return null
    val directory = "$path/$CACHE_DIRECTORY"
    val manager = NSFileManager.defaultManager
    if (!manager.fileExistsAtPath(directory)) {
        manager.createDirectoryAtPath(
            directory,
            withIntermediateDirectories = true,
            attributes = null,
            error = null,
        )
    }
    return directory
}

private fun entryPath(key: String): String? = directory()?.let { "$it/${key.stableHash()}.json" }

/**
 * A stable, filename-safe digest of a string.
 *
 * FNV-1a: short, in common code, and the only property that matters for choosing
 * a *filename* is that it does not change between launches — which rules out
 * anything seeded per process.
 */
internal fun String.stableHash(): String {
    var hash = -0x340d631b7bdddcdbL
    for (ch in this) {
        hash = hash xor ch.code.toLong()
        hash *= 0x100000001b3L
    }
    return hash.toULong().toString(16).padStart(16, '0')
}
