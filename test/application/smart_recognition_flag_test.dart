import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/multi_document_segmentation_flag.dart';
import 'package:scan_id/application/smart_recognition_flag.dart';

/// The shipped app runs the pipeline; a host that says nothing keeps the
/// legacy intake. The flag stays app-level and never enters project storage.
void main() {
  test('the shipped application enables smart recognition', () {
    expect(appSmartRecognitionEnabled, isTrue);
    expect(smartRecognitionAllows(true), isTrue);
    expect(smartRecognitionAllows(false), isFalse);
  });

  test('a host that says nothing keeps the legacy intake', () {
    expect(smartRecognitionEnabled, isFalse);
    expect(smartRecognitionEnabled && appSmartRecognitionEnabled, isFalse);
  });

  test('automatic segmentation is still disabled', () {
    expect(multiDocumentSegmentationEnabled, isFalse);
  });
}
