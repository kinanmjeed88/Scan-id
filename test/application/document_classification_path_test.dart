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

/// The document-kind classification path, kept SEPARATE from the question of
/// whether a region is a usable document candidate.
///
/// Two invariants are pinned here:
///
/// 1. Orientation is a presentation detail. `52 × 287 mm` is the ration card in
///    its natural PORTRAIT orientation; `PhysicalSizeMm.aspect` and the shape
///    match are both long/short, so a card photographed upright and the same
///    card photographed on its side classify identically, and are sized by
///    TURNING the catalog entry — never by editing it.
/// 2. A catalog size is CONFIRMED only when the boundary was actually resolved
///    and the classification cleared its own floor. A region can match a
///    catalogued proportion perfectly and still be refused a confirmed size —
///    which is what stops a background strip that happens to share a document's
///    proportion from being placed on the sheet as that document.
///
/// The segmenter is injected here on purpose: these tests are about
/// classification and size confirmation, not about segmentation. Segmenter
/// behaviour over real pixels is covered by
/// `test/imaging/document_segmenter_gate_test.dart` and
/// `test/application/false_positive_document_test.dart`.
library;

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

/// A portrait ration-card quad: 150 × 828 px, ratio 5.520 against the
/// catalogued 287 / 52 = 5.5192 — an exact shape match in the card's natural
/// orientation.
List<Point2> _rationQuad() => [
  Point2(.4, .08),
  Point2(.55, .08),
  Point2(.55, .908),
  Point2(.4, .908),
];

/// The same quad held on its side.
List<Point2> _rationQuadLandscape() => [
  Point2(.08, .4),
  Point2(.908, .4),
  Point2(.908, .55),
  Point2(.08, .55),
];

/// An ID-1 quad: 320 × 200 px, ratio 1.600, inside the 4 % tolerance of
/// 85.6 / 53.98 = 1.5858.
List<Point2> _cardQuad() => [
  Point2(.06, .1),
  Point2(.38, .1),
  Point2(.38, .3),
  Point2(.06, .3),
];

