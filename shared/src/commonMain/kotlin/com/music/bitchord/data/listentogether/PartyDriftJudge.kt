package com.music.bitchord.data.listentogether

import kotlin.math.abs
import kotlin.concurrent.Volatile

/**
 * Deciding when to move this device's playhead to match the party's.
 *
 * ## The problem this exists to solve
 *
 * A seek is audible. It is a discontinuity in the music, and on a track with a
 * chorus it is the single most obvious thing that can happen to a listening
 * experience. So "drift is 300 ms" must **not** produce a seek, even though 300 ms
 * is measurable and even though the number is technically wrong.
 *
 * Three rules together, and each is doing separate work:
 *
 *  - **[ALIGN_TOLERANCE]** — a gap under this is left alone. Below it, a correction
 *    costs more than the error. 120 ms is under the threshold of noticing on music,
 *    which is roughly 3 ms per frame of audio, so it is not a masking argument: the
 *    error genuinely is not there.
 *
 *  - **[DRIFT_STRIKES] consecutive ticks** — a gap is not acted on the first time it
 *    is over the limit. A single wide tick is usually one slow frame, and correcting
 *    on it means correcting on network noise. Two in a row is a gap that survived a
 *    round trip, which is the difference between a measurement and a fact.
 *
 *  - **[DRIFT_COOLDOWN]** — at most one seek per six seconds. Without this the
 *    two-strike rule does not compound: a persistent gap stays over the limit, so
 *    every pair of ticks would seek, and the party would be machine-gunned. One
 *    correction is enough to re-anchor a playhead; more than that is the correction
 *    itself becoming the fault.
 *
 * The combination is what makes the steady state quiet and the *wrong* state loud.
 * That is the right asymmetry: a device that cannot follow should be obvious, and a
 * device that can follow should be inaudible.
 */
class PartyDriftJudge {

    /**
     * What the judge decided this tick.
     *
     * [seekToMs] is the position to move to, and is already the party's position
     * corrected by the clock — the judge does not do the correction, so a caller
     * cannot apply a raw frame position and skip the offset.
     */
    sealed interface Decision {
        /** Close enough. Do nothing, and do not treat it as a strike. */
        data object None : Decision

        /** Move the playhead here. */
        data class Seek(val seekToMs: Long) : Decision

        /** The party is paused and this device is not. */
        data object Pause : Decision
    }

    private var strikes = 0

    @Volatile
    private var lastSeekAtMs: Long? = null

    fun reset() {
        strikes = 0
        lastSeekAtMs = null
    }

    /**
     * One tick.
     *
     * @param partyPositionMs where the party is, already corrected by the clock
     * @param localPositionMs where this device is
     * @param localIsPlaying whether this device is playing
     * @param partyIsPlaying whether the party is playing
     * @param nowMs a local monotonic reading, for the cooldown
     */
    fun onTick(
        partyPositionMs: Long,
        localPositionMs: Long,
        localIsPlaying: Boolean,
        partyIsPlaying: Boolean,
        nowMs: Long,
    ): Decision {
        // A party that is paused is a different question from a party that is
        // drifting, and it is a *categorical* one, so it is answered without reference
        // to position at all.
        //
        // This was wrong at first and it is worth saying why, because the version that
        // compared positions looked reasonable: a party paused at 30 000 and a device
        // playing at 30 000 have a gap of zero, so a positional test reports "close
        // enough" and leaves the device playing. The listener then hears music that
        // nobody in the party chose, including whoever pressed pause. Being out of
        // step is measured in milliseconds; playing when the party is paused is a
        // different kind of wrong, and a tolerance has no business covering it.
        //
        // No strikes and no cooldown either: a pause is not audible the way a seek is,
        // so the whole machinery below does not apply and the answer is available on
        // the first tick.
        if (!partyIsPlaying) {
            strikes = 0
            return if (localIsPlaying) Decision.Pause else Decision.None
        }

        val gap = partyPositionMs - localPositionMs
        val magnitude = abs(gap)

        // Inside the alignment tolerance nothing is recorded, deliberately: a strike
        // that a momentary blur cancelled would let a real gap survive by accident.
        if (magnitude <= ALIGN_TOLERANCE_MS) {
            strikes = 0
            return Decision.None
        }

        if (magnitude <= DRIFT_LIMIT_MS) {
            // Over the alignment tolerance but under the limit: wrong, and not worth
            // a discontinuity. The count is cleared rather than left, so only gaps
            // that are *persistently* over the limit accumulate.
            strikes = 0
            return Decision.None
        }

        strikes++
        if (strikes < DRIFT_STRIKES) return Decision.None

        // Enough. Reset before the cooldown check so a suppressed seek does not leave
        // a strike banked for the next tick to spend.
        strikes = 0

        val last = lastSeekAtMs
        if (last != null && nowMs - last < DRIFT_COOLDOWN_MS) return Decision.None

        lastSeekAtMs = nowMs
        // Clamped at zero: a corrected position is never negative, and a negative seek
        // is a fault rather than an alignment.
        return Decision.Seek(partyPositionMs.coerceAtLeast(0))
    }

    companion object {
        /** Below this, the error is inaudible and a correction costs more than it fixes. */
        const val ALIGN_TOLERANCE_MS = 120L

        /** Over this, the gap is real rather than a slow frame. */
        const val DRIFT_LIMIT_MS = 1_200L

        /** Consecutive ticks over the limit before a seek. */
        const val DRIFT_STRIKES = 2

        /** At most one seek per this long, however persistent the gap. */
        const val DRIFT_COOLDOWN_MS = 6_000L

    }
}

/** How often the party is reconciled with the local player. */
const val PARTY_TICK_MS = 700L

/**
 * How long a device's own control press keeps it out of the party's way.
 *
 * A listener who presses pause has said something, and the next state frame — which
 * still says *playing*, because the control has not reached the server yet — must not
 * undo it. Without this the press appears not to work, which is worse than a
 * momentary disagreement.
 */
const val INTENT_QUIET_MS = 4_500L

/**
 * How long a deferred play waits for the party to catch up before giving up and
 * playing anyway.
 *
 * A party that has stalled should not be able to hold a device silent indefinitely.
 */
const val DEFERRED_PLAY_TIMEOUT_MS = 1_800L

/** Whether a position is close enough to a party's to be considered following it. */
fun isFollowing(partyPositionMs: Long, localPositionMs: Long): Boolean =
    abs(partyPositionMs - localPositionMs) <= PartyDriftJudge.ALIGN_TOLERANCE_MS
