import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../application/cancellation.dart';
import '../application/import_trace.dart';
import '../application/contracts.dart';
import '../domain/boundary_decision.dart';
import '../application/ids.dart';
import '../application/stage_budget.dart';
import '../application/image_reader.dart';
import '../domain/crop_draft.dart';
import '../domain/geometry.dart';
import '../domain/image_limits.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import '../imaging/docquad_model.dart';
import '../imaging/boundary_arbitration.dart';
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

/// Hard limit on the learned boundary cascade for one preview.
///
/// DocQuadNet and DocAligner both run inside the ONNX Runtime plugin. A native
/// call that never answers used to leave the import waiting with no result at
/// all; expiring the stage falls through to the independent classical detector,
/// which is exactly the next cascade stage and needs no native code.
const Duration defaultBoundaryProposalBudget = Duration(seconds: 45);

/// Creates the isolate closure in a minimal, sendable-only scope. Keeping this
/// out of [LocalImageEditor.suggestProposal] prevents the closure context from
/// picking up the native model handle or the cancellation token.
Future<BoundaryMeasurements> _measureBoundaryCandidatesInIsolate(
  Uint8List preview,
  List<double>? encoded,
  CancellationToken? cancellation,
) => runCancellableIsolate<BoundaryMeasurements>(
  () => measureBoundaryCandidates(preview, encoded),
  cancellation: cancellation,
  debugName: 'boundary-measured-arbitration',
);

