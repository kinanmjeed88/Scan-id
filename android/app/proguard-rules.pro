# Flutter enables R8 for release APKs and loads this file automatically.
# The pinned flutter_onnxruntime Android plugin has no consumer keep rules.
# ONNX Runtime's JNI library looks up these classes, constructors and members
# by name; shrinking/renaming them breaks analysis only in minimized builds.
# Keep the complete native API contract, not just the plugin's Dart facade.
-keep class ai.onnxruntime.** { *; }
