plugins {
    id("com.android.application")
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
}

dependencies {
    // Aligne les versions de kotlin-stdlib tirees transitivement par
    // AndroidX. Depuis Kotlin 1.8, kotlin-stdlib-jdk7 et -jdk8 ont ete
    // fusionnes dans kotlin-stdlib ; une dependance AndroidX en reclame
    // encore la version 1.6.21, qui contient toujours ces classes. Les
    // deux jeux se retrouvent alors dans l'APK et la construction echoue
    // sur « Duplicate class kotlin.streams.jdk8.StreamsKt ». Alignees sur
    // une version recente, ces deux archives sont vides.
    //
    // Le greffon Kotlin posait cet alignement lui-meme ; il a ete retire
    // du projet, l'activite etant ecrite en Java.
    implementation(platform("org.jetbrains.kotlin:kotlin-bom:1.9.24"))

    implementation("androidx.appcompat:appcompat:1.7.0")
    // WebViewAssetLoader : sert les fichiers embarques sous une origine
    // https, ce qui donne acces a localStorage et evite les restrictions
    // du protocole file://.
    implementation("androidx.webkit:webkit:1.11.0")
}
