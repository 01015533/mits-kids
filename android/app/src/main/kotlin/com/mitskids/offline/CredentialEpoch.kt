package com.mitskids.offline

/** Serializes credential commits with lifecycle revocation, never derivation. */
class CredentialEpoch {
    private var value = 0L

    @Synchronized fun current(): Long = value

    @Synchronized fun revoke() { value++ }

    @Synchronized fun <T> withCurrent(expected: Long, operation: () -> T): T {
        if (expected != value) throw InterruptedException("Parent session interrupted")
        return operation()
    }
}
