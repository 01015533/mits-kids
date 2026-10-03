package com.mitskids.offline

/** Persistent authentication backoff: each attempt is bounded, up to 5 minutes. */
object RetryDelay {
    fun milliseconds(failures: Int): Long = when {
        failures < 5 -> 1_000L
        else -> (30_000L * (1L shl (failures - 5).coerceIn(0, 4))).coerceAtMost(300_000L)
    }
}
