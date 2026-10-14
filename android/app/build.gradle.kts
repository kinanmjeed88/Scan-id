import java.io.ByteArrayInputStream
import java.io.File
import java.security.KeyStore
import java.security.PrivateKey
import java.util.Base64
import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localSigningProperties = Properties()
val localSigningPropertiesFile = rootProject.file("key.properties")
if (localSigningPropertiesFile.isFile) {
    try {
        localSigningPropertiesFile.inputStream().use(localSigningProperties::load)
    } catch (error: Exception) {
        throw GradleException("Could not read the ignored local Android signing properties file.", error)
    }
}

// Environment variables take precedence; key.properties is a git-ignored local fallback.
val keyStoreBase64 = providers.environmentVariable("KEYSTORE_BASE64").orNull
    ?: localSigningProperties.getProperty("KEYSTORE_BASE64")
val localKeyStorePath = localSigningProperties.getProperty("storeFile")
val keyStorePassword = providers.environmentVariable("KEYSTORE_STORE_PASSWORD").orNull
    ?: localSigningProperties.getProperty("KEYSTORE_STORE_PASSWORD")
val keyAlias = providers.environmentVariable("KEYSTORE_KEY_ALIAS").orNull
    ?: localSigningProperties.getProperty("KEYSTORE_KEY_ALIAS")
val keyPassword = providers.environmentVariable("KEYSTORE_KEY_PASSWORD").orNull
    ?: localSigningProperties.getProperty("KEYSTORE_KEY_PASSWORD")
val requireReleaseSigning = providers.environmentVariable("REQUIRE_RELEASE_SIGNING")
    .orNull
    ?.equals("true", ignoreCase = true) == true

val hasKeyStoreSource = !keyStoreBase64.isNullOrBlank() || !localKeyStorePath.isNullOrBlank()
val signingPasswordsAndAlias = listOf(keyStorePassword, keyAlias, keyPassword)
val hasAnySigningValue = hasKeyStoreSource || signingPasswordsAndAlias.any { !it.isNullOrBlank() }
val hasAllSigningValues = hasKeyStoreSource && signingPasswordsAndAlias.all { !it.isNullOrBlank() }

if (hasAnySigningValue && !hasAllSigningValues) {
    throw GradleException(
        "Provide KEYSTORE_BASE64 or a local storeFile, plus " +
            "KEYSTORE_STORE_PASSWORD, KEYSTORE_KEY_ALIAS, and KEYSTORE_KEY_PASSWORD.",
    )
}
if (requireReleaseSigning && !hasAllSigningValues) {
    throw GradleException(
        "Release signing is required, but Android signing values are missing."
    )
}

var releaseKeyStoreFile: File? = null
var releaseKeyStoreType: String? = null

if (hasAllSigningValues) {
    val keyStoreBytes = if (!keyStoreBase64.isNullOrBlank()) {
        val encodedKeyStore = keyStoreBase64.filterNot { it.isWhitespace() }
        try {
            Base64.getDecoder().decode(encodedKeyStore)
        } catch (error: IllegalArgumentException) {
            throw GradleException("KEYSTORE_BASE64 is not valid Base64.", error)
        }
    } else {
        val localKeyStoreFile = rootProject.file(localKeyStorePath!!)
        if (!localKeyStoreFile.isFile) {
            throw GradleException("The local signing keystore file configured by storeFile is missing.")
        }
        try {
            localKeyStoreFile.readBytes()
        } catch (error: Exception) {
            throw GradleException("Could not read the local Android signing keystore file.", error)
        }
    }
    if (keyStoreBytes.isEmpty()) {
        throw GradleException("The supplied Android signing keystore is empty.")
    }

    var loadedKeyStore: KeyStore? = null
    var detectedKeyStoreType: String? = null
    for (candidateType in listOf("JKS", "PKCS12")) {
        try {
            val candidate = KeyStore.getInstance(candidateType)
            ByteArrayInputStream(keyStoreBytes).use {
                candidate.load(it, keyStorePassword!!.toCharArray())
            }
            loadedKeyStore = candidate
            detectedKeyStoreType = candidateType
            break
        } catch (_: Exception) {
            // Try the other common Android keystore format without logging secrets.
        }
    }

    val parsedKeyStore = loadedKeyStore
        ?: throw GradleException(
            "Could not read KEYSTORE_BASE64 as JKS or PKCS12; check the keystore and store password.",
        )
    if (!parsedKeyStore.containsAlias(keyAlias!!)) {
        throw GradleException("KEYSTORE_KEY_ALIAS was not found in the keystore.")
    }
    if (!parsedKeyStore.isKeyEntry(keyAlias)) {
        throw GradleException("KEYSTORE_KEY_ALIAS does not identify a private-key entry.")
    }
    val signingKey = try {
        parsedKeyStore.getKey(keyAlias, keyPassword!!.toCharArray())
    } catch (error: Exception) {
        throw GradleException("KEYSTORE_KEY_PASSWORD did not unlock the signing key.", error)
    }
    if (signingKey !is PrivateKey) {
        throw GradleException("The selected keystore entry is not a private signing key.")
    }

    val keyStoreFile = layout.buildDirectory
        .file("signing/release-signing.keystore")
        .get()
        .asFile
    try {
        keyStoreFile.parentFile.mkdirs()
        keyStoreFile.writeBytes(keyStoreBytes)
    } catch (error: Exception) {
        throw GradleException("Could not materialize the signing keystore in the build directory.", error)
    }
    releaseKeyStoreFile = keyStoreFile
    releaseKeyStoreType = detectedKeyStoreType
}

android {
    namespace = "iq.scanid.scan_id"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "iq.scanid.scan_id"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (releaseKeyStoreFile != null) {
        signingConfigs {
            create("release") {
                storeFile = releaseKeyStoreFile!!
                storePassword = keyStorePassword
                keyAlias = keyAlias
                keyPassword = keyPassword
                storeType = releaseKeyStoreType
            }
        }
    }

    buildTypes {
        release {
            // CI verification remains debug-signed unless explicit signing variables are supplied.
            // Dedicated release CI sets REQUIRE_RELEASE_SIGNING=true to prohibit that fallback.
            signingConfig = if (releaseKeyStoreFile != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

// Apache-2.0 AndroidX FileProvider; scoped camera URI grants, no storage permission.
dependencies { implementation("androidx.core:core:1.13.1") }
