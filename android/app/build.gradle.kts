import java.util.Properties
import java.util.zip.ZipFile
import java.util.Base64
import com.flutter.gradle.tasks.FlutterTask

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase push-уведомления (FCM).
    id("com.google.gms.google-services")
}

val releaseKeysFile = rootProject.file("key.properties")
// Reuse the second Android app already registered in google-services.json.
// Dart and Android identity are derived from the same build flag.
val uiBeta = providers.gradleProperty("dart-defines").orNull
    ?.split(",")?.any { String(Base64.getDecoder().decode(it)) == "UI_BETA=true" } == true
val releaseKeys = Properties().apply {
    if (releaseKeysFile.isFile) {
        releaseKeysFile.inputStream().use { load(it) }
    }
}
val releaseSigningConfigured = releaseKeysFile.isFile && listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
).all { !releaseKeys.getProperty(it).isNullOrBlank() }
if (releaseKeysFile.isFile && (!releaseSigningConfigured || listOf(
        "storePassword",
        "keyPassword",
    ).any { releaseKeys.getProperty(it).startsWith("replace-") }
)) {
    throw GradleException("Replace the template values in android/key.properties with your release keystore passwords")
}
val configuredStoreFile = releaseKeys.getProperty("storeFile", "")
val userProfile = System.getenv("USERPROFILE")
if (configuredStoreFile.contains("%USERPROFILE%") && userProfile.isNullOrBlank()) {
    throw GradleException("USERPROFILE is required to resolve storeFile in android/key.properties")
}
val releaseStoreFile = configuredStoreFile
    .replace("%USERPROFILE%", userProfile ?: "")
    .replace("\\", "/")

