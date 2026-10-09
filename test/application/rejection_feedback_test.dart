/// Rejection feedback: what the user is TOLD when the gates refuse regions.
///
/// The gates were already tested (`test/imaging/document_segmenter_gate_test`)
/// and the absence of bogus documents too
/// (`test/application/false_positive_document_test`). What neither proves is
/// that a refusal reaches the user: a region refused silently is
/// indistinguishable from a document the app never saw, and the editor's import
/// path reported only cropped / recognized / not-detected counts, so refusals
/// were invisible there while the very same import from the project screen
/// listed them as warnings.
///
/// These tests run the production intake over the real repositories. The
/// segmenter is stubbed where a test needs a specific tally — the numbers under
/// test here are the report's, not the gates' — and one test drives the real
/// segmenter so the tally is proven to come from measured refusals.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

import '../fixtures.dart';

final _paper = img.ColorRgb8(240, 238, 230);
final _dark = img.ColorRgb8(14, 14, 16);

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

/// A mid-tone desk with nothing on it: recognition produces no document, so a
/// stubbed tally is the only thing the report has to explain.
Uint8List get _blankDesk =>
    _png(_canvas(1200, 1600, img.ColorRgb8(128, 122, 116)));

/// Two ID cards on a desk — the clean baseline that must report no refusal.
img.Image _twoCards() {
  final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
  _rect(image, 150, 180, 800, 590, _paper);
  _rect(image, 200, 900, 851, 1311, img.ColorRgb8(232, 230, 222));
  return image;
}

/// Two cards plus furniture the REAL segmenter refuses for two DIFFERENT
/// reasons, measured through a port of its own arithmetic before this test was
/// written: the top band reaches 3 frame edges (aspect 16.88) and the dark
/// strip measures aspect 12.46 with no frame contact. Background estimate
/// (128, 122, 116), Otsu 114.4, two accepted regions, `multi` true.
img.Image _twoCardsWithFurniture() {
  final image = _twoCards();
  _rect(image, 0, 0, 1200, 70, img.ColorRgb8(16, 15, 15));
  _rect(image, 40, 700, 96, 1420, _dark);
  return image;
}

RejectedRegion _refused(
  RegionRejection rejection, {
  double aspect = 12.0,
  List<double> region = const [.1, .1, .2, .9],
}) => RejectedRegion(
  region: region,
  rejection: rejection,
  aspect: aspect,
  areaFraction: .02,
  fill: 1.0,
  borderSides: rejection == RegionRejection.frameArtifact ? 2 : 0,
  cropWidth: 90,
  cropHeight: 900,
);

