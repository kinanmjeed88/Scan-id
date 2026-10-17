import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'cancellation.dart';
import 'ids.dart';
import 'update_installer.dart';

const int maxUpdateMetadataBytes = 2 * 1024 * 1024;
const int maxUpdateDownloadBytes = 512 * 1024 * 1024;

/// Prefix of every package this feature writes. It names the whole update
/// directory, so leftovers from an interrupted session are recognisable.
const String updateFilePrefix = 'scan-id-update-';

/// The one directory a downloaded package is written to.
///
/// Three files must agree on this name, because that is what makes a handoff to
/// the system installer both possible and narrow: the provider's declared path
/// in `android/app/src/main/res/xml/update_paths.xml`, the accepted directory
/// in `UpdateInstaller.kt`, and the directory this service writes.
/// `tool/check_source.py` re-checks all three, so a rename in one place cannot
/// silently open a wider grant or leave the installer refusing a file it may
/// not read.
const String updateDirectoryName = 'scan-updates';

/// The update directory inside the app's own cache, which is exactly what
/// `getTemporaryDirectory()` resolves to on Android (`context.getCacheDir()`).
Future<Directory> updateDownloadDirectory() async => Directory(
  p.join((await getTemporaryDirectory()).path, updateDirectoryName),
);

/// A check must answer even when a captive portal or a dead DNS swallows the
/// socket: the release feed never gets to hold the screen that asked open.
const Duration updateConnectTimeout = Duration(seconds: 10);
const Duration updateReadTimeout = Duration(seconds: 30);
const Duration updateCheckTimeout = Duration(seconds: 25);

/// Hosts an update may come from. The metadata host is listed with the asset
/// hosts so one rule decides both, and a redirect can only ever land here.
const Set<String> _trustedUpdateHosts = {
  'api.github.com',
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

/// Why an update request could not be completed.
///
/// The kind is decided from the exception type the transport raised, not from a
/// search through its message: a check that greps for `"404"` reports a network
/// outage as a missing release as soon as a port, a byte count or a locale
/// happens to contain those digits — which is exactly how a user ends up being
/// told to check their internet when the app had no route at all.
enum UpdateFailureKind {
  unavailable,
  timeout,
  rejected,
  corrupt,
  tooLarge,
  failed,
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.kind, this.detail, {this.status});

  final UpdateFailureKind kind;

  /// A short technical note for logs and tests. Never shown as written.
  final String detail;

  /// The HTTP status, when a server answered with one.
  final int? status;

  @override
  String toString() => 'UpdateFailure(${kind.name}: $detail)';
}

/// The sentence a user reads for [failure], kept beside the failure itself so
/// every surface that reports one says the same thing.
String describeUpdateFailure(UpdateFailure failure) {
  switch (failure.kind) {
    case UpdateFailureKind.unavailable:
      return 'لا يمكن الوصول إلى مصدر التحديثات. تحقّق من الاتصال بالإنترنت.';
    case UpdateFailureKind.timeout:
      return 'انتهت مهلة الاتصال بمصدر التحديثات. أعد المحاولة.';
    case UpdateFailureKind.rejected:
      if (failure.status == HttpStatus.notFound) {
        return 'لم يُنشر إصدار جديد بعد.';
      }
      return 'مصدر التحديثات غير متاح الآن؛ حاول لاحقاً.';
    case UpdateFailureKind.corrupt:
      return 'بيانات الإصدار المنشور غير صالحة؛ حاول لاحقاً.';
    case UpdateFailureKind.tooLarge:
      return 'بيانات التحديث أكبر من الحد المسموح.';
    case UpdateFailureKind.failed:
      return 'تعذر التحقق من التحديث؛ حاول لاحقاً.';
  }
}

/// Maps anything a transport can raise onto one [UpdateFailure].
UpdateFailure classifyUpdateError(Object error) {
  if (error is UpdateFailure) return error;
  if (error is TimeoutException) {
    return const UpdateFailure(
      UpdateFailureKind.timeout,
      'The update request timed out.',
    );
  }
  if (error is HandshakeException) {
    return const UpdateFailure(
      UpdateFailureKind.rejected,
      'The update connection could not be secured.',
    );
  }
  if (error is SocketException) {
    return const UpdateFailure(
      UpdateFailureKind.unavailable,
      'No route to the update feed.',
    );
  }
  if (error is HttpException) {
    return const UpdateFailure(
      UpdateFailureKind.rejected,
      'The update feed rejected the request.',
    );
  }
  if (error is FormatException) {
    return const UpdateFailure(
      UpdateFailureKind.corrupt,
      'Release metadata is not readable.',
    );
  }
  return UpdateFailure(UpdateFailureKind.failed, error.runtimeType.toString());
}

/// A client whose every phase can end: connecting, waiting for headers and
/// reading a body. `HttpClient` alone has no read timeout at all, so a server
/// that accepts the connection and then says nothing would hold the check open
/// for as long as the surface that asked for it stays open.
HttpClient _newUpdateClient() =>
    HttpClient()..connectionTimeout = updateConnectTimeout;

