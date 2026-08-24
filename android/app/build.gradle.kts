plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Prepare les fichiers web embarques avant chaque construction. Plus rien
// a lancer a la main : voir android/preparer-assets.gradle.kts.
apply(from = "../preparer-assets.gradle.kts")

android {
    namespace = "com.modulimo.cohabitat"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.modulimo.cohabitat.demo"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false   // l'application est une page web, rien a reduire
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    // WebViewAssetLoader : sert les fichiers embarques sous une origine
    // https, ce qui donne acces a localStorage et evite les restrictions
    // du protocole file://.
    implementation("androidx.webkit:webkit:1.11.0")
}
