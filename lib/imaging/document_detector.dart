import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/geometry.dart';
import '../domain/validation.dart';
import 'prepare_image.dart';

/// Proposes the four corners of the document photographed in [preview].
///
/// Corners are normalized to the image (`x / (width - 1)`), ordered
/// clockwise starting from the corner whose following edge runs most to the
/// right (top-left for an upright document). Returns null when no boundary is
/// trustworthy; the caller then keeps the full frame for manual adjustment.
///
/// The pipeline is purely local and deterministic:
/// 1. A ~480 px working copy yields colour structure-tensor gradients.
/// 2. Candidates come from two independent sources: background segmentation
///    (border colours clustered, foreground thresholded with Otsu) and a
///    gradient-directed Hough transform whose line pairs form quadrilaterals.
/// 3. Each quadrilateral is scored by edge support along its sides, edge
///    strength, inside/outside contrast and area, with texture-crossing
///    penalties so patterned backgrounds do not produce confident crops.
/// 4. Near-best candidates are re-ranked by edge sharpness at full preview
///    resolution (soft shadow outlines lose to the physical card edge).
/// 5. Each side is refined at preview resolution with sub-pixel edge
///    localisation and a robust line fit; corners are the line intersections.
List<Point2>? suggestDocumentCorners(Uint8List preview) {
  final decoded = decodeForProcessing(preview);
  return detectDocumentCorners(decoded);
}

/// Same as [suggestDocumentCorners] for an already decoded image.
List<Point2>? detectDocumentCorners(img.Image image) {
  if (image.width < 20 || image.height < 20) {
    return null;
  }
  final fine = _Raster.fromImage(image, _fineSide);
  final coarse = _Raster.fromImage(image, _coarseSide);
  final detector = _Detector(fine, coarse);
  final quad =
      detector.run(sensitivity: 1, needMean: .5, needMin: .3) ??
      detector.run(sensitivity: .5, needMean: .7, needMin: .5);
  if (quad == null) {
    return null;
  }
  final w = fine.width - 1, h = fine.height - 1;
  final normalized = [
    for (final p in quad)
      Point2((p.x / w).clamp(0.0, 1.0), (p.y / h).clamp(0.0, 1.0)),
  ];
  try {
    CropGeometry(corners: normalized, outputWidth: 1, outputHeight: 1);
  } on ValidationException {
    return null;
  }
  return normalized;
}

const _coarseSide = 480;
const _fineSide = 1200;

class _P {
  const _P(this.x, this.y);
  final double x;
  final double y;
}

/// Planar floating point RGB copy, optionally reduced with box averaging.
class _Raster {
  _Raster(this.width, this.height)
    : r = Float32List(width * height),
      g = Float32List(width * height),
      b = Float32List(width * height);

  factory _Raster.fromImage(img.Image source, int maxSide) {
    var image = source;
    final longest = math.max(image.width, image.height);
    if (longest > maxSide) {
      final scale = maxSide / longest;
      image = img.copyResize(
        image,
        width: math.max(1, (image.width * scale).round()),
        height: math.max(1, (image.height * scale).round()),
        interpolation: img.Interpolation.average,
      );
    }
    final raster = _Raster(image.width, image.height);
    var i = 0;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++, i++) {
        final pixel = image.getPixel(x, y);
        raster.r[i] = pixel.rNormalized.toDouble() * 255;
        raster.g[i] = pixel.gNormalized.toDouble() * 255;
        raster.b[i] = pixel.bNormalized.toDouble() * 255;
      }
    }
    return raster;
  }

  final int width;
  final int height;
  final Float32List r;
  final Float32List g;
  final Float32List b;

  /// Separable binomial [1 4 6 4 1] / 16 blur with clamped borders.
  _Raster blurred() {
    final out = _Raster(width, height);
    final tmp = Float32List(width * height);
    const k = [1 / 16, 4 / 16, 6 / 16, 4 / 16, 1 / 16];
    for (final (src, dst) in [(r, out.r), (g, out.g), (b, out.b)]) {
      for (var y = 0; y < height; y++) {
        final row = y * width;
        for (var x = 0; x < width; x++) {
          var sum = 0.0;
          for (var d = -2; d <= 2; d++) {
            sum += k[d + 2] * src[row + (x + d).clamp(0, width - 1)];
          }
          tmp[row + x] = sum;
        }
      }
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          var sum = 0.0;
          for (var d = -2; d <= 2; d++) {
            sum += k[d + 2] * tmp[(y + d).clamp(0, height - 1) * width + x];
          }
          dst[y * width + x] = sum;
        }
      }
    }
    return out;
  }
}

