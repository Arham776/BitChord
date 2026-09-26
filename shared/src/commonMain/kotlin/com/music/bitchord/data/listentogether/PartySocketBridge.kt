package com.music.bitchord.data.listentogether

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.concurrent.Volatile
import kotlin.coroutines.resume

/**
 * The party socket, as a platform seam.
 *
 * ## Why this is Swift and not Kotlin
 *
 * Ktor's `ktor-client-websockets` is an **empty shell on Darwin** — the artifact
 * resolves, the dependency graph is correct, and the package contains nothing. And
 * the alternative, `NSURLSessionWebSocketTask` through Kotlin/Native's ObjC interop,
 * is a losing fight: `NSMutableURLRequest.setValue(_:forHTTPHeaderField:)` does not
 * resolve under any spelling, and a token has to travel in a header.
 *
 * So it is written in Swift, the way `ModuleJsEngine` and `Http.probe` already are.
 * `URLSessionWebSocketTask` in Swift is short, native, and gives the close code and
 * the ping/pong this protocol actually needs. Nothing is lost: the frames, the
 * reconnect policy and the clock all stay in portable code above this line.
 *
 * ## What the implementation is told, and not asked to decide
 *
 * It is given a base, a code and a token, and it is given a callback. It is *not*
 * asked to parse frames, to apply them, to know what a party is, or to decide when
 * to give up — every one of those is policy, and policy that lives in Swift is
 * policy that cannot be tested without a socket. The one decision it does make is
 * the one only it can: [Impl.onBye] tells [PartySession] that the server ended the
 * session on purpose, which is the single fact that must stop a reconnect loop.
 */
object PartySocketBridge {

    interface Impl {
        /**
         * Connect and stay connected, reporting each frame as it arrives.
         *
         * Returns immediately; the socket runs until [stop] or until the server
         * ends the session on purpose.
         */
        fun connect(base: String, code: String, token: String, onFrame: FrameCallback)

        fun stop()

        /**
         * Send one already-encoded frame.
         *
         * Takes JSON rather than a [PartyOutgoing] because the one frame the client
         * originates on a timer — the playhead report — is built by
         * [PartyOutgoingJson] and sent straight from [PartySync], and routing it
         * through a sealed type just to hand it back unchanged would be a hop with
         * no purpose.
         */
        fun sendRaw(json: String)
    }

    fun interface FrameCallback {
        /** A frame as raw JSON, or null when the socket closed without one. */
        fun onFrame(json: String?)
    }

    @Volatile
    private var impl: Impl? = null

    fun setImpl(value: Impl?) {
        impl = value
    }

    val isWired: Boolean get() = impl != null

    /**
     * Start the socket, and call [onFrame] for every frame until it ends.
     *
     * Suspends until the socket stops, so a caller can await a session's end. The
     * frames themselves go to the callback rather than being returned, because there
     * are unboundedly many of them and the end is the only thing worth awaiting.
     */
    suspend fun connect(base: String, code: String, token: String, onFrame: (String) -> Unit) {
        val bridge = impl ?: return
        suspendCancellableCoroutine<Unit> { cont ->
            val callback = FrameCallback { json ->
                if (json != null) onFrame(json)
            }
            bridge.connect(base, code, token, callback)
            cont.invokeOnCancellation { bridge.stop() }
            // Nothing resumes this: the caller's scope cancellation is the only exit,
            // which is right — a party ends when the user leaves it or the server
            // says so, and neither is a return value of "connect".
        }
    }

    fun stop() {
        impl?.stop()
    }

    /**
     * Send one frame, or drop it when the socket is not up.
     *
     * Dropping rather than queueing is deliberate for the one frame that uses this: a
     * playhead report describes *now*, and a report that arrives late is worse than
     * no report — it would describe a position the device has already left.
     */
    fun sendRaw(json: String) {
        impl?.sendRaw(json)
    }
}
