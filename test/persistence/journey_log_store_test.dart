import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/persistence/journey_log_store.dart';

ImageJourney journeyFor(String key, {String? project = 'project1'}) =>
    ImageJourney(
      id: 'batch-0001-$key',
      batchId: 'batch-0001',
      projectId: project ?? 'project1',
      projectName: 'مستمسكات العائلة',
      imageName: '$key.png',
      startedAt: DateTime.utc(2026, 11, 9, 9),
      steps: [
        JourneyStep(
          stage: JourneyStage.selection,
          outcome: JourneyOutcome.passed,
          detail: 'اختيرت لتُضاف إلى المشروع.',
        ),
        JourneyStep(
          stage: JourneyStage.copy,
          outcome: JourneyOutcome.passed,
          detail: 'نُسخت إلى مساحة التطبيق.',
          durationMs: 120,
        ),
        JourneyStep(
          stage: JourneyStage.placement,
          outcome: JourneyOutcome.passed,
          detail: 'وُضع في الصفحة 1 داخل حدود الورقة.',
        ),
      ],
    );

void main() {
  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('journey-log-test');
  });

  tearDown(() async {
    if (await support.exists()) await support.delete(recursive: true);
  });

  LocalJourneyLog logWith({int maxEntries = 200, int maxBytes = 512 * 1024}) =>
      LocalJourneyLog(
        supportDirectory: () async => support,
        maxEntries: maxEntries,
        maxBytes: maxBytes,
      );

  File logFile() => File(
    '${support.path}${Platform.pathSeparator}image_journeys'
    '${Platform.pathSeparator}${LocalJourneyLog.fileName}',
  );

  group('journey log store', () {
    test('an absent log reads as empty instead of failing', () async {
      final log = logWith();
      expect(await log.read(), isEmpty);
      final stats = await log.stats();
      expect(stats.entries, 0);
      expect(stats.bytes, 0);
      expect(stats.isEmpty, isTrue);
    });

    test('appends are readable and keep the newest entry first', () async {
      final log = logWith();
      await log.append([journeyFor('first')]);
      await log.append([journeyFor('second')]);
      final entries = await log.read();
      expect(entries.map((entry) => entry.imageName), [
        'second.png',
        'first.png',
      ]);
      final stats = await log.stats();
      expect(stats.entries, 2);
      expect(stats.bytes, greaterThan(0));
      expect(stats.sizeLabel, isNotEmpty);
    });

    test(
      're-appending the same report replaces it instead of duplicating it',
      () async {
        final log = logWith();
        final journey = journeyFor('only');
        await log.append([journey]);
        await log.append([journey]);
        final entries = await log.read();
        expect(entries, hasLength(1));
        expect(entries.single.id, journey.id);
      },
    );

    test('the entry cap drops the oldest reports', () async {
      final log = logWith(maxEntries: 2);
      await log.append([journeyFor('first')]);
      await log.append([journeyFor('second')]);
      await log.append([journeyFor('third')]);
      final entries = await log.read();
      expect(entries.map((entry) => entry.imageName), [
        'third.png',
        'second.png',
      ]);
    });

    test(
      'the byte cap trims from the oldest end and keeps the newest',
      () async {
        final log = logWith(maxBytes: 900);
        for (final key in ['first', 'second', 'third']) {
          await log.append([journeyFor(key)]);
        }
        final entries = await log.read();
        expect(entries, isNotEmpty);
        expect(entries.first.imageName, 'third.png');
        expect(entries.length, lessThan(3));
      },
    );

    test('clearing removes the file and leaves the directory', () async {
      final log = logWith();
      await log.append([journeyFor('first')]);
      expect(await logFile().exists(), isTrue);
      await log.clear();
      expect(await logFile().exists(), isFalse);
      expect(await log.read(), isEmpty);
      expect(await support.exists(), isTrue);
    });

    test('a damaged file reads as empty rather than throwing', () async {
      final log = logWith();
      await log.append([journeyFor('first')]);
      await logFile().writeAsString('{not json');
      expect(await log.read(), isEmpty);
    });

    test('an unknown schema version is ignored, not misinterpreted', () async {
      final log = logWith();
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}image_journeys',
      );
      await directory.create(recursive: true);
      await logFile().writeAsString(
        jsonEncode({
          'version': 99,
          'journeys': [journeyFor('x').toJson()],
        }),
      );
      expect(await log.read(), isEmpty);
    });

    test('one damaged entry does not hide the healthy ones', () async {
      final log = logWith();
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}image_journeys',
      );
      await directory.create(recursive: true);
      await logFile().writeAsString(
        jsonEncode({
          'version': 1,
          'journeys': [
            journeyFor('healthy').toJson(),
            {'stage': 'nonsense'},
          ],
        }),
      );
      final entries = await log.read();
      expect(entries.map((entry) => entry.imageName), ['healthy.png']);
    });

    test(
      'append preserves corrupt, unknown and partially damaged logs',
      () async {
        final log = logWith();
        await logFile().parent.create(recursive: true);
        for (final raw in [
          '{not json',
          jsonEncode({'version': 99, 'journeys': <Object?>[]}),
          jsonEncode({
            'version': 1,
            'journeys': [journeyFor('ok').toJson(), <String, Object?>{}],
          }),
        ]) {
          await logFile().writeAsString(raw);
          await expectLater(
            log.append([journeyFor('new')]),
            throwsA(isA<Object>()),
          );
          expect(await logFile().readAsString(), raw);
        }
      },
    );

    test('failed write preserves the previous log and a retry works', () async {
      final log = logWith();
      await log.append([journeyFor('old')]);
      final old = await logFile().readAsString();
      final obstacle = Directory('${logFile().path}.tmp');
      await obstacle.create();
      await expectLater(
        log.append([journeyFor('new')]),
        throwsA(isA<Object>()),
      );
      expect(await logFile().readAsString(), old);
      await obstacle.delete();
      await log.append([journeyFor('new')]);
      expect((await log.read()).map((j) => j.imageName), [
        'new.png',
        'old.png',
      ]);
    });

    test('writes leave no temporary file behind', () async {
      final log = logWith();
      await log.append([journeyFor('first')]);
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}image_journeys',
      );
      final names = await directory
          .list()
          .map((entry) => entry.path.split(Platform.pathSeparator).last)
          .toList();
      expect(names, [LocalJourneyLog.fileName]);
    });

    test('concurrent appends never interleave into a truncated file', () async {
      final log = logWith();
      await Future.wait([
        log.append([journeyFor('first')]),
        log.append([journeyFor('second')]),
        log.append([journeyFor('third')]),
      ]);
      final entries = await log.read();
      expect(entries, hasLength(3));
      // The file must still be valid JSON: a half-written file reads as empty.
      final decoded =
          jsonDecode(await logFile().readAsString()) as Map<String, Object?>;
      expect(decoded['version'], 1);
    });

    test('instances in the same isolate serialize appends', () async {
      final a = logWith();
      final b = logWith();
      await Future.wait([
        a.append([journeyFor('first')]),
        b.append([journeyFor('second')]),
      ]);
      expect(
        (await a.read()).map((entry) => entry.imageName),
        unorderedEquals(['first.png', 'second.png']),
      );
    });

    test(
      'an unwritable location reports append failure and tolerant reads',
      () async {
        final log = LocalJourneyLog(
          supportDirectory: () async =>
              Directory('/proc/definitely-not-writable/scan-id'),
        );
        await expectLater(
          log.append([journeyFor('first')]),
          throwsA(isA<Object>()),
        );
        expect(await log.read(), isEmpty);
        expect((await log.stats()).entries, 0);
      },
    );
  });
}
