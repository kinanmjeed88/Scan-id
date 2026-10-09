/// The ration-proportion false positive: measured, bounded, and NOT claimed to
/// be solved.
///
/// ADR-012 records an accepted residual risk: a non-document band whose
/// proportion happens to match the ration card's (52 x 287 mm, 5.52:1) cannot
/// be refused by a geometric gate, because any bound tight enough to refuse it
/// also refuses the real card. These tests are the evidence for that claim,
/// and for the two things that DO bound the risk in production:
///
/// 1. `automationMode` is `reviewAll`, so a document recognised from such a
///    region enters the review queue exactly like a genuine one. Nothing is
///    silently accepted, so the user always has the decision.
/// 2. The original is immutable and stays in the library, so a wrong document
///    is always correctable and a refused region always hand-croppable.
///
/// Every geometry asserted here was measured first through a port of the
/// segmenter's own arithmetic (360 px working frame, `Interpolation.average`,
/// 2 px border median, Otsu over 128 bins / 765, 8 % region margin, Dart
/// `.round()`), on the editor's 900x1200 preview of each 1200x1600 photo:
///
///   shadow band   accepted  aspect 5.60  sides 0  fill 1.000  crop 158x866
///   ration card   accepted  aspect 5.62  sides 0  fill 0.986  crop 158x869
///   touching pair refused/implausibleAspect  aspect 11.25  sides 0
///   pair with gap accepted  aspect 5.50 and 5.50, plus the card at 1.60
///
/// The band and the card differ by 0.02 in aspect — 0.35 % — and the band is
/// the LOWER of the two, so lowering `maxPlausibleRegionAspect` refuses the
/// card before it refuses the band. Its fill is also HIGHER (1.000 against
/// 0.986), because printed ink slightly erodes a genuine card's mask, so a
/// "too uniform to be a document" rule is inverted here and would refuse
/// blank, faded and washed-out cards, which measure fill 1.000 too.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
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

/// One ID card, so a photo is never a single-region fallback: whatever happens
/// to the narrow region happens alongside a document that is certainly valid.
img.Image _withIdCard(void Function(img.Image) draw) {
  final image = _canvas(1200, 1600, _desk);
  _rect(image, 150, 180, 800, 590, _paper);
  draw(image);
  return image;
}

/// A crisp shadow band at the ration card's own proportion: 181 x 1000 px,
/// 5.52:1, no frame contact. This is the residual risk given pixels.
Uint8List get _shadowBand =>
    _png(_withIdCard((image) => _rect(image, 900, 300, 1080, 1299, _shadow)));

/// A GENUINE ration card of the same drawn proportion, with printed content.
Uint8List get _rationCard => _png(
  _withIdCard((image) {
    _rect(image, 900, 300, 1080, 1299, _paper2);
    for (final y in [360, 620, 880, 1140]) {
      _rect(image, 920, y, 1060, y + 34, _ink);
    }
  }),
);

/// Two ration cards laid edge to edge with NO gap, plus a separate ID card.
/// The pair is one connected component measuring aspect 11.25 — more extreme
/// than any catalogued document — so the gate refuses the merged region.
Uint8List get _touchingPair => _png(() {
  final image = _canvas(1200, 1600, _desk);
  _rect(image, 100, 300, 599, 390, _paper2);
  _rect(image, 600, 300, 1099, 390, _paper2);
  _rect(image, 250, 900, 900, 1310, _paper);
  return image;
}());

/// The same three documents with a visible desk gap between the two cards: the
/// positive control that proves the refusal above is about TOUCHING, not about
/// the ration-card proportion.
Uint8List get _pairWithGap => _png(() {
  final image = _canvas(1200, 1600, _desk);
  _rect(image, 100, 300, 589, 390, _paper2);
  _rect(image, 610, 300, 1099, 390, _paper2);
  _rect(image, 250, 900, 900, 1310, _paper);
  return image;
}());

