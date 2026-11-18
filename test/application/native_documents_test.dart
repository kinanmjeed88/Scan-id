import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/native_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iq.scanid/local_documents');

  void answer(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Windows Explorer select keeps path glued to /select,', () {
    const path = r'C:\Users\me\AppData\Local\Temp\scan-exports\page.pdf';
    expect(windowsExplorerSelectArguments(path), ['/select,$path']);
    expect(windowsExplorerSelectArguments(path), hasLength(1));
  });

  test('an interrupted picker returns no files instead of hanging', () async {
    answer((call) async {
      throw PlatformException(code: 'interrupted', message: 'engine');
    });
    expect(await pickAndroidImages(), isEmpty);
  });

  test('a busy picker is treated as cancellation', () async {
    answer((call) async {
      throw PlatformException(code: 'busy', message: 'in flight');
    });
    expect(await pickAndroidImages(), isEmpty);
  });

  test('a missing plugin after engine reset cancels the picker', () async {
    answer((call) async {
      throw MissingPluginException('iq.scanid/local_documents');
    });
    expect(await pickAndroidImages(), isEmpty);
  });

  test('a picker engine failure is reported', () async {
    answer((call) async {
      throw PlatformException(code: 'open', message: 'fail');
    });
    await expectLater(pickAndroidImages(), throwsA(isA<StorageException>()));
  });
}
