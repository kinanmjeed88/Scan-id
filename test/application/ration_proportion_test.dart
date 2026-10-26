/// Synthetic geometry regression for narrow regions and the segmenter's
/// configured aspect gate. No real photograph or human annotation is present;
/// these results are not document-validity or accuracy evidence.
///
/// The fixtures compare a narrow band-like rectangle with a similarly
/// proportioned panel containing synthetic marks, plus touching and separated
/// narrow rectangles. The test preserves the current geometric gate behavior
/// without assigning any document category from proportions or appearance.
///
/// Fixture measurements were calculated with the segmenter's arithmetic
/// (360 px working frame, `Interpolation.average`, 2 px border median, Otsu
/// over 128 bins / 765, 8 % region margin, Dart `.round()`), on a 900x1200
/// preview of each 1200x1600 synthetic image:
///
///   band-like region       accepted  aspect 5.60  sides 0  fill 1.000  crop 158x866
///   panel with marks       accepted  aspect 5.62  sides 0  fill 0.986  crop 158x869
///   touching pair          refused/implausibleAspect  aspect 11.25  sides 0
///   separated pair         accepted  aspect 5.50 and 5.50, plus a wide region at 1.60
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

final _paper = img.ColorRgb8(240, 238, 230);
final _paper2 = img.ColorRgb8(232, 230, 222);
final _desk = img.ColorRgb8(128, 122, 116);
final _ink = img.ColorRgb8(60, 58, 62);
final _shadow = img.ColorRgb8(74, 70, 66);

img.Image _canvas(int width, int height, img.ColorRgb8 background) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: background);
  return image;
}

void _rect(
  img.Image image,
  int x1,
  int y1,
  int x2,
  int y2,
  img.ColorRgb8 color,
) => img.fillRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: color);

Uint8List _png(img.Image image) => Uint8List.fromList(img.encodePng(image));

double _aspect(DocumentItem item) =>
    math.max(item.width, item.height) / math.min(item.width, item.height);

/// A separate synthetic wide rectangle keeps the fixture multi-region while
/// the narrow band-like region is measured by the segmenter.
img.Image _withWideRegion(void Function(img.Image) draw) {
  final image = _canvas(1200, 1600, _desk);
  _rect(image, 150, 180, 800, 590, _paper);
  draw(image);
  return image;
}

/// A crisp synthetic narrow band: 181 x 1000 px, about 5.52:1, no frame contact.
Uint8List get _shadowBand => _png(
  _withWideRegion((image) => _rect(image, 900, 300, 1080, 1299, _shadow)),
);

/// A synthetic panel of the same drawn proportion with decorative rectangles;
/// these marks are not OCR text or a document label.
Uint8List get _panelWithMarks => _png(
  _withWideRegion((image) {
    _rect(image, 900, 300, 1080, 1299, _paper2);
    for (final y in [360, 620, 880, 1140]) {
      _rect(image, 920, y, 1060, y + 34, _ink);
    }
  }),
);

/// Two synthetic narrow rectangles touching edge to edge with NO gap, plus a
/// separate wide rectangle. The connected component measures about 11.25:1,
/// so the geometric gate refuses the merged region.
Uint8List get _touchingPair => _png(() {
  final image = _canvas(1200, 1600, _desk);
  _rect(image, 100, 300, 599, 390, _paper2);
  _rect(image, 600, 300, 1099, 390, _paper2);
  _rect(image, 250, 900, 900, 1310, _paper);
  return image;
}());

/// The same three synthetic rectangles with a visible background gap between
/// the two narrow regions. This checks that the gate responds to connectivity.
Uint8List get _pairWithGap => _png(() {
  final image = _canvas(1200, 1600, _desk);
  _rect(image, 100, 300, 589, 390, _paper2);
  _rect(image, 610, 300, 1099, 390, _paper2);
  _rect(image, 250, 900, 900, 1310, _paper);
  return image;
}());

/// Geometry-only summary of a synthetic run: the narrowest region, whether
/// any type/size was assigned, and whether every record remains reviewable.
class _Decision {
  _Decision(this.report);

  final AutomaticLayoutReport report;

  Project get project => report.project;

