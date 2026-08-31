package com.music.bitchord.data.innertube

/**
 * Swift-facing seam over [PlaybackTracker]. Progress is in whole seconds.
 */
object PlaybackTrackerBridge {
    fun onPlaying(videoId: String) = PlaybackTracker.onPlaying(videoId)
    fun onTrackChanged(positionSeconds: Long) = PlaybackTracker.onTrackChanged(positionSeconds)
    fun onProgress(videoId: String, positionSeconds: Long) =
        PlaybackTracker.onProgress(videoId, positionSeconds)
    fun onPlaybackFinished(positionSeconds: Long) =
        PlaybackTracker.onPlaybackFinished(positionSeconds)
}
