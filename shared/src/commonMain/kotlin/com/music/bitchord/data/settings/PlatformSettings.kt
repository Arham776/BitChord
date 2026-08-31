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
}