/// Colour structure-tensor gradient: magnitude (per-channel units) and the
/// unit normal of the dominant edge orientation at each pixel.
class _Field {
  _Field(_Raster source, {required bool smooth})
    : rgb = smooth ? source.blurred() : source,
      width = source.width,
      height = source.height,
      mag = Float32List(source.width * source.height),
      nx = Float32List(source.width * source.height),
      ny = Float32List(source.width * source.height),
      theta = Float32List(source.width * source.height) {
    final w = width, h = height;
    for (var y = 0; y < h; y++) {
      final ym = math.max(0, y - 1) * w, yc = y * w;
      final yp = math.min(h - 1, y + 1) * w;
      for (var x = 0; x < w; x++) {
        final xm = math.max(0, x - 1), xp = math.min(w - 1, x + 1);
        var gxx = 0.0, gyy = 0.0, gxy = 0.0;
        for (final c in [rgb.r, rgb.g, rgb.b]) {
          final gx =
              (c[ym + xp] + 2 * c[yc + xp] + c[yp + xp]) -
              (c[ym + xm] + 2 * c[yc + xm] + c[yp + xm]);
          final gy =
              (c[yp + xm] + 2 * c[yp + x] + c[yp + xp]) -
              (c[ym + xm] + 2 * c[ym + x] + c[ym + xp]);
          gxx += gx * gx;
          gyy += gy * gy;
          gxy += gx * gy;
        }
        final det = math.sqrt((gxx - gyy) * (gxx - gyy) + 4 * gxy * gxy);
        final i = yc + x;
        mag[i] = math.sqrt(math.max(0.0, (gxx + gyy + det) / 2) / 3) / 4;
        final t = .5 * math.atan2(2 * gxy, gxx - gyy);
        theta[i] = t;
        nx[i] = math.cos(t);
        ny[i] = math.sin(t);
      }
    }
  }

  final _Raster rgb;
  final int width;
  final int height;
  final Float32List mag;
  final Float32List nx;
  final Float32List ny;
  final Float32List theta;

  /// Gradient magnitude weighted by how well the local edge matches the
  /// expected normal (cos²), so crossing texture contributes little.
  double aligned(double x, double y, double ux, double uy) {
    final xi = x.round(), yi = y.round();
    if (xi < 0 || yi < 0 || xi >= width || yi >= height) {
      return 0;
    }
    final i = yi * width + xi;
    final c = (nx[i] * ux + ny[i] * uy).abs();
    return mag[i] * c * c;
  }
}

class _Line {
  const _Line(this.a, this.b);
  final _P a;
  final _P b;
}

class _Score {
  const _Score({
    required this.total,
    required this.mean,
    required this.min,
    required this.area,
    required this.texture,
  });

  final double total;
  final double mean;
  final double min;
  final double area;
  final double texture;
}

class _Candidate {
  _Candidate(this.quad, this.score);
  final List<_P> quad;
  final _Score score;
}

class _Detector {
  _Detector(this.fineRaster, _Raster coarseRaster)
    : coarse = _Field(coarseRaster, smooth: true),
      scale = fineRaster.width / coarseRaster.width;

  final _Raster fineRaster;
  final _Field coarse;
  final double scale;
  _Field? _fine;
  _Field get fine => _fine ??= _Field(fineRaster, smooth: false);

  List<_P>? run({
    required double sensitivity,
    required double needMean,
    required double needMin,
  }) {
    final f = coarse;
    final w = f.width, h = f.height;
    if (math.min(w, h) < 20) {
      return null;
    }
    final sorted = Float32List.fromList(f.mag)..sort();
    final p90 = sorted[((sorted.length - 1) * .9).round()];
    final high = math.max(12.0, p90);
    final low = math.max(3.0, .45 * high * sensitivity);

    final quads = <List<_P>>[
      ..._segmentationCandidates(f),
      ..._houghCandidates(f, low),
    ];
    final scored = <_Candidate>[];
    for (final q in quads) {
      final s = _scoreQuad(f, q, low);
      if (s != null && s.texture < 30 && s.area < .985) {
        scored.add(_Candidate(q, s));
      }
    }
    if (scored.isEmpty) {
      return null;
    }
    scored.sort((a, b) => b.score.total.compareTo(a.score.total));
    final best = scored.first.score;
    if (best.mean < needMean || best.min < needMin) {
      return null;
    }

    // Shortlist near-best candidates and re-rank them by edge sharpness at
    // preview resolution: a soft shadow outline has a much weaker fine-scale
    // gradient relative to its coarse gradient than the physical card edge.
    final shortlist = <_Candidate>[];
    for (final c in scored) {
      if (c.score.total < best.total - .05 || shortlist.length >= 12) {
        break;
      }
      if (c.score.mean < needMean || c.score.min < needMin) {
        continue;
      }
      final duplicate = shortlist.any(
        (o) => List.generate(
          4,
          (i) => _dist(o.quad[i], c.quad[i]),
        ).every((d) => d < 1.5),
      );
      if (!duplicate) {
        shortlist.add(c);
      }
    }
    final ff = fine;
    var pick = shortlist.first;
    var pickValue = double.negativeInfinity;
    for (final c in shortlist) {
      final scaled = _scaled(c.quad, scale);
      final fineValues = _sideSharpness(ff, scaled, scale);
      final coarseValues = _sideSharpness(f, c.quad, 1);
      final fm = _mean(fineValues), cm = _mean(coarseValues);
      final sharpness = cm > 0 ? math.min(1.0, fm / cm) : 0.0;
      final value = c.score.total + .2 * sharpness;
      if (value > pickValue) {
        pickValue = value;
        pick = c;
      }
    }

    var q = _scaled(pick.quad, scale);
    final radius = math.max(3, (3 * scale).round());
    for (var pass = 0; pass < 2; pass++) {
      final refined = _refine(ff, q, low * .5, radius, 2.5 * scale);
      if (refined == null) {
        break;
      }
      final ordered = _orderQuad(refined);
      if (!_validQuad(ordered, ff.width, ff.height, .03)) {
        break;
      }
      q = refined;
    }
    return _orderQuad(q);
  }