/// What the pipeline DECIDED about the narrowest item of a run, plus the
/// review-queue state that bounds the risk. Rendered as text so that a
/// difference between two runs shows up as evidence rather than as a guess.
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

  @override
  String toString() {
    final item = narrowest;
    // Sizes are rounded to whole millimetres on purpose: the comparison under
    // test is what the pipeline DECIDED (kind, confirmation, review), and a
    // sub-pixel difference in a rectified crop is not a decision.
    final described = item == null
        ? 'none'
        : '${item.documentKind.name} confirmed=${item.sizeConfirmed} '
              'size=${item.width.round()}x${item.height.round()} '
              'aspect=${_aspect(item).toStringAsFixed(2)}';
    return 'documents=${project.documents.length} '
        'items=${project.items.length} '
        'rejected=${report.rejectedRegions} '
        'reviewed=$everyRecordReviewed '
        'narrowest=$described';
  }
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-ration-proportion-');
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
    segmenter: (bytes) async => segmentDocumentBytes(bytes),
  );

  /// Runs one photo through the real import + arrangement pipeline.
  Future<_Decision> run(String name, Uint8List bytes) async {
    final s = service();
    var project = await s.create(name);
    project = (await s.importImages(project, [
      ImportSource('$name.png', () => Stream<List<int>>.value(bytes)),
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

  group('the residual risk is real, and it is bounded', () {
    test('the gates accept both the band and the card', () {
      const names = ['shadow band', 'genuine card'];
      final photos = [_shadowBand, _rationCard];
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

    test('no aspect bound separates them: the band is LOWER', () {
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
      final card = narrowestOf(_rationCard);
      // Measured 5.4785 for the band against 5.4997 for the card. The gap is
      // four tenths of one percent, and it runs the WRONG way: a bound between
      // them refuses the genuine card and keeps the shadow.
      expect(band, lessThan(card), reason: 'band=$band card=$card');
      expect(
        card - band,
        lessThan(0.05),
        reason: 'band=$band card=$card — too close for any threshold',
      );
      expect(band, lessThanOrEqualTo(maxPlausibleRegionAspect));
      expect(card, lessThanOrEqualTo(maxPlausibleRegionAspect));
    });

    test('the pipeline cannot tell them apart either', () async {
      final band = await run('شريط ظل', _shadowBand);
      final card = await run('بطاقة تموينية', _rationCard);

      // The claim under test: whatever the pipeline decides for a genuine
      // ration card, it decides the SAME for a shadow band of that proportion.
      // If this ever fails, a separating signal exists and ADR-012's residual
      // risk should be revisited — the failure message names both decisions.
      expect(
        band.toString(),
        card.toString(),
        reason: 'shadow band and genuine card must be indistinguishable',
      );

      // Both regions were accepted, so both photos produced both documents.
      expect(band.report.rejectedRegions, 0);
      expect(band.project.documents, hasLength(2));
      expect(band.project.items, hasLength(2));
    });

    test('nothing is silently accepted: every record reaches review', () async {
      final band = await run('شريط ظل', _shadowBand);

      expect(automationMode, AutomationMode.reviewAll);
      expect(band.everyRecordReviewed, isTrue, reason: '$band');
      expect(
        band.project.documents.every(
          (record) => reviewReasons(record).isNotEmpty,
        ),
        isTrue,
        reason: 'a recognised document must always name why it needs review',
      );
      // The narrow region is NOT refused, so this is a residual risk that is
      // managed by review, not eliminated by detection. Recorded explicitly so
      // nobody reads these tests as a claim that the case is solved.
      expect(band.report.rejectedRegions, 0);
      expect(band.report.rejectedSummary, isNull);
    });

    test('the source stays recoverable whatever was decided', () async {
      final band = await run('شريط ظل', _shadowBand);

      // The original is still an asset of the project, so the user can crop any
      // part of it by hand after dismissing a wrong document.
      expect(band.project.assets, isNotEmpty);
      final source = band.project.assets.firstWhere(
        (asset) => asset.derivedFrom == null,
      );
      expect(source.derivedFrom, isNull);
      // Every derived crop still names its source (Task C's invariant, asserted
      // here too because a wrong document is only correctable if its crop is
      // traceable back to the photo it came from).
      for (final asset in band.project.assets) {
        if (asset.id == source.id) continue;
        expect(asset.derivedFrom, source.id, reason: '${asset.name}');
      }
    });
  });

  group('touching narrow documents: the measured trade-off', () {
    test('a touching pair is refused as one region, and recoverable', () async {
      final decision = await run('بطاقتان متلاصقتان', _touchingPair);
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

      // The consequence, stated rather than hidden: with only one accepted
      // region the photo is not a multi-document source, so it takes the
      // single-document path. What must NEVER happen is an 11:1 "document".
      for (final item in decision.project.items) {
        expect(
          _aspect(item),
          lessThanOrEqualTo(maxPlausibleRegionAspect),
          reason: 'no item may be sized from the merged pair: $decision',
        );
      }
      // And nothing is lost: the photo is still there, whole, for a hand crop.
      expect(decision.project.assets, isNotEmpty);
      expect(decision.project.items, isNotEmpty, reason: '$decision');
    });

    test('a visible gap keeps all three documents', () async {
      final decision = await run('بطاقتان متباعدتان', _pairWithGap);
      final report = decision.report;

      expect(report.rejectedRegions, 0, reason: '${report.rejectedByReason}');
      expect(report.multiDocumentImages, 1);
      expect(decision.project.documents, hasLength(3), reason: '$decision');
      expect(decision.project.items, hasLength(3));
      // Both narrow cards survived as SEPARATE items and kept a narrow
      // proportion of their own: neither was merged into the other nor
      // refused. (That the ration-card KIND is then recognised from such a
      // proportion is covered by document_classification_path_test.)
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
