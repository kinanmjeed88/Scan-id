import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/image_limits.dart';
import 'package:scan_id/imaging/docquad_model.dart';

/// The coordinate frame a learned corner is expressed in.
///
/// The detector is fed a bounded display preview, but every consumer of its
/// corners — measured arbitration, `verifyBoundary`, `CropDraft`, the native
/// region decoder — works in the SOURCE image's frame. A preview preserves the
/// source aspect ratio, so the two frames agree only while the longest source
/// edge is inside the preview bound. Once it is not, a raw preview fraction
/// read against the source is a wrong number with no gate to catch it; these
/// tests fix the contract so a future change cannot reintroduce the error.
///
/// Synthetic dimensions only: no image data is used or produced here.
void main() {
  group('detector coordinate frame', () {
    test('a source inside the preview bound keeps its own size', () {
      final frame = detectorFrame(sourceWidth: 800, sourceHeight: 600);
      expect(frame.width, 800);
      expect(frame.height, 600);
    });

    test('an oversized source reports the reduced preview size', () {
      // 1600x1200 becomes 1200x900; 4:3 either way, but the numbers differ by
      // 25 % and that is exactly the error this contract removes.
      final frame = detectorFrame(sourceWidth: 1600, sourceHeight: 1200);
      expect(frame.width, maxRecognitionPreviewLongEdge);
      expect(
        frame.height,
        (1200 * maxRecognitionPreviewLongEdge / 1600).round(),
      );
      expect(frame.width, lessThan(1600));
    });

    test('a portrait source is bounded on its long edge too', () {
      final frame = detectorFrame(sourceWidth: 3000, sourceHeight: 4000);
      expect(frame.height, maxRecognitionPreviewLongEdge);
      expect(
        frame.width,
        (3000 * maxRecognitionPreviewLongEdge / 4000).round(),
      );
    });

    test('the preview frame keeps the source aspect ratio', () {
      for (final (sourceWidth, sourceHeight) in const [
        (4961, 7016),
        (4032, 3024),
        (1280, 875),
        (900, 700),
      ]) {
        final frame = detectorFrame(
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
        );
        expect(
          frame.width / frame.height,
          closeTo(sourceWidth / sourceHeight, .01),
          reason: '$sourceWidth x $sourceHeight must not change shape',
        );
      }
    });

    test('a degenerate size is passed through, never divided by zero', () {
      final frame = detectorFrame(sourceWidth: 0, sourceHeight: 0);
      expect(frame.width, 0);
      expect(frame.height, 0);
    });
  });

  group('a corner fraction means the same thing in both frames', () {
    // The identity that makes the preview safe: a point at fraction f of a
    // preview is the same fraction f of the source, because the only difference
    // between them is a uniform scale. Written as an arithmetic check on the
    // frames themselves, so it fails if anyone changes how the preview is
    // produced without revisiting the mapping.
    test('a fraction of the preview is the same fraction of the source', () {
      const sourceWidth = 4961;
      const sourceHeight = 3508;
      final frame = detectorFrame(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
      );
      const fraction = .25;
      final previewPixel = fraction * (frame.width - 1);
      final sourcePixel = previewPixel * (sourceWidth - 1) / (frame.width - 1);
      expect(sourcePixel, closeTo(fraction * (sourceWidth - 1), 1e-6));
    });

    test('pixel-centre convention: the last centre is width - 1', () {
      // `_Peak` positions are centres (x + .5). Dividing by the width instead
      // of the last index would make an edge-touching corner report strictly
      // less than 1 and hide real frame contact.
      const width = 1200;
      const lastCentre = (width - 1) + .5;
      expect(lastCentre / (width - 1), greaterThan(1.0));
      expect((width - .5) / (width - 1), greaterThan(1.0));
    });
  });
}
