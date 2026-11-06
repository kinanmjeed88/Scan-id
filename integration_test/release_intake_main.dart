import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'release_intake_probe.dart';

/// Release-only test entrypoint used by the disposable-key CI regression.
/// The production lib/main.dart and plugin set are otherwise unchanged. The
/// shell runner requires this exact result marker plus the Release R8 mapping.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      'stack': stack.toString().substring(0, stack.toString().length < 1500
          ? stack.toString().length
          : 1500),
    };
  }
  // ignore: avoid_print
  print('SCANID_RELEASE_INTAKE_RESULT ${jsonEncode(result)}');
  await Future<void>.delayed(const Duration(seconds: 1));
  exit(result['status'] == 'success' ? 0 : 1);
}
