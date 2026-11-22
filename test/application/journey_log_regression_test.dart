import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/intake_stage_log.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// Regression tests for the processing-log fix (the processing log must reveal
/// the boundary decision, the cause of a missing crop, and the per-document
/// recognition, measurement and placement results).
///
/// These tests drive the REAL batch path through
/// [ProjectService.arrangeImportedImages] with a controlled segmenter seam,
/// then read the recorded steps back from the [IntakeBatchLog].
///
/// The fixtures mirror the two families of the 2026-11-22 sample:
///
///   - crop not produced (five journeys): one measured region with no
///     trustworthy boundary. The sample reached that state through the
///     whole-frame fallback; determinism here comes from the honest
///     unresolved-region path, which has the same observable outcome (no crop,
///     one document, one item, no size confirmation, no placement).
///   - crop produced (five journeys): one measured region with a valid
///     quadrilateral.
///
/// Every value asserted below comes from the analysis the pipeline just
/// measured (the classification, the committed item), never recomputed.
void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_regression_');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  Uint8List syntheticImage() {
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

  Future<SegmentationResult> _unresolvedRegion(Uint8List bytes) async =>
      SegmentationResult(
        multi: false,
        candidates: const [
          SegmentCandidate(
            // A measured region with no usable quadrilateral: the review
            // vocabulary of an unresolved boundary, in the honest form.
            region: const [.1, .1, .9, .6045],
            reason: 'no-trustworthy-quad',
          ),
        ],
      );

  Future<SegmentationResult> _acceptedRegion(Uint8List bytes) async =>
      SegmentationResult(
        multi: false,
        candidates: [
          SegmentCandidate(
            region: const [.1, .1, .9, .6045],
            corners: const [
              Point2(.1, .1),
              Point2(.9, .1),
              Point2(.9, .6045),
              Point2(.1, .6045),
            ],
            detectionConfidence: .9,
            reason: 'component-support',
          ),
        ],
      );

  /// Runs a single-image batch and returns the log together with the asset id
  /// so the assertions can read only that image's records.
  Future<(IntakeBatchLog, String)> runBatch(
    Future<SegmentationResult> Function(Uint8List bytes) segmenter, {
    String name = 'صورة.png',
  }) async {
    final service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      smartRecognitionEnabled: true,
      segmenter: segmenter,
    );
    var project = await service.create('regression');
    final bytes = syntheticImage();
    project = (await service.importImages(project, [
      ImportSource(name, () => Stream.value(bytes)),
    ])).project;
    final assetId = project.assets.single.id;
    final log = IntakeBatchLog(batchId: 'regression-batch');
    await service.arrangeImportedImages(project, [assetId], stageLog: log);
    return (log, assetId);
  }

  List<IntakeStageRecord> recordsFor(IntakeBatchLog log, String assetId) {
    final records = <IntakeStageRecord>[];
    for (final logged in log.logs) {
      if (logged.assetId == assetId) records.addAll(logged.records);
    }
    return records;
  }

  IntakeStageRecord recordFor(
    IntakeBatchLog log,
    String assetId,
    JourneyStage stage,
  ) {
    final matches = recordsFor(
      log,
      assetId,
    ).where((r) => r.stage == stage).toList();
    expect(matches, isNotEmpty, reason: 'expected a record for ${stage.name}');
    return matches.single;
  }

  group('crop not produced (the sample’s five crop-review journeys)', () {
    test(
      'detection and crop records name the decision and the cause',
      () async {
        final (log, assetId) = await runBatch(_unresolvedRegion);
        final detection = recordFor(log, assetId, JourneyStage.detection);
        final crop = recordFor(log, assetId, JourneyStage.crop);

        // A measured region the decision rejects is NOT a detection pass.
        expect(detection.outcome, JourneyOutcome.review);
        expect(detection.fields['accepted'], isFalse);
        expect(detection.fields['regions'], 1);
        expect(detection.fields['decision'], isNotNull);
        expect(detection.fields['reason'], isNotNull);

        // The crop did not happen, and the cause is named, never silent.
        expect(crop.outcome, JourneyOutcome.review);
        expect(crop.fields['cropped'], 0);
        expect(crop.fields['notDetected'], 1);
        expect(crop.fields['accepted'], isFalse);
        expect(crop.fields['decision'], isNotNull);
        expect(crop.fields['reason'], isNotNull);
        expect(crop.detail, contains('قص'));
        // The committed document carries its own measurement facts.
        expect(crop.fields['kind'], 'unknown');
        expect(crop.fields['sizeConfirmed'], isFalse);
        expect(crop.fields['sizeSource'], 'provisional_image_dimensions');
        expect(crop.fields['widthMm'], isA<double>());
        expect(crop.fields['heightMm'], isA<double>());
      },
    );

    test('the recognition record names what the region classified', () async {
      final (log, assetId) = await runBatch(_unresolvedRegion);
      final recognition = recordFor(log, assetId, JourneyStage.recognition);

      expect(recognition.outcome, JourneyOutcome.review);
      expect(recognition.fields['known'], 0);
      expect(recognition.fields['kind'], 'unknown');
      expect(recognition.fields['status'], 'unknown');
      // An unclassified region invents no classification value.
      expect(recognition.fields['confidence'], isNull);
    });

    test(
      'the placement record names the unplaced document per-document',
      () async {
        final (log, assetId) = await runBatch(_unresolvedRegion);
        final placement = recordFor(log, assetId, JourneyStage.placement);

        expect(placement.outcome, JourneyOutcome.review);
        expect(placement.fields['placedItems'], 0);
        expect(placement.fields['i1_placed'], isFalse);
        expect(placement.fields['i1_sizeConfirmed'], isFalse);
        expect(
          placement.fields['i1_sizeSource'],
          'provisional_image_dimensions',
        );
        expect(placement.detail, contains('حدّد النوع'));
      },
    );
  });

  group('crop produced (the sample’s five crop-passed journeys)', () {
    test(
      'detection passes on the accepted decision; crop names state and facts',
      () async {
        final (log, assetId) = await runBatch(_acceptedRegion);
        final detection = recordFor(log, assetId, JourneyStage.detection);
        final crop = recordFor(log, assetId, JourneyStage.crop);

        expect(detection.outcome, JourneyOutcome.passed);
        expect(detection.fields['accepted'], isTrue);
        expect(detection.fields['decision'], 'accepted');
        expect(detection.fields['reason'], isNull);
        expect(detection.fields['regions'], 1);

        expect(crop.outcome, JourneyOutcome.passed);
        expect(crop.fields['cropped'], 1);
        expect(crop.fields['notDetected'], 0);
        expect(crop.fields['accepted'], isTrue);
        expect(crop.fields['kind'], 'unknown');
        expect(crop.fields['sizeConfirmed'], isFalse);
        expect(crop.fields['widthMm'], isA<double>());
        expect(crop.fields['heightMm'], isA<double>());
      },
    );

    test('the placement record names the unplaced, unconfirmed item', () async {
      final (log, assetId) = await runBatch(_acceptedRegion);
      final placement = recordFor(log, assetId, JourneyStage.placement);

      // Cropped, but its kind is unknown, so its size is not confirmed and it
      // is not placed — the record says exactly that.
      expect(placement.outcome, JourneyOutcome.review);
      expect(placement.fields['placedItems'], 0);
      expect(placement.fields['i1_placed'], isFalse);
      expect(placement.fields['i1_sizeConfirmed'], isFalse);
    });
  });
}
