package com.music.bitchord.data.sources

import com.music.bitchord.data.model.Song
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of the judgements upstream pins down in `TrackMatcher`'s own tests, plus
 * the three that bit this port specifically.
 *
 * Every case here is one of the two silent failures the matcher's header names:
 * too loose and the wrong recording plays under the right title, too strict and a
 * source the user configured is quietly never used. Neither shows up as a crash or
 * a log line, which is exactly why they are worth pinning.
 */
class TrackMatcherTest {

    private fun song(
        title: String,
        artist: String,
        duration: String? = null,
        album: String? = null,
        explicit: Boolean? = null,
        video: Boolean = false,
        id: String = "x",
    ) = Song(
        videoId = id,
        title = title,
        artist = artist,
        durationText = duration,
        albumName = album,
        isExplicit = explicit,
        isVideo = video,
    )

    // ── Identity: what must agree ───────────────────────────────────────────

    @Test
    fun refusesADifferentRecordingOfTheSameTitle() {
        val target = TrackMatcher.Target("Yesterday", "The Beatles", 125)
        // A *different* runtime, which is the realistic cover case: a cover is a
        // different recording and usually says so with its length.
        val cover = song("Yesterday", "David Cover", "4:41")
        assertNull(TrackMatcher.score(cover, target), "a different singer is a different recording")
    }

    /**
     * The same title under a different singer is admitted when the runtimes agree
     * *exactly* — deliberately, and only as a last resort.
     *
     * That is the `CREDITS_DISAGREE` override, and it exists because catalogues
     * genuinely describe one recording from different ends of it: a film score
     * filed under its composer in one place and its singer in every other. Nothing
     * in either credit hints at the other, so the tie is broken by length.
     *
     * Pinned here because it is a real behaviour, not an accident: it means a cover
     * that happens to run the same length is *eligible*, and the only thing keeping
     * it from playing is that any properly-credited candidate outranks it. The two
     * tests below are the pair that makes that safe.
     */
    @Test
    fun anExactRuntimeAdmitsACoverButOnlyAsALastResort() {
        val target = TrackMatcher.Target("Yesterday", "The Beatles", 125)
        val cover = song("Yesterday", "David Cover", "2:05")
        val coverScore = TrackMatcher.score(cover, target)
        assertNotNull(coverScore, "an exact runtime is the tie-breaker when the credits disagree")
        val creditedScore = TrackMatcher.score(song("Yesterday", "The Beatles", "2:05"), target)
        assertNotNull(creditedScore)
        assertTrue(
            creditedScore > coverScore,
            "a proper credit must always outrank the override: $creditedScore vs $coverScore",
        )
    }

    @Test
    fun refusesTheOtherDirectionOfAVersionMarker() {
        val albumCut = TrackMatcher.Target("Bohemian Rhapsody", "Queen", 355)
        assertNull(
            TrackMatcher.score(song("Bohemian Rhapsody (Live)", "Queen", "5:55"), albumCut),
            "asking for the album cut must not land on the live take",
        )
        val liveTake = TrackMatcher.Target("Bohemian Rhapsody (Live)", "Queen", 355)
        assertNull(
            TrackMatcher.score(song("Bohemian Rhapsody", "Queen", "5:55"), liveTake),
            "asking for the live take must not land on the album cut",
        )
    }

    @Test
    fun acceptsTheSameRecording() {
        val target = TrackMatcher.Target("Paniyon Sa", "Atif Aslam", 300)
        assertNotNull(TrackMatcher.score(song("Paniyon Sa", "Atif Aslam", "5:00"), target))
    }

    /**
     * The one that kept a source out of the way of the very tracks it held: a
     * *partial* credit is a formatting choice, not a disagreement. "Atif Aslam" and
     * "Atif Aslam, Tulsi Kumar" are one recording with two spellings.
     */
    @Test
    fun acceptsAPartialCredit() {
        val target = TrackMatcher.Target("Paniyon Sa", "Atif Aslam", 300)
        assertNotNull(
            TrackMatcher.score(song("Paniyon Sa", "Atif Aslam, Tulsi Kumar", "5:00"), target),
            "a duet with only one singer in the title is still the duet",
        )
    }

