import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'release_intake_probe.dart';

/// Release-only test entrypoint used by the disposable-key CI regression.
/// The production lib/main.dart and its plugin set are otherwise unchanged.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('iq.scanid.scan_id/release_intake_test');
  Map<String, Object?> result;
  try {
    result = <String, Object?>{
      'status': 'success',
      'evidence': await runReleaseIntakeProbe(),
    };
  } catch (error, stack) {
    result = <String, Object?>{
      'status': 'failure',
      'error': error.toString(),
      'stack': stack.toString(),
    };
  }

  // The Android test registers this handler before executing the Dart
  // entrypoint. The bounded retry only covers platform-channel scheduling.
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      await channel.invokeMethod<void>('finished', result);
      return;
    } on MissingPluginException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError('Native Release intake test did not receive the result.');
}
