import 'dart:math' as math;

import 'geometry.dart';
import 'image_adjustments.dart';
import 'image_limits.dart';
import 'validation.dart';

class ImageEditRecipe {
  const ImageEditRecipe(this.geometry, this.adjustments);
  final CropGeometry geometry;
  final ImageAdjustments adjustments;
}

/// Draft corners may temporarily cross during dragging. Only toRecipe() can
/// produce a processing request, and it validates the complete quadrilateral.
class CropDraft {
  CropDraft({
    required List<Point2> corners,
    ImageAdjustments? adjustments,
    this.aspectRatio,
    this.preservedGeometry,
  }) : corners = List.unmodifiable(corners),
       adjustments = adjustments ?? ImageAdjustments() {
    require(corners.length == 4, 'يجب تحديد أربع زوايا.');
    require(
      preservedGeometry == null ||
          List.generate(
            4,
            (i) =>
                corners[i].x == preservedGeometry!.corners[i].x &&
                corners[i].y == preservedGeometry!.corners[i].y,
          ).every((v) => v),
      'هندسة محفوظة لا تطابق الزوايا.',
    );
    require(
      aspectRatio == null ||
          (aspectRatio!.isFinite && aspectRatio! >= .1 && aspectRatio! <= 10),
      'نسبة الأبعاد غير صالحة.',
    );
  }
  factory CropDraft.fullImage() => CropDraft(
    corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
  );
  final List<Point2> corners;
  final ImageAdjustments adjustments;
  final double? aspectRatio;
  final CropGeometry? preservedGeometry;

  CropDraft withCorner(int index, Point2 point) {
    require(index >= 0 && index < 4, 'رقم زاوية غير صالح.');
    final next = [...corners]..[index] = point;
    return CropDraft(
      corners: next,
      adjustments: adjustments,
      aspectRatio: aspectRatio,
    );
  }

  CropDraft withAdjustments(ImageAdjustments value) => CropDraft(
    corners: corners,
    adjustments: value,
    aspectRatio: aspectRatio,
    preservedGeometry: preservedGeometry,
  );

  ImageEditRecipe toRecipe(int sourceWidth, int sourceHeight) {
    require(
      withinImageBudget(sourceWidth, sourceHeight),
      'أبعاد المصدر غير صالحة.',
    );
    if (preservedGeometry != null) {
      return ImageEditRecipe(preservedGeometry!, adjustments);
    }
    double distance(Point2 a, Point2 b) => math.sqrt(
      math.pow((a.x - b.x) * (sourceWidth - 1), 2) +
          math.pow((a.y - b.y) * (sourceHeight - 1), 2),
    );
    // Estimated pixel dimensions, not inferred physical document dimensions.
    var width =
        ((distance(corners[0], corners[1]) + distance(corners[3], corners[2])) /
            2 +
        1);
    var height =
        ((distance(corners[0], corners[3]) + distance(corners[1], corners[2])) /
            2 +
        1);
    if (aspectRatio != null) {
      // Fit the requested ratio without inventing resolution above the estimate.
      if (width / height > aspectRatio!) {
        width = height * aspectRatio!;
      } else {
        height = width / aspectRatio!;
      }
    }
    require(width.isFinite && height.isFinite, 'أبعاد القص غير صالحة.');
    final scale = math.min(1.0, math.sqrt(maxImportPixels / (width * height)));
    final geometry = CropGeometry(
      corners: corners,
      outputWidth: math.max(1, (width * scale).floor()),
      outputHeight: math.max(1, (height * scale).floor()),
    );
    return ImageEditRecipe(geometry, adjustments);
  }
}
