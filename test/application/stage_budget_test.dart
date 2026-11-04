import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/stage_budget.dart';

/// A stage that never answers is the failure mode behind a stuck import dialog:
/// the batch worker only reports progress after a lane finishes, so a native
/// call that never replies leaves the counter at 0 / 1 forever. These tests pin
/// the guarantee that every bounded stage ends.
void main() {
  test('a stage that finishes in time returns its value', () async {
    final outcome = await runStageWithin(
      () async => 42,
      budget: const Duration(seconds: 5),
      name: 'unit-fast',
    );

    expect(outcome.didComplete, isTrue);
    expect(outcome.value, 42);
    expect(outcome.didTimeOut, isFalse);
  });

  test('a stage that never finishes expires instead of hanging', () async {
    final stopwatch = Stopwatch()..start();
    final outcome = await runStageWithin(
      () => Completer<int>().future,
      budget: const Duration(milliseconds: 40),
      name: 'unit-stalled',
    );
    stopwatch.stop();

    expect(outcome.didTimeOut, isTrue);
    expect(outcome.value, isNull);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('a failing stage returns its error instead of a value', () async {
    final outcome = await runStageWithin(
      () async => throw StateError('native session failed'),
      budget: const Duration(seconds: 5),
      name: 'unit-failure',
    );

    expect(outcome.didComplete, isFalse);
    expect(outcome.error, isA<StateError>());
    expect(outcome.value, isNull);
  });

  test('a cancelled token stops the stage from starting at all', () async {
    final token = CancellationToken()..cancel();
    var started = false;

    await expectLater(
      runStageWithin(
        () async {
          started = true;
          return 1;
        },
        budget: const Duration(seconds: 5),
        name: 'unit-cancelled-before',
        cancellation: token,
      ),
      throwsA(isA<OperationCancelled>()),
    );
    expect(started, isFalse, reason: 'no work starts after a cancel request');
  });

  test('a late value is released instead of leaked', () async {
    final late = Completer<String>();
    String? released;

    final outcome = await runStageWithin(
      () => late.future,
      budget: const Duration(milliseconds: 20),
      name: 'unit-late',
      onLateValue: (value) => released = value,
    );
    expect(outcome.didTimeOut, isTrue);

    late.complete('native session');

    // Let the abandonment callback run.
    await Future<void>.delayed(Duration.zero);
    expect(released, 'native session');
  });

  test('a late error is observed rather than thrown at the zone', () async {
    final late = Completer<int>();
    Object? observed;

    final outcome = await runStageWithin(
      () => late.future,
      budget: const Duration(milliseconds: 20),
      name: 'unit-late-error',
      onLateError: (error, _) => observed = error,
    );
    expect(outcome.didTimeOut, isTrue);

    late.completeError(StateError('late failure'));
    await Future<void>.delayed(Duration.zero);

    expect(observed, isA<StateError>());
  });

  test('a late release that throws is contained, not unhandled', () async {
    // The release runs after the caller moved on, so an exception there has no
    // caller to catch it. flutter_test fails a test on an unhandled async error,
    // so reaching the end of this test proves containment.
    final late = Completer<int>();

    final outcome = await runStageWithin(
      () => late.future,
      budget: const Duration(milliseconds: 20),
      name: 'unit-late-throw',
      onLateValue: (_) => throw StateError('release failed'),
    );
    expect(outcome.didTimeOut, isTrue);

    late.complete(7);
    await Future<void>.delayed(const Duration(milliseconds: 40));
  });

  test('a typed timeout is thrown for the caller', () async {
    await expectLater(
      requireStageWithin(
        () => Completer<int>().future,
        budget: const Duration(milliseconds: 20),
        name: 'unit-required',
      ),
      throwsA(
        isA<StageTimeout>().having(
          (error) => error.stage,
          'stage',
          'unit-required',
        ),
      ),
    );
  });

  test('requireStageWithin rethrows the stage error unchanged', () async {
    await expectLater(
      requireStageWithin(
        () async => throw StateError('decode failed'),
        budget: const Duration(seconds: 5),
        name: 'unit-rethrow',
      ),
      throwsA(isA<StateError>()),
    );
  });
}
