import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/validation.dart';

/// Pure-model (de)serialization contracts for the v5 recognition structures.
///
/// These hold no I/O and no migration; they pin the JSON shape the schema and
/// migration rely on: absent values are omitted (never a fabricated zero), the
/// final confidence is keyed `final`, preset confidence lives on
/// [PresetSelection] (not [ConfidenceSet]), and [UserOverride] carries
/// recognition-level fields only.
void main() {
  group('Confidence / ConfidenceSet', () {
    test('Confidence round-trips value, reason, producer and version', () {
      final c = Confidence(
        value: 0.42,
        reason: 'legacy scalar (pre-v5)',
        producer: 'suggestDocumentType',
        version: 'legacy',
      );
      final json = c.toJson();
      expect(json, {
        'value': 0.42,
        'reason': 'legacy scalar (pre-v5)',
        'producer': 'suggestDocumentType',
        'version': 'legacy',
      });
      expect(Confidence.fromJson(json).toJson(), json);
    });

    test('absent dimensions are omitted, never a fabricated zero', () {
      final set = ConfidenceSet(
        classification: Confidence(value: 0.9, producer: 'p'),
        finalConfidence: Confidence(value: 0.9, producer: 'p'),
      );
      final json = set.toJson();
      // detection / geometry / ocr are unavailable for a legacy import: they
      // must not appear at all, and never as numeric zero.
      expect(json.containsKey('detection'), isFalse);
      expect(json.containsKey('geometry'), isFalse);
      expect(json.containsKey('ocr'), isFalse);
      expect(json.containsKey('classification'), isTrue);
      expect(json.containsKey('final'), isTrue);
      // `preset` is NOT a fusion dimension; it must never be serialized here.
      expect(json.containsKey('preset'), isFalse);
      final restored = ConfidenceSet.fromJson(json);
      expect(restored.detection, isNull);
      expect(restored.geometry, isNull);
      expect(restored.ocr, isNull);
      expect(restored.classification?.value, 0.9);
      expect(restored.finalConfidence?.value, 0.9);
      expect(restored.toJson(), json);
    });

    test('final confidence is keyed `final`, not `finalConfidence`', () {
      final set = ConfidenceSet(finalConfidence: Confidence(value: 1));
      expect(set.toJson().keys, contains('final'));
      expect(set.toJson().keys, isNot(contains('finalConfidence')));
      final restored = ConfidenceSet.fromJson({
        'final': {'value': 1.0},
      });
      expect(restored.finalConfidence?.value, 1);
    });
  });

  group('PresetSelection', () {
    test('resolved/awaiting round-trip with presetConfidence', () {
      const resolved = PresetSelection.resolved(
        'builtin-passport',
        presetConfidence: 0.8,
      );
      final json = resolved.toJson();
      expect(json, {
        'variantId': 'builtin-passport',
        'presetConfidence': 0.8,
        'awaitingSize': false,
        'candidates': <String>[],
      });
      expect(PresetSelection.fromJson(json).toJson(), json);

      const awaiting = PresetSelection.awaiting();
      expect(awaiting.awaitingSize, isTrue);
      expect(awaiting.variantId, isNull);
      expect(awaiting.presetConfidence, isNull);
      expect(
        PresetSelection.fromJson(awaiting.toJson()).toJson(),
        awaiting.toJson(),
      );
    });

    test('presetConfidence is absent (not zero) when never scored', () {
      // Legacy presets are resolved by kind, never scored.
      const resolved = PresetSelection.resolved('builtin-passport');
      expect(resolved.presetConfidence, isNull);
      expect(resolved.toJson().containsKey('presetConfidence'), isTrue);
      expect(resolved.toJson()['presetConfidence'], isNull);
      final round = PresetSelection.fromJson(resolved.toJson());
      expect(round.presetConfidence, isNull);
    });
  });

  group('ProcessedAssetRef', () {
    test('round-trips crop corners, output size and effective dpi', () {
      final ref = ProcessedAssetRef(
        workingPath: 'projects/p1/processed/proc1/working.png',
        thumbnailPath: 'projects/p1/processed/proc1/thumb.jpg',
        width: 1200,
        height: 760,
        orientation: 1,
        processingVersion: 'legacy-v4',
        corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
        outputWidth: 1200,
        outputHeight: 760,
        effectiveDpi: 300,
      );
      final json = ref.toJson();
      expect(json['corners'], isA<List<Object?>>());
      expect((json['corners']! as List<Object?>).length, 4);
      expect(json['outputWidth'], 1200);
      expect(json['outputHeight'], 760);
      expect(json['effectiveDpi'], 300);
      final restored = ProcessedAssetRef.fromJson(json);
      expect(restored.toJson(), json);
      expect(restored.corners?.length, 4);
      expect(restored.outputWidth, 1200);
      expect(restored.effectiveDpi, 300);
    });

    test('optional crop fields are omitted when absent (never fabricated)', () {
      final ref = ProcessedAssetRef(
        workingPath: 'projects/p1/assets/a1/working.png',
        thumbnailPath: 'projects/p1/assets/a1/thumb.jpg',
        width: 400,
        height: 250,
      );
      final json = ref.toJson();
      expect(json.containsKey('corners'), isFalse);
      expect(json.containsKey('outputWidth'), isFalse);
      expect(json.containsKey('outputHeight'), isFalse);
      expect(json.containsKey('effectiveDpi'), isFalse);
      final restored = ProcessedAssetRef.fromJson(json);
      expect(restored.corners, isNull);
      expect(restored.outputWidth, isNull);
      expect(restored.outputHeight, isNull);
      expect(restored.effectiveDpi, isNull);
      expect(restored.toJson(), json);
    });

    test('working and thumbnail paths must be independent', () {
      expect(
        () => ProcessedAssetRef(
          workingPath: 'projects/p1/assets/a1/working.png',
          thumbnailPath: 'projects/p1/assets/a1/working.png',
          width: 10,
          height: 10,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('DetectionRef', () {
    test('round-trips optional polygon and bbox', () {
      final ref = DetectionRef(
        detectionId: 'det1',
        producer: 'detector-x',
        version: '1.0',
        polygon: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
        bbox: RectMm(0, 0, 10, 5),
      );
      final json = ref.toJson();
      expect((json['polygon']! as List<Object?>).length, 4);
      expect(json['bbox'], {'x': 0.0, 'y': 0.0, 'width': 10.0, 'height': 5.0});
      final restored = DetectionRef.fromJson(json);
      expect(restored.toJson(), json);
      expect(restored.bbox?.width, 10);
    });

    test('polygon and bbox are omitted when absent', () {
      final ref = DetectionRef(
        detectionId: 'det1',
        producer: 'legacy-import',
        version: 'legacy-v4',
      );
      final json = ref.toJson();
      expect(json.containsKey('polygon'), isFalse);
      expect(json.containsKey('bbox'), isFalse);
      expect(json.containsKey('detectionConfidence'), isTrue);
      expect(json['detectionConfidence'], isNull);
      expect(DetectionRef.fromJson(json).toJson(), json);
    });
  });

  group('PresetSnapshot', () {
    test('is a frozen value that round-trips without re-asserting bounds', () {
      final snap = PresetSnapshot(
        variantId: 'builtin-passport',
        widthMm: 125,
        heightMm: 88,
        status: PresetStatus.standard,
      );
      final json = snap.toJson();
      expect(json, {
        'variantId': 'builtin-passport',
        'widthMm': 125.0,
        'heightMm': 88.0,
        'status': 'standard',
      });
      // Immutability: fields are final; a second read yields an equal snapshot.
      final restored = PresetSnapshot.fromJson(json);
      expect(restored.toJson(), json);
      expect(restored.variantId, snap.variantId);
      expect(restored.status, snap.status);
    });
  });

  group('UserOverride', () {
    test('recognition-level only — no page/position/layout fields', () {
      final override = UserOverride(
        documentKind: DocumentKind.passport,
        presetVariantId: 'builtin-passport',
        side: SideKind.front,
        pairing: PairingState.single,
        dismissed: false,
        fields: const ['documentKind'],
      );
      final json = override.toJson();
      // The complete key set — anything layout/A4/page/position would be a bug.
      expect(json.keys.toSet(), <String>{
        'documentKind',
        'presetVariantId',
        'corners',
        'side',
        'pairing',
        'dismissed',
        'fields',
      });
      for (final forbidden in const [
        'x',
        'y',
        'width',
        'height',
        'rotation',
        'pageIndex',
        'zIndex',
        'keepAspectRatio',
        'groupId',
      ]) {
        expect(
          json.containsKey(forbidden),
          isFalse,
          reason: 'UserOverride must not carry layout field "$forbidden"',
        );
      }
      expect(UserOverride.fromJson(json).toJson(), json);
    });

    test('round-trips user-confirmed corners', () {
      final override = UserOverride(
        corners: [
          Point2(0.1, 0.1),
          Point2(0.9, 0.1),
          Point2(0.9, 0.9),
          Point2(0.1, 0.9),
        ],
      );
      final json = override.toJson();
      expect((json['corners']! as List<Object?>).length, 4);
      expect(UserOverride.fromJson(json).corners?.length, 4);
      expect(UserOverride.fromJson(json).toJson(), json);
    });
  });
}