/// Region bounds carrying the segmenter's own 8 % margin around a quad. The
/// margin is what makes these regions realistic; measured against the catalog
/// they still match (5.517 for the ration region, 1.599 for the card region).
List<double> _regionOf(List<Point2> quad) {
  final xs = quad.map((p) => p.x).toList();
  final ys = quad.map((p) => p.y).toList();
  final mx = (xs.reduce((a, b) => a > b ? a : b) -
          xs.reduce((a, b) => a < b ? a : b)) *
      .08;
  final my = (ys.reduce((a, b) => a > b ? a : b) -
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
SegmentCandidate _unresolved(List<Point2> quad) => SegmentCandidate(
  region: _regionOf(quad),
  reason: 'no-trustworthy-quad',
);

/// Two regions — the ration card and a national card — the second always
/// resolved so the multi-document path is taken either way.
Future<SegmentationResult> Function(Uint8List) _rationAndCard({
  required bool rationResolved,
}) =>
    (Uint8List bytes) async => SegmentationResult(
      multi: true,
      candidates: [
        rationResolved ? _candidate(_rationQuad()) : _unresolved(_rationQuad()),
        _candidate(_cardQuad()),
      ],
    );

/// A quad whose proportion is INSIDE the 4 % shape tolerance of the national
/// card (900 × 546 px, ratio 1.648, best error 0.039) but whose shape match is
/// too weak to classify: confidence 0.509, below the R4 floor of 0.6.
Future<SegmentationResult> _weakShapeMatch(Uint8List bytes) async =>
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

    test('the shape match is identical in both orientations', () {
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
          name: 'x',
          width: uprightWidth,
          height: uprightHeight,
          catalog: catalog,
        );
        // The SAME crop turned a quarter turn: width and height exchanged.
        // `suggestDocumentType` matches on long/short, so the match and its
        // confidence must be identical either way round.
        final onItsSide = suggestDocumentType(
          name: 'x',
          width: uprightHeight,
          height: uprightWidth,
          catalog: catalog,
        );
        expect(upright.kind, kind, reason: '$kind upright');
        expect(onItsSide.kind, kind, reason: '$kind on its side');
        expect(onItsSide.confidence, upright.confidence);
        // Turning the crop turns the SIZE to match it, and the entry it turns
        // is the same catalog entry either way — never an edited one.
        // Compared field by field: PhysicalSizeMm has no `operator ==`.
        final asHeld = catalog.sizeFor(kind, landscape: uprightIsWide)!;
        expect([asHeld.width, asHeld.height], [natural.width, natural.height]);
        final turned = catalog.sizeFor(kind, landscape: !uprightIsWide)!;
        expect([turned.width, turned.height], [natural.height, natural.width]);
      }
    });

    test('camera-frame shapes are refused, not guessed', () {
      final frame = suggestDocumentType(
        name: 'x',
        width: 1600,
        height: 1200,
        fullFrame: true,
      );
      expect(frame.kind, DocumentKind.unknown);
      expect(frame.confidence, 0);
      // A document proportion WITH no detected boundary is still a candidate:
      // an already-cut scan has the document's shape.
      expect(
        suggestDocumentType(name: 'x', width: 1586, height: 1000).kind,
        DocumentKind.unifiedNationalId,
      );
      // An explicit filename label outranks the shape.
      expect(
        suggestDocumentType(
          name: 'البطاقة التموينية.png',
          width: 1586,
          height: 1000,
        ).kind,
        DocumentKind.rationCard,
      );
    });
  });

  group('the orientation a document is held in', () {
    test('cropHeldAspect preserves orientation', () {
      expect(
        cropHeldAspect(_rationQuad(), sourceWidth: 1000, sourceHeight: 1000),
        lessThan(1.0),
        reason: 'a portrait crop',
      );
      expect(
        cropHeldAspect(
          _rationQuadLandscape(),
          sourceWidth: 1000,
          sourceHeight: 1000,
        ),
        greaterThan(1.0),
        reason: 'the same card on its side',
      );
      // It agrees with the catalog's own long/short view of the same quad.
      final held = cropHeldAspect(
        _rationQuad(),
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
            _rationQuad(),
            sourceWidth: 1000,
            sourceHeight: 1000,
          ),
          expectedAspect: expected,
        ).quarterTurns,
        0,
      );
      // Held on its side, it is crossed and a turn IS proposed.
      expect(
        estimateOrientation(pixelAspect: 1 / expected, expectedAspect: expected)
            .quarterTurns,
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
        estimateOrientation(pixelAspect: 1 / expected, expectedAspect: expected)
            .confident,
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
      segmenter: segmenter,
    );

    Future<AutomaticLayoutReport> run(
      ProjectService s,
      String name,
      List<List<int>> rects,
    ) async {
      final bytes = _photo(rects);
      var project = await s.create(name);
      project = (await s.importImages(project, [
        ImportSource('$name.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      return s.arrangeImportedImages(project, [project.assets.single.id]);
    }

    DocumentItem itemOfKind(AutomaticLayoutReport report, DocumentKind kind) =>
        report.project.items.firstWhere((i) => i.documentKind == kind);

    const rationRect = [400, 80, 550, 908];
    const cardRect = [60, 100, 380, 300];

    test('a resolved ration card is recognized and sized 52 × 287', () async {
      final report = await run(
        service(_rationAndCard(rationResolved: true)),
        'تموينية',
        const [rationRect, cardRect],
      );

      expect(report.project.documents, hasLength(2));
      expect(report.project.items, hasLength(2));
      expect(report.project.assets, hasLength(3));

      final ration = itemOfKind(report, DocumentKind.rationCard);
      expect(ration.sizeConfirmed, isTrue);
      expect([ration.width, ration.height], [52, 287]);
      expect(
        hasUnresolvedBoundary(
          report.project.documents.firstWhere((d) => d.id == ration.documentId),
        ),
        isFalse,
      );

      // The national card in the same photo is unaffected.
      final card = itemOfKind(report, DocumentKind.unifiedNationalId);
      expect(card.sizeConfirmed, isTrue);
      expect([card.width, card.height], [85.6, 53.98]);

      // The catalog entry was turned, never edited.
      final naturalRation = report.project.catalog.natural(
        DocumentKind.rationCard,
      )!;
      expect([naturalRation.width, naturalRation.height], [52, 287]);
    });

    test('the SAME region unresolved never claims a catalog size', () async {
      final report = await run(
        service(_rationAndCard(rationResolved: false)),
        'بلا حدود',
        const [rationRect, cardRect],
      );

      expect(report.project.documents, hasLength(2));
      expect(report.project.assets, hasLength(3));
      final ration = itemOfKind(report, DocumentKind.rationCard);
      final record = report.project.documents.firstWhere(
        (d) => d.id == ration.documentId,
      );

      // Identical geometry, identical 5.520 proportion, a perfect catalog
      // match — and still no confirmed size, because there is no trustworthy
      // boundary to measure it from. This is the safeguard that keeps a strip
      // sharing a document's proportion off the sheet: classification can
      // never override a failed geometry assessment.
      expect(ration.sizeConfirmed, isFalse);
      expect([ration.width, ration.height], isNot([52, 287]));
      // A provisional size keeps the proportion and stays editable, which is
      // what keeps the item recoverable from the editor.
      expect(ration.height / ration.width, greaterThan(4));
      expect(ration.width, greaterThanOrEqualTo(minDocumentEdgeMm));
      expect(ration.height, greaterThanOrEqualTo(minDocumentEdgeMm));
      expect(
        validDocumentSize(PhysicalSizeMm(ration.width, ration.height)),
        isA<PhysicalSizeMm>(),
      );
      // Preserved and recoverable, never dropped and never confirmed.
      expect(hasUnresolvedBoundary(record), isTrue);
      expect(record.sides.single.detection!.polygon, isNull);
      expect(record.provenance.sourceImageId, isNotNull);
      expect(recordNeedsReview(record), isTrue);
      // The preset is resolved from the KIND alone, so it does NOT report
      // "awaiting size" here — the unresolved boundary has to be named
      // separately or the queue would hide the one thing to act on.
      expect(record.recognition!.preset.awaitingSize, isFalse);
      expect(
        reviewReasons(record),
        contains('حدود غير محسومة — يحتاج القص إلى مراجعة'),
      );
      // The resolved card beside it is still confirmed.
      expect(
        itemOfKind(report, DocumentKind.unifiedNationalId).sizeConfirmed,
        isTrue,
      );
    });

    test('the same card on its side is sized 287 × 52', () async {
      final report = await run(
        service(
          (Uint8List bytes) async => SegmentationResult(
            multi: true,
            candidates: [
              _candidate(_rationQuadLandscape()),
              _candidate(_cardQuad()),
            ],
          ),
        ),
        'تموينية بالعرض',
        const [
          [80, 400, 908, 550],
          cardRect,
        ],
      );

      final ration = itemOfKind(report, DocumentKind.rationCard);
      expect(ration.sizeConfirmed, isTrue);
      expect([ration.width, ration.height], [287, 52]);
      // Still the same catalog entry, just turned.
      final naturalRation = report.project.catalog.natural(
        DocumentKind.rationCard,
      )!;
      expect([naturalRation.width, naturalRation.height], [52, 287]);
    });

    test('a shape match too weak to classify confirms no size', () async {
      final report = await run(
        service(_weakShapeMatch),
        'ضعيفة',
        const [
          [50, 200, 950, 746],
          [100, 800, 385, 980],
        ],
      );

      expect(report.project.items, hasLength(2));
      // Ratio 1.648 is inside the 4 % tolerance of 85.6 / 53.98, but the
      // resulting confidence 0.509 is below the R4 floor of 0.6, so the kind
      // becomes unknown and no catalog size can be claimed.
      final weak = report.project.items
          .where((i) => !i.sizeConfirmed)
          .toList();
      expect(weak, hasLength(1));
      expect(weak.single.documentKind, DocumentKind.unknown);
      expect([weak.single.width, weak.single.height], isNot([85.6, 53.98]));
      final record = report.project.documents.firstWhere(
        (d) => d.id == weak.single.documentId,
      );
      expect(record.recognition!.status, RecognitionStatus.unknown);
      expect(reviewReasons(record), contains('بانتظار تحديد المقاس'));
      // The evidence is preserved for review even though the kind is not.
      final classification = record.recognition!.confidences.classification;
      expect(classification, isNotNull);
      expect(
        classification!.value,
        lessThan(defaultThresholds.minClassification),
      );
      expect(record.recognition!.evidence, isNotEmpty);
      // The clearly-matched card beside it is unaffected.
      expect(
        itemOfKind(report, DocumentKind.unifiedNationalId).sizeConfirmed,
        isTrue,
      );
    });

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
