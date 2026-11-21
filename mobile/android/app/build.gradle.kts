import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Ключ подписи релизов. В GitHub Actions — переменные окружения из секретов,
// на своём компьютере — android/key.properties (в git не попадает, см. docs/release.md).
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val releaseStore: String? = System.getenv("ANDROID_KEYSTORE_PATH") ?: keyProps.getProperty("storeFile")
val releasePassword: String? = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: keyProps.getProperty("storePassword")

android {
    namespace = "ru.barakhtinsa.app"
    // 37: этого требуют flutter_local_notifications и androidx.core. targetSdk остаётся от Flutter.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Нужно для flutter_local_notifications (новые API Java на старых Android).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Имя пакета — навсегда: после публикации его не поменять. Не связано с названием приложения.
        applicationId = "ru.barakhtinsa.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Схема возврата из VK ID: vk<ID приложения VK ID>. Задать при сборке:
        // flutter build apk --android-project-arg vkidClientId=12345678 (пока не задано — vk0).
        manifestPlaceholders["vkidRedirectScheme"] =
            "vk" + (project.findProperty("vkidClientId")?.toString() ?: "0")
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStore != null && releasePassword != null) {
            create("release") {
                storeFile = file(releaseStore)
                storePassword = releasePassword
                keyAlias = "release"
                keyPassword = releasePassword
            }
        }
    }

    buildTypes {
        release {
            // Без ключа — отладочная подпись: такой APK годится для проверки, но не для RuStore.
            val release = signingConfigs.findByName("release")
            if (release == null) {
                logger.warn("Ключ подписи не найден — релиз подписан отладочным ключом (не для публикации)")
            }
            signingConfig = release ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