  DocumentItem? get narrowest {
    if (project.items.isEmpty) return null;
    return [
      ...project.items,
    ].reduce((a, b) => _aspect(a) >= _aspect(b) ? a : b);
  }

  bool get everyRecordReviewed => project.documents.every(recordNeedsReview);

  bool get everyItemUnknown =>
      project.items.every((item) => item.documentKind == DocumentKind.unknown);

  bool get noItemSizeConfirmed =>
      project.items.every((item) => !item.sizeConfirmed);

  String get described {
    final item = narrowest;
    if (item == null) return 'none';
    return '${item.documentKind.name} '
        '${item.sizeConfirmed ? 'size-confirmed' : 'size-unconfirmed'} '
        'aspect=${_aspect(item).toStringAsFixed(3)}';
  }

  @override
  String toString() {
    return 'documents=${project.documents.length} '
        'items=${project.items.length} '
        'rejected=${report.rejectedRegions} '
        'reviewed=$everyRecordReviewed '
        'allUnknown=$everyItemUnknown '
        'allSizesUnconfirmed=$noItemSizeConfirmed '
        'narrowest=$described';
  }
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-synthetic-proportion-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ProjectService service() => ProjectService(
    projects,
    assets,
    imageEditor: LocalImageEditor(projects.files),
    smartRecognitionEnabled: true,
    segmenter: (bytes) async => segmentDocumentBytes(bytes),
  );

