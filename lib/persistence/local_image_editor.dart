import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../application/contracts.dart';
import '../application/ids.dart';
import '../application/image_reader.dart';
import '../domain/crop_draft.dart';
import '../domain/geometry.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import '../imaging/document_detector.dart';
import '../imaging/perspective.dart';
import '../imaging/prepare_image.dart';
import 'safe_files.dart';

class LocalImageEditor implements ImageEditor {
  const LocalImageEditor(this.files);
  final SafeFiles files;
  Future<Uint8List> _original(ImageAsset asset) async => readBoundedImage(
    (await files.existingFile(asset.originalPath)).openRead(),
  );

  @override
  Future<EditorSource> open(ImageAsset asset) async {
    final bytes = await _original(asset);
    return Isolate.run(() {
      final image = decodeForProcessing(bytes);
      final reduced = img.copyResize(
        image,
        width: image.width >= image.height ? math.min(1200, image.width) : null,
        height: image.height > image.width
            ? math.min(1200, image.height)
            : null,
      );
      return EditorSource(img.encodePng(reduced), image.width, image.height);
    });
  }

  @override
  Future<List<Point2>?> suggest(Uint8List preview) =>
      Isolate.run(() => suggestDocumentCorners(preview));

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) async {
    final bytes = await _original(asset);
    return Isolate.run(
      () => renderPerspective(bytes, recipe, previewLongEdge: 1200),
    );
  }

  @override
  Future<ImageAsset> createRevision(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async {
    final bytes = await _original(asset);
    final root = files.root.path;
    return Isolate.run(() => _saveRevision(root, asset, recipe, bytes));
  }
}

Future<ImageAsset> _saveRevision(
  String root,
  ImageAsset asset,
  ImageEditRecipe recipe,
  Uint8List original,
) async {
  final rendered = warpPerspective(original, recipe);
  final png = img.encodePng(rendered);
  final small = img.copyResize(
    rendered,
    width: rendered.width >= rendered.height
        ? math.min(320, rendered.width)
        : null,
    height: rendered.height > rendered.width
        ? math.min(320, rendered.height)
        : null,
  );
  final id = newId();
  final safe = SafeFiles(Directory(root));
  final staging = Directory(await safe.checkedPath('staging/$id'));
  require(!await staging.exists(), 'تعارض في معرّف المعالجة.');
  await staging.create(recursive: true);
  try {
    await File('${staging.path}/working.png').writeAsBytes(png, flush: true);
    await File(
      '${staging.path}/thumb.jpg',
    ).writeAsBytes(img.encodeJpg(small, quality: 82), flush: true);
    // Prefix ownership was validated by Project; never replace an earlier file.
    final prefix = asset.originalPath.substring(
      0,
      asset.originalPath.lastIndexOf('/'),
    );
    final relative = '$prefix/edits/$id';
    final destination = Directory(await safe.checkedPath(relative));
    require(!await destination.exists(), 'نسخة المعالجة موجودة مسبقاً.');
    await destination.parent.create(recursive: true);
    await staging.rename(destination.path);
    final log = [...asset.transforms, 'perspective-edit:$id'];
    return ImageAsset(
      id: asset.id,
      captureId: asset.captureId,
      name: asset.name,
      originalPath: asset.originalPath,
      workingPath: '$relative/working.png',
      thumbnailPath: '$relative/thumb.jpg',
      width: rendered.width,
      height: rendered.height,
      crop: recipe.geometry,
      adjustments: recipe.adjustments,
      transforms: log.skip(math.max(0, log.length - 500)).toList(),
    );
  } finally {
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}