  // ---------------------------------------------------------------- segmentation

  List<List<_P>> _segmentationCandidates(_Field f) {
    final w = f.width, h = f.height, n = w * h;
    final c = f.rgb;
    final band = math.max(2, (math.min(w, h) * .02).round());
    final border = <int>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (y < band || y >= h - band || x < band || x >= w - band) {
          border.add(y * w + x);
        }
      }
    }
    // k-means (k = 3) on the border colours: the background may be bimodal
    // (wood grain, two-tone tables) while the document rarely touches all
    // four borders.
    final centres = [
      for (final i in [0, border.length ~/ 2, border.length - 1])
        [c.r[border[i]], c.g[border[i]], c.b[border[i]]],
    ];
    final labels = Uint8List(border.length);
    for (var iteration = 0; iteration < 8; iteration++) {
      final sums = List.generate(3, (_) => [0.0, 0.0, 0.0, 0.0]);
      for (var j = 0; j < border.length; j++) {
        final i = border[j];
        var bestK = 0, bestD = double.infinity;
        for (var k = 0; k < 3; k++) {
          final dr = c.r[i] - centres[k][0];
          final dg = c.g[i] - centres[k][1];
          final db = c.b[i] - centres[k][2];
          final d = dr * dr + dg * dg + db * db;
          if (d < bestD) {
            bestD = d;
            bestK = k;
          }
        }
        labels[j] = bestK;
        sums[bestK][0] += c.r[i];
        sums[bestK][1] += c.g[i];
        sums[bestK][2] += c.b[i];
        sums[bestK][3] += 1;
      }
      for (var k = 0; k < 3; k++) {
        if (sums[k][3] > 0) {
          centres[k] = [
            sums[k][0] / sums[k][3],
            sums[k][1] / sums[k][3],
            sums[k][2] / sums[k][3],
          ];
        }
      }
    }
    final counts = List.filled(3, 0);
    for (final l in labels) {
      counts[l]++;
    }
    final kept = [
      for (var k = 0; k < 3; k++)
        if (counts[k] >= .1 * border.length) centres[k],
    ];
    final dist = Float32List(n);
    var maxDist = 0.0;
    for (var i = 0; i < n; i++) {
      var best = double.infinity;
      for (final centre in kept) {
        final dr = c.r[i] - centre[0];
        final dg = c.g[i] - centre[1];
        final db = c.b[i] - centre[2];
        best = math.min(best, dr * dr + dg * dg + db * db);
      }
      dist[i] = math.sqrt(best);
      maxDist = math.max(maxDist, dist[i]);
    }
    final threshold = math.max(18.0, _otsu(dist, maxDist));
    var mask = Uint8List(n);
    for (var i = 0; i < n; i++) {
      mask[i] = dist[i] > threshold ? 1 : 0;
    }
    mask = _morph(_morph(mask, w, h, 2, dilate: true), w, h, 2, dilate: false);
    mask = _fillHoles(mask, w, h);
    mask = _morph(_morph(mask, w, h, 2, dilate: false), w, h, 2, dilate: true);

    final result = <List<_P>>[];
    final components = _components(mask, w, h)
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final component in components.take(3)) {
      if (component.length < .03 * n) {
        break;
      }
      if (component.length > .995 * n) {
        continue;
      }
      // Leftmost/rightmost pixel per row are enough for an exact hull.
      final left = <int, int>{}, right = <int, int>{};
      for (final i in component) {
        final x = i % w, y = i ~/ w;
        left[y] = math.min(left[y] ?? x, x);
        right[y] = math.max(right[y] ?? x, x);
      }
      final points = <_P>[
        for (final y in left.keys) ...[
          _P(left[y]!.toDouble(), y.toDouble()),
          _P(right[y]!.toDouble(), y.toDouble()),
        ],
      ];
      final hull = _hull(points);
      if (hull.length < 4) {
        continue;
      }
      final quad = _enclosingQuad(hull);
      if (quad.length != 4) {
        continue;
      }
      final ordered = _orderQuad(quad);
      if (_validQuad(ordered, w, h, .03)) {
        result.add(ordered);
      }
    }
    return result;
  }

  // ---------------------------------------------------------------- hough

  List<List<_P>> _houghCandidates(_Field f, double low) {
    final w = f.width, h = f.height;
    final peaks = _houghPeaks(f, low);
    final pairs = <(int, int)>[];
    final cx = (w - 1) / 2, cy = (h - 1) / 2;
    for (var i = 0; i < peaks.length; i++) {
      for (var j = i + 1; j < peaks.length; j++) {
        final a = peaks[i], b = peaks[j];
        if (_angleDiff(a.theta, b.theta) > 25) {
          continue;
        }
        final sa = a.signedDistance(cx, cy), sb = b.signedDistance(cx, cy);
        final sameDirection = a.cos * b.cos + a.sin * b.sin > 0;
        final gap = sameDirection ? (sa - sb).abs() : (sa + sb).abs();
        if (gap < .1 * math.min(w, h)) {
          continue;
        }
        pairs.add((i, j));
      }
    }
    final result = <List<_P>>[];
    for (var p = 0; p < pairs.length; p++) {
      for (var q = p + 1; q < pairs.length; q++) {
        final (a1, a2) = pairs[p];
        final (b1, b2) = pairs[q];
        if ({a1, a2, b1, b2}.length < 4) {
          continue;
        }
        if (_angleDiff(peaks[a1].theta, peaks[b1].theta) < 55) {
          continue;
        }
        final lines = [
          for (final k in [a1, b1, a2, b2]) peaks[k].line,
        ];
        final corners = <_P>[];
        for (var k = 0; k < 4; k++) {
          final x = _intersect(lines[k], lines[(k + 1) % 4]);
          if (x == null) {
            break;
          }
          corners.add(x);
        }
        if (corners.length != 4) {
          continue;
        }
        final ordered = _orderQuad(corners);
        if (_validQuad(ordered, w, h, .04)) {
          result.add(ordered);
        }
      }
    }
    return result;
  }

  List<_Peak> _houghPeaks(_Field f, double low, {int maxLines = 16}) {
    final w = f.width, h = f.height;
    final diag = math.sqrt(w * w + h * h).ceil();
    final rhoBins = 2 * diag + 1;
    final acc = Float32List(180 * rhoBins);
    final cosv = List.generate(180, (t) => math.cos(t * math.pi / 180));
    final sinv = List.generate(180, (t) => math.sin(t * math.pi / 180));
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final m = f.mag[i];
        if (m < low) {
          continue;
        }
        // Non-maximum suppression across the edge.
        final dx = f.nx[i].round(), dy = f.ny[i].round();
        if (m < f.mag[(y + dy) * w + x + dx] ||
            m < f.mag[(y - dy) * w + x - dx]) {
          continue;
        }
        // Step-edge test: thin strokes (text, printed rules) have the same
        // colour on both sides and must not vote for document boundaries.
        final xa = (x + f.nx[i] * 3).round(), ya = (y + f.ny[i] * 3).round();
        final xb = (x - f.nx[i] * 3).round(), yb = (y - f.ny[i] * 3).round();
        if (xa >= 0 &&
            ya >= 0 &&
            xa < w &&
            ya < h &&
            xb >= 0 &&
            yb >= 0 &&
            xb < w &&
            yb < h) {
          final ia = ya * w + xa, ib = yb * w + xb;
          final c = f.rgb;
          final dr = c.r[ia] - c.r[ib], dg = c.g[ia] - c.g[ib];
          final db = c.b[ia] - c.b[ib];
          if (math.sqrt(dr * dr + dg * dg + db * db) <
              math.max(12.0, 1.2 * m)) {
            continue;
          }
        }
        final t = (f.theta[i] * 180 / math.pi).round() % 180;
        for (var dt = -5; dt <= 5; dt++) {
          final tt = (t + dt) % 180;
          final r = (x * cosv[tt] + y * sinv[tt]).round() + diag;
          acc[tt * rhoBins + r] += 1;
        }
      }
    }
    final minVotes = .12 * math.min(w, h);
    final peaks = <_Peak>[];
    for (var n = 0; n < maxLines; n++) {
      var bestIndex = 0;
      var bestValue = -1.0;
      for (var i = 0; i < acc.length; i++) {
        if (acc[i] > bestValue) {
          bestValue = acc[i];
          bestIndex = i;
        }
      }
      if (bestValue < minVotes) {
        break;
      }
      final t = bestIndex ~/ rhoBins, r = bestIndex % rhoBins;
      peaks.add(_Peak(t, (r - diag).toDouble()));
      for (var dt = -6; dt <= 6; dt++) {
        final raw = t + dt;
        final tt = raw % 180;
        final rr = raw >= 0 && raw < 180 ? r : 2 * diag - r;
        for (var d = -8; d <= 8; d++) {
          final k = rr + d;
          if (k >= 0 && k < rhoBins) {
            acc[tt * rhoBins + k] = 0;
          }
        }
      }
    }
    return peaks;
  }

  // ---------------------------------------------------------------- scoring

  _Score? _scoreQuad(_Field f, List<_P> q, double low) {
    final w = f.width, h = f.height;
    final supports = <double>[], strengths = <double>[];
    final contrasts = <double>[], textures = <double>[];
    final c = f.rgb;
    for (var i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4];
      final length = _dist(a, b);
      if (length < 4) {
        return null;
      }
      final tx = (b.x - a.x) / length, ty = (b.y - a.y) / length;
      final nx = ty, ny = -tx; // outward for a clockwise (y-down) polygon
      if (_onBorder(a, b, w, h, 2.5)) {
        supports.add(.55);
        strengths.add(.5);
        continue;
      }
      final n = (length / 3).clamp(12, 80).toInt();
      var hits = 0;
      final st = <double>[], cs = <double>[];
      final inside = <List<double>>[], outside = <List<double>>[];
      for (var k = 0; k < n; k++) {
        final t = .1 + .8 * k / (n - 1);
        final x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t;
        var best = 0.0;
        for (var o = -2; o <= 2; o++) {
          best = math.max(best, f.aligned(x + nx * o, y + ny * o, nx, ny));
        }
        if (best >= low) {
          hits++;
        }
        st.add(best);
        final xi = (x - nx * 4).round(), yi = (y - ny * 4).round();
        final xo = (x + nx * 4).round(), yo = (y + ny * 4).round();
        if (xi >= 0 &&
            xi < w &&
            yi >= 0 &&
            yi < h &&
            xo >= 0 &&
            xo < w &&
            yo >= 0 &&
            yo < h) {
          final ii = yi * w + xi, io = yo * w + xo;
          final pin = [c.r[ii], c.g[ii], c.b[ii]];
          final pout = [c.r[io], c.g[io], c.b[io]];
          cs.add(
            math.sqrt(
              math.pow(pin[0] - pout[0], 2) +
                  math.pow(pin[1] - pout[1], 2) +
                  math.pow(pin[2] - pout[2], 2),
            ),
          );
          inside.add(pin);
          outside.add(pout);
        }
      }
      supports.add(hits / n);
      strengths.add(math.min(1.0, _median(st) / (2.5 * low)));
      if (cs.isNotEmpty) {
        contrasts.add(_median(cs));
      }
      if (inside.length >= 6) {
        textures.add(math.min(_colourSpread(inside), _colourSpread(outside)));
      }
    }
    final saturated = [for (final s in supports) math.min(1.0, s / .9)];
    final meanSupport = _mean(supports);
    final minSupport = supports.reduce(math.min);
    final meanSaturated = _mean(saturated);
    final minSaturated = saturated.reduce(math.min);
    final contrast = math.min(1.0, _mean(contrasts) / 40);
    final area = _polygonArea(q) / (w * h);
    final strength = _mean(strengths);
    // A side counts as texture-crossing when both the inside and the outside
    // colours fluctuate strongly along it; three such sides mean the
    // quadrilateral is drawn on a pattern, not around a document.
    textures.sort();
    final texture = textures.length >= 3 ? textures[1] : 0.0;
    final penalty = ((texture - 15) / 30).clamp(0.0, 1.0);
    final total =
        .4 * meanSaturated +
        .2 * minSaturated +
        .1 * contrast +
        .15 * strength +
        .1 * math.sqrt(area) -
        .3 * penalty;
    return _Score(
      total: total,
      mean: meanSupport,
      min: minSupport,
      area: area,
      texture: texture,
    );
  }

  List<double> _sideSharpness(_Field f, List<_P> q, double k) {
    final r = math.max(1, k.round());
    final values = <double>[];
    for (var i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4];
      if (_onBorder(a, b, f.width, f.height, 2.5 * k)) {
        continue;
      }
      final length = _dist(a, b);
      final nx = (b.y - a.y) / length, ny = -(b.x - a.x) / length;
      final side = <double>[];
      for (var j = 0; j < 24; j++) {
        final t = .1 + .8 * j / 23;
        final x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t;
        var best = 0.0;
        for (var o = -r; o <= r; o++) {
          best = math.max(best, f.aligned(x + nx * o, y + ny * o, nx, ny));
        }
        side.add(best);
      }
      values.add(_median(side));
    }
    return values;
  }

  // ---------------------------------------------------------------- refinement

  List<_P>? _refine(
    _Field f,
    List<_P> q,
    double low,
    int radius,
    double borderTolerance,
  ) {
    final lines = <_Line>[];
    for (var i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4];
      final length = _dist(a, b);
      if (length < 1) {
        return null;
      }
      final nx = (b.y - a.y) / length, ny = -(b.x - a.x) / length;
      final points = <_P>[];
      if (!_onBorder(a, b, f.width, f.height, borderTolerance)) {
        final n = (length / 2).clamp(16, 120).toInt();
        final values = List<double>.filled(2 * radius + 1, 0);
        for (var k = 0; k < n; k++) {
          final t = .08 + .84 * k / (n - 1);
          final x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t;
          var j = 0;
          var weightedBest = -1.0;
          for (var o = -radius; o <= radius; o++) {
            final v = f.aligned(x + nx * o, y + ny * o, nx, ny);
            values[o + radius] = v;
            // Prefer the edge nearest the coarse estimate among similar ones.
            final weighted = v * (1 - .5 * math.pow(o / radius, 2));
            if (weighted > weightedBest) {
              weightedBest = weighted;
              j = o + radius;
            }
          }
          if (values[j] < low) {
            continue;
          }
          var offset = (j - radius).toDouble();
          if (j > 0 && j < values.length - 1) {
            final den = values[j - 1] - 2 * values[j] + values[j + 1];
            if (den < 0) {
              offset += .5 * (values[j - 1] - values[j + 1]) / den;
            }
          }
          points.add(_P(x + nx * offset, y + ny * offset));
        }
      }
      lines.add(points.length >= 8 ? _fitLine(points) : _Line(a, b));
    }
    final out = <_P>[];
    for (var i = 0; i < 4; i++) {
      final x = _intersect(lines[(i + 3) % 4], lines[i]);
      if (x == null) {
        return null;
      }
      out.add(x);
    }
    return out;
  }
}

