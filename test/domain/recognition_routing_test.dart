import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_routing.dart';

DocumentRecord _record({
  double? finalValue,
  RecognitionStatus status = RecognitionStatus.recognized,
  bool awaitingSize = false,
  PairingState pairing = PairingState.single,
  List<UserOverride> overrides = const [],
}) => DocumentRecord(
  id: 'doc-a',
  sourceImageId: 'asset1',
  sides: [
    DocumentSide(
      id: 'side-a',
      side: SideKind.unknown,
      processedAsset: ProcessedAssetRef(
        workingPath: 'projects/p/assets/a/working.png',
        thumbnailPath: 'projects/p/assets/a/thumb.jpg',
        width: 856,
        height: 540,
      ),
    ),
  ],
  recognition: RecognitionResult(
    documentKind: status == RecognitionStatus.unknown
        ? DocumentKind.unknown
        : DocumentKind.unifiedNationalId,
    status: status,
    confidences: ConfidenceSet(
      finalConfidence: finalValue == null
          ? null
          : Confidence(value: finalValue),
    ),
    preset: awaitingSize
        ? const PresetSelection.awaiting()
        : const PresetSelection.resolved('builtin-unifiedNationalId'),
  ),
  pairing: pairing,
  overrides: overrides,
  provenance: Provenance(
    sourceImageId: 'asset1',
    detectionIds: ['asset1-d0'],
    processedAssetVersion: 'smart-1',
    pipelineVersion: 'smart-1',
  ),
);

void main() {
  group('bands', () {
    test('thresholds split at .9 and .7', () {
      expect(bandFor(.95), RecognitionBand.autoCandidate);
      expect(bandFor(.9), RecognitionBand.autoCandidate);
      expect(bandFor(.89), RecognitionBand.review);
      expect(bandFor(.7), RecognitionBand.review);
      expect(bandFor(.69), RecognitionBand.unresolved);
      expect(bandFor(0), RecognitionBand.unresolved);
    });
  });

  group('weightedGeometricMean', () {
    test('absent components are excluded, never zero', () {
      final some = weightedGeometricMean([(.5, .8), (.5, null)]);
      expect(some, closeTo(.8, 1e-9));
    });

    test('returns null when nothing is available', () {
      expect(weightedGeometricMean([(.5, null), (.5, null)]), isNull);
    });

    test('a zero component stays influential without erasing the rest', () {
      final mean = weightedGeometricMean([(.5, 0), (.5, 1)])!;
      expect(mean, greaterThan(0));
      expect(mean, lessThan(.1));
    });

    test('is the plain geometric mean for equal weights', () {
      expect(weightedGeometricMean([(1, .4), (1, .9)]), closeTo(.6, 1e-9));
    });
  });

  group('routing rules', () {
    test('R1: auto needs two sources with one non-OCR', () {
      final ocrOnly = routeRecognition(
        finalValue: .95,
        independentSources: 1,
        nonOcrSources: 0,
        availableComponents: const [.95],
        classConflict: false,
      );
      expect(ocrOnly.band, RecognitionBand.review);
      expect(ocrOnly.reasons, contains('R1:insufficient-sources'));

      final enough = routeRecognition(
        finalValue: .95,
        independentSources: 2,
        nonOcrSources: 1,
        availableComponents: const [.95, .92],
        classConflict: false,
      );
      expect(enough.band, RecognitionBand.autoCandidate);
    });

    test('R2: a weak component caps to review', () {
      final capped = routeRecognition(
        finalValue: .93,
        independentSources: 2,
        nonOcrSources: 2,
        availableComponents: const [.95, .4],
        classConflict: false,
      );
      expect(capped.band, RecognitionBand.review);
      expect(capped.reasons, contains('R2:component-floor'));
    });

    test('R3: a class conflict caps to review', () {
      final capped = routeRecognition(
        finalValue: .93,
        independentSources: 2,
        nonOcrSources: 2,
        availableComponents: const [.95, .92],
        classConflict: true,
      );
      expect(capped.band, RecognitionBand.review);
      expect(capped.reasons, contains('R3:class-conflict'));
    });

    test('caps change the band, not the stored value', () {
      final decision = routeRecognition(
        finalValue: .95,
        independentSources: 1,
        nonOcrSources: 0,
        availableComponents: const [.95],
        classConflict: false,
      );
      // The band is review but the caller keeps .95 as the honest value.
      expect(decision.band, RecognitionBand.review);
    });
  });

  group('review queue derivation', () {
    test('shipped mode is reviewAll: even auto candidates queue', () {
      expect(automationMode, AutomationMode.reviewAll);
      final record = _record(finalValue: .95);
      expect(recordNeedsReview(record), isTrue);
      expect(
        reviewReasons(record),
        contains('مؤهل تلقائياً — بانتظار التأكيد'),
      );
    });

    test('a confirmed record leaves the queue', () {
      final record = _record(
        finalValue: .95,
        overrides: [
          UserOverride(fields: const [reviewConfirmedField]),
        ],
      );
      expect(isUserResolved(record), isTrue);
      expect(recordNeedsReview(record), isFalse);
    });

    test('kind/side/pairing overrides and dismissal also resolve', () {
      for (final override in [
        UserOverride(documentKind: DocumentKind.passport),
        UserOverride(side: SideKind.front),
        UserOverride(pairing: PairingState.single),
        UserOverride(dismissed: true),
      ]) {
        expect(
          recordNeedsReview(_record(finalValue: .5, overrides: [override])),
          isFalse,
        );
      }
    });

    test('reasons name every outstanding problem', () {
      final record = _record(
        finalValue: .75,
        status: RecognitionStatus.uncertain,
        awaitingSize: true,
        pairing: PairingState.ambiguous,
      );
      final reasons = reviewReasons(record);
      expect(reasons, contains('ثقة متوسطة'));
      expect(reasons, contains('تصنيف غير حاسم'));
      expect(reasons, contains('بانتظار تحديد المقاس'));
      expect(reasons, contains('اقتران وجهين غير مؤكد'));
    });

    test('a record without recognition never queues', () {
      final record = DocumentRecord(
        id: 'doc-a',
        sourceImageId: 'asset1',
        sides: _record().sides,
        pairing: PairingState.unknown,
        provenance: _record().provenance,
      );
      expect(recordNeedsReview(record), isFalse);
    });

    test('missing final confidence queues explicitly', () {
      expect(reviewReasons(_record()), contains('بلا ثقة نهائية'));
    });
  });
}
