import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/intake_stage_log.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/persistence/journey_log_store.dart';

/// The stage report is the artefact requirement 2 asks for: every stage of
/// every image, with the technical cause of a failure. These tests cover the
/// parts that can be wrong silently — a report that loses its cause, a round
/// trip that invents one, and a bound that lets reports evict each other.
void main() {
  late Directory folder;
  late LocalJourneyLog store;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('stage-report-test');
    store = LocalJourneyLog(supportDirectory: () async => folder);
  });

  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  IntakeStageReport report({String batchId = 'batch-0001'}) {
    final log = IntakeStageLog(assetId: 'asset-1', assetName: 'one.png')
      ..pass(JourneyStage.copy, 'نُسخت إلى مساحة التطبيق.')
      ..block(
        JourneyStage.detection,
        'تعذّر فحص التقسيم متعدد المستمسكات: صورة غير صالحة',
        fields: {'errorType': 'FormatException'},
      );
    return IntakeStageReport(
      batchId: batchId,
      projectId: 'project-1',
      projectName: 'مشروع',
      startedAt: DateTime.utc(2026, 11, 18, 12),
      summary: 'تعذّرت معالجة 1 من 1 صورة',
      logs: [log],
    );
  }

  test('a report round-trips with its cause and its measured fields', () async {
    await store.appendStageReport(report());
    final read = await store.readStageReports();
    expect(read, hasLength(1));
    final images = read.single.logs;
    expect(images, hasLength(1));
    final detection = images.single.records.firstWhere(
      (IntakeStageRecord record) => record.stage == JourneyStage.detection,
    );
    expect(detection.outcome, JourneyOutcome.blocked);
    expect(detection.detail, contains('تعذّر فحص التقسيم'));
    // The machine-readable cause is what a reader uses to tell failures apart.
    expect(detection.fields['errorType'], 'FormatException');
  });

  test('re-filing a batch replaces its report', () async {
    await store.appendStageReport(report());
    await store.appendStageReport(report());
    expect(await store.readStageReports(), hasLength(1));
  });

  test('an empty report writes nothing', () async {
    await store.appendStageReport(
      IntakeStageReport(
        batchId: 'empty',
        projectId: 'p',
        projectName: '',
        startedAt: DateTime.utc(2026),
        summary: '',
        logs: const [],
      ),
    );
    expect(await store.readStageReports(), isEmpty);
  });

  test('newest report is first', () async {
    await store.appendStageReport(report(batchId: 'batch-0001'));
    await store.appendStageReport(report(batchId: 'batch-0002'));
    final read = await store.readStageReports();
    expect(read.first.batchId, 'batch-0002');
  });

  test('reports and journeys are independent records', () async {
    // Both live in the same store but in different files, and clearing one
    // must not touch the other: they describe different things.
    await store.appendStageReport(report());
    await store.clear();
    expect(await store.readStageReports(), hasLength(1));
  });

  test('a corrupt report file reads as empty rather than throwing', () async {
    await store.appendStageReport(report());
    final file = File(
      '${folder.path}${Platform.pathSeparator}image_journeys'
      '${Platform.pathSeparator}${LocalJourneyLog.stageReportFileName}',
    );
    expect(await file.exists(), isTrue, reason: 'fixture must be on disk');
    await file.writeAsString('{not json');
    // Reading is tolerant by contract: a damaged report is dropped, and
    // losing a report must not become a second failure on top of the one it
    // documents.
    expect(await store.readStageReports(), isEmpty);
  });

  test('a report written by another build is dropped, not trusted', () async {
    final json = report().toJson()..['batchId'] = 42;
    expect(IntakeStageReport.fromJson(json), isNull);
    final ok = report().toJson();
    final restored = IntakeStageReport.fromJson(ok);
    expect(restored, isNotNull);
    expect(restored!.failed, hasLength(1));
    expect(restored.headline, contains('كشف الحدود'));
  });
}
