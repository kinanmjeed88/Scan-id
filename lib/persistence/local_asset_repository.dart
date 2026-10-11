import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../application/contracts.dart';
import '../application/ids.dart';
import '../domain/image_limits.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import '../imaging/image_header.dart';
import '../imaging/large_jpeg_plan.dart';
import '../imaging/prepare_image.dart';
import 'large_jpeg_scaler.dart';
import 'safe_files.dart';

class LocalAssetRepository implements AssetRepository {
  const LocalAssetRepository(
    this.files, {
    this.largeJpegScaler = const PlatformLargeJpegScaler(),
  });
  final SafeFiles files;
  final LargeJpegScaler largeJpegScaler;

  @override
  Future<File> resolve(String relativePath) => files.existingFile(relativePath);

  @override
  Future<Uint8List> previewImage(Uint8List source) async {
    final scaled = await _scaleLargeSource(source);
    final boundedSource = scaled?.png ?? source;
    return Isolate.run(() => prepareBoundedPreview(boundedSource));
  }

  @override
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  ) async {
    validId(projectId);
    validName(name);
    final scaled = await _scaleLargeSource(bytes);
    final root = files.root.path;
    // Pixel processing and writes stay in an isolate. Only the bounded native
    // sampled decode runs through the platform decoder before this hand-off.
    return Isolate.run(
      () => _import(
        root,
        projectId,
        name,
        bytes,
        processingPng: scaled?.png,
        sourceExtension: scaled?.sourceExtension,
        scaleNote: scaled?.plan.transformNote,
      ),
    );
  }

  @override
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
    Uint8List bytes,
  ) async {
    validId(projectId);
    validId(assetId);
    final scaled = await _scaleLargeSource(bytes);
    final root = files.root.path;
    return Isolate.run(
      () => _replace(
        root,
        projectId,
        assetId,
        bytes,
        processingPng: scaled?.png,
        sourceExtension: scaled?.sourceExtension,
        scaleNote: scaled?.plan.transformNote,
      ),
    );
  }

  Future<_ScaledSource?> _scaleLargeSource(Uint8List source) async {
    final header = inspectImageHeader(source);
    if (withinImageBudget(header.width, header.height)) return null;
    final plan = LargeJpegPlan.fromHeader(header);
    final png = await largeJpegScaler.scaleJpeg(source, plan);
    require(
      png.length <= maxScaledWorkingBytes,
      'نتيجة تصغير الصورة تتجاوز حد التخزين المؤقت الآمن.',
    );
    final scaledHeader = inspectImageHeader(png);
    final orientedWidth = plan.orientation >= 5
        ? plan.sourceHeight
        : plan.sourceWidth;
    final orientedHeight = plan.orientation >= 5
        ? plan.sourceWidth
        : plan.sourceHeight;
    final sourceAspect = orientedWidth / orientedHeight;
    final scaledAspect = scaledHeader.width / scaledHeader.height;
    final roundingTolerance = 1 / scaledHeader.width + 1 / scaledHeader.height;
    require(
      scaledHeader.encoding == ImageEncoding.png &&
          scaledHeader.width * scaledHeader.height <= plan.targetPixels &&
          (scaledAspect / sourceAspect - 1).abs() <= roundingTolerance,
      'فشل تصغير JPEG مع الحفاظ على أبعاده واتجاهه.',
    );
    final longEdge = math.max(scaledHeader.width, scaledHeader.height);
    final shortEdge = math.min(scaledHeader.width, scaledHeader.height);
    final previewShortEdge =
        (shortEdge * math.min(1, maxRecognitionPreviewLongEdge / longEdge))
            .floor();
    require(
      previewShortEdge >= minRecognitionPreviewSide,
      'نتيجة تصغير JPEG أصغر من حد التحليل الأدنى؛ '
      'استورد نسخة أقل استطالة أو أصغر حجماً.',
    );
    return _ScaledSource(png, 'jpg', plan);
  }
}

class _ScaledSource {
  const _ScaledSource(this.png, this.sourceExtension, this.plan);
  final Uint8List png;
  final String sourceExtension;
  final LargeJpegPlan plan;
}

Future<ImageAsset> _import(
  String root,
  String projectId,
  String name,
  Uint8List bytes, {
  Uint8List? processingPng,
  String? sourceExtension,
  String? scaleNote,
}) async {
  final prepared = processingPng == null
      ? prepareImage(bytes)
      : prepareScaledWorkingPng(processingPng);
  final originalExtension = sourceExtension ?? prepared.extension;
  final id = newId();
  final files = SafeFiles(Directory(root));
  final relative = 'projects/$projectId/assets/$id';
  final staging = Directory(await _stagingDirectory(files, id));
  try {
    await _writePrepared(staging.path, bytes, prepared, originalExtension);
    await _publish(files, staging, relative);
    return ImageAsset(
      id: id,
      name: name,
      originalPath: '$relative/original.$originalExtension',
      workingPath: '$relative/working.png',
      thumbnailPath: '$relative/thumb.jpg',
      width: prepared.width,
      height: prepared.height,
      transforms: ['exif-orientation', if (scaleNote != null) scaleNote],
    );
  } finally {
    // Clean only the unique staging directory created by this operation.
    // Never remove a committed asset on a database save failure.
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}

/// Replacements live under the asset prefix the project already owns, so the
/// previous files stay byte-identical and the layout keeps its asset id.
Future<ReplacementFiles> _replace(
  String root,
  String projectId,
  String assetId,
  Uint8List bytes, {
  Uint8List? processingPng,
  String? sourceExtension,
  String? scaleNote,
}) async {
  final prepared = processingPng == null
      ? prepareImage(bytes)
      : prepareScaledWorkingPng(processingPng);
  final originalExtension = sourceExtension ?? prepared.extension;
  final id = newId();
  final files = SafeFiles(Directory(root));
  final relative = 'projects/$projectId/assets/$assetId/replacements/$id';
  final staging = Directory(await _stagingDirectory(files, id));
  try {
    await _writePrepared(staging.path, bytes, prepared, originalExtension);
    await _publish(files, staging, relative);
    return ReplacementFiles(
      revision: id,
      originalPath: '$relative/original.$originalExtension',
      workingPath: '$relative/working.png',
      thumbnailPath: '$relative/thumb.jpg',
      width: prepared.width,
      height: prepared.height,
      sourceScaling: scaleNote,
    );
  } finally {
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}

Future<String> _stagingDirectory(SafeFiles files, String id) async {
  final path = await files.checkedPath('staging/$id');
  final staging = Directory(path);
  require(!await staging.exists(), 'تعارض في مجلد الاستيراد.');
  await staging.create(recursive: true);
  return path;
}

Future<void> _writePrepared(
  String stagingPath,
  Uint8List original,
  PreparedImage prepared,
  String originalExtension,
) async {
  // EXIF remains in the original, as promised. No destructive sanitization.
  await File(
    '$stagingPath/original.$originalExtension',
  ).writeAsBytes(original, flush: true);
  await File(
    '$stagingPath/working.png',
  ).writeAsBytes(prepared.working, flush: true);
  await File(
    '$stagingPath/thumb.jpg',
  ).writeAsBytes(prepared.thumbnail, flush: true);
}

Future<void> _publish(
  SafeFiles files,
  Directory staging,
  String relative,
) async {
  final destination = await files.checkedPath(relative);
  require(!await Directory(destination).exists(), 'تعارض في معرّف الصورة.');
  await Directory(destination).parent.create(recursive: true);
  await staging.rename(destination);
}
