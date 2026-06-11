plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.emotion.emotion_resolution_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.emotion.emotion_resolution_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // posthog_flutter는 minSdk 23 이상 필요.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 릴리스 서명(테스터 사이드로딩 배포용). CI(GitHub Actions)가 환경변수로
    // 키스토어(PKCS12)를 주입하면 그 키로 서명하고, 없으면 debug로 폴백한다 —
    // 키 없는 로컬/기여자도 빌드 가능. 일정한 키로 서명해야 테스터가 재설치 없이
    // 버전 업데이트를 덮어쓸 수 있다(키스토어/비밀번호는 절대 커밋 금지, Secrets로만).
    val releaseKeystorePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")
    val hasReleaseSigning = releaseKeystorePath != null && file(releaseKeystorePath).exists()

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // 키 미주입 시 debug 서명으로 폴백(`flutter run --release` 등 로컬).
                signingConfigs.getByName("debug")
            }
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
