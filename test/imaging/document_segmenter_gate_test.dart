/// Candidate-quality gates on measured foreground regions.
///
/// Every geometry asserted here was measured on these exact fixtures through a
/// port of this segmenter's own arithmetic — the same Otsu binning, the same
/// 360 px working frame with `Interpolation.average`, the same 2 px border
/// median, the same 8 % region margin and the same `.round()` semantics —
/// before the assertion was written, so the numbers are evidence rather than
/// expectation. Measured on the fixtures in this file:
///
///   genuine documents   aspect 1.26 .. 5.36   border sides 0   crop ≥ 139
///   background strips   aspect 12.00 .. 22.50  border sides 0 .. 3
///
/// The genuine maximum, 5.36, IS the ration-card proportion (287 / 52 = 5.52
/// catalogued), which is why [maxPlausibleRegionAspect] is 8.0 and not lower: a
/// dark strip drawn to the ration card's own catalogued proportion measures
/// 5.62 against the genuine card's 5.49, and both are accepted, so any bound
/// tight enough to refuse that strip also refuses the real document. Such a
/// region is ambiguous, not invalid, and is left to the caller's review path.
///
/// The gates use no ink, colour or texture measure. A genuine document can be
/// faded, low-resolution, washed out or mostly blank, and content-based filters
/// cannot tell one from a solid artifact: measured on these fixtures, internal
/// structure is 0.000 for BOTH a genuine low-contrast card and a solid dark
/// strip, because both are uniform, so no separating threshold exists. Such a
/// filter is therefore deliberately not used here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/imaging/document_segmenter.dart';

final _paper = img.ColorRgb8(240, 238, 230);
final _paper2 = img.ColorRgb8(232, 230, 222);
final _dark = img.ColorRgb8(14, 14, 16);

img.Image _canvas(int width, int height, img.ColorRgb8 background) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: background);
  return image;
}

void _rect(
  img.Image image,
  int x1,
  int y1,
  int x2,
  int y2,
  img.ColorRgb8 color,
) => img.fillRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: color);

/// Two cards on a mid-tone desk: measured aspect 1.59 and 2.13, no border
/// contact, 469 and 460 px short sides. The baseline a photo must keep.
img.Image _twoCards() {
  final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
  _rect(image, 150, 180, 800, 590, _paper);
  _rect(image, 200, 900, 1050, 1300, _paper2);
  return image;
}

RejectedRegion _only(SegmentationResult result) {
  expect(result.rejected, hasLength(1), reason: '$result');
  return result.rejected.single;
}

