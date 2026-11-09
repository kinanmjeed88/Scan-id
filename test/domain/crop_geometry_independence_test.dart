import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';

void main() {
  test(
    'saved geometry is preserved until corners change, not an implicit aspect lock',
    () {
      final corners = [
        Point2(.1, .1),
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
      ];
      final saved = CropGeometry(
        corners: corners,
        outputWidth: 40,
        outputHeight: 64,
      );
      final draft = CropDraft(corners: corners, preservedGeometry: saved);
      expect(draft.toRecipe(400, 250).geometry, same(saved));
      final edited = draft.withCorner(0, Point2(.11, .1));
      final measured = CropDraft(
        corners: edited.corners,
      ).toRecipe(400, 250).geometry;
      final geometry = edited.toRecipe(400, 250).geometry;
      expect(geometry.outputWidth, measured.outputWidth);
      expect(geometry.outputHeight, measured.outputHeight);
      expect(geometry.outputWidth / geometry.outputHeight, greaterThan(1));
      expect(edited.aspectRatio, isNull);
    },
  );
}
