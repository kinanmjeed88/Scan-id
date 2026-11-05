/// Region-isolated OCR image preparation. This creates an in-memory, bounded
/// OCR input only; it never writes a file or changes the source image.
library;

import 'dart:typed_data';

import '../application/cancellation.dart';
import '../domain/crop_draft.dart';
import '../domain/geometry.dart';
import '../domain/image_limits.dart';
import '../domain/validation.dart';
import 'image_header.dart';
import 'perspective.dart';
import 'region_crop.dart';

/// Runs the CPU-heavy decode and perspective preparation away from the UI
/// isolate. The computation is read-only and can be killed on cancellation.
Future<Uint8List> prepareOcrRegionIsolated(
  Uint8List previewBytes, {
  List<Point2>? corners,
  List<double>? region,
  CancellationToken? cancellation,
}) => runCancellableIsolate(
  () => prepareOcrRegion(previewBytes, corners: corners, region: region),
  cancellation: cancellation,
  debugName: 'ocr-region',
);

/// Prepares one detected document's preview for an OCR engine.
///
/// A trustworthy accepted quadrilateral is warped with the existing geometry
/// path. If no accepted quad exists, a measured segmentation region is cropped
/// axis-aligned. Only the single-document fallback with no separate region may
/// use the whole preview. The source is header-checked against the normal image
/// budget, and a perspective result is capped to the recognition preview edge.
Uint8List prepareOcrRegion(
  Uint8List previewBytes, {
  List<Point2>? corners,
  List<double>? region,
}) {
  final header = inspectImageHeader(previewBytes);
  require(
    withinImageBudget(header.width, header.height),
    'معاينة OCR تتجاوز حد المعالجة الآمن.',
  );
  if (corners != null) {
    final recipe = CropDraft(
      corners: corners,
    ).toRecipe(header.width, header.height);
    return renderPerspective(
      previewBytes,
      recipe,
      previewLongEdge: maxRecognitionPreviewLongEdge,
    );
  }
  if (region != null) {
    require(
      region.length == 4 &&
          region.every((value) => value.isFinite && value >= 0 && value <= 1) &&
          region[2] > region[0] &&
          region[3] > region[1],
      'منطقة OCR المقاسة غير صالحة.',
    );
    return cropRegionBytes(previewBytes, region);
  }
  return previewBytes;
}
