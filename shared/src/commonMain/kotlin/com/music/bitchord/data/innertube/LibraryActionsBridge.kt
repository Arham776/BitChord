package com.music.bitchord.data.innertube

import com.music.bitchord.data.LikeState
import com.music.bitchord.data.model.LikeStatus
import com.music.bitchord.data.model.PlaylistPrivacy
import com.music.bitchord.data.model.SongMenu
import com.music.bitchord.data.model.UserPlaylist
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Swift-facing writes: like, save, playlists. Same Innertube endpoints as
 * upstream `YtMusicRepository`.
 */
object LibraryActionsBridge {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    fun interface DoneCallback {
        fun onResult(ok: Boolean, message: String?)
    }

    fun interface JsonCallback {
        fun onResult(json: String?, message: String?)
    }

    fun rate(videoId: String, status: String, callback: DoneCallback) {
        scope.launch {
            try {
                val target = LikeStatus.valueOf(status)
                Innertube.rate(videoId, target)
                LikeState.set(videoId, target)
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun likeStatus(videoId: String): String =
        LikeState.get(videoId)?.name ?: ""

    fun ratePlaylist(playlistId: String, saved: Boolean, callback: DoneCallback) {
        scope.launch {
            try {
                Innertube.ratePlaylist(playlistId, saved)
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun setSubscribed(channelId: String, subscribed: Boolean, callback: DoneCallback) {
        scope.launch {
            try {
                Innertube.setSubscribed(channelId, subscribed)
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun sendFeedback(token: String, callback: DoneCallback) {
        scope.launch {
            try {
                Innertube.sendFeedback(token)
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun createPlaylist(title: String, privacy: String, videoId: String?, callback: JsonCallback) {
        scope.launch {
            try {
                val p = PlaylistPrivacy.entries.firstOrNull { it.name.equals(privacy, true) }
                    ?: PlaylistPrivacy.PRIVATE
                val ids = listOfNotNull(videoId?.takeIf { it.isNotBlank() })
                val id = Innertube.createPlaylist(title, p, videoIds = ids)
                callback.onResult("""{"playlistId":${json.encodeToString(id)}}""", null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    fun deletePlaylist(playlistId: String, callback: DoneCallback) {
        scope.launch {
            try {
                Innertube.deletePlaylist(playlistId)
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun addToPlaylist(playlistId: String, videoId: String, callback: DoneCallback) {
        scope.launch {
            try {
                Innertube.addToPlaylist(playlistId, listOf(videoId))
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun removeFromPlaylist(playlistId: String, setVideoId: String, videoId: String, callback: DoneCallback) {
        scope.launch {
            try {
                Innertube.removeFromPlaylist(playlistId, listOf(setVideoId to videoId))
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun renamePlaylist(playlistId: String, title: String, callback: DoneCallback) {
        scope.launch {
            try {
                Innertube.renamePlaylist(playlistId, title)
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun setPlaylistPrivacy(playlistId: String, privacy: String, callback: DoneCallback) {
        scope.launch {
            try {
                Innertube.setPlaylistPrivacy(playlistId, privacy)
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun movePlaylistItem(
        playlistId: String,
        setVideoId: String,
        successorSetVideoId: String?,
        callback: DoneCallback,
    ) {
        scope.launch {
            try {
                Innertube.movePlaylistItem(playlistId, setVideoId, successorSetVideoId)
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun userPlaylists(callback: JsonCallback) {
        scope.launch {
            try {
                val list = InnertubeParser.parseUserPlaylists(
                    Innertube.browse("FEmusic_liked_playlists"),
                )
                callback.onResult(
                    json.encodeToString(ListSerializer(UserPlaylist.serializer()), list),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    fun songMenu(videoId: String, callback: JsonCallback) {
        scope.launch {
            try {
                val menu = InnertubeParser.parseSongMenu(Innertube.next(videoId), videoId)
                    ?: SongMenu()
                menu.likeStatus?.let {
                    runCatching { LikeState.set(videoId, LikeStatus.valueOf(it)) }
                }
                callback.onResult(json.encodeToString(SongMenu.serializer(), menu), null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }
}