    @Test
    fun acceptsAnInitialledCredit() {
        val target = TrackMatcher.Target("Jai Ho", "A. R. Rahman", 320)
        assertNotNull(TrackMatcher.score(song("Jai Ho", "AR Rahman", "5:20"), target))
    }

    @Test
    fun matchesAcrossPackagingInTheTitle() {
        // The YouTube title carries the film; the catalogue listing does not.
        val target = TrackMatcher.Target("Paniyon Sa", "Atif Aslam", 300)
        assertNotNull(
            TrackMatcher.score(song("Paniyon Sa (From \"Satyamev Jayate\")", "Atif Aslam", "5:00"), target),
        )
    }

    @Test
    fun doesNotMatchQueenInsideQueensryche() {
        val target = TrackMatcher.Target("Bohemian Rhapsody", "Queen", 355)
        assertNull(
            TrackMatcher.score(song("Bohemian Rhapsody", "Queensrÿche", "6:12"), target),
            "a name inside a longer name is not a credit",
        )
    }

    // ── Duration ────────────────────────────────────────────────────────────

    @Test
    fun refusesADifferentCutOfTheSameSong() {
        // A DJ edit on a compilation carries the right title and artist. Three
        // regimes, and the middle one is the one worth stating explicitly:
        //
        //  - inside 30s: a loose match, scored low. Enough for a catalogue rounding
        //    or a second of lead-in trimmed differently.
        //  - 30–90s with a *shared credit*: allowed, at zero duration credit. This
        //    is the video-drift allowance — a music video runs long because of a
        //    visual outro, and the flag cannot be the only way through it, so an
        //    exact title/version plus a shared artist is accepted instead. It is
        //    deliberately gated on the credit: duration must never make an
        //    unrelated artist into the song.
        //  - past 90s, or past 30s with a different artist: refused.
        val target = TrackMatcher.Target("Punjabi Dj Holi Songs", "Various", 180)
        assertNotNull(
            TrackMatcher.score(song("Punjabi Dj Holi Songs", "Various", "3:05"), target),
            "a five-second drift inside the limit is a loose match",
        )
        assertNotNull(
            TrackMatcher.score(song("Punjabi Dj Holi Songs", "Various", "4:12"), target),
            "a shared credit earns the wider window",
        )
        assertNull(
            TrackMatcher.score(song("Punjabi Dj Holi Songs", "Some Other Act", "4:12"), target),
            "a different artist does not, whatever the runtime",
        )
        assertNull(
            TrackMatcher.score(song("Punjabi Dj Holi Songs", "Various", "6:00"), target),
            "past the wider window it is a different recording",
        )
    }

    @Test
    fun aSevereRuntimeDifferenceIsNotTheSameRecording() {
        assertTrue(TrackMatcher.isSevereMismatch(180, 241))
        assertFalse(TrackMatcher.isSevereMismatch(180, 182))
        assertFalse(TrackMatcher.isSevereMismatch(null, 241), "an unknown length is not a mismatch")
    }

    @Test
    fun aVideoMayRunLongerThanItsAudio() {
        // The audio cut beside the video: the row names the same artist, so the wider
        // window applies.
        val target = TrackMatcher.Target("Brown Rang", "Yo Yo Honey Singh", 211, isVideo = true)
        assertNotNull(
            TrackMatcher.score(song("Brown Rang", "Yo Yo Honey Singh", "2:31"), target),
            "a video's visual outro is credible drift when the artist agrees",
        )
    }

    // ── The credit-disagree override ────────────────────────────────────────

    /**
     * Film catalogues describe one recording from different ends of it: one files
     * "Jhak Maar Ke" under Pritam, who *wrote* it, every store under Neeraj
     * Shridhar, who *sang* it. Neither is wrong, and nothing in either credit hints
     * at the other — so the tie is broken by length, and only by an exact one.
     */
    @Test
    fun anExactRuntimeStandsInForAMissingSharedCredit() {
        val target = TrackMatcher.Target("Jhak Maar Ke", "Pritam", 233)
        assertNotNull(TrackMatcher.score(song("Jhak Maar Ke", "Neeraj Shridhar", "3:53"), target))
    }

