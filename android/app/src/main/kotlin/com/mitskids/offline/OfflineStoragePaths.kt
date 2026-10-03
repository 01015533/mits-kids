package com.mitskids.offline

import java.io.File
import java.nio.file.Files

/** Validates the one existing private directory whose free space may be queried. */
object OfflineStoragePaths {
    fun directory(flutterDirectory: File, requestedPath: String? = null): File {
        // Canonicalize the Android-owned parent: /data/data may itself be an OS alias.
        // The app-created offline child must never be redirected with a symlink.
        val expected = File(flutterDirectory.canonicalFile, "offline")
        require(!Files.isSymbolicLink(expected.toPath()) && expected.isDirectory) {
            "A private offline directory is required"
        }
        require(expected.canonicalFile == expected)
        if (requestedPath != null) {
            val requested = File(requestedPath)
            val normalized = requested.toPath().normalize().toFile()
            val platformPath = File(flutterDirectory.absoluteFile, "offline").toPath().normalize().toFile()
            require(requested.isAbsolute && (normalized == expected || normalized == platformPath)) {
                "Only the private offline directory is supported"
            }
            require(!Files.isSymbolicLink(requested.toPath()) && requested.canonicalFile == expected) {
                "Symlinked offline directories are unsupported"
            }
        }
        return expected
    }
}
