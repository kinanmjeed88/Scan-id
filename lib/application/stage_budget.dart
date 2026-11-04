/// Every stage of an import must end with a result, a failure or a cancellation
/// — never with silence.
///
/// The import path crosses boundaries this app does not control: the ONNX
/// Runtime plugin (session creation and inference), the texture/asset channels
/// and OS-backed isolate spawning. A plugin that fails inside its platform
/// thread without replying leaves the Dart `Future` pending forever: no error,
/// no timeout, no log. In the UI that is exactly the reported symptom — the
/// import dialog sits at `0 / 1` forever, because `RecognitionBatchWorker` only
/// reports progress *after* a lane finishes its item.
///
/// [runStageWithin] converts that class of failure into an explicit
/// [StageOutcome]: the caller always continues, and a late completion is still
/// observed so a resource that arrives after we gave up on it can be closed
/// instead of leaked, and a late error never escapes as an unhandled zone error.
///
/// The implementation deliberately uses `Future.timeout` (which cancels its own
/// timer when the stage settles) rather than a hand-rolled timer or a zone
/// race: a pending timer is a test failure in `testWidgets`, and the whole point
/// of this helper is that the surrounding tests stay honest.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'cancellation.dart';

/// How a bounded stage ended.
enum StageOutcomeKind { completed, timedOut }

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

/// Marks an expired stage without exposing a synthetic domain error.
class _StageExpired implements Exception {
  const _StageExpired();
}

/// Runs [stage] and returns within [budget], whatever the stage does.
///
/// * a stage that finishes in time yields [StageOutcome.completed];
/// * a stage that throws yields [StageOutcome.completed] with `error` set (the
///   caller decides how to react — this helper never turns a failure into a
///   success value);
/// * a stage that outlives [budget] yields [StageOutcome.timedOut] and the
///   caller continues; the abandoned work is still observed, and its value is
///   handed to [onLateValue] so an acquired native resource can be released.
///
/// [name] must be a fixed stage identifier, never document content.
Future<StageOutcome<T>> runStageWithin<T>(
  Future<T> Function() stage, {
  required Duration budget,
  required String name,
  CancellationToken? cancellation,
  void Function(T value)? onLateValue,
  void Function(Object error, StackTrace stackTrace)? onLateError,
}) async {
  cancellation?.throwIfCancelled();
  Future<T> started;
  try {
    started = stage();
  } catch (error, stackTrace) {
    return StageOutcome<T>.failed(error, stackTrace);
  }

  var expired = false;
  // The abandoned stage stays observed: an error that arrives after the budget
  // must not surface as an unhandled asynchronous error, and a value that
  // arrives after the budget is a resource its owner wants to release.
  unawaited(
    started.then<void>(
      (value) {
        if (!expired) return;
        developer.log(
          'stage completed after its budget name=$name',
          name: 'scan_id.stage',
        );
        onLateValue?.call(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!expired) return;
        developer.log(
          'stage failed after its budget name=$name error=${error.runtimeType}',
          name: 'scan_id.stage',
        );
        onLateError?.call(error, stackTrace);
      },
    ),
  );

  try {
    final value = await started.timeout(
      budget,
      onTimeout: () => throw const _StageExpired(),
    );
    return StageOutcome<T>.completed(value);
  } on _StageExpired {
    expired = true;
    developer.log(
      'stage expired name=$name budgetMs=${budget.inMilliseconds}',
      name: 'scan_id.stage',
    );
    return const StageOutcome.timedOut();
  } catch (error, stackTrace) {
    return StageOutcome<T>.failed(error, stackTrace);
  }
}

/// Convenience for stages that must behave exactly as before when they finish
/// in time: returns the value, rethrows the stage's own error, and throws
/// [StageTimeout] when the budget expired.
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
  if (outcome.didTimeOut) throw StageTimeout(name, budget);
  final error = outcome.error;
  if (error != null) Error.throwWithStackTrace(error, outcome.stackTrace!);
  return outcome.value as T;
}
