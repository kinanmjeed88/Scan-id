import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/boundary_arbitration.dart';
import 'package:scan_id/imaging/document_detector.dart';

// Refinement runs until it converges instead of stopping after one round.
//
// Measured on the second field photo: both learned models agreed and the crop
// was accepted, but the accepted left side stopped part-way to the card's
// edge and cut a wedge up to 9 px wide off the card. One round had raised the
// measured edge support (0.76 to 0.85) without reaching the edge; further
// rounds kept raising it (0.94, then 1.00) and ended on the edge.
//
// The stopping rules are verified with numbers alone, and those tests are the
// ones that tell the old single round from the converged search. A clean
// synthetic scene then checks that the image path returns the converged
// quadrilateral; it cannot reproduce the print and wear that made one round
// fall short on the photo. No photograph is involved.

QuadEdgeEvidence _support(double value) =>
    QuadEdgeEvidence(meanSupport: value, minSupport: value, score: value);

/// A quad whose left side sits at [left]; only that side ever moves here.
List<Point2> _quad(double left) => [
  Point2(left, .2),
  Point2(.9, .2),
  Point2(.9, .8),
  Point2(left, .8),
];

/// Drives [convergeRefinement] through a scripted series of rounds: round `i`
/// proposes `steps[i]` with support `supports[i]`.
RefinementOutcome _run({
  required List<double> steps,
  required List<double> supports,
  double startSupport = .5,
  bool Function(List<Point2> quad)? allowed,
  List<int>? refineCalls,
}) {
  var round = 0;
  return convergeRefinement(
    start: _quad(.30),
    startEvidence: _support(startSupport),
    refine: (from) {
      refineCalls?.add(round);
      return round < steps.length ? _quad(steps[round]) : null;
    },
    measure: (quad) => _support(supports[round++]),
    allowed: allowed ?? (_) => true,
    // One unit of the normalized frame is 1000 px in these scripts.
    travelPixels: (from, to) => (from.first.x - to.first.x).abs() * 1000,
    cutPixels: (quad) => proposalCutPixels(_quad(.30), quad, 1000, 1000),
  );
}

/// A quad whose left and top sides sit at [left] and [top].
List<Point2> _quadLeftTop(double left, double top) => [
  Point2(left, top),
  Point2(.9, top),
  Point2(.9, .8),
  Point2(left, .8),
];

/// As [_run], with two sides moving: round `i` proposes `steps[i]` as
/// `(left, top)`. The proposal is left .30, top .20, in a 1000 px frame.
RefinementOutcome _runLeftTop({
  required List<(double, double)> steps,
  required List<double> supports,
}) {
  var round = 0;
  final start = _quadLeftTop(.30, .20);
  return convergeRefinement(
    start: start,
    startEvidence: _support(.5),
    refine: (from) => round < steps.length
        ? _quadLeftTop(steps[round].$1, steps[round].$2)
        : null,
    measure: (quad) => _support(supports[round++]),
    allowed: (_) => true,
    travelPixels: (from, to) => refinementTravelPixels(from, to, 1000, 1000),
    cutPixels: (quad) => proposalCutPixels(start, quad, 1000, 1000),
  );
}

