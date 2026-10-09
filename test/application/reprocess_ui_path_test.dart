import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart' as rec;
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

// ---------------------------------------------------------------------------
// Fixtures
//
// The photo and the segmenters mirror the ones in reprocess_test.dart so both
// suites describe the same product behaviour. They are duplicated rather than
// shared so each suite stays readable on its own.
// ---------------------------------------------------------------------------

/// Region 0: an ID-1 shaped card.
List<Point2> _topQuad() => [
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .6045),
  Point2(.1, .6045),
];

/// Region 1: the ID-1 shape again, lower down.
List<Point2> _bottomQuad() => [
  Point2(.2, .62),
  Point2(.8, .62),
  Point2(.8, .9983),
  Point2(.2, .9983),
];

/// Region 2: a third card, only present when the analysis improves.
List<Point2> _thirdQuad() => [
  Point2(.05, .05),
  Point2(.45, .05),
  Point2(.45, .3335),
  Point2(.05, .3335),
];

/// Two regions: the top one resolves, the bottom one does not.
Future<SegmentationResult> _oneUnresolved(Uint8List bytes) async =>
    SegmentationResult(
      multi: true,
      candidates: [
        SegmentCandidate(
          region: const [.1, .1, .9, .6],
          corners: _topQuad(),
          detectionConfidence: .8,
          reason: 'component-support',
        ),
        const SegmentCandidate(
          region: [.2, .62, .8, 1],
          reason: 'no-trustworthy-quad',
        ),
      ],
    );

/// The same two regions, both resolved.
Future<SegmentationResult> _bothResolved(Uint8List bytes) async =>
    SegmentationResult(
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
          corners: _bottomQuad(),
          detectionConfidence: .75,
          reason: 'component-support',
        ),
      ],
    );

/// Three regions: the first two unchanged, plus a newly detected one.
Future<SegmentationResult> _threeResolved(Uint8List bytes) async =>
    SegmentationResult(
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
          corners: _bottomQuad(),
          detectionConfidence: .75,
          reason: 'component-support',
        ),
        SegmentCandidate(
          region: const [.05, .05, .45, .34],
          corners: _thirdQuad(),
          detectionConfidence: .7,
          reason: 'component-support',
        ),
      ],
    );

