allprojects {
    repositories {
        // Official artifacts prepared locally when Google Maven is unreachable.
        // Optional: a clean checkout still uses the standard repositories above.
        val localRecordingRepository = rootProject.file("../build/test_dependencies/recording-maven")
        if (localRecordingRepository.isDirectory) {
            maven { url = uri(localRecordingRepository) }
        }
        google()
        mavenCentral()
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
    fun fixCompileSdk() {
        val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        android?.compileSdkVersion(36)
    }

    if (project.state.executed) {
        fixCompileSdk()
    } else {
        project.afterEvaluate {
            fixCompileSdk()
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
