import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/smart_recognition_flag.dart';

/// Smart Recognition ships ENABLED: the import intake routes through the
/// recognition pipeline. The flag stays an app-level switch (never part of
/// the schema) so the legacy byte-for-byte path remains one constant away.
void main() {
  test('Smart Recognition feature flag is ON in this build', () {
    expect(smartRecognitionEnabled, isTrue);
  });

  test('allows() still honours the per-call gate', () {
    expect(smartRecognitionAllows(false), isFalse);
    expect(smartRecognitionAllows(true), isTrue);
  });
}