    @Test
    fun anApproximateRuntimeDoesNot() {
        val target = TrackMatcher.Target("Jhak Maar Ke", "Pritam", 233)
        assertNull(
            TrackMatcher.score(song("Jhak Maar Ke", "Neeraj Shridhar", "3:50"), target),
            "three seconds either side is not the corroboration this needs",
        )
    }

    // ── Album and explicit ──────────────────────────────────────────────────

    @Test
    fun anExactReleaseBeatsACloserRuntime() {
        val target = TrackMatcher.Target("Hollow", "Twenty One Pilots", 300, album="Scaled and Icy")
        val wrongAlbum = song("Hollow", "Twenty One Pilots", "5:01", album="Blurryface")
        val rightAlbum = song("Hollow", "Twenty One Pilots", "5:00", album="Scaled and Icy")
        val ranked = TrackMatcher.ranked(listOf(wrongAlbum, rightAlbum), target)
        assertEquals(rightAlbum.videoId, ranked.first().videoId)
    }

    @Test
    fun anExplicitEditionMustAgreeWhenBothSaySo() {
        val target = TrackMatcher.Target("Wild Thoughts", "DJ Khaled", 200, isExplicit = true)
        assertNull(
            TrackMatcher.score(song("Wild Thoughts", "DJ Khaled", "3:20", explicit = false), target),
            "clean and uncensored are different masters",
        )
    }

    @Test
    fun anUnstatedEditionIsNotRejectedForHavingNoClaim() {
        val target = TrackMatcher.Target("Wild Thoughts", "DJ Khaled", 200, isExplicit = true)
        assertNotNull(
            TrackMatcher.score(song("Wild Thoughts", "DJ Khaled", "3:20", explicit = null), target),
        )
    }

    // ── Asking ──────────────────────────────────────────────────────────────

    @Test
    fun theSearchQueryDropsThePackagingButKeepsTheVersion() {
        val queries = TrackMatcher.queries(TrackMatcher.Target("Paniyon Sa (From \"Satyamev Jayate\")", "Atif Aslam"))
        assertTrue(queries.isNotEmpty())
        assertTrue(
            queries.none { "Satyamev" in it },
            "handing a catalogue words it has never stored is asking it not to match: $queries",
        )
        assertEquals(2, queries.size, "title+artist, then title alone")
    }

    @Test
    fun aVersionMarkerSurvivesIntoTheQuery() {
        val queries = TrackMatcher.queries(TrackMatcher.Target("Song (Acoustic)", "Artist"))
        assertTrue(
            queries.any { "acoustic" in it },
            "dropping the version marker would let the plain take answer for it: $queries",
        )
    }

    @Test
    fun anAlbumVersionIsNotAVersionMarker() {
        // "Album Version" and "Radio Edit" describe the ordinary release. Treating
        // them as versions would stop a source ever matching the plain listing.
        //
        // The title is "Clocks" and not "Song" because `song` is packaging noise and
        // is dropped from the core — a track genuinely titled "Song" therefore has
        // an empty core and matches nothing at all, which is upstream's behaviour
        // and a good reason not to use that word in a fixture.
        val target = TrackMatcher.Target("Clocks", "Coldplay", 300)
        assertNotNull(TrackMatcher.score(song("Clocks (Album Version)", "Coldplay", "5:00"), target))
        assertNotNull(TrackMatcher.score(song("Clocks (Radio Edit)", "Coldplay", "5:00"), target))
    }

    // ── Ranking ─────────────────────────────────────────────────────────────

