import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Temporary, privacy-safe startup breadcrumbs for the Android crash report.
/// The markers are enabled only in debug builds and never include paths,
/// project data, image contents, exception messages, or platform details.
class StartupDiagnostics {
  StartupDiagnostics._();

  static int _sequence = 0;

  static void mark(String stage) {
    if (!kDebugMode) return;
    final sequence = ++_sequence;
    debugPrintSynchronously(
      '[ScanIdStartup] ${sequence.toString().padLeft(4, '0')} $stage',
    );
  }

  static void failure(String stage, Object error) {
    if (!kDebugMode) return;
    final safeDetail = error is PlatformException ? ' code=${error.code}' : '';
    mark('$stage failed type=${error.runtimeType}$safeDetail');
  }

  /// Logs uncaught Dart errors while preserving the handlers Flutter had set.
  static void installErrorHooks() {
    if (!kDebugMode) return;

    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      failure('flutter.framework_error', details.exception);
      if (previousFlutterHandler != null) {
        previousFlutterHandler(details);
      } else {
        FlutterError.dumpErrorToConsole(details);
      }
    };

    final dispatcher = ui.PlatformDispatcher.instance;
    final previousPlatformHandler = dispatcher.onError;
    dispatcher.onError = (error, stackTrace) {
      failure('dart.uncaught_async_error', error);
      return previousPlatformHandler?.call(error, stackTrace) ?? false;
    };
  }
}