void main() {
  group('convergeRefinement', () {
    test('keeps going while the support keeps rising', () {
      final outcome = _run(
        steps: [.28, .26, .24, .22],
        supports: [.76, .85, .94, 1.0],
      );
      expect(outcome.rounds, 4);
      expect(outcome.corners.first.x, .22);
      expect(outcome.evidence.quality, closeTo(1.0, 1e-9));
    });

    test('a single round is what the old behaviour stopped at', () {
      // The same script, cut after one round: the side is still short of
      // where the full search ends. This is the field loss in numbers.
      final outcome = _run(steps: [.28], supports: [.76]);
      expect(outcome.rounds, 1);
      expect(outcome.corners.first.x, .28);
    });

    test('stops at the first round that does not raise the support', () {
      final outcome = _run(
        steps: [.28, .26, .24, .22],
        supports: [.76, .85, .85, 1.0],
      );
      expect(outcome.rounds, 2);
      expect(outcome.corners.first.x, .26);
      expect(outcome.evidence.quality, closeTo(.85, 1e-9));
    });

    test('a later round that only ties is refused, the first may tie', () {
      // First round: adopted when not worse than the proposal (unchanged).
      final tieFirst = _run(steps: [.28], supports: [.5]);
      expect(tieFirst.rounds, 1);
      // Later rounds: saturated support cannot keep the search drifting.
      final saturated = _run(steps: [.28, .26, .24], supports: [1.0, 1.0, 1.0]);
      expect(saturated.rounds, 1);
      expect(saturated.corners.first.x, .28);
    });

    test('a first round with worse support leaves the proposal untouched', () {
      final outcome = _run(steps: [.28], supports: [.4]);
      expect(outcome.rounds, 0);
      expect(outcome.corners.first.x, .30);
      expect(outcome.evidence.quality, closeTo(.5, 1e-9));
    });

    test('a later round that gives up area is refused, support or not', () {
      // Continued refinement exists to stop cutting the document. A round
      // that shrinks the quad is heading for an inner edge: measured on a
      // laminated card, such rounds kept raising the support while walking
      // 9 px into the laminate.
      final outcome = _run(steps: [.28, .31, .26], supports: [.76, .9, .95]);
      expect(outcome.rounds, 1);
      expect(outcome.corners.first.x, .28);
      expect(outcome.evidence.quality, closeTo(.76, 1e-9));
    });

    test('the first round may still move either way, as it always could', () {
      final inward = _run(steps: [.32], supports: [.6]);
      expect(inward.rounds, 1);
      expect(inward.corners.first.x, .32);
    });

    test('a refused round ends the search on the last adopted quad', () {
      // The guards answer to the original proposal: here anything left of
      // .25 is beyond the displacement cap.
      final outcome = _run(
        steps: [.28, .26, .24, .22],
        supports: [.76, .85, .94, 1.0],
        allowed: (quad) => quad.first.x >= .25,
      );
      expect(outcome.rounds, 2);
      expect(outcome.corners.first.x, .26);
    });

    test('a refused first round is not adopted either', () {
      final outcome = _run(
        steps: [.28],
        supports: [.99],
        allowed: (_) => false,
      );
      expect(outcome.rounds, 0);
      expect(outcome.corners.first.x, .30);
    });

    test('an unrefinable or unmeasurable round ends the search', () {
      final unrefinable = _run(steps: [.28], supports: [.76, .85]);
      expect(unrefinable.rounds, 1);
      final unmeasurable = convergeRefinement(
        start: _quad(.30),
        startEvidence: _support(.5),
        refine: (_) => _quad(.28),
        measure: (_) => null,
        allowed: (_) => true,
        travelPixels: (_, _) => 10,
        cutPixels: (_) => const [0, 0, 0, 0],
      );
      expect(unmeasurable.rounds, 0);
    });

    test('a round that barely moves is adopted and ends the search', () {
      final calls = <int>[];
      final outcome = _run(
        // 0.0004 of the frame is 0.4 px here, under the half-pixel tolerance.
        steps: [.2996, .2990],
        supports: [.76, .85],
        refineCalls: calls,
      );
      expect(outcome.rounds, 1);
      expect(calls, hasLength(1));
    });

    test('the work is bounded even when every round improves', () {
      final calls = <int>[];
      final outcome = _run(
        steps: [for (var i = 1; i <= 20; i++) .30 - i * .005],
        supports: [for (var i = 1; i <= 20; i++) .5 + i * .02],
        refineCalls: calls,
      );
      expect(outcome.rounds, maxRefinementRounds);
      expect(calls, hasLength(maxRefinementRounds));
    });
  });

  group('a later round may not cut deeper into the proposal', () {
    // The area rule cannot see this on its own: one side walks outward far
    // enough that the quad grows while another side walks INTO the proposal.
    // Measured on synthetic scenes with known ground truth, such rounds made
    // the cut up to 9.8 px worse than the single round had left it.

    test('area grows, support rises, and a side still walks in: refused', () {
      final outcome = _runLeftTop(
        // Round 2: left side 60 px further out, top side 10 px further in.
        steps: [(.28, .20), (.22, .21)],
        supports: [.76, .9],
      );
      expect(outcome.rounds, 1);
      expect(outcome.corners.first.x, .28);
      expect(outcome.corners.first.y, .20);
      expect(outcome.evidence.quality, closeTo(.76, 1e-9));
    });

    test('control: the same round without the inward step is adopted', () {
      final outcome = _runLeftTop(
        steps: [(.28, .20), (.22, .20)],
        supports: [.76, .9],
      );
      expect(outcome.rounds, 2);
      expect(outcome.corners.first.x, .22);
    });

    test('a step within the half-pixel tolerance is not a cut', () {
      final outcome = _runLeftTop(
        // 0.0004 of the frame is 0.4 px.
        steps: [(.28, .20), (.22, .2004)],
        supports: [.76, .9],
      );
      expect(outcome.rounds, 2);
      expect(outcome.corners.first.y, .2004);
    });

    test('a step just over the tolerance is', () {
      final outcome = _runLeftTop(
        // 0.0006 of the frame is 0.6 px.
        steps: [(.28, .20), (.22, .2006)],
        supports: [.76, .9],
      );
      expect(outcome.rounds, 1);
      expect(outcome.corners.first.y, .20);
    });

    test('what the first round trimmed is the baseline, not a fault', () {
      // The first round keeps its long-standing freedom and trims the top by
      // 5 px. Later rounds are held to that depth, not to zero.
      final outcome = _runLeftTop(
        steps: [(.28, .205), (.25, .205), (.22, .2053)],
        supports: [.76, .85, .9],
      );
      expect(outcome.rounds, 3);
      expect(outcome.corners.first.x, .22);
      expect(outcome.corners.first.y, .2053);
    });

    test('the tolerance is measured from the first round, so small steps '
        'cannot add up', () {
      // Each round moves the top 0.4 px further in: within tolerance of the
      // round before it, but the second such step is 0.8 px past the first
      // round's depth.
      final outcome = _runLeftTop(
        steps: [(.28, .20), (.26, .2004), (.24, .2008)],
        supports: [.76, .85, .9],
      );
      expect(outcome.rounds, 2);
      expect(outcome.corners.first.y, .2004);
    });

    test('each corner answers for itself: releasing one does not pay for '
        'cutting another', () {
      // Scripted depths, in px, for the four corners of the proposal.
      var round = 0;
      final cuts = [
        [5.0, 0.0, 0.0, 0.0], // first round: one corner trimmed by 5 px
        [0.0, 0.0, 3.0, 0.0], // later: that corner released, another cut 3 px
      ];
      final outcome = convergeRefinement(
        start: _quad(.30),
        startEvidence: _support(.5),
        refine: (from) => _quad(.28 - round * .02),
        measure: (quad) => _support(.76 + round * .1),
        allowed: (_) => true,
        travelPixels: (_, _) => 20,
        cutPixels: (_) => cuts[round++],
      );
      // The deepest cut fell from 5 px to 3 px, and the round is refused all
      // the same: the corner now cut was whole after the first round.
      expect(outcome.rounds, 1);
      expect(outcome.corners.first.x, .28);
    });

    test('a depth that cannot be measured is treated as a cut', () {
      var round = 0;
      final cuts = [
        [0.0, 0.0, 0.0, 0.0],
        [double.nan, 0.0, 0.0, 0.0],
      ];
      final outcome = convergeRefinement(
        start: _quad(.30),
        startEvidence: _support(.5),
        refine: (from) => _quad(.28 - round * .02),
        measure: (quad) => _support(.76 + round * .1),
        allowed: (_) => true,
        travelPixels: (_, _) => 20,
        cutPixels: (_) => cuts[round++],
      );
      expect(outcome.rounds, 1);
    });

    test('the first round is not held to this rule', () {
      // Unchanged: the first round is adopted when its support is not worse,
      // whichever way it moved.
      final outcome = _runLeftTop(steps: [(.31, .22)], supports: [.6]);
      expect(outcome.rounds, 1);
      expect(outcome.corners.first.x, .31);
      expect(outcome.corners.first.y, .22);
    });
  });

  group('proposalCutPixels', () {
    final proposal = _quadLeftTop(.30, .20);

    test('a quad that contains the proposal cuts nothing', () {
      expect(
        proposalCutPixels(proposal, _quadLeftTop(.25, .15), 1000, 1000),
        everyElement(0),
      );
      expect(
        proposalCutPixels(proposal, proposal, 1000, 1000),
        everyElement(closeTo(0, 1e-9)),
      );
    });

    test('a side moved inward cuts the corners on that side, by that much', () {
      final cut = proposalCutPixels(
        proposal,
        _quadLeftTop(.31, .20),
        1000,
        1000,
      );
      // Corners 0 and 3 are the left side of the proposal.
      expect(cut[0], closeTo(10, 1e-6));
      expect(cut[3], closeTo(10, 1e-6));
      expect(cut[1], closeTo(0, 1e-9));
      expect(cut[2], closeTo(0, 1e-9));
    });

    test('a corner outside two sides reports the deeper of the two', () {
      final cut = proposalCutPixels(
        proposal,
        _quadLeftTop(.31, .23),
        1000,
        1000,
      );
      expect(cut[0], closeTo(30, 1e-6)); // 10 px left of it, 30 px above it
      expect(cut[1], closeTo(30, 1e-6));
      expect(cut[3], closeTo(10, 1e-6));
      expect(cut[2], closeTo(0, 1e-9));
    });

    test('pixels follow the frame, not the unit square', () {
      final cut = proposalCutPixels(proposal, _quadLeftTop(.31, .21), 400, 200);
      expect(cut[3], closeTo(4, 1e-6)); // .01 of 400 px wide
      expect(cut[1], closeTo(2, 1e-6)); // .01 of 200 px high
    });

    test('the winding of the quad does not change the answer', () {
      final quad = _quadLeftTop(.31, .23);
      expect(proposalCutPixels(proposal, quad.reversed.toList(), 1000, 1000), [
        for (final value in proposalCutPixels(proposal, quad, 1000, 1000))
          closeTo(value, 1e-9),
      ]);
    });

    test('a tilted side is measured across the side, not along an axis', () {
      // The quad's left side runs from (300, 200) to (340, 800): the bottom
      // left corner of the proposal, (300, 800), is 40 px to its left along
      // the row and a little less across the side.
      final tilted = [
        Point2(.30, .20),
        Point2(.90, .20),
        Point2(.90, .80),
        Point2(.34, .80),
      ];
      final cut = proposalCutPixels(proposal, tilted, 1000, 1000);
      final across = 40 * 600 / math.sqrt(600 * 600 + 40 * 40);
      expect(cut[3], closeTo(across, 1e-6));
      expect(cut[0], closeTo(0, 1e-9));
    });

    test('something that is not a quad cuts everything', () {
      expect(
        proposalCutPixels(proposal, proposal.sublist(0, 3), 1000, 1000),
        everyElement(double.infinity),
      );
    });
  });

  group('the image path', () {
    const width = 400, height = 300;
    // A light card on a dark table; its left edge leans.
    const card = [(64.0, 60.0), (340.0, 52.0), (350.0, 240.0), (40.0, 246.0)];

    Uint8List scene() {
      final image = img.Image(width: width, height: height);
      img.fill(image, color: img.ColorRgb8(34, 36, 40));
      img.fillPolygon(
        image,
        vertices: [for (final (x, y) in card) img.Point(x, y)],
        color: img.ColorRgb8(232, 230, 226),
      );
      return Uint8List.fromList(img.encodePng(image));
    }

    List<double> encode(List<(double, double)> px) => [
      for (final (x, _) in px) x / (width - 1),
      for (final (_, y) in px) y / (height - 1),
    ];

    double worstPixels(List<Point2> quad, List<(double, double)> px) {
      var worst = 0.0;
      for (var i = 0; i < 4; i++) {
        final dx = quad[i].x * (width - 1) - px[i].$1;
        final dy = quad[i].y * (height - 1) - px[i].$2;
        worst = math.max(worst, math.sqrt(dx * dx + dy * dy));
      }
      return worst;
    }

    test('a side proposed inside the card ends on the card edge', () {
      // The proposal's left side is nearly upright: 1 px inside at the top
      // and 12 px inside at the bottom, the shape of the field loss.
      const proposal = [
        (65.0, 60.0),
        (340.0, 52.0),
        (350.0, 240.0),
        (52.0, 246.0),
      ];
      final measured = measureBoundaryCandidates(scene(), encode(proposal));
      final learned = measured.learned!;
      expect(learned.wasRefined, isTrue);
      expect(worstPixels(learned.corners, card), lessThan(2.0));
      expect(worstPixels(learned.originalCorners, proposal), lessThan(1e-6));
      expect(learned.evidence.looksLikeBoundary, isTrue);
    });

    test('a proposal already on the edge stays there', () {
      final measured = measureBoundaryCandidates(scene(), encode(card));
      expect(worstPixels(measured.learned!.corners, card), lessThan(2.0));
    });

    test('the result never leaves the displacement cap of the proposal', () {
      // 40 px inside is beyond 4% of the diagonal (20 px): whatever the
      // search finds, it may not travel further than the cap allows.
      const far = [(104.0, 60.0), (340.0, 52.0), (350.0, 240.0), (80.0, 246.0)];
      final learned = measureBoundaryCandidates(scene(), encode(far)).learned!;
      expect(
        boundaryDisagreement(
          learned.originalCorners,
          learned.corners,
          width,
          height,
        ),
        lessThanOrEqualTo(maxRefinementDisplacement),
      );
    });
  });

  group('the limits this change did not move', () {
    test('acceptance and safety constants keep their values', () {
      expect(frameTouchTolerance, .016);
      expect(minPlausibleAreaFraction, .05);
      expect(measuredQualityMargin, .10);
      expect(boundaryAgreementTolerance, .04);
      expect(maxRefinementDisplacement, .04);
    });

    test('the search bounds are the documented ones', () {
      expect(maxRefinementRounds, 6);
      expect(refinementConvergencePixels, .5);
    });
  });
}
