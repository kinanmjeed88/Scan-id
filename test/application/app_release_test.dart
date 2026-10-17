import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/app_release.dart';
import 'package:scan_id/application/ota_update.dart';

/// The update check is only as honest as the number it compares itself with.
/// These tests hold the three things that must agree in place: `pubspec.yaml`,
/// the one Dart line the release flow edits, and the settings surface that must
/// not turn an update into a tour of where the app came from.
void main() {
  test('the published version is the version the check compares against', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:[ \t]*([0-9]+\.[0-9]+\.[0-9]+)([+-][^\n]*)?$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec must carry version: x.y.z+n');
    expect(appVersion, match!.group(1));
    expect(UpdateInfo.compareVersions(appVersion, appVersion), 0);
  });

  test('the release flow still edits a line this app reads', () {
    final source = File('lib/application/app_release.dart').readAsStringSync();
    expect(
      source,
      contains("const String appVersion = '$appVersion';"),
      reason: 'release-management.yml rewrites exactly this shape',
    );

    const workflowPath = '.github/workflows/release-management.yml';
    final workflow = File(workflowPath).readAsStringSync();
    expect(
      workflow,
      contains('version_file: lib/application/app_release.dart'),
    );
    expect(workflow, contains("const String appVersion = '"));
    expect(
      workflow,
      isNot(contains('_appVersion')),
      reason: 'a second version constant would be free to disagree',
    );

    // Publishing must commit both files the bump rewrote. Staging only the
    // pubspec would tag a branch whose installed app still compares updates
    // against the previous release — an update that offers the same version
    // forever — and would leave the branch red on the test you are reading.
    expect(
      workflow,
      contains('git add pubspec.yaml lib/application/app_release.dart'),
      reason: 'the release commit must stage the version the app reads',
    );
    // The proof is not the staging but the commit: a `git add` of a file that
    // no longer holds that line would be a silent success.
    expect(
      workflow,
      contains('git show HEAD:lib/application/app_release.dart'),
      reason: 'the tagged commit must be checked before the tag is pushed',
    );
    for (final retired in [
      'lib/presentation/settings_screen.dart',
      'lib/presentation/app.dart',
    ]) {
      expect(
        workflow,
        isNot(contains(retired)),
        reason: '$retired holds no version to publish',
      );
    }
  });

  test('the update feed is named in code, never on screen', () {
    const settingsPath = 'lib/presentation/settings_screen.dart';
    final settings = File(settingsPath).readAsStringSync();
    for (final forbidden in [
      'github.com',
      'releases/latest',
      'api.github',
      'فتح صفحة الإصدارات',
      'open_in_new',
    ]) {
      expect(
        settings,
        isNot(contains(forbidden)),
        reason: 'settings must not show "$forbidden"',
      );
    }
    expect(releaseOwner, isNotEmpty);
    expect(releaseRepository, isNotEmpty);
    expect(
      File('lib/application/ota_update.dart').readAsStringSync(),
      contains('api.github.com'),
      reason: 'the metadata host belongs to the transport, and nowhere else',
    );
  });
}
