import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/presentation/image_viewport.dart';

/// A 4000 × 3000 photograph shown in a 800 × 600 box: the fitted rectangle is the
/// whole viewport, which makes every expected value below readable by hand.
ImageViewport _wide() => ImageViewport(
  viewport: const Size(800, 600),
  imageWidth: 4000,
  imageHeight: 3000,
);

void main() {
  group('fitting the whole photograph', () {
    test('a matching aspect fills the box exactly', () {
      expect(_wide().displayedRect, const Rect.fromLTWH(0, 0, 800, 600));
    });

    test('a taller photograph is letterboxed horizontally and centred', () {
      final tall = ImageViewport(
        viewport: const Size(800, 600),
        imageWidth: 3000,
        imageHeight: 4000,
      );
      final rect = tall.displayedRect;
      expect(rect.height, 600);
      expect(rect.width, closeTo(450, 1e-9));
      expect(rect.left, closeTo(175, 1e-9));
      expect(rect.top, 0);
    });

    test('a wider photograph is letterboxed vertically and centred', () {
      final wide = ImageViewport(
        viewport: const Size(800, 600),
        imageWidth: 4000,
        imageHeight: 1000,
      );
      final rect = wide.displayedRect;
      expect(rect.width, 800);
      expect(rect.height, closeTo(200, 1e-9));
      expect(rect.top, closeTo(200, 1e-9));
    });
  });

  group('coordinate conversion', () {
    test('the four image corners map to the four displayed corners', () {
      final viewport = _wide();
      final rect = viewport.displayedRect;
      expect(viewport.toScreen(Point2(0, 0)), Offset(rect.left, rect.top));
      expect(viewport.toScreen(Point2(1, 0)), Offset(rect.right, rect.top));
      expect(viewport.toScreen(Point2(1, 1)), Offset(rect.right, rect.bottom));
      expect(viewport.toScreen(Point2(0, 1)), Offset(rect.left, rect.bottom));
    });

    test('screen to image is the exact inverse at 1x', () {
      final viewport = _wide();
      for (final point in [
        Point2(.25, .4),
        Point2(.75, .6),
        Point2(.5, .5),
      ]) {
        final back = viewport.toImage(viewport.toScreen(point));
        expect(back.x, closeTo(point.x, 1e-9));
        expect(back.y, closeTo(point.y, 1e-9));
      }
    });

    test('a tap just outside the photograph clamps to its edge, not beyond it', () {
      final viewport = _wide();
      final outside = viewport.toImage(const Offset(-40, 900));
      expect(outside.x, 0);
      expect(outside.y, 1);
    });
  });

  group('zoom', () {
    test('zoom keeps the image point under the focus finger', () {
      final viewport = _wide();
      const focus = Offset(300, 200);
      final before = viewport.toImage(focus);
      final zoomed = viewport.scaledBy(2, focus: focus);
      final after = zoomed.toImage(focus);
      expect(after.x, closeTo(before.x, 1e-9));
      expect(after.y, closeTo(before.y, 1e-9));
      expect(zoomed.scale, 2);
    });

    test('a corner picked at 1x stays on the same document pixel at 3x', () {
      final viewport = _wide();
      final corner = Point2(.3, .7);
      final screenAtOne = viewport.toScreen(corner);
      final zoomed = viewport.scaledBy(3, focus: screenAtOne);
      // The corner is still under the same screen point after zooming onto it.
      expect((zoomed.toScreen(corner) - screenAtOne).distance, closeTo(0, 1e-9));
      // And converting that screen point back yields the original image point.
      final back = zoomed.toImage(screenAtOne);
      expect(back.x, closeTo(corner.x, 1e-9));
      expect(back.y, closeTo(corner.y, 1e-9));
    });

    test('zoom is bounded at both ends', () {
      final viewport = _wide();
      expect(viewport.scaledBy(100).scale, ImageViewport.maxScale);
      expect(viewport.scaledBy(.01).scale, ImageViewport.minScale);
    });

    test('zooming out from a zoomed state returns to the whole photograph', () {
      final zoomed = _wide().scaledBy(4);
      final back = zoomed.scaledBy(.01);
      expect(back.scale, ImageViewport.minScale);
      expect(back.offset, Offset.zero);
      expect(back.displayedRect, const Rect.fromLTWH(0, 0, 800, 600));
    });
  });

  group('pan', () {
    test('an image that fits cannot be panned away', () {
      final viewport = _wide().translatedBy(const Offset(200, 200));
      expect(viewport.offset, Offset.zero);
      expect(viewport.displayedRect, const Rect.fromLTWH(0, 0, 800, 600));
    });

    test('a zoomed image pans, but never loses the photograph entirely', () {
      final zoomed = _wide().scaledBy(2); // 1600 × 1200 displayed
      final panned = zoomed.translatedBy(const Offset(-200000, -200000));
      final rect = panned.displayedRect;
      // The right edge of the photograph may not cross the left of the box.
      expect(rect.right, closeTo(800, 1e-6));
      expect(rect.bottom, closeTo(600, 1e-6));
      final other = zoomed.translatedBy(const Offset(200000, 200000));
      expect(other.displayedRect.left, closeTo(0, 1e-6));
      expect(other.displayedRect.top, closeTo(0, 1e-6));
    });

    test('a pan does not change what a screen point means relative to the photo', () {
      final zoomed = _wide().scaledBy(2);
      final panned = zoomed.translatedBy(const Offset(-100, -50));
      // The same image point must still convert back to itself from its own
      // screen position: panning moves the picture, not the coordinate system.
      final point = Point2(.4, .6);
      final back = panned.toImage(panned.toScreen(point));
      expect(back.x, closeTo(point.x, 1e-9));
      expect(back.y, closeTo(point.y, 1e-9));
    });
  });

  group('screen-space distances', () {
    test('the same two image points are further apart when zoomed in', () {
      final viewport = _wide();
      final a = Point2(.2, .2);
      final b = Point2(.25, .25);
      final atOne = viewport.screenDistance(a, b);
      final atFour = viewport.scaledBy(4).screenDistance(a, b);
      expect(atFour, closeTo(atOne * 4, 1e-6));
    });
  });

  group('resizing the window', () {
    test('keeps the zoom and the image point that was at the centre', () {
      final zoomed = _wide().scaledBy(2);
      final centre = zoomed.toImage(const Offset(400, 300));
      final resized = zoomed.resized(const Size(600, 900));
      expect(resized.viewport, const Size(600, 900));
      expect(resized.scale, 2);
      final newCentre = resized.toImage(const Offset(300, 450));
      expect(newCentre.x, closeTo(centre.x, 1e-6));
      expect(newCentre.y, closeTo(centre.y, 1e-6));
    });
  });

  test('an invalid zoom or a zero-sized box is refused, not silently accepted', () {
    expect(
      () => ImageViewport(
        viewport: const Size(0, 600),
        imageWidth: 4000,
        imageHeight: 3000,
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => ImageViewport(
        viewport: const Size(800, 600),
        imageWidth: 0,
        imageHeight: 3000,
      ),
      throwsA(isA<ValidationException>()),
    );
  });
}