class LocalImageEditor
    implements ImageEditor, CropBytesImageEditor, BoundaryProposalImageEditor {
  const LocalImageEditor(
    this.files, {
    this.readFullResolutionRegion,
    this.boundaryProposer,
    this.boundaryBudget = defaultBoundaryProposalBudget,
  });
  final SafeFiles files;

  /// Null in tests that never crop a large JPEG. A production editor must set
  /// it. A missing reader is an explicit failure, not a silent sample.
  final FullResolutionRegionReader? readFullResolutionRegion;

  /// Optional offline learned proposer. Missing/failed/invalid model results
  /// fall through to the local classical detector and remain review-only.
  final BoundaryProposalModel? boundaryProposer;

  /// Upper bound on the learned cascade before the classical fallback runs.
  final Duration boundaryBudget;

  Future<Uint8List> _source(ImageAsset asset) async => readBoundedImage(
    (await files.existingFile(asset.processingInputPath)).openRead(),
  );

  @override
  Future<EditorSource> open(
    ImageAsset asset, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final bytes = await ImportTrace.stage(
      'source_read',
      () => _source(asset),
      phase: 'preview',
    );
    cancellation?.throwIfCancelled();
    return _openSourceIsolated(bytes, cancellation);
  }

  /// Identifies the offline cascade for diagnostics; the proposal's producer
  /// field records whether DocQuadNet or the classical fallback actually ran.
  @override
  String? get boundaryModelId => boundaryProposer == null
      ? null
      : '${boundaryProposer!.modelId}+measured-classical-arbitration';

  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    BoundaryProposal? learnedProposal;
    final learned = boundaryProposer;
    if (learned != null) {
      final outcome = await _boundedCascade(learned, preview, cancellation);
      if (outcome.didTimeOut) {
        // A stuck native call must not hold the import: the measured classical
        // detector below is independent of the plugin and stays review-only.
        developer.log(
          'learned boundary stage expired; using measured arbitration',
          name: 'scan_id.boundary',
        );
      } else if (outcome.error != null) {
        developer.log(
          'learned boundary stage failed '
          'type=${outcome.error.runtimeType}; using measured arbitration',
          name: 'scan_id.boundary',
        );
      } else {
        learnedProposal = outcome.value;
      }
    }
    cancellation?.throwIfCancelled();

    // ALWAYS measure the classical candidate, even when both learned models
    // agreed. Geometry validation alone cannot see that four valid points sit
    // in the middle of a clearly visible card; measured edge support can. The
    // two are compared on one scale and the better-measured quad is retained.
    final encoded = learnedProposal?.corners == null
        ? null
        : <double>[
            for (final point in learnedProposal!.corners!) point.x,
            for (final point in learnedProposal!.corners!) point.y,
          ];
    final measurements = await _measureBoundaryCandidatesInIsolate(
      preview,
      encoded,
      cancellation,
    );
    cancellation?.throwIfCancelled();
    return arbitrateBoundaryProposal(
      learned: learnedProposal,
      measurements: measurements,
    );
  }

  /// Runs the offline cascade in its own scope.
  ///
  /// Both isolate hand-offs (this learned stage and the measured arbitration
  /// below) must be created in scopes that hold nothing but sendable bytes.
  /// Dart closures can share an enclosing context with sibling closures; while
  /// the two shared a scope, the isolate message also carried the native cascade
  /// object and failed with
  /// `ArgumentError: Illegal argument in isolate message`.
  Future<StageOutcome<BoundaryProposal?>> _boundedCascade(
    BoundaryProposalModel learned,
    Uint8List preview,
    CancellationToken? cancellation,
  ) => runStageWithin<BoundaryProposal?>(
    () => learned.suggestProposal(preview, cancellation: cancellation),
    budget: boundaryBudget,
    name: 'boundary-cascade',
    cancellation: cancellation,
  );

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async =>
      (await suggestProposal(preview))?.corners;

  @override
  Future<Uint8List> preview(
    ImageAsset asset,
    ImageEditRecipe recipe, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final bytes = await _source(asset);
    cancellation?.throwIfCancelled();
    return _renderPreviewIsolated(bytes, recipe, cancellation);
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
    return _saveRevisionIsolated(root, asset, recipe, bytes);
  }

  @override
  Future<Uint8List> renderCropBytes(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async {
    if (asset.hasScaledLargeSource && _usesOriginalJpeg(recipe)) {
      final prepared = await _prepareFullResolutionExtract(asset, recipe);
      return _renderCropBytesIsolated(prepared.extracted, prepared.recipe);
    }
    final bytes = await _source(asset);
    return _renderCropBytesIsolated(bytes, recipe);
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

  Future<({Uint8List extracted, ImageEditRecipe recipe})>
  _prepareFullResolutionExtract(
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
      orientedWidth: oriented.$1,
      orientedHeight: oriented.$2,
      regionWidth: extractedHeader.width,
      regionHeight: extractedHeader.height,
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
    return (extracted: extracted, recipe: localRecipe);
  }

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
    final prepared = await _prepareFullResolutionExtract(asset, recipe);
    final root = files.root.path;
    return _saveRevisionIsolated(
      root,
      asset,
      prepared.recipe,
      prepared.extracted,
      storedCorners: [
        for (final corner in recipe.geometry.corners)
          Point2(corner.x, corner.y),
      ],
    );
  }
}

// Separate scopes ensure these closures contain only bytes/recipes. In
// particular, they must not capture LocalImageEditor, the native region-reader
// method tear-off or the live ONNX sessions held by boundaryProposer.
Future<EditorSource> _openSourceIsolated(
  Uint8List bytes,
  CancellationToken? cancellation,
) => runCancellableIsolate(
  () {
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
  },
  cancellation: cancellation,
  debugName: 'crop-source',
);

Future<Uint8List> _renderPreviewIsolated(
  Uint8List bytes,
  ImageEditRecipe recipe,
  CancellationToken? cancellation,
) => runCancellableIsolate(
  () => renderPerspective(bytes, recipe, previewLongEdge: 1200),
  cancellation: cancellation,
  debugName: 'crop-preview',
);

Future<Uint8List> _renderCropBytesIsolated(
  Uint8List bytes,
  ImageEditRecipe recipe,
) => Isolate.run(() => img.encodePng(warpPerspective(bytes, recipe)));

Future<ImageAsset> _saveRevisionIsolated(
  String root,
  ImageAsset asset,
  ImageEditRecipe recipe,
  Uint8List bytes, {
  List<Point2>? storedCorners,
}) => Isolate.run(
  () => _saveRevision(root, asset, recipe, bytes, storedCorners: storedCorners),
);

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