class _Peak {
  _Peak(this.theta, this.rho)
    : cos = math.cos(theta * math.pi / 180),
      sin = math.sin(theta * math.pi / 180);
  final int theta;
  final double rho;
  final double cos;
  final double sin;

  double signedDistance(double x, double y) => x * cos + y * sin - rho;

  _Line get line {
    final x0 = cos * rho, y0 = sin * rho;
    return _Line(_P(x0, y0), _P(x0 - sin * 100, y0 + cos * 100));
  }
}

// ------------------------------------------------------------------ helpers

double _dist(_P a, _P b) =>
    math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

double _mean(List<double> values) =>
    values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;

double _median(List<double> values) {
  if (values.isEmpty) {
    return 0;
  }
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Mean per-channel standard deviation.
double _colourSpread(List<List<double>> colours) {
  var total = 0.0;
  for (var channel = 0; channel < 3; channel++) {
    final values = [for (final c in colours) c[channel]];
    final m = _mean(values);
    var v = 0.0;
    for (final x in values) {
      v += (x - m) * (x - m);
    }
    total += math.sqrt(v / values.length);
  }
  return total / 3;
}

List<_P> _scaled(List<_P> q, double k) => [
  for (final p in q) _P(p.x * k, p.y * k),
];

double _angleDiff(int a, int b) {
  final d = (a - b).abs() % 180;
  return math.min(d, 180 - d).toDouble();
}

double _cross(_P o, _P a, _P b) =>
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

double _polygonArea(List<_P> p) {
  var sum = 0.0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i], b = p[(i + 1) % p.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum / 2;
}

_P? _intersect(_Line l1, _Line l2) {
  final p1 = l1.a, p2 = l1.b, p3 = l2.a, p4 = l2.b;
  final d = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x);
  if (d.abs() < 1e-12) {
    return null;
  }
  final a = p1.x * p2.y - p1.y * p2.x, b = p3.x * p4.y - p3.y * p4.x;
  return _P(
    (a * (p3.x - p4.x) - (p1.x - p2.x) * b) / d,
    (a * (p3.y - p4.y) - (p1.y - p2.y) * b) / d,
  );
}

