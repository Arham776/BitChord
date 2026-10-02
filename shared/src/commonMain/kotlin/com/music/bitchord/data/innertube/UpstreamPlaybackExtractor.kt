package com.music.bitchord.data.innertube

import com.metrolist.innertubex.InnerTube
import com.metrolist.innertubex.InnerTubeLogger
import com.metrolist.innertubex.cipher.PlayerConfigRepository
import com.metrolist.innertubex.cipher.RemotePlayerConfigStore
import com.metrolist.innertubex.cipher.YouTubeCipherService
import com.metrolist.innertubex.extraction.AudioQuality
import com.metrolist.innertubex.extraction.ContentHints
import com.metrolist.innertubex.extraction.InnerTubeExtractor
import com.metrolist.innertubex.extraction.generateClientPlaybackNonce
import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.time.TimeSource
import kotlin.time.TimeMark
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Same maintained extraction stack as Android upstream, on the shared Darwin transport. */
@OptIn(ExperimentalAtomicApi::class)
internal object UpstreamPlaybackExtractor {
    private class Session(val generation: Long, val innerTube: InnerTube, val extractor: InnerTubeExtractor, val cipher: YouTubeCipherService)
    private data class Issued(val id: String, val profile: String, val generation: Long)
    private val refreshScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val issued = AtomicReference<Map<String, Issued>>(emptyMap())
    private val excluded = AtomicReference<Map<String, TimeMark>>(emptyMap())
    fun onRefused(url: String, excludeClient: Boolean = false) {
        val origin = issued.load()[url] ?: return
        if (origin.generation != Innertube.sessionGeneration) return
        if (excludeClient) while (true) {
            val old = excluded.load()
            val next = (if (old.size >= 64) emptyMap() else old) + ("${origin.generation}:${origin.id}:${origin.profile}" to TimeSource.Monotonic.markNow())
            if (excluded.compareAndSet(old, next)) break
        }
        refreshScope.launch {
            lock.withLock { session?.takeIf { it.generation == origin.generation }?.cipher }
                ?.let { runCatching { it.refreshAfterStreamRejection() } }
        }
    }
    private val lock = Mutex()
    private var session: Session? = null
    private val logger = InnerTubeLogger { event ->
        // Library diagnostics may contain signed URLs. The shared redactor is
        // applied before anything reaches the system log; never print details maps.
        DebugLog.d("ITX ${event.tag}: ${event.message}")
    }
    private suspend fun current(): Session {
        val generation = Innertube.sessionGeneration
        if (Innertube.cookie != null) Innertube.ensureSessionScope()
        Innertube.checkSession(generation)
        return lock.withLock {
            session?.takeIf { it.generation == generation }?.let { return@withLock it }
            session?.let { it.innerTube.close(); it.cipher.dispose() }
            val snapshot = Innertube.requestSession()
            val tube = InnerTube(Http.client, logger = logger)
            tube.replaceSession(snapshot.cookie, snapshot.visitor, snapshot.dataSyncId,
                snapshot.authUser ?: "0", useLoginForBrowse = snapshot.cookie != null)
            val repository = object : PlayerConfigRepository {
                override val enabled = true
                override val sourceUrl = "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json"
                override val defaultSourceUrl = sourceUrl
                override var cachedJson = ""
                override var cachedAtMs = 0L
                override var cachedSourceUrl = ""
                override var cachedEtag = ""
            }
            val store = RemotePlayerConfigStore(Http.client, repository, logger)
            val cipher = YouTubeCipherService(Http.client, store, logger)
            val extractor = InnerTubeExtractor(
                configParser = com.metrolist.innertubex.extraction.YtConfigParserImpl(Http.client, tube, store, cipherService = cipher),
                cipherService = cipher, innerTube = tube, tokenProvider = PlaybackTokenBridge.tokenProvider(), logger = logger)
            Session(generation, tube, extractor, cipher).also { session = it }
        }
    }
    suspend fun extract(videoId: String, maxKbps: Int): StreamResolver.ResolvedStream? {
        val session = current()
        val stream = session.extractor.extract(
            videoId = videoId,
            hints = ContentHints(wantVideo = false).withStreamCapabilities(allowHls = false, allowSabr = false, allowBoundedRange = true),
            excludedClients = excluded.load().filter { (key, at) ->
                key.startsWith("${session.generation}:$videoId:") && at.elapsedNow() < 5.minutes
            }.keys.map { it.substringAfterLast(":") }.toSet(),
            audioQuality = if (maxKbps <= 64) AudioQuality.LOW else AudioQuality.AUTO,
            clientPlaybackNonce = generateClientPlaybackNonce()) ?: return null
        Innertube.checkSession(session.generation)
        check(stream.sabrBootstrap == null) { "This audio engine requires a progressive stream" }
        while (true) {
            val old = issued.load()
            val next = (if (old.size >= 64) emptyMap() else old) + (stream.audioUrl to Issued(videoId, stream.profileId, session.generation))
            if (issued.compareAndSet(old, next)) break
        }
        DebugLog.d("$videoId: upstream ${stream.profileId} selected ${(stream.bitrate ?: 0) / 1000}kbps")
        return StreamResolver.ResolvedStream(stream.audioUrl, (stream.bitrate ?: 0) / 1000,
            stream.mimeType.orEmpty() + (stream.codecs?.let { "; codecs=\"$it\"" } ?: ""),
            stream.headers, stream.loudnessDb, stream.mediaMetadata?.durationSeconds?.takeIf { it > 0 })
    }
}
