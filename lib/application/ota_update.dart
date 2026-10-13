import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'cancellation.dart';
import 'ids.dart';

const int maxUpdateMetadataBytes = 2 * 1024 * 1024;
const int maxUpdateDownloadBytes = 512 * 1024 * 1024;
const Set<String> _trustedUpdateHosts = {
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
};

bool _isAllowedUpdateUri(Uri uri) =>
    uri.scheme == 'https' &&
    _trustedUpdateHosts.contains(uri.host.toLowerCase()) &&
    uri.userInfo.isEmpty &&
    (!uri.hasPort || uri.port == 443) &&
    !uri.hasFragment;

/// Metadata for one platform-specific release asset.
class UpdateInfo {
  UpdateInfo({
    required this.currentVersion,
    required this.newVersion,
    required this.downloadUrl,
    this.summary,
    this.size,
    String? sha256,
  }) : sha256 = _normalizeDigest(sha256);

  final String currentVersion;
  final String newVersion;
  final String downloadUrl;
  final String? summary;
  final int? size;

  /// SHA-256 advertised by the release API, if present. Installation remains
  /// disabled until publisher signing/installer integration is configured.
  final String? sha256;

  bool get isNewer => compareVersions(newVersion, currentVersion) > 0;

  /// Compares strict SemVer 2.0.0 values. Build metadata is ignored and a
  /// prerelease sorts below its corresponding stable release.
  static int compareVersions(String a, String b) {
    final left = _SemVersion.parse(a);
    final right = _SemVersion.parse(b);
    if (left == null) throw FormatException('Invalid SemVer version: $a');
    if (right == null) throw FormatException('Invalid SemVer version: $b');
    return left.compareTo(right);
  }
}

class _SemVersion implements Comparable<_SemVersion> {
  const _SemVersion(this.major, this.minor, this.patch, this.prerelease);

  final BigInt major;
  final BigInt minor;
  final BigInt patch;
  final List<String> prerelease;

  static _SemVersion? parse(String value) {
    final match = RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
      r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(value);
    if (match == null) return null;
    final prerelease = match.group(4)?.split('.') ?? const <String>[];
    for (final identifier in prerelease) {
      if (RegExp(r'^[0-9]+$').hasMatch(identifier) &&
          identifier.length > 1 &&
          identifier.startsWith('0')) {
        return null;
      }
    }
    return _SemVersion(
      BigInt.parse(match.group(1)!),
      BigInt.parse(match.group(2)!),
      BigInt.parse(match.group(3)!),
      List.unmodifiable(prerelease),
    );
  }

  @override
  int compareTo(_SemVersion other) {
    final core = major.compareTo(other.major);
    if (core != 0) return core;
    final minorOrder = minor.compareTo(other.minor);
    if (minorOrder != 0) return minorOrder;
    final patchOrder = patch.compareTo(other.patch);
    if (patchOrder != 0) return patchOrder;

    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final left = prerelease[i];
      final right = other.prerelease[i];
      final leftNumeric = RegExp(r'^[0-9]+$').hasMatch(left);
      final rightNumeric = RegExp(r'^[0-9]+$').hasMatch(right);
      int order;
      if (leftNumeric && rightNumeric) {
        order = left.length != right.length
            ? left.length.compareTo(right.length)
            : left.compareTo(right);
      } else if (leftNumeric != rightNumeric) {
        order = leftNumeric ? -1 : 1;
      } else {
        order = left.compareTo(right);
      }
      if (order != 0) return order;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}

String? _normalizeDigest(String? value) {
  if (value == null) return null;
  final digest = value.startsWith('sha256:') ? value.substring(7) : value;
  return digest.toLowerCase();
}

bool _isSha256(String? value) =>
    value != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

/// External update metadata provider (for example, GitHub Releases).
abstract interface class UpdateSource {
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    required UpdatePlatform platform,
  });
}