bool _onBorder(_P a, _P b, int w, int h, double tol) =>
    (a.x <= tol && b.x <= tol) ||
    (a.y <= tol && b.y <= tol) ||
    (a.x >= w - 1 - tol && b.x >= w - 1 - tol) ||
    (a.y >= h - 1 - tol && b.y >= h - 1 - tol);

/// Clockwise (y-down) order starting at the vertex whose outgoing edge points
/// most to the right.
List<_P> _orderQuad(List<_P> q) {
  final cx = _mean([for (final p in q) p.x]);
  final cy = _mean([for (final p in q) p.y]);
  final sorted = [...q]
    ..sort(
      (a, b) => math
          .atan2(a.y - cy, a.x - cx)
          .compareTo(math.atan2(b.y - cy, b.x - cx)),
    );
  var start = 0;
  var bestDx = -2.0;
  for (var i = 0; i < 4; i++) {
    final a = sorted[i], b = sorted[(i + 1) % 4];
    final length = _dist(a, b);
    final dx = length == 0 ? -1.0 : (b.x - a.x) / length;
    if (dx > bestDx) {
      bestDx = dx;
      start = i;
    }
  }
  return [for (var i = 0; i < 4; i++) sorted[(start + i) % 4]];
}

bool _validQuad(List<_P> q, int w, int h, double minArea) {
  for (var i = 0; i < 4; i++) {
    if (_cross(q[i], q[(i + 1) % 4], q[(i + 2) % 4]) <= 0) {
      return false;
    }
    final a = q[(i + 3) % 4], b = q[i], c = q[(i + 1) % 4];
    final v1x = a.x - b.x, v1y = a.y - b.y, v2x = c.x - b.x, v2y = c.y - b.y;
    final l =
        math.sqrt(v1x * v1x + v1y * v1y) * math.sqrt(v2x * v2x + v2y * v2y);
    if (l == 0) {
      return false;
    }
    final angle =
        math.acos(((v1x * v2x + v1y * v2y) / l).clamp(-1.0, 1.0)) *
        180 /
        math.pi;
    if (angle < 45 || angle > 135) {
      return false;
    }
  }
  final m = .04 * math.max(w, h);
  for (final p in q) {
    if (p.x < -m || p.y < -m || p.x > w - 1 + m || p.y > h - 1 + m) {
      return false;
    }
  }
  return _polygonArea(q) >= minArea * w * h;
}

