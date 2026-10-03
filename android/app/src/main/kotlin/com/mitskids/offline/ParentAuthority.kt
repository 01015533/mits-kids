package com.mitskids.offline

/** Native backup operations require the same fresh, memory-only parent authority. */
object ParentAuthority {
    private var token: String? = null
    private var expiresAt = 0L

    @Synchronized fun unlock(value: String) {
        token = value
        expiresAt = System.nanoTime() + 5L * 60 * 1_000_000_000L
    }

    @Synchronized fun revoke() { token = null; expiresAt = 0L }

    @Synchronized fun requireToken(value: String) {
        check(token != null && value == token && System.nanoTime() < expiresAt) {
            "Parent access is locked"
        }
    }
}
