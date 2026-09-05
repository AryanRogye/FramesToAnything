plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.aryanrogye.iosfiretv"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.aryanrogye.iosfiretv"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

// This is the local and CI merge gate for the receiver's most important
// playback invariant. Keep the named task stable so branch protection can
// continue requiring it even if the underlying build is reorganized.
tasks.register("verifyPlaybackSafety") {
    group = "verification"
    description = "Runs the A/V clock contract and builds both receiver APK variants."
    dependsOn("testDebugUnitTest", "assembleDebug", "assembleRelease")
}
