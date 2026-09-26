package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Translating between this device's clock and the party's.
 *
 * The property that matters and is easy to get wrong: the offset is chosen by
 * *smallest round trip*, not by newest or by average. On a mobile network one
 * request delayed behind a radio wake-up is wrong by hundreds of milliseconds, and
 * both of the alternatives fold that error in rather than throwing it away.
 */
class ServerClockTest {

    // ---- No samples yet ---------------------------------------------------

    @Test
    fun `an unsynced clock has no offset and says so`() {
        val clock = ServerClock()
        assertNull(clock.offsetMs)
        assertFalse(clock.synced)
        assertNull(clock.serverNowMs(1_000))
    }

    @Test
    fun `one sample is enough to sync`() {
        val clock = ServerClock()
        // Sent at 1000, server said 5000, arrived at 1200. Midpoint 1100.
        clock.record(sentAtLocalMs = 1_000, serverMs = 5_000, receivedAtLocalMs = 1_200)
        assertTrue(clock.synced)
        assertEquals(3_900, clock.offsetMs)
        assertEquals(200, clock.roundTripMs)
    }

    @Test
    fun `the server clock is the local clock plus the offset`() {
        val clock = ServerClock()
        clock.record(1_000, 5_000, 1_200)
        assertEquals(10_000 + 3_900, clock.serverNowMs(10_000))
    }

    // ---- Choosing a sample ------------------------------------------------

    @Test
    fun `the shortest round trip wins · not the newest` () {
        val clock = ServerClock()
        // A first sample delayed by a radio wake-up: 800ms round trip, and the
        // offset it implies is badly wrong.
        clock.record(0, 10_000, 800)
        // Then a clean one: 40ms.
        clock.record(1_000, 11_020, 1_040)
        // Taking the newest gives ~9,980. Taking the shortest gives ~10,000,
        // which is the offset the server actually has.
        assertEquals(10_000, clock.offsetMs)
        assertEquals(40, clock.roundTripMs)
    }

    @Test
    fun `a long sample does not overwrite a short one`() {
        val clock = ServerClock()
        clock.record(0, 5_000, 100) // 100ms
        clock.record(200, 5_000, 900) // 700ms, and stale-looking
        assertEquals(100, clock.roundTripMs)
    }

    @Test
    fun `the window is bounded`() {
        val clock = ServerClock()
        repeat(40) { index ->
            clock.record(
                sentAtLocalMs = index * 1_000L,
                serverMs = 0,
                receivedAtLocalMs = index * 1_000L + 10,
            )
        }
        assertTrue(clock.sampleCount() <= ServerClock.WINDOW)
    }

    @Test
    fun `a sample older than its lifetime stops counting`() {
        val clock = ServerClock()
        // A clean sample, long ago — beyond the two-minute lifetime.
        clock.record(0, 10_000, 20)
        // A recent sample with a worse round trip. Recency beats quality once the
        // good one has aged out, because the alternative is pinning the offset to
        // a measurement taken minutes ago on a drifting clock.
        clock.record(1_000_000, 10_500, 1_000_200)
        assertEquals(200, clock.roundTripMs)
        assertEquals(10_500 - 1_000_100, clock.offsetMs)
    }

    @Test
    fun `a negative round trip is treated as zero rather than skewing the offset`() {
        // Only reachable through a clock that stepped backwards. The midpoint must
        // not go before the send, or the offset comes out enormous.
        val clock = ServerClock()
        clock.record(sentAtLocalMs = 5_000, serverMs = 5_000, receivedAtLocalMs = 4_000)
        assertEquals(0, clock.roundTripMs)
        assertEquals(0, clock.offsetMs)
    }

    @Test
    fun `reset forgets everything`() {
        val clock = ServerClock()
        clock.record(0, 5_000, 100)
        clock.reset()
        assertNull(clock.offsetMs)
        assertEquals(0, clock.sampleCount())
        assertFalse(clock.synced)
    }

    // ---- Where this device ought to be ------------------------------------

    @Test
    fun `a position is advanced by the time since the party said it`() {
        val clock = ServerClock()
        clock.record(0, 0, 0) // offset 0, so the two clocks agree
        // The party was 30s into the track when it told us, and that was 5s ago.
        assertEquals(35_000, clock.positionFor(positionMs = 30_000, trueAtServerMs = 0, localNowMs = 5_000))
    }

    @Test
    fun `a position we are already past is not rewound`() {
        val clock = ServerClock()
        clock.record(0, 0, 0)
        // The party said position 0 was true 2s ago, so it is now at 2s and we are
        // already there. Rewinding to 0 would be a 2s skip nobody asked for.
        assertEquals(2_000, clock.positionFor(positionMs = 0, trueAtServerMs = -2_000, localNowMs = 0))
    }

    @Test
    fun `a position the party has not reached is held at zero`() {
        val clock = ServerClock()
        clock.record(0, 0, 0)
        // The party is 2s ahead of us. Playing its position now would put the same
        // bar of music at two different moments, which is the one thing a party is
        // not — so the answer is zero, meaning "wait", and the caller re-asks.
        assertEquals(0, clock.positionFor(positionMs = 0, trueAtServerMs = 2_000, localNowMs = 0))
        assertEquals(0, clock.positionFor(positionMs = 0, trueAtServerMs = 1, localNowMs = 0))
    }

    @Test
    fun `an unsynced device reports zero rather than guessing`() {
        val clock = ServerClock()
        assertEquals(0, clock.positionFor(30_000, trueAtServerMs = 0, localNowMs = 5_000))
    }

    // ---- Being in sync ----------------------------------------------------

    @Test
    fun `a small gap is in sync`() {
        assertTrue(isInSync(0))
        assertTrue(isInSync(200))
        assertTrue(isInSync(-200))
        assertTrue(isInSync(750))
    }

    @Test
    fun `a large gap is not`() {
        assertFalse(isInSync(751))
        assertFalse(isInSync(-751))
        assertFalse(isInSync(5_000))
    }

    @Test
    fun `two devices each within tolerance of the server can still be out with each other`() {
        // Compared against the gap, not each device's offset: two devices at the
        // opposite edges of tolerance are a tolerance and a half apart, and
        // comparing offsets would have both claim to be in sync while the party is
        // audibly split.
        val gap = PARTY_SYNC_TOLERANCE_MS + 400
        assertFalse(isInSync(gap))
    }
}
