import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ═══ 正式簽名：讀 android/key.properties（怎麼填看 key.properties.example）═══
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// key.properties 填了、而且 .jks 文件真的存在，才啟用正式簽名。
val releaseKeystoreReady =
    keystorePropertiesFile.exists() &&
        (keystoreProperties["storeFile"] as String?)
            ?.let { file(it).exists() } == true

// Debug 開發不受影響；但任何 release APK/AAB 任務都必須有正式簽名，
// 避免開源貢獻者或 CI 誤把 debug-key release 當成可分發成品。
gradle.taskGraph.whenReady {
    val releaseArtifactRequested = allTasks.any { task ->
        Regex("^(assemble|bundle|package).*Release$").matches(task.name)
    }
    if (releaseArtifactRequested && !releaseKeystoreReady) {
        throw GradleException(
            "Release signing is not configured. Add android/key.properties and a valid release keystore."
        )
    }
}

// Optional side-by-side validation package. Normal debug/release builds keep
// com.yanci.holt; CI or a local safety check may pass Gradle properties such as
// -PholtApplicationIdSuffix=.staging -PholtApplicationLabel="Holt Staging".
val holtApplicationIdSuffix = providers.gradleProperty("holtApplicationIdSuffix")
    .orNull
    ?.trim()
    ?.takeIf { it.isNotEmpty() }
val holtApplicationLabel = providers.gradleProperty("holtApplicationLabel")
    .orNull
    ?.trim()
    ?.takeIf { it.isNotEmpty() }
    ?: "Holt"
if (holtApplicationIdSuffix != null &&
    !Regex("^\\.[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*$").matches(holtApplicationIdSuffix)
) {
    error("holtApplicationIdSuffix must start with '.' and contain package-safe segments")
}

android {
    namespace = "com.yanci.holt"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.yanci.holt${holtApplicationIdSuffix ?: ""}"
        manifestPlaceholders["holtApplicationLabel"] = holtApplicationLabel
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 僅打包 arm64：flutter_gemma / llamadart / LiteRt 只提供 arm64 原生庫，
        // 若包含 armeabi-v7a 或 x86_64，Android 會選到缺少 libflutter.so 的資料夾而崩潰。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
                // flutter_gemma 0.16.5 ships this optional qdrant-edge RAG
                // library with 4 KB ELF LOAD alignment. It makes Android 16 KB
                // page-size checks fail even though the app only uses Gemma
                // inference, not flutter_gemma's vector-store/RAG API.
                "lib/**/libqdrant_edge_ffi.so",
                // Optional Qualcomm HTP DSP-side libraries from flutter_gemma.
                // These prebuilts are still 4 KB-aligned; excluding them keeps
                // CPU/GPU inference usable while avoiding Android 16 KB
                // compatibility failures.
                "lib/**/libQnnHtpV*Skel.so",
                // Qualcomm NPU dispatch/runtime binaries in flutter_gemma's
                // downloaded bundle do not include verifiable redistribution
                // terms. Holt only exposes CPU/GPU local inference, so keep the
                // entire optional QNN path out of every distributable APK.
                "lib/**/libQnn*.so",
                "lib/**/libLiteRtDispatch_Qualcomm.so",
                // Development-only Vulkan validation layer; never required by
                // app runtime and otherwise adds ~15 MB to the package.
                "lib/**/libVkLayer_khronos_validation.so",
                // flutter_gemma also pulls in MediaPipe's standalone image
                // generator. Holt uses the shared multimodal LLM classes but
                // never calls this separate native image-generation engine.
                "lib/**/libimagegenerator_gpu.so",
                "lib/**/libmediapipe_tasks_vision_jni.so",
                "lib/**/libmediapipe_tasks_vision_image_generator_jni.so",
            )
        }
    }

    signingConfigs {
        if (releaseKeystoreReady) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = if (releaseKeystoreReady) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        release {
            if (releaseKeystoreReady) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

// sherpa_onnx 1.13.5 declares its WebAssembly implementation as an ordinary
// package asset, so Flutter copies it into Android even though this target uses
// the arm64 native plugin. Prune only that unreachable web payload immediately
// before Android merges Flutter assets (~15 MB uncompressed). Flutter web/PWA
// builds do not execute this Gradle hook.
tasks.matching {
    it.name == "mergeDebugAssets" || it.name == "mergeReleaseAssets"
}.configureEach {
    doFirst {
        val variant = name
            .removePrefix("merge")
            .removeSuffix("Assets")
            .replaceFirstChar { it.lowercase() }
        delete(
            layout.buildDirectory.dir(
                "intermediates/flutter/$variant/flutter_assets/packages/sherpa_onnx_web"
            )
        )
    }
}
