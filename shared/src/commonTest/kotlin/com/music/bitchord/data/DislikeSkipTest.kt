package com.music.bitchord.data

import com.music.bitchord.data.model.LikeStatus
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Whether thumbing a track down should move the player on.
 *
 * Four cases and the first is the one that matters: the *second* tap on a disliked
 * track is an undo, and skipping then would mean a listener who changed their mind
 * could not stay on the song — it would leave the moment they took the dislike off.
 */
class DislikeSkipTest {

    @Test
    fun `disliking the track that is playing skips it`() {
        assertTrue(
            shouldSkipAfterDislike(
                previousStatus = LikeStatus.INDIFFERENT,
                targetVideoId = "abc",
                currentVideoId = "abc",
            ),
        )
    }

    @Test
    fun `disliking a liked track that is playing still skips it`() {
        // The rating changes from LIKE to DISLIKE, so the previous status is not the
        // one that decides anything.
        assertTrue(
            shouldSkipAfterDislike(
                previousStatus = LikeStatus.LIKE,
                targetVideoId = "abc",
                currentVideoId = "abc",
            ),
        )
    }

    @Test
    fun `taking a dislike back off does not skip`() {
        assertFalse(
            shouldSkipAfterDislike(
                previousStatus = LikeStatus.DISLIKE,
                targetVideoId = "abc",
                currentVideoId = "abc",
            ),
        )
    }

    @Test
    fun `disliking a track that is not playing does not skip`() {
        // Offered on every row of every list; skipping would surprise somebody who was
        // only browsing a queue.
        assertFalse(
            shouldSkipAfterDislike(
                previousStatus = LikeStatus.INDIFFERENT,
                targetVideoId = "abc",
                currentVideoId = "xyz",
            ),
        )
    }

    @Test
    fun `nothing playing means nothing to skip`() {
        assertFalse(
            shouldSkipAfterDislike(
                previousStatus = LikeStatus.INDIFFERENT,
                targetVideoId = "abc",
                currentVideoId = null,
            ),
        )
    }

    @Test
    fun `a rating nobody sent skips nothing`() {
        // `null` is the not-signed-in case, where no rating was written at all. It is
        // distinct from INDIFFERENT, and it must not be read as "was not disliked".
        assertFalse(
            shouldSkipAfterDislike(
                previousStatus = null,
                targetVideoId = "abc",
                currentVideoId = "abc",
            ),
        )
    }
}
