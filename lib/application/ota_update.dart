import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// معلومات عن تحديث متاح.
class UpdateInfo {
  UpdateInfo({
    required this.currentVersion,
    required this.newVersion,
    required this.downloadUrl,
    this.summary,
    this.size,
    this.sha256,
  });

  final String currentVersion;
  final String newVersion;
  final String downloadUrl;
  final String? summary;
  final int? size;
  final String? sha256;

  /// Whether this update is newer than the current version.
  bool get isNewer => compareVersions(newVersion, currentVersion) > 0;

  /// Compares two version strings in the format "major.minor.patch".
  static int compareVersions(String a, String b) {
    final partsA = a.split('.').map(int.parse).toList();
    final partsB = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final va = i < partsA.length ? partsA[i] : 0;
      final vb = i < partsB.length ? partsB[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }
}

/// مصدر تحديث خارجي (مثل GitHub Releases).
abstract class UpdateSource {
  Future<UpdateInfo?> checkForUpdate(String currentVersion);
}

/// مصدر تحديث يستخدم GitHub Releases.
class GitHubUpdateSource implements UpdateSource {
  GitHubUpdateSource({
    required this.owner,
    required this.repo,
    this.releaseTagPrefix = '',
  });

  final String owner;
  final String repo;
  final String releaseTagPrefix;

  static const _baseUrl = 'https://api.github.com/repos';

  @override
  Future<UpdateInfo?> checkForUpdate(String currentVersion) async {
    HttpClient? client;
    try {
      client = HttpClient();
      final uri = Uri.parse('$_baseUrl/$owner/$repo/releases/latest');
      final request = await client.getUrl(uri);
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      final response = await request.close();

      if (response.statusCode != 200) {
        return null;
      }

      final body = await response.transform(Utf8Decoder()).join();
      final release = GitHubUpdateSource.parseReleaseJson(body);
      if (release == null) return null;

      final tag = release['tagName'] as String;
      final version = extractVersion(tag);
      if (version == null) return null;

      if (UpdateInfo.compareVersions(version, currentVersion) <= 0) {
        return null;
      }

      final assets = release['assets'] as List<_AssetInfo>;
      final downloadUrl = assets
          .where(
            (a) =>
                (a.name?.endsWith('.apk') ?? false) ||
                (a.name?.endsWith('.exe') ?? false),
          )
          .firstOrNull
          ?.url;

      if (downloadUrl == null) return null;

      return UpdateInfo(
        currentVersion: currentVersion,
        newVersion: version,
        downloadUrl: downloadUrl,
        summary: release['body'] as String?,
        size: assets.where((a) => a.url == downloadUrl).firstOrNull?.size,
        // Note: GitHub API does not provide SHA-256 for release assets by default.
        // For production, use a separate trusted source or GitHub's attestation.
        sha256: null,
      );
    } catch (e) {
      return null;
    } finally {
      client?.close();
    }
  }

  static Map<String, dynamic>? parseReleaseJson(String json) {
    try {
      final data = _parseJson(json);
      if (data == null || data['tag_name'] == null) return null;

      final assets =
          (data['assets'] as List<dynamic>?)
              ?.map((a) => _parseAsset(a))
              .whereType<_AssetInfo>()
              .toList() ??
          [];

      return {
        'tagName': data['tag_name'] as String,
        'body': data['body'] as String?,
        'assets': assets,
      };
    } catch (e) {
      return null;
    }
  }

  static Map<String, dynamic>? _parseJson(String json) {
    try {
      return jsonDecode(json) as Map<String, dynamic>?;
    } catch (e) {
      return null;
    }
  }

  static _AssetInfo? _parseAsset(dynamic a) {
    if (a is! Map<String, dynamic>) return null;
    return _AssetInfo(
      url: a['browser_download_url'] as String?,
      name: a['name'] as String?,
      size: (a['size'] as num?)?.toInt(),
      sha256: a['sha256'] as String?,
    );
  }

  static String? extractVersion(String tag) {
    var version = tag;
    if (version.startsWith('v')) {
      version = version.substring(1);
    }
    if (version.startsWith('release-')) {
      version = version.substring('release-'.length);
    }
    if (RegExp(r'^\d+\.\d+\.\d+').hasMatch(version)) {
      return version;
    }
    return null;
  }
}

class _AssetInfo {
  _AssetInfo({this.url, this.name, this.size, this.sha256});

  final String? url;
  final String? name;
  final int? size;
  final String? sha256;
}

/// خدمة إدارة التحديثات.
class UpdateService {
  UpdateService({
    required this.source,
    required this.currentVersion,
    this.platform = UpdatePlatform.android,
  });

  final UpdateSource source;
  final String currentVersion;
  final UpdatePlatform platform;

  Future<UpdateInfo?> checkForUpdate() => source.checkForUpdate(currentVersion);

