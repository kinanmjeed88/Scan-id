import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/image_journey_report.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/imaging/docaligner_model.dart';
import 'package:scan_id/imaging/docquad_model.dart';

import '../fixtures.dart';

// Pins the two journey-report defects established from the field logs:
//
//  1. A crop revision keeps the source asset's id (see `_saveRevision`), so a
//     report that looked the asset up by id described the CROP as the COPY.
//     The field log proves it: the copy step reported 334x217 while the file on
//     disk was 399x501 — and 334x217 is exactly the crop's output size.
//  2. `detail` is clipped at 240 characters and the clipped tail carried the
//     detector score, so decision evidence was lost from the log.
//
// These tests are pure data: no image, no OCR text, no personal data.

const _sourceW = 399;
const _sourceH = 501;
const _cropW = 334;
const _cropH = 217;

/// The asset as the project stores it AFTER the automatic crop: the id is still
/// the imported one (that is the defect's precondition), the pixels are the
/// crop's.
ImageAsset _croppedUnderSameId() {
  final base = assetFixture();
  return ImageAsset(
    id: base.id,
    name: base.name,
    originalPath: base.originalPath,
    workingPath: base.workingPath,
    thumbnailPath: base.thumbnailPath,
    width: _cropW,
    height: _cropH,
  );
}

DocumentSide _warpedSide() => DocumentSide(
  id: 's1',
  side: SideKind.unknown,
  processedAsset: ProcessedAssetRef(
    workingPath: 'projects/project1/processed/crop-e1/working.png',
    thumbnailPath: 'projects/project1/processed/crop-e1/thumb.jpg',
    width: _cropW,
    height: _cropH,
    outputWidth: _cropW,
    outputHeight: _cropH,
    corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
  ),
  detection: DetectionRef(
    detectionId: 'det-1',
    producer: 'docquad',
    version: 'v1',
    // The ids the shipped models write. A capitalised look-alike used to
    // stand here for the second one, and hid that its facts were being filed
    // under the generic `detector_` keys.
    detectionTrace: [
      'model=$docQuadNetModelId;outcome=proposal;confidence=0.211',
      'model=$docAlignerModelId;outcome=noQuad',
      'disagreement=0.013',
      'aspect=1.69',
      'area=0.057',
      'geometry=0.091',
      'review=modelNotCorroborated',
      'review=lowModelConfidence',
    ],
    boundaryDiagnostics: ['لم تتوفر حدود صالحة من كاشف ثانٍ للتحقق'],
  ),
);

DocumentRecord _record() {
  final asset = _croppedUnderSameId();
  return DocumentRecord(
    id: 'd1',
    sourceImageId: asset.id,
    sides: [_warpedSide()],
    pairing: PairingState.single,
    provenance: Provenance(
      sourceImageId: asset.id,
      detectionIds: const ['det-1'],
      processedAssetVersion: 'smart-1',
      pipelineVersion: 'pipeline-v1',
    ),
  );
}

/// A project in the state the field log was exported from: one asset carrying
/// the crop, under the id the import assigned.
Project _project() {
  final asset = _croppedUnderSameId();
  return projectFixture().copyWith(
    assets: [asset],
    documents: [_record()],
    // An active record must own a layout item (Project's own invariant), so the
    // fixture carries the placement a real crop would have produced.
    items: [
      DocumentItem(
        id: 'item1',
        assetId: asset.id,
        documentId: 'd1',
        sideId: 's1',
        x: 20,
        y: 25,
        width: 90,
        height: 55,
      ),
    ],
  );
}

ImportedImageFact _fact({int? copiedWidth, int? copiedHeight}) =>
    ImportedImageFact(
      name: 'صورة.jpg',
      assetId: _project().assets.single.id,
      copyDurationMs: 411,
      copiedWidth: copiedWidth,
      copiedHeight: copiedHeight,
    );

Map<JourneyStage, JourneyStep> _stepsFor(ImportedImageFact fact) {
  final project = _project();
  final journey = buildImageJourneys(
    batchId: 'batch-0001',
    project: project,
    images: [fact],
    startedAt: DateTime.utc(2026, 11, 11, 20, 8),
  ).single;
  return {for (final step in journey.steps) step.stage: step};
}

