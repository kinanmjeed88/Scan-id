import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/processing_ledger.dart';
import 'package:scan_id/domain/processing_record.dart';
import 'package:scan_id/persistence/processing_journal_store.dart';

StageEvidence _ok() =>
    StageEvidence(verified: true, counts: const {'items': 1});

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('processing_journal_test');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  LocalProcessingJournal store({
    int maxOperations = 20,
    int maxEventsPerOperation = 1200,
    int maxBytesPerOperation = 1024 * 1024,
  }) => LocalProcessingJournal(
    supportDirectory: () async => root,
    maxOperations: maxOperations,
    maxEventsPerOperation: maxEventsPerOperation,
    maxBytesPerOperation: maxBytesPerOperation,
  );

  ProcessingLedger ledgerFor(
    String batch,
    ProcessingJournalSink sink, {
    DateTime? now,
  }) {
    final clock = now ?? DateTime.utc(2026, 1, 1, 10);
    var current = clock;
    return ProcessingLedger(
      operationId: batch,
      projectId: 'project-1',
      projectName: 'مشروع الاختبار',
      sink: sink,
      clock: () {
        final value = current;
        current = current.add(const Duration(milliseconds: 5));
        return value;
      },
    );
  }

  File fileFor(String batch) => File(
    '${root.path}${Platform.pathSeparator}'
    '${LocalProcessingJournal.folderName}'
    '${Platform.pathSeparator}operation_$batch.jsonl',
  );

  test('a finalised operation is read back with its stages', () async {
    final journal = store();
    final ledger = ledgerFor('batch-store-1', journal);
    ledger.image('img', name: 'one.jpg', width: 400, height: 600);
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
      errorCode: FailureCode.validation,
    );
    ledger.finalize();

    await journal.idle;
    final reports = await journal.reports();
    expect(reports.length, 1);
    final report = reports.single;
    expect(report.batchId, 'batch-store-1');
    expect(report.recovered, isFalse);
    expect(report.finalised, isTrue);
    expect(report.images.single.imageName, 'one.jpg');
    expect(
      report.images.single.stageOf(ProcessingStage.selection)!.status,
      StageStatus.succeeded,
    );
    expect(
      report.images.single.stageOf(ProcessingStage.decode)!.errorType,
      'FormatException',
    );
    expect(report.verdict, ProcessingVerdict.failed);
    expect(await fileFor('batch-store-1').exists(), isTrue);
    expect(await journal.reportFor('batch-store-1'), isNotNull);
  });

  test('a crash mid-processing keeps the stages that ran', () async {
    final journal = store();
    final ledger = ledgerFor('batch-store-crash', journal);
    ledger.image('img', name: 'one.jpg');
    ledger.succeeded(
      'img',
      ProcessingStage.selection,
      reason: 'استُلمت الصورة.',
      evidence: _ok(),
    );
    ledger.succeeded(
      'img',
      ProcessingStage.fileValidation,
      reason: 'صيغة مدعومة.',
      evidence: _ok(),
    );
    ledger.succeeded(
      'img',
      ProcessingStage.decode,
      reason: 'فُك الترميز.',
      evidence: _ok(),
    );
    // No finalize: the process died here.
    await journal.idle;

    final recovered = await journal.reportFor('batch-store-crash');
    expect(recovered, isNotNull);
    expect(recovered!.recovered, isTrue);
    expect(recovered.finalised, isFalse);
    expect(recovered.verdict, ProcessingVerdict.interrupted);
    expect(recovered.images.single.outcome, ImageOutcome.interrupted);
    expect(
      recovered.images.single.stageOf(ProcessingStage.decode)!.status,
      StageStatus.succeeded,
    );
    final filled = recovered.images.single.filledStages();
    expect(
      filled.firstWhere((s) => s.stage == ProcessingStage.dimensions).status,
      StageStatus.notReached,
    );
    expect(recovered.headline, contains('انقطعت'));
  });

  test('one damaged line does not hide the stages around it', () async {
    final journal = store();
    final ledger = ledgerFor('batch-store-damaged', journal);
    ledger.image('img');
    ledger.succeeded(
      'img',
      ProcessingStage.selection,
      reason: 'استُلمت.',
      evidence: _ok(),
    );
    ledger.finalize();
    await journal.idle;

    final file = fileFor('batch-store-damaged');
    await file.writeAsString(
      'not a json line{{{\n',
      mode: FileMode.append,
      flush: true,
    );

    final report = await journal.reportFor('batch-store-damaged');
    expect(report, isNotNull);
    expect(
      report!.images.single.stageOf(ProcessingStage.selection)!.status,
      StageStatus.succeeded,
    );
  });

  test('unavailable journal storage cannot fail processing or its report', () async {
    final journal = LocalProcessingJournal(
      supportDirectory: () async => throw const FileSystemException(
        'storage unavailable',
      ),
    );
    final ledger = ledgerFor('batch-store-unavailable', journal);

    ledger.image('img');
    ledger.succeeded(
      'img',
      ProcessingStage.selection,
      reason: 'استُلم المصدر.',
      evidence: _ok(),
    );
    final report = ledger.finalize();
    await journal.idle;

    expect(report.finalised, isTrue);
    expect(report.images.single.statusOf(ProcessingStage.selection), StageStatus.succeeded);
    expect(await journal.reports(), isEmpty);
  });

  test('unknown and invalid operation ids are not invented', () async {
    final journal = store();
    expect(await journal.reportFor('missing-operation'), isNull);
    expect(await journal.reportFor('../escape'), isNull);
    expect(await journal.latest(), isNull);
    expect(await journal.reports(), isEmpty);
  });

  test('clear removes the journal files only', () async {
    final journal = store();
    final ledger = ledgerFor('batch-store-clear', journal);
    ledger.image('img');
    ledger.finalize();
    await journal.idle;
    expect(await fileFor('batch-store-clear').exists(), isTrue);

    final projectFile = File('${root.path}/project.json');
    await projectFile.writeAsString('{"keep":true}');
    await journal.clear();

    expect(await fileFor('batch-store-clear').exists(), isFalse);
    expect(await projectFile.exists(), isTrue);
    expect(await journal.reports(), isEmpty);
  });

  test('older operations are pruned when the bound is reached', () async {
    final journal = store(maxOperations: 1);
    final first = ledgerFor(
      'batch-store-old',
      journal,
      now: DateTime.utc(2026, 1, 1, 9),
    );
    first.image('img');
    first.finalize();
    await journal.idle;
    expect(await fileFor('batch-store-old').exists(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 25));

    final second = ledgerFor(
      'batch-store-new',
      journal,
      now: DateTime.utc(2026, 1, 1, 11),
    );
    second.image('img');
    second.finalize();
    await journal.idle;

    final reports = await journal.reports();
    expect(reports.length, 1);
    expect(reports.single.batchId, 'batch-store-new');
  });

  test(
    'retention also prunes incomplete operations when a new batch starts',
    () async {
      final journal = store(maxOperations: 1);
      final first = ledgerFor('batch-store-crashed-old', journal);
      first.image('img');
      await journal.idle;
      expect(await fileFor('batch-store-crashed-old').exists(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final second = ledgerFor('batch-store-crashed-new', journal);
      second.image('img');
      await journal.idle;

      expect(await fileFor('batch-store-crashed-old').exists(), isFalse);
      expect(await fileFor('batch-store-crashed-new').exists(), isTrue);
      final reports = await journal.reports();
      expect(reports, hasLength(1));
      expect(reports.single.batchId, 'batch-store-crashed-new');
    },
  );

  test(
    'the event cap does not double-count already-written queue entries',
    () async {
      final journal = store(maxEventsPerOperation: 3);
      final ledger = ledgerFor('batch-store-exact-cap', journal);
      await journal.idle;
      ledger.image('img');
      await journal.idle;
      ledger.succeeded(
        'img',
        ProcessingStage.selection,
        reason: 'استُلم المصدر.',
        evidence: _ok(),
      );
      await journal.idle;
      ledger.succeeded(
        'img',
        ProcessingStage.fileValidation,
        reason: 'صيغة مدعومة.',
        evidence: _ok(),
      );
      ledger.finalize();
      await journal.idle;

      final lines = await fileFor('batch-store-exact-cap').readAsLines();
      final events = [
        for (final line in lines) (jsonDecode(line) as Map)['event'],
      ];
      expect(events, ['batch', 'image', 'stage', 'report']);
    },
  );

  test(
    'ordinary JSONL lines cannot cross the byte cap but the final report can',
    () async {
      final journal = store(maxBytesPerOperation: 1);
      final ledger = ledgerFor('batch-store-byte-cap', journal);
      ledger.image('img', name: 'one.jpg');
      ledger.finalize();
      await journal.idle;

      final lines = await fileFor('batch-store-byte-cap').readAsLines();
      expect(lines, hasLength(1));
      expect((jsonDecode(lines.single) as Map)['event'], 'report');
      final report = await journal.reportFor('batch-store-byte-cap');
      expect(report, isNotNull);
      expect(report!.images.single.imageName, 'one.jpg');
    },
  );

  test('the final report is written even after the event bound', () async {
    final journal = store(maxEventsPerOperation: 2);
    final ledger = ledgerFor('batch-store-capped', journal);
    ledger.image('img');
    for (final stage in [
      ProcessingStage.selection,
      ProcessingStage.fileValidation,
      ProcessingStage.decode,
      ProcessingStage.dimensions,
      ProcessingStage.analysis,
    ]) {
      ledger.succeeded('img', stage, reason: 'مرحلة مقاسة.', evidence: _ok());
    }
    ledger.finalize();
    await journal.idle;

    final report = await journal.latest();
    expect(report, isNotNull);
    expect(report!.finalised, isTrue);
    expect(report.batchId, 'batch-store-capped');
  });
}
