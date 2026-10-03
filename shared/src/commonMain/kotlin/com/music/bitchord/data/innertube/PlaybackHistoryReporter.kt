package com.music.bitchord.data.innertube

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Serializes transport events while tracking requests run in the background.
 * Each play, including another lap of the same song, owns a separate request.
 * A late open can finish reporting its own short play, never become the new song.
 */
internal class PlaybackHistoryReporter<T : Any>(
    private val scope: CoroutineScope,
    private val generation: () -> Long,
    private val open: suspend (String, Long) -> T?,
    private val watchtime: suspend (T, Long, Boolean) -> Unit,
    private val atr: suspend (T) -> Unit,
    private val atrAfter: (T) -> Long,
) {
    private sealed interface Event {
        data class Start(val id: String, val generation: Long) : Event
        data class Progress(val id: String, val seconds: Long, val generation: Long) : Event
        data class Stop(val seconds: Long) : Event
        data class Reset(val generation: Long) : Event
        class Opened<T : Any>(val request: Request<T>, val value: T) : Event
    }
    private class Request<T : Any>(val id: String, val generation: Long) {
        var latestPosition = 0L
        var finalPosition: Long? = null
        var session: Session<T>? = null
    }
    private class Session<T : Any>(val value: T) {
        val reportLock = Mutex()
        var scheduledSeconds = 0L
        var reportedSeconds = 0L // only accessed with reportLock held
        var atrSent = false
    }
    private val events = Channel<Event>(Channel.UNLIMITED)
    private var current: Request<T>? = null

    init {
        scope.launch {
            for (event in events) when (event) {
                is Event.Start -> start(event)
                is Event.Progress -> {
                    if (event.generation != generation()) continue
                    // A listener may sign in while a guest-started song is still
                    // playing. Its first signed-in progress opens history tracking.
                    if (current == null || current?.generation != event.generation) {
                        start(Event.Start(event.id, event.generation))
                    }
                    val request = current ?: continue
                    if (request.id != event.id || request.generation != generation()) continue
                    request.latestPosition = event.seconds.coerceAtLeast(0)
                    request.session?.let { progress(request, it) }
                }
                is Event.Stop -> {
                    val request = current ?: continue
                    current = null
                    request.finalPosition = event.seconds.coerceAtLeast(0)
                    request.session?.let { flush(request, it, request.finalPosition!!, final = true) }
                }
                is Event.Reset -> if (current?.generation != event.generation) current = null
                is Event.Opened<*> -> {
                    @Suppress("UNCHECKED_CAST")
                    val opened = event as Event.Opened<T>
                    val request = opened.request
                    if (request.generation != generation()) continue
                    val session = Session(opened.value)
                    request.session = session
                    if (request === current) progress(request, session)
                    else request.finalPosition?.let { flush(request, session, it, final = true) }
                }
            }
        }
    }

    fun onPlaying(id: String) { events.trySend(Event.Start(id, generation())) }
    fun onProgress(id: String, seconds: Long) { events.trySend(Event.Progress(id, seconds, generation())) }
    fun onStopped(seconds: Long) { events.trySend(Event.Stop(seconds)) }
    fun onSessionChanged() { events.trySend(Event.Reset(generation())) }

    private fun start(event: Event.Start) {
        if (event.generation != generation()) return
        if (current?.id == event.id && current?.generation == event.generation) return
        val request = Request<T>(event.id, event.generation)
        current = request
        scope.launch {
            repeat(3) { attempt ->
                if (request.generation != generation()) return@launch
                val value = try { open(request.id, request.generation) }
                catch (e: CancellationException) { throw e }
                catch (_: Throwable) { null }
                if (value != null) {
                    events.send(Event.Opened(request, value))
                    return@launch
                }
                if (attempt < 2) delay(2_000)
            }
        }
    }

    private fun progress(request: Request<T>, session: Session<T>) {
        if (!session.atrSent && request.latestPosition >= atrAfter(session.value)) {
            session.atrSent = true
            scope.launch {
                if (request.generation == generation()) runCatching { atr(session.value) }
            }
        }
        if (request.latestPosition - session.scheduledSeconds >= 30) {
            flush(request, session, request.latestPosition, final = false)
        }
    }

    private fun flush(request: Request<T>, session: Session<T>, seconds: Long, final: Boolean) {
        session.scheduledSeconds = maxOf(session.scheduledSeconds, seconds)
        scope.launch {
            session.reportLock.withLock {
                if (request.generation != generation()) return@withLock
                if (!final && seconds <= session.reportedSeconds) return@withLock
                runCatching { watchtime(session.value, seconds, final) }.onSuccess {
                    session.reportedSeconds = maxOf(session.reportedSeconds, seconds)
                }
            }
        }
    }
}
