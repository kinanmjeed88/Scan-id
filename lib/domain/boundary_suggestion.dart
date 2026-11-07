/// One place to find and validate the editable 4-corner boundary suggestion
/// that recognition saved for an image.
///
/// A suggestion is a CLAIM, never an approved crop: it lives either on the
/// asset itself (single-document intake) or on a side's `DetectionRef`
/// (smart-recognition intake). Both representations are read here so the crop
/// editor, the classification workflow and the service layer cannot disagree
/// about what was proposed, and so every caller applies the SAME geometric
/// validity gate before offering it to the user.
library;

import 'geometry.dart';
import 'project.dart';
import 'quad_assessment.dart';

/// The saved, unedited suggestion for [asset], or null when none was recorded.
///
/// The ownership test is deliberately path-based, not a comparison with the
/// asset's current working path: a new image revision changes that path while
/// the suggestion still belongs to the same source asset.
List<Point2>? savedSuggestedBoundary(Project project, ImageAsset asset) {
  final direct = asset.suggestedCrop;
  if (direct != null) return direct;
  for (final record in project.documents) {
    for (final side in record.sides) {
      final saved = side.detection?.suggestedPolygon;
      if (saved == null) continue;
      if (assetOwnsProjectPath(
            project.id,
            asset.id,
            side.processedAsset.workingPath,
          ) ||
          (record.sides.length == 1 && record.sourceImageId == asset.id)) {
        return saved;
      }
    }
  }
  return null;
}

/// Why a saved suggestion cannot be applied as a user-approved crop.
enum SuggestionRejection { absent, wrongPointCount, geometry }

class BoundarySuggestion {
  const BoundarySuggestion._(this.corners, this.rejection);

  /// Validated corners, present only when [isUsable].
  final List<Point2>? corners;
  final SuggestionRejection? rejection;

  bool get isUsable => corners != null;
}

/// Validates the saved suggestion against the source it was measured on.
///
/// Geometry validation (`assessQuad`) is the same gate the crop editor uses
/// before displaying handles. Model scores are intentionally NOT consulted:
/// they are uncalibrated routing heuristics, and this function's only job is to
/// decide whether four measured points can be offered as an editable crop.
BoundarySuggestion inspectSuggestedBoundary(
  Project project,
  ImageAsset asset, {
  required int sourceWidth,
  required int sourceHeight,
}) {
  final corners = savedSuggestedBoundary(project, asset);
  if (corners == null) {
    return const BoundarySuggestion._(null, SuggestionRejection.absent);
  }
  if (corners.length != 4) {
    return const BoundarySuggestion._(
      null,
      SuggestionRejection.wrongPointCount,
    );
  }
  final assessment = assessQuad(
    corners,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
  if (!assessment.acceptable) {
    return const BoundarySuggestion._(null, SuggestionRejection.geometry);
  }
  return BoundarySuggestion._(List.unmodifiable(corners), null);
}
