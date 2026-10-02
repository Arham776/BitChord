package com.metrolist.innertubex.cipher

import com.metrolist.innertubex.InnerTubeLogger
import kotlinx.coroutines.runBlocking
import kotlin.test.Test

/** Exercise the native runtime and embedded resources, rather than only parser fixtures. */
class AppleEjsRuntimeTest {
    @Test fun embeddedSolverBootstraps() = runBlocking {
        val engine = QuickJsEngine()
        try {
            engine.initialize()
            engine.setupYoutubeGlobals()
            engine.execute("globalThis.bitChordRuntimeReady = true")
            EjsChallengeSolver(engine, InnerTubeLogger.NONE).ensureLoaded()
        } finally { engine.dispose() }
    }
}
