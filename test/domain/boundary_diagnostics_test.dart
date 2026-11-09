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
