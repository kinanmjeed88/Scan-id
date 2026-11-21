import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/processing_ledger.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/intake_options.dart';
import 'package:scan_id/domain/processing_record.dart';
import 'package:scan_id/domain/recognition.dart' show SideKind;

class _Clock {
  _Clock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(int milliseconds) {
    now = now.add(Duration(milliseconds: milliseconds));
  }
}

class _Sink implements ProcessingJournalSink {
  final List<Map<String, Object?>> events = [];

  @override
  void add(Map<String, Object?> event) => events.add(event);
}

ProcessingLedger _ledger({
  String batch = 'batch-1',
  String projectName = 'مشروع الاختبار',
  _Clock? clock,
  ProcessingJournalSink? sink,
  IntakeOptions? options,
}) => ProcessingLedger(
  operationId: batch,
  projectId: 'project-1',
  projectName: projectName,
  options: options,
  sink: sink,
  clock: clock?.call,
);

StageEvidence _ok({int items = 1}) => StageEvidence(
  verified: true,
  checks: [EvidenceCheck(name: 'measured', passed: true)],
  counts: {'items': items},
);

DocumentProcessingLog _succeedDocument(
  ProcessingLedger ledger, {
  required String imageId,
  required String documentId,
  int index = 1,
}) {
  final document = ledger.document(
    imageId,
    index: index,
    documentId: documentId,
    kind: DocumentKind.unifiedNationalId,
    side: SideKind.front,
    kindSource: RecordSource.user,
    sideSource: RecordSource.user,
  );
  ledger.documentSucceeded(
    imageId,
    document.id,
    ProcessingStage.crop,
    reason: 'أُنتجت صورة مقصوصة غير فارغة.',
    evidence: _ok(),
  );
  ledger.documentSucceeded(
    imageId,
    document.id,
    ProcessingStage.typeSideSize,
    reason: 'ثُبت النوع والوجه والمقاس.',
    evidence: _ok(),
  );
  ledger.documentSucceeded(
    imageId,
    document.id,
    ProcessingStage.saveDocument,
    reason: 'حُفظ المستند.',
    evidence: _ok(),
  );
  ledger.documentSucceeded(
    imageId,
    document.id,
    ProcessingStage.addToProject,
    reason: 'أُضيف إلى الورقة.',
    evidence: _ok(),
  );
  ledger.documentSucceeded(
    imageId,
    document.id,
    ProcessingStage.verifyAddition,
    reason: 'تُحققت الإضافة بالقراءة.',
    evidence: _ok(),
  );
  return document;
}