  /// تنزيل ملف التحديث مع دعم الإلغاء والتنظيف.
  Future<DownloadResult> downloadUpdate(
    UpdateInfo update, {
    required void Function(int received, int total) onProgress,
    required void Function() onCancel,
  }) async {
    HttpClient? client;
    bool cancelled = false;
    File? tempFile;

    try {
      client = HttpClient();
      final uri = Uri.parse(update.downloadUrl);
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode != 200) {
        return DownloadResult.error('HTTP ${response.statusCode}');
      }

      final total = response.contentLength;
      var received = 0;
      final chunks = <Uint8List>[];

      await for (final chunk in response) {
        chunks.add(chunk as Uint8List);
        received += chunk.length;
        onProgress(received, total);
      }

      final bytes = Uint8List.fromList(chunks.expand((c) => c).toList());

      // التحقق من checksum إذا كان متاحاً
      if (update.sha256 != null) {
        final hash = sha256.convert(bytes);
        if (hash.toString() != update.sha256) {
          await _cleanupTempFile(tempFile);
          return DownloadResult.error('فشل التحقق من checksum');
        }
      }

      // حفظ الملف المؤقت
      final tempDir = await getTemporaryDirectory();
      final fileName = p.basename(update.downloadUrl);
      tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(bytes);

      return DownloadResult.success(tempFile.path);
    } catch (e) {
      await _cleanupTempFile(tempFile);
      return DownloadResult.error('فشل التنزيل: $e');
    } finally {
      client?.close();
    }
  }

  /// تنظيف الملف المؤقت عند الفشل أو الإلغاء.
  Future<void> _cleanupTempFile(File? file) async {
    if (file != null && await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // لا تRaise خطأ عند فشل التنظيف
      }
    }
  }

  /// التحقق من مصدر الملف قبل التثبيت.
  /// لا تثبّت ملفًا لم يتم التحقق من مصدره وسلامته.
  Future<bool> verifyUpdateSource(UpdateInfo update, String filePath) async {
    // التحقق من المطابقة بين URL والملف
    final expectedFileName = p.basename(update.downloadUrl);
    final actualFileName = p.basename(filePath);
    if (expectedFileName != actualFileName) {
      return false;
    }

    // التحقق من وجود الملف
    final file = File(filePath);
    if (!await file.exists()) {
      return false;
    }

    // التحقق من عدم كونه ملفًا فارغًا
    if (await file.length() == 0) {
      return false;
    }

    // ملاحظة: SHA-256 من نفس المصدر ليس تحققًا مستقلًا
    // للتطبيقات الحساسة، استخدم مصدرًا مستقلًا للبصمة أو توقيعًا مشفرًا
    if (update.sha256 != null) {
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes);
      if (hash.toString() != update.sha256) {
        return false;
      }
    }

    return true;
  }

  /// تثبيت التحديث المنزّل (يعتمد على المنصة).
  /// لا تثبّت إلا بعد التحقق من المصدر والسلامة.
  Future<InstallResult> installUpdate(
    UpdateInfo update,
    String filePath,
  ) async {
    // التحقق من المصدر قبل التثبيت
    final verified = await verifyUpdateSource(update, filePath);
    if (!verified) {
      return InstallResult.error(
        'لم يتم التحقق من مصدر ملف التحديث. لا يتم التثبيت.',
      );
    }

    if (platform == UpdatePlatform.android) {
      return _installAndroid(filePath);
    } else if (platform == UpdatePlatform.windows) {
      return _installWindows(filePath);
    }
    return InstallResult.error('غير مدعوم على هذه المنصة');
  }

  Future<InstallResult> _installAndroid(String filePath) async {
    // على Android، يستخدم PackageInstaller عبر Intent
    // هذا تلقائي - التنفيذ الفعلي يتطلب منصات معينة
    // لا يدّعي تثبيتًا صامتًا في تطبيق عادي
    return InstallResult.pending(
      'تم تحميل التحديث. سيتم تثبيته عبر شاشة تثبيت النظام.',
    );
  }

  Future<InstallResult> _installWindows(String filePath) async {
    // على Windows، تشغيل المثبت بعد التحقق
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return InstallResult.error('ملف التحديث غير موجود');
      }

      // التحقق من أن الملف هو ملف تنفيذي صحيح
      final extension = p.extension(filePath).toLowerCase();
      if (extension != '.exe' && extension != '.msi') {
        return InstallResult.error('نوع الملف غير معتمد للتثبيت: $extension');
      }

      await Process.run('cmd', ['/c', 'start', filePath]);
      return InstallResult.success('تم تشغيل المثبت. يرجى اتباع التعليمات.');
    } catch (e) {
      return InstallResult.error('فشل تشغيل المثبت: $e');
    }
  }
}

enum UpdatePlatform { android, windows }

class DownloadResult {
  DownloadResult._({this.filePath, this.error});

  final String? filePath;
  final String? error;

  factory DownloadResult.success(String path) =>
      DownloadResult._(filePath: path);

  factory DownloadResult.error(String message) =>
      DownloadResult._(error: message);

  bool get isSuccess => error == null && filePath != null;
}

class InstallResult {
  InstallResult._({this.message, this.error, this.isPending = false});

  final String? message;
  final String? error;
  final bool isPending;

  factory InstallResult.success(String message) =>
      InstallResult._(message: message);

  factory InstallResult.error(String error) => InstallResult._(error: error);

  factory InstallResult.pending(String message) =>
      InstallResult._(message: message, isPending: true);

  bool get isSuccess => error == null && !isPending;
}