/// A segmenter that refuses exactly [refused] and finds no document region.
Future<SegmentationResult> Function(Uint8List) stubSegmenter(
  List<RejectedRegion> rejected,
) =>
    (bytes) async => SegmentationResult(
      candidates: const [],
      multi: false,
      rejected: List.unmodifiable(rejected),
    );

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-rejection-feedback-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ProjectService service({
    Future<SegmentationResult> Function(Uint8List)? segmenter,
  }) => ProjectService(
    projects,
    assets,
    imageEditor: LocalImageEditor(projects.files),
    segmenter: segmenter,
  );

  /// Imports [photos] and arranges them, returning the report.
  Future<AutomaticLayoutReport> arrange(
    ProjectService s,
    List<(String, Uint8List)> photos,
  ) async {
    var project = await s.create('تقرير الاستبعاد');
    project = (await s.importImages(project, [
      for (final (name, bytes) in photos)
        ImportSource(name, () => Stream<List<int>>.value(bytes)),
    ])).project;
    return s.arrangeImportedImages(project, [
      for (final asset in project.assets) asset.id,
    ]);
  }

  group('the report carries the measured tally', () {
    test('one entry per reason, summing to the refusal count', () async {
      final report = await arrange(
        service(
          segmenter: stubSegmenter([
            _refused(RegionRejection.frameArtifact),
            _refused(RegionRejection.implausibleAspect),
            _refused(
              RegionRejection.implausibleAspect,
              region: [.5, .1, .6, .9],
            ),
          ]),
        ),
        [('صورة.png', _blankDesk)],
      );

      expect(report.rejectedRegions, 3);
      expect(report.rejectedByReason, {
        RegionRejection.frameArtifact: 1,
        RegionRejection.implausibleAspect: 2,
      });
      expect(
        report.rejectedByReason.values.fold(0, (a, b) => a + b),
        report.rejectedRegions,
        reason: 'the tally must account for every refusal',
      );
      // Only reasons that were actually decided are present: naming a category
      // with a zero count would be a diagnostic the pipeline never measured.
      expect(
        report.rejectedByReason.containsKey(RegionRejection.unusableCrop),
        isFalse,
      );
      expect(
        report.rejectedByReason.containsKey(RegionRejection.candidateCap),
        isFalse,
      );
    });

    test('a clean photo reports no refusal and no summary', () async {
      final report = await arrange(
        service(segmenter: (bytes) async => segmentDocumentBytes(bytes)),
        [('بطاقتان.png', _png(_twoCards()))],
      );

      expect(report.rejectedRegions, 0);
      expect(report.rejectedByReason, isEmpty);
      expect(report.rejectedSummary, isNull);
      expect(report.rejectedHeadline, isNull);
      expect(report.project.documents, hasLength(2));
      expect(report.project.items, hasLength(2));
    });

    test('the tally aggregates across a batch of photos', () async {
      final report = await arrange(
        service(
          segmenter: stubSegmenter([_refused(RegionRejection.unusableCrop)]),
        ),
        [('الأولى.png', _blankDesk), ('الثانية.png', _blankDesk)],
      );

      expect(report.rejectedRegions, 2);
      expect(report.rejectedByReason, {RegionRejection.unusableCrop: 2});
    });

    test('the real segmenter produces the tally, not just the stub', () async {
      final report = await arrange(
        service(segmenter: (bytes) async => segmentDocumentBytes(bytes)),
        [('ثلاث مناطق.png', _png(_twoCardsWithFurniture()))],
      );

      expect(report.rejectedRegions, 2);
      expect(report.rejectedByReason, {
        RegionRejection.frameArtifact: 1,
        RegionRejection.implausibleAspect: 1,
      });
      // The two real cards are still documents: reporting a refusal must never
      // cost a valid detection.
      expect(report.project.documents, hasLength(2));
      expect(report.project.items, hasLength(2));
    });

    test('reprocessing reports the same tally as the import did', () async {
      final s = service(
        segmenter: stubSegmenter([
          _refused(RegionRejection.frameArtifact),
          _refused(RegionRejection.implausibleAspect),
        ]),
      );
      final imported = await arrange(s, [('صورة.png', _blankDesk)]);
      final ids = [for (final asset in imported.project.assets) asset.id];
      final rerun = await s.reprocessImages(imported.project, ids);

      expect(rerun, isNotNull);
      expect(rerun!.rejectedRegions, imported.rejectedRegions);
      expect(rerun.rejectedByReason, imported.rejectedByReason);
      expect(rerun.rejectedSummary, imported.rejectedSummary);
    });

    test('a tally that contradicts the count is refused', () {
      expect(
        () => AutomaticLayoutReport(
          project: projectFixture(),
          cropped: 0,
          notDetected: 0,
          rejectedRegions: 2,
          rejectedByReason: const {RegionRejection.frameArtifact: 1},
          warnings: const [],
        ),
        throwsA(isA<AssertionError>()),
        reason: 'two surfaces must never tell the user different stories',
      );
    });
  });

  group('the Arabic feedback', () {
    test('names the count, the categories and the way back', () async {
      final report = await arrange(
        service(
          segmenter: stubSegmenter([
            _refused(RegionRejection.frameArtifact),
            _refused(RegionRejection.implausibleAspect),
            _refused(
              RegionRejection.implausibleAspect,
              region: [.5, .1, .6, .9],
            ),
          ]),
        ),
        [('صورة.png', _blankDesk)],
      );

      final summary = report.rejectedSummary!;
      expect(summary, contains('3'));
      expect(
        summary,
        contains(regionRejectionLabel(RegionRejection.frameArtifact)),
      );
      expect(
        summary,
        contains(regionRejectionLabel(RegionRejection.implausibleAspect)),
      );
      expect(summary, contains(rejectedRegionsRecoveryHint));
      // It must say nothing entered the project, or the user cannot tell a
      // refusal from a document that is merely waiting for review.
      expect(summary, contains('لم تُضف إلى المشروع'));
      // No claim of understanding the image: there is no OCR engine in this
      // build, so the wording must not imply one read the region.
      expect(summary, isNot(contains('OCR')));
      expect(summary, isNot(contains('نص')));
    });

    test('aggregates: one warning per photo, never one per region', () async {
      final report = await arrange(
        service(
          segmenter: stubSegmenter([
            for (var i = 0; i < 5; i++)
              _refused(
                RegionRejection.implausibleAspect,
                region: [.1 + i * .05, .1, .14 + i * .05, .9],
              ),
          ]),
        ),
        [('صورة.png', _blankDesk)],
      );

      expect(report.rejectedRegions, 5);
      final aggregated = report.warnings
          .where((w) => w.contains('تجاهل التقسيم'))
          .toList();
      expect(aggregated, hasLength(1), reason: '${report.warnings}');
      expect(aggregated.single, contains('5'));
      // One reason was decided, so its label is named once — not five times.
      final label = regionRejectionLabel(RegionRejection.implausibleAspect);
      expect(aggregated.single.split(label).length - 1, 1);
      expect(report.rejectedSummary, isNot(contains('\n')));
    });

    test('the headline is the short form for a crowded banner', () async {
      final report = await arrange(
        service(
          segmenter: stubSegmenter([_refused(RegionRejection.frameArtifact)]),
        ),
        [('صورة.png', _blankDesk)],
      );

      final headline = report.rejectedHeadline!;
      expect(headline, contains('1'));
      expect(
        headline,
        contains(regionRejectionLabel(RegionRejection.frameArtifact)),
      );
      expect(headline, isNot(contains(rejectedRegionsRecoveryHint)));
      expect(headline.length, lessThan(report.rejectedSummary!.length));
      // Both come from one tally, so they can never disagree about the count.
      expect(report.rejectedSummary, startsWith(headline));
    });

    test('every rejection reason has a label the summary can use', () {
      for (final reason in RegionRejection.values) {
        expect(regionRejectionLabel(reason), isNotEmpty, reason: '$reason');
      }
      final all = rejectedRegionsSummary(4, {
        for (final reason in RegionRejection.values) reason: 1,
      })!;
      for (final reason in RegionRejection.values) {
        expect(all, contains(regionRejectionLabel(reason)));
      }
      expect(rejectionTally(const []), isEmpty);
      expect(rejectedRegionsMessage(const []), isNull);
      expect(rejectedRegionsSummary(0, const {}), isNull);
      expect(rejectedRegionsHeadline(0, const {}), isNull);
    });
  });
}
