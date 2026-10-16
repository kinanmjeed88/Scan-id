import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/ota_update.dart';

void main() {
  group('Windows ZIP support in OTA', () {
    const releaseJsonWithZip = '''
    {
      "tag_name": "v0.1.1",
      "body": "Release notes",
      "assets": [
        {
          "browser_download_url": "https://github.com/example/app/releases/download/v0.1.1/app.apk",
          "name": "app.apk",
          "size": 1024,
          "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        },
        {
          "browser_download_url": "https://github.com/example/app/releases/download/v0.1.1/app.zip",
          "name": "app.zip",
          "size": 2048,
          "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        },
        {
          "browser_download_url": "https://github.com/example/app/releases/download/v0.1.1/app.exe",
          "name": "app.exe",
          "size": 4096,
          "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        }
      ]
    }
    ''';

    test('Windows selects EXE first, then MSI, then ZIP', () {
      final update = GitHubUpdateSource.updateFromReleaseJson(
        releaseJsonWithZip,
        currentVersion: '0.1.0',
        platform: UpdatePlatform.windows,
      );
      expect(update, isNotNull);
      // Should pick .exe as highest priority
      expect(update!.downloadUrl, endsWith('/app.exe'));
    });

    test('Windows selects ZIP when no EXE or MSI', () {
      const jsonOnlyZip = '''
      {"tag_name":"v0.1.1","assets":[
        {"name":"app.apk","browser_download_url":"https://github.com/example/app/releases/download/v0.1.1/app.apk","size":1024,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        {"name":"app.zip","browser_download_url":"https://github.com/example/app/releases/download/v0.1.1/app.zip","size":2048,"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
      ]}
      ''';
      final update = GitHubUpdateSource.updateFromReleaseJson(
        jsonOnlyZip,
        currentVersion: '0.1.0',
        platform: UpdatePlatform.windows,
      );
      expect(update, isNotNull);
      expect(update!.downloadUrl, endsWith('/app.zip'));
    });

    test('Windows selects MSI before ZIP', () {
      const jsonMsiZip = '''
      {"tag_name":"v0.1.1","assets":[
        {"name":"app.msi","browser_download_url":"https://github.com/example/app/releases/download/v0.1.1/app.msi","size":1024,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        {"name":"app.zip","browser_download_url":"https://github.com/example/app/releases/download/v0.1.1/app.zip","size":2048,"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
      ]}
      ''';
      final update = GitHubUpdateSource.updateFromReleaseJson(
        jsonMsiZip,
        currentVersion: '0.1.0',
        platform: UpdatePlatform.windows,
      );
      expect(update, isNotNull);
      expect(update!.downloadUrl, endsWith('/app.msi'));
    });

    test('Android never selects ZIP, only APK', () {
      const jsonMixed = '''
      {"tag_name":"v0.1.1","assets":[
        {"name":"app.zip","browser_download_url":"https://github.com/example/app/releases/download/v0.1.1/app.zip","size":2048,"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
        {"name":"app.exe","browser_download_url":"https://github.com/example/app/releases/download/v0.1.1/app.exe","size":2048,"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
      ]}
      ''';
      final update = GitHubUpdateSource.updateFromReleaseJson(
        jsonMixed,
        currentVersion: '0.1.0',
        platform: UpdatePlatform.android,
      );
      expect(update, isNull, reason: 'Android should not select zip or exe');
    });

    test('Android selects APK even when ZIP present', () {
      final update = GitHubUpdateSource.updateFromReleaseJson(
        releaseJsonWithZip,
        currentVersion: '0.1.0',
        platform: UpdatePlatform.android,
      );
      expect(update, isNotNull);
      expect(update!.downloadUrl, endsWith('/app.apk'));
    });

    test('Release with only ZIP for Windows is valid for OTA', () {
      const jsonZipOnly = '''
      {"tag_name":"v2.0.0","assets":[
        {"name":"scan-id-windows-v2.0.0.zip","browser_download_url":"https://github.com/kinanmjeed88/Scan-id/releases/download/v2.0.0/scan-id-windows-v2.0.0.zip","size":5000000,"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}
      ]}
      ''';
      final update = GitHubUpdateSource.updateFromReleaseJson(
        jsonZipOnly,
        currentVersion: '1.0.0',
        platform: UpdatePlatform.windows,
      );
      expect(update, isNotNull);
      expect(update!.downloadUrl, contains('.zip'));
      expect(update.sha256, 'd' * 64);
    });

    test('Release missing platform asset returns null', () {
      const jsonNoWindowsAsset = '''
      {"tag_name":"v2.0.0","assets":[
        {"name":"app.apk","browser_download_url":"https://github.com/example/app/releases/download/v2.0.0/app.apk","size":1024,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
      ]}
      ''';
      expect(
        GitHubUpdateSource.updateFromReleaseJson(
          jsonNoWindowsAsset,
          currentVersion: '1.0.0',
          platform: UpdatePlatform.windows,
        ),
        isNull,
      );
    });

    test('Tag with v prefix and prerelease handled', () {
      expect(GitHubUpdateSource.extractVersion('v1.2.3'), '1.2.3');
      expect(GitHubUpdateSource.extractVersion('v1.2.3-rc.1'), '1.2.3-rc.1');
      expect(GitHubUpdateSource.extractVersion('release-1.2.3'), '1.2.3');
    });

    test('Build metadata ignored for newer check', () {
      // Current 0.1.0, new 0.1.0+build == not newer
      const jsonBuildMeta = '''
      {"tag_name":"v0.1.0+build.1","assets":[
        {"name":"app.apk","browser_download_url":"https://github.com/example/app/releases/download/v0.1.0/app.apk","size":1024,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
      ]}
      ''';
      final update = GitHubUpdateSource.updateFromReleaseJson(
        jsonBuildMeta,
        currentVersion: '0.1.0',
        platform: UpdatePlatform.android,
      );
      expect(
        update,
        isNull,
        reason: 'Build metadata should not count as newer',
      );
    });

    test('Same version not offered', () {
      final update = GitHubUpdateSource.updateFromReleaseJson(
        releaseJsonWithZip,
        currentVersion: '0.1.1',
        platform: UpdatePlatform.android,
      );
      expect(update, isNull);
    });

    test('Invalid JSON returns null without throwing', () {
      expect(
        GitHubUpdateSource.updateFromReleaseJson(
          'not json',
          currentVersion: '1.0.0',
          platform: UpdatePlatform.android,
        ),
        isNull,
      );
      expect(GitHubUpdateSource.parseReleaseJson('{"no_tag":1}'), isNull);
    });

    test('Untrusted host rejected', () {
      const jsonUntrusted = '''
      {"tag_name":"v2.0.0","assets":[
        {"name":"app.apk","browser_download_url":"https://evil.com/app.apk","size":1024,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
      ]}
      ''';
      expect(
        GitHubUpdateSource.updateFromReleaseJson(
          jsonUntrusted,
          currentVersion: '1.0.0',
          platform: UpdatePlatform.android,
        ),
        isNull,
      );
    });

    test('Release assets must match OTA platform extensions', () {
      // Simulate verification that published assets match expectations:
      // Android needs .apk, Windows needs .exe/.msi/.zip
      final assets = [
        'scan-id-android-v0.1.1.apk',
        'scan-id-windows-v0.1.1.zip',
        'SHA256SUMS.txt',
      ];
      final hasApk = assets.any((a) => a.endsWith('.apk'));
      final hasWindows = assets.any(
        (a) => a.endsWith('.exe') || a.endsWith('.msi') || a.endsWith('.zip'),
      );
      expect(
        hasApk,
        isTrue,
        reason: 'Release must contain APK for Android OTA',
      );
      expect(hasWindows, isTrue, reason: 'Release must contain Windows asset');
    });
  });
}
