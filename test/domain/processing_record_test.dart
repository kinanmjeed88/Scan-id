import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/intake_options.dart';
import 'package:scan_id/domain/processing_record.dart';
import 'package:scan_id/domain/recognition.dart' show SideKind;
import 'package:scan_id/domain/validation.dart';

StageEvidence _evidence({int items = 1}) => StageEvidence(
  verified: true,
  checks: [
    EvidenceCheck(name: 'measured', passed: true, detail: '$items'),
  ],
  counts: {'items': items},
);

StageRecord _stage(
  ProcessingStage stage,
  StageStatus status, {
  String reason = 'سبب مقاس',
  StageEvidence? evidence,
  Map<String, Object?> results = const {},
}) => StageRecord(
  stage: stage,
  status: status,
  reason: reason,
  results: results,
  evidence:
      evidence ??
      (status == StageStatus.succeeded
          ? _evidence()
          : null),
);

DocumentProcessingLog _document({
  required String imageId,
  required int index,
  StageStatus save = StageStatus.succeeded,
  StageStatus verify = StageStatus.succeeded,
  bool failedCrop = false,
}) => DocumentProcessingLog(
  id: 'doc-$index',
  imageId: imageId,
  selectionIndex: index,
  kind: DocumentKind.unifiedNationalId,
  side: SideKind.front,
  kindSource: RecordSource.user,
  sideSource: RecordSource.user,
  stages: [
    _stage(
      ProcessingStage.crop,
      failedCrop ? StageStatus.failed : StageStatus.succeeded,
      reason: failedCrop ? 'تعذر إنتاج صورة.' : 'أُنتجت صورة.',
      evidence: failedCrop ? null : _evidence(),
    ),
    if (failedCrop)
      StageRecord(
        stage: ProcessingStage.saveDocument,
        status: StageStatus.failed,
        reason: 'لم يُحفظ لأن القص تعذر.',
        errorType: 'CropFailed',
        diagnostics: const ['crop_failed'],
      )
    else ...[
      _stage(ProcessingStage.typeSideSize, StageStatus.succeeded),
      _stage(
        ProcessingStage.saveDocument,
        save,
        reason: save == StageStatus.succeeded ? 'حُفظ.' : 'لم يُحفظ.',
      ),
      _stage(
        ProcessingStage.addToProject,
        save,
        reason: 'أُضيف.',
      ),
      _stage(
        ProcessingStage.verifyAddition,
        verify,
        reason: 'تُحقّق.',
      ),
    ],
  ],
  outcome: failedCrop ? 'فشل' : 'نجح',
);

ProcessingReport _report({
  String batchId = 'batch-1',
  bool finalised = true,
  List<ImageProcessingLog>? images,
  IntakeOptions? options,
  bool recovered = false,
}) => ProcessingReport(
  batchId: batchId,
  projectId: 'project-1',
  projectName: 'مشروع',
  startedAt: DateTime.utc(2026, 1, 1, 10),
  endedAt: DateTime.utc(2026, 1, 1, 10, 1),
  options: options,
  optionCodes: options?.traceCodes.toList() ?? const [],
  images:
      images ??
      [
        ImageProcessingLog(
          operationId: batchId,
          imageId: 'image-1',
          imageName: 'doc.jpg',
          startedAt: DateTime.utc(2026, 1, 1, 10),
          endedAt: DateTime.utc(2026, 1, 1, 10, 1),
          stages: [
            _stage(ProcessingStage.selection, StageStatus.succeeded),
            _stage(ProcessingStage.fileValidation, StageStatus.succeeded),
            _stage(ProcessingStage.decode, StageStatus.succeeded),
            _stage(ProcessingStage.dimensions, StageStatus.succeeded),
            _stage(ProcessingStage.importCopy, StageStatus.succeeded),
            _stage(
              ProcessingStage.completion,
              StageStatus.succeeded,
              reason: 'أُنهيت.',
            ),
          ],
        ),
      ],
  recovered: recovered,
  finalised: finalised,
);

