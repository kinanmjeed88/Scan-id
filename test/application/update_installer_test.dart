import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/update_installer.dart';

/// The Android half of an update refuses a package before the installer is
/// offered it, whenever the package's publisher cannot be established. That
/// comparison belongs to Kotlin, because only the platform can read the
/// certificate of the app already installed; no test on a host can perform it.
///
/// What Dart owns is the answer a person reads, and it has to be true in both
/// directions: a deliberate refusal is not a malfunction, and a foreign-signed
/// package must never be described as a trouble opening the installer — that
/// wording would invite the person to retry until it slips through.
///
/// The last group reads the platform sources. It is not proof that the check
/// works on a handset; it is the gate that keeps the check, and the sentence
/// that goes with it, from being edited apart by someone who only reads Dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iq.scanid/updates');
  const installer = AndroidPackageInstaller(channel: channel);
  const packagePath =
      '/data/user/0/iq.scanid.scan_id/cache/scan-updates/app-release.apk';

  void answer(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  void refuseWith(String code, String detail) {
    answer((call) => throw PlatformException(code: code, message: detail));
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('the answer given to the person', () {
    test('a foreign publisher is refused, and said out loud', () async {
      final calls = <MethodCall>[];
      answer((call) {
        calls.add(call);
        throw PlatformException(
          code: 'signature',
          message: 'signer 00aa is not the pinned release certificate',
        );
      });

      final outcome = await installer.install(packagePath);

      expect(calls.single.method, 'install');
      expect(outcome.started, isFalse);
      expect(outcome.message, contains('لم تُفتح شاشة التثبيت'));
      // A refusal is not reported as a breakdown: the installer was never
      // reached, and the person is not asked to fix their device.
      expect(outcome.message, isNot(equals(installUnavailableMessage)));
      // The native detail names certificates and paths. Reading them out loud
      // would tell an attacker which pin to satisfy, and nothing here helps.
      expect(outcome.message, isNot(contains('pinned')));
      expect(outcome.message, isNot(contains('00aa')));
      expect(outcome.message, isNot(contains('scan-updates')));
    });

    test('a missing install allowance is named as one', () async {
      refuseWith('permission', 'not allowed to install');

      final outcome = await installer.install(packagePath);

      expect(outcome.started, isFalse);
      expect(outcome.message, contains('تثبيت التطبيقات المجهولة'));
      expect(outcome.message, isNot(contains('not allowed')));
    });

    test('a package deleted mid-flight asks for a fresh download', () async {
      refuseWith('missing', 'the file is gone');

      final outcome = await installer.install(packagePath);

      expect(outcome.started, isFalse);
      expect(outcome.message, contains('نزّله من جديد'));
    });

    test('a device with no installer says what is absent', () async {
      refuseWith('unavailable', 'no installer activity');

      final outcome = await installer.install(packagePath);

      expect(outcome.started, isFalse);
      expect(outcome.message, contains('لا يوجد مثبت تطبيقات'));
    });

    test('an answer with no sentence is not dressed up as one', () async {
      refuseWith('install', 'the intent could not be started');

      final outcome = await installer.install(packagePath);

      expect(outcome.started, isFalse);
      // Unknown codes mean the platform itself failed, which is exactly what
      // the fallback sentence says. A known refusal must not land here.
      expect(outcome.message, equals(installUnavailableMessage));
    });

    test('success is the installer opening, never an update applied', () async {
      answer((call) async => null);

      final outcome = await installer.install(packagePath);

      expect(outcome.started, isTrue);
      expect(outcome.message, contains('فُتح مثبت النظام'));
      expect(outcome.message, isNot(contains('اكتمل')));
    });

    test('a build with no native channel admits it cannot install', () async {
      const orphan = AndroidPackageInstaller(
        channel: MethodChannel('iq.scanid/absent'),
      );

      final outcome = await orphan.install(packagePath);

      expect(outcome.started, isFalse);
      expect(outcome.message, equals(installUnavailableMessage));
    });

    test('the platform decides whether an installer exists at all', () {
      expect(platformUpdateInstaller, returnsNormally);
      if (Platform.isAndroid) {
        expect(platformUpdateInstaller(), isA<AndroidPackageInstaller>());
      } else {
        expect(platformUpdateInstaller(), isNull);
      }
    });
  });

  group('the publisher check is still compiled in', () {
    final kotlin = _read(
      'android/app/src/main/kotlin/iq/scanid/scan_id/UpdateInstaller.kt',
    );
    final gradle = _read('android/app/build.gradle.kts');
    final dart = _read('lib/application/update_installer.dart');
    final releaseWorkflow = _read('.github/workflows/release-management.yml');

    test('the archive is opened for its signer, against both anchors', () {
      expect(kotlin, contains('getPackageArchiveInfo'));
      expect(kotlin, contains('GET_SIGNING_CERTIFICATES'));
      expect(kotlin, contains('GET_SIGNATURES'));
      expect(kotlin, contains('apkContentsSigners'));
      expect(kotlin, contains('signingCertificateHistory'));
      expect(kotlin, contains('MessageDigest.getInstance("SHA-256")'));
      expect(kotlin, contains('archive.packageName'));
      expect(kotlin, contains('BuildConfig.EXPECTED_UPDATE_CERT_SHA256'));
      // More than one current signer is not a publisher: refuse it, exactly
      // as the release job refuses such an APK.
      expect(kotlin, contains('signers.size != 1'));
    });

    test('the check answers before anything is handed over', () {
      final steps = [
        'val packageFile = verifiedFile(raw)',
        'val refusal = publisherRefusal(packageFile)',
        'if (refusal != null)',
        'startInstall(packageFile, reply)',
      ];
      final positions = steps.map(kotlin.indexOf).toList();
      for (final position in positions) {
        expect(position, greaterThanOrEqualTo(0), reason: 'a step vanished');
      }
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], greaterThan(positions[i - 1]));
      }
    });

    test('every native refusal code has a sentence of its own', () {
      final codes = RegExp(
        'reply\\.error\\(\\s*"([a-z]+)"',
      ).allMatches(kotlin).map((match) => match.group(1)!).toSet();
      expect(
        codes,
        containsAll(['signature', 'missing', 'permission', 'unavailable']),
      );
      for (final code in codes) {
        if (code == 'install') continue;
        expect(
          dart,
          contains("'$code' =>"),
          reason: '$code is answered natively but maps to nothing',
        );
      }
    });

    test('the release build compiles the pin it is signed with', () {
      expect(gradle, contains('buildConfig = true'));
      expect(
        gradle,
        contains('"EXPECTED_UPDATE_CERT_SHA256", expectedCertSha256Literal'),
      );
      expect(
        gradle,
        contains('requestsReleasePackage && expectedCertSha256.isEmpty()'),
        reason: 'a release without an anchor must not be packaged',
      );
      expect(
        gradle,
        contains('Regex("^[0-9a-f]{64}\$").matches(expectedCertSha256)'),
      );
    });

    test('the job that builds the APK can see the same pin', () {
      final build = releaseWorkflow.substring(
        releaseWorkflow.indexOf('\n  build:\n'),
        releaseWorkflow.indexOf('\n  windows:\n'),
      );
      expect(build, contains('EXPECTED_CERT_SHA256:'));
      expect(build, contains('flutter build apk --release'));
      expect(
        build.indexOf('EXPECTED_CERT_SHA256:'),
        lessThan(build.indexOf('flutter build apk --release')),
        reason: 'the pin must be job scope, not only the verify step',
      );
    });
  });
}

String _read(String relativePath) => File(relativePath).readAsStringSync();