/// A source of two ID-1 shaped cards on a plain background.
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

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-reprocess-ui-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ProjectService service({
    Future<SegmentationResult> Function(Uint8List bytes)? segmenter,
  }) => ProjectService(
    projects,
    assets,
    imageEditor: LocalImageEditor(projects.files),
    segmenter: segmenter,
  );

  /// EXACTLY the argument list the ribbon button builds —
  /// `lib/presentation/layout_screen.dart`, key `rb-reprocess`:
  ///
  ///     () => c.reprocessImages([for (final asset in project.assets) asset.id])
  ///
  /// Using this construction is the point of the suite: it is what the user
  /// actually triggers, and it hands the service EVERY asset, derived crops
  /// included.
  List<String> uiAssetIds(Project project) => [
    for (final asset in project.assets) asset.id,
  ];

  Future<Project> importAndArrange(
    Uint8List bytes, {
    required Future<SegmentationResult> Function(Uint8List) segmenter,
  }) async {
    final s = service(segmenter: segmenter);
    var project = await s.create('مسار الواجهة');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    return (await s.arrangeImportedImages(project, [
      project.assets.single.id,
    ])).project;
  }

  /// The exhaustive layout fingerprint of one item.
  ///
  /// Reprocessing may refresh `documentKind` and `recognitionConfidence` and
  /// nothing else; every other key is the user's layout or the document's
  /// identity and must survive unchanged.
  void expectOnlyRecognitionFieldsDiffer(
    DocumentItem before,
    DocumentItem after,
  ) {
    final b = before.toJson();
    final a = after.toJson();
    expect(
      a.keys,
      unorderedEquals(b.keys),
      reason: 'item shape must not change',
    );
    for (final key in b.keys) {
      if (key == 'documentKind' || key == 'recognitionConfidence') continue;
      expect(a[key], b[key], reason: 'layout field $key must not change');
    }
    // Named again for the fields the audit calls out, so a failure names the
    // property rather than only a JSON key.
    expect(after.id, before.id, reason: 'layout-item identity');
    expect(after.assetId, before.assetId, reason: 'asset link');
    expect(after.documentId, before.documentId, reason: 'document link');
    expect(after.sideId, before.sideId, reason: 'side link');
    expect(after.pageIndex, before.pageIndex, reason: 'page assignment');
    expect(after.x, before.x, reason: 'x position');
    expect(after.y, before.y, reason: 'y position');
    expect(after.width, before.width, reason: 'width / printed footprint');
    expect(after.height, before.height, reason: 'height / printed footprint');
    expect(after.rotation, before.rotation, reason: 'rotation');
    expect(after.zIndex, before.zIndex, reason: 'z order');
    expect(after.locked, before.locked, reason: 'lock state');
    expect(after.groupId, before.groupId, reason: 'grouping');
    expect(after.sizeConfirmed, before.sizeConfirmed, reason: 'confirmed size');
  }

  group('Defect A — the full asset list must not duplicate documents', () {
    test(
      'reprocessing every asset of a two-document photo keeps both documents',
      () async {
        final first = await importAndArrange(
          _photo(),
          segmenter: _bothResolved,
        );

        // One source photo plus one derived crop per region.
        expect(first.assets, hasLength(3));
        expect(first.documents, hasLength(2));
        expect(first.items, hasLength(2));

        final recordIds = first.documents.map((d) => d.id).toList();
        final itemIds = first.items.map((i) => i.id).toList();
        final assetIds = first.assets.map((a) => a.id).toList();

        // The button passes all three ids, derived crops included.
        final result = (await service(
          segmenter: _bothResolved,
        ).reprocessImages(first, uiAssetIds(first)))!.project;

        // A derived crop is a PRODUCT of its source, not a new photograph.
        // Treating it as one re-detects the card inside the crop and appends
        // it again: two documents would become four.
        expect(result.documents, hasLength(2), reason: 'no duplicate records');
        expect(result.items, hasLength(2), reason: 'no duplicate layout items');
        expect(result.assets, hasLength(3), reason: 'no redundant assets');
        expect(result.documents.map((d) => d.id).toList(), recordIds);
        expect(result.items.map((i) => i.id).toList(), itemIds);
        expect(result.assets.map((a) => a.id).toList(), assetIds);

        // The source photo is still the source of both records.
        for (final record in result.documents) {
          expect(record.sourceImageId, first.assets.first.id);
          expect(record.provenance.sourceImageId, first.assets.first.id);
        }
        expect(
          (await projects.get(result.id)).toJson(),
          result.toJson(),
          reason: 'the result is exactly what was committed',
        );
      },
    );

    test('reprocessing twice is idempotent', () async {
      final first = await importAndArrange(_photo(), segmenter: _bothResolved);
      final recordIds = first.documents.map((d) => d.id).toList();
      final itemIds = first.items.map((i) => i.id).toList();

      final once = (await service(
        segmenter: _bothResolved,
      ).reprocessImages(first, uiAssetIds(first)))!.project;
      final twice = (await service(
        segmenter: _bothResolved,
      ).reprocessImages(once, uiAssetIds(once)))!.project;

      // Counts never grow on a repeated run over unchanged sources.
      expect(twice.documents, hasLength(2));
      expect(twice.items, hasLength(2));
      expect(twice.assets, hasLength(3));
      expect(twice.documents.map((d) => d.id).toList(), recordIds);
      expect(twice.items.map((i) => i.id).toList(), itemIds);

      // The second run changes no layout either.
      for (final before in once.items) {
        final after = twice.items.firstWhere((i) => i.id == before.id);
        expectOnlyRecognitionFieldsDiffer(before, after);
      }
    });

    test(
      'an unresolved region is kept and can be resolved by a later retry',
      () async {
        final first = await importAndArrange(
          _photo(),
          segmenter: _oneUnresolved,
        );

        // Both measured regions became documents: one resolved, one kept as a
        // reviewable region crop. Nothing was silently dropped.
        expect(first.documents, hasLength(2));
        expect(first.items, hasLength(2));
        final unresolved = first.documents.firstWhere(
          (d) => d.sides.single.detection!.polygon == null,
        );

        // A better analysis finds the boundary it missed — through the same
        // full-asset-list path the button uses.
        final result = (await service(
          segmenter: _bothResolved,
        ).reprocessImages(first, uiAssetIds(first)))!.project;

        expect(result.documents, hasLength(2), reason: 'updated, not appended');
        expect(result.items, hasLength(2));
        expect(result.assets, hasLength(3));
        expect(result.documents.map((d) => d.id), contains(unresolved.id));
        final fixed = result.documents.firstWhere((d) => d.id == unresolved.id);
        expect(
          fixed.sides.single.detection!.polygon,
          isNotNull,
          reason: 'the region is now resolved in the SAME record',
        );
        // The region's own identity never changed.
        expect(
          fixed.sides.single.detection!.detectionId,
          unresolved.sides.single.detection!.detectionId,
        );
      },
    );

    test('a genuinely new region adds exactly one document', () async {
      final first = await importAndArrange(_photo(), segmenter: _bothResolved);
      final recordIds = first.documents.map((d) => d.id).toList();

      final result = (await service(
        segmenter: _threeResolved,
      ).reprocessImages(first, uiAssetIds(first)))!.project;

      expect(result.documents, hasLength(3));
      expect(result.items, hasLength(3));
      expect(result.assets, hasLength(4), reason: 'one new derived asset');
      // The two existing records were refreshed, never replaced.
      expect(result.documents.map((d) => d.id).toSet(), containsAll(recordIds));
      // Exactly one document per region: no region matched twice.
      final regionIds = result.documents
          .map((d) => d.sides.single.detection!.detectionId)
          .toList();
      expect(regionIds.toSet(), hasLength(3));
    });

    test('a missing derived asset is rebuilt, not duplicated', () async {
      final first = await importAndArrange(_photo(), segmenter: _bothResolved);
      final victim = first.assets.firstWhere(
        (a) => a.id != first.assets.first.id,
      );
      await (await assets.resolve(victim.workingPath)).delete();

      final report = await service(
        segmenter: _bothResolved,
      ).reprocessImages(first, uiAssetIds(first));

      // The record survives, its crop is regenerated, and nothing duplicates.
      expect(report!.project.documents, hasLength(2));
      expect(report.project.items, hasLength(2));
      expect(report.project.assets, hasLength(3));
      expect(
        report.project.documents.map((d) => d.id).toList(),
        first.documents.map((d) => d.id).toList(),
      );
      final restored = report.project.assets.firstWhere(
        (a) => a.id == victim.id,
      );
      expect(
        restored.workingPath,
        isNot(victim.workingPath),
        reason: 'the crop was regenerated',
      );
      expect(
        await (await assets.resolve(restored.workingPath)).exists(),
        isTrue,
      );
      // The source photo was never destroyed.
      expect(
        await (await assets.resolve(
          first.assets.first.originalPath,
        )).readAsBytes(),
        isNotEmpty,
      );
    });

    test(
      'an unreadable source original is reported and the project survives',
      () async {
        final first = await importAndArrange(
          _photo(),
          segmenter: _bothResolved,
        );
        await (await assets.resolve(first.assets.first.originalPath)).delete();

        final report = await service(
          segmenter: _bothResolved,
        ).reprocessImages(first, uiAssetIds(first));

        expect(report!.warnings, isNotEmpty);
        expect(report.notDetected, 1);
        // Nothing was deleted or duplicated by the failure.
        expect(report.project.documents, hasLength(2));
        expect(report.project.items, hasLength(2));
        expect(
          report.project.documents.map((d) => d.id).toList(),
          first.documents.map((d) => d.id).toList(),
        );
      },
    );

    test(
      'user overrides survive and are reported, never overwritten',
      () async {
        var first = await importAndArrange(_photo(), segmenter: _bothResolved);
        final itemId = first.items.last.id;
        final recordId = first.items.last.documentId!;
        first = await projects.save(
          rec.setKindWithOverride(first, itemId, DocumentKind.passport),
        );
        expect(
          first.documents.firstWhere((d) => d.id == recordId).overrides,
          isNotEmpty,
        );

        final report = await service(
          segmenter: _bothResolved,
        ).reprocessImages(first, uiAssetIds(first));

        final kept = report!.project.documents.firstWhere(
          (d) => d.id == recordId,
        );
        expect(
          kept.overrides,
          isNotEmpty,
          reason: 'ADR-004: the decision stays',
        );
        expect(kept.recognition!.documentKind, DocumentKind.passport);
        expect(report.warnings.join('\n'), contains('تُرِك'));
        // Still no duplicates.
        expect(report.project.documents, hasLength(2));
        expect(report.project.items, hasLength(2));
      },
    );

    test('side-paired documents keep their pairing', () async {
      var first = await importAndArrange(_photo(), segmenter: _bothResolved);
      final a = first.documents[0];
      final b = first.documents[1];
      first = await projects.save(
        first.copyWith(
          documents: [
            a.copyWith(pairing: PairingState.paired, pairedDocumentId: b.id),
            b.copyWith(pairing: PairingState.paired, pairedDocumentId: a.id),
          ],
        ),
      );

      final result = (await service(
        segmenter: _bothResolved,
      ).reprocessImages(first, uiAssetIds(first)))!.project;

      // The reciprocal pair still resolves in both directions.
      expect(result.documents, hasLength(2));
      final afterA = result.documents.firstWhere((d) => d.id == a.id);
      final afterB = result.documents.firstWhere((d) => d.id == b.id);
      expect(afterA.pairing, PairingState.paired);
      expect(afterB.pairing, PairingState.paired);
      expect(afterA.pairedDocumentId, b.id);
      expect(afterB.pairedDocumentId, a.id);
      // A pair is never merged into one document.
      expect(
        result.documents
            .map((d) => d.sides.single.detection!.detectionId)
            .toSet(),
        hasLength(2),
      );
    });

    test(
      'a cancelled run followed by a normal run leaves no duplicates',
      () async {
        final first = await importAndArrange(
          _photo(),
          segmenter: _bothResolved,
        );

        final cancelled = await service(segmenter: _bothResolved)
            .reprocessImages(
              first,
              uiAssetIds(first),
              cancellation: CancellationToken()..cancel(),
            );
        expect(cancelled!.project.revision, first.revision);
        expect(cancelled.warnings.join('\n'), contains('أُلغيت'));

        // The retry after a cancellation is clean: no residue, no duplicates.
        final result = (await service(segmenter: _bothResolved).reprocessImages(
          cancelled.project,
          uiAssetIds(cancelled.project),
        ))!.project;
        expect(result.documents, hasLength(2));
        expect(result.items, hasLength(2));
        expect(result.assets, hasLength(3));
      },
    );
  });

  group('Defect B — reprocessing must never rearrange the layout', () {
    /// A deliberate, non-default layout: distinct positions, a rotation, a
    /// lock, a real layout group and an explicit z order.
    Future<Project> withNontrivialLayout(Project project) async {
      final items = project.items.toList();
      expect(items.length, greaterThanOrEqualTo(2));
      final rearranged = <DocumentItem>[
        items[0].copyWith(x: 10, y: 20, rotation: 90, zIndex: 7, locked: true),
        items[1].copyWith(x: 90, y: 10, rotation: 0, zIndex: 3, locked: false),
        ...items.skip(2),
      ];
      return projects.save(
        project.copyWith(
          items: [
            for (final item in rearranged) item.copyWith(groupId: 'group-a'),
          ],
          layoutGroups: [
            LayoutGroup(id: 'group-a', itemIds: [items[0].id, items[1].id]),
          ],
        ),
      );
    }

    // The reprocess entry point no longer takes a keepPlaced flag at all, so
    // there is exactly ONE behaviour to test — which is the fix: preserving
    // the sheet can no longer depend on the automatic-flow setting. Both flow
    // modes are asserted to produce the same, preserving, result.
    for (final autoFlow in [true, false]) {
      test('autoFlow = $autoFlow: existing layout is preserved', () async {
        final arranged = await importAndArrange(
          _photo(),
          segmenter: _bothResolved,
        );
        final first = await withNontrivialLayout(arranged);
        expect(first.items, hasLength(2));
        // The layout really is non-default before reprocessing.
        expect(first.items.first.rotation, 90);
        expect(first.items.first.locked, isTrue);
        expect(first.items.first.groupId, 'group-a');

        // autoFlow only ever reached the service as `keepPlaced: !autoFlow`.
        // With that parameter gone the call is identical in both modes, and
        // this is exactly the call the controller makes.
        final result = (await service(
          segmenter: _bothResolved,
        ).reprocessImages(first, uiAssetIds(first)))!.project;

        expect(result.items, hasLength(2));
        for (final before in first.items) {
          final after = result.items.firstWhere((i) => i.id == before.id);
          expectOnlyRecognitionFieldsDiffer(before, after);
        }
        // A locked item is left completely alone, recognition included.
        final lockedBefore = first.items.firstWhere((i) => i.locked);
        final lockedAfter = result.items.firstWhere(
          (i) => i.id == lockedBefore.id,
        );
        expect(lockedAfter.toJson(), lockedBefore.toJson());
        // Page count, paper and groups are untouched.
        expect(result.pageCount, first.pageCount);
        expect(result.paper.toJson(), first.paper.toJson());
        expect(result.layoutGroups.map((g) => g.id).toList(), ['group-a']);
      });

      test(
        'autoFlow = $autoFlow: repeating reprocessing never re-arranges',
        () async {
          final arranged = await importAndArrange(
            _photo(),
            segmenter: _bothResolved,
          );
          final first = await withNontrivialLayout(arranged);

          final once = (await service(
            segmenter: _bothResolved,
          ).reprocessImages(first, uiAssetIds(first)))!.project;
          final twice = (await service(
            segmenter: _bothResolved,
          ).reprocessImages(once, uiAssetIds(once)))!.project;

          // No implicit full arrangement: the second run moves nothing.
          for (final before in once.items) {
            final after = twice.items.firstWhere((i) => i.id == before.id);
            expectOnlyRecognitionFieldsDiffer(before, after);
          }
          expect(twice.pageCount, once.pageCount);
        },
      );
    }

    test('a substantially changed recognized size does not resize or move a '
        'placed item', () async {
      final arranged = await importAndArrange(
        _photo(),
        segmenter: _bothResolved,
      );
      // Give one placed document a size that differs from the catalog size
      // the next recognition will report, plus a deliberate position.
      final target = arranged.items.first;
      final resized = await projects.save(
        arranged.copyWith(
          items: [
            for (final item in arranged.items)
              if (item.id == target.id)
                item.copyWith(x: 10, y: 20, width: 120, height: 80)
              else
                item,
          ],
        ),
      );
      expect(resized.items.firstWhere((i) => i.id == target.id).width, 120);

      final report = await service(
        segmenter: _bothResolved,
      ).reprocessImages(resized, uiAssetIds(resized));

      final after = report!.project.items.firstWhere((i) => i.id == target.id);
      // Kept where and how large the user has it — not silently resized.
      expect(after.pageIndex, target.pageIndex);
      expect(after.x, 10);
      expect(after.y, 20);
      expect(after.width, 120, reason: 'printed footprint is the user layout');
      expect(after.height, 80);
      expect(after.sizeConfirmed, isTrue);
      // …and the conflict is reported instead of applied.
      expect(
        report.warnings.join('\n'),
        contains('بقي المستند بموضعه وحجمه الحالي'),
      );
      // Recognition still refreshed the derived image and the kind.
      final record = report.project.documents.firstWhere(
        (d) => d.id == target.documentId,
      );
      expect(
        record.sides.single.processedAsset.workingPath,
        isNot(
          arranged.documents
              .firstWhere((d) => d.id == target.documentId)
              .sides
              .single
              .processedAsset
              .workingPath,
        ),
        reason: 'the crop was still regenerated',
      );
    });

    test('a new document is placed; existing ones are not moved', () async {
      final arranged = await importAndArrange(
        _photo(),
        segmenter: _bothResolved,
      );
      final first = await withNontrivialLayout(arranged);
      final beforeIds = first.items.map((i) => i.id).toList();

      final result = (await service(
        segmenter: _threeResolved,
      ).reprocessImages(first, uiAssetIds(first)))!.project;

      expect(result.items, hasLength(3));
      for (final before in first.items) {
        final after = result.items.firstWhere((i) => i.id == before.id);
        expectOnlyRecognitionFieldsDiffer(before, after);
      }
      // The newly discovered document is the only one that gets a placement.
      final added = result.items.firstWhere((i) => !beforeIds.contains(i.id));
      expect(added.pageIndex, isNotNull, reason: 'new documents are placed');
      expect(added.documentId, isNotNull);
      expect(result.pageCount, first.pageCount);
    });
  });
}
