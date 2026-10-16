import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/smart_recognition_flag.dart';

/// Smart Recognition is enabled in this build so multi-document images
/// can be segmented; the flag stays app-level and never enters project persistence.
void main() {
  test('Smart Recognition feature flag is ON in this build', () {
    expect(smartRecognitionEnabled, isTrue);
  });

  test('the enabled app-level flag follows the request state', () {
    expect(smartRecognitionAllows(false), isFalse);
    expect(smartRecognitionAllows(true), isTrue);
  });
}
