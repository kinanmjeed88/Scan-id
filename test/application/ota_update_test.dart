import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/ota_update.dart';

void main() {
  group('UpdateInfo', () {
    test('compares versions correctly', () {
      expect(UpdateInfo.compareVersions('1.0.0', '0.9.9'), greaterThan(0));
      expect(UpdateInfo.compareVersions('1.0.0', '1.0.0'), equals(0));
      expect(UpdateInfo.compareVersions('0.9.9', '1.0.0'), lessThan(0));
      expect(UpdateInfo.compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(UpdateInfo.compareVersions('1.2.3', '1.2.2'), greaterThan(0));
    });

    test('isNewer returns true for newer versions', () {
      final update = UpdateInfo(
        currentVersion: '1.0.0',
        newVersion: '2.0.0',
        downloadUrl: 'https://example.com/update.apk',
      );
      expect(update.isNewer, isTrue);
    });

    test('isNewer returns false for same version', () {
      final update = UpdateInfo(
        currentVersion: '1.0.0',
        newVersion: '1.0.0',
        downloadUrl: 'https://example.com/update.apk',
      );
      expect(update.isNewer, isFalse);
    });

    test('isNewer returns false for older version', () {
      final update = UpdateInfo(
        currentVersion: '2.0.0',
        newVersion: '1.0.0',
        downloadUrl: 'https://example.com/update.apk',
      );
      expect(update.isNewer, isFalse);
    });
  });

  group('GitHubUpdateSource', () {
    test('extracts version from tag with v prefix', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      expect(source.extractVersion('v1.2.3'), equals('1.2.3'));
    });

    test('extracts version from tag without prefix', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      expect(source.extractVersion('1.2.3'), equals('1.2.3'));
    });

    test('extracts version from release- prefix', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      expect(source.extractVersion('release-1.2.3'), equals('1.2.3'));
    });

    test('returns null for invalid version', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      expect(source.extractVersion('invalid'), isNull);
      expect(source.extractVersion('1.2'), isNull);
    });

    test('parses release JSON correctly', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      final json = '''
      {
        "tag_name": "v1.0.0",
        "body": "Release notes",
        "assets": [
          {
            "browser_download_url": "https://example.com/app.apk",
            "name": "app.apk",
            "size": 1024
          }
        ]
      }
      ''';
      final result = source.parseReleaseJson(json);
      expect(result, isNotNull);
      expect(result!['tagName'], equals('v1.0.0'));
      expect(result!['body'], equals('Release notes'));
      expect(result!['assets'], isA<List>());
    });

    test('returns null for invalid JSON', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      expect(source.parseReleaseJson('invalid json'), isNull);
    });

    test('returns null when tag_name is missing', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      final json = '{"body": "no tag"}';
      expect(source.parseReleaseJson(json), isNull);
    });
  });

  group('UpdateService', () {
    test('creates with required parameters', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      final service = UpdateService(source: source, currentVersion: '1.0.0');
      expect(service.currentVersion, equals('1.0.0'));
    });

    test('supports both platforms', () {
      final source = GitHubUpdateSource(owner: 'test', repo: 'test');
      final androidService = UpdateService(
        source: source,
        currentVersion: '1.0.0',
        platform: UpdatePlatform.android,
      );
      expect(androidService.platform, equals(UpdatePlatform.android));

      final windowsService = UpdateService(
        source: source,
        currentVersion: '1.0.0',
        platform: UpdatePlatform.windows,
      );
      expect(windowsService.platform, equals(UpdatePlatform.windows));
    });
  });

  group('DownloadResult', () {
    test('success creates valid result', () {
      final result = DownloadResult.success('/tmp/update.apk');
      expect(result.isSuccess, isTrue);
      expect(result.filePath, equals('/tmp/update.apk'));
      expect(result.error, isNull);
    });

    test('error creates invalid result', () {
      final result = DownloadResult.error('فشل التنزيل');
      expect(result.isSuccess, isFalse);
      expect(result.filePath, isNull);
      expect(result.error, equals('فشل التنزيل'));
    });
  });

  group('InstallResult', () {
    test('success creates valid result', () {
      final result = InstallResult.success('تم التثبيت');
      expect(result.isSuccess, isTrue);
      expect(result.message, equals('تم التثبيت'));
      expect(result.error, isNull);
      expect(result.isPending, isFalse);
    });

    test('error creates invalid result', () {
      final result = InstallResult.error('فشل التثبيت');
      expect(result.isSuccess, isFalse);
      expect(result.message, isNull);
      expect(result.error, equals('فشل التثبيت'));
      expect(result.isPending, isFalse);
    });

    test('pending creates result with isPending true', () {
      final result = InstallResult.pending('جارٍ التثبيت...');
      expect(result.isSuccess, isFalse);
      expect(result.message, equals('جارٍ التثبيت...'));
      expect(result.error, isNull);
      expect(result.isPending, isTrue);
    });
  });

  group('version comparison edge cases', () {
    test('handles versions with different lengths', () {
      expect(UpdateInfo._compareVersions('1.0', '1.0.0'), equals(0));
      expect(UpdateInfo._compareVersions('1', '1.0.0'), equals(0));
    });

    test('handles pre-release versions as equal', () {
      // Pre-release identifiers are not handled, so 1.0.0-alpha == 1.0.0
      expect(UpdateInfo._compareVersions('1.0.0-alpha', '1.0.0'), equals(0));
    });
  });
}