/// Reads a whole response body under a hard cap, with an idle timeout between
/// chunks, and never holds more than [limit] bytes.
Future<List<int>> _readBounded(Stream<List<int>> source, int limit) async {
  final builder = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in source.timeout(updateReadTimeout)) {
    received += chunk.length;
    if (received > limit) {
      throw UpdateFailure(
        UpdateFailureKind.tooLarge,
        'Response exceeds its $limit-byte limit.',
      );
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

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

  /// SHA-256 advertised by the release API, if present. It proves the bytes
  /// that arrived are the bytes that were published; it says nothing about who
  /// published them, which the platform checks at install time.
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
    if (!_isAllowedUpdateUri(uri)) {
      throw const UpdateFailure(
        UpdateFailureKind.rejected,
        'The configured release feed is not an allowed update host.',
      );
    }
    final client = _newUpdateClient();
    try {
      final release = await _fetchMetadata(
        client,
        uri,
      ).timeout(updateCheckTimeout);
      if (release == null) return null;
      return selectUpdate(
        release,
        currentVersion: currentVersion,
        platform: platform,
        releaseTagPrefix: releaseTagPrefix,
      );
    } on Object catch (error) {
      throw classifyUpdateError(error);
    } finally {
      client.close(force: true);
    }
  }

  /// The release record, or `null` for a response that carries no published
  /// release. Everything that can go wrong on the way there is an
  /// [UpdateFailure] by the time it leaves this method.
  Future<Map<String, dynamic>?> _fetchMetadata(
    HttpClient client,
    Uri uri,
  ) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers
      ..set('Accept', 'application/vnd.github+json')
      ..set('User-Agent', 'Scan-id-update-check')
      ..set('X-GitHub-Api-Version', '2022-11-28');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw UpdateFailure(
        UpdateFailureKind.rejected,
        'Release metadata returned HTTP ${response.statusCode}.',
        status: response.statusCode,
      );
    }
    final bytes = await _readBounded(response, maxUpdateMetadataBytes);
    return parseReleaseJson(utf8.decode(bytes));
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
  final HttpClient _client = _newUpdateClient();

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
          // A stalled connection must not hold a download open forever; the
          // timeout is between chunks, so a slow but live server keeps going.
          body: response.timeout(updateReadTimeout),
        );
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (redirects >= 5 || location == null) {
        throw HttpException('Update redirect limit exceeded.', uri: current);
      }
      final next = current.resolve(location);
      if (!_isAllowedUpdateUri(next)) {
        throw HttpException(
          'Update redirect target is not trusted.',
          uri: next,
        );
      }
      current = next;
    }
  }

  @override
  void close() => _client.close(force: true);
}

/// Platform update operations. Downloads are streamed to a unique bounded
/// temporary file and accepted only when a SHA-256 digest is supplied and
/// verified. [installer] is the only thing that may hand a verified package to
/// the operating system; with none configured, installation stays refused
/// rather than pretending to have happened.
class UpdateService {
  UpdateService({
    required this.source,
    required this.currentVersion,
    this.platform = UpdatePlatform.android,
    UpdateTransport Function()? transportFactory,
    Future<Directory> Function()? temporaryDirectory,
    this.installer,
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

  /// Asks the operating system to install a package this service verified. Null
  /// means this build has no install path and never starts one.
  final UpdateInstaller? installer;
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
      await _discardPreviousDownloads(directory);
      final extension = p.extension(uri.path).toLowerCase();
      tempFile = File(
        p.join(directory.path, '$updateFilePrefix${newId()}$extension'),
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
      return fail(describeUpdateFailure(classifyUpdateError(error)));
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

  /// Hands a verified package to [installer].
  ///
  /// Verification is corruption detection, not authorization: this digest is
  /// published by the same account as the asset, so matching it cannot prove a
  /// publisher. Authorization belongs to the platform, which compares the
  /// package's signer with this app's own certificate and with the certificate
  /// the build was configured with, and refuses before the installer is opened
  /// (see `UpdateInstaller.kt`). What makes an install acceptable to the
  /// person remains the system installer's own confirmation. With no installer
  /// configured this build refuses the
  /// operation and keeps the verified file, exactly as it did before native
  /// install integration existed, so a Windows package is never executed here.
  Future<InstallResult> installUpdate(
    UpdateInfo update,
    String filePath,
  ) async {
    if (!await verifyUpdateSource(update, filePath)) {
      return InstallResult.error(
        'تعذر التحقق من ملف التحديث؛ لم يُشغَّل أي مثبت.',
      );
    }
    final target = installer;
    if (target == null) {
      return InstallResult.error(switch (platform) {
        UpdatePlatform.android =>
          'لا يفتح هذا البناء مثبت النظام تلقائياً؛ لم يبدأ مثبت النظام.',
        UpdatePlatform.windows =>
          'تثبيت Windows الهوائي غير مهيأ دون حزمة ومُثبّت موثوقين؛ لم يُشغَّل أي ملف.',
      });
    }
    final outcome = await target.install(filePath);
    final message = outcome.message ?? 'تعذر إكمال التثبيت.';
    if (!outcome.started) {
      return InstallResult.error(message);
    }
    return InstallResult.success(message);
  }

  /// Removes packages an interrupted session left behind. This directory
  /// belongs to the update feature alone, so anything already in it names a
  /// download that was never completed — keeping it only costs disk space.
  Future<void> _discardPreviousDownloads(Directory directory) async {
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!p.basename(entity.path).startsWith(updateFilePrefix)) continue;
        try {
          await entity.delete();
        } on Object {
          // An undeletable leftover must not fail a download that can proceed.
        }
      }
    } on Object {
      // An unreadable directory is created again by the caller.
    }
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
      UpdatePlatform.windows =>
        extension == '.exe'
            ? 0
            : extension == '.msi'
            ? 1
            : 2,
    };

List<String> _extensionsFor(UpdatePlatform platform) => switch (platform) {
  UpdatePlatform.android => const ['.apk'],
  UpdatePlatform.windows => const ['.exe', '.msi', '.zip'],
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
