import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Privacy-safe startup breadcrumbs for the Android "exits after the splash
/// screen" investigation.
///
/// Two sinks are supported and each stays silent unless a build asks for it:
///
///  * in debug builds the mark is printed synchronously to logcat, which is what
///    the CI emulator smoke test reads;
///  * in an Android build compiled with `BuildConfig.STARTUP_PROBE` the mark is
///    also forwarded to the native recorder over `iq.scanid/startup_probe`,
///    which keeps it in a report file the person can share from the phone
///    without a computer.
///
/// The channel is created by `MainActivity` before `main()` runs, so a mark
/// cannot be lost to plugin registration. Marks made before the enabled/disabled
/// answer arrives are buffered and flushed in order. Nothing here records paths,
/// project data, image contents, keys or user text: only stage names and the
/// runtime type of an error.
class StartupDiagnostics {
  StartupDiagnostics._();

  static const MethodChannel _channel = MethodChannel(
    'iq.scanid/startup_probe',
  );

  static int _sequence = 0;
  static bool? _nativeEnabled;
  static final List<String> _pending = <String>[];
  static bool _publishRequested = false;

  static void mark(String stage) {
    if (kDebugMode) {
      final sequence = ++_sequence;
      debugPrintSynchronously(
        '[ScanIdStartup] ${sequence.toString().padLeft(4, '0')} $stage',
      );
    }
    _forward(stage);
  }

  static void failure(String stage, Object error) {
    final safeDetail = error is PlatformException ? ' code=${error.code}' : '';
    mark('$stage failed type=${error.runtimeType}$safeDetail');
  }

  /// Asks the native recorder whether this build carries it, then flushes the
  /// marks that were made before the answer arrived.
  static Future<void> attachToPlatform() async {
    if (kIsWeb) return;
    var enabled = false;
    try {
      enabled = await _channel.invokeMethod<bool>('enabled') ?? false;
    } on MissingPluginException {
      // No native recorder in this build; the debug log is the only sink.
    } on PlatformException {
      // The recorder exists but refused to answer; treat it as absent.
    }
    _nativeEnabled = enabled;
    if (!enabled) {
      _pending.clear();
      return;
    }
    for (final stage in _pending) {
      unawaited(_send('mark', stage));
    }
    _pending.clear();
  }

  /// Asks the diagnostic build to write the report for this run now that a
  /// window has been drawn, so a successful start still leaves evidence.
  static void publishReportAfterFirstFrame() {
    if (kIsWeb || _publishRequested) return;
    _publishRequested = true;
    unawaited(_publish());
  }

  static Future<void> _publish() async {
    try {
      await _channel.invokeMethod<void>('publish');
    } on MissingPluginException {
      // No native recorder in this build.
    } on PlatformException {
      // Best effort: a failed report write must not affect the application.
    }
  }

  static void _forward(String stage) {
    final enabled = _nativeEnabled;
    if (enabled == null) {
      if (_pending.length < 200) _pending.add(stage);
      return;
    }
    if (enabled) unawaited(_send('mark', stage));
  }

  static Future<void> _send(String method, String stage) async {
    try {
      await _channel.invokeMethod<void>(method, <String, Object?>{
        'stage': stage,
      });
    } on MissingPluginException {
      // No native recorder in this build.
    } on PlatformException {
      // Diagnostics must never disturb the path they are observing.
    }
  }

  /// Logs uncaught Dart errors while preserving the handlers Flutter had set.
  ///
  /// The Android recorder also watches Java/Kotlin exceptions, but it never sees
  /// a Dart error, so both sinks are installed here.
  static void installErrorHooks() {
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
