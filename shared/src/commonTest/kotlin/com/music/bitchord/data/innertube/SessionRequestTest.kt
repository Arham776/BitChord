package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.HttpStatusException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlin.test.*

class SessionRequestTest {
    private fun signedIn() {
        Innertube.cookie = "SAPISID=synthetic"
        Innertube.adoptSessionScope("default-page", "default-sync", "2", "visitor", "live-version", true)
        Innertube.adoptPageScope(null, "selected-sync", "3")
    }
    private suspend fun fixture(body: suspend () -> Unit) {
        val transport = Innertube.musicTransport
        val scopeTransport = Innertube.scopeTransport
        val playerTransport = Innertube.playerTransport
        try { body() } finally {
            Innertube.musicTransport = transport
            Innertube.scopeTransport = scopeTransport
            Innertube.playerTransport = playerTransport
            Innertube.cookie = null
            Innertube.adoptPageScope(null, null, null)
        }
    }
    @Test fun selectedChannelNeverInheritsDefaultPage() = runTest {
        fixture {
            signedIn()
            var captured: Innertube.MusicRequest? = null
            Innertube.musicTransport = { captured = it; "{}" }
            Innertube.browse("FEmusic_history")
            val request = assertNotNull(captured)
            assertEquals("3", request.headers["X-Goog-AuthUser"])
            assertNull(request.headers["X-Goog-PageId"])
            assertTrue(request.headers["Authorization"]!!.startsWith("SAPISIDHASH "))
            assertTrue(request.body.contains("selected-sync"))
            assertFalse(request.body.contains("default-sync"))
            assertFalse(request.body.contains("default-page"))
        }
    }
    @Test fun selectedAccountWithoutChannelIdsDoesNotFallBack() = runTest {
        fixture {
            signedIn()
            Innertube.adoptPageScope(null, null, "7")
            Innertube.musicTransport = {
                assertEquals("7", it.headers["X-Goog-AuthUser"])
                assertNull(it.headers["X-Goog-PageId"])
                assertFalse(it.body.contains("default-sync"))
                "{}"
            }
            Innertube.browse("FEmusic_history")
        }
    }
    @Test fun trackingCredentialsRejectForeignOrigins() = runTest {
        fixture {
            signedIn()
            for (url in listOf("https://foreign.invalid/stats", "http://music.youtube.com/stats",
                "https://music.youtube.com:8443/stats", "https://user:password@music.youtube.com/stats")) {
                assertFailsWith<IllegalArgumentException> { Innertube.pingPlayback(url, "fixture") }
            }
        }
    }
    @Test fun guestRequestsCarryNoAccountCredentials() = runTest {
        fixture {
            Innertube.cookie = null
            Innertube.adoptPageScope(null, null, null)
            Innertube.musicTransport = {
                assertFalse(it.headers.containsKey("Cookie"))
                assertFalse(it.headers.containsKey("Authorization"))
                assertFalse(it.headers.containsKey("X-Goog-AuthUser"))
                "{}"
            }
            Innertube.search("fixture")
        }
    }
    @Test fun personalReadsRequireIdentity() = runTest {
        fixture {
            Innertube.cookie = null
            var requests = 0
            Innertube.musicTransport = { requests++; "{}" }
            assertFailsWith<Innertube.NotSignedInException> { Innertube.browse("FEmusic_history") }
            assertFailsWith<Innertube.NotSignedInException> { Innertube.accountMenu() }
            assertEquals(0, requests)
        }
    }
    @Test fun obsoleteResponsesCannotBeReturnedAfterAccountSwitch() = runTest {
        fixture {
            signedIn()
            val before = Innertube.sessionGeneration
            Innertube.musicTransport = {
                Innertube.adoptPageScope("new-page", "new-sync", "4")
                "{}"
            }
            assertFailsWith<Innertube.SessionChangedException> { Innertube.browse("FEmusic_home") }
            assertTrue(Innertube.sessionGeneration > before)
        }
    }
    @Test fun immutableSnapshotKeepsItsIdentityAfterSwitch() {
        try {
            signedIn()
            val old = Innertube.requestSession()
            Innertube.adoptPageScope("new-page", "new-sync", "4")
            assertEquals("3", Innertube.authHeaders(old, "https://music.youtube.com")["X-Goog-AuthUser"])
            assertNull(Innertube.authHeaders(old, "https://music.youtube.com")["X-Goog-PageId"])
            assertFailsWith<IllegalArgumentException> { Innertube.authHeaders(old, "https://example.invalid") }
        } finally { Innertube.cookie = null; Innertube.adoptPageScope(null, null, null) }
    }
    @Test fun anonymousPlayerStaysAnonymousWhileSignedIn() = runTest {
        fixture {
            signedIn()
            Innertube.playerTransport = {
                assertNull(it.headers["Cookie"])
                assertNull(it.headers["Authorization"])
                assertFalse(it.body.contains("selected-sync"))
                "{}"
            }
            Innertube.player("fixture", PlayerClient.IOS, authenticated = false)
        }
    }
    @Test fun authenticatedPlayerUsesOneSnapshot() = runTest {
        fixture {
            signedIn()
            Innertube.playerTransport = {
                assertEquals("3", it.headers["X-Goog-AuthUser"])
                assertEquals("SAPISID=synthetic", it.headers["Cookie"])
                assertTrue(it.body.contains("selected-sync"))
                assertTrue(it.url.startsWith("https://music.youtube.com/"))
                "{}"
            }
            Innertube.player("fixture", PlayerClient.WEB_REMIX, authenticated = true)
        }
    }
    @Test fun authenticatedDevicePlayerNamesTheOriginThatWasSigned() = runTest {
        fixture {
            signedIn()
            Innertube.playerTransport = {
                assertEquals("https://www.youtube.com", it.headers["Origin"])
                assertEquals("https://www.youtube.com", it.headers["X-Origin"])
                assertEquals("3", it.headers["X-Goog-AuthUser"])
                assertTrue(it.url.startsWith("https://www.youtube.com/"))
                "{}"
            }
            Innertube.player("fixture", PlayerClient.ANDROID_MUSIC, authenticated = true)
        }
    }
    @Test fun deviceClientRejectionDoesNotDeclareAValidatedAccountExpired() = runTest {
        fixture {
            signedIn()
            var calls = 0
            Innertube.scopeTransport = { """{"LOGGED_IN":true,"SESSION_INDEX":2}""" }
            Innertube.playerTransport = { calls++; throw HttpStatusException(401) }
            assertFailsWith<Innertube.PlayerAuthenticationException> {
                Innertube.player("fixture", PlayerClient.ANDROID_MUSIC, authenticated = true)
            }
            assertEquals(2, calls)
            assertNotNull(Innertube.requestSession().cookie)
        }
    }
    @Test fun mutationIsNeverAutomaticallyReplayed() = runTest {
        fixture {
            signedIn()
            var calls = 0
            Innertube.musicTransport = { calls++; throw HttpStatusException(401) }
            assertFailsWith<Innertube.AuthenticationException> { Innertube.createPlaylist("fixture", com.music.bitchord.data.model.PlaylistPrivacy.PRIVATE) }
            assertEquals(1, calls)
            assertEquals("SAPISID=synthetic", Innertube.cookie)
        }
    }
    @Test fun safeReadRefreshesOnceAndPreservesSelectedChannel() = runTest {
        fixture {
            signedIn()
            var calls = 0
            var shells = 0
            Innertube.scopeTransport = {
                shells++
                """{"LOGGED_IN":true,"DATASYNC_ID":"default-sync||delegated","SESSION_INDEX":2,"INNERTUBE_CLIENT_VERSION":"new-version"}"""
            }
            Innertube.musicTransport = {
                calls++
                if (calls == 1) throw HttpStatusException(401)
                assertEquals("3", it.headers["X-Goog-AuthUser"])
                assertTrue(it.body.contains("selected-sync"))
                "{}"
            }
            Innertube.browse("FEmusic_home")
            assertEquals(2, calls); assertEquals(1, shells)
        }
    }
    @Test fun expiredShellDoesNotBecomeAGuestSession() = runTest {
        fixture {
            signedIn()
            Innertube.musicTransport = { throw HttpStatusException(401) }
            Innertube.scopeTransport = { """{"LOGGED_IN":false,"INNERTUBE_CLIENT_VERSION":"version"}""" }
            assertFailsWith<Innertube.AuthenticationException> { Innertube.browse("FEmusic_history") }
            assertEquals("SAPISID=synthetic", Innertube.cookie)
        }
    }
    @Test fun unresolvedIdentityDoesNotSendAPersonalRequest() = runTest {
        fixture {
            Innertube.cookie = "SAPISID=unresolved"
            Innertube.scopeTransport = { error("offline") }
            var calls = 0
            Innertube.musicTransport = { calls++; "{}" }
            assertFails { Innertube.browse("FEmusic_history") }
            assertEquals(0, calls)
            assertEquals("SAPISID=unresolved", Innertube.cookie)
        }
    }
    @Test fun missingAccountIndexIsNotSilentlyZero() = runTest {
        fixture {
            Innertube.cookie = "SAPISID=unresolved-index"
            Innertube.scopeTransport = { """{"LOGGED_IN":true,"DATASYNC_ID":"unresolved","INNERTUBE_CLIENT_VERSION":"version"}""" }
            var calls = 0
            Innertube.musicTransport = { calls++; "{}" }
            assertFailsWith<Innertube.SessionUnavailableException> { Innertube.browse("FEmusic_history") }
            assertEquals(0, calls)
            assertEquals("SAPISID=unresolved-index", Innertube.cookie)
        }
    }
    @Test fun diagnosticsDoNotExposeCredentialsOrSignedURLs() {
        val text = DebugLog.sanitize("Authorization: Bearer synthetic\nhttps://user:password@example.invalid/private?token=synthetic\nSAPISID=synthetic")
        assertFalse(text.contains("synthetic")); assertFalse(text.contains("password"))
    }
}
