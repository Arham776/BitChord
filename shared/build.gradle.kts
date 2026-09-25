// BitChord shared KMP module — spec §1.
// Apple-only targets for now; androidMain exists as a dormant placeholder for
// the future Android reunification (§10 non-goals).
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    kotlin("multiplatform") version "2.4.10"
    kotlin("plugin.serialization") version "2.4.10"
    id("com.rickclephas.kmp.nativecoroutines") version "1.0.5"
}

kotlin {
    // One combined XCFramework consumed by AppleApp (spec §1.1).
    val xcf = XCFramework("BitChordShared")

    listOf(
        iosArm64(),
        iosSimulatorArm64(),
        macosArm64(),
        // Add macosX64()/iosX64() only if Intel support becomes a requirement (§1.1).
    ).forEach { target ->
        target.binaries.framework {
            baseName = "BitChordShared"
            isStatic = true
            xcf.add(this)
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation("io.ktor:ktor-client-core:3.2.0")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
            implementation("com.rickclephas.kmp:kmp-nativecoroutines-core:1.0.5")
            // sqldelight: add only if upstream Room usage is confirmed (spec §1.1).
        }

        commonTest.dependencies {
            implementation(kotlin("test"))
        }

        // The Darwin Ktor engine only resolves for Apple targets, so it lives in
        // appleMain — the common ancestor of every configured Apple target.
        appleMain.dependencies {
            implementation("io.ktor:ktor-client-darwin:3.2.0")
        }
    }
}
