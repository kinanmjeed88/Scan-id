# Used only when CI opts into androidTest against the minified Release app.
# The production app remains shrunk by its own rules. The test APK's runner is
# reflective/service-loaded, so do not shrink its AndroidX/JUnit infrastructure.
-keep class androidx.** { *; }
-keep class org.junit.** { *; }
-keep class iq.scanid.scan_id.ReleaseIntakeInstrumentationTest { *; }
# Optional compile-only/service-loader references that need not be packaged.
-dontwarn com.google.errorprone.annotations.**
-dontwarn org.kxml2.io.**
