package com.music.bitchord.data.auth

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

/**
 * Identity and ordering for the multi-account selector.
 *
 * The two id chains are the judgement worth pinning down. Both are fallbacks
 * that decide *which account a selection refers to after a relaunch*, so getting
 * one wrong does not produce an error — it produces a selection that silently
 * applies to the wrong account, or forgets itself. Neither failure is visible
 * at the moment it happens, which is exactly why they need tests.
 */
class AccountSessionsTest {

    // Builders, so a test says what it means rather than spelling out a record.

    private fun profile(
        id: String = "p1",
        name: String = "Channel",
        pageId: String? = null,
        dataSyncId: String? = null,
        authUser: String? = null,
    ) = YouTubeProfile(profileId = id, name = name, pageId = pageId, dataSyncId = dataSyncId, authUser = authUser)

    private fun account(
        id: String = "a1",
        cookie: String = "SID=x",
        profiles: List<YouTubeProfile> = emptyList(),
        active: String? = null,
    ) = GoogleAccountSession(
        accountId = id, cookie = cookie, profiles = profiles, activeProfileId = active
    )

    // ---- sessionIdOf --------------------------------------------------------

    @Test
    fun a_session_id_prefers_the_data_sync_id() {
        // It is the identity the requests carry, so it is the one that has to
        // survive a re-login. A cookie digest would not: a fresh login issues a
        // fresh cookie and the account would look like a new one.
        assertEquals("ds-123", sessionIdOf("SID=whatever", "ds-123"))
    }

    @Test
    fun a_session_id_falls_back_to_the_cookie_digest() {
        val id = sessionIdOf("SID=abc", null)
        assertEquals(24, id.length)
        assertEquals(id, sessionIdOf("SID=abc", null))
    }

    @Test
    fun different_cookies_get_different_session_ids() {
        assertNotEquals(sessionIdOf("SID=abc", null), sessionIdOf("SID=xyz", null))
    }

    @Test
    fun a_blank_data_sync_id_is_treated_as_absent() {
        // The store round-trips through JSON, where a missing field and an empty
        // one are easy to confuse. An empty string is not an identity.
        assertEquals(sessionIdOf("SID=abc", null), sessionIdOf("SID=abc", ""))
        assertEquals(sessionIdOf("SID=abc", null), sessionIdOf("SID=abc", "   "))
    }

    // ---- profileIdOf --------------------------------------------------------

    @Test
    fun a_profile_id_prefers_the_page_id() {
        assertEquals("page-1", profileIdOf("page-1", "ds-1", "Name"))
    }

    @Test
    fun a_profile_id_falls_back_to_the_data_sync_id() {
        assertEquals("ds-1", profileIdOf(null, "ds-1", "Name"))
    }

    @Test
    fun a_profile_id_falls_back_last_to_a_name_digest() {
        val id = profileIdOf(null, null, "Some Channel")
        assertEquals("profile:", id.take(8))
        // "profile:" plus 16 hex characters. The prefix is what makes a
        // name-derived id distinguishable from a real one at a glance in a
        // settings string, so it is part of the value rather than decoration.
        assertEquals(8 + 16, id.length)
    }

    @Test
    fun the_name_digest_is_stable_across_calls() {
        // The whole point of the last-resort chain: an id that changed on every
        // launch would forget the listener's selection every time they opened
        // the app.
        assertEquals(profileIdOf(null, null, "X"), profileIdOf(null, null, "X"))
    }

    @Test
    fun two_channels_with_the_same_name_collide_on_the_name_digest() {
        // Documented, not defended against: a name is not unique. A *stable*
        // wrong answer is easier to live with than an unstable right one.
        assertEquals(profileIdOf(null, null, "Acme"), profileIdOf(null, null, "Acme"))
    }

    @Test
    fun a_blank_page_id_falls_through_to_the_next_link() {
        assertEquals("ds-1", profileIdOf("", "ds-1", "Name"))
        assertEquals("ds-1", profileIdOf("  ", "ds-1", "Name"))
    }

    @Test
    fun a_profile_with_a_real_id_ignores_a_colliding_name() {
        // The collision only applies when there is nothing better to use.
        assertNotEquals(
            profileIdOf("page-1", null, "Acme"),
            profileIdOf("page-2", null, "Acme"),
        )
    }

    // ---- ordering -----------------------------------------------------------

    @Test
    fun profiles_flatten_in_account_order_then_profile_order() {
        val accounts = listOf(
            account(id = "a1", profiles = listOf(profile("p1"), profile("p2"))),
            account(id = "a2", profiles = listOf(profile("p3"))),
        )
        assertEquals(
            listOf("a1" to "p1", "a1" to "p2", "a2" to "p3"),
            flattenedProfiles(accounts),
        )
    }

    @Test
    fun an_account_with_no_profiles_contributes_nothing() {
        val accounts = listOf(account(id = "a1"), account(id = "a2", profiles = listOf(profile("p9"))))
        assertEquals(listOf("a2" to "p9"), flattenedProfiles(accounts))
    }

    @Test
    fun the_order_is_stored_order_not_alphabetical() {
        // Alphabetical would move a listener's second account to the top the
        // moment they added a third. The ordering being stable is the feature.
        val accounts = listOf(
            account(id = "zzz", profiles = listOf(profile("p1"))),
            account(id = "aaa", profiles = listOf(profile("p2"))),
        )
        assertEquals(listOf("zzz" to "p1", "aaa" to "p2"), flattenedProfiles(accounts))
    }

    // ---- adjacency ----------------------------------------------------------

    @Test
    fun the_next_profile_is_the_one_after_it() {
        val accounts = listOf(
            account(id = "a1", profiles = listOf(profile("p1"), profile("p2"))),
            account(id = "a2", profiles = listOf(profile("p3"))),
        )
        assertEquals("a2" to "p3", adjacentProfile(accounts, "a1", "p2", forward = true))
    }

    @Test
    fun the_previous_profile_is_the_one_before_it() {
        val accounts = listOf(account(id = "a1", profiles = listOf(profile("p1"), profile("p2"))))
        assertEquals("a1" to "p1", adjacentProfile(accounts, "a1", "p2", forward = false))
    }

    @Test
    fun stepping_past_the_end_does_nothing_rather_than_wrapping() {
        // A swipe past the last profile should do nothing visible, not teleport
        // the listener from their newest channel to their oldest.
        val accounts = listOf(account(id = "a1", profiles = listOf(profile("p1"))))
        assertNull(adjacentProfile(accounts, "a1", "p1", forward = true))
        assertNull(adjacentProfile(accounts, "a1", "p1", forward = false))
    }

    @Test
    fun an_unknown_selection_has_no_neighbour() {
        val accounts = listOf(account(id = "a1", profiles = listOf(profile("p1"))))
        assertNull(adjacentProfile(accounts, "a1", "nope", forward = true))
        assertNull(adjacentProfile(accounts, "nope", "p1", forward = true))
        assertNull(adjacentProfile(accounts, null, null, forward = true))
    }

    @Test
    fun adjacency_spans_accounts() {
        val accounts = listOf(
            account(id = "a1", profiles = listOf(profile("p1"))),
            account(id = "a2", profiles = listOf(profile("p2"))),
        )
        assertEquals("a2" to "p2", adjacentProfile(accounts, "a1", "p1", forward = true))
        assertEquals("a1" to "p1", adjacentProfile(accounts, "a2", "p2", forward = false))
    }
}
