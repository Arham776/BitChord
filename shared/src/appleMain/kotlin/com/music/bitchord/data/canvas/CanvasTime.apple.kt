package com.music.bitchord.data.canvas

import kotlinx.cinterop.ExperimentalForeignApi
import platform.posix.time

@OptIn(ExperimentalForeignApi::class)
internal actual fun canvasNowMs(): Long = time(null) * 1000L
