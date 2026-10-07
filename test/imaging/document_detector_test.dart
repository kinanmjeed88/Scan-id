import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/document_detector.dart';

const _w = 640, _h = 480;

/// Deterministic noise so every run renders the identical scene.
class _Lcg {
  _Lcg(this._state);
  int _state;
  double next() {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state / 0x7fffffff;
  }
}

typedef _Background = List<double> Function(int x, int y, _Lcg noise);

/// Positive inside a clockwise (y-down) convex quadrilateral.
double _signedInside(double px, double py, List<(double, double)> quad) {
  var d = double.infinity;
  for (var i = 0; i < 4; i++) {
    final (ax, ay) = quad[i];
    final (bx, by) = quad[(i + 1) % 4];
    final l = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    final nx = -(by - ay) / l, ny = (bx - ax) / l;
    d = math.min(d, (px - ax) * nx + (py - ay) * ny);
  }
  return d;
}

/// A card with a photo block and text lines over [background], with a soft
/// cast shadow offset down-right — the situation in ordinary phone photos.
img.Image _scene(
  _Background background,
  List<(double, double)>? quad,
  List<double> cardColour,
) {
  final noise = _Lcg(3);
  final image = img.Image(width: _w, height: _h);
  final shadow = quad == null
      ? null
      : [for (final (x, y) in quad) (x + 7, y + 9)];
  final x0 = quad == null ? 0.0 : quad.map((p) => p.$1).reduce(math.min);
  final y0 = quad == null ? 0.0 : quad.map((p) => p.$2).reduce(math.min);
  for (var y = 0; y < _h; y++) {
    for (var x = 0; x < _w; x++) {
      var c = background(x, y, noise);
      if (shadow != null) {
        final d = _signedInside(x.toDouble(), y.toDouble(), shadow);
        final f = ((d + 12) / 24).clamp(0.0, 1.0);
        c = [for (final v in c) v * (1 - .35 * f)];
      }
      if (quad != null &&
          _signedInside(x.toDouble(), y.toDouble(), quad) >= 0) {
        final px = x - x0 - 30, py = y - y0 - 40;
        if (px >= 0 && px < 60 && py >= 0 && py < 70) {
          c = [110, 95, 90];
        } else if ((y - y0).floor() % 17 == 0 && x - x0 > 110) {
          c = [80, 80, 90];
        } else {
          c = cardColour;
        }
      }
      image.setPixelRgb(
        x,
        y,
        c[0].round().clamp(0, 255),
        c[1].round().clamp(0, 255),
        c[2].round().clamp(0, 255),
      );
    }
  }
  return image;
}

List<double> _wood(int x, int y, _Lcg noise) {
  final g =
      (math.sin(x / 9 + math.sin(y / 40) * 3) * .5 + .5) * 40 +
      noise.next() * 20;
  return [150 + g, 100 + .7 * g, 60 + .4 * g];
}

List<double> _dark(int x, int y, _Lcg noise) {
  final n = noise.next() * 12;
  return [40 + n, 45 + n, 55 + n];
}

List<double> _checker(int x, int y, _Lcg noise) =>
    (x ~/ 24 + y ~/ 24).isEven ? [200, 60, 60] : [235, 220, 220];

List<(double, double)> _rotated(
  double cx,
  double cy,
  double w,
  double h,
  double degrees,
) {
  final a = degrees * math.pi / 180;
  return [
    for (final (u, v) in [
      (-w / 2, -h / 2),
      (w / 2, -h / 2),
      (w / 2, h / 2),
      (-w / 2, h / 2),
    ])
      (
        cx + u * math.cos(a) - v * math.sin(a),
        cy + u * math.sin(a) + v * math.cos(a),
      ),
  ];
}

double _maxError(List<Point2> found, List<(double, double)> truth) {
  var worst = 0.0;
  for (var i = 0; i < 4; i++) {
    final (tx, ty) = truth[i];
    worst = math.max(worst, (found[i].x - tx / (_w - 1)).abs());
    worst = math.max(worst, (found[i].y - ty / (_h - 1)).abs());
  }
  return worst;
}

void main() {
  test('proposes a plain card on a contrasting background without applying '
      'it', () {
    final source = img.Image(width: 200, height: 140);
    img.fillRect(
      source,
      x1: 25,
      y1: 20,
      x2: 175,
      y2: 120,
      color: img.ColorRgb8(245, 245, 245),
    );
    final bytes = img.encodePng(source), before = img.encodePng(source);
    final points = suggestDocumentCorners(bytes);
    expect(points, isNotNull);
    expect(points![0].x, closeTo(25 / 199, .01));
    expect(points[0].y, closeTo(20 / 139, .01));
    expect(points[2].x, closeTo(175 / 199, .01));
    expect(points[2].y, closeTo(120 / 139, .01));
    expect(bytes, before);
  });

  test('finds a rotated ID card with a shadow on wood grain', () {
    final truth = _rotated(330, 250, 300, 300 / 1.5858, 17);
    final found = detectDocumentCorners(_scene(_wood, truth, [225, 228, 235]));
    expect(found, isNotNull);
    expect(_maxError(found!, truth), lessThan(.005));
  });

  test('finds a card photographed in perspective on a dark cloth', () {
    final truth = [
      (170.0, 130.0),
      (470.0, 110.0),
      (500.0, 330.0),
      (150.0, 360.0),
    ];
    final found = detectDocumentCorners(_scene(_dark, truth, [230, 215, 160]));
    expect(found, isNotNull);
    expect(_maxError(found!, truth), lessThan(.005));
  });

  test('corners are normalized, clockwise and start at the top-left', () {
    final truth = _rotated(330, 250, 300, 300 / 1.5858, 17);
    final found = detectDocumentCorners(_scene(_wood, truth, [225, 228, 235]))!;
    expect(
      CropGeometry(corners: found, outputWidth: 10, outputHeight: 10).corners,
      hasLength(4),
    );
    expect(found[0].y, lessThan(found[3].y));
    expect(found[1].x, greaterThan(found[0].x));
  });

  test('a patterned surface without a document gives no confident crop', () {
    expect(detectDocumentCorners(_scene(_checker, null, const [])), isNull);
  });

  test('flat or tiny photos give no confident boundary suggestion', () {
    expect(
      suggestDocumentCorners(img.encodePng(img.Image(width: 120, height: 90))),
      isNull,
    );
    expect(
      suggestDocumentCorners(img.encodePng(img.Image(width: 2, height: 2))),
      isNull,
    );
  });
}
