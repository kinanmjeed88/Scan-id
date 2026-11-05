import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/retryable_future.dart';

void main() {
  test('shares a pending creation and retries after a failure', () async {
    final cache = RetryableFuture<int>();
    final attempt = Completer<int>();
    var calls = 0;
    Future<int> create() {
      calls++;
      return attempt.future;
    }

    final first = cache.getOrCreate(create);
    final second = cache.getOrCreate(create);
    expect(identical(first, second), isTrue);
    final firstFailure = expectLater(first, throwsStateError);
    final secondFailure = expectLater(second, throwsStateError);
    attempt.completeError(StateError('failed'));
    await firstFailure;
    await secondFailure;
    expect(await cache.getOrCreate(() async => 42), 42);
    expect(calls, 1);
  });

  test('an old detached failure cannot clear the new creation', () async {
    final cache = RetryableFuture<int>();
    final old = Completer<int>();
    final next = Completer<int>();
    final oldFuture = cache.getOrCreate(() => old.future);
    final detached = cache.take();
    expect(identical(detached, oldFuture), isTrue);
    final newFuture = cache.getOrCreate(() => next.future);
    final failure = expectLater(oldFuture, throwsStateError);
    old.completeError(StateError('old'));
    await failure;
    expect(identical(cache.getOrCreate(() async => 99), newFuture), isTrue);
    next.complete(7);
    expect(await newFuture, 7);
    expect(identical(cache.take(), newFuture), isTrue);
  });
}
