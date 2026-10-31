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
// SHA-256 of the certificate a legitimate update package must be signed with. It
// is not a secret: the release workflows compare this same value against the
// keystore they sign with and against the APK they built, and an app that cannot
// reach it refuses to install anything. An empty value means this build carries no
// pin of its own, so the installer falls back to the signature of the app already
// installed on the device, and refuses when even that cannot be read.
val expectedCertSha256 = (
    providers.environmentVariable("EXPECTED_CERT_SHA256").orNull
        ?: localSigningProperties.getProperty("EXPECTED_CERT_SHA256")
    )
    ?.trim()
    ?.lowercase()
    .orEmpty()
// A buildConfigField writes source text, so the constant it defines needs quotes.
val expectedCertSha256Literal = "\"$expectedCertSha256\""

// Identity of the tree that produced this APK, so a startup report names the
// build it came from instead of "some APK from Actions".
val buildSha = (
    providers.environmentVariable("GITHUB_SHA").orNull
        ?: providers.environmentVariable("SCAN_ID_BUILD_SHA").orNull
    )
    ?.trim()
    ?.takeIf { it.isNotEmpty() }
    ?: "local"
val buildShaLiteral = "\"${buildSha.replace("\"", "")}\""

// The startup evidence recorder is compiled in only where it is asked for: the
// `diagnostic` flavor always, and the production `scanid` flavor only when a
// build explicitly passes -PscanIdStartupProbe=true. Production releases keep
// the default (off), so normal installs neither write report files nor load the
// ONNX Runtime libraries outside their normal code path.
val startupProbeRequested = providers.gradleProperty("scanIdStartupProbe")
    .orNull
    ?.equals("true", ignoreCase = true) == true

// Release variants must never fall back to the debug key. The explicit environment
// flag also protects CI jobs whose requested task names are indirect.
val releaseTaskRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.substringAfterLast(':').contains("release", ignoreCase = true)
}
val requireReleaseSigning = releaseTaskRequested ||
    providers.environmentVariable("REQUIRE_RELEASE_SIGNING")
        .orNull
        ?.equals("true", ignoreCase = true) == true

val hasKeyStoreSource = !keyStoreBase64.isNullOrBlank() || !localKeyStorePath.isNullOrBlank()
val signingPasswordsAndAlias = listOf(keyStorePassword, keyAlias, keyPassword)
val hasAnySigningValue = hasKeyStoreSource || signingPasswordsAndAlias.any { !it.isNullOrBlank() }
val hasAllSigningValues = hasKeyStoreSource && signingPasswordsAndAlias.all { !it.isNullOrBlank() }

// Name (never value) of every missing signing input, for actionable failures.
val missingSigningValues = buildList {
    if (!hasKeyStoreSource) add("KEYSTORE_BASE64 (or local storeFile in key.properties)")
    if (keyStorePassword.isNullOrBlank()) add("KEYSTORE_STORE_PASSWORD")
    if (keyAlias.isNullOrBlank()) add("KEYSTORE_KEY_ALIAS")
    if (keyPassword.isNullOrBlank()) add("KEYSTORE_KEY_PASSWORD")
}

if (hasAnySigningValue && !hasAllSigningValues) {
    throw GradleException(
        "Incomplete Android release signing configuration. Missing: " +
            missingSigningValues.joinToString(", ") + ".",
    )
}
if (requireReleaseSigning && !hasAllSigningValues) {
    throw GradleException(
        "Release signing is required, but Android signing values are missing. " +
            "Missing: " + missingSigningValues.joinToString(", ") + "."
    )
}
// A pin that is present must be the digest shape the release workflows compare, so
// a typo cannot silently disable the in-app publisher check on every installed app.
if (expectedCertSha256.isNotEmpty() && !Regex("^[0-9a-f]{64}$").matches(expectedCertSha256)) {
    throw GradleException(
        "EXPECTED_CERT_SHA256 must be the 64 hex digits of the release certificate " +
            "digest; the supplied value is not that shape."
    )
}