void main() {
  group('StageRecord invariants', () {
    test('a successful stage is impossible without verified evidence', () {
      expect(
        () => StageRecord(
          stage: ProcessingStage.crop,
          status: StageStatus.succeeded,
          reason: 'نجح',
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => StageRecord(
          stage: ProcessingStage.crop,
          status: StageStatus.succeeded,
          reason: 'نجح',
          evidence: StageEvidence(verified: false),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('verified evidence must carry a measurement', () {
      expect(
        () => StageEvidence(verified: true),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a success cannot contradict one of its measured checks', () {
      expect(
        () => StageRecord(
          stage: ProcessingStage.decode,
          status: StageStatus.succeeded,
          reason: 'فُك الترميز.',
          evidence: StageEvidence(
            verified: true,
            checks: [EvidenceCheck(name: 'image_decoded', passed: false)],
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a failed stage must name its error or carry diagnostics', () {
      expect(
        () => StageRecord(
          stage: ProcessingStage.crop,
          status: StageStatus.failed,
          reason: 'فشل',
        ),
        throwsA(isA<ValidationException>()),
      );
      final undetermined = StageRecord(
        stage: ProcessingStage.crop,
        status: StageStatus.failed,
        reason: 'فشل',
        diagnostics: const [StageRecord.undeterminedCause],
      );
      expect(undetermined.status, StageStatus.failed);
      expect(undetermined.diagnostics, isNotEmpty);
    });

    test('duration is measured from the timestamps exactly', () {
      final start = DateTime.utc(2026, 1, 1, 10, 0, 0);
      final record = StageRecord(
        stage: ProcessingStage.decode,
        status: StageStatus.succeeded,
        reason: 'فُك الترميز.',
        startedAt: start,
        endedAt: start.add(const Duration(milliseconds: 1250)),
        evidence: _evidence(),
      );
      expect(record.durationMs, 1250);
    });

    test('an end before the start is refused', () {
      final start = DateTime.utc(2026, 1, 1, 10);
      expect(
        () => StageRecord(
          stage: ProcessingStage.decode,
          status: StageStatus.succeeded,
          reason: 'فُك.',
          startedAt: start,
          endedAt: start.subtract(const Duration(seconds: 1)),
          evidence: _evidence(),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('long text is clipped, never turned into a second failure', () {
      final record = StageRecord(
        stage: ProcessingStage.crop,
        status: StageStatus.failed,
        reason: 'سطر طويل\n' * 200,
        errorType: 'TestFailure',
        diagnostics: ['تفصيل\n' * 300],
      );
      expect(record.reason.contains('\n'), isFalse);
      expect(record.reason.length, lessThanOrEqualTo(280));
      expect(record.diagnostics.single.length, lessThanOrEqualTo(200));
    });

    test('a stage record round-trips through JSON with all its facts', () {
      final start = DateTime.utc(2026, 1, 1, 9);
      final original = StageRecord(
        stage: ProcessingStage.geometryCheck,
        status: StageStatus.succeeded,
        reason: 'اجتاز التحقق الهندسي.',
        startedAt: start,
        endedAt: start.add(const Duration(milliseconds: 42)),
        inputs: const {'corners': 4, 'width': 400},
        results: const {'aspect': 1.58, 'accepted': true},
        itemCount: 4,
        actionTaken: 'تابع إلى القص.',
        evidence: StageEvidence(
          verified: true,
          note: 'قياس مقاس',
          checks: [
            EvidenceCheck(name: 'quad_acceptable', passed: true, detail: 'ok'),
          ],
          counts: const {'corners': 4},
        ),
      );
      final restored = StageRecord.fromJson(original.toJson());
      expect(restored.stage, original.stage);
      expect(restored.status, original.status);
      expect(restored.durationMs, 42);
      expect(restored.inputs, original.inputs);
      expect(restored.results, original.results);
      expect(restored.evidence!.checks.single.name, 'quad_acceptable');
      expect(restored.evidence!.counts['corners'], 4);
      expect(restored.actionTaken, original.actionTaken);
    });
  });

  group('ImageProcessingLog fills every stage honestly', () {
    test('stages after a failure are stopped, never successful', () {
      final image = ImageProcessingLog(
        operationId: 'op',
        imageId: 'img',
        startedAt: DateTime.utc(2026, 1, 1),
        stages: [
          _stage(ProcessingStage.selection, StageStatus.succeeded),
          _stage(ProcessingStage.fileValidation, StageStatus.succeeded),
          StageRecord(
            stage: ProcessingStage.decode,
            status: StageStatus.failed,
            reason: 'تعذر فك الترميز.',
            errorType: 'FormatException',
          ),
        ],
      );
      final filled = image.filledStages();
      expect(filled.length, ProcessingStage.values.where((s) => !s.documentScoped).length);
      final decode = filled.firstWhere(
        (stage) => stage.stage == ProcessingStage.decode,
      );
      expect(decode.status, StageStatus.failed);
      for (final stage in filled) {
        if (stage.stage.index <= ProcessingStage.decode.index) continue;
        expect(stage.status, StageStatus.stopped);
        expect(stage.reason, contains('فك الترميز'));
        expect(stage.status, isNot(StageStatus.succeeded));
      }
      expect(image.outcome, ImageOutcome.failed);
    });

    test('a gap before a later recorded stage is not read as success', () {
      final image = ImageProcessingLog(
        operationId: 'op',
        imageId: 'img',
        startedAt: DateTime.utc(2026, 1, 1),
        endedAt: DateTime.utc(2026, 1, 1, 0, 1),
        stages: [
          _stage(ProcessingStage.selection, StageStatus.succeeded),
          _stage(ProcessingStage.analysis, StageStatus.succeeded),
        ],
      );
      final filled = image.filledStages();
      final decode = filled.firstWhere(
        (stage) => stage.stage == ProcessingStage.decode,
      );
      expect(decode.status, StageStatus.notReached);
      expect(image.recordingGaps, contains(ProcessingStage.decode));
      expect(image.outcome, ImageOutcome.completedWithReview);
    });

    test('bypass, non-applicable and success stay distinct', () {
      final image = ImageProcessingLog(
        operationId: 'op',
        imageId: 'img',
        startedAt: DateTime.utc(2026, 1, 1),
        stages: [
          _stage(ProcessingStage.selection, StageStatus.succeeded),
          _stage(ProcessingStage.analysis, StageStatus.succeeded),
          _stage(
            ProcessingStage.preprocessing,
            StageStatus.overridden,
            reason: 'حدّد المستخدم النوع؛ لا قراءة نص.',
          ),
          _stage(
            ProcessingStage.confidence,
            StageStatus.notApplicable,
            reason: 'لا ثقة مقيسة.',
          ),
        ],
      );
      expect(
        image.statusOf(ProcessingStage.preprocessing),
        StageStatus.overridden,
      );
      expect(
        image.statusOf(ProcessingStage.confidence),
        StageStatus.notApplicable,
      );
      expect(
        image.statusOf(ProcessingStage.analysis),
        StageStatus.succeeded,
      );
    });
  });

  group('Documents and report totals', () {
    test('document gaps and downstream stops remain explicit', () {
      final document = DocumentProcessingLog(
        id: 'doc-1',
        imageId: 'img',
        selectionIndex: 1,
        stages: [
          _stage(ProcessingStage.boundaryCorners, StageStatus.succeeded),
          StageRecord(
            stage: ProcessingStage.crop,
            status: StageStatus.failed,
            reason: 'لم ينتج القص صورة.',
            errorType: 'EmptyCrop',
          ),
        ],
      );
      final filled = document.filledStages();
      expect(
        filled.length,
        ProcessingStage.values.where((stage) => stage.documentScoped).length,
      );
      expect(
        filled.firstWhere((stage) => stage.stage == ProcessingStage.geometryCheck).status,
        StageStatus.notReached,
      );
      expect(
        filled.firstWhere((stage) => stage.stage == ProcessingStage.crop).status,
        StageStatus.failed,
      );
      expect(
        filled.firstWhere((stage) => stage.stage == ProcessingStage.saveDocument).status,
        StageStatus.stopped,
      );
      expect(document.recordingGaps, contains(ProcessingStage.geometryCheck));
    });

    test('each document is independent and partial success is reported', () {
      final image = ImageProcessingLog(
        operationId: 'op',
        imageId: 'img',
        startedAt: DateTime.utc(2026, 1, 1),
        stages: [
          _stage(ProcessingStage.selection, StageStatus.succeeded),
          _stage(ProcessingStage.analysis, StageStatus.succeeded),
          _stage(ProcessingStage.completion, StageStatus.succeeded),
        ],
        documents: [
          for (var index = 1; index <= 3; index++)
            _document(imageId: 'img', index: index),
          _document(imageId: 'img', index: 4, failedCrop: true),
        ],
      );
      final report = _report(images: [image]);
      expect(report.documentsMeasured, 4);
      expect(report.documentsCropped, 3);
      expect(report.documentsSaved, 3);
      expect(report.documentsAdded, 3);
      expect(report.documentsFailed, 1);
      expect(image.outcome, ImageOutcome.partial);
      expect(report.verdict, ProcessingVerdict.partial);
      expect(report.headline, contains('نجاح جزئي'));
      for (final document in image.documents) {
        expect(document.imageId, image.imageId);
      }
    });

    test('a report reflects the user options, not a fixed list', () {
      const options = IntakeOptions(
        side: SideKind.back,
        kind: DocumentKind.unifiedNationalId,
        acceptSuggestedBoundary: true,
        centerDocuments: false,
        multiDocument: true,
        confirmed: {
          IntakeOptionKey.kind,
          IntakeOptionKey.center,
        },
      );
      final report = _report(options: options);
      expect(report.route, IntakeRoute.manualSelections);
      expect(report.optionCodes, contains('kind=unifiedNationalId'));
      expect(report.optionCodes, contains('center=false'));
      expect(report.optionCodes, contains('acceptBoundary=true'));
      final restored = ProcessingReport.fromJson(report.toJson());
      expect(restored.options!.multiDocument, isTrue);
      expect(restored.options!.centerDocuments, isFalse);
      expect(restored.options!.side, SideKind.back);
    });

    test('report JSON preserves images, documents and verdict', () {
      final image = ImageProcessingLog(
        operationId: 'op',
        imageId: 'img',
        imageName: 'one.jpg',
        startedAt: DateTime.utc(2026, 1, 1),
        endedAt: DateTime.utc(2026, 1, 1, 0, 0, 2),
        stages: [
          _stage(ProcessingStage.selection, StageStatus.succeeded),
          _stage(ProcessingStage.completion, StageStatus.succeeded),
        ],
        documents: [_document(imageId: 'img', index: 1)],
      );
      final report = ProcessingReport(
        batchId: 'batch-9',
        projectId: 'project-9',
        projectName: 'مشروع ٩',
        startedAt: DateTime.utc(2026, 1, 1),
        endedAt: DateTime.utc(2026, 1, 1, 0, 0, 2),
        images: [image],
      );
      final restored = ProcessingReport.fromJson(report.toJson());
      expect(restored.batchId, 'batch-9');
      expect(restored.images.single.imageName, 'one.jpg');
      expect(restored.images.single.documents.single.id, 'doc-1');
      expect(restored.verdict, report.verdict);
      expect(restored.totalDurationMs, 2000);
      expect(restored.stageDurations[ProcessingStage.selection], isNotNull);
    });

    test('non-finite measurements cannot break journal JSON encoding', () {
      final record = _stage(
        ProcessingStage.confidence,
        StageStatus.succeeded,
        results: const {'valid': 0.8, 'invalid': double.nan},
      );

      expect(record.results['valid'], 0.8);
      expect(record.results.containsKey('invalid'), isFalse);
      expect(record.toJson(), isNotEmpty);
    });

    test('diagnostics retain a basename but never persist a filesystem path', () {
      final image = ImageProcessingLog(
        operationId: 'op',
        imageId: 'img',
        imageName: r'C:\Users\Alice\private\scan.png',
        startedAt: DateTime.utc(2026, 1, 1),
        stages: [
          StageRecord(
            stage: ProcessingStage.selection,
            status: StageStatus.succeeded,
            reason: 'استُلم المصدر.',
            evidence: _evidence(),
            results: const {'path': r'C:\Users\Alice\private\scan.png'},
          ),
        ],
      );
      expect(image.imageName, 'scan.png');
      final result = image.stages.single.results['path'] as String;
      expect(result, isNot(contains('Alice')));
      expect(result, contains('مسار محذوف'));
    });
  });
}