/// Retrieves a GitHub release and chooses only the asset for [platform].
class GitHubUpdateSource implements UpdateSource {
  GitHubUpdateSource({
    required this.owner,
    required this.repo,
    this.releaseTagPrefix = '',
  }) {
    final validSegment = RegExp(r'^[A-Za-z0-9_.-]+$');
    if (!validSegment.hasMatch(owner) ||
        !validSegment.hasMatch(repo) ||
        owner == '.' ||
        owner == '..' ||
        repo == '.' ||
        repo == '..') {
      throw ArgumentError('GitHub owner and repository must be path segments.');
    }
  }

  final String owner;
  final String repo;
  final String releaseTagPrefix;

  static const _baseUrl = 'https://api.github.com/repos';

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    required UpdatePlatform platform,
  }) async {
    final uri = Uri.parse('$_baseUrl/$owner/$repo/releases/latest');
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers
        ..set('Accept', 'application/vnd.github+json')
        ..set('User-Agent', 'Scan-id-update-check')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub release metadata returned HTTP ${response.statusCode}.',
          uri: uri,
        );
      }
      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        if (received > maxUpdateMetadataBytes) {
          throw const FormatException(
            'Release metadata exceeds its size limit.',
          );
        }
        builder.add(chunk);
      }
      final release = parseReleaseJson(utf8.decode(builder.takeBytes()));
      if (release == null) return null;
      return selectUpdate(
        release,
        currentVersion: currentVersion,
        platform: platform,
        releaseTagPrefix: releaseTagPrefix,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Pure selection path used by the network adapter and by tests. The
  /// returned URL always belongs to the requested platform.
  static UpdateInfo? updateFromReleaseJson(
    String json, {
    required String currentVersion,
    required UpdatePlatform platform,
    String releaseTagPrefix = '',
  }) {
    final release = parseReleaseJson(json);
    if (release == null) return null;
    return selectUpdate(
      release,
      currentVersion: currentVersion,
      platform: platform,
      releaseTagPrefix: releaseTagPrefix,
    );
  }

  static UpdateInfo? selectUpdate(
    Map<String, dynamic> release, {
    required String currentVersion,
    required UpdatePlatform platform,
    String releaseTagPrefix = '',
  }) {
    final tag = release['tagName'];
    if (tag is! String) return null;
    final version = extractVersion(
      tag.startsWith(releaseTagPrefix)
          ? tag.substring(releaseTagPrefix.length)
          : tag,
    );
    if (version == null ||
        UpdateInfo.compareVersions(version, currentVersion) <= 0) {
      return null;
    }

    final rawAssets = release['assets'];
    if (rawAssets is! List<_AssetInfo>) return null;
    final candidates =
        rawAssets.where((asset) {
          final url = Uri.tryParse(asset.url ?? '');
          final extension = p.extension(url?.path ?? '').toLowerCase();
          return url != null &&
              _isAllowedUpdateUri(url) &&
              _extensionsFor(platform).contains(extension);
        }).toList()..sort((a, b) {
          final aExtension = p
              .extension(Uri.tryParse(a.url ?? '')?.path ?? '')
              .toLowerCase();
          final bExtension = p
              .extension(Uri.tryParse(b.url ?? '')?.path ?? '')
              .toLowerCase();
          final order = _extensionPriority(
            platform,
            aExtension,
          ).compareTo(_extensionPriority(platform, bExtension));
          return order != 0 ? order : (a.name ?? '').compareTo(b.name ?? '');
        });
    final asset = candidates.firstOrNull;
    final downloadUrl = asset?.url;
    if (downloadUrl == null) return null;
    return UpdateInfo(
      currentVersion: currentVersion,
      newVersion: version,
      downloadUrl: downloadUrl,
      summary: release['body'] as String?,
      size: asset!.size,
      sha256: asset.sha256,
    );
  }

  static Map<String, dynamic>? parseReleaseJson(String json) {
    try {
      final data = jsonDecode(json);
      if (data is! Map<String, dynamic> || data['tag_name'] is! String) {
        return null;
      }
      final rawAssets = data['assets'];
      final assets = rawAssets is List
          ? rawAssets.map(_parseAsset).whereType<_AssetInfo>().toList()
          : <_AssetInfo>[];
      return {
        'tagName': data['tag_name'],
        'body': data['body'] is String ? data['body'] as String : null,
        'assets': assets,
      };
    } on Object {
      return null;
    }
  }

  static _AssetInfo? _parseAsset(Object? asset) {
    if (asset is! Map<String, dynamic>) return null;
    final url = asset['browser_download_url'];
    final name = asset['name'];
    final digest = asset['digest'] ?? asset['sha256'];
    final size = asset['size'];
    return _AssetInfo(
      url: url is String ? url : null,
      name: name is String ? name : null,
      size: size is int && size > 0 ? size : null,
      sha256: digest is String ? digest : null,
    );
  }

  static String? extractVersion(String tag) {
    var version = tag;
    if (version.startsWith('v')) version = version.substring(1);
    if (version.startsWith('release-')) {
      version = version.substring('release-'.length);
    }
    return _SemVersion.parse(version) == null ? null : version;
  }
}

