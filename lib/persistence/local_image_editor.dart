import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import '../application/contracts.dart';
import '../application/ids.dart';
import '../application/image_reader.dart';
import '../domain/boundary_decision.dart';
import '../domain/crop_draft.dart';
import '../domain/geometry.dart';
import '../domain/image_limits.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import '../imaging/ai_document_detector.dart';
import '../imaging/document_detector.dart';
import '../imaging/document_segmenter.dart';
import '../imaging/full_resolution_manual_crop.dart';
import '../imaging/image_header.dart';
import '../imaging/perspective.dart';
import '../imaging/prepare_image.dart';
import 'safe_files.dart';

/// Reads one oriented rectangle from an immutable JPEG at native density.
///
/// The editor uses this only for the final revision of a sampled large JPEG.
/// Preview and corner dragging stay on the bounded working PNG.
typedef FullResolutionRegionReader =
    Future<Uint8List> Function({
      required Uint8List source,
      required int sourceWidth,
      required int sourceHeight,
      required int orientation,
      required double left,
      required double top,
      required double right,
      required double bottom,
    });

class LocalImageEditor implements BoundaryProposalImageEditor {
  const LocalImageEditor(
    this.files, {
    this.readFullResolutionRegion,
    this.aiBundle,
  });
  final SafeFiles files;

  /// Null in tests that never crop a large JPEG. A production editor must set
  /// it. A missing reader is an explicit failure, not a silent sample.
  final FullResolutionRegionReader? readFullResolutionRegion;

  /// Verified offline ONNX model bundle (`ScanIdDocNet-v1`). When null (e.g.,
  /// existing classical unit tests), falls back to the deterministic classical
  /// `suggestDocumentCorners` detector.
  final AiModelBundle? aiBundle;

  @override
  String? get boundaryModelId => aiBundle?.bundleId;

  Future<Uint8List> _source(ImageAsset asset) async => readBoundedImage(
    (await files.existingFile(asset.processingInputPath)).openRead(),
  );

  @override
  Future<EditorSource> open(ImageAsset asset) async {
    final bytes = await _source(asset);
    return Isolate.run(() {
      final image = decodeForProcessing(bytes);
      final reduced = img.copyResize(
        image,
        width: image.width >= image.height
            ? math.min(maxRecognitionPreviewLongEdge, image.width)
            : null,
        height: image.height > image.width
            ? math.min(maxRecognitionPreviewLongEdge, image.height)
            : null,
      );
      return EditorSource(img.encodePng(reduced), image.width, image.height);
    });
  }

  static final LinkedHashMap<String, AiSceneDetection> _aiSceneCache =
      LinkedHashMap<String, AiSceneDetection>();

  Future<AiSceneDetection> _detectAiSceneCached(
    Uint8List preview,
    AiModelBundle bundle,
  ) async {
    final key = '${bundle.bundleId}:${sha256.convert(preview)}';
    final cached = _aiSceneCache.remove(key);
    if (cached != null) {
      _aiSceneCache[key] = cached;
      return cached;
    }
    final computed = await Isolate.run(
      () => detectSceneWithAiBundle(preview, bundle),
    );
    if (_aiSceneCache.length >= 8) {
      _aiSceneCache.remove(_aiSceneCache.keys.first);
    }
    _aiSceneCache[key] = computed;
    return computed;
  }

  /// Runs multi-document segmentation using [aiBundle] when verified, sharing
  /// the bounded preview cache with [suggestProposal] so singleton imports do
  /// not execute Stage-1/Stage-2 ONNX inference twice on the same preview.
  Future<SegmentationResult> segment(Uint8List preview) async {
    final bundle = aiBundle;
    if (bundle != null) {
      final scene = await _detectAiSceneCached(preview, bundle);
      return scene.toSegmentationResult();
    }
    return Isolate.run(() => segmentDocuments(preview));
  }

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async {
    final bundle = aiBundle;
    if (bundle != null) {
      final scene = await _detectAiSceneCached(preview, bundle);
      return scene.candidates.isEmpty ? null : scene.candidates.first.corners;
    }
    return Isolate.run(() => suggestDocumentCorners(preview));
  }

