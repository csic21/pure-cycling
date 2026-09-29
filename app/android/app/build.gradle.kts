import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
//
// `key.properties` is gitignored — see docs/ci.md. It is absent on a fresh
// clone and on every CI job that is only checking the build compiles, in which
// case the release build falls back to the debug key rather than failing.
//
// That fallback is deliberate but it must not be mistaken for a shipping
// configuration: a debug-signed APK cannot be uploaded to Play, and the three
// secrets below have to be set in the repository for a real release.
// ---------------------------------------------------------------------------
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()

if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "app.purecycling.cycling"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    defaultConfig {
        applicationId = "app.purecycling.cycling"

        // 23 is the floor for the runtime permission model this app depends
        // on for location, and for `usesPermissionFlags="neverForLocation"` on
        // the Bluetooth scan permission. Flutter's default is 21; raising it
        // costs no real devices and removes a whole class of conditional
        // permission code.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Chinese place names and ride notes are stored as UTF-8; declaring it
        // keeps a future XML resource or backup extractor from mangling them.
        resourceConfigurations += listOf("zh", "en")
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Local and CI builds only. See the note above.
                signingConfigs.getByName("debug")
            }

            // The recording path is already free of debug-only assumptions;
            // keeping R8 on in release catches a class of reflection problems
            // (drift, Supabase serialization) that debug builds hide.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // GPS_PROVIDER requests go through LocationRequestCompat. The same
    // artifact geolocator already uses; the app has to name it because a
    // plugin's implementation dependency is not on this module's classpath.
    implementation("androidx.core:core:1.16.0")
}
