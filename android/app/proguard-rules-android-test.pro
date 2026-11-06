# Used only when CI opts into androidTest against the minified Release app.
# AndroidX Test references these compile-only/optional service-loader classes;
# they are not part of the production app's ONNX JNI contract.
-dontwarn com.google.errorprone.annotations.**
-dontwarn org.kxml2.io.**
