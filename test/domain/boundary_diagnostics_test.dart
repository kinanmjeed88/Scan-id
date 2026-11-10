import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/recognition.dart';

void main() {
  test('all measured gate failures survive persistence without OCR text', () {
    final messages = [
      for (final reason in BoundaryReviewReason.values)
        boundaryReviewReasonMessage(
          reason,
          modelConfidence: .764,
          minAutoAcceptConfidence: .55,
        ),
    ];
    final detection = DetectionRef(
      detectionId: 'a-d0',
      producer: 'test',
      version: '1',
      detectionConfidence: Confidence(value: .764),
      boundaryDiagnostics: messages,
    );
    final restored = DetectionRef.fromJson(detection.toJson());
    expect(restored.boundaryDiagnostics, messages);
    expect(restored.detectionConfidence!.value, .764);
    expect(restored.boundaryDiagnostics.join(' '), contains('اختلف كاشفا'));
  });
  test('measured detection facts survive persistence as codes', () {
    final traces = [
      const BoundaryDetectorTrace(
        modelId: 'docquadnet256',
        outcome: BoundaryDetectorOutcome.proposal,
        confidence: .62,
      ).encode(),
      const BoundaryDetectorTrace(
        modelId: 'docaligner-1.1.1-fastvit-sa24',
        outcome: BoundaryDetectorOutcome.failed,
        errorType: 'OnnxRuntimeException',
      ).encode(),
      'disagreement=0.013',
      'aspect=1.583',
      'area=0.410',
    ];
    final detection = DetectionRef(
      detectionId: 'a-d0',
      producer: 'docquadnet256->docaligner-1.1.1-fastvit-sa24',
      version: '1',
      detectionTrace: traces,
    );
    final restored = DetectionRef.fromJson(detection.toJson());
    expect(restored.detectionTrace, traces);
    expect(restored.detectionTrace.join(' '), isNot(contains('الاسم')));
  });

  test('a damaged trace decodes to nothing instead of an invented outcome', () {
    expect(BoundaryDetectorTrace.decode('model=x;outcome=nonsense'), isNull);
    expect(BoundaryDetectorTrace.decode(''), isNull);
    expect(BoundaryDetectorTrace.decode('outcome=proposal'), isNull);
    final failed = BoundaryDetectorTrace.decode(
      'model=docaligner;outcome=failed;error=StateError',
    );
    expect(failed!.outcome, BoundaryDetectorOutcome.failed);
    expect(failed.errorType, 'StateError');
    expect(failed.confidence, isNull);
  });

  test('legacy records have no fabricated decision failures', () {
    final restored = DetectionRef.fromJson({
      'detectionId': 'a-d0',
      'producer': 'test',
      'version': '1',
    });
    expect(restored.boundaryDiagnostics, isEmpty);
    expect(restored.toJson().containsKey('boundaryDiagnostics'), isFalse);
  });
}
