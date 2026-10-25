pluginManagement {
    // Flutter forwards -P properties, but has no Gradle --offline flag.
    // Apply it before plugin resolution, including Flutter's included build.
    if (providers.gradleProperty("pulsepath.offline").orNull == "true") {
        gradle.startParameter.isOffline = true
    }
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    // Firebase: google-services читает android/app/google-services.json.
    id("com.google.gms.google-services") version "4.4.2" apply false
}

include(":app")