  @override
  Future<BoundaryProposal?> suggestProposal(Uint8List preview) async {
    final bundle = aiBundle;
    if (bundle != null) {
      final scene = await _detectAiSceneCached(preview, bundle);
      if (scene.candidates.isEmpty || scene.candidates.length > 1) {
        return null;
      }
      return scene.candidates.single.toBoundaryProposal();
    }
    return Isolate.run(() {
      final corners = suggestDocumentCorners(preview);
      if (corners == null) return null;
      return BoundaryProposal(
        producer: BoundaryProducer.wholeFrameDetector,
        corners: corners,
      );
    });
  }

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) async {
    final bytes = await _source(asset);
    return Isolate.run(
      () => renderPerspective(bytes, recipe, previewLongEdge: 1200),
    );
  }

  @override
  Future<ImageAsset> createRevision(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async {
    if (asset.hasScaledLargeSource && _usesOriginalJpeg(recipe)) {
      return _createFullResolutionRevision(asset, recipe);
    }
    final bytes = await _source(asset);
    final root = files.root.path;
    return Isolate.run(() => _saveRevision(root, asset, recipe, bytes));
  }

  /// A sampled large JPEG uses the original for every region except the whole
  /// oriented frame.
  ///
  /// That frame cannot fit the 16 MP budget, so adjustments and recovery of an
  /// uncropped asset keep the import sample. Crop commands refuse it before
  /// they reach this method. A smaller region that does not fit is refused
  /// inside [_createFullResolutionRevision], never replaced by the sample.
  bool _usesOriginalJpeg(ImageEditRecipe recipe) =>
      !coversOrientedFrame(manualCropBounds(recipe.geometry.corners));

  /// Final pixels of a sampled large JPEG come from the immutable original.
  ///
  /// The recipe corners are normalized to the EXIF-oriented preview, which is
  /// a uniform scale of that same frame. The platform extracts only the
  /// quadrilateral's bounds; the warp then uses those pixels. A region that
  /// cannot fit the existing budget fails here. The sampled PNG is not a
  /// fallback.
  Future<ImageAsset> _createFullResolutionRevision(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async {
    final readRegion = readFullResolutionRegion;
    if (readRegion == null) {
      throw const ValidationException(
        'لا تتوفر معالجة JPEG كاملة الدقة على هذا النظام؛ '
        'لن يُستخدم التصغير الصامت.',
      );
    }
    final original = await readBoundedImage(
      (await files.existingFile(asset.originalPath)).openRead(),
    );
    final header = inspectImageHeader(original);
    require(
      header.encoding == ImageEncoding.jpeg,
      'الأصل الكبير ليس JPEG صالحاً للقص كامل الدقة.',
    );
    final oriented = orientedPixelSize(
      header.width,
      header.height,
      header.orientation,
    );
    final bounds = manualCropBounds(recipe.geometry.corners);
    requireFullResolutionCropFits(
      bounds: bounds,
      orientedWidth: oriented.$1,
      orientedHeight: oriented.$2,
    );
    final extracted = await readRegion(
      source: original,
      sourceWidth: header.width,
      sourceHeight: header.height,
      orientation: header.orientation,
      left: bounds.left,
      top: bounds.top,
      right: bounds.right,
      bottom: bounds.bottom,
    );
    final extractedHeader = inspectImageHeader(extracted);
    require(
      extractedHeader.encoding == ImageEncoding.png &&
          withinImageBudget(extractedHeader.width, extractedHeader.height),
      'منطقة JPEG كاملة الدقة غير صالحة.',
    );
    final localCorners = remapCornersIntoRegion(
      recipe.geometry.corners,
      bounds,
    );
    final measured = CropDraft(
      corners: localCorners,
      adjustments: recipe.adjustments,
    ).toRecipe(extractedHeader.width, extractedHeader.height);
    final storedAspect =
        recipe.geometry.outputWidth / recipe.geometry.outputHeight;
    final measuredAspect =
        measured.geometry.outputWidth / measured.geometry.outputHeight;
    // A manual aspect baked into the requested recipe is kept. Ordinary
    // floor rounding between the preview estimate and this extract is not.
    final imposed =
        storedAspect > 0 &&
        measuredAspect > 0 &&
        (storedAspect / measuredAspect - 1).abs() > .01;
    final localRecipe = imposed
        ? CropDraft(
            corners: localCorners,
            adjustments: recipe.adjustments,
            aspectRatio: storedAspect,
          ).toRecipe(extractedHeader.width, extractedHeader.height)
        : measured;
    final root = files.root.path;
    return Isolate.run(
      () => _saveRevision(
        root,
        asset,
        localRecipe,
        extracted,
        storedCorners: [
          for (final corner in recipe.geometry.corners)
            Point2(corner.x, corner.y),
        ],
      ),
    );
  }
}

Future<ImageAsset> _saveRevision(
  String root,
  ImageAsset asset,
  ImageEditRecipe recipe,
  Uint8List original, {
  List<Point2>? storedCorners,
}) async {
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
      // A revision changes pixels, never provenance or crop authorship: dropping
      // either would turn a derived or manually cropped asset into an apparent
      // original / automatic crop.
      derivedFrom: asset.derivedFrom,
      userAuthoredCrop: asset.userAuthoredCrop,
      name: asset.name,
      originalPath: asset.originalPath,
      workingPath: '$relative/working.png',
      thumbnailPath: '$relative/thumb.jpg',
      width: rendered.width,
      height: rendered.height,
      // A full-resolution extract warps local corners, but the saved recipe
      // must stay in the preview's full-frame space so the next edit maps.
      crop: storedCorners == null
          ? recipe.geometry
          : CropGeometry(
              corners: storedCorners,
              outputWidth: rendered.width,
              outputHeight: rendered.height,
            ),
      adjustments: recipe.adjustments,
      transforms: boundedTransformLog(log),
    );
  } finally {
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}
