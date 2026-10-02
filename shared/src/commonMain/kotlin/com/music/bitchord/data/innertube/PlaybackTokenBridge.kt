package com.music.bitchord.data.innertube

import com.metrolist.innertubex.extraction.*
import com.metrolist.innertubex.extraction.strategy.PoTokenProviderKind
import com.music.bitchord.data.http.Http
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.coroutines.resume

/** Native WebKit attestation, matching upstream's hidden BotGuard WebView. */
@OptIn(ExperimentalAtomicApi::class)
object PlaybackTokenBridge {
    interface Provider { fun generate(videoId: String, visitorData: String, callback: TokenCallback) }
    fun interface TokenCallback { fun onResult(playerToken: String?, streamingToken: String?) }
    fun interface ChallengeCallback { fun onResult(json: String?, message: String?) }
    private val native = AtomicReference<Provider?>(null)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    fun register(provider: Provider) { native.store(provider) }
    internal fun tokenProvider(): TokenProvider = object : TokenProvider {
        override val capabilities: TokenProviderCapabilities
            get() = if (native.load() == null) TokenProviderCapabilities() else
                TokenProviderCapabilities(setOf(PoTokenProviderKind.WEB_BOTGUARD), usesWebView = true)
        override suspend fun getPoToken(videoId: String, visitorData: String, cookie: String?): PoTokenResult? {
            val provider = native.load() ?: return null
            val generation = Innertube.sessionGeneration
            return withTimeoutOrNull(8_000) {
                suspendCancellableCoroutine { continuation ->
                    provider.generate(videoId, visitorData) { player, streaming ->
                        if (continuation.isActive) continuation.resume(
                            if (generation == Innertube.sessionGeneration && !player.isNullOrBlank() && !streaming.isNullOrBlank())
                                mapTokens(visitorData, player, streaming) else null)
                    }
                }
            }
        }
    }
    /** Match upstream's binding semantics: visitor for PLAYER, video for GVS. */
    internal fun mapTokens(visitor: String, videoToken: String, visitorToken: String): PoTokenResult =
        PoTokenResult(playerRequestToken = visitorToken, streamingDataToken = videoToken, visitorData = visitor)

    /** Fixed, credential-free Google challenge routes on the shared transport. */
    fun challenge(botguardResponse: String?, callback: ChallengeCallback) {
        scope.launch {
            try {
                val response = withTimeout(8_000) {
                    Http.client.post("https://www.youtube.com/api/jnn/v1/" + if (botguardResponse == null) "Create" else "GenerateIT") {
                        contentType(ContentType("application", "json+protobuf"))
                        header("Accept", "application/json")
                        // Upstream uses a cookie-free challenge client; bypass the provider jar.
                        header("Cookie", "")
                        header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3")
                        header("x-goog-api-key", "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw")
                        header("x-user-agent", "grpc-web-javascript/0.1")
                        setBody(buildJsonArray { add("O43z0dpjhgX20SCx4KAo"); botguardResponse?.let { add(it) } }.toString())
                    }.let { response ->
                        check(response.status.value == 200) { "Challenge service unavailable" }
                        response.bodyAsText().also { check(it.length <= 2 * 1024 * 1024) }
                    }
                }
                callback.onResult(response, null)
            } catch (_: Exception) { callback.onResult(null, "Web playback verification unavailable") }
        }
    }
}
