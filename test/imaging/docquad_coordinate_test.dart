import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/docquad_model.dart';

/// Round-trip verification of the learned detector's coordinate mapping.
///
/// Arithmetic on synthetic geometry only — no image data, no model call. It
/// fixes the contract [docQuadCorners] must satisfy: a mis-mapped corner is a
/// plausible rectangle in the wrong place, which every downstream geometry gate
/// (`verifyBoundary`, `assessQuad`, `CropDraft`) accepts, so the error is
/// invisible except to a coordinate test.
typedef Box = ({double scale, double offsetX, double offsetY});

/// Segmenter letterbox, reproducing `DocQuadNet256._letterbox` so the test
/// asserts against the same geometry production uses.
Box letterbox(int sourceWidth, int sourceHeight, {int input = 256}) {
  final scale = math.min(input / sourceWidth, input / sourceHeight);
  return (
    scale: scale,
    offsetX: (input - sourceWidth * scale) / 2,
    offsetY: (input - sourceHeight * scale) / 2,
  );
}

/// The `x256`/`y256` the heatmap would report for a corner resting on a given
/// pixel, i.e. the exact inverse of the production back-mapping. Each axis has
/// its own letterbox offset, and mixing them up is precisely the class of error
/// this file exists to catch.
double x256For(double pixel, Box box) => pixel * box.scale + box.offsetX;
double y256For(double pixel, Box box) => pixel * box.scale + box.offsetY;

List<Point2> map(
  List<(double, double)> pixels,
  Box box, {
  required int frameWidth,
  required int frameHeight,
}) => docQuadCorners(
  [for (final (x, y) in pixels) (x256: x256For(x, box), y256: y256For(y, box))],
  scale: box.scale,
  offsetX: box.offsetX,
  offsetY: box.offsetY,
  frameWidth: frameWidth,
  frameHeight: frameHeight,
);

