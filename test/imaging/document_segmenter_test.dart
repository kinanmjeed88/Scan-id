import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/imaging/document_segmenter.dart';

img.Image _background(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(45, 55, 70));
  return image;
}

void _card(img.Image image, int x1, int y1, int x2, int y2) {
  img.fillRect(
    image,
    x1: x1,
    y1: y1,
    x2: x2,
    y2: y2,
    color: img.ColorRgb8(235, 233, 228),
  );
}

void main() {
  test('two separated cards segment into two corner candidates', () {
    final image = _background(900, 700);
    _card(image, 60, 60, 420, 290); // top card ≈ ID-1 shape
    _card(image, 60, 400, 420, 630); // bottom card
    final result = segmentDecoded(image);
    expect(result.multi, isTrue);
    final quads = result.candidates.where((c) => c.corners != null).toList();
    expect(quads, hasLength(2));
    for (final candidate in quads) {
      expect(candidate.corners, hasLength(4));
      expect(candidate.detectionConfidence, isNotNull);
      expect(candidate.detectionConfidence, lessThanOrEqualTo(.9));
      for (final p in candidate.corners!) {
        expect(p.x, inInclusiveRange(0, 1));
        expect(p.y, inInclusiveRange(0, 1));
      }
    }
    // Deterministic top-to-bottom order: first candidate is the top card.
    final first = result.candidates.first;
    final second = result.candidates[1];
    expect(first.region[1], lessThan(second.region[1]));
    // Mapped corners sit around the drawn rectangles.
    expect(first.corners![0].y, closeTo(60 / 699, .05));
    expect(second.corners![0].y, closeTo(400 / 699, .05));
  });

  test('a single card reports no multi-document structure', () {
    final image = _background(900, 700);
    _card(image, 150, 150, 740, 540);
    final result = segmentDecoded(image);
    expect(result.multi, isFalse);
    expect(
      result.candidates,
      isEmpty,
      reason: 'a resolved singleton stays on the established full-frame path',
    );
  });

  group('multi-document and frame-contact contract', () {
    _multiDocumentContract();
  });

  test('one plausible region with unresolved corners is retained', () {
    final image = _background(900, 700);
    const centerX = 450, centerY = 350, radius = 100;
    for (var y = centerY - radius; y <= centerY + radius; y++) {
      for (var x = centerX - radius; x <= centerX + radius; x++) {
        final dx = x - centerX, dy = y - centerY;
        if (dx * dx + dy * dy <= radius * radius) {
          image.setPixel(x, y, img.ColorRgb8(235, 233, 228));
        }
      }
    }

    final result = segmentDecoded(image);

    expect(result.multi, isFalse);
    expect(result.candidates, hasLength(1));
    expect(result.candidates.single.corners, isNull);
    expect(result.candidates.single.region, isNotEmpty);
  });

  test('a blank image reports no structure at all', () {
    final result = segmentDecoded(_background(600, 400));
    expect(result.multi, isFalse);
    expect(result.candidates, isEmpty);
  });

  test('tiny images are rejected safely', () {
    final result = segmentDecoded(img.Image(width: 20, height: 20));
    expect(result.multi, isFalse);
    expect(result.candidates, isEmpty);
  });

  test('segmentation is deterministic for identical input', () {
    final image = _background(900, 700);
    _card(image, 60, 60, 420, 290);
    _card(image, 460, 380, 830, 610);
    final a = segmentDecoded(image);
    final b = segmentDecoded(image);
    expect(a.multi, b.multi);
    expect(a.candidates.length, b.candidates.length);
    for (var i = 0; i < a.candidates.length; i++) {
      expect(a.candidates[i].region, b.candidates[i].region);
      expect(
        a.candidates[i].detectionConfidence,
        b.candidates[i].detectionConfidence,
      );
    }
  });

  test('bytes entry point decodes and matches the decoded path', () {
    final image = _background(600, 500);
    _card(image, 40, 40, 280, 200);
    _card(image, 40, 280, 280, 440);
    final bytes = img.encodePng(image);
    final fromBytes = segmentDocumentBytes(bytes);
    final fromImage = segmentDecoded(image);
    expect(fromBytes.multi, fromImage.multi);
    expect(fromBytes.candidates.length, fromImage.candidates.length);
  });
}

