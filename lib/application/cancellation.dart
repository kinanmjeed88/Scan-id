/// Cooperative cancellation (ADR-009). Batch/persistence work checks tokens
/// at safe boundaries; read-only CPU isolates may be killed immediately via
/// [runCancellableIsolate]. File/database writes are never killed mid-commit.
library;

import 'dart:async';
import 'dart:isolate';

import '../domain/validation.dart';

/// Thrown by [CancellationToken.throwIfCancelled]. Not an error: callers
/// treat it as a clean early stop and report partial results.
class OperationCancelled implements Exception {
  const OperationCancelled();
  @override
  String toString() => 'أُلغيت العملية قبل اكتمالها.';
}

class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  final _listeners = <void Function()>[];

  /// Registers a synchronous cancellation notification. Read-only isolate
  /// workers use this to stop CPU work; persistence never registers a killer.
  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Requests cancellation. Idempotent; checkpoint-only callers still observe
  /// it at their next safe boundary.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const OperationCancelled();
  }
}

/// Runs a read-only computation off the UI isolate and actually kills it on
/// cancellation. Never use for file/database writes: those must finish their
/// atomic staging/commit protocol and discard only the UI continuation.
Future<T> runCancellableIsolate<T>(
  FutureOr<T> Function() computation, {
  CancellationToken? cancellation,
  String? debugName,
}) async {
  cancellation?.throwIfCancelled();
  final results = ReceivePort();
  final exits = ReceivePort();
  final completer = Completer<T>();
  Isolate? worker;
  var done = false;
  var resultReceived = false;

  void finish() {
    if (done) return;
    done = true;
    cancellation?.removeListener(cancel);
    worker?.kill(priority: Isolate.immediate);
    results.close();
    exits.close();
  }

  void cancel() {
    if (!completer.isCompleted) {
      completer.completeError(const OperationCancelled());
    }
    finish();
  }

  cancellation?.addListener(cancel);
  final exitSubscription = exits.listen((_) {
    if (!done && !resultReceived && !completer.isCompleted) {
      completer.completeError(
        const ValidationException('توقفت معالجة الصورة قبل إكمال المعاينة.'),
      );
    }
    finish();
  });
  final subscription = results.listen((Object? message) {
    if (done || completer.isCompleted) return;
    resultReceived = true;
    final result = message as (T?, Object?, StackTrace?);
    if (result.$2 != null) {
      completer.completeError(result.$2!, result.$3);
    } else {
      completer.complete(result.$1 as T);
    }
    finish();
  });
  try {
    worker = await Isolate.spawn<_CancellableIsolateRequest<T>>(
      _runCancellableIsolate<T>,
      _CancellableIsolateRequest(results.sendPort, computation),
      debugName: debugName ?? 'scan-id-read-only',
      onExit: exits.sendPort,
      errorsAreFatal: true,
    );
    if (done) worker!.kill(priority: Isolate.immediate);
    return await completer.future;
  } catch (_) {
    finish();
    rethrow;
  } finally {
    await subscription.cancel();
    await exitSubscription.cancel();
  }
}

class _CancellableIsolateRequest<T> {
  const _CancellableIsolateRequest(this.reply, this.computation);
  final SendPort reply;
  final FutureOr<T> Function() computation;
}

Future<void> _runCancellableIsolate<T>(
  _CancellableIsolateRequest<T> request,
) async {
  try {
    final value = await request.computation();
    request.reply.send((value, null, null));
  } catch (error, stack) {
    request.reply.send((null, error, stack));
  }
}
