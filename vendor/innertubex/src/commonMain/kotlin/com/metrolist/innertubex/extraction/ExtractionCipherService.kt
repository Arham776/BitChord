package com.metrolist.innertubex.extraction

import com.metrolist.innertubex.cipher.YouTubeCipherService
import com.metrolist.innertubex.models.response.PlayerResponse.StreamingData.Format

internal interface ExtractionCipherService {
    suspend fun initialize()

    suspend fun preloadPlayerCode(playerUrl: String)

    suspend fun prewarmEjs()

    suspend fun processFormats(
        playerUrl: String,
        formats: List<Format>,
    ): List<Format>
}

internal class DefaultExtractionCipherService(
    private val delegate: YouTubeCipherService,
) : ExtractionCipherService {
    override suspend fun initialize() {
        delegate.initialize()
    }

    override suspend fun preloadPlayerCode(playerUrl: String) {
        delegate.preloadPlayerCode(playerUrl)
    }

    override suspend fun prewarmEjs() {
        delegate.prewarmEjs()
    }

    override suspend fun processFormats(
        playerUrl: String,
        formats: List<Format>,
    ): List<Format> = delegate.processFormats(playerUrl, formats)
}
