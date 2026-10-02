package com.metrolist.innertubex.cipher

import kotlinx.coroutines.CoroutineDispatcher

/** A single OS thread with enough native stack for the upstream EJS parser. */
internal expect fun appleCipherDispatcher(): CoroutineDispatcher
