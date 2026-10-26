/// The document-kind classification path, kept SEPARATE from the question of
/// whether a region is a usable document candidate.
///
/// These tests separate the catalog's physical-size presets from document-kind
/// classification. Image dimensions and boundary aspect can validate a size
/// only after an independent kind is known; neither can create a kind. With no
/// OCR/visual classifier in this build, automated results remain `unknown` and
/// retain a measured, editable size.
///
/// The segmenter is injected here on purpose: these tests are about
/// classification and size confirmation, not about segmentation. Segmenter
/// behaviour over real pixels is covered by
/// `test/imaging/document_segmenter_gate_test.dart` and
/// `test/application/false_positive_document_test.dart`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/quad_assessment.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

final _paper = img.ColorRgb8(240, 238, 232);

Uint8List _photo(List<List<int>> rects) {
  final source = img.Image(width: 1000, height: 1000);
  img.fill(source, color: img.ColorRgb8(50, 60, 75));
  for (final rect in rects) {
    img.fillRect(
      source,
      x1: rect[0],
      y1: rect[1],
      x2: rect[2],
      y2: rect[3],
      color: _paper,
    );
  }
  return Uint8List.fromList(img.encodePng(source));
}

/// Synthetic portrait geometry, 150 × 828 px (aspect 5.520). This deliberately
/// resembles a catalog aspect for boundary/size-validation tests; it is not a
/// document-kind label or ground-truth sample.
List<Point2> _portraitQuad() => [
  Point2(.4, .08),
  Point2(.55, .08),
  Point2(.55, .908),
  Point2(.4, .908),
];

/// The same quad held on its side.
List<Point2> _landscapeQuad() => [
  Point2(.08, .4),
  Point2(.908, .4),
  Point2(.908, .55),
  Point2(.08, .55),
];

/// Synthetic 320 × 200 px geometry (aspect 1.600), near one catalog aspect.
/// This is not a label or a real-document accuracy fixture.
List<Point2> _wideQuad() => [
  Point2(.06, .1),
  Point2(.38, .1),
  Point2(.38, .3),
  Point2(.06, .3),
];

/// Region bounds carrying the synthetic 8 % margin around a quad. The measured
/// aspects are used only to exercise geometry and size-validation paths.
List<double> _regionOf(List<Point2> quad) {
  final xs = quad.map((p) => p.x).toList();
  final ys = quad.map((p) => p.y).toList();
  final mx =
      (xs.reduce((a, b) => a > b ? a : b) -
          xs.reduce((a, b) => a < b ? a : b)) *
      .08;
  final my =
      (ys.reduce((a, b) => a > b ? a : b) -
          ys.reduce((a, b) => a < b ? a : b)) *
      .08;
  return [
    (xs.reduce((a, b) => a < b ? a : b) - mx).clamp(0.0, 1.0),
    (ys.reduce((a, b) => a < b ? a : b) - my).clamp(0.0, 1.0),
    (xs.reduce((a, b) => a > b ? a : b) + mx).clamp(0.0, 1.0),
    (ys.reduce((a, b) => a > b ? a : b) + my).clamp(0.0, 1.0),
  ];
}

SegmentCandidate _candidate(List<Point2> quad, {double confidence = .8}) =>
    SegmentCandidate(
      region: _regionOf(quad),
      corners: quad,
      detectionConfidence: confidence,
      reason: 'component-support',
    );

/// A region whose boundary could NOT be resolved: measured bounds, no corners.
SegmentCandidate _unresolved(List<Point2> quad) =>
    SegmentCandidate(region: _regionOf(quad), reason: 'no-trustworthy-quad');

/// Two synthetic measured regions; the first can be unresolved while the
/// second remains valid. Neither region has a document-kind label.
Future<SegmentationResult> Function(Uint8List) _twoQuads({
  required bool firstResolved,
}) =>
    (Uint8List bytes) async => SegmentationResult(
      multi: true,
      candidates: [
        firstResolved
            ? _candidate(_portraitQuad())
            : _unresolved(_portraitQuad()),
        _candidate(_wideQuad()),
      ],
    );