    @Test
    fun takesTheBestMatchNotTheFirst() {
        val target = TrackMatcher.Target("Hollow", "Twenty One Pilots", 300, album = "Scaled and Icy")
        val candidates = listOf(
            song("Hollow (Live)", "Twenty One Pilots", "6:11", id = "live"),
            song("Hollow", "Some Cover", "3:20", id = "cover"),
            song("Hollow", "Twenty One Pilots", "5:00", album = "Scaled and Icy", id = "right"),
        )
        assertEquals("right", TrackMatcher.best(candidates, target)?.videoId)
    }

    @Test
    fun aProperlyCreditedRowBeatsOneTheRuntimeVouchedFor() {
        val target = TrackMatcher.Target("Jhak Maar Ke", "Pritam", 233)
        val candidates = listOf(
            song("Jhak Maar Ke", "Neeraj Shridhar", "3:53", id = "runtime"),
            song("Jhak Maar Ke", "Pritam", "3:53", id = "credited"),
        )
        assertEquals("credited", TrackMatcher.best(candidates, target)?.videoId)
    }

    // ── Video → audio ───────────────────────────────────────────────────────

    @Test
    fun findsTheCatalogueAudioForAVideoRow() {
        val target = TrackMatcher.Target("Brown Rang", "Yo Yo Honey Singh", 211, isVideo = true)
        val found = TrackMatcher.bestOfficialAudioForVideo(
            listOf(
                song("Brown Rang", "Different Artist", "3:31", id = "cover"),
                song("Brown Rang", "Yo Yo Honey Singh", "3:31", id = "audio"),
            ),
            target,
        )
        assertEquals("audio", found?.videoId)
    }

    // ── Catalogue collisions ────────────────────────────────────────────────

    @Test
    fun flagsConflictingReleasesWhenTheTargetNamesNone() {
        val target = TrackMatcher.Target("Song", "Artist", 200)
        val candidates = listOf(
            song("Song", "Artist", "3:20", album = "Original 2011", id = "a"),
            song("Song", "Artist", "3:21", album = "Compilation", id = "b"),
        )
        assertTrue(TrackMatcher.hasConflictingAlbums(candidates, target))
    }

    @Test
    fun doesNotFlagWhenTheTargetNamesTheRelease() {
        val target = TrackMatcher.Target("Song", "Artist", 200, album = "Original 2011")
        val candidates = listOf(
            song("Song", "Artist", "3:20", album = "Original 2011", id = "a"),
            song("Song", "Artist", "3:21", album = "Compilation", id = "b"),
        )
        assertFalse(TrackMatcher.hasConflictingAlbums(candidates, target))
    }

    @Test
    fun resolvesACollisionOnlyOnAUniquelyFullerCredit() {
        val target = TrackMatcher.Target("Jhak Maar Ke", "Pritam, Neeraj Shridhar, Arijit Singh", 233)
        val fuller = song("Jhak Maar Ke", "Neeraj Shridhar, Arijit Singh, Pritam", "3:53", id = "fuller")
        val abridged = song("Jhak Maar Ke", "Neeraj Shridhar", "3:53", id = "abridged")
        assertEquals(
            "fuller",
            TrackMatcher.uniquelyMostCreditedCloseMatch(listOf(abridged, fuller), target)?.videoId,
        )
    }

    @Test
    fun refusesACollisionOnATie() {
        val target = TrackMatcher.Target("Song", "Artist", 200)
        val candidates = listOf(
            song("Song", "Artist One", "3:20", album = "A", id = "a"),
            song("Song", "Artist Two", "3:21", album = "B", id = "b"),
        )
        assertNull(
            TrackMatcher.uniquelyMostCreditedCloseMatch(candidates, target),
            "a tie is not evidence, and guessing is what plays the wrong song",
        )
    }

    // ── Duration parsing ────────────────────────────────────────────────────

    @Test
    fun parsesBothDurationShapes() {
        assertEquals(225, TrackMatcher.secondsOf("3:45"))
        assertEquals(3723, TrackMatcher.secondsOf("1:02:03"))
        assertNull(TrackMatcher.secondsOf("3"))
        assertNull(TrackMatcher.secondsOf("0:00"))
        assertNull(TrackMatcher.secondsOf("not a time"))
    }
}
