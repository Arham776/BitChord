package com.music.bitchord.data.innertube

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class PlaybackHistoryReporterTest {
    private data class Play(val id: String, val token: Int)
    private data class Report(val play: Play, val seconds: Long, val final: Boolean)

    @Test fun signingInDuringPlaybackStartsHistoryAndLateResetPreservesTheNewSession() = runTest {
        var generation = 1L
        val starts = mutableListOf<Play>()
        val reports = mutableListOf<Report>()
        val reporter = PlaybackHistoryReporter(
            scope = backgroundScope, generation = { generation },
            open = { id, account -> Play(id, account.toInt()).also { starts += it } },
            watchtime = { play, seconds, final -> reports += Report(play, seconds, final) },
            atr = {}, atrAfter = { 5L },
        )
        // No start event: playback began as a guest before sign-in.
        reporter.onProgress("song", 35)
        runCurrent()
        assertEquals(1, starts.size)
        generation = 2
        reporter.onProgress("song", 36)
        reporter.onSessionChanged()
        runCurrent()
        reporter.onStopped(40)
        runCurrent()
        assertEquals(listOf(1, 2), starts.map { it.token })
        assertEquals(2, reports.last().play.token)
        assertTrue(reports.last().final)
    }

    @Test fun repeatedPlaysHaveSeparateStartsAndFinalWatchtime() = runTest {
        val starts = mutableListOf<Play>()
        val reports = mutableListOf<Report>()
        val atr = mutableListOf<Play>()
        val reporter = PlaybackHistoryReporter(
            scope = backgroundScope, generation = { 1L },
            open = { id, _ -> Play(id, starts.size).also { starts += it } },
            watchtime = { play, seconds, final -> reports += Report(play, seconds, final) },
            atr = { atr += it }, atrAfter = { 5L },
        )
        repeat(3) {
            reporter.onPlaying("same-song")
            reporter.onPlaying("same-song") // repeated transport notification is not a play
            runCurrent()
            reporter.onProgress("same-song", 5)
            reporter.onProgress("same-song", 31)
            reporter.onProgress("same-song", 32)
            runCurrent()
            reporter.onStopped(60)
            runCurrent()
        }
        assertEquals(3, starts.size)
        assertEquals(3, starts.map { it.token }.distinct().size)
        assertEquals(3, atr.size)
        assertEquals(listOf(31L, 60L, 31L, 60L, 31L, 60L), reports.map { it.seconds })
        assertEquals(3, reports.count { it.final })
    }

    @Test fun delayedStartReportsItsOwnSkippedPlayWithoutReplacingTheNewSong() = runTest {
        val gate = CompletableDeferred<Unit>()
        val reports = mutableListOf<Report>()
        val reporter = PlaybackHistoryReporter(
            scope = backgroundScope, generation = { 1L },
            open = { id, _ -> if (id == "old") gate.await(); Play(id, 0) },
            watchtime = { play, seconds, final -> reports += Report(play, seconds, final) },
            atr = {}, atrAfter = { 5L },
        )
        reporter.onPlaying("old")
        runCurrent()
        reporter.onStopped(4)
        reporter.onPlaying("new")
        runCurrent()
        gate.complete(Unit)
        runCurrent()
        reporter.onProgress("new", 35)
        reporter.onStopped(40)
        runCurrent()
        assertEquals(listOf("old", "new", "new"), reports.map { it.play.id })
        assertEquals(listOf(4L, 35L, 40L), reports.map { it.seconds })
        assertTrue(reports.first().final)
    }

    @Test fun accountChangeDropsOldTrackingUrlsAndResetsSameSongIdentity() = runTest {
        var generation = 1L
        val gate = CompletableDeferred<Unit>()
        val reports = mutableListOf<Report>()
        val starts = mutableListOf<Play>()
        val reporter = PlaybackHistoryReporter(
            scope = backgroundScope, generation = { generation },
            open = { id, account ->
                if (account == 1L) gate.await()
                Play(id, account.toInt()).also { starts += it }
            },
            watchtime = { play, seconds, final -> reports += Report(play, seconds, final) },
            atr = {}, atrAfter = { 5L },
        )
        reporter.onPlaying("same")
        runCurrent()
        generation = 2
        reporter.onSessionChanged()
        reporter.onPlaying("same")
        runCurrent()
        gate.complete(Unit)
        runCurrent()
        reporter.onProgress("same", 35)
        reporter.onStopped(40)
        runCurrent()
        assertTrue(reports.all { it.play.token == 2 })
        assertEquals(2, reports.size)
    }

    @Test fun progressDuringOpenIsRetainedAndWrongTrackProgressIsIgnored() = runTest {
        val gate = CompletableDeferred<Unit>()
        val reports = mutableListOf<Report>()
        val reporter = PlaybackHistoryReporter(
            scope = backgroundScope, generation = { 1L },
            open = { id, _ -> gate.await(); Play(id, 0) },
            watchtime = { play, seconds, final -> reports += Report(play, seconds, final) },
            atr = {}, atrAfter = { 5L },
        )
        reporter.onPlaying("song")
        reporter.onProgress("song", 35)
        reporter.onProgress("other", 90)
        runCurrent()
        gate.complete(Unit)
        runCurrent()
        assertEquals(listOf(35L), reports.map { it.seconds })
    }
}
