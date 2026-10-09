import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/intake.dart';

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late ProjectService service;

  Uint8List bytes() =>
      Uint8List.fromList(img.encodePng(img.Image(width: 120, height: 90)));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_intake_');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
    );
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  List<ImportSource> sources(
    int count, {
    List<bool> broken = const [],
    List<int> cleaned = const [],
  }) => [
    for (var i = 0; i < count; i++)
      ImportSource(
        'صورة$i.png',
        broken.contains(i)
            ? () => Stream<List<int>>.value(Uint8List.fromList([1, 2, 3]))
            : () => Stream<List<int>>.value(bytes()),
        cleanup: cleaned.contains(i) ? () async {} : null,
      ),
  ];

  test(
    'import progress counts real committed work, one step per source',
    () async {
      final project = await service.create('تقدم');
      final seen = <int>[];
      final report = await service.importImages(
        project,
        sources(3),
        onProgress: (BatchProgress progress) {
          expect(progress.total, 3);
          expect(progress.stage, importStageLabel);
          seen.add(progress.completed);
        },
      );
      expect(report.imported, 3);
      // One emission before the first source and one after each finished
      // source: the count always reflects committed work, never a timer.
      expect(seen, [0, 1, 2, 3]);
    },
  );

  test(
    'cancellation keeps committed images and never opens the rest',
    () async {
      final project = await service.create('إلغاء');
      final token = CancellationToken();
      final opened = <int>[];
      var released = 0;
      final picked = <ImportSource>[
        for (var i = 0; i < 4; i++)
          ImportSource(
            'صورة$i.png',
            () {
              opened.add(i);
              return Stream<List<int>>.value(bytes());
            },
            cleanup: () async {
              released++;
            },
          ),
      ];
      final report = await service.importImages(
        project,
        picked,
        cancellation: token,
        onProgress: (progress) {
          // Cancel as soon as the first image has been committed: the stop is
          // cooperative and takes effect before the next source is opened.
          if (progress.completed == 1) token.cancel();
        },
      );
      expect(opened, [0], reason: 'sources after the cancel are never opened');
      expect(report.imported, 1);
      expect(report.failures, hasLength(3));
      for (final failure in report.failures) {
        expect(failure.message, contains('أُلغيت'));
      }
      // No leaked picker cache: every source that was not imported is released.
      expect(released, 4);
      // Persistence is consistent: exactly one committed asset, reloadable.
      final saved = await projects.get(project.id);
      expect(saved.assets, hasLength(1));
      expect(saved.toJson(), report.project.toJson());
      expect(saved.assets.single.name, 'صورة0.png');
    },
  );

  test('cancelling before the first source imports nothing', () async {
    final project = await service.create('إلغاء مبكر');
    final token = CancellationToken()..cancel();
    var opened = 0;
    final picked = <ImportSource>[
      for (var i = 0; i < 2; i++)
        ImportSource('صورة$i.png', () {
          opened++;
          return Stream<List<int>>.value(bytes());
        }),
    ];
    final report = await service.importImages(
      project,
      picked,
      cancellation: token,
    );
    expect(opened, 0);
    expect(report.imported, 0);
    expect(report.failures, hasLength(2));
    // Nothing was saved, so the revision is untouched.
    expect(report.project.revision, project.revision);
    expect((await projects.get(project.id)).assets, isEmpty);
  });

  test(
    'a partial failure keeps the good images and reports the bad one',
    () async {
      final project = await service.create('فشل جزئي');
      final report = await service.importImages(
        project,
        sources(3, broken: [1]),
      );
      expect(report.imported, 2);
      expect(report.failures, hasLength(1));
      expect(report.failures.single.name, 'صورة1.png');
      final saved = await projects.get(project.id);
      expect(saved.assets, hasLength(2));
      expect(saved.toJson(), report.project.toJson());
    },
  );

  // ---------------------------------------------------------------------
  // The shared runner used by BOTH entry points

  test('the shared runner imports and arranges with real progress', () async {
    final project = await service.create('مُشغّل');
    final seen = <String>[];
    final run = await IntakeRunner(service: service, project: project).run(
      sources(2),
      onProgress: (progress) =>
          seen.add('${progress.stage}/${progress.completed}/${progress.total}'),
    );
    expect(run.import.imported, 2);
    expect(run.error, isNull);
    expect(run.layout, isNotNull);
    expect(run.project.assets, hasLength(2));
    // Both phases report: copying first, then analysing the new images.
    expect(seen.first, startsWith('$importStageLabel/'));
    expect(seen.any((entry) => entry.startsWith('تحليل الصور/')), isTrue);
    expect(run.project.toJson(), (await projects.get(project.id)).toJson());
  });

  test('a cancelled runner leaves a committed, reloadable project', () async {
    final project = await service.create('مُشغّل مُلغى');
    final runner = IntakeRunner(service: service, project: project);
    final run = await runner.run(
      sources(3),
      onProgress: (progress) {
        if (progress.completed == 1) runner.cancel();
      },
    );
    expect(run.import.imported, 1);
    expect(run.layout, isNull, reason: 'analysis never started');
    expect(run.project.assets, hasLength(1));
    expect(run.project.toJson(), (await projects.get(project.id)).toJson());
  });

  test('a runner over an empty selection changes nothing', () async {
    final project = await service.create('فارغ');
    final run = await IntakeRunner(
      service: service,
      project: project,
    ).run(const []);
    expect(run.import.imported, 0);
    expect(run.project.revision, project.revision);
    expect(run.layout, isNull);
  });
}
