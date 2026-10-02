package com.music.bitchord.data.settings

import com.music.bitchord.data.sources.PlaybackCodecCapabilities
import kotlin.test.*

class AppleSettingsParityTest {
    @Test fun addedPreferencesSurviveBackupRestore() {
        val oldBlur = AppSettings.lyricsBlur.value
        val oldLanguage = AppSettings.translationLanguage.value
        val oldDolby = AppSettings.dolbyAtmos.value
        try {
            AppSettings.setLyricsBlur(false)
            AppSettings.setTranslationLanguage("fr")
            AppSettings.setDolbyAtmos(false)
            val backup = AppSettings.exportPrefsJson()
            AppSettings.setLyricsBlur(true)
            AppSettings.setTranslationLanguage("de")
            AppSettings.setDolbyAtmos(true)
            AppSettings.importPrefsJson(backup)
            assertFalse(AppSettings.lyricsBlur.value)
            assertEquals("fr", AppSettings.translationLanguage.value)
            assertFalse(AppSettings.dolbyAtmos.value)
        } finally {
            AppSettings.setLyricsBlur(oldBlur)
            AppSettings.setTranslationLanguage(oldLanguage)
            AppSettings.setDolbyAtmos(oldDolby)
        }
    }
    @Test fun dolbyRequiresHostSupportPreferenceAndCredentialFreeTransport() {
        val old = AppSettings.dolbyAtmos.value
        try {
            AppSettings.setDolbyAtmos(true)
            PlaybackCodecCapabilities.setAppleDolbyAvailable(false)
            assertFalse(PlaybackCodecCapabilities.canRenderDolby("eac3-joc", emptyMap()))
            PlaybackCodecCapabilities.setAppleDolbyAvailable(true)
            assertTrue(PlaybackCodecCapabilities.canRenderDolby("eac3-joc", emptyMap()))
            assertFalse(PlaybackCodecCapabilities.canRenderDolby("eac3-joc", mapOf("Authorization" to "synthetic")))
            assertFalse(PlaybackCodecCapabilities.canRenderDolby("truehd", emptyMap()))
            AppSettings.setDolbyAtmos(false)
            assertFalse(PlaybackCodecCapabilities.canRenderDolby("eac3-joc", emptyMap()))
        } finally {
            PlaybackCodecCapabilities.setAppleDolbyAvailable(false)
            AppSettings.setDolbyAtmos(old)
        }
    }
}
