import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_recovery.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// Two ID-1-shaped quads in a 1000×1000 source, so the intake produces two
/// DERIVED assets (one per detected document) next to the original source.
List<Point2> _topQuad() => [
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .6045),
  Point2(.1, .6045),
];

Future<SegmentationResult> _twoCards(Uint8List bytes) async => SegmentationResult(
  multi: true,
  candidates: [
    SegmentCandidate(
      region: const [.1, .1, .9, .6],
      corners: _topQuad(),
      detectionConfidence: .8,
      reason: 'component-support',
    ),
    SegmentCandidate(
      region: const [.2, .62, .8, 1],
      corners: [
        Point2(.2, .62),
        Point2(.8, .62),
        Point2(.8, .9983),
        Point2(.2, .9983),
      ],
      detectionConfidence: .75,
      reason: 'component-support',
    ),
  ],
);

Uint8List _photo() {
  final source = img.Image(width: 1000, height: 1000);
  img.fill(source, color: img.ColorRgb8(50, 60, 75));
  img.fillRect(
    source,
    x1: 100,
    y1: 100,
    x2: 900,
    y2: 604,
    color: img.ColorRgb8(240, 238, 232),
  );
  img.fillRect(
    source,
    x1: 200,
    y1: 620,
    x2: 800,
    y2: 998,
    color: img.ColorRgb8(226, 230, 235),
  );
  return Uint8List.fromList(img.encodePng(source));
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late LocalImageEditor editor;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-derived-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    editor = LocalImageEditor(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  /// A project whose intake produced two derived assets from one photo.
  Future<Project> projectWithDerived() async {
    final service = ProjectService(
      projects,
      assets,
      imageEditor: editor,
      segmenter: _twoCards,
    );
    var project = await service.create('مستندات مشتقة');
    final bytes = _photo();
    project = (await service.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final report = await service.arrangeImportedImages(project, [
      project.assets.single.id,
    ]);
    expect(report.project.assets, hasLength(3), reason: 'source + 2 derived');
    return report.project;
  }

  /// The source photo: the asset the recognition records were derived from.
  ImageAsset sourceOf(Project project) => project.assets.firstWhere(
    (a) => project.documents.any((d) => d.sourceImageId == a.id),
  );

  List<ImageAsset> derivedOf(Project project) => [
    for (final record in project.documents)
      project.assets.firstWhere(
        (a) => a.workingPath == record.sides.single.processedAsset.workingPath,
      ),
  ];

  test(
    'a deleted derived working copy is rebuilt without touching the source',
    () async {
      final created = await projectWithDerived();
      final bytes = await (await assets.resolve(
        sourceOf(created).originalPath,
      )).readAsBytes();
      final derived = derivedOf(created);
      expect(derived, hasLength(2));

      final victim = derived.first;
      await (await assets.resolve(victim.workingPath)).delete();
      await (await assets.resolve(victim.thumbnailPath)).writeAsString('broken');

      // Reload from storage: the damage is on disk, not in the record.
      final reloaded = await projects.get(created.id);
      expect(reloaded.toJson(), created.toJson());

      final repaired = await LocalProjectRecovery(
        projects,
        editor,
      ).rebuildDerived(await projects.metadata(created.id));

      final fixed = repaired.assets.firstWhere((a) => a.id == victim.id);
      expect(fixed.workingPath, isNot(victim.workingPath));
      // The derived image is readable again...
      expect(
        img.decodePng(await (await assets.resolve(fixed.workingPath)).readAsBytes()),
        isNotNull,
      );
      // ...and the source photo is byte-identical to what was imported.
      expect(
        await (await assets.resolve(sourceOf(repaired).originalPath)).readAsBytes(),
        bytes,
      );
      // Layout and recognition truth are untouched by a file rebuild.
      expect(repaired.items.map((i) => i.id).toList(),
          created.items.map((i) => i.id).toList());
      expect(repaired.documents, hasLength(2));
      expect((await projects.get(created.id)).toJson(), repaired.toJson());
    },
  );

  test('a corrupt derived working copy is replaced, not silently kept', () async {
    final created = await projectWithDerived();
    final derived = derivedOf(created);
    final victim = derived.last;
    await (await assets.resolve(victim.workingPath)).writeAsString(
      'not a png at all',
    );

    final repaired = await LocalProjectRecovery(
      projects,
      editor,
    ).rebuildDerived(await projects.metadata(created.id));
    final fixed = repaired.assets.firstWhere((a) => a.id == victim.id);
    expect(fixed.workingPath, isNot(victim.workingPath));
    expect(
      img.decodePng(await (await assets.resolve(fixed.workingPath)).readAsBytes()),
      isNotNull,
    );
  });

  test(
    'a missing derived original aborts recovery without changing metadata',
    () async {
      final created = await projectWithDerived();
      final victim = derivedOf(created).first;
      await (await assets.resolve(victim.originalPath)).delete();

      final recovery = LocalProjectRecovery(projects, editor);
      await expectLater(
        recovery.rebuildDerived(await projects.metadata(created.id)),
        throwsA(isA<Object>()),
      );
      // The committed record is exactly as it was: nothing was invented or
      // half-applied by the failed rebuild.
      expect((await projects.metadata(created.id)).toJson(), created.toJson());
    },
  );

  test(
    'an unreadable source original aborts recovery and keeps the photo safe',
    () async {
      final created = await projectWithDerived();
      final source = sourceOf(created);
      final original = await assets.resolve(source.originalPath);
      final bytes = await original.readAsBytes();
      // Simulate an unreadable file (permissions are unreliable on Windows and
      // in sandboxes, so replace the content with undecodable bytes).
      await original.writeAsBytes(Uint8List.fromList([0x00, 0x01, 0x02]));

      final recovery = LocalProjectRecovery(projects, editor);
      await expectLater(
        recovery.rebuildDerived(await projects.metadata(created.id)),
        throwsA(isA<Object>()),
      );
      expect((await projects.metadata(created.id)).toJson(), created.toJson());
      // The derived assets that were fine are still readable.
      for (final derived in derivedOf(created)) {
        expect(
          img.decodePng(
            await (await assets.resolve(derived.workingPath)).readAsBytes(),
          ),
          isNotNull,
        );
      }
      // Restoring the original makes recovery possible again.
      await original.writeAsBytes(bytes);
      final repaired = await recovery.rebuildDerived(
        await projects.metadata(created.id),
      );
      expect(repaired.assets, hasLength(3));
      expect(
        await (await assets.resolve(source.originalPath)).readAsBytes(),
        bytes,
      );
    },
  );

  test('repeated rebuilds keep the project semantically identical', () async {
    final created = await projectWithDerived();
    final recovery = LocalProjectRecovery(projects, editor);
    final first = await recovery.rebuildDerived(
      await projects.metadata(created.id),
    );
    final second = await recovery.rebuildDerived(
      await projects.metadata(created.id),
    );
    // Every rebuild writes NEW revision files and never overwrites an earlier
    // one, so paths differ — but the project means the same thing.
    expect(second.items.map((i) => i.id).toList(),
        first.items.map((i) => i.id).toList());
    expect(second.documents.map((d) => d.id).toList(),
        first.documents.map((d) => d.id).toList());
    expect(second.assets, hasLength(3));
    for (final asset in second.assets) {
      expect(
        img.decodePng(
          await (await assets.resolve(asset.workingPath)).readAsBytes(),
        ),
        isNotNull,
      );
    }
  });
}
