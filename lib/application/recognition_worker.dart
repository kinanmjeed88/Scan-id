/// Bounded batch worker for recognition (ADR-009): explicit contracts for
/// input, output, progress, cancellation and failure. Concurrency is
/// bounded, results keep deterministic input order however workers finish,
/// one failed item never affects the others, and cancellation is cooperative
/// (checked before each item; running items complete and their results are
/// kept — persistence is never corrupted).
library;

import 'dart:async';

import 'cancellation.dart';

/// Typed failure categories for recognition work (spec §36). Actionable and
/// safe to log: they never carry document contents.
enum RecognitionErrorCategory {
  invalidInput,
  decodeFailure,
  resourceLimit,
  detectionFailure,
  segmentationFailure,
  geometryFailure,
  perspectiveFailure,
  ocrUnavailable,
  ocrFailure,
  classificationFailure,
  persistenceFailure,
  cancelled,
  missingAsset,
}

/// Progress of a running batch. [completed] counts finished items (success,
/// failure or cancelled-before-start alike).
class BatchProgress {
  const BatchProgress({
    required this.total,
    required this.completed,
    required this.stage,
  });
  final int total;
  final int completed;
  final String stage;
}

class BatchItemFailure {
  const BatchItemFailure({required this.category, required this.message});
  final RecognitionErrorCategory category;
  final String message;
}

/// The outcome of one batch item: exactly one of [value] or [failure].
class BatchOutcome<T> {
  const BatchOutcome.success(this.index, T this.value) : failure = null;
  const BatchOutcome.failed(this.index, BatchItemFailure this.failure)
    : value = null;
  final int index;
  final T? value;
  final BatchItemFailure? failure;
  bool get succeeded => failure == null;
}

/// Default bounded concurrency (ADR-009 initial values; tuned by evidence,
/// not raised speculatively — image analysis holds decoded pixel buffers).
const defaultRecognitionConcurrency = 1;

class RecognitionBatchWorker {
  const RecognitionBatchWorker({
    this.concurrency = defaultRecognitionConcurrency,
  });

  /// Number of items processed simultaneously; always ≥ 1, never unbounded.
  final int concurrency;

  /// Runs [task] over [inputs] with bounded concurrency.
  ///
  /// Results arrive ordered by input index regardless of completion order.
  /// An item whose task throws is recorded as a failed outcome via
  /// [categorize]; a cancel request marks all not-yet-started items as
  /// cancelled and lets running items finish normally.
  Future<List<BatchOutcome<O>>> run<I, O>(
    List<I> inputs,
    Future<O> Function(I input) task, {
    CancellationToken? token,
    void Function(BatchProgress progress)? onProgress,
    BatchItemFailure Function(Object error)? categorize,
    String stage = 'معالجة',
  }) async {
    final outcomes = List<BatchOutcome<O>?>.filled(inputs.length, null);
    var next = 0;
    var completed = 0;

    void report() => onProgress?.call(
      BatchProgress(total: inputs.length, completed: completed, stage: stage),
    );

    BatchItemFailure describe(Object error) {
      if (error is OperationCancelled) {
        return BatchItemFailure(
          category: RecognitionErrorCategory.cancelled,
          message: error.toString(),
        );
      }
      if (categorize != null) return categorize(error);
      return BatchItemFailure(
        category: RecognitionErrorCategory.classificationFailure,
        message: error.toString(),
      );
    }

    Future<void> lane() async {
      while (true) {
        if (next >= inputs.length) return;
        final index = next++;
        if (token != null && token.isCancelled) {
          outcomes[index] = BatchOutcome.failed(
            index,
            const BatchItemFailure(
              category: RecognitionErrorCategory.cancelled,
              message: 'أُلغيت العملية قبل بدء هذا العنصر.',
            ),
          );
          completed++;
          report();
          continue;
        }
        try {
          final value = await task(inputs[index]);
          outcomes[index] = BatchOutcome.success(index, value);
        } catch (error) {
          outcomes[index] = BatchOutcome.failed(index, describe(error));
        }
        completed++;
        report();
      }
    }

    report();
    final lanes = concurrency < 1 ? 1 : concurrency;
    await Future.wait([
      for (var lane0 = 0; lane0 < lanes; lane0++) lane(),
    ]);
    return [for (final outcome in outcomes) outcome!];
  }
}
