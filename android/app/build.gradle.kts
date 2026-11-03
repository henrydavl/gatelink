plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.compose.compiler)
}

android {
  namespace = "com.example.gatelink"
  compileSdk = 36
  defaultConfig {
    applicationId = "com.example.gatelink"
    // 30: Keystore keys with an auth timeout (setUserAuthenticationParameters).
    minSdk = 30
    targetSdk = 36
    versionCode = 1
    versionName = "2.0.6"
    // libopenconnect is built for arm64 only (scripts/build-openconnect-android.sh).
    ndk { abiFilters += "arm64-v8a" }
  }

  buildTypes {
    release {
      isMinifyEnabled = false
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  buildFeatures {
    compose = true
  }
}

kotlin {
  jvmToolchain(17)
}

dependencies {
  implementation(platform(libs.androidx.compose.bom))
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.activity.compose)
  implementation(libs.androidx.biometric)
  implementation(libs.androidx.camera.camera2)
  implementation(libs.androidx.camera.view)
  implementation(libs.androidx.fragment)
  implementation(libs.androidx.lifecycle.runtime.compose)
  implementation(libs.androidx.lifecycle.viewmodel.compose)
  implementation(libs.androidx.compose.ui)
  implementation(libs.androidx.compose.ui.tooling.preview)
  implementation(libs.androidx.compose.material3)
  implementation(libs.kotlinx.coroutines.android)
  implementation(libs.zxing.core)
  debugImplementation(libs.androidx.compose.ui.tooling)

  testImplementation(libs.junit)
}