List<_P> _hull(List<_P> input) {
  final points = [...input]
    ..sort((a, b) {
      final x = a.x.compareTo(b.x);
      return x == 0 ? a.y.compareTo(b.y) : x;
    });
  if (points.length < 3) {
    return points;
  }
  final lower = <_P>[], upper = <_P>[];
  for (final p in points) {
    while (lower.length >= 2 &&
        _cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  for (final p in points.reversed) {
    while (upper.length >= 2 &&
        _cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  return [...lower.take(lower.length - 1), ...upper.take(upper.length - 1)];
}

/// Reduces a convex polygon to the enclosing quadrilateral by repeatedly
/// removing the edge whose neighbours, once extended, add the least area.
List<_P> _enclosingQuad(List<_P> hull) {
  final p = [...hull];
  while (p.length > 4) {
    final n = p.length;
    int? bestIndex;
    _P? bestPoint;
    var bestAdded = double.infinity;
    for (var i = 0; i < n; i++) {
      final a = p[(i - 1 + n) % n], b = p[i], c = p[(i + 1) % n];
      final d = p[(i + 2) % n];
      final x = _intersect(_Line(a, b), _Line(c, d));
      if (x == null) {
        continue;
      }
      if ((x.x - b.x) * (b.x - a.x) + (x.y - b.y) * (b.y - a.y) < -1e-9) {
        continue;
      }
      if ((x.x - c.x) * (c.x - d.x) + (x.y - c.y) * (c.y - d.y) < -1e-9) {
        continue;
      }
      final added = _cross(b, x, c).abs() / 2;
      if (added < bestAdded) {
        bestAdded = added;
        bestIndex = i;
        bestPoint = x;
      }
    }
    if (bestIndex == null) {
      var remove = 0;
      var smallest = double.infinity;
      for (var i = 0; i < n; i++) {
        final cost = _cross(p[(i - 1 + n) % n], p[i], p[(i + 1) % n]).abs();
        if (cost < smallest) {
          smallest = cost;
          remove = i;
        }
      }
      p.removeAt(remove);
      continue;
    }
    p[bestIndex] = bestPoint!;
    p.removeAt((bestIndex + 1) % n);
  }
  return p;
}

/// Least-squares line through [points] after discarding outliers.
_Line _fitLine(List<_P> input) {
  var points = input;
  late _P centre;
  late double dx, dy;
  for (var iteration = 0; iteration < 3; iteration++) {
    final mx = _mean([for (final p in points) p.x]);
    final my = _mean([for (final p in points) p.y]);
    var sxx = 0.0, syy = 0.0, sxy = 0.0;
    for (final p in points) {
      sxx += (p.x - mx) * (p.x - mx);
      syy += (p.y - my) * (p.y - my);
      sxy += (p.x - mx) * (p.y - my);
    }
    final angle = .5 * math.atan2(2 * sxy, sxx - syy);
    centre = _P(mx, my);
    dx = math.cos(angle);
    dy = math.sin(angle);
    final residuals = [
      for (final p in points) ((p.x - mx) * -dy + (p.y - my) * dx).abs(),
    ];
    final limit = math.max(1.0, 2.5 * _median(residuals));
    final kept = [
      for (var i = 0; i < points.length; i++)
        if (residuals[i] <= limit) points[i],
    ];
    if (kept.length == points.length || kept.length < 8) {
      break;
    }
    points = kept;
  }
  return _Line(centre, _P(centre.x + dx, centre.y + dy));
}

double _otsu(Float32List values, double maxValue, {int bins = 256}) {
  final top = maxValue + 1e-9;
  final hist = List<int>.filled(bins, 0);
  for (final v in values) {
    hist[math.min(bins - 1, (v / top * bins).floor())]++;
  }
  final total = values.length;
  var sumAll = 0.0;
  for (var i = 0; i < bins; i++) {
    sumAll += i * hist[i];
  }
  var wb = 0, sb = 0.0, best = 0.0, threshold = 0;
  for (var i = 0; i < bins; i++) {
    wb += hist[i];
    if (wb == 0) {
      continue;
    }
    final wf = total - wb;
    if (wf == 0) {
      break;
    }
    sb += i * hist[i];
    final mb = sb / wb, mf = (sumAll - sb) / wf;
    final between = wb * wf * (mb - mf) * (mb - mf);
    if (between > best) {
      best = between;
      threshold = i;
    }
  }
  return (threshold + 1) * top / bins;
}

/// Square structuring element, separable. Erosion treats outside as set so
/// regions touching the frame are not eaten away.
Uint8List _morph(Uint8List mask, int w, int h, int r, {required bool dilate}) {
  final outside = dilate ? 0 : 1;
  var src = mask;
  for (final horizontal in [true, false]) {
    final dst = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var value = dilate ? 0 : 1;
        for (var d = -r; d <= r; d++) {
          final xx = horizontal ? x + d : x, yy = horizontal ? y : y + d;
          final v = xx < 0 || yy < 0 || xx >= w || yy >= h
              ? outside
              : src[yy * w + xx];
          value = dilate ? math.max(value, v) : math.min(value, v);
        }
        dst[y * w + x] = value;
      }
    }
    src = dst;
  }
  return src;
}

Uint8List _fillHoles(Uint8List mask, int w, int h) {
  final reach = Uint8List(w * h);
  final stack = <int>[];
  void seed(int i) {
    if (mask[i] == 0 && reach[i] == 0) {
      reach[i] = 1;
      stack.add(i);
    }
  }

  for (var x = 0; x < w; x++) {
    seed(x);
    seed((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    seed(y * w);
    seed(y * w + w - 1);
  }
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final x = i % w, y = i ~/ w;
    if (x > 0) {
      seed(i - 1);
    }
    if (x < w - 1) {
      seed(i + 1);
    }
    if (y > 0) {
      seed(i - w);
    }
    if (y < h - 1) {
      seed(i + w);
    }
  }
  final out = Uint8List(w * h);
  for (var i = 0; i < out.length; i++) {
    out[i] = reach[i] == 0 ? 1 : 0;
  }
  return out;
}

List<List<int>> _components(Uint8List mask, int w, int h) {
  final label = Int32List(w * h)..fillRange(0, w * h, -1);
  final result = <List<int>>[];
  for (var s = 0; s < mask.length; s++) {
    if (mask[s] == 0 || label[s] >= 0) {
      continue;
    }
    final id = result.length;
    final points = <int>[s];
    label[s] = id;
    for (var head = 0; head < points.length; head++) {
      final i = points[head], x = i % w, y = i ~/ w;
      for (final j in [
        if (x > 0) i - 1,
        if (x < w - 1) i + 1,
        if (y > 0) i - w,
        if (y < h - 1) i + w,
      ]) {
        if (mask[j] != 0 && label[j] < 0) {
          label[j] = id;
          points.add(j);
        }
      }
    }
    result.add(points);
  }
  return result;
}
