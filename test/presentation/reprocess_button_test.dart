import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/safe_files.dart';

import 'editor_harness.dart';

/// The ribbon's **إعادة التعرف** button (key `rb-reprocess`), driven for real.
///
/// These tests exist because both reprocessing defects were REACHABLE ONLY
/// THROUGH THIS BUTTON: it hands the service every asset id in the project,
/// and it used to derive layout preservation from the automatic-flow setting.
/// The service-level suite (`test/application/reprocess_ui_path_test.dart`)
/// reproduces the button's argument list; this suite drives the button itself.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-reprocess-btn-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Region 0: an ID-1 shaped card.
  List<Point2> topQuad() => [
    Point2(.1, .1),
    Point2(.9, .1),
    Point2(.9, .6045),
    Point2(.1, .6045),
  ];

  /// Region 1: the ID-1 shape again, lower down.
  List<Point2> bottomQuad() => [
    Point2(.2, .62),
    Point2(.8, .62),
    Point2(.8, .9983),
    Point2(.2, .9983),
  ];

  Future<SegmentationResult> twoCards(Uint8List bytes) async =>
      SegmentationResult(
        multi: true,
        candidates: [
          SegmentCandidate(
            region: const [.1, .1, .9, .6],
            corners: topQuad(),
            detectionConfidence: .8,
            reason: 'component-support',
          ),
          SegmentCandidate(
            region: const [.2, .62, .8, 1],
            corners: bottomQuad(),
            detectionConfidence: .75,
            reason: 'component-support',
          ),
        ],
      );

  Uint8List photo() {
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

  /// Builds a real project: one photo of two cards, imported and arranged
  /// through the real service, then given a deliberate non-default layout.
  Future<Project> arrangedProject(MemoryProjects store) async {
    final files = SafeFiles(Directory(await root.resolveSymbolicLinks()));
    final service = ProjectService(
      store,
      LocalAssetRepository(files),
      imageEditor: LocalImageEditor(files),
      segmenter: twoCards,
    );
    var project = await service.create('زر إعادة التعرف');
    project = (await service.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(photo())),
    ])).project;
    project = (await service.arrangeImportedImages(project, [
      project.assets.single.id,
    ])).project;
    expect(project.items, hasLength(2));
    return store.save(
      project.copyWith(
        items: [
          project.items[0].copyWith(
            x: 10,
            y: 20,
            rotation: 90,
            zIndex: 7,
            locked: true,
          ),
          project.items[1].copyWith(x: 90, y: 10, rotation: 0, zIndex: 3),
        ],
      ),
    );
  }

  for (final autoFlow in [true, false]) {
    testWidgets('autoFlow = $autoFlow: the reprocess button refreshes without '
        'duplicating or rearranging', (tester) async {
      final store = MemoryProjects();
      final project = await arrangedProject(store);
      expect(project.assets, hasLength(3), reason: 'source + 2 derived');

      final beforeItems = {
        for (final item in project.items) item.id: item.toJson(),
      };
      final beforeRecordIds = project.documents.map((d) => d.id).toList();

      await EditorHarness.pump(
        tester,
        project: project,
        repository: store,
        segmenter: twoCards,
        assetRepository: LocalAssetRepository(
          SafeFiles(Directory(await root.resolveSymbolicLinks())),
        ),
        imageEditor: LocalImageEditor(
          SafeFiles(Directory(await root.resolveSymbolicLinks())),
        ),
      );

      // The controller starts with automatic flow ON (its documented
      // default); the ribbon's own toggle turns it off where required.
      await tapKey(tester, const Key('ribbon-tab-home'));
      if (!autoFlow) {
        // ترتيب مستمر — the ribbon's own automatic-flow toggle.
        await tapKey(tester, const Key('rb-autoflow'));
      }

      // The real button, on its real tab.
      await tapKey(tester, const Key('ribbon-tab-file'));
      expect(find.byKey(const Key('rb-reprocess')), findsOneWidget);
      await tapKey(tester, const Key('rb-reprocess'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final after = EditorHarness(store, project.id).saved;

      // Defect A: the button passes every asset id, derived crops included.
      // A derived crop must not be re-analysed as its own photograph.
      expect(after.documents, hasLength(2), reason: 'no duplicate records');
      expect(after.items, hasLength(2), reason: 'no duplicate items');
      expect(after.assets, hasLength(3), reason: 'no redundant assets');
      expect(
        after.documents.map((d) => d.id).toList(),
        beforeRecordIds,
        reason: 'the same records were refreshed in place',
      );

      // Defect B: layout preservation no longer depends on autoFlow.
      for (final item in after.items) {
        final before = beforeItems[item.id]!;
        for (final key in before.keys) {
          if (key == 'documentKind' || key == 'recognitionConfidence') {
            continue;
          }
          expect(
            item.toJson()[key],
            before[key],
            reason: '$key must not change (autoFlow = $autoFlow)',
          );
        }
      }
      // Recognition really did run: the derived crops were regenerated.
      for (final record in after.documents) {
        final previous = project.documents.firstWhere((d) => d.id == record.id);
        expect(
          record.sides.single.processedAsset.workingPath,
          isNot(previous.sides.single.processedAsset.workingPath),
          reason: 'the crop was regenerated',
        );
      }
    });
  }
}
