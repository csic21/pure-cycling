allprojects {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("androidx\\..*")
                includeGroupByRegex("com\\.google\\.android.*")
                includeGroupByRegex("com\\.google\\.firebase.*")
                includeGroupByRegex("com\\.google\\.testing.*")
            }
        }
        mavenCentral {
            content {
                excludeGroupByRegex("com\\.android.*")
                excludeGroupByRegex("androidx\\..*")
                excludeGroupByRegex("com\\.google\\.android.*")
                excludeGroupByRegex("com\\.google\\.firebase.*")
                excludeGroupByRegex("com\\.google\\.testing.*")
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// ---------------------------------------------------------------------------
// Kotlin plugin for Flutter plugins that forget to apply it
//
// `universal_ble` ships an `android/build.gradle` that applies only
// `com.android.library`, then uses a top-level `kotlin { compilerOptions { } }`
// block. The `kotlin` extension only exists once the Kotlin Android plugin is
// applied, so the build fails at configuration time with
//
//     Could not find method kotlin() for arguments ...
//
// rather than with anything that points at the real cause.
//
// Flutter's plugin loader applies the Kotlin plugin to most plugins; it does
// not for this one. The fix belongs in the plugin, but it publishes on its own
// schedule, so it is applied here instead — narrowly, only to Android library
// subprojects that actually have Kotlin sources.
//
// Revisit when `universal_ble` applies `org.jetbrains.kotlin.android` itself.
// ---------------------------------------------------------------------------
subprojects {
    plugins.withId("com.android.library") {
        val hasKotlinSources = project.file("src/main/kotlin").isDirectory
        if (hasKotlinSources && !project.plugins.hasPlugin("org.jetbrains.kotlin.android")) {
            project.pluginManager.apply("org.jetbrains.kotlin.android")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
