plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// MITS release security v3
val mitsReleaseValues = listOf("MITS_RELEASE_STORE_FILE", "MITS_RELEASE_STORE_PASSWORD", "MITS_RELEASE_KEY_ALIAS", "MITS_RELEASE_KEY_PASSWORD")
    .associateWith { System.getenv(it) }
val mitsSigningReady = mitsReleaseValues.values.all { !it.isNullOrBlank() }
// Native integration tests use their own data/Keystore namespace. This switch
// can never change the identity of a production release.
val mitsValidationBuild = System.getenv("MITS_VALIDATION_BUILD") == "1"
if (mitsValidationBuild && gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }) {
    throw GradleException("Validation builds are debug-only and must not be released.")
}
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } && !mitsSigningReady) {
    throw GradleException("Release signing is required. See docs/SECURITY-UPDATE.md. Debug signing is never used for release.")
}
tasks.configureEach {
    if (name == "preReleaseBuild") {
        doFirst {
            if (!mitsSigningReady) throw GradleException("MITS release signing is required.")
        }
    }
}

android {
    signingConfigs {
        if (mitsSigningReady) {
            create("mitsRelease") {
                storeFile = file(mitsReleaseValues.getValue("MITS_RELEASE_STORE_FILE")!!)
                storePassword = mitsReleaseValues.getValue("MITS_RELEASE_STORE_PASSWORD")
                keyAlias = mitsReleaseValues.getValue("MITS_RELEASE_KEY_ALIAS")
                keyPassword = mitsReleaseValues.getValue("MITS_RELEASE_KEY_PASSWORD")
            }
        }
    }

    namespace = "com.example.mits_kids_youtube"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.mits_kids_youtube"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["mitsAppLabel"] = "MITS Kids"
    }

    buildTypes {
        debug {
            if (mitsValidationBuild) {
                applicationIdSuffix = ".validation"
                versionNameSuffix = "-validation"
                manifestPlaceholders["mitsAppLabel"] = "MITS Kids validation"
            }
        }
        release {
            signingConfig = signingConfigs.findByName("mitsRelease")
            isDebuggable = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Portable encrypted backups use Tink's reviewed streaming construction.
    implementation("com.google.crypto.tink:tink-android:1.23.0")
}
