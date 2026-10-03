package com.mitskids.offline

import java.io.File
import java.nio.file.Files

fun main() {
    val temporary = Files.createTempDirectory("mits-storage-path-checks").toFile()
    var checks = 0
    fun rejects(block: () -> Unit) {
        var rejected = false
        try { block() } catch (_: IllegalArgumentException) { rejected = true }
        check(rejected)
        checks++
    }
    try {
        val flutter = File(temporary, "app_flutter").apply { mkdir() }
        val offline = File(flutter, "offline")
        rejects { OfflineStoragePaths.directory(flutter, offline.path) }
        offline.mkdir()
        check(OfflineStoragePaths.directory(flutter, offline.path) == offline.canonicalFile)
        checks++
        check(OfflineStoragePaths.directory(flutter) == offline.canonicalFile)
        checks++
        rejects { OfflineStoragePaths.directory(flutter, "offline") }
        rejects { OfflineStoragePaths.directory(flutter, temporary.path) }
        rejects { OfflineStoragePaths.directory(flutter, File(offline, "child").path) }
        val other = File(temporary, "elsewhere").apply { mkdir() }
        val alias = File(temporary, "alias")
        Files.createSymbolicLink(alias.toPath(), offline.toPath())
        rejects { OfflineStoragePaths.directory(flutter, alias.path) }
        offline.delete()
        Files.createSymbolicLink(offline.toPath(), other.toPath())
        rejects { OfflineStoragePaths.directory(flutter, offline.path) }
        rejects { OfflineStoragePaths.directory(flutter) }
        offline.delete()
        offline.writeText("not a directory")
        rejects { OfflineStoragePaths.directory(flutter, offline.path) }
    } finally {
        temporary.walkBottomUp().forEach { it.delete() }
    }
    println("$checks offline directory validation checks passed; StatFs still requires Android validation.")
}