void main() {
  group('run verifies the result, not the call', () {
    test('a measured stage is recorded as success with its duration', () async {
      final clock = _Clock(DateTime.utc(2026, 1, 1, 10));
      final ledger = _ledger(clock: clock);
      ledger.image('img', name: 'one.jpg', width: 400, height: 600);

      final value = await ledger.run(
        'img',
        ProcessingStage.decode,
        () async {
          clock.advance(37);
          return 400 * 600;
        },
        verify: (pixels) => pixels > 0,
        successReason: 'فُك الترميز وأُنتجت بكسلات صالحة.',
        results: (pixels) => {'pixels': pixels},
        items: (_) => 1,
        checks: (_) => [
          EvidenceCheck(name: 'pixels_positive', passed: true),
        ],
      );

      final stage = ledger.report.images.single.stageOf(ProcessingStage.decode)!;
      expect(value, 240000);
      expect(stage.status, StageStatus.succeeded);
      expect(stage.durationMs, 37);
      expect(stage.evidence!.verified, isTrue);
      expect(stage.results['pixels'], 240000);
      expect(stage.itemCount, 1);
      expect(stage.attempt, 1);
    });

    test('unmeasured stages do not claim a zero-millisecond duration', () {
      final ledger = _ledger();
      final stage = ledger.succeeded(
        'img',
        ProcessingStage.detection,
        reason: 'قِيست نتيجة الكشف.',
        evidence: _ok(),
      );

      expect(stage.startedAt, isNull);
      expect(stage.endedAt, isNotNull);
      expect(stage.durationMs, isNull);
    });

    test('a positive predicate without measured evidence is not success', () async {
      final ledger = _ledger();
      ledger.image('img');

      final value = await ledger.run<int>(
        'img',
        ProcessingStage.decode,
        () async => 1,
        verify: (pixels) => pixels > 0,
        successReason: 'فُك الترميز.',
      );

      expect(value, 1);
      final stage = ledger.report.images.single.stageOf(ProcessingStage.decode)!;
      expect(stage.status, StageStatus.failed);
      expect(stage.errorCode, FailureCode.resultUnverified);
      expect(stage.diagnostics, contains('evidence_measurement_missing'));
      expect(stage.evidence!.verified, isFalse);
    });

    test('contradictory checks are downgraded instead of breaking the task', () {
      final ledger = _ledger();
      final record = ledger.succeeded(
        'img',
        ProcessingStage.dimensions,
        reason: 'قِيست الأبعاد.',
        evidence: StageEvidence(
          verified: true,
          checks: [EvidenceCheck(name: 'dimensions_positive', passed: false)],
        ),
      );

      expect(record.status, StageStatus.failed);
      expect(record.errorCode, FailureCode.resultUnverified);
      expect(record.evidence!.verified, isFalse);
    });

    test('a call that returned but failed verification is a failure', () async {
      final clock = _Clock(DateTime.utc(2026, 1, 1, 10));
      final ledger = _ledger(clock: clock);
      ledger.image('img');

      final value = await ledger.run(
        'img',
        ProcessingStage.decode,
        () async => 0,
        verify: (pixels) => pixels > 0,
        successReason: 'فُك الترميز.',
      );

      final stage = ledger.report.images.single.stageOf(ProcessingStage.decode)!;
      expect(value, 0);
      expect(stage.status, StageStatus.failed);
      expect(stage.errorCode, FailureCode.resultUnverified);
      expect(stage.status, isNot(StageStatus.succeeded));
      expect(stage.evidence!.verified, isFalse);
    });

    test('an exception is recorded with its type and rethrown', () async {
      final clock = _Clock(DateTime.utc(2026, 1, 1, 10));
      final ledger = _ledger(clock: clock);
      ledger.image('img');

      await expectLater(
        ledger.run<int>(
          'img',
          ProcessingStage.decode,
          () async {
            clock.advance(11);
            throw const FormatException('bad header');
          },
          verify: (value) => value > 0,
          successReason: 'فُك الترميز.',
          failureAction: 'أُوقفت السلسلة؛ لم تُنتج صورة.',
        ),
        throwsA(isA<FormatException>()),
      );

      final image = ledger.report.images.single;
      final stage = image.stageOf(ProcessingStage.decode)!;
      expect(stage.status, StageStatus.failed);
      expect(stage.errorType, 'FormatException');
      expect(stage.durationMs, 11);
      expect(stage.actionTaken, contains('أُوقفت'));
      expect(stage.diagnostics, isNotEmpty);
      expect(image.stageOf(ProcessingStage.crop), isNull);
    });

    test('OperationCancelled records a cancelled stage, not a failure', () async {
      final ledger = _ledger();
      ledger.image('img');

      await expectLater(
        ledger.run<int>(
          'img',
          ProcessingStage.analysis,
          () async => throw const OperationCancelled(),
          verify: (value) => value > 0,
          successReason: 'اكتمل التحليل.',
        ),
        throwsA(isA<OperationCancelled>()),
      );

      final stage = ledger.report.images.single.stageOf(ProcessingStage.analysis)!;
      expect(stage.status, StageStatus.cancelled);
      expect(stage.errorCode, FailureCode.cancelled);
      expect(stage.diagnostics, contains('operation_cancelled'));
    });

    test('runSync verifies the same way', () {
      final ledger = _ledger();
      ledger.image('img');
      final accepted = ledger.runSync(
        'img',
        ProcessingStage.geometryCheck,
        () => 4,
        verify: (corners) => corners == 4,
        successReason: 'أربع زوايا صالحة.',
        items: (corners) => corners,
        checks: (_) => [EvidenceCheck(name: 'four_corners', passed: true)],
      );
      expect(accepted, 4);
      expect(
        ledger.report.images.single
            .stageOf(ProcessingStage.geometryCheck)!
            .status,
        StageStatus.succeeded,
      );
    });

    test('runDocument keeps one verified attempt and rethrows failures', () async {
      final ledger = _ledger();
      ledger.image('img');
      final document = ledger.document('img', documentId: 'doc-1');
      final result = await ledger.runDocument<int>(
        'img',
        document.id,
        ProcessingStage.crop,
        () async => 4,
        verify: (bytes) => bytes > 0,
        successReason: 'أُنتجت بايتات قص غير فارغة.',
        checks: (bytes) => [
          EvidenceCheck(name: 'bytes_not_empty', passed: bytes > 0),
        ],
        results: (bytes) => {'bytes': bytes},
      );
      expect(result, 4);
      expect(document.stageOf(ProcessingStage.crop)!.attempt, 1);
      expect(document.stageOf(ProcessingStage.crop)!.status, StageStatus.succeeded);

      await expectLater(
        ledger.runDocument<int>(
          'img',
          document.id,
          ProcessingStage.perspective,
          () async => throw const FormatException('bad output'),
          verify: (value) => value > 0,
          successReason: 'صُحح المنظور.',
          failureAction: 'لم يُحفظ المستند.',
        ),
        throwsA(isA<FormatException>()),
      );
      final failed = document.stageOf(ProcessingStage.perspective)!;
      expect(failed.status, StageStatus.failed);
      expect(failed.errorType, 'FormatException');
      expect(failed.errorCode, FailureCode.unknown);
    });

    test('runDocument preserves cancellation status', () async {
      final ledger = _ledger();
      ledger.image('img');
      final document = ledger.document('img', documentId: 'doc-cancel');

      await expectLater(
        ledger.runDocument<int>(
          'img',
          document.id,
          ProcessingStage.crop,
          () async => throw const OperationCancelled(),
          verify: (value) => value > 0,
          successReason: 'أُنتجت صورة المستند.',
        ),
        throwsA(isA<OperationCancelled>()),
      );

      final stage = document.stageOf(ProcessingStage.crop)!;
      expect(stage.status, StageStatus.cancelled);
      expect(stage.errorCode, FailureCode.cancelled);
    });

    test('run retries replace a stage instead of duplicating it', () async {
      final ledger = _ledger();
      ledger.image('img');
      Future<int> action(int value) async => value;
      for (final value in [1, 2]) {
        await ledger.run<int>(
          'img',
          ProcessingStage.decode,
          () => action(value),
          verify: (result) => result > 0,
          successReason: 'فُك الترميز.',
          checks: (result) => [
            EvidenceCheck(name: 'pixels_measured', passed: result > 0),
          ],
        );
      }
      final rows = ledger.report.images.single.stages
          .where((stage) => stage.stage == ProcessingStage.decode)
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.attempt, 2);
      expect(rows.single.status, StageStatus.succeeded);
      expect(rows.single.results, isEmpty);
    });
  });

  group('statuses stay distinct and keep their real reason', () {
    test('bypass and non-applicable are not success', () {
      final ledger = _ledger();
      ledger.image('img');
      ledger.succeeded(
        'img',
        ProcessingStage.analysis,
        reason: 'حُلّلت الصورة.',
        evidence: _ok(),
      );
      ledger.overridden(
        'img',
        ProcessingStage.preprocessing,
        reason: 'حدّد المستخدم النوع يدوياً، فلا حاجة لقراءة النص.',
      );
      ledger.notApplicable(
        'img',
        ProcessingStage.confidence,
        reason: 'لا يوفر هذا المسار درجة ثقة.',
      );
      final image = ledger.report.images.single;
      expect(
        image.stageOf(ProcessingStage.preprocessing)!.status,
        StageStatus.overridden,
      );
      expect(
        image.stageOf(ProcessingStage.preprocessing)!.reason,
        contains('حدّد المستخدم'),
      );
      expect(
        image.stageOf(ProcessingStage.confidence)!.status,
        StageStatus.notApplicable,
      );
      expect(image.stageOf(ProcessingStage.analysis)!.status, StageStatus.succeeded);
      expect(image.filledStages().every((stage) => stage.status != StageStatus.succeeded || stage.evidence != null), isTrue);
    });

    test('recording the same stage twice replaces it and counts attempts', () {
      final ledger = _ledger();
      ledger.image('img');
      ledger.succeeded(
        'img',
        ProcessingStage.decode,
        reason: 'المحاولة الأولى.',
        evidence: _ok(),
      );
      ledger.failed(
        'img',
        ProcessingStage.decode,
        reason: 'المحاولة الثانية تعذرت.',
        errorType: 'FormatException',
      );
      final image = ledger.report.images.single;
      final rows = image.stages
          .where((stage) => stage.stage == ProcessingStage.decode)
          .toList();
      expect(rows.length, 1);
      expect(rows.single.status, StageStatus.failed);
      expect(rows.single.attempt, 2);
    });
  });

  group('finalisation never invents a result', () {
    test('unreached stages are stopped and named after the blocking stage', () {
      final clock = _Clock(DateTime.utc(2026, 1, 1, 10));
      final ledger = _ledger(clock: clock);
      ledger.image('img');
      ledger.succeeded(
        'img',
        ProcessingStage.selection,
        reason: 'استُلمت الصورة.',
        evidence: _ok(),
      );
      ledger.failed(
        'img',
        ProcessingStage.decode,
        reason: 'تعذر فك الترميز.',
        errorType: 'FormatException',
      );

      final report = ledger.finalize();
      final image = report.images.single;
      expect(image.stageOf(ProcessingStage.completion)!.status, StageStatus.succeeded);
      expect(image.stageOf(ProcessingStage.dimensions)!.status, StageStatus.stopped);
      expect(image.stageOf(ProcessingStage.dimensions)!.reason, contains('فك الترميز'));
      expect(image.outcome, ImageOutcome.failed);
      expect(report.verdict, ProcessingVerdict.failed);
      expect(report.headline, isNotEmpty);
      expect(report.finalised, isTrue);
    });

    test('cancellation is cancelled, not success', () {
      final clock = _Clock(DateTime.utc(2026, 1, 1, 10));
      final ledger = _ledger(clock: clock);
      ledger.image('img');
      ledger.succeeded(
        'img',
        ProcessingStage.selection,
        reason: 'استُلمت الصورة.',
        evidence: _ok(),
      );

      final report = ledger.finalize(cancelled: true);
      final completion = report.images.single.stageOf(ProcessingStage.completion)!;
      expect(completion.status, StageStatus.cancelled);
      expect(completion.evidence, isNull);
      expect(report.verdict, ProcessingVerdict.cancelled);
      expect(report.images.single.outcome, ImageOutcome.cancelled);
    });

    test('a batch stop is reported as stopped', () {
      final ledger = _ledger();
      ledger.image('img');
      ledger.failed(
        'img',
        ProcessingStage.analysis,
        reason: 'فشل التحليل.',
        errorType: 'StateError',
      );
      final stop = StageRecord(
        stage: ProcessingStage.analysis,
        status: StageStatus.failed,
        reason: 'فشل التحليل.',
        errorType: 'StateError',
      );
      final report = ledger.finalize(batchStop: stop);
      expect(
        report.images.single.stageOf(ProcessingStage.completion)!.status,
        StageStatus.stopped,
      );
      expect(report.images.single.outcome, ImageOutcome.stopped);
      expect(report.verdict, ProcessingVerdict.stopped);
    });

    test('failBatch records a shared, named stop', () {
      final ledger = _ledger();
      ledger.image('img-1');
      ledger.image('img-2');
      final failure = ledger.failBatch(
        ProcessingStage.importCopy,
        'تعذر حفظ نسخة المشروع الحالية.',
        errorCode: FailureCode.storage,
      );
      expect(failure.status, StageStatus.failed);
      expect(failure.errorCode, FailureCode.storage);
      expect(ledger.report.images, hasLength(2));
      expect(
        ledger.report.images.every(
          (image) =>
              image.stageOf(ProcessingStage.importCopy)?.errorType ==
              'BatchFailure',
        ),
        isTrue,
      );
      final report = ledger.finalize(batchStop: failure);
      expect(report.images.every((image) => image.outcome == ImageOutcome.stopped), isTrue);
      expect(report.verdict, ProcessingVerdict.stopped);
    });

    test('an unconfirmed type or size stays under review, not complete', () {
      final ledger = _ledger();
      ledger.image('img');
      final document = ledger.document('img', documentId: 'doc-provisional');
      ledger.documentSucceeded(
        'img',
        document.id,
        ProcessingStage.crop,
        reason: 'أُنتجت صورة مقصوصة.',
        evidence: _ok(),
      );
      ledger.documentStopped(
        'img',
        document.id,
        ProcessingStage.typeSideSize,
        reason: 'المقاس مبدئي وغير مؤكد.',
      );
      ledger.documentSucceeded(
        'img',
        document.id,
        ProcessingStage.saveDocument,
        reason: 'حُفظت الصورة مؤقتاً.',
        evidence: _ok(),
      );
      ledger.documentSucceeded(
        'img',
        document.id,
        ProcessingStage.addToProject,
        reason: 'أُضيف العنصر للمراجعة.',
        evidence: _ok(),
      );
      ledger.documentSucceeded(
        'img',
        document.id,
        ProcessingStage.verifyAddition,
        reason: 'قُرئت الإضافة من المشروع.',
        evidence: _ok(),
      );

      final report = ledger.finalize();
      expect(document.succeeded, isFalse);
      expect(document.needsAttention, isTrue);
      expect(report.documentsSaved, 1);
      expect(report.documentsAdded, 1);
      expect(report.images.single.outcome, ImageOutcome.completedWithReview);
      expect(report.verdict, ProcessingVerdict.completedWithReview);
    });

    test('partial success splits saved documents from the failed one', () {
      final ledger = _ledger();
      ledger.image('img');
      ledger.succeeded('img', ProcessingStage.selection, reason: 'استُلمت.', evidence: _ok());
      ledger.succeeded('img', ProcessingStage.analysis, reason: 'حُلّلت.', evidence: _ok());
      for (var index = 1; index <= 3; index++) {
        _succeedDocument(ledger, imageId: 'img', documentId: 'doc-$index', index: index);
      }
      final failed = ledger.document(
        'img',
        index: 4,
        documentId: 'doc-4',
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.back,
        kindSource: RecordSource.user,
        sideSource: RecordSource.user,
      );
      ledger.documentFailed(
        'img',
        failed.id,
        ProcessingStage.crop,
        errorType: 'InvalidCropOutput',
        reason: 'أعاد القص صورة فارغة.',
        diagnostics: const ['bytes_empty'],
      );

      final report = ledger.finalize();
      expect(report.documentsMeasured, 4);
      expect(report.documentsSaved, 3);
      expect(report.documentsAdded, 3);
      expect(report.documentsFailed, 1);
      expect(report.verdict, ProcessingVerdict.partial);
      expect(report.images.single.outcome, ImageOutcome.partial);
      expect(
        report.images.single.documents.map((d) => d.imageId).toSet(),
        {'img'},
      );
      expect(failed.stageOf(ProcessingStage.crop)!.diagnostics, ['bytes_empty']);
    });
  });

  group('journal and recovery', () {
    test('events carry increasing sequence numbers and the chosen options', () async {
      const options = IntakeOptions(
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.front,
        multiDocument: true,
        centerDocuments: false,
        acceptSuggestedBoundary: true,
        confirmed: {IntakeOptionKey.kind, IntakeOptionKey.side},
      );
      final sink = _Sink();
      final ledger = _ledger(batch: 'batch-events', sink: sink, options: options);
      ledger.image('img', name: 'one.jpg');
      ledger.succeeded('img', ProcessingStage.selection, reason: 'استُلمت.', evidence: _ok());
      ledger.warn('img', 'صورة صغيرة.');
      final report = ledger.finalize();

      expect(sink.events.first['event'], 'batch');
      expect(sink.events.last['event'], 'report');
      final sequences = [
        for (final event in sink.events) event['seq']! as int,
      ];
      expect(sequences, orderedEquals([...sequences]..sort()));
      expect(report.options!.multiDocument, isTrue);
      expect(report.options!.centerDocuments, isFalse);
      expect(report.optionCodes, contains('center=false'));
      expect(report.route, IntakeRoute.manualSelections);
      expect(report.warnings, contains('صورة صغيرة.'));
    });

    test('rekey preserves early import stages and recovers one real image id', () {
      final sink = _Sink();
      final ledger = _ledger(batch: 'batch-rekey', sink: sink);
      ledger.image('source-1', name: 'one.jpg');
      ledger.succeeded(
        'source-1',
        ProcessingStage.selection,
        reason: 'استُلم المصدر.',
        evidence: _ok(),
      );
      ledger.succeeded(
        'source-1',
        ProcessingStage.fileValidation,
        reason: 'اجتاز التحقق الأولي.',
        evidence: _ok(),
      );
      ledger.rekeyImage('source-1', 'asset-1', width: 320, height: 480);
      ledger.succeeded(
        'asset-1',
        ProcessingStage.decode,
        reason: 'فُك ترميز الصورة.',
        evidence: _ok(),
      );
      final report = ledger.finalize();
      expect(report.images, hasLength(1));
      expect(report.images.single.imageId, 'asset-1');
      expect(report.images.single.sourceWidth, 320);
      expect(report.images.single.sourceHeight, 480);
      expect(
        report.images.single.stageOf(ProcessingStage.selection)!.status,
        StageStatus.succeeded,
      );
      final recovered = ProcessingLedger.tryRecover('batch-rekey', sink.events);
      expect(recovered, isNotNull);
      expect(recovered!.images, hasLength(1));
      expect(recovered.images.single.imageId, 'asset-1');
      expect(recovered.images.single.sourceWidth, 320);
      expect(
        recovered.images.single.stageOf(ProcessingStage.fileValidation)!.status,
        StageStatus.succeeded,
      );
    });

    test('late image-name enrichment survives event replay', () {
      final sink = _Sink();
      final ledger = _ledger(batch: 'batch-late-name', sink: sink);
      ledger.image('img');
      ledger.image('img', name: r'C:\private\one.jpg');

      final recovered = ProcessingLedger.tryRecover('batch-late-name', sink.events);
      expect(recovered, isNotNull);
      expect(recovered!.images.single.imageName, 'one.jpg');
    });

    test('a durable batch stop recovers as terminal without replacing completed stages', () {
      final sink = _Sink();
      final ledger = _ledger(batch: 'batch-stop-recovery', sink: sink);
      ledger.image('img', name: 'one.jpg');
      final document = ledger.document('img', documentId: 'doc-1');
      final waitingDocument = ledger.document('img', documentId: 'doc-2');
      ledger.documentSucceeded(
        'img',
        document.id,
        ProcessingStage.addToProject,
        reason: 'أُضيف المستند إلى المشروع.',
        evidence: _ok(),
      );
      final stop = ledger.failBatch(
        ProcessingStage.addToProject,
        'تعذّر إكمال ترتيب الدفعة.',
        errorCode: FailureCode.storage,
      );
      expect(
        document.stageOf(ProcessingStage.addToProject)!.status,
        StageStatus.succeeded,
      );
      expect(
        waitingDocument.stageOf(ProcessingStage.addToProject)!.status,
        StageStatus.failed,
      );

      // Replay before the final summary event: the explicit stop event is
      // sufficient to identify a terminal, stopped batch.
      final recovered = ProcessingLedger.tryRecover(
        'batch-stop-recovery',
        sink.events,
      );
      expect(recovered, isNotNull);
      expect(recovered!.recovered, isTrue);
      expect(recovered.finalised, isTrue);
      expect(recovered.verdict, ProcessingVerdict.stopped);
      expect(recovered.images.single.outcome, ImageOutcome.stopped);
      expect(
        recovered.images.single.documents.first
            .stageOf(ProcessingStage.addToProject)!
            .status,
        StageStatus.succeeded,
      );
      expect(
        recovered.images.single.documents.last
            .stageOf(ProcessingStage.addToProject)!
            .status,
        StageStatus.failed,
      );
      expect(recovered.warnings, contains(stop.reason));
    });

    test('an interrupted operation is recovered as interrupted, with its stages', () {
      final sink = _Sink();
      final ledger = _ledger(batch: 'batch-crash', sink: sink);
      ledger.image('img', name: 'one.jpg');
      ledger.succeeded('img', ProcessingStage.selection, reason: 'استُلمت.', evidence: _ok());
      ledger.succeeded('img', ProcessingStage.fileValidation, reason: 'صيغة مدعومة.', evidence: _ok());

      final recovered = ProcessingLedger.tryRecover('batch-crash', sink.events);
      expect(recovered, isNotNull);
      expect(recovered!.recovered, isTrue);
      expect(recovered.finalised, isFalse);
      expect(recovered.verdict, ProcessingVerdict.interrupted);
      expect(recovered.images.single.outcome, ImageOutcome.interrupted);
      expect(
        recovered.images.single.stageOf(ProcessingStage.fileValidation)!.status,
        StageStatus.succeeded,
      );
      expect(
        recovered.images.single.stageOf(ProcessingStage.dimensions),
        isNull,
      );
      expect(
        recovered.images.single
            .filledStages()
            .firstWhere((stage) => stage.stage == ProcessingStage.dimensions)
            .status,
        StageStatus.notReached,
      );
    });

    test('a filed report survives replay with its verdict and options', () {
      const options = IntakeOptions(
        kind: DocumentKind.unifiedNationalId,
        centerDocuments: false,
        confirmed: {IntakeOptionKey.kind},
      );
      final sink = _Sink();
      final ledger = _ledger(batch: 'batch-filed', sink: sink, options: options);
      ledger.image('img', name: 'one.jpg');
      ledger.succeeded('img', ProcessingStage.selection, reason: 'استُلمت.', evidence: _ok());
      ledger.finalize(cancelled: true);

      final recovered = ProcessingLedger.tryRecover('batch-filed', sink.events);
      expect(recovered, isNotNull);
      expect(recovered!.finalised, isTrue);
      expect(recovered.recovered, isFalse);
      expect(recovered.verdict, ProcessingVerdict.cancelled);
      expect(recovered.options!.kind, DocumentKind.unifiedNationalId);
      expect(recovered.images.single.imageName, 'one.jpg');
    });

    test('a document is linked to its source image and its created ids', () {
      final ledger = _ledger();
      ledger.image('img');
      final document = ledger.document(
        'img',
        documentId: 'doc-1',
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.front,
        kindSource: RecordSource.auto,
        sideSource: RecordSource.auto,
      );
      ledger.linkDocument(
        'img',
        document.id,
        recordId: 'record-1',
        itemId: 'item-1',
        assetId: 'asset-1',
        outcome: 'حُفظ المستند وأُضيف إلى الورقة وتحققت إضافته.',
      );
      final restored = ledger.report.images.single.documents.single;
      expect(restored.imageId, 'img');
      expect(restored.documentRecordId, 'record-1');
      expect(restored.layoutItemId, 'item-1');
      expect(restored.derivedAssetId, 'asset-1');
      expect(restored.outcome, contains('تحققت إضافته'));
    });
  });

  group('centring settlement', () {
    test('an enabled, placed document is only then successful', () {
      final ledger = _ledger();
      ledger.image('img');
      final document = ledger.document('img', documentId: 'doc-1');
      ledger.documentStopped(
        'img',
        document.id,
        ProcessingStage.centering,
        reason: 'ينتظر الترتيب.',
        actionTaken: 'يُحسم بعد حفظ المشروع.',
      );
      ledger.linkDocument('img', document.id, itemId: 'item-1');

      ledger.settleCentering(centerEnabled: true, placed: (id) => id == 'item-1');
      final centering = ledger.report.images.single.documents.single
          .stageOf(ProcessingStage.centering)!;
      expect(centering.status, StageStatus.succeeded);
      expect(centering.evidence!.checks.map((check) => check.name), contains('item_placed'));
    });

    test('a disabled option is a bypass, not a success', () {
      final ledger = _ledger();
      ledger.image('img');
      final disabled = ledger.document('img', documentId: 'doc-disabled');
      ledger.documentStopped(
        'img',
        disabled.id,
        ProcessingStage.centering,
        reason: 'ينتظر الترتيب.',
      );
      ledger.settleCentering(centerEnabled: false, placed: (_) => false);
      final disabledCentering = ledger.report.images.single.documents.single
          .stageOf(ProcessingStage.centering)!;
      expect(disabledCentering.status, StageStatus.overridden);
      expect(disabledCentering.reason, contains('عطّل المستخدم'));
    });

    test('an enabled but unplaced document stays stopped', () {
      final ledger = _ledger();
      ledger.image('img');
      final unplaced = ledger.document('img', documentId: 'doc-unplaced');
      ledger.documentStopped(
        'img',
        unplaced.id,
        ProcessingStage.centering,
        reason: 'ينتظر الترتيب.',
      );
      ledger.linkDocument('img', unplaced.id, itemId: 'item-2');
      ledger.settleCentering(centerEnabled: true, placed: (_) => false);
      final centering = ledger.report.images.single.documents.single
          .stageOf(ProcessingStage.centering)!;
      expect(centering.status, StageStatus.stopped);
      expect(centering.diagnostics, ['item_not_placed']);
    });
  });

  group('privacy and boundedness', () {
    test('an exception path is never copied into the record', () {
      expect(describeFailure(StateError('/home/user/secret/scan.jpg')), 'StateError');
      expect(describeFailure(null), 'سبب غير محدد');
      expect(FailureCode.of(StateError('x')), FailureCode.unknown);
    });

    test('project names are sanitized before journal events are queued', () {
      final sink = _Sink();
      final ledger = _ledger(
        batch: 'batch-project-name-privacy',
        sink: sink,
        projectName: r'Project C:\private\scan',
      );

      expect(ledger.projectName, isNot(contains('private')));
      expect(sink.events.first['project_name'], ledger.projectName);
      expect(sink.events.first['project_name'], isNot(contains('private')));
    });

    test('warning events and stored reports redact paths and deduplicate', () {
      final sink = _Sink();
      final ledger = _ledger(batch: 'batch-warning-privacy', sink: sink);
      const message = r'Could not read C:\private\scan.jpg';
      ledger.warn('img', message);
      ledger.warn('img', message);
      final report = ledger.finalize();
      final warningEvents = sink.events.where(
        (event) => event['event'] == 'warning',
      );

      expect(warningEvents, isNotEmpty);
      expect(
        warningEvents.every(
          (event) => !(event['message'] as String).contains('private'),
        ),
        isTrue,
      );
      expect(report.warnings, hasLength(1));
      expect(report.warnings.single, isNot(contains('private')));
      expect(report.images.single.warnings, hasLength(1));
    });

    test('batch warnings are sanitized, bounded, and included in the report', () {
      final sink = _Sink();
      final ledger = _ledger(batch: 'batch-warning-summary', sink: sink);
      ledger.warnBatch(r'تعذر الوصول إلى C:\private\source.jpg');
      final report = ledger.finalize();

      expect(report.warnings, hasLength(1));
      expect(report.warnings.single, isNot(contains('private')));
      expect(
        sink.events.any(
          (event) =>
              event['event'] == 'warning' && event['image'] == null,
        ),
        isTrue,
      );
    });

    test('long free text is clipped to one bounded line', () {
      final ledger = _ledger();
      ledger.image('img');
      ledger.overridden(
        'img',
        ProcessingStage.preprocessing,
        reason: List.filled(100, 'سبب\nطويل ').join(),
      );
      final stage = ledger.report.images.single.stageOf(ProcessingStage.preprocessing)!;
      expect(stage.reason.length, lessThanOrEqualTo(280));
      expect(stage.reason.contains('\n'), isFalse);
    });
  });
}
