// Release signing comes from ~/.gradle/gradle.properties, never from this repo.
val signingProps = listOf(
    "QR_GATE_STORE_FILE",
    "QR_GATE_STORE_PASSWORD",
    "QR_GATE_KEY_ALIAS",
    "QR_GATE_KEY_PASSWORD",
)
val missingSigningProps = signingProps.filterNot { project.hasProperty(it) }

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
}

android {
    namespace = "com.fullcircle.qrgate"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.fullcircle.qrgate"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "1.0.0"
        manifestPlaceholders["usesCleartextTraffic"] = "false"
    }

    signingConfigs {
        create("release") {
            if (missingSigningProps.isEmpty()) {
                storeFile = file(project.property("QR_GATE_STORE_FILE") as String)
                storePassword = project.property("QR_GATE_STORE_PASSWORD") as String
                keyAlias = project.property("QR_GATE_KEY_ALIAS") as String
                keyPassword = project.property("QR_GATE_KEY_PASSWORD") as String
            }
        }
    }

    buildTypes {
        debug {
            manifestPlaceholders["usesCleartextTraffic"] = "true"
        }
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            manifestPlaceholders["usesCleartextTraffic"] = "false"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf("-opt-in=androidx.camera.core.ExperimentalGetImage")
    }

    buildFeatures {
        buildConfig = true
        viewBinding = true
    }
}

// Fail before anything builds, rather than emitting an unsigned APK that only
// fails at install time, or dying deep in packageRelease after a long build.
gradle.taskGraph.whenReady {
    val wantsRelease = allTasks.any { t ->
        t.name.contains("Release") &&
            (t.name.startsWith("package") || t.name.startsWith("assemble") ||
                t.name.startsWith("bundle"))
    }
    if (wantsRelease && missingSigningProps.isNotEmpty()) {
        throw GradleException(
            "Cannot build a release APK: missing signing propert" +
                (if (missingSigningProps.size == 1) "y " else "ies ") +
                missingSigningProps.joinToString(", ") +
                ". Set them in ~/.gradle/gradle.properties " +
                "(see .claude/skills/qr-gate-punch.md).",
        )
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("com.google.mlkit:face-detection:16.1.7")

    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    testImplementation("junit:junit:4.13.2")
}
