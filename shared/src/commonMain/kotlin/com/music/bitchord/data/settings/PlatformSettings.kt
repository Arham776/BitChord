package com.music.bitchord.data.settings

/**
 * Portable key-value store seam (spec §1.3). Upstream backs settings with
 * DataStore/SharedPreferences; the Apple actual is `NSUserDefaults` via
 * Kotlin/Native's Foundation interop. The `multiplatform-settings` klib is
 * bypassed deliberately: 1.3.0 fails to resolve under Kotlin 2.4.10 (its klib
 * is silently dropped by the compiler), and the direct Foundation interop is
 * what the spec's `actual` describes in the first place.
 */
expect object PlatformSettings {
    fun getString(key: String, default: String): String
    fun putString(key: String, value: String)
    fun getInt(key: String, default: Int): Int
    fun putInt(key: String, value: Int)
    fun getBoolean(key: String, default: Boolean): Boolean
    fun putBoolean(key: String, value: Boolean)
    fun getFloat(key: String, default: Float): Float
    fun putFloat(key: String, value: Float)
    fun getLong(key: String, default: Long): Long
    fun putLong(key: String, value: Long)

    /**
     * A value that must not sit in plain preferences, or null when there is
     * none.
     *
     * Separate from the typed accessors because the *storage* is different, not
     * the type: a Discord bearer token, a WebDAV or SMB password, and an addon's
     * base URL — which on this protocol can carry a token in its path — are all
     * full credentials. Upstream keeps every one of them in
     * `EncryptedSharedPreferences` for exactly this reason, and it is why its
     * backup export carries a `SECRETS` exclusion list.
     *
     * On Apple the actual is the Keychain, which is the platform's equivalent of
     * the Android Keystore-backed store. A platform with no such facility
     * degrades to an in-memory value for the session rather than silently
     * writing the secret to disk.
     */
    fun getSecret(key: String): String?
    fun putSecret(key: String, value: String?)
}