void main() {
  group('invalid artifacts are refused with a typed reason', () {
    test('a narrow dark strip beside two cards is not a document', () {
      final image = _twoCards();
      // Measured: aspect 12.46, no border contact, 90 px short side, fill 1.00.
      _rect(image, 40, 700, 96, 1420, _dark);
      final result = segmentDecoded(image);

      final rejected = _only(result);
      expect(rejected.rejection, RegionRejection.implausibleAspect);
      expect(rejected.aspect, greaterThan(maxPlausibleRegionAspect));
      expect(rejected.borderSides, 0);
      expect(rejected.fill, greaterThan(.99), reason: 'a solid strip');
      expect(rejected.region, hasLength(4));
      // Both real cards survive; the strip never becomes a candidate.
      expect(result.candidates, hasLength(2));
      expect(result.multi, isTrue);
    });

    test('a wide short strip along a table edge is not a document', () {
      final image = _twoCards();
      // Measured: aspect 12.00, 104 px short side.
      _rect(image, 200, 1450, 1050, 1520, _dark);
      final result = segmentDecoded(image);

      expect(_only(result).rejection, RegionRejection.implausibleAspect);
      expect(result.candidates, hasLength(2));
      expect(result.multi, isTrue);
    });

    test('frame-edge bands are refused, not segmented as documents', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(196, 194, 188));
      // A heavy vignette on the top and left edges. It does something worse
      // than add a region: the background is estimated from the 2 px border
      // band, which is ALL vignette here, so the estimate becomes the vignette
      // colour (measured (14, 14, 16)) and the rest of the photo — canvas and
      // both cards together — measures as ONE foreground component. Measured:
      // sides 2, area fraction 0.874, aspect 1.36, fill 0.999, and exactly one
      // component in the whole frame. No aspect bound could catch that, and no
      // ink measure would either; only the frame-edge test does.
      _rect(image, 0, 0, 1200, 90, _dark);
      _rect(image, 0, 0, 90, 1600, _dark);
      _rect(image, 250, 400, 950, 840, _paper);
      _rect(image, 250, 1000, 950, 1440, _paper2);
      final result = segmentDecoded(image);

      final rejected = _only(result);
      expect(rejected.rejection, RegionRejection.frameArtifact);
      expect(rejected.borderSides, greaterThanOrEqualTo(2));
      expect(rejected.aspect, lessThan(maxPlausibleRegionAspect));
      expect(rejected.fill, greaterThan(.99));
      // Nothing plausible is left, so the caller falls back to the precise
      // single-document detector — and the refusal is still reported. Before
      // the gate this frame-sized region was a perfectly ordinary-looking
      // candidate: solid, well proportioned and 87 % of the photograph.
      expect(result.candidates, isEmpty);
      expect(result.multi, isFalse);
    });

    test('a region the photo cut in half is refused', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(70, 72, 78));
      _rect(image, 250, 250, 950, 690, _paper);
      // Measured: aspect 2.34, touching the right and bottom frame edges —
      // again an ordinary proportion, caught only by the border test.
      _rect(image, 900, 900, 1200, 1600, _paper2);
      final result = segmentDecoded(image);

      final rejected = _only(result);
      expect(rejected.rejection, RegionRejection.frameArtifact);
      expect(rejected.borderSides, 2);
      expect(rejected.aspect, lessThan(maxPlausibleRegionAspect));
      // One plausible region is left, which is the single-document path's job:
      // the whole card is handed to the precise detector, never dropped, and
      // the cut-off fragment never becomes a second document.
      expect(result.candidates, isEmpty);
      expect(result.multi, isFalse);
    });

    test('a bright sliver along one side is refused', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(96, 98, 104));
      _rect(image, 200, 300, 900, 740, _paper);
      _rect(image, 200, 900, 900, 1340, _paper2);
      // A sheet of paper just outside the frame: measured 3 border sides and
      // aspect 22.50. The border test is the more specific reason, so it is
      // reported first even though the aspect bound would also refuse it.
      _rect(image, 1130, 0, 1200, 1600, img.ColorRgb8(250, 249, 246));
      final result = segmentDecoded(image);

      final rejected = _only(result);
      expect(rejected.rejection, RegionRejection.frameArtifact);
      expect(rejected.borderSides, 3);
      expect(rejected.aspect, greaterThan(maxPlausibleRegionAspect));
      expect(result.candidates, hasLength(2));
    });

    test('a region too small to crop is refused instead of emitted', () {
      final image = _canvas(200, 200, img.ColorRgb8(128, 122, 116));
      _rect(image, 20, 20, 170, 110, _paper);
      // Measured: a 43x43 crop, below the 48 px floor. This source is only
      // 200 px across, which is what makes the floor reachable at all — with
      // the editor's 1200 px preview a region that clears the segmenter's own
      // 10 px box floor already crops to about 60 px.
      _rect(image, 60, 150, 94, 184, _dark);
      final result = segmentDecoded(image);

      final rejected = _only(result);
      expect(rejected.rejection, RegionRejection.unusableCrop);
      expect(rejected.cropWidth, lessThan(minUsableRegionCropPx));
      expect(rejected.cropHeight, lessThan(minUsableRegionCropPx));
      // A too-small region used to be emitted as a `region-too-small`
      // candidate that the intake went on to turn into a derived file, a
      // document record and an editor item. It is refused before that.
      expect(
        result.candidates.where((c) => c.reason == 'region-too-small'),
        isEmpty,
      );
      expect(result.candidates, isEmpty);
    });
  });

  group('genuine documents are never refused', () {
    test('the ration-card proportion is inside the aspect bound', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
      _rect(image, 150, 180, 800, 590, _paper);
      // Measured aspect 5.36 (source 1001x186, ratio 5.38) — the most extreme
      // proportion any catalogued document has, and the reason the bound cannot
      // be tightened. This is the guard against tuning the bound to make one
      // artifact disappear.
      _rect(image, 100, 700, 1100, 885, _paper2);
      final result = segmentDecoded(image);

      expect(result.rejected, isEmpty, reason: '$result');
      expect(result.candidates, hasLength(2));
      expect(result.multi, isTrue);
    });

    test('rotated cards survive', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(52, 50, 48));
      _rect(image, 120, 200, 760, 600, _paper);
      _rect(image, 120, 950, 760, 1350, _paper2);
      // Rotating the whole canvas is what a handheld photo does, and it moves
      // every measurement the gates use: `img.copyRotate` EXPANDS the canvas
      // (to 1635x1892 here) and leaves the new corners unset, i.e. black, so
      // the 2 px border median estimates the background as (0, 0, 0). The desk
      // at (52, 50, 48) is then only 150 from that estimate while the cards are
      // about 708, so the measured Otsu threshold of 379 keeps the two cards
      // alone. Measured at -18 degrees each card is aspect 1.26 with fill 0.61
      // — an axis-aligned box around a tilted rectangle — and touches no frame
      // edge, so both survive on their measurements rather than by luck.
      final result = segmentDecoded(img.copyRotate(image, angle: -18));

      expect(result.rejected, isEmpty, reason: '$result');
      expect(result.candidates, hasLength(2));
      expect(result.multi, isTrue);
    });

    test('a document touching ONE frame edge is not frame furniture', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
      // A card lying flush against the left edge of the photograph: measured
      // sides 1, aspect 1.57, 442 px short side. This is why the frame test
      // needs TWO edges — one edge is an ordinary photograph of a document that
      // happened to be near the border, and refusing it would lose a real
      // document. Only a region reaching two edges is the frame itself, a
      // vignette, or a document the photo cut in half.
      _rect(image, 0, 400, 600, 780, _paper);
      _rect(image, 700, 1000, 1150, 1350, _paper2);
      final result = segmentDecoded(image);

      expect(result.rejected, isEmpty, reason: '$result');
      expect(result.candidates, hasLength(2));
      expect(result.multi, isTrue);
    });

    test('low-contrast and washed-out cards survive', () {
      final lowContrast = _canvas(1200, 1600, img.ColorRgb8(120, 118, 114));
      _rect(lowContrast, 150, 200, 780, 600, img.ColorRgb8(150, 149, 146));
      _rect(lowContrast, 150, 900, 780, 1300, img.ColorRgb8(148, 147, 145));
      final faded = segmentDecoded(lowContrast);
      expect(faded.rejected, isEmpty, reason: '$faded');
      expect(faded.candidates, hasLength(2));

      final washed = _canvas(1200, 1600, img.ColorRgb8(170, 168, 164));
      _rect(washed, 150, 200, 1000, 740, img.ColorRgb8(214, 213, 210));
      _rect(washed, 150, 900, 1000, 1440, img.ColorRgb8(210, 209, 207));
      final pale = segmentDecoded(washed);
      expect(pale.rejected, isEmpty, reason: '$pale');
      expect(pale.candidates, hasLength(2));
    });

    test('a small distant document survives', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(52, 50, 48));
      _rect(image, 120, 200, 900, 700, _paper);
      // Measured: aspect 1.49, 215 px short side, area fraction 0.0257 — just
      // above the segmenter's own 1.5 % support floor and 4.5x the usable-crop
      // bound, so a document photographed from further away is still kept.
      _rect(image, 900, 1000, 1170, 1180, _paper2);
      final result = segmentDecoded(image);

      expect(result.rejected, isEmpty, reason: '$result');
      expect(result.candidates, hasLength(2));
    });

    test('three documents on a textured surface all survive', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(46, 42, 40));
      for (var y = 0; y < 1600; y += 3) {
        _rect(image, 0, y, 1200, y, img.ColorRgb8(52, 47, 44));
      }
      _rect(image, 130, 160, 760, 556, _paper);
      _rect(image, 800, 200, 1120, 700, _paper2);
      _rect(image, 180, 1000, 900, 1452, img.ColorRgb8(242, 240, 232));
      final result = segmentDecoded(image);

      expect(result.rejected, isEmpty, reason: '$result');
      expect(result.candidates, hasLength(3));
      expect(result.multi, isTrue);
    });
  });

  group('a rejection is a decision, never a mutation', () {
    test('the source pixels are unchanged and the bytes path agrees', () {
      final image = _twoCards();
      _rect(image, 40, 700, 96, 1420, _dark);
      final before = img.encodePng(image);

      final fromImage = segmentDecoded(image);
      expect(
        img.encodePng(image),
        before,
        reason: 'segmentation must be read-only (ADR-003)',
      );

      final fromBytes = segmentDocumentBytes(before);
      expect(fromBytes.rejected, hasLength(fromImage.rejected.length));
      expect(
        fromBytes.rejected.single.rejection,
        fromImage.rejected.single.rejection,
      );
      expect(fromBytes.candidates, hasLength(fromImage.candidates.length));
    });

    test('the candidate cap refuses the excess, keeping the largest', () {
      final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
      // Fourteen separated cards of strictly decreasing area (measured area
      // fraction 0.0397 down to 0.0200, aspect 2.54 .. 4.95, no border
      // contact): more than maxSegmentCandidates, so the cap fires and the two
      // smallest are reported rather than silently dropped.
      for (var i = 0; i < 14; i++) {
        final column = i % 2;
        final row = i ~/ 2;
        final height = 170 - i * 6;
        final left = column == 0 ? 100 : 660;
        final top = 90 + row * 215;
        _rect(
          image,
          left,
          top,
          left + 440,
          top + height,
          column == 0 ? _paper : _paper2,
        );
      }
      final result = segmentDecoded(image);

      expect(result.rejected, hasLength(2), reason: '${result.rejected}');
      expect(result.candidates.length, lessThanOrEqualTo(maxSegmentCandidates));
      for (final rejected in result.rejected) {
        expect(rejected.rejection, RegionRejection.candidateCap);
      }
      expect(result.candidates, hasLength(maxSegmentCandidates));
      // The cap keeps the regions with the most measured foreground, so a real
      // document is never dropped in favour of a smaller fragment. Here the
      // two smallest are the bottom row (i = 12 and 13), so every dropped
      // region sits strictly below every kept one and carries strictly less
      // foreground area than the smallest survivor.
      final keptTops = result.candidates.map((c) => c.region[1]).toList();
      final keptAreas = result.candidates
          .map((c) => (c.region[2] - c.region[0]) * (c.region[3] - c.region[1]))
          .toList();
      for (final rejected in result.rejected) {
        expect(
          rejected.region[1],
          greaterThan(keptTops.reduce((a, b) => a > b ? a : b)),
        );
        expect(
          (rejected.region[2] - rejected.region[0]) *
              (rejected.region[3] - rejected.region[1]),
          lessThan(keptAreas.reduce((a, b) => a < b ? a : b)),
        );
      }
    });

    test('a clean photo reports no rejections at all', () {
      expect(segmentDecoded(_twoCards()).rejected, isEmpty);
      expect(segmentDecoded(_canvas(600, 400, _dark)).rejected, isEmpty);
      expect(
        segmentDecoded(img.Image(width: 20, height: 20)).rejected,
        isEmpty,
      );
    });
  });
}
