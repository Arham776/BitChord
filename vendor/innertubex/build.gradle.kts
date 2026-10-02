import java.util.Base64
plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
}
val generateYtEjsNativeScripts =
    tasks.register("generateYtEjsNativeScripts") {
        val scripts = layout.projectDirectory.dir("src/commonMain/resources/yt_ejs")
        val out = layout.buildDirectory.dir("generated/ytEjsNative")
        inputs.dir(scripts)
        outputs.dir(out)
        doLast {
            val names = listOf("yt.solver.core.min.js", "yt.solver.lib.min.js")
            val entries =
                names.joinToString(",\n") { name ->
                    val b64 = Base64.getEncoder().encodeToString(scripts.file(name).asFile.readBytes())
                    "        \"$name\" to \"\"\"\n" + b64.chunked(100).joinToString("\n") + "\"\"\".replace(\"\\n\", \"\")"
                }
            val dir =
                out
                    .get()
                    .asFile
                    .resolve("com/metrolist/innertubex/cipher")
                    .apply { mkdirs() }
            dir.resolve("YtEjsScriptLoader.native.kt").writeText(
                listOf(
                    "package com.metrolist.innertubex.cipher",
                    "",
                    "import kotlin.io.encoding.Base64",
                    "import kotlin.io.encoding.ExperimentalEncodingApi",
                    "",
                    "@OptIn(ExperimentalEncodingApi::class)",
                    "internal actual fun readYtEjsSolverScript(fileName: String): String =",
                    "    Base64.decode(EMBEDDED[fileName] ?: error(\"Missing embedded script: \$fileName\")).decodeToString()",
                    "",
                    "private val EMBEDDED =",
                    "    mapOf(",
                    entries,
                    "    )",
                    "",
                ).joinToString("\n"),
            )
        }
    }

kotlin {
    iosArm64(); iosSimulatorArm64(); macosArm64()
    sourceSets {
        all { languageSettings.optIn("kotlin.RequiresOptIn"); languageSettings.optIn("kotlin.ExperimentalStdlibApi") }
        commonMain.dependencies {
            api("io.ktor:ktor-client-core:3.5.2")
            api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
            api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            implementation("io.github.dokar3:quickjs-kt:1.0.14")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation("io.ktor:ktor-client-mock:3.5.2")
            implementation("io.ktor:ktor-client-content-negotiation:3.5.2")
            implementation("io.ktor:ktor-serialization-kotlinx-json:3.5.2")
        }
        nativeMain { kotlin.srcDir(generateYtEjsNativeScripts) }
    }
    targets.all { compilations.all { compileTaskProvider.configure {
        compilerOptions.freeCompilerArgs.add("-Xexpect-actual-classes")
    } } }
}