class _AssetInfo {
  const _AssetInfo({this.url, this.name, this.size, this.sha256});

  final String? url;
  final String? name;
  final int? size;
  final String? sha256;
}

/// A response body is a single-use byte stream, so downloads need not be held
/// in memory before writing and verifying them.
class UpdateResponse {
  const UpdateResponse({
    required this.statusCode,
    required this.contentLength,
    required this.body,
  });

  final int statusCode;
  final int contentLength;
  final Stream<List<int>> body;
}

abstract interface class UpdateTransport {
  Future<UpdateResponse> get(Uri uri);
  void close();
}

class _IoUpdateTransport implements UpdateTransport {
  final HttpClient _client = HttpClient();

  @override
  Future<UpdateResponse> get(Uri uri) async {
    var current = uri;
    for (var redirects = 0; ; redirects++) {
      if (!_isAllowedUpdateUri(current)) {
        throw HttpException('Update URL is not trusted.', uri: current);
      }
      final request = await _client.getUrl(current);
      request.followRedirects = false;
      final response = await request.close();
      if (!response.isRedirect) {
        return UpdateResponse(
          statusCode: response.statusCode,
          contentLength: response.contentLength,
          body: response,
        );
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (redirects >= 5 || location == null) {
        throw HttpException('Update redirect limit exceeded.', uri: current);
      }
      final next = current.resolve(location);
      if (!_isAllowedUpdateUri(next)) {
        throw HttpException('Update redirect target is not trusted.', uri: next);
      }
      current = next;
    }
  }

  @override
  void close() => _client.close(force: true);
}

/// Platform update operations. Downloads are streamed to a unique bounded
/// temporary file and accepted only when a SHA-256 digest is supplied and
/// verified. Installation deliberately fails closed until signed production
/// packages and native installer integrations are configured.
class UpdateService {
  UpdateService({
    required this.source,
    required this.currentVersion,
    this.platform = UpdatePlatform.android,
    UpdateTransport Function()? transportFactory,
    Future<Directory> Function()? temporaryDirectory,
    this.maxDownloadBytes = maxUpdateDownloadBytes,
  }) : _transportFactory = transportFactory ?? _IoUpdateTransport.new,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory {
    if (_SemVersion.parse(currentVersion) == null) {
      throw FormatException('Invalid current SemVer version: $currentVersion');
    }
    if (maxDownloadBytes <= 0) {
      throw ArgumentError.value(maxDownloadBytes, 'maxDownloadBytes');
    }
  }

  final UpdateSource source;
  final String currentVersion;
  final UpdatePlatform platform;
  final int maxDownloadBytes;
  final UpdateTransport Function() _transportFactory;
  final Future<Directory> Function() _temporaryDirectory;

  Future<UpdateInfo?> checkForUpdate() =>
      source.checkForUpdate(currentVersion, platform: platform);

