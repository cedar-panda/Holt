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

// key.properties 填了、而且 .jks 文件真的存在，才啟用正式簽名；
// 否則靜默退回 debug 簽名，開發流程永遠不會被擋住。
val releaseKeystoreReady =
    keystorePropertiesFile.exists() &&
        (keystoreProperties["storeFile"] as String?)
            ?.let { file(it).exists() } == true

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
        applicationId = "com.yanci.holt"
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
        release {
            // .jks 就緒 → 正式簽名；否則退回 debug 簽名（僅供本機開發，
            // 給任何人安裝的包都必須用正式簽名打）
            signingConfig = if (releaseKeystoreReady) {
                signingConfigs.getByName("release")
            } else {
                println("⚠️ 正式簽名未就緒（key.properties 或 .jks 缺失），release 使用 debug 簽名（不可分發）")
                signingConfigs.getByName("debug")
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