void main() {
  // One row per requested case: name, frame width, frame height.
  const cases = <(String, int, int)>[
    ('landscape', 1200, 900),
    ('portrait', 900, 1200),
    ('square', 1200, 1200),
    ('unusual aspect', 1200, 275),
    ('tall and narrow', 320, 1200),
    ('small', 64, 48),
    ('minimum side', 40, 40),
    ('one pixel wide', 1, 1200),
    ('one pixel tall', 1200, 1),
  ];

  group('a corner pixel round-trips to itself', () {
    for (final (name, width, height) in cases) {
      test(name, () {
        final box = letterbox(width, height);
        // Both endpoints plus the middle: an off-by-one in the divisor is
        // invisible in the middle and maximal at the far edge.
        Set<double> samples(int extent) => {
          for (final value in <double>[
            0,
            1,
            (extent - 1) / 2,
            extent - 2,
            extent - 1,
          ])
            if (value >= 0 && value <= extent - 1) value,
        };
        final pixels = [
          for (final x in samples(width))
            for (final y in samples(height)) (x, y),
        ];
        final corners = map(
          pixels,
          box,
          frameWidth: width,
          frameHeight: height,
        );

        for (var i = 0; i < pixels.length; i++) {
          final (x, y) = pixels[i];
          // The app multiplies a fraction by (extent - 1) to reach a pixel
          // (assessQuad, warpPerspective): this is that exact inverse.
          expect(
            corners[i].x * math.max(1, width - 1),
            closeTo(x, 1e-9),
            reason: '$name x=$x',
          );
          expect(
            corners[i].y * math.max(1, height - 1),
            closeTo(y, 1e-9),
            reason: '$name y=$y',
          );
        }
      });
    }
  });

  group('the mapping never leaves the frame', () {
    for (final (name, width, height) in cases) {
      test(name, () {
        final box = letterbox(width, height);
        final corners = map(
          [
            (0, 0),
            ((width - 1).toDouble(), 0),
            (0, (height - 1).toDouble()),
            ((width - 1).toDouble(), (height - 1).toDouble()),
          ],
          box,
          frameWidth: width,
          frameHeight: height,
        );
        for (final corner in corners) {
          expect(corner.x, inInclusiveRange(0, 1), reason: name);
          expect(corner.y, inInclusiveRange(0, 1), reason: name);
        }
      });
    }
  });

  group('edge contact is reported as contact', () {
    const width = 1200;
    const height = 900;
    final box = letterbox(width, height);

    test('the mapping round-trips the last pixel to exactly 1', () {
      // Arithmetic property of the mapping, not a reachable model output: the
      // heatmap's last centre is 4*63.5 = 254, four pixels short of the edge.
      final corners = map(
        [(width - 1.0, height - 1.0)],
        box,
        frameWidth: width,
        frameHeight: height,
      );
      expect(corners.single.x, closeTo(1, 1e-9));
      expect(corners.single.y, closeTo(1, 1e-9));
    });

    test('the furthest reachable peak is still inside the clipping band', () {
      // This is the achievable limit: peak index 63 gives x256 = 254. If the
      // divisor were too large, this value would fall below the 1.6 % band and
      // a physically clipped document would be reported as strictly interior.
      final corners = docQuadCorners(
        [(x256: 254, y256: 254)],
        scale: box.scale,
        offsetX: box.offsetX,
        offsetY: box.offsetY,
        frameWidth: width,
        frameHeight: height,
      );
      expect(corners.single.x, closeTo(.99302, 1e-5));
      expect(corners.single.x, greaterThanOrEqualTo(1 - .016));
      expect(corners.single.y, greaterThanOrEqualTo(1 - .016));
    });

    test('a corner a few pixels inside the edge stays off the edge', () {
      final corners = map(
        [(width - 24.0, height - 24.0)],
        box,
        frameWidth: width,
        frameHeight: height,
      );
      expect(corners.single.x * (width - 1), closeTo(width - 24, 1e-9));
      expect(corners.single.y * (height - 1), closeTo(height - 24, 1e-9));
      expect(corners.single.x, lessThan(1 - .016));
    });
  });

  group('a corner fraction means the same thing in both frames', () {
    test('a preview fraction maps to the same source fraction', () {
      // Justification for the bounded preview: the letterbox only differs from
      // the frame by a uniform scale, so a fraction is frame-independent. This
      // fails if the preview ever stops preserving the aspect ratio.
      const source = (4961, 3508);
      const preview = (1200, 849);
      final sourceBox = letterbox(source.$1, source.$2);
      final previewBox = letterbox(preview.$1, preview.$2);
      for (final fraction in [.1, .25, .5, .75, .9]) {
        final px = fraction * (preview.$1 - 1);
        final asSource = px * (source.$1 - 1) / (preview.$1 - 1);
        expect(asSource / (source.$1 - 1), closeTo(fraction, 1e-9));
        // Both letterboxes must describe the same shape.
        expect(
          previewBox.scale * preview.$1,
          closeTo(sourceBox.scale * source.$1, 1e-6),
        );
      }
    });
  });

  group('degenerate frames are refused, never divided by zero', () {
    const degenerate = [(0, 0), (1, 1), (1, 1200), (1200, 0)];
    for (final (width, height) in degenerate) {
      test('${width}x$height stays finite', () {
        final corners = docQuadCorners(
          [(x256: 2, y256: 2)],
          scale: 1,
          offsetX: 0,
          offsetY: 0,
          frameWidth: width,
          frameHeight: height,
        );
        expect(corners.single.x.isFinite, isTrue);
        expect(corners.single.y.isFinite, isTrue);
      });
    }
  });

  group('out-of-frame peaks are surfaced, not silently clamped', () {
    // The mapping itself must not clamp: a peak in the letterbox padding is
    // not a document corner, and hiding it would turn a bad detection into a
    // plausible one. The gate downstream is what rejects it.
    test('a peak inside the padding maps outside [0, 1]', () {
      const width = 1200;
      const height = 900;
      final box = letterbox(width, height);
      // y256 = 0 is inside the top padding band for this aspect ratio.
      final corners = docQuadCorners(
        [(x256: 130, y256: 0)],
        scale: box.scale,
        offsetX: box.offsetX,
        offsetY: box.offsetY,
        frameWidth: width,
        frameHeight: height,
      );
      expect(corners.single.y, lessThan(0));
    });

    test('verifyBoundary rejects those corners as out of bounds', () {
      const width = 1200;
      const height = 900;
      final box = letterbox(width, height);
      final corners = docQuadCorners(
        [
          (x256: 130, y256: 0),
          (x256: 254, y256: 0),
          (x256: 254, y256: 254),
          (x256: 130, y256: 254),
        ],
        scale: box.scale,
        offsetX: box.offsetX,
        offsetY: box.offsetY,
        frameWidth: width,
        frameHeight: height,
      );
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: corners,
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(
        decision.verification.hasUsableGeometry,
        isFalse,
        reason: 'an out-of-frame claim must never authorize a crop',
      );
    });
  });

  group('floating-point overshoot at the edge is snapped, nothing else', () {
    // Dividing by (extent - 1) is the exact inverse of the consumer, but not
    // exact in binary. A scan of every frame up to 1200x1200 found 357,436
    // such (axis, width, height) combinations, always within 1e-9 of 1 — well
    // below one heatmap cell. `normalizedQuadIssue` rejects any coordinate
    // strictly greater than 1, so without snapping these discard the proposal.
    for (final (width, height) in const [(40, 65), (42, 1166), (1200, 275)]) {
      test('${width}x$height reports the last pixel as exactly 1', () {
        final box = letterbox(width, height);
        final corners = map(
          [(width - 1.0, height - 1.0)],
          box,
          frameWidth: width,
          frameHeight: height,
        );
        expect(corners.single.x, lessThanOrEqualTo(1));
        expect(corners.single.y, lessThanOrEqualTo(1));
        expect(corners.single.x, 1);
        expect(corners.single.y, 1);
      });
    }

    test('snapping never rescues a peak that truly sits outside', () {
      const width = 1200;
      const height = 900;
      final box = letterbox(width, height);
      // y256 = 0 is 32 px into the top padding band: a bogus detection.
      final corners = docQuadCorners(
        [(x256: 130, y256: 0)],
        scale: box.scale,
        offsetX: box.offsetX,
        offsetY: box.offsetY,
        frameWidth: width,
        frameHeight: height,
      );
      expect(corners.single.y, closeTo(-.166852, 1e-5));
      expect(
        verifyBoundary(
          BoundaryProposal(
            producer: BoundaryProducer.learnedModel,
            corners: [
              corners.single,
              Point2(.9, corners.single.y),
              Point2(.9, .9),
              Point2(.1, .9),
            ],
          ),
          sourceWidth: width,
          sourceHeight: height,
        ).verification.hasUsableGeometry,
        isFalse,
      );
    });
  });

  test('corners keep the model order and stay normalized Point2', () {
    final corners = docQuadCorners(
      [(x256: 2, y256: 2), (x256: 254, y256: 2), (x256: 254, y256: 254)],
      scale: .2133,
      offsetX: 0,
      offsetY: 0,
      frameWidth: 1200,
      frameHeight: 900,
    );
    expect(corners, hasLength(3));
    expect(corners, everyElement(isA<Point2>()));
    expect(corners[0].x, lessThan(corners[1].x));
    expect(corners[0].y, lessThan(corners[2].y));
  });

  // RC-10: order is a CONTRACT, not a coincidence of one plausible rectangle.
  //
  // The channel order of the four heatmaps decides which corner is which. If
  // the model's channel 0 is not the top-left corner, the returned ring
  // describes a bow-tie or a rotated ring, and a rotated ring of the SAME
  // rectangle is a perfectly plausible rectangle in the WRONG place: every
  // geometry gate accepts it, the crop comes out rotated, and nothing reports a
  // failure. Only asserting the identity of all four corners catches it.
  group('all four corners land in TL, TR, BR, BL order', () {
    const frames = <(String, int, int)>[
      ('landscape', 1200, 900),
      ('portrait', 900, 1200),
      ('square', 1000, 1000),
      ('wide letterbox', 1200, 275),
      ('tall letterbox', 320, 1200),
    ];

    for (final (name, width, height) in frames) {
      test(name, () {
        final box = letterbox(width, height);
        // A document inset from every border on a real-looking frame.
        final source = <(double, double)>[
          (width * .18, height * .15),
          (width * .82, height * .15),
          (width * .82, height * .85),
          (width * .18, height * .85),
        ];
        final corners = map(source, box, frameWidth: width, frameHeight: height);

        expect(corners, hasLength(4));
        // TL then TR: the first edge runs LEFT to RIGHT along the top.
        expect(corners[0].x, lessThan(corners[1].x), reason: '$name TL->TR is rightward');
        expect(corners[0].y, closeTo(corners[1].y, 1e-9), reason: '$name top edge is level');
        // TR then BR: the second edge runs TOP to BOTTOM along the right.
        expect(corners[1].y, lessThan(corners[2].y), reason: '$name TR->BR is downward');
        expect(corners[1].x, closeTo(corners[2].x, 1e-9), reason: '$name right edge is upright');
        // BR then BL: the third edge runs RIGHT to LEFT along the bottom.
        expect(corners[2].x, greaterThan(corners[3].x), reason: '$name BR->BL is leftward');
        expect(corners[2].y, closeTo(corners[3].y, 1e-9), reason: '$name bottom edge is level');
        // BL closes back up to TL.
        expect(corners[3].y, greaterThan(corners[0].y), reason: '$name BL->TL is upward');

        // Screen space is y-down, so a clockwise ring has POSITIVE signed area.
        var twiceArea = 0.0;
        for (var i = 0; i < 4; i++) {
          final a = corners[i];
          final b = corners[(i + 1) % 4];
          twiceArea += a.x * b.y - b.x * a.y;
        }
        expect(twiceArea, greaterThan(0), reason: '$name is clockwise, not inverted');

        // And the ring is a convex quadrilateral, never a bow-tie.
        expect(
          normalizedQuadIssue(corners),
          isNull,
          reason: '$name must be a simple convex ring',
        );

        // The named corners are the corners they claim to be.
        expect(corners[0].x, closeTo(source[0].$1 / (width - 1), 1e-6));
        expect(corners[0].y, closeTo(source[0].$2 / (height - 1), 1e-6));
        expect(corners[2].x, closeTo(source[2].$1 / (width - 1), 1e-6));
        expect(corners[2].y, closeTo(source[2].$2 / (height - 1), 1e-6));
      });
    }

    test('an inverted channel order is rejected, not silently accepted', () {
      // The same rectangle with its ring reversed describes the same document,
      // so the ORDER inside the model is not a safety property of the map. What
      // must never happen is a ring that pairs diagonal corners: that is a
      // bow-tie, and it must fail the geometry gate rather than become a crop.
      const width = 1200;
      const height = 900;
      final box = letterbox(width, height);
      final corners = map(
        [
          (216.0, 135.0),
          (738.0, 765.0),
          (984.0, 135.0),
          (216.0, 765.0),
        ],
        box,
        frameWidth: width,
        frameHeight: height,
      );
      expect(normalizedQuadIssue(corners), isNotNull);
      expect(
        verifyBoundary(
          BoundaryProposal(
            producer: BoundaryProducer.learnedModel,
            corners: corners,
            modelConfidence: .99,
            minAutoAcceptConfidence: .55,
          ),
          sourceWidth: width,
          sourceHeight: height,
        ).verification.hasUsableGeometry,
        isFalse,
      );
    });
  });
}