  Future<DownloadResult> downloadUpdate(
    UpdateInfo update, {
    required void Function(int received, int total) onProgress,
    required void Function() onCancel,
    CancellationToken? cancellation,
  }) async {
    File? tempFile;
    UpdateTransport? transport;
    var cancelNotified = false;
    void notifyCancel() {
      if (cancelNotified) return;
      cancelNotified = true;
      try {
        onCancel();
      } on Object {
        // Cancellation notification is best-effort; cleanup still proceeds.
      }
    }

    Future<DownloadResult> fail(String message) async {
      final cleaned = await _cleanupTempFile(tempFile);
      return DownloadResult.error(
        cleaned ? message : '$message تعذر حذف الملف المؤقت بأمان.',
      );
    }

    if (cancellation?.isCancelled ?? false) {
      notifyCancel();
      return DownloadResult.error('أُلغي تنزيل التحديث.');
    }
    if (!_matchesPlatform(update) || update.currentVersion != currentVersion) {
      return DownloadResult.error('بيانات التحديث لا تطابق الإصدار أو المنصة.');
    }
    if (_SemVersion.parse(update.newVersion) == null) {
      return DownloadResult.error('إصدار التحديث ليس SemVer صالحاً.');
    }
    if (!update.isNewer) {
      return DownloadResult.error(
        'الإصدار المعروض ليس أحدث من الإصدار الحالي.',
      );
    }
    if (!_isSha256(update.sha256)) {
      return DownloadResult.error('لا توجد بصمة SHA-256 صالحة؛ رُفض التنزيل.');
    }
    if (update.size != null &&
        (update.size! <= 0 || update.size! > maxDownloadBytes)) {
      return DownloadResult.error('حجم التحديث يتجاوز الحدود المسموحة.');
    }

    final uri = Uri.parse(update.downloadUrl);
    try {
      transport = _transportFactory();
      final response = await transport.get(uri);
      if (response.statusCode != HttpStatus.ok) {
        return DownloadResult.error(
          'فشل تنزيل التحديث: HTTP ${response.statusCode}.',
        );
      }
      if (response.contentLength == 0 ||
          response.contentLength > maxDownloadBytes ||
          (update.size != null &&
              response.contentLength >= 0 &&
              response.contentLength != update.size)) {
        return DownloadResult.error(
          'حجم ملف التحديث لا يطابق الحدود أو بيانات الإصدار.',
        );
      }
      final total =
          update.size ??
          (response.contentLength >= 0 ? response.contentLength : 0);
      final directory = await _temporaryDirectory();
      await directory.create(recursive: true);
      final extension = p.extension(uri.path).toLowerCase();
      tempFile = File(
        p.join(directory.path, 'scan-id-update-${newId()}$extension'),
      );
      final output = tempFile.openWrite(mode: FileMode.writeOnly);
      final hashSink = _SingleDigestSink();
      final hashInput = sha256.startChunkedConversion(hashSink);
      var received = 0;
      var cancelled = false;
      try {
        await for (final chunk in response.body) {
          if (cancellation?.isCancelled ?? false) {
            cancelled = true;
            break;
          }
          if (chunk.isEmpty) continue;
          received += chunk.length;
          if (received > maxDownloadBytes ||
              (update.size != null && received > update.size!)) {
            throw const _UpdateFailure('تجاوز التنزيل حد الحجم المعلن.');
          }
          output.add(chunk);
          hashInput.add(chunk);
          await output.flush();
          onProgress(received, total);
        }
      } finally {
        hashInput.close();
        try {
          await output.flush();
        } finally {
          await output.close();
        }
      }
      if (cancelled || (cancellation?.isCancelled ?? false)) {
        notifyCancel();
        return fail('أُلغي تنزيل التحديث.');
      }
      if (received == 0) {
        return fail('ملف التحديث فارغ.');
      }
      if (update.size != null && received != update.size) {
        return fail('حجم ملف التحديث غير مكتمل.');
      }
      final digest = hashSink.digest;
      if (digest == null || digest.toString() != update.sha256) {
        return fail('فشل التحقق من بصمة SHA-256 للتحديث.');
      }
      return DownloadResult.success(tempFile.path);
    } on _UpdateFailure catch (error) {
      return fail(error.message);
    } on Object catch (error) {
      return fail('فشل تنزيل التحديث: $error');
    } finally {
      transport?.close();
    }
  }

