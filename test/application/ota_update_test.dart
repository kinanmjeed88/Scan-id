import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/ota_update.dart';

class _NoUpdateSource implements UpdateSource {
  UpdatePlatform? checkedPlatform;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    required UpdatePlatform platform,
  }) async {
    checkedPlatform = platform;
    return null;
  }
}

class _FakeTransport implements UpdateTransport {
  _FakeTransport(this.response);

  final UpdateResponse response;
  Uri? requestedUri;
  int requestCount = 0;
  bool closed = false;

  @override
  Future<UpdateResponse> get(Uri uri) async {
    requestCount++;
    requestedUri = uri;
    return response;
  }

  @override
  void close() => closed = true;
}

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

UpdateInfo _update({
  String url = 'https://github.com/example/scan-id/releases/download/v2.0.0/app.apk',
  List<int> bytes = const [1, 2, 3, 4],
  String? digest,
  int? size,
  bool includeDigest = true,
}) => UpdateInfo(
  currentVersion: '1.0.0',
  newVersion: '2.0.0',
  downloadUrl: url,
  size: size ?? bytes.length,
  sha256: includeDigest ? digest ?? _digest(bytes) : null,
);

void main() {
  group('Semantic Versioning', () {
    test('compares core versions and ignores build metadata', () {
      expect(UpdateInfo.compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(UpdateInfo.compareVersions('1.2.3', '1.2.2'), greaterThan(0));
      expect(
        UpdateInfo.compareVersions('1.0.0+build.7', '1.0.0+other'),
        0,
      );
    });

    test('prereleases sort below stable releases and by identifiers', () {
      expect(UpdateInfo.compareVersions('1.0.0-alpha', '1.0.0'), lessThan(0));
      expect(
        UpdateInfo.compareVersions('1.0.0-alpha.2', '1.0.0-alpha.10'),
        lessThan(0),
      );
      expect(
        UpdateInfo.compareVersions('1.0.0-beta', '1.0.0-alpha.9'),
        greaterThan(0),
      );
      expect(
        UpdateInfo.compareVersions('1.0.0-1', '1.0.0-alpha'),
        lessThan(0),
      );
    });

    test('rejects non-SemVer, leading zero core, and numeric prerelease zeros', () {
      for (final version in ['1.0', '01.0.0', '1.0.0-alpha.01', '1.0.0junk']) {
        expect(
          () => UpdateInfo.compareVersions(version, '1.0.0'),
          throwsFormatException,
          reason: version,
        );
      }
    });

    test('isNewer follows SemVer prerelease precedence', () {
      final prerelease = UpdateInfo(
        currentVersion: '1.0.0',
        newVersion: '1.0.1-rc.1',
        downloadUrl: 'https://example.com/app.apk',
      );
      final stable = UpdateInfo(
        currentVersion: '1.0.0-rc.1',
        newVersion: '1.0.0',
        downloadUrl: 'https://example.com/app.apk',
      );
      expect(prerelease.isNewer, isTrue);
      expect(stable.isNewer, isTrue);
    });
  });

  group('GitHubUpdateSource', () {
    const releaseJson = '''
    {
      "tag_name": "v2.1.0",
      "body": "Release notes",
      "assets": [
        {
          "browser_download_url": "https://github.com/example/app/releases/download/v2.1.0/app.apk",
          "name": "app.apk",
          "size": 1024,
          "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        },
        {
          "browser_download_url": "https://github.com/example/app/releases/download/v2.1.0/app.msi",
          "name": "app.msi",
          "size": 2048
        },
        {
          "browser_download_url": "https://github.com/example/app/releases/download/v2.1.0/app.exe",
          "name": "app.exe",
          "size": 4096
        }
      ]
    }
    ''';

    test('extracts only complete SemVer release tags', () {
      expect(GitHubUpdateSource.extractVersion('v1.2.3'), '1.2.3');
      expect(GitHubUpdateSource.extractVersion('release-1.2.3-rc.1'), '1.2.3-rc.1');
      expect(GitHubUpdateSource.extractVersion('1.2'), isNull);
      expect(GitHubUpdateSource.extractVersion('1.2.3junk'), isNull);
    });

    test('selects an Android APK and never an EXE', () {
      final update = GitHubUpdateSource.updateFromReleaseJson(
        releaseJson,
        currentVersion: '2.0.0',
        platform: UpdatePlatform.android,
      );
      expect(update, isNotNull);
      expect(update!.downloadUrl, endsWith('/app.apk'));
      expect(update.sha256, 'a' * 64);
      expect(update.size, 1024);
    });

    test('selects Windows EXE before MSI and never an APK', () {
      final update = GitHubUpdateSource.updateFromReleaseJson(
        releaseJson,
        currentVersion: '2.0.0',
        platform: UpdatePlatform.windows,
      );
      expect(update, isNotNull);
      expect(update!.downloadUrl, endsWith('/app.exe'));
    });

    test('does not offer a release with no asset for the requested platform', () {
      const json = '''
      {"tag_name":"v2.0.0","assets":[
        {"name":"app.exe","browser_download_url":"https://github.com/x/app.exe"}
      ]}
      ''';
      expect(
        GitHubUpdateSource.updateFromReleaseJson(
          json,
          currentVersion: '1.0.0',
          platform: UpdatePlatform.android,
        ),
        isNull,
      );
    });

    test('ignores releases that are not newer or have malformed JSON', () {
      expect(
        GitHubUpdateSource.updateFromReleaseJson(
          releaseJson,
          currentVersion: '2.1.0',
          platform: UpdatePlatform.android,
        ),
        isNull,
      );
      expect(GitHubUpdateSource.parseReleaseJson('not json'), isNull);
      expect(GitHubUpdateSource.parseReleaseJson('{"body":"no tag"}'), isNull);
    });

    test('rejects dot path segments in the configured repository', () {
      expect(
        () => GitHubUpdateSource(owner: '..', repo: 'Scan-id'),
        throwsArgumentError,
      );
      expect(
        () => GitHubUpdateSource(owner: 'kinan', repo: '.'),
        throwsArgumentError,
      );
    });

    test('service passes its selected platform to the source', () async {
      final source = _NoUpdateSource();
      final service = UpdateService(
        source: source,
        currentVersion: '1.0.0',
        platform: UpdatePlatform.windows,
      );
      expect(await service.checkForUpdate(), isNull);
      expect(source.checkedPlatform, UpdatePlatform.windows);
    });
  });

  group('streamed downloads and verification', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('scan_id_ota_test_');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('streams bytes to a unique file, verifies the digest, and closes transport', () async {
      const bytes = [1, 2, 3, 4];
      final transport = _FakeTransport(
        UpdateResponse(
          statusCode: HttpStatus.ok,
          contentLength: bytes.length,
          body: Stream.fromIterable([bytes.sublist(0, 2), bytes.sublist(2)]),
        ),
      );
      final service = UpdateService(
        source: _NoUpdateSource(),
        currentVersion: '1.0.0',
        transportFactory: () => transport,
        temporaryDirectory: () async => root,
      );
      final progress = <(int, int)>[];
      final result = await service.downloadUpdate(
        _update(bytes: bytes),
        onProgress: (received, total) => progress.add((received, total)),
        onCancel: () => fail('unexpected cancel'),
      );

      expect(result.isSuccess, isTrue);
      final file = File(result.filePath!);
      expect(await file.readAsBytes(), bytes);
      expect(await service.verifyUpdateSource(_update(bytes: bytes), file.path), isTrue);
      expect(progress, [(2, 4), (4, 4)]);
      expect(transport.requestedUri?.scheme, 'https');
      expect(transport.closed, isTrue);
      final install = await service.installUpdate(_update(bytes: bytes), file.path);
      expect(install.isSuccess, isFalse);
      expect(install.isPending, isFalse);
      expect(install.error, contains('لم يبدأ مثبت النظام'));
      expect(await file.exists(), isTrue, reason: 'unavailable installation keeps the verified download');
    });

    test('rejects a bad digest and removes the partial file', () async {
      const bytes = [1, 2, 3, 4];
      final transport = _FakeTransport(
        UpdateResponse(
          statusCode: HttpStatus.ok,
          contentLength: bytes.length,
          body: Stream.value(bytes),
        ),
      );
      final service = UpdateService(
        source: _NoUpdateSource(),
        currentVersion: '1.0.0',
        transportFactory: () => transport,
        temporaryDirectory: () async => root,
      );
      final result = await service.downloadUpdate(
        _update(bytes: bytes, digest: '0' * 64),
        onProgress: (_, _) {},
        onCancel: () {},
      );
      expect(result.isSuccess, isFalse);
      expect(result.error, contains('SHA-256'));
      expect(await root.list().toList(), isEmpty);
    });

    test('cancellation stops at a chunk boundary, notifies once, and cleans up', () async {
      final token = CancellationToken();
      final bytes = [1, 2, 3, 4];
      final transport = _FakeTransport(
        UpdateResponse(
          statusCode: HttpStatus.ok,
          contentLength: bytes.length,
          body: Stream.fromIterable([bytes.sublist(0, 2), bytes.sublist(2)]),
        ),
      );
      final service = UpdateService(
        source: _NoUpdateSource(),
        currentVersion: '1.0.0',
        transportFactory: () => transport,
        temporaryDirectory: () async => root,
      );
      var cancelCalls = 0;
      final result = await service.downloadUpdate(
        _update(bytes: bytes),
        onProgress: (received, _) {
          if (received == 2) token.cancel();
        },
        onCancel: () => cancelCalls++,
        cancellation: token,
      );
      expect(result.isSuccess, isFalse);
      expect(result.error, contains('أُلغي'));
      expect(cancelCalls, 1);
      expect(await root.list().toList(), isEmpty);
      expect(transport.closed, isTrue);
    });

    test('enforces size limits and refuses downloads without a digest', () async {
      const bytes = [1, 2, 3, 4];
      final tooLargeTransport = _FakeTransport(
        UpdateResponse(
          statusCode: HttpStatus.ok,
          contentLength: bytes.length,
          body: Stream.value(bytes),
        ),
      );
      final limited = UpdateService(
        source: _NoUpdateSource(),
        currentVersion: '1.0.0',
        maxDownloadBytes: 3,
        transportFactory: () => tooLargeTransport,
        temporaryDirectory: () async => root,
      );
      final sizeResult = await limited.downloadUpdate(
        _update(bytes: bytes),
        onProgress: (_, _) {},
        onCancel: () {},
      );
      expect(sizeResult.isSuccess, isFalse);
      expect(sizeResult.error, contains('حجم'));
      expect(await root.list().toList(), isEmpty);

      final noDigestTransport = _FakeTransport(
        UpdateResponse(
          statusCode: HttpStatus.ok,
          contentLength: bytes.length,
          body: Stream.value(bytes),
        ),
      );
      final noDigestService = UpdateService(
        source: _NoUpdateSource(),
        currentVersion: '1.0.0',
        transportFactory: () => noDigestTransport,
        temporaryDirectory: () async => root,
      );
      final noDigest = await noDigestService.downloadUpdate(
        _update(bytes: bytes, includeDigest: false),
        onProgress: (_, _) {},
        onCancel: () {},
      );
      expect(noDigest.isSuccess, isFalse);
      expect(noDigestTransport.requestedUri, isNull);
      expect(await root.list().toList(), isEmpty);
    });

    test('rejects a non-HTTPS URL and non-200 responses', () async {
      final responseTransport = _FakeTransport(
        UpdateResponse(
          statusCode: HttpStatus.notFound,
          contentLength: 0,
          body: const Stream<List<int>>.empty(),
        ),
      );
      final service = UpdateService(
        source: _NoUpdateSource(),
        currentVersion: '1.0.0',
        transportFactory: () => responseTransport,
        temporaryDirectory: () async => root,
      );
      final insecure = await service.downloadUpdate(
        _update(url: 'http://github.com/app.apk'),
        onProgress: (_, _) {},
        onCancel: () {},
      );
      expect(insecure.isSuccess, isFalse);
      expect(responseTransport.requestedUri, isNull);

      final httpFailure = await service.downloadUpdate(
        _update(),
        onProgress: (_, _) {},
        onCancel: () {},
      );
      expect(httpFailure.isSuccess, isFalse);
      expect(httpFailure.error, contains('404'));
      expect(await root.list().toList(), isEmpty);
    });
  });

  test('an empty stream and malformed release version are never accepted', () async {
    final transport = _FakeTransport(
      const UpdateResponse(
        statusCode: HttpStatus.ok,
        contentLength: -1,
        body: Stream<List<int>>.empty(),
      ),
    );
    final root = await Directory.systemTemp.createTemp('scan_id_ota_empty_');
    try {
      final service = UpdateService(
        source: _NoUpdateSource(),
        currentVersion: '1.0.0',
        transportFactory: () => transport,
        temporaryDirectory: () async => root,
      );
      final empty = UpdateInfo(
        currentVersion: '1.0.0',
        newVersion: '2.0.0',
        downloadUrl: 'https://github.com/example/scan-id/releases/app.apk',
        sha256: _digest(const []),
      );
      final result = await service.downloadUpdate(
        empty,
        onProgress: (_, _) {},
        onCancel: () {},
      );
      expect(result.isSuccess, isFalse);
      expect(result.error, contains('فارغ'));
      expect(await root.list().toList(), isEmpty);
      expect(transport.closed, isTrue);

      final badVersion = UpdateInfo(
        currentVersion: '1.0.0',
        newVersion: '2.0',
        downloadUrl: empty.downloadUrl,
        sha256: _digest(const [1]),
      );
      final invalid = await service.downloadUpdate(
        badVersion,
        onProgress: (_, _) {},
        onCancel: () {},
      );
      expect(invalid.isSuccess, isFalse);
      expect(invalid.error, contains('SemVer'));
      expect(transport.requestCount, 1);
    } finally {
      await root.delete(recursive: true);
    }
  });

  group('operation results', () {
    test('download success/error are explicit', () {
      expect(DownloadResult.success('/tmp/update.apk').isSuccess, isTrue);
      expect(DownloadResult.error('failed').isSuccess, isFalse);
    });

    test('install success, pending, and error are distinguishable', () {
      expect(InstallResult.success('installed').isSuccess, isTrue);
      expect(InstallResult.pending('awaiting').isPending, isTrue);
      expect(InstallResult.error('failed').isSuccess, isFalse);
    });
  });
}
