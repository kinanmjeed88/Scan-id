import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/multi_document_segmentation_flag.dart';
import 'package:scan_id/application/smart_recognition_flag.dart';

/// Smart Recognition remains opt-in and OFF in the shipping configuration;
/// its flag stays app-level and never enters project persistence.
void main() {
  test('Smart Recognition feature flag is OFF by default', () {
    expect(smartRecognitionEnabled, isFalse);
  });

  test('the disabled app-level flag denies both request states', () {
    expect(smartRecognitionAllows(false), isFalse);
    expect(smartRecognitionAllows(true), isFalse);
  });

  test('automatic segmentation is disabled without a qualified detector', () {
    expect(multiDocumentSegmentationEnabled, isFalse);
    expect(smartRecognitionEnabled, isFalse);
  });
}
