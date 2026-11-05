import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/domain/validation.dart';

void main() {
  test('result and exit do not race across ports', () async {
    for (var i = 0; i < 100; i++) {
      expect(await runCancellableIsolate(() => 42), 42);
    }
  });

  test('unexpected isolate exit reports failure', () async {
    await expectLater(
      runCancellableIsolate<int>(() => Isolate.exit()),
      throwsA(isA<ValidationException>()),
    );
  });

  test('cancellation during spawn or computation is observed', () async {
    final token = CancellationToken();
    final pending = runCancellableIsolate<int>(() async {
      await Future<void>.delayed(const Duration(seconds: 5));
      return 1;
    }, cancellation: token);
    final expectation = expectLater(
      pending,
      throwsA(isA<OperationCancelled>()),
    );
    token.cancel();
    await expectation;
  });
}