/// Two synthetic quads with catalog-like aspects. They exercise the geometric
/// boundary/size paths only; their dimensions do not supply class evidence.
Future<SegmentationResult> _twoShapeFixtures(Uint8List bytes) async =>
    SegmentationResult(
      multi: true,
      candidates: [
        _candidate([
          Point2(.05, .2),
          Point2(.95, .2),
          Point2(.95, .746),
          Point2(.05, .746),
        ]),
        _candidate([
          Point2(.1, .8),
          Point2(.385, .8),
          Point2(.385, .98),
          Point2(.1, .98),
        ]),
      ],
    );

void main() {
  group('catalog dimensions and orientation semantics', () {
    test('the ration card is stored portrait, 52 × 287 mm', () {
      const size = DocumentSizeCatalog.defaultRationCard;
      expect(size.width, 52);
      expect(size.height, 287);
      expect(size.isLandscape, isFalse, reason: 'a tall paper card');
      // The shape match is orientation-independent: long / short.
      expect(size.aspect, closeTo(287 / 52, 1e-9));
      expect(size.aspect, greaterThan(size.width / size.height));
    });

    test('sizes turn to the orientation of the crop, never get edited', () {
      const catalog = DocumentSizeCatalog();
      final portrait = catalog.sizeFor(
        DocumentKind.rationCard,
        landscape: false,
      )!;
      expect([portrait.width, portrait.height], [52, 287]);
      final landscape = catalog.sizeFor(
        DocumentKind.rationCard,
        landscape: true,
      )!;
      expect([landscape.width, landscape.height], [287, 52]);
      // Turning is a rotation of the same entry, not a different size.
      // Compared field by field: PhysicalSizeMm deliberately has no
      // `operator ==` (it offers `sameAs`), so an instance comparison here
      // would be an identity check that passes or fails on const
      // canonicalization rather than on the value under test.
      expect(
        [landscape.width, landscape.height],
        [portrait.height, portrait.width],
      );
      expect(landscape.aspect, closeTo(portrait.aspect, 1e-9));

      final card = catalog.sizeFor(
        DocumentKind.unifiedNationalId,
        landscape: false,
      )!;
      expect([card.width, card.height], [53.98, 85.6]);
      final cardUpright = catalog.sizeFor(
        DocumentKind.unifiedNationalId,
        landscape: true,
      )!;
      expect(
        [cardUpright.width, cardUpright.height],
        [
          DocumentSizeCatalog.unifiedNationalId.width,
          DocumentSizeCatalog.unifiedNationalId.height,
        ],
      );
      // The stored defaults are untouched by any of this.
      final naturalRation = catalog.natural(DocumentKind.rationCard)!;
      expect([naturalRation.width, naturalRation.height], [52, 287]);
      expect(naturalRation.isLandscape, isFalse);
    });

    test('turning a crop changes only preset orientation, never its kind', () {
      const catalog = DocumentSizeCatalog();
      for (final kind in const [
        DocumentKind.unifiedNationalId,
        DocumentKind.residenceCard,
        DocumentKind.passport,
        DocumentKind.rationCard,
      ]) {
        final natural = catalog.natural(kind)!;
        final long = (natural.aspect * 1000).round();
        final uprightIsWide = natural.isLandscape;
        final uprightWidth = uprightIsWide ? long : 1000;
        final uprightHeight = uprightIsWide ? 1000 : long;
        final upright = suggestDocumentType(
          name: 'neutral-name.png',
          width: uprightWidth,
          height: uprightHeight,
          catalog: catalog,
        );
        final onItsSide = suggestDocumentType(
          name: 'different-name/passport.png',
          width: uprightHeight,
          height: uprightWidth,
          catalog: catalog,
        );
        expect(upright.kind, DocumentKind.unknown);
        expect(onItsSide.kind, upright.kind);
        expect(onItsSide.confidence, upright.confidence);
        final asHeld = catalog.sizeFor(kind, landscape: uprightIsWide)!;
        expect([asHeld.width, asHeld.height], [natural.width, natural.height]);
        final turned = catalog.sizeFor(kind, landscape: !uprightIsWide)!;
        expect([turned.width, turned.height], [natural.height, natural.width]);
      }
    });

    test('camera-frame and document-shaped images both stay unknown', () {
      for (final entry in const [
        (name: 'IMG_0001.jpg', width: 1600, height: 1200, fullFrame: true),
        (
          name: 'Passport/photo.png',
          width: 1586,
          height: 1000,
          fullFrame: false,
        ),
        (
          name: 'بطاقة التموينية.png',
          width: 1586,
          height: 1000,
          fullFrame: true,
        ),
      ]) {
        final suggestion = suggestDocumentType(
          name: entry.name,
          width: entry.width,
          height: entry.height,
          fullFrame: entry.fullFrame,
        );
        expect(suggestion.kind, DocumentKind.unknown);
        expect(suggestion.confidence, 0);
      }
    });
  });

  group('the orientation a document is held in', () {
    test('cropHeldAspect preserves orientation', () {
      expect(
        cropHeldAspect(_portraitQuad(), sourceWidth: 1000, sourceHeight: 1000),
        lessThan(1.0),
        reason: 'a portrait crop',
      );
      expect(
        cropHeldAspect(_landscapeQuad(), sourceWidth: 1000, sourceHeight: 1000),
        greaterThan(1.0),
        reason: 'the same card on its side',
      );
      // It agrees with the catalog's own long/short view of the same quad.
      final held = cropHeldAspect(
        _portraitQuad(),
        sourceWidth: 1000,
        sourceHeight: 1000,
      );
      expect(
        1 / held,
        closeTo(DocumentSizeCatalog.defaultRationCard.aspect, .05),
      );
      // Degenerate input never invents an orientation.
      expect(
        cropHeldAspect(const [], sourceWidth: 1000, sourceHeight: 1000),
        1.0,
      );
    });

    test('an upright portrait document is not proposed a quarter turn', () {
      // The ration card's natural width / height is 52 / 287 = 0.181, so an
      // upright crop (held aspect below 1) already matches it and needs no
      // turn. Feeding estimateOrientation a normalized long/short ratio —
      // which is what the classification path needs — would invert this and
      // propose a turn for every correctly held ration card.
      const expected = 52 / 287;
      expect(
        estimateOrientation(
          pixelAspect: cropHeldAspect(
            _portraitQuad(),
            sourceWidth: 1000,
            sourceHeight: 1000,
          ),
          expectedAspect: expected,
        ).quarterTurns,
        0,
      );
      // Held on its side, it is crossed and a turn IS proposed.
      expect(
        estimateOrientation(
          pixelAspect: 1 / expected,
          expectedAspect: expected,
        ).quarterTurns,
        1,
      );
      // A landscape-natural document held portrait is crossed too.
      expect(
        estimateOrientation(
          pixelAspect: 53.98 / 85.6,
          expectedAspect: 85.6 / 53.98,
        ).quarterTurns,
        1,
      );
      // Every branch stays unconfident: rotation is the user's decision, so
      // nothing downstream may apply this without asking.
      expect(
        estimateOrientation(
          pixelAspect: 1 / expected,
          expectedAspect: expected,
        ).confident,
        isFalse,
      );
    });
  });

  group('a catalog size is confirmed only by resolved geometry', () {
    late Directory root;
    late LocalProjectRepository projects;
    late LocalAssetRepository assets;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('scan-classification-');
      projects = await LocalProjectRepository.open(root);
      assets = LocalAssetRepository(projects.files);
    });

    tearDown(() async {
      await projects.close();
      await root.delete(recursive: true);
    });

    ProjectService service(
      Future<SegmentationResult> Function(Uint8List bytes) segmenter,
    ) => ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      smartRecognitionEnabled: true,
      segmenter: segmenter,
    );

    /// Imports one synthetic photo under [name] and arranges it. Names are
    /// deliberately varied by the invariance tests; none is a kind label.
    Future<AutomaticLayoutReport> run(
      ProjectService s,
      String name,
      List<List<int>> rects,
    ) async {
      final bytes = _photo(rects);
      var project = await s.create('synthetic classification fixture');
      project = (await s.importImages(project, [
        ImportSource('$name.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      return s.arrangeImportedImages(project, [project.assets.single.id]);
    }

    DocumentItem itemForRecord(
      AutomaticLayoutReport report,
      DocumentRecord record,
    ) =>
        report.project.items.firstWhere((item) => item.documentId == record.id);

    const tallRect = [400, 80, 550, 908];
    const wideRect = [60, 100, 380, 300];

    test(
      'resolved regions are cropped without inferring kind or size',
      () async {
        final report = await run(
          service(_twoQuads(firstResolved: true)),
          'ration-card.png',
          const [tallRect, wideRect],
        );

        expect(report.project.documents, hasLength(2));
        expect(report.project.items, hasLength(2));
        expect(report.project.assets, hasLength(3));

        for (final record in report.project.documents) {
          final item = itemForRecord(report, record);
          final asset = report.project.assets.firstWhere(
            (entry) => entry.id == item.assetId,
          );
          expect(record.sides.single.detection!.polygon, hasLength(4));
          expect(hasUnresolvedBoundary(record), isFalse);
          expect(record.recognition!.documentKind, DocumentKind.unknown);
          expect(record.recognition!.evidence, isEmpty);
          expect(record.recognition!.preset.awaitingSize, isTrue);
          expect(item.documentKind, DocumentKind.unknown);
          expect(item.sizeConfirmed, isFalse);
          expect(item.pageIndex, isNull);
          expect(
            item.width / item.height,
            closeTo(asset.width / asset.height, 1e-3),
          );
        }
      },
    );

    test(
      'changing only the asset name leaves kind and crop result unchanged',
      () async {
        const rects = [tallRect, wideRect];
        final named = await run(
          service(_twoQuads(firstResolved: true)),
          'Passport-scan',
          rects,
        );
        final renamed = await run(
          service(_twoQuads(firstResolved: true)),
          'IMG_2041',
          rects,
        );

        expect(renamed.cropped, named.cropped);
        expect(renamed.notDetected, named.notDetected);
        expect(
          renamed.project.documents,
          hasLength(named.project.documents.length),
        );
        expect(renamed.project.items, hasLength(named.project.items.length));
        for (var index = 0; index < named.project.items.length; index++) {
          final a = named.project.items[index];
          final b = renamed.project.items[index];
          expect(b.documentKind, a.documentKind);
          expect(b.documentKind, DocumentKind.unknown);
          expect(b.sizeConfirmed, a.sizeConfirmed);
          expect(b.width, a.width);
          expect(b.height, a.height);
          expect(b.pageIndex, a.pageIndex);
        }
        for (var index = 0; index < named.project.documents.length; index++) {
          final a = named.project.documents[index];
          final b = renamed.project.documents[index];
          expect(b.recognition!.documentKind, a.recognition!.documentKind);
          expect(b.recognition!.evidence, a.recognition!.evidence);
          expect(
            b.sides.single.detection!.polygon,
            a.sides.single.detection!.polygon,
          );
        }
      },
    );

    test('an unresolved region stays recoverable and unclassified', () async {
      final report = await run(
        service(_twoQuads(firstResolved: false)),
        'unresolved-case',
        const [tallRect, wideRect],
      );

      expect(report.project.documents, hasLength(2));
      expect(report.project.assets, hasLength(3));
      final unresolvedRecord = report.project.documents.firstWhere(
        (record) => record.sides.single.detection!.polygon == null,
      );
      final unresolvedItem = itemForRecord(report, unresolvedRecord);
      expect(unresolvedItem.documentKind, DocumentKind.unknown);
      expect(unresolvedItem.sizeConfirmed, isFalse);
      expect(unresolvedItem.height / unresolvedItem.width, greaterThan(4));
      expect(unresolvedItem.width, greaterThanOrEqualTo(minDocumentEdgeMm));
      expect(unresolvedItem.height, greaterThanOrEqualTo(minDocumentEdgeMm));
      expect(
        validDocumentSize(
          PhysicalSizeMm(unresolvedItem.width, unresolvedItem.height),
        ),
        isA<PhysicalSizeMm>(),
      );
      expect(hasUnresolvedBoundary(unresolvedRecord), isTrue);
      expect(unresolvedRecord.provenance.sourceImageId, isNotNull);
      expect(recordNeedsReview(unresolvedRecord), isTrue);
      expect(unresolvedRecord.recognition!.preset.awaitingSize, isTrue);
      expect(
        reviewReasons(unresolvedRecord),
        contains('حدود غير محسومة — يحتاج القص إلى مراجعة'),
      );
      expect(reviewReasons(unresolvedRecord), contains('بانتظار تحديد المقاس'));

      final resolvedRecord = report.project.documents.firstWhere(
        (record) => record.sides.single.detection!.polygon != null,
      );
      final resolvedItem = itemForRecord(report, resolvedRecord);
      expect(resolvedItem.documentKind, DocumentKind.unknown);
      expect(resolvedItem.sizeConfirmed, isFalse);
      expect(resolvedRecord.recognition!.evidence, isEmpty);
    });

    test(
      'a turned region keeps measured orientation without inferring kind',
      () async {
        final report = await run(
          service(
            (Uint8List bytes) async => SegmentationResult(
              multi: true,
              candidates: [
                _candidate(_landscapeQuad()),
                _candidate(_wideQuad()),
              ],
            ),
          ),
          'landscape-case',
          const [
            [80, 400, 908, 550],
            wideRect,
          ],
        );

        expect(report.project.items, hasLength(2));
        final landscapeRecord = report.project.documents.firstWhere(
          (record) =>
              record.sides.single.processedAsset.width /
                  record.sides.single.processedAsset.height >
              4,
        );
        final landscapeItem = itemForRecord(report, landscapeRecord);
        expect(landscapeItem.documentKind, DocumentKind.unknown);
        expect(landscapeItem.sizeConfirmed, isFalse);
        expect(landscapeItem.width, greaterThan(landscapeItem.height));
        expect(
          landscapeItem.width / landscapeItem.height,
          closeTo(
            landscapeRecord.sides.single.processedAsset.width /
                landscapeRecord.sides.single.processedAsset.height,
            1e-3,
          ),
        );
        expect(
          report.project.items.every(
            (item) => item.documentKind == DocumentKind.unknown,
          ),
          isTrue,
        );
        expect(
          report.project.catalog.natural(DocumentKind.rationCard)!.width,
          52,
        );
        expect(
          report.project.catalog.natural(DocumentKind.rationCard)!.height,
          287,
        );
      },
    );

    test(
      'aspect matches alone never produce a kind or confirmed size',
      () async {
        final report = await run(
          service(_twoShapeFixtures),
          'passport.png',
          const [
            [50, 200, 950, 746],
            [100, 800, 385, 980],
          ],
        );

        expect(report.project.items, hasLength(2));
        expect(report.project.documents, hasLength(2));
        for (final record in report.project.documents) {
          final item = itemForRecord(report, record);
          expect(item.documentKind, DocumentKind.unknown);
          expect(item.sizeConfirmed, isFalse);
          expect(record.recognition!.status, RecognitionStatus.unknown);
          expect(record.recognition!.confidences.classification, isNull);
          expect(record.recognition!.evidence, isEmpty);
          expect(record.recognition!.preset.awaitingSize, isTrue);
          expect(reviewReasons(record), contains('بانتظار تحديد المقاس'));
        }
      },
    );

    test('provisionalSize stays editable at any proportion', () {
      // An extreme proportion such as a shadow strip would otherwise produce a
      // sub-10 mm edge that validDocumentSize rejects — and DocumentEdits
      // .resize validates through that same function, leaving an item the
      // editor could not resize at all.
      for (final entry in const [
        (width: 1000, height: 80),
        (width: 80, height: 1000),
        (width: 3000, height: 40),
        (width: 40, height: 3000),
      ]) {
        final size = provisionalSize(width: entry.width, height: entry.height);
        expect(size.width, greaterThanOrEqualTo(minDocumentEdgeMm));
        expect(size.height, greaterThanOrEqualTo(minDocumentEdgeMm));
        expect(size.width, lessThanOrEqualTo(maxDocumentEdgeMm));
        expect(size.height, lessThanOrEqualTo(maxDocumentEdgeMm));
        expect(validDocumentSize(size), size);
      }
      // A plausible document proportion is left alone.
      final card = provisionalSize(width: 900, height: 567);
      expect(card.width, closeTo(80, .001));
      expect(card.height, closeTo(80 * 567 / 900, .001));
    });
  });
}
