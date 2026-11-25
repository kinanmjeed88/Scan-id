import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/frame_edge_band.dart';
import 'package:scan_id/domain/geometry.dart';

/// Unit tests for the derived frame-edge band. Arithmetic only: no image, no
/// model. The numbers asserted here are the ones the replay script
/// `tool/evidence/run_corner_order_replay.py` prints, so a drift in either
/// direction is visible.

void main() {
  group('quantisation derives one cell per axis', () {
    test('a landscape frame gets a wider band on its shorter axis', () {
      // One heatmap cell is a fixed number of SOURCE pixels, so it is a larger
      // fraction of the shorter axis. Asserting the direction, not just a
      // value, is what makes this test about the physics.
      final band = FrameEdgeBand.quantisation(
        frameWidth: 1200,
        frameHeight: 900,
        inputPixels: 256,
        heatmapCells: 64,
      );
      expect(band.top, greaterThan(band.left));
      expect(band.bottom, band.top);
      expect(band.right, band.left);
    });

    test('a portrait frame is the mirror image of the landscape one', () {
      final landscape = FrameEdgeBand.quantisation(
        frameWidth: 1200,
        frameHeight: 900,
        inputPixels: 256,
        heatmapCells: 64,
      );
      final portrait = FrameEdgeBand.quantisation(
        frameWidth: 900,
        frameHeight: 1200,
        inputPixels: 256,
        heatmapCells: 64,
      );
      expect(portrait.left, closeTo(landscape.top, 1e-12));
      expect(portrait.top, closeTo(landscape.left, 1e-12));
    });

    test('a square frame gets the same band on both axes', () {
      final band = FrameEdgeBand.quantisation(
        frameWidth: 1200,
        frameHeight: 1200,
        inputPixels: 256,
        heatmapCells: 64,
      );
      expect(band.left, closeTo(band.top, 1e-12));
    });

    test('the band scales with the cell size, not with the frame size', () {
      // Twice the frame with the same input and cell count: a cell covers twice
      // as many source pixels, so the FRACTION is unchanged. This is the
      // property a fixed 0.016 constant could never have.
      final small = FrameEdgeBand.quantisation(
        frameWidth: 1200,
        frameHeight: 1200,
        inputPixels: 256,
        heatmapCells: 64,
      );
      final large = FrameEdgeBand.quantisation(
        frameWidth: 2400,
        frameHeight: 2400,
        inputPixels: 256,
        heatmapCells: 64,
      );
      expect(large.left, closeTo(small.left, 0.002));
    });

    test('the band is capped so it can never reach the middle', () {
      final band = FrameEdgeBand.quantisation(
        frameWidth: 40,
        frameHeight: 1200,
        inputPixels: 256,
        heatmapCells: 64,
      );
      expect(band.maximumSide, lessThanOrEqualTo(.05));
    });

    test('unusable inputs fall back to the legacy band, never to zero', () {
      for (final band in [
        FrameEdgeBand.quantisation(
          frameWidth: 1,
          frameHeight: 900,
          inputPixels: 256,
          heatmapCells: 64,
        ),
        FrameEdgeBand.quantisation(
          frameWidth: 1200,
          frameHeight: 900,
          inputPixels: 0,
          heatmapCells: 64,
        ),
        FrameEdgeBand.quantisation(
          frameWidth: 1200,
          frameHeight: 900,
          inputPixels: 256,
          heatmapCells: 0,
        ),
      ]) {
        expect(band.left, FrameEdgeBand.agentlessBand);
        expect(band.top, FrameEdgeBand.agentlessBand);
      }
    });
  });

  group('sidesTouchedBy reports each side on its own', () {
    final band = FrameEdgeBand.quantisation(
      frameWidth: 1200,
      frameHeight: 900,
      inputPixels: 256,
      heatmapCells: 64,
    );

    test('a corner on the left edge reports only the left side', () {
      expect(band.sidesTouchedBy([Point2(.001, .5), Point2(.5, .5)]), {
        FrameEdgeSide.left,
      });
    });

    test('a corner on the right edge reports only the right side', () {
      expect(band.sidesTouchedBy([Point2(.999, .5), Point2(.5, .5)]), {
        FrameEdgeSide.right,
      });
    });

    test('a corner on the top edge reports only the top side', () {
      expect(band.sidesTouchedBy([Point2(.5, .001), Point2(.5, .5)]), {
        FrameEdgeSide.top,
      });
    });

    test('a corner on the bottom edge reports only the bottom side', () {
      expect(band.sidesTouchedBy([Point2(.5, .999), Point2(.5, .5)]), {
        FrameEdgeSide.bottom,
      });
    });

    test('a corner well inside reports no side at all', () {
      expect(band.sidesTouchedBy([Point2(.5, .5), Point2(.4, .6)]), isEmpty);
    });

    test('a corner one cell inside IS reported on both axes', () {
      // The defect this band exists to fix: the previous fixed 0.016 band
      // missed this on the shorter axis of a non-square frame.
      final corner = Point2(1 - band.left, 1 - band.bottom);
      expect(band.sidesTouchedBy([corner]), {
        FrameEdgeSide.right,
        FrameEdgeSide.bottom,
      });
    });

    test('a corner two cells inside is NOT reported', () {
      final corner = Point2(1 - 2 * band.left, 1 - 2 * band.bottom);
      expect(band.sidesTouchedBy([corner]), isEmpty);
    });
  });

  group('the legacy band preserves the old behaviour exactly', () {
    test('it is the historical 1.6 percent on every side', () {
      for (final side in [
        FrameEdgeBand.legacy.left,
        FrameEdgeBand.legacy.top,
        FrameEdgeBand.legacy.right,
        FrameEdgeBand.legacy.bottom,
      ]) {
        expect(side, .016);
      }
    });

    test('a corner the old gate flagged is still flagged', () {
      expect(
        FrameEdgeBand.legacy.sidesTouchedBy([Point2(.986, .14)]),
        contains(FrameEdgeSide.right),
      );
    });
  });
}
