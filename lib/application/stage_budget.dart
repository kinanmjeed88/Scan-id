/// Every stage of an import must end with a result, a failure or a cancellation
/// — never with silence.
///
/// The import path crosses three boundaries this app does not control: the
/// ONNX Runtime plugin (session creation and inference), the texture/asset
/// channels, and OS-backed isolate spawning. A plugin that fails inside its
/// platform thread without replying leaves the Dart `Future` pending forever:
/// no error, no timeout, no log. In the UI that is exactly the reported
/// symptom — the import dialog sits at `0 / 1` and the batch never advances,
/// because `RecognitionBatchWorker` only reports progress *after* a lane
/// finishes its item.
///
/// [runStageWithin] converts that class of failure into an explicit
/// [StageOutcome]: the caller always continues, and a late completion is still
/// observed (so a resource that arrives after we gave up on it can be closed
/// instead of leaked, and a late error is never unhandled).
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'cancellation.dart';

/// How a bounded stage ended.
enum StageOutcomeKind { completed, timedOut, cancelled }

/// The guaranteed result of one bounded stage.
class StageOutcome<T> {
  const StageOutcome.completed(this.value)
    : kind = StageOutcomeKind.completed,
      error = null,
      stackTrace = null;

  const StageOutcome.timedOut()
    : kind = StageOutcomeKind.timedOut,
      value = null,
      error = null,
      stackTrace = null;

  const StageOutcome.cancelled()
    : kind = StageOutcomeKind.cancelled,
      value = null,
      error = null,
      stackTrace = null;

  /// Failed stage: the error the stage itself threw.
  const StageOutcome.failed(this.error, this.stackTrace)
    : kind = StageOutcomeKind.completed,
      value = null;

  final StageOutcomeKind kind;
  final T? value;
  final Object? error;
  final StackTrace? stackTrace;

  bool get didComplete => kind == StageOutcomeKind.completed && error == null;
  bool get didTimeOut => kind == StageOutcomeKind.timedOut;
  bool get wasCancelled => kind == StageOutcomeKind.cancelled;
}

/// Thrown by callers that turn an expired budget into a user-visible failure.
class StageTimeout implements Exception {
  const StageTimeout(this.stage, this.budget);

  final String stage;
  final Duration budget;

  @override
  String toString() =>
      'تجاوزت مرحلة «$stage» المهلة الزمنية (${budget.inSeconds} ثانية).';
}

/// Runs [stage] and returns within [budget], whatever the stage does.
///
/// * a stage that finishes in time yields [StageOutcome.completed];
/// * a stage that throws yields [StageOutcome.completed] with `error` set (the
///   caller decides how to react — this helper never swallows a failure into a
///   success value);
/// * a stage that outlives [budget] yields [StageOutcome.timedOut] and the
///   caller continues; the abandoned work is still observed, and its value is
///   handed to [onLateValue] so an acquired native resource can be released;
/// * a cancellation request ends the wait immediately with
///   [StageOutcome.cancelled], so the dialog's cancel button works even while a
///   native call is stuck.
///
/// [name] must be a fixed stage identifier, never document content.
Future<StageOutcome<T>> runStageWithin<T>(
  Future<T> Function() stage, {
  required Duration budget,
  required String name,
  CancellationToken? cancellation,
  void Function(T value)? onLateValue,
  void Function(Object error, StackTrace stackTrace)? onLateError,
}) {
  cancellation?.throwIfCancelled();
  final completer = Completer<StageOutcome<T>>();
  var settled = false;
  Timer? timer;
  void Function()? removeCancelListener;

  void settle(StageOutcome<T> outcome) {
    if (settled) return;
    settled = true;
    timer?.cancel();
    removeCancelListener?.call();
    completer.complete(outcome);
  }

  if (cancellation != null) {
    void onCancel() => settle(const StageOutcome.cancelled());
    cancellation.addListener(onCancel);
    removeCancelListener = () => cancellation.removeListener(onCancel);
  }

  Future<T> started;
  try {
    started = stage();
  } catch (error, stackTrace) {
    settle(StageOutcome<T>.failed(error, stackTrace));
    return completer.future;
  }

  timer = Timer(budget, () {
    developer.log(
      'stage expired name=$name budgetMs=${budget.inMilliseconds}',
      name: 'scan_id.stage',
    );
    settle(const StageOutcome.timedOut());
  });

  started.then<void>(
    (value) {
      if (settled) {
        developer.log(
          'stage completed after its budget name=$name',
          name: 'scan_id.stage',
        );
        onLateValue?.call(value);
        return;
      }
      settle(StageOutcome<T>.completed(value));
    },
    onError: (Object error, StackTrace stackTrace) {
      if (settled) {
        developer.log(
          'stage failed after its budget name=$name error=${error.runtimeType}',
          name: 'scan_id.stage',
        );
        onLateError?.call(error, stackTrace);
        return;
      }
      settle(StageOutcome<T>.failed(error, stackTrace));
    },
  );
  return completer.future;
}

/// Convenience for stages that must behave exactly as before when they finish
/// in time: returns the value, rethrows the stage's own error, throws
/// [StageTimeout] when the budget expired and [OperationCancelled] when the
/// caller cancelled.
Future<T> requireStageWithin<T>(
  Future<T> Function() stage, {
  required Duration budget,
  required String name,
  CancellationToken? cancellation,
  void Function(T value)? onLateValue,
}) async {
  final outcome = await runStageWithin<T>(
    stage,
    budget: budget,
    name: name,
    cancellation: cancellation,
    onLateValue: onLateValue,
  );
  if (outcome.wasCancelled) throw const OperationCancelled();
  if (outcome.didTimeOut) throw StageTimeout(name, budget);
  final error = outcome.error;
  if (error != null) Error.throwWithStackTrace(error, outcome.stackTrace!);
  return outcome.value as T;
}
