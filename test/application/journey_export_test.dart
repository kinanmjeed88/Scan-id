import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/journey_export.dart';
import 'package:scan_id/domain/image_journey.dart';

ImageJourney journeyFor(String key) => ImageJourney(
  id: 'batch-0001-$key',
  batchId: 'batch-0001',
  projectId: 'project1',
  projectName: 'مستمسكات العائلة',
  imageName: '$key.png',
  startedAt: DateTime.utc(2026, 11, 9, 9),
  steps: [
    JourneyStep(
      stage: JourneyStage.selection,
      outcome: JourneyOutcome.passed,
      detail: 'اختيرت من جهازك.',
    ),
    JourneyStep(
      stage: JourneyStage.placement,
      outcome: JourneyOutcome.passed,
      detail: 'وُضع في الصفحة 1.',
    ),
  ],
);

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('journey-export-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  JourneyExporter exporter({
    required Future<bool> Function(File file, String mime) save,
  }) => JourneyExporter(
    saveFile: save,
    temporaryDirectory: () async => temporary,
    clock: () => DateTime(2026, 11, 9, 13, 45),
  );

  group('journey export', () {
    test('the file name carries the local date and time', () {
      expect(
        journeyExportFileName(DateTime(2026, 11, 9, 13, 45)),
        'scan-id-journeys-2026-11-09-1345.json',
      );
      expect(
        journeyExportFileName(DateTime(2026, 1, 2, 3, 4)),
        'scan-id-journeys-2026-01-02-0304.json',
      );
    });

    test('the document is versioned, counted and readable', () {
      final document = encodeJourneyExport(
        [journeyFor('first'), journeyFor('second')],
        exportedAt: DateTime.utc(2026, 11, 9, 10, 45),
      );
      final decoded = jsonDecode(document) as Map<String, Object?>;
      expect(decoded['format'], journeyExportFormat);
      expect(decoded['version'], journeyExportVersion);
      expect(decoded['entries'], 2);
      expect(decoded['exported_utc'], '2026-11-09T10:45:00.000Z');
      final journeys = decoded['journeys'] as List<Object?>;
      expect(journeys, hasLength(2));
      final first = journeys.first as Map<String, Object?>;
      expect(first['image'], 'first.png');
      expect(first['project'], isA<Map<String, Object?>>());
    });

    test('the export keeps the log order and adds no document text', () {
      final document = encodeJourneyExport(
        [journeyFor('first')],
        exportedAt: DateTime.utc(2026, 11, 9),
      );
      expect(document.contains('first.png'), isTrue);
      expect(document.contains('الاسم'), isFalse);
      expect(document.contains('الرقم الوطني'), isFalse);
      expect(document.contains('IDIRQ'), isFalse);
    });

    test('a save writes the document and reports what was written', () async {
      String? written;
      var mime = '';
      final journey = journeyFor('first');
      final outcome = await exporter(
        save: (file, type) async {
          written = await file.readAsString();
          mime = type;
          return true;
        },
      ).export([journey]);

      expect(outcome.status, JourneyExportStatus.saved);
      expect(outcome.saved, isTrue);
      expect(outcome.entries, 1);
      expect(outcome.bytes, greaterThan(0));
      expect(outcome.fileName, 'scan-id-journeys-2026-11-09-1345.json');
      expect(mime, 'application/json');
      final decoded = jsonDecode(written!) as Map<String, Object?>;
      expect(decoded['format'], journeyExportFormat);
      expect((decoded['journeys'] as List).single['id'], journey.id);
    });

    test('a closed dialog reports cancellation and keeps no file', () async {
      var offered = 0;
      final outcome = await exporter(
        save: (file, type) async {
          offered++;
          return false;
        },
      ).export([journeyFor('first')]);

      expect(offered, 1);
      expect(outcome.status, JourneyExportStatus.cancelled);
      expect(outcome.fileName, isNull);
      expect(outcome.bytes, 0);
    });

    test('an empty log never opens a dialog', () async {
      var offered = 0;
      final outcome = await exporter(
        save: (file, type) async {
          offered++;
          return true;
        },
      ).export(const []);

      expect(offered, 0);
      expect(outcome.status, JourneyExportStatus.empty);
      expect(outcome.entries, 0);
    });

    test('the staging folder is removed after the dialog closes', () async {
      await exporter(save: (file, type) async => true).export([
        journeyFor('first'),
      ]);
      await exporter(save: (file, type) async => false).export([
        journeyFor('second'),
      ]);
      expect(await temporary.list().toList(), isEmpty);
    });

    test('a write failure is reported to the caller', () async {
      final missing = Directory('${temporary.path}/gone');
      final failing = JourneyExporter(
        saveFile: (file, type) async => true,
        temporaryDirectory: () async => missing,
      );
      await expectLater(
        failing.export([journeyFor('first')]),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