// Also inspect the resolved task graph so aggregate invocations (for example `build`)
// cannot package a release variant using the debug fallback below.
gradle.taskGraph.whenReady {
    val requestsReleasePackage = allTasks.any { task ->
        val taskName = task.name.lowercase()
        (taskName.startsWith("assemble") || taskName.startsWith("bundle")) &&
            taskName.endsWith("release")
    }
    if (requestsReleasePackage && !hasAllSigningValues) {
        throw GradleException("Release APK/AAB packaging requires a configured release keystore.")
    }
    if (requestsReleasePackage && expectedCertSha256.isEmpty()) {
        // Packaging without the pin would ship an app whose update path has no
        // anchor to compare a package's signer with. Fail here instead of leaving
        // every installed build to trust whatever its feed returns.
        throw GradleException(
            "Release APK/AAB packaging requires EXPECTED_CERT_SHA256, the " +
                "certificate fingerprint an update package must be signed with."
        )
    }
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

    // The update installer reads the release certificate pin out of BuildConfig,
    // and AGP 8 stopped generating that class unless a build asks for it.
    buildFeatures {
        buildConfig = true
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
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Compiled in so a downloaded package can be checked against the publisher
        // this build was signed with, without asking a network what is true.
        buildConfigField("String", "EXPECTED_UPDATE_CERT_SHA256", expectedCertSha256Literal)
        // Startup evidence recorder (see StartupProbe.kt). Off unless a variant
        // or an explicit -P flag turns it on.
        buildConfigField(
            "boolean",
            "STARTUP_PROBE",
            if (startupProbeRequested) "true" else "false",
        )
        buildConfigField("String", "BUILD_SHA", buildShaLiteral)
    }

    flavorDimensions += "edition"
    productFlavors {
        create("scanid") {
            dimension = "edition"
            // Inherits the existing production applicationId.
        }
        create("annotator") {
            dimension = "edition"
            applicationId = "iq.scanid.referenceannotator"
            versionNameSuffix = "-reference"
        }
        create("diagnostic") {
            dimension = "edition"
            applicationIdSuffix = ".startupdiag"
            versionNameSuffix = "-startupdiag"
            // This flavor exists only to record why a device exits after the
            // splash screen, so the evidence recorder is always on here.
            buildConfigField("boolean", "STARTUP_PROBE", "true")
        }
    }

    if (releaseKeyStoreFile != null) {
        // Capture the script-level values under distinct names BEFORE entering
        // the SigningConfig receiver scope. Inside `create("release") { ... }`
        // the receiver is a SigningConfig, so `keyAlias = keyAlias` and
        // `keyPassword = keyPassword` would resolve to the receiver's own
        // (still null) properties -- a self-assignment that made AGP fail with:
        //   SigningConfig "release" is missing required property "keyPassword"
        // even though the environment secrets reached Gradle correctly.
        val signingStorePassword = keyStorePassword
        val signingKeyAlias = keyAlias
        val signingKeyPassword = keyPassword
        signingConfigs {
            create("release") {
                storeFile = releaseKeyStoreFile!!
                storePassword = signingStorePassword
                keyAlias = signingKeyAlias
                keyPassword = signingKeyPassword
                storeType = releaseKeyStoreType
            }
        }
    }

    buildTypes {
        release {
            // The task-graph guard rejects release packaging without this release config;
            // the debug assignment is not permitted to produce a Release APK/AAB.
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
dependencies {
    implementation("androidx.core:core:1.13.1")
    androidTestImplementation("androidx.test:core:1.6.1")
    // integration_test 3.35.7 exposes runner 1.2+ and Gradle's Android
    // consistent-resolution rule pins androidTest to the app runtime's 1.2.0.
    androidTestImplementation("androidx.test:runner:1.2.0")
    androidTestImplementation("junit:junit:4.12")
}
