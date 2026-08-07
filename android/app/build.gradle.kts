import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名：CI 通过环境变量（ANDROID_KEYSTORE_PATH / *_PASSWORD / KEY_ALIAS）提供，
// 本地通过 android/key.properties 提供。两者都没有时回退 debug 签名（仅供本地调试，
// debug 签名每台机器不同，无法用于「覆盖更新」）。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
fun signingProp(envName: String, propName: String): String? =
    System.getenv(envName) ?: keystoreProperties.getProperty(propName)
val releaseStorePath = signingProp("ANDROID_KEYSTORE_PATH", "storeFile")
val hasReleaseSigning = releaseStorePath != null && file(releaseStorePath).exists()

// WJPlayer 仅面向 64 位 ARM Android 手机。
val targetAbi = "arm64-v8a"
val excludedAbis = listOf("armeabi-v7a", "x86", "x86_64")

android {
    namespace = "com.mapleling.wjplayer"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.mapleling.wjplayer"
        minSdk = 24  // Vulkan 支持需要 API 24+ (Android 7.0+)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                // Keep the JNI bridge self-contained so packaging does not
                // collide with the shared STL shipped by prebuilt native libs.
                arguments += "-DANDROID_STL=c++_static"
            }
        }

        ndk {
            abiFilters.add(targetAbi)
        }

    }

    // Android 手机端是唯一产品，不定义 TV 或桌面 Flavor。

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packagingOptions {
        excludes += excludedAbis.map { "lib/$it/**" }
        // 优先使用项目内 arm64 原生库，覆盖依赖包可能附带的副本。
        pickFirsts += listOf(
            "lib/arm64-v8a/libc++_shared.so",
            "lib/arm64-v8a/libmpv.so"
        )
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = file(releaseStorePath!!)
                storePassword = signingProp("ANDROID_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = signingProp("ANDROID_KEY_ALIAS", "keyAlias")
                keyPassword = signingProp("ANDROID_KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有发布签名就用统一发布 key（可覆盖更新）；否则回退 debug（仅本地）。
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // Flutter release 默认开启 R8（构建产物已被混淆，字段被改名为 a/b/c/d）。
            // libplayer.so(mpv-android JNI 桥)在 create() 里通过 GetStaticMethodID 反查
            // is.xyz.mpv.MPVLib 的 eventProperty/event/logMessage 回调；R8 看不到 JNI 调用方，
            // 会把这些「无 Java 引用」的方法删掉 → 运行时 NoSuchMethodError → SIGABRT。
            // 显式接入 keep 规则(proguard-rules.pro)保住 JNI 回调面。
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    val media3Version = "1.8.0"

    // Media3 ExoPlayer（原生播放器内核）
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-exoplayer-dash:$media3Version")

    // FFmpeg 软件解码扩展：EAC3/AC3/DTS/TrueHD 等设备硬件不支持的音频格式
    // 由 FFmpeg 兜底解码（ExoPlayerPlugin 已设 EXTENSION_RENDERER_MODE_PREFER
    // + enableDecoderFallback，缺此依赖时扩展渲染器不可用、静默回退硬件解码，
    // 设备无对应 MediaCodec 解码器即播放失败/无声）。
    implementation("androidx.media3:media3-decoder-ffmpeg:$media3Version")

    // Mature ASS integration for Media3/ExoPlayer.
    implementation("io.github.peerless2012:ass-media:0.4.0")


}

flutter {
    source = "../.."
}
