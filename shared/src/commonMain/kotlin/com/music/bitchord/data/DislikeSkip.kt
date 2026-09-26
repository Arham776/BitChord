package com.music.bitchord.data

import com.music.bitchord.data.model.LikeStatus

/**
 * Whether thumbing a track down should also move the player on.
 *
 * Port of upstream `MainActivity.shouldSkipAfterDislike`, and the rule is a line in
 * upstream and a function here for the same reason it is a function everywhere else in
 * this port: it is a judgement with an edge case, and the edge case is the whole
 * point.
 *
 * The rule: **disliking the track that is playing skips it.** Two things it must not
 * do, and both are why this is a function with a name:
 *
 * - **Un-disliking does not skip.** The second tap on a disliked track is an undo,
 *   and skipping then would mean a listener who changed their mind about a song
 *   could not stay on it — the track would leave the moment they took the dislike
 *   back off.
 * - **Disliking a track that is not playing does not skip.** The action is offered on
 *   every row in every list; skipping would be a surprise for a queue that was only
 *   being browsed.
 */
fun shouldSkipAfterDislike(
    previousStatus: LikeStatus?,
    targetVideoId: String,
    currentVideoId: String?,
): Boolean = previousStatus != null &&
    previousStatus != LikeStatus.DISLIKE &&
    targetVideoId == currentVideoId
