import org.gradle.api.DefaultTask
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.gangofbeads.openteams"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.gangofbeads.openteams"
        minSdk = 29
        targetSdk = 36
        versionCode = 2
        versionName = "0.2.0"
    }

    buildTypes {
        release {
            // Personal builds: the debug key keeps a release install over the debug one.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        viewBinding = true
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.activity:activity-ktx:1.11.0")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.preference:preference-ktx:1.2.1")
    implementation("com.google.android.material:material:1.13.0")
}

/**
 * Bundles open-teams' Electron preload modules (../app/browser/...) with the
 * Android preload into one document-start script. The modules are CommonJS, so
 * each is wrapped in a factory and resolved by the small loader in
 * src/main/js/android-preload.js; `require("electron")` gets an ipcRenderer
 * backed by the native WebMessage bridge.
 */
abstract class BundlePreloadTask : DefaultTask() {
    @get:Internal
    abstract val openTeamsAppDir: DirectoryProperty

    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val modules: ConfigurableFileCollection

    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val preload: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun bundle() {
        val root = openTeamsAppDir.get().asFile
        // Sloppy mode on purpose: Electron loads these modules as plain CommonJS.
        val out = StringBuilder("(function () {\nconst __otModules = {\n")
        modules.files.sortedBy { it.path }.forEach { file ->
            val id = file.relativeTo(root).invariantSeparatorsPath
            out.append("\"").append(id).append("\": function (module, exports, require, process) {\n")
                .append(file.readText())
                .append("\n},\n")
        }
        out.append("};\n").append(preload.get().asFile.readText()).append("\n})();\n")
        outputDir.file("open-teams-preload.js").get().asFile.writeText(out.toString())
    }
}

val openTeamsApp = rootProject.layout.projectDirectory.dir("../app")

val bundlePreload = tasks.register<BundlePreloadTask>("bundleOpenTeamsPreload") {
    openTeamsAppDir.set(openTeamsApp)
    modules.from(
        listOf(
            "browser/tools/activityHub.js",
            "browser/tools/reactHandler.js",
            "browser/tools/tokenCache.js",
            "browser/tools/wakeLock.js",
            "browser/tools/speakingIndicator.js",
            "browser/tools/disableAutogain.js",
            "browser/tools/emulatePlatform.js",
            "browser/tools/_micConstraintHelpers.js",
            "browser/tools/theme.js",
            "browser/notifications/activityManager.js",
            "browser/notifications/notificationBridge.js",
        ).map { openTeamsApp.file(it) },
    )
    preload.set(layout.projectDirectory.file("src/main/js/android-preload.js"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(bundlePreload, BundlePreloadTask::outputDir)
    }
}
