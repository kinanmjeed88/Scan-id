import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/smart_recognition_flag.dart';

/// The Smart Recognition gate is scaffolding only in Phase 1B and must start
/// OFF, so today's import path is byte-for-byte unchanged while the new
/// pipeline is introduced (GATE 0 / section H).
void main() {
  test('Smart Recognition feature flag starts OFF by default', () {
    expect(smartRecognitionEnabled, isFalse);
  });

  test('allows() stays false while the feature is off, whatever the gate', () {
    expect(smartRecognitionAllows(false), isFalse);
    expect(smartRecognitionAllows(true), isFalse);
  });
}
