import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/recognition_worker.dart';

void main() {
  test('results keep input order whatever the completion order', () async {
    const worker = RecognitionBatchWorker(concurrency: 2);
    final outcomes = await worker.run<int, int>([30, 0, 10], (ms) async {
      await Future<void>.delayed(Duration(milliseconds: ms));
      return ms * 2;
    });
    expect(outcomes.map((o) => o.index), [0, 1, 2]);
    expect(outcomes.map((o) => o.value), [60, 0, 20]);
    expect(outcomes.every((o) => o.succeeded), isTrue);
  });

  test('one failing item never affects the others', () async {
    const worker = RecognitionBatchWorker();
    final outcomes = await worker.run<int, String>(
      [1, 2, 3],
      (n) async {
        if (n == 2) throw StateError('boom');
        return 'ok-$n';
      },
      categorize: (error) => const BatchItemFailure(
        category: RecognitionErrorCategory.decodeFailure,
        message: 'تعذر فك الترميز',
      ),
    );
    expect(outcomes[0].value, 'ok-1');
    expect(outcomes[1].succeeded, isFalse);
    expect(
      outcomes[1].failure!.category,
      RecognitionErrorCategory.decodeFailure,
    );
    expect(outcomes[2].value, 'ok-3');
  });

  test('progress counts every finished item exactly once', () async {
    const worker = RecognitionBatchWorker();
    final seen = <int>[];
    await worker.run<int, int>(
      [1, 2, 3],
      (n) async => n,
      onProgress: (progress) {
        expect(progress.total, 3);
        seen.add(progress.completed);
      },
      stage: 'تحليل',
    );
    expect(seen, [0, 1, 2, 3]);
  });

  test('cancellation marks unstarted items; started items finish', () async {
    final token = CancellationToken();
    const worker = RecognitionBatchWorker();
    final outcomes = await worker.run<int, int>([1, 2, 3], (n) async {
      if (n == 1) token.cancel();
      return n * 10;
    }, token: token);
    expect(outcomes[0].value, 10, reason: 'already running — kept');
    expect(outcomes[1].failure?.category, RecognitionErrorCategory.cancelled);
    expect(outcomes[2].failure?.category, RecognitionErrorCategory.cancelled);
  });

  test(
    'a task throwing OperationCancelled maps to the cancelled category',
    () async {
      const worker = RecognitionBatchWorker();
      final outcomes = await worker.run<int, int>([1], (n) async {
        throw const OperationCancelled();
      });
      expect(
        outcomes.single.failure!.category,
        RecognitionErrorCategory.cancelled,
      );
    },
  );

  test('empty input completes immediately with one progress report', () async {
    const worker = RecognitionBatchWorker();
    final reports = <BatchProgress>[];
    final outcomes = await worker.run<int, int>(
      [],
      (n) async => n,
      onProgress: reports.add,
    );
    expect(outcomes, isEmpty);
    expect(reports, hasLength(1));
    expect(reports.single.completed, 0);
  });

  test('concurrency below one is clamped to a single lane', () async {
    const worker = RecognitionBatchWorker(concurrency: 0);
    var running = 0;
    var peak = 0;
    await worker.run<int, int>([1, 2, 3], (n) async {
      running++;
      peak = peak < running ? running : peak;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      running--;
      return n;
    });
    expect(peak, 1);
  });

  test('cancellation token works through the shared token type', () {
    final token = CancellationToken();
    expect(token.isCancelled, isFalse);
    token.throwIfCancelled();
    token.cancel();
    token.cancel(); // idempotent
    expect(token.isCancelled, isTrue);
    expect(token.throwIfCancelled, throwsA(isA<OperationCancelled>()));
  });
}