/// Two cards in ONE photograph must be two documents, and a candidate that runs
/// off the edge of the photo must say so.
///
/// These tests pin the measured contract, not an implementation: what the
/// segmenter reports about region count and frame contact. Synthetic pixels
/// only — no real document image is used anywhere in this suite.
void _multiDocumentContract() {
  // KNOWN LIMITATION, measured and recorded rather than hidden.
  //
  // Two cards that touch or overlap in the photograph are ONE foreground
  // component: their pixels are the same colour and there is no background
  // between them. On the 57-image boundary dataset this is 8 of 49 measurable
  // documents, and an occupancy-valley split of the mask was measured and
  // REJECTED as a fix: it produced 162 regions for 60 (instance precision
  // 0.467 -> 0.136) because a page's own margins and text bands form the same
  // profile as a gap between two cards. Separating them needs a detector that
  // models documents rather than one thresholded mask.
  //
  // The test stays here, skipped, so the day such a detector lands removing the
  // skip is the acceptance check.
  test(
    'two cards touching each other are two regions, not one',
    () {
      final image = _background(900, 700);
      _card(image, 100, 200, 430, 430);
      _card(image, 434, 200, 764, 430);
      final result = segmentDecoded(image);
      for (final candidate in result.candidates) {
        final horizontalSpan = candidate.region[2] - candidate.region[0];
        final coversLeftCard = candidate.region[0] <= 100 / 899;
        final coversRightCard = candidate.region[2] >= 764 / 899;
        expect(
          coversLeftCard && coversRightCard && horizontalSpan > .55,
          isFalse,
          reason:
              'a single region must not enclose two separate cards '
              '(region ${candidate.region})',
        );
      }
    },
    skip: 'known limitation: adjacent cards merge into one region',
  );

  test('a merged two-card component never reports frame contact it lacks', () {
    // A 4 px gap is far narrower than the mask's morphological close, so the
    // two cards form ONE foreground component well inside the frame. Whatever
    // segmenter does with that region, the contact flag must still be a
    // MEASUREMENT of its corners: an interior region is never reported as
    // touching the border, because a false contact flag would send every
    // ordinary card to manual review.
    final image = _background(900, 700);
    _card(image, 100, 200, 430, 430);
    _card(image, 434, 200, 764, 430);
    final result = segmentDecoded(image);
    for (final candidate in result.candidates) {
      expect(
        candidate.touchesFrameEdge,
        isFalse,
        reason: 'the merged region lies inside the photo',
      );
    }
  });

  test('a card cut off by the photo edge is flagged as touching the frame', () {
    final image = _background(900, 700);
    // Reaches the right and bottom edges: the document continues past the
    // picture.
    _card(image, 520, 260, 899, 699);
    final result = segmentDecoded(image);
    final touching = result.candidates.where((c) => c.touchesFrameEdge);
    expect(
      touching.isNotEmpty || result.candidates.isEmpty,
      isTrue,
      reason:
          'either the region is reported with frame contact, or it is refused; '
          'it must never be accepted as complete',
    );
    for (final candidate in result.candidates) {
      if (candidate.corners == null) continue;
      if (candidate.touchesFrameEdge) continue;
      for (final p in candidate.corners!) {
        expect(p.x, greaterThan(.016));
        expect(p.x, lessThan(.984));
        expect(p.y, greaterThan(.016));
        expect(p.y, lessThan(.984));
      }
    }
  });

  test('a fully contained card is not flagged as touching the frame', () {
    final image = _background(900, 700);
    _card(image, 150, 150, 740, 540);
    final result = segmentDecoded(image);
    for (final candidate in result.candidates) {
      expect(candidate.touchesFrameEdge, isFalse);
    }
  });
}
