plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "org.albumwinnow.core"
    compileSdk = 35
    ndkVersion = "28.2.13676358"
    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    sourceSets["main"].jniLibs.srcDir("../../../.local/core/android/jniLibs")
    sourceSets["main"].assets.srcDir("../../../.local/core/android/assets")
    sourceSets["androidTest"].assets.srcDir("../../CoreFixtures")
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    packaging { jniLibs.useLegacyPackaging = false }
}

dependencyLocking { lockAllConfigurations() }

dependencies {
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
