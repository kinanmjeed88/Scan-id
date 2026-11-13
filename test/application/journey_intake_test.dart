import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/journey_log.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/persistence/journey_log_store.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/intake.dart';

void main() {
  late Directory root;
  late Directory support;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late LocalJourneyLog log;
  late ProjectService service;

  Uint8List bytes() =>
      Uint8List.fromList(img.encodePng(img.Image(width: 120, height: 90)));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_journey_');
    support = await Directory.systemTemp.createTemp('scan_journey_log_');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    log = LocalJourneyLog(supportDirectory: () async => support);
    service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      smartRecognitionEnabled: true,
      journeyLog: log,
    );
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
    await support.delete(recursive: true);
  });

  List<ImportSource> sources(int count, {List<int> broken = const []}) => [
    for (var i = 0; i < count; i++)
      ImportSource(
        'صورة$i.png',
        broken.contains(i)
            ? () => Stream<List<int>>.value(Uint8List.fromList([1, 2, 3]))
            : () => Stream<List<int>>.value(bytes()),
      ),
  ];

  test(
    'an intake files one report per image, from the picker to the save',
    () async {
      final project = await service.create('سجل');
      final runner = IntakeRunner(service: service, project: project);
      final run = await runner.run(sources(1));

      expect(run.importedCount, 1);
      final stored = await log.read();
      expect(stored, hasLength(1));
      final journey = stored.single;
      expect(journey.imageName, 'صورة0.png');
      expect(journey.projectName, 'سجل');
      expect(journey.batchId, runner.lastTrace!.taskId);
      expect(journey.steps.first.stage, JourneyStage.selection);
      expect(journey.steps.last.stage, JourneyStage.save);
      expect(journey.imported, isTrue);
      final stageIndexes = journey.steps
          .map((step) => step.stage.index)
          .toList();
      expect(stageIndexes, orderedEquals([...stageIndexes]..sort()));
      // The durable copy is the one Settings reads; the runner exposes the same
      // reports so the screen that imported them can point at them.
      expect(runner.lastJourneys.map((entry) => entry.id), [journey.id]);
    },
  );

  test('a broken source is reported as not imported, and the next image still '
      'gets its own report', () async {
    final project = await service.create('سجل');
    final runner = IntakeRunner(service: service, project: project);
    final run = await runner.run(sources(2, broken: [0]));

    expect(run.failures, hasLength(1));
    final stored = await log.read();
    expect(stored.map((entry) => entry.imageName), ['صورة0.png', 'صورة1.png']);
    final refused = stored.firstWhere(
      (entry) => entry.imageName == 'صورة0.png',
    );
    final imported = stored.firstWhere(
      (entry) => entry.imageName == 'صورة1.png',
    );
    expect(refused.imported, isFalse);
    expect(
      refused.steps.any(
        (step) =>
            step.stage == JourneyStage.copy &&
            step.outcome == JourneyOutcome.blocked,
      ),
      isTrue,
    );
    expect(imported.imported, isTrue);
  });

  test(
    'a picked name the journal cannot hold never fails the intake',
    () async {
      // The journal stores one-line names of bounded length. The report is
      // filed after the images were committed, so a name outside those bounds
      // has to be described, not thrown: before this was pinned, either of
      // these names made the whole run end in an exception although the other
      // images had been imported.
      final project = await service.create('سجل');
      final runner = IntakeRunner(service: service, project: project);
      final tooLong = '${'ن' * 240}.png';
      final run = await runner.run([
        ImportSource(tooLong, () => Stream<List<int>>.value(bytes())),
        ImportSource('صورة\nسطر.png', () => Stream<List<int>>.value(bytes())),
        ImportSource('سليمة.png', () => Stream<List<int>>.value(bytes())),
      ]);

      // The import's own rule is unchanged: a name over 160 characters is a
      // per-source failure. The other two are committed.
      expect(run.failures, hasLength(1));
      expect(run.importedCount, 2);
      expect(run.error, isNull);

      final stored = await log.read();
      expect(stored, hasLength(3));
      final names = stored.map((entry) => entry.imageName).toSet();
      expect(names, contains('سليمة.png'));
      expect(names, contains('صورة سطر.png'));
      final shortened = stored.firstWhere(
        (entry) => entry.imageName.startsWith('نننن'),
      );
      expect(shortened.imageName.length, lessThanOrEqualTo(200));
      expect(shortened.imageName, endsWith('…'));
      expect(shortened.imported, isFalse);
      expect(
        stored.where((entry) => entry.imported).map((entry) => entry.imageName),
        unorderedEquals(['سليمة.png', 'صورة سطر.png']),
      );
      expect(runner.lastJourneys, hasLength(3));
    },
  );

  test('a host with no log still imports normally', () async {
    final plain = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      smartRecognitionEnabled: true,
    );
    final project = await plain.create('بلا سجل');
    final run = await IntakeRunner(
      service: plain,
      project: project,
    ).run(sources(1));

    expect(run.importedCount, 1);
    expect(await log.read(), isEmpty);
  });
  test('failed journey writes retry and do not invalidate a committed import', () async {
    final failing = _FailingJourneyLog(failures: 2);
    final host = ProjectService(projects, assets,
        imageEditor: LocalImageEditor(projects.files), journeyLog: failing);
    final project = await host.create('سجل');
    final runner = IntakeRunner(service: host, project: project);
    final result = await runner.run(sources(1));
    expect(result.importedCount, 1);
    expect(result.journeyWriteFailed, isTrue);
    expect(failing.attempts, 2);
    expect(runner.lastJourneys, hasLength(1));
    expect((await projects.get(project.id)).assets, hasLength(1));
  });

  test('transient journey failure is retried without warning', () async {
    final failing = _FailingJourneyLog(failures: 1);
    final host = ProjectService(projects, assets,
        imageEditor: LocalImageEditor(projects.files), journeyLog: failing);
    final project = await host.create('سجل');
    final result = await IntakeRunner(service: host, project: project).run(sources(1));
    expect(result.importedCount, 1);
    expect(result.journeyWriteFailed, isFalse);
    expect(failing.attempts, 2);
    expect(failing.saved, hasLength(1));
  });

}


class _FailingJourneyLog implements JourneyLog {
  _FailingJourneyLog({required this.failures});
  int failures;
  int attempts = 0;
  final saved = <ImageJourney>[];

  @override
  Future<void> append(Iterable<ImageJourney> journeys) async {
    attempts++;
    if (failures-- > 0) throw StateError('write failed');
    saved.addAll(journeys);
  }

  @override
  Future<void> clear() async => saved.clear();
  @override
  Future<List<ImageJourney>> read() async => saved;
  @override
  Future<JourneyLogStats> stats() async => JourneyLogStats(entries: saved.length, bytes: 0);
}