android {
    namespace = "com.example.pulsepath"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Требование flutter_local_notifications (java.time на старых API).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = if (uiBeta) "com.pulsepath.app" else "com.example.pulsepath"
        manifestPlaceholders["pulsepathLabel"] = if (uiBeta) "PulsePath UI Beta" else "PulsePath"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (releaseSigningConfigured) {
        signingConfigs {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile)
                storePassword = releaseKeys.getProperty("storePassword")
                keyAlias = releaseKeys.getProperty("keyAlias")
                keyPassword = releaseKeys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            proguardFiles("proguard-rules.pro")
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
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

// Windows drive aliases can name the same output files differently. Flutter's
// cleanup can consequently remove the new bundle as obsolete previous output.
// Use a stable real output path and guard packaging independently of Copy's
// NO-SOURCE optimisation, which would otherwise skip a doFirst check.
// Java's Windows toRealPath can preserve SUBST drives. The launcher supplies
// the original project path before mapping its temporary build drive.
val actualProjectRoot = providers.gradleProperty("pulsepath.projectRoot").orNull
    ?.let { rootProject.file(it).toPath().toRealPath() }
    ?: rootProject.projectDir.toPath().toRealPath().parent
val stableFlutterOutput = actualProjectRoot
    .resolve("build/app/intermediates/flutter/canonical_release").toFile()
gradle.projectsEvaluated {
    tasks.withType<FlutterTask>().matching { it.name == "compileFlutterBuildRelease" }.configureEach {
        intermediateDir = stableFlutterOutput
    }
    // The stock CopySpec captured the original intermediate directory earlier.
    // Keep the task active: Gradle cleans its previous output on NO-SOURCE and
    // that output overlaps mergeReleaseAssets. Copy only the stable bundle.
    tasks.withType<Copy>().matching { it.name == "copyFlutterAssetsRelease" }.configureEach {
        from(stableFlutterOutput) { include("flutter_assets/**") }
        exclude(org.gradle.api.specs.Spec<org.gradle.api.file.FileTreeElement> { element ->
            !element.file.toPath().normalize().startsWith(stableFlutterOutput.toPath().normalize())
        })
    }
}
val generatedFlutterAssets = stableFlutterOutput.resolve("flutter_assets")
val stagedFlutterAssets = layout.buildDirectory.dir("generated/pulsepath_assets/release")
val verifyPulsePathReleaseAssets = tasks.register("verifyPulsePathReleaseAssets") {
    dependsOn("compileFlutterBuildRelease")
    doLast {
        listOf("FontManifest.json", "AssetManifest.bin", "fonts/MaterialIcons-Regular.otf",
            "assets/branding/pulsepath_icon.png", "assets/maptiler-logo.png").forEach { asset ->
            val file = generatedFlutterAssets.resolve(asset)
            if (!file.isFile || file.length() == 0L) {
                throw GradleException("Missing generated Flutter asset: $asset. Rebuild the Flutter asset bundle before packaging.")
            }
        }
    }
}
val stagePulsePathReleaseAssets = tasks.register<Copy>("stagePulsePathReleaseAssets") {
    dependsOn(verifyPulsePathReleaseAssets)
    from(generatedFlutterAssets) { into("flutter_assets") }
    into(stagedFlutterAssets)
    outputs.upToDateWhen { false }
}
android.sourceSets.getByName("release").assets.srcDir(stagedFlutterAssets.get().asFile)
tasks.matching { it.name == "mergeReleaseAssets" }.configureEach {
    dependsOn(stagePulsePathReleaseAssets)
}
tasks.matching { it.name == "packageRelease" }.configureEach {
    doLast {
        val packages = outputs.files.asFileTree.matching { include("**/*.apk") }.files
        if (packages.isEmpty()) throw GradleException("Release APK was not produced")
        packages.forEach { apk ->
            ZipFile(apk).use { archive ->
                listOf("FontManifest.json", "AssetManifest.bin", "fonts/MaterialIcons-Regular.otf",
                    "assets/branding/pulsepath_icon.png", "assets/maptiler-logo.png").forEach { asset ->
                    if (archive.getEntry("assets/flutter_assets/$asset") == null) {
                        throw GradleException("Release APK is missing Flutter asset: $asset")
                    }
                }
            }
        }
    }
}

// Apply the same bundle protection to debug APKs. In Windows alias builds the
// stock copy task can otherwise leave only VM/kernel assets, without fonts/UI.
val stableDebugFlutterOutput = actualProjectRoot
    .resolve("build/app/intermediates/flutter/canonical_debug").toFile()
gradle.projectsEvaluated {
    tasks.withType<FlutterTask>().matching { it.name == "compileFlutterBuildDebug" }.configureEach {
        intermediateDir = stableDebugFlutterOutput
    }
    tasks.withType<Copy>().matching { it.name == "copyFlutterAssetsDebug" }.configureEach {
        from(stableDebugFlutterOutput) { include("flutter_assets/**") }
        exclude(org.gradle.api.specs.Spec<org.gradle.api.file.FileTreeElement> { element ->
            !element.file.toPath().normalize().startsWith(stableDebugFlutterOutput.toPath().normalize())
        })
    }
}
val generatedDebugFlutterAssets = stableDebugFlutterOutput.resolve("flutter_assets")
val stagedDebugFlutterAssets = layout.buildDirectory.dir("generated/pulsepath_assets/debug")
val verifyPulsePathDebugAssets = tasks.register("verifyPulsePathDebugAssets") {
    dependsOn("compileFlutterBuildDebug")
    doLast {
        listOf("FontManifest.json", "AssetManifest.bin", "fonts/MaterialIcons-Regular.otf",
            "assets/branding/pulsepath_icon.png", "assets/maptiler-logo.png", "kernel_blob.bin").forEach { asset ->
            val file = generatedDebugFlutterAssets.resolve(asset)
            if (!file.isFile || file.length() == 0L) throw GradleException("Missing generated debug Flutter asset: $asset")
        }
    }
}
val stagePulsePathDebugAssets = tasks.register<Copy>("stagePulsePathDebugAssets") {
    dependsOn(verifyPulsePathDebugAssets)
    from(generatedDebugFlutterAssets) { into("flutter_assets") }
    into(stagedDebugFlutterAssets)
    outputs.upToDateWhen { false }
}
android.sourceSets.getByName("debug").assets.srcDir(stagedDebugFlutterAssets.get().asFile)
tasks.matching { it.name == "mergeDebugAssets" }.configureEach { dependsOn(stagePulsePathDebugAssets) }
tasks.matching { it.name == "packageDebug" }.configureEach {
    doLast {
        val packages = outputs.files.asFileTree.matching { include("**/*.apk") }.files
        if (packages.isEmpty()) throw GradleException("Debug APK was not produced")
        packages.forEach { apk ->
            ZipFile(apk).use { archive ->
                listOf("FontManifest.json", "AssetManifest.bin", "fonts/MaterialIcons-Regular.otf",
                    "assets/branding/pulsepath_icon.png", "assets/maptiler-logo.png", "kernel_blob.bin").forEach { asset ->
                    if (archive.getEntry("assets/flutter_assets/$asset") == null) throw GradleException("Debug APK is missing Flutter asset: $asset")
                }
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core:1.13.1")
    implementation("com.google.android.gms:play-services-fitness:21.3.0")
    implementation("com.google.android.gms:play-services-location:21.2.0")
    implementation("androidx.work:work-runtime:2.10.1")
    testImplementation("junit:junit:4.13.2")
}
