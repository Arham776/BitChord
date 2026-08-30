package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.Account
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

/**
 * Swift-facing bridge for the signed-in account info.
 */
object AccountBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface AccountCallback {
        fun onResult(json: String?, message: String?)
    }

    fun account(callback: AccountCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                val response = Innertube.accountMenu()
                val account = InnertubeParser.parseAccount(response)
                if (account != null) {
                    callback.onResult(
                        json.encodeToString(Account.serializer(), account),
                        null,
                    )
                } else {
                    callback.onResult(null, "Not signed in")
                }
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }
}
