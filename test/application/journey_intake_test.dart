import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
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

  List<ImportSource> sources(
    int count, {
    List<int> broken = const [],
  }) => [
    for (var i = 0; i < count; i++)
      ImportSource(
        'صورة$i.png',
        broken.contains(i)
            ? () => Stream<List<int>>.value(Uint8List.fromList([1, 2, 3]))
            : () => Stream<List<int>>.value(bytes()),
      ),
  ];

  test('an intake files one report per image, from the picker to the save',
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
  });

  test('a broken source is reported as not imported, and the next image still '
      'gets its own report', () async {
    final project = await service.create('سجل');
    final runner = IntakeRunner(service: service, project: project);
    final run = await runner.run(sources(2, broken: [0]));

    expect(run.failures, hasLength(1));
    final stored = await log.read();
    expect(stored.map((entry) => entry.imageName), ['صورة0.png', 'صورة1.png']);
    final refused = stored.firstWhere((entry) => entry.imageName == 'صورة0.png');
    final imported = stored.firstWhere(
      (entry) => entry.imageName == 'صورة1.png',
    );
    expect(refused.imported, isFalse);
    expect(refused.steps.any((step) => step.stage == JourneyStage.copy &&
        step.outcome == JourneyOutcome.blocked), isTrue);
    expect(imported.imported, isTrue);
  });

  test('a host with no log still imports normally', () async {
    final plain = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      smartRecognitionEnabled: true,
    );
    final project = await plain.create('بلا سجل');
    final run = await IntakeRunner(service: plain, project: project).run(
      sources(1),
    );

    expect(run.importedCount, 1);
    expect(await log.read(), isEmpty);
  });
}