  bool _matchesPlatform(UpdateInfo update) {
    final uri = Uri.tryParse(update.downloadUrl);
    if (uri == null || !_isAllowedUpdateUri(uri)) {
      return false;
    }
    return _extensionsFor(
      platform,
    ).contains(p.extension(uri.path).toLowerCase());
  }

  /// Confirms the downloaded file's extension, declared size and digest. This
  /// is corruption detection only; it is not an independent publisher
  /// signature and is not sufficient authorization to install the package.
  Future<bool> verifyUpdateSource(UpdateInfo update, String filePath) async {
    if (!_matchesPlatform(update) || !_isSha256(update.sha256)) {
      return false;
    }
    try {
      final uri = Uri.parse(update.downloadUrl);
      final expectedExtension = p.extension(uri.path).toLowerCase();
      if (p.extension(filePath).toLowerCase() != expectedExtension) {
        return false;
      }
      final file = File(filePath);
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      if (length == 0 || length > maxDownloadBytes) {
        return false;
      }
      if (update.size != null && length != update.size) {
        return false;
      }
      final actualDigest = await sha256.bind(file.openRead()).first;
      return actualDigest.toString() == update.sha256;
    } on Object {
      return false;
    }
  }

  /// The current release configuration has no production publisher identity or
  /// native installer implementation. Verification alone never launches or
  /// installs an executable; this method reports the operation as unavailable.
  Future<InstallResult> installUpdate(
    UpdateInfo update,
    String filePath,
  ) async {
    if (!await verifyUpdateSource(update, filePath)) {
      return InstallResult.error(
        'تعذر التحقق من ملف التحديث؛ لم يُشغَّل أي مثبت.',
      );
    }
    return InstallResult.error(switch (platform) {
      UpdatePlatform.android =>
        'تثبيت Android الهوائي غير مهيأ لهذا البناء؛ لم يبدأ مثبت النظام.',
      UpdatePlatform.windows =>
        'تثبيت Windows الهوائي غير مهيأ دون حزمة ومُثبّت موثوقين؛ لم يُشغَّل أي ملف.',
    });
  }

  Future<bool> _cleanupTempFile(File? file) async {
    if (file == null) {
      return true;
    }
    try {
      if (await file.exists()) {
        await file.delete();
      }
      return !await file.exists();
    } on Object {
      return false;
    }
  }
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest value) => digest = value;

  @override
  void close() {}
}

class _UpdateFailure implements Exception {
  const _UpdateFailure(this.message);
  final String message;
}

int _extensionPriority(UpdatePlatform platform, String extension) =>
    switch (platform) {
      UpdatePlatform.android => 0,
      UpdatePlatform.windows => extension == '.exe' ? 0 : 1,
    };

List<String> _extensionsFor(UpdatePlatform platform) => switch (platform) {
  UpdatePlatform.android => const ['.apk'],
  UpdatePlatform.windows => const ['.exe', '.msi'],
};

enum UpdatePlatform { android, windows }

class DownloadResult {
  DownloadResult._({this.filePath, this.error});

  final String? filePath;
  final String? error;
  bool get isSuccess => error == null && filePath != null;

  factory DownloadResult.success(String path) =>
      DownloadResult._(filePath: path);

  factory DownloadResult.error(String message) =>
      DownloadResult._(error: message);
}

class InstallResult {
  InstallResult._({this.message, this.error, this.isPending = false});

  final String? message;
  final String? error;
  final bool isPending;
  bool get isSuccess => error == null && !isPending;

  factory InstallResult.success(String message) =>
      InstallResult._(message: message);

  factory InstallResult.error(String error) => InstallResult._(error: error);

  factory InstallResult.pending(String message) =>
      InstallResult._(message: message, isPending: true);
}