void main() {
  group('the copy step reports the copy, never the crop', () {
    test('a cropped asset under the same id cannot rewrite the copy size', () {
      final steps = _stepsFor(
        _fact(copiedWidth: _sourceW, copiedHeight: _sourceH),
      );

      // The crop step speaks for the crop...
      expect(steps[JourneyStage.crop]!.fields['outputWidth'], _cropW);
      expect(steps[JourneyStage.crop]!.fields['outputHeight'], _cropH);
      expect(steps[JourneyStage.crop]!.detail, contains('334×217'));

      // ...and the copy step speaks for the copy, not for the crop.
      expect(steps[JourneyStage.copy]!.fields['copiedWidth'], _sourceW);
      expect(steps[JourneyStage.copy]!.fields['copiedHeight'], _sourceH);
      expect(steps[JourneyStage.copy]!.detail, contains('399×501'));
      expect(
        steps[JourneyStage.copy]!.detail,
        isNot(contains('334×217')),
        reason: 'reporting the crop size as the copy size is the defect',
      );
    });

    test('without a recorded copy size the step refuses to state one', () {
      // A caller that does not capture the size must not fall back to the
      // asset's width, because by then it may be the crop's.
      final copy = _stepsFor(_fact())[JourneyStage.copy]!;
      expect(copy.detail, isNot(contains('334×217')));
      expect(copy.detail, isNot(contains('399×501')));
      expect(copy.detail, contains('غير مسجّلة'));
      expect(copy.fields.containsKey('copiedWidth'), isFalse);
    });

    test('the copy duration is still reported when it was measured', () {
      expect(_stepsFor(_fact())[JourneyStage.copy]!.durationMs, 411);
    });
  });

  group('decision evidence survives the detail clip', () {
    test('every measured number is in fields, not only in the sentence', () {
      final detection = _stepsFor(
        _fact(copiedWidth: _sourceW, copiedHeight: _sourceH),
      )[JourneyStage.detection]!;

      // These are the exact numbers the field log lost to the 240-char clip.
      expect(detection.fields['area'], closeTo(0.057, 1e-9));
      expect(detection.fields['geometry'], closeTo(0.091, 1e-9));
      expect(detection.fields['aspect'], closeTo(1.69, 1e-9));
      expect(detection.fields['disagreement'], closeTo(0.013, 1e-9));

      // Detector outcomes are codes, so a clipped sentence cannot hide them.
      expect(detection.fields['docquadnet_outcome'], 'proposal');
      expect(detection.fields['docquadnet_confidence'], closeTo(0.211, 1e-9));
      expect(detection.fields['docaligner_outcome'], 'noQuad');
      // No accepted polygon was recorded, so the step must not claim one: the
      // key is absent rather than asserted false.
      expect(detection.fields.containsKey('accepted'), isFalse);
      expect(detection.outcome, JourneyOutcome.review);
      // The refusal trail is a count, so no message text enters the field map.
      expect(detection.fields['reasons'], 1);
    });

    test('the sentence stays within the detail bound while fields do not', () {
      final detection = _stepsFor(
        _fact(copiedWidth: _sourceW, copiedHeight: _sourceH),
      )[JourneyStage.detection]!;
      expect(
        detection.detail.length,
        lessThanOrEqualTo(JourneyStep.maxDetailLength),
      );
      expect(detection.fields, isNotEmpty);
    });

    test('the review reasons are kept as codes, in decision order', () {
      final fields = _stepsFor(_fact())[JourneyStage.detection]!.fields;
      // The sentences for these reasons are appended to the detail and were
      // cut mid-word in the field export; the codes cannot be.
      expect(fields['review_1'], 'modelNotCorroborated');
      expect(fields['review_2'], 'lowModelConfidence');
      expect(fields.containsKey('review_3'), isFalse);
    });

    test('a detector that produced no number records no number', () {
      final detection = _stepsFor(
        _fact(copiedWidth: _sourceW, copiedHeight: _sourceH),
      )[JourneyStage.detection]!;
      // DocAligner returned no quad, so a confidence key would invent data.
      expect(detection.fields.containsKey('docaligner_confidence'), isFalse);
      expect(detection.fields.containsKey('docquadnet_confidence'), isTrue);
    });
  });

  group('log schema stays backward compatible', () {
    test('an entry written before fields existed still reads', () {
      final step = JourneyStep.fromJson({
        'stage': JourneyStage.copy.name,
        'outcome': JourneyOutcome.passed.name,
        'detail': 'نُسخت إلى مساحة التطبيق (1200×1600 بكسل).',
      });
      expect(step.stage, JourneyStage.copy);
      expect(step.fields, isEmpty);
      expect(step.detail, contains('1200×1600'));
    });

    test('fields round-trip through JSON unchanged', () {
      final step = JourneyStep(
        stage: JourneyStage.detection,
        outcome: JourneyOutcome.review,
        detail: 'الكشف: DocAligner لم يجد مستنداً',
        fields: const {
          'docquadnet_outcome': 'proposal',
          'docquadnet_confidence': 0.211,
          'docaligner_outcome': 'noQuad',
          'area': 0.057,
          'geometry': 0.0907,
          'accepted': false,
        },
      );
      final restored = JourneyStep.fromJson(step.toJson());
      expect(restored.fields, step.fields);
      expect(restored.stage, step.stage);
      expect(restored.detail, step.detail);
    });

    test('an empty field map is omitted so the stored shape is unchanged', () {
      final step = JourneyStep(
        stage: JourneyStage.save,
        outcome: JourneyOutcome.passed,
        detail: 'حُفظ المشروع',
      );
      expect(step.toJson().containsKey('fields'), isFalse);
    });
  });

  group('fields cannot smuggle free text or personal data', () {
    test(
      'only numbers, booleans and short single-line strings are accepted',
      () {
        for (final bad in <Map<String, Object?>>[
          {
            'reasons': ['a', 'b'],
          },
          {'k': 'line one\nline two'},
          {'k' * (JourneyStep.maxFieldKeyLength + 1): 1},
          {'k': 'x' * (JourneyStep.maxFieldValueLength + 1)},
        ]) {
          expect(
            () => JourneyStep(
              stage: JourneyStage.detection,
              outcome: JourneyOutcome.review,
              detail: 'x',
              fields: bad,
            ),
            throwsA(anything),
            reason: 'must reject $bad',
          );
        }
      },
    );
  });
}