  /// Runs one synthetic image through the real import + arrangement pipeline.
  Future<_Decision> run(Uint8List bytes) async {
    final s = service();
    var project = await s.create('synthetic geometry fixture');
    project = (await s.importImages(project, [
      ImportSource('scene.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final source = project.assets.single;
    final report = await s.arrangeImportedImages(project, [source.id]);
    expect(
      await (await assets.resolve(source.originalPath)).readAsBytes(),
      bytes,
      reason: 'the original must be byte-for-byte untouched (ADR-003)',
    );
    return _Decision(report);
  }

  group('synthetic geometric regions remain unclassified and reviewable', () {
    test('the geometric gate accepts both synthetic panel shapes', () {
      const names = ['band-like geometry', 'panel with synthetic marks'];
      final photos = [_shadowBand, _panelWithMarks];
      for (var i = 0; i < photos.length; i++) {
        final entry = (names[i], photos[i]);
        final result = segmentDocumentBytes(entry.$2);
        expect(
          result.rejected,
          isEmpty,
          reason: '${entry.$1}: ${result.rejected}',
        );
        // Both regions are candidates, so the decision about them is made
        // downstream of the gates, not by them.
        expect(result.candidates, hasLength(2), reason: entry.$1);
      }
    });

    test('the two synthetic geometries have very similar measured aspects', () {
      double narrowestOf(Uint8List bytes) {
        final result = segmentDocumentBytes(bytes);
        // The accepted regions carry their margin-expanded preview bounds, so
        // the proportion is recomputed the way the crop will have it.
        // Recomputed from the normalized region bounds the same way the crop
        // renderer does it: `round(bound * (side - 1))`, inclusive, so the +1.
        final aspects = [
          for (final candidate in result.candidates)
            ((candidate.region[3] - candidate.region[1]) * 1199 + 1) /
                ((candidate.region[2] - candidate.region[0]) * 899 + 1),
        ];
        return aspects.reduce((a, b) => a > b ? a : b);
      }

      final band = narrowestOf(_shadowBand);
      final panel = narrowestOf(_panelWithMarks);
      // These synthetic measurements are approximately 5.4785 and 5.4997.
      expect(band, lessThan(panel), reason: 'band=$band panel=$panel');
      expect(panel - band, lessThan(0.05), reason: 'band=$band panel=$panel');
      expect(band, lessThanOrEqualTo(maxPlausibleRegionAspect));
      expect(panel, lessThanOrEqualTo(maxPlausibleRegionAspect));
    });

    test('similar geometry never supplies a document-kind label', () async {
      final band = await run(_shadowBand);
      final panel = await run(_panelWithMarks);

      expect(band.everyItemUnknown, isTrue, reason: '$band');
      expect(panel.everyItemUnknown, isTrue, reason: '$panel');
      expect(band.noItemSizeConfirmed, isTrue, reason: '$band');
      expect(panel.noItemSizeConfirmed, isTrue, reason: '$panel');
      expect(band.report.rejectedRegions, 0);
      expect(panel.report.rejectedRegions, 0);
      expect(band.project.documents, hasLength(2));
      expect(panel.project.documents, hasLength(2));
      expect(band.project.items, hasLength(2));
      expect(panel.project.items, hasLength(2));
    });

    test('unknown geometry candidates remain in review', () async {
      final band = await run(_shadowBand);

      expect(automationMode, AutomationMode.reviewAll);
      expect(band.everyRecordReviewed, isTrue, reason: '$band');
      expect(
        band.project.documents.every(
          (record) => reviewReasons(record).isNotEmpty,
        ),
        isTrue,
        reason:
            'an unknown synthetic candidate should explain its review state',
      );
      // The narrow region is NOT refused, so this is a residual risk that is
      // managed by review, not eliminated by detection. Recorded explicitly so
      // nobody reads these tests as a claim that the case is solved.
      expect(band.report.rejectedRegions, 0);
      expect(band.report.rejectedSummary, isNull);
    });

    test('the source stays recoverable whatever was decided', () async {
      final band = await run(_shadowBand);

      // The original remains available for manual cropping after review or
      // dismissal of an unwanted synthetic candidate.
      expect(band.project.assets, isNotEmpty);
      final source = band.project.assets.firstWhere(
        (asset) => asset.derivedFrom == null,
      );
      expect(source.derivedFrom, isNull);
      // Every derived crop remains traceable to the source image.
      for (final asset in band.project.assets) {
        if (asset.id == source.id) continue;
        expect(asset.derivedFrom, source.id, reason: asset.name);
      }
    });
  });

  group('touching synthetic rectangles: measured geometry only', () {
    test(
      'a touching pair is refused as one elongated region, and recoverable',
      () async {
        final decision = await run(_touchingPair);
        final report = decision.report;

        // Measured: the merged pair is aspect 11.25 with no frame contact, so it
        // is refused for its proportion, and the refusal is reported.
        expect(report.rejectedRegions, 1);
        expect(report.rejectedByReason, {RegionRejection.implausibleAspect: 1});
        expect(report.rejectedSummary, isNotNull);
        expect(
          report.warnings.any((w) => w.contains('تجاهل التقسيم')),
          isTrue,
          reason: '${report.warnings}',
        );

        // The remaining accepted regions follow the single-image path. Any
        // created item stays unknown and does not receive a physical size from
        // the elongated component.
        for (final item in decision.project.items) {
          expect(item.documentKind, DocumentKind.unknown);
          expect(item.sizeConfirmed, isFalse);
          expect(
            _aspect(item),
            lessThanOrEqualTo(maxPlausibleRegionAspect),
            reason: 'no item may be sized from the merged pair: $decision',
          );
        }
        // And nothing is lost: the photo is still there, whole, for a hand crop.
        expect(decision.project.assets, isNotEmpty);
        expect(decision.project.items, isNotEmpty, reason: '$decision');
      },
    );

    test('a visible gap keeps all three synthetic regions separate', () async {
      final decision = await run(_pairWithGap);
      final report = decision.report;

      expect(report.rejectedRegions, 0, reason: '${report.rejectedByReason}');
      expect(report.multiDocumentImages, 1);
      expect(decision.project.documents, hasLength(3), reason: '$decision');
      expect(decision.project.items, hasLength(3));
      // Both narrow synthetic regions survive as separate, unclassified
      // review items; their proportions do not create a kind or print size.
      expect(
        decision.project.items.every(
          (item) =>
              item.documentKind == DocumentKind.unknown &&
              !item.sizeConfirmed &&
              item.pageIndex == null,
        ),
        isTrue,
        reason: '$decision',
      );
      final narrow = [
        for (final item in decision.project.items)
          if (_aspect(item) > 4) item,
      ];
      expect(narrow, hasLength(2), reason: '$decision');
      for (final item in narrow) {
        expect(
          _aspect(item),
          lessThanOrEqualTo(maxPlausibleRegionAspect),
          reason: '$decision',
        );
      }
    });
  });
}
