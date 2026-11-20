import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../domain/geometry.dart';
import '../domain/validation.dart';

/// Maps between the photograph's own coordinates and the screen while the
/// photograph is zoomed and panned.
///
/// This is the ONLY place the two coordinate systems meet. Everything stored and
/// everything cropped speaks normalized image coordinates (0..1); everything
/// tapped and drawn speaks screen pixels. Keeping the conversion in one small,
/// testable value is what makes a corner stay on the same pixel of the document
/// at 1× and at 4×.
///
/// [viewport] is the box the photograph is shown in. The fitted rectangle is the
/// largest rectangle of the image's aspect that fits that box (what
/// `BoxFit.contain` produces); [scale] and [offset] are the zoom and pan the
/// person applied on top of the fit.
class ImageViewport {
  ImageViewport({
    required this.viewport,
    required this.imageWidth,
    required this.imageHeight,
    this.scale = 1,
    this.offset = Offset.zero,
  }) {
    // require(), not assert(): an unusable box is a real error in release too,
    // and a bare assertion would vanish and let a bogus transform through.
    require(
      viewport.width > 0 && viewport.height > 0,
      'أبعاد العرض غير صالحة.',
    );
    require(imageWidth > 0 && imageHeight > 0, 'أبعاد الصورة غير صالحة.');
    require(
      scale.isFinite && scale >= minScale && scale <= maxScale,
      'نسبة التكبير خارج الحد المسموح.',
    );
  }

  /// Smallest zoom: the fitted image, whole, inside the viewport.
  static const double minScale = 1;

  /// 5× matches the crop editor's own zoom ceiling, so both screens let a person
  /// reach the same level of detail.
  static const double maxScale = 5;

  final Size viewport;
  final double imageWidth;
  final double imageHeight;
  final double scale;
  final Offset offset;

  double get imageAspect => imageWidth / imageHeight;

  /// The rectangle the photograph would occupy, centred, at 1×.
  Rect get fittedRect {
    final viewportAspect = viewport.width / viewport.height;
    if (imageAspect >= viewportAspect) {
      final width = viewport.width;
      final height = width / imageAspect;
      return Rect.fromLTWH(0, (viewport.height - height) / 2, width, height);
    }
    final height = viewport.height;
    final width = height * imageAspect;
    return Rect.fromLTWH((viewport.width - width) / 2, 0, width, height);
  }

  /// The rectangle the photograph actually covers on screen right now.
  Rect get displayedRect {
    final fit = fittedRect;
    return Rect.fromLTWH(
      fit.left * scale + offset.dx,
      fit.top * scale + offset.dy,
      fit.width * scale,
      fit.height * scale,
    );
  }

  /// Normalized image point to screen pixels.
  ///
  /// Not clamped: at high zoom an edge point legitimately sits outside the
  /// viewport, and callers may still want its true position to draw handles.
  Offset toScreen(Point2 point) => Offset(
    displayedRect.left + point.x * displayedRect.width,
    displayedRect.top + point.y * displayedRect.height,
  );

  /// Screen pixels to a normalized image point, clamped to [0, 1] on both axes.
  ///
  /// Clamping is a decision, not tidiness: a tap a couple of pixels outside the
  /// photograph is a person meaning «the edge», and refusing it would make it
  /// impossible to frame a document that reaches the border. The clamped point is
  /// still validated by the geometry rules before anything is cropped.
  Point2 toImage(Offset screen) {
    final rect = displayedRect;
    require(
      rect.width > 0 && rect.height > 0,
      'لا يمكن تحويل النقطة دون صورة معروضة.',
    );
    return Point2(
      ((screen.dx - rect.left) / rect.width).clamp(0.0, 1.0),
      ((screen.dy - rect.top) / rect.height).clamp(0.0, 1.0),
    );
  }

  /// True when [screen] falls inside the photograph's displayed area, with
  /// [tolerance] pixels of slack so the outer half-pixel of an edge still counts.
  bool containsScreen(Offset screen, {double tolerance = 0}) =>
      displayedRect.inflate(tolerance).contains(screen);

  /// Distance in screen pixels between two normalized points.
  ///
  /// The minimum tap separation is a screen-space ergonomics rule: at 4× a person
  /// can aim far more precisely, so the limit must scale with what they can see.
  double screenDistance(Point2 a, Point2 b) {
    final rect = displayedRect;
    final dx = (a.x - b.x) * rect.width;
    final dy = (a.y - b.y) * rect.height;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Zoom by [factor] keeping the image point under [focus] under the same
  /// finger. Defaults to the viewport centre.
  ///
  /// Without the focus correction a pinch drags the document out from under the
  /// person's hands and the corner they were aiming at drifts away.
  ImageViewport scaledBy(double factor, {Offset? focus}) {
    if (!factor.isFinite || factor <= 0) return this;
    final next = (scale * factor).clamp(minScale, maxScale).toDouble();
    if (next == scale) return this;
    final anchor = focus ?? Offset(viewport.width / 2, viewport.height / 2);
    final rect = displayedRect;
    if (rect.width <= 0 || rect.height <= 0) return _withScale(next);
    final u = (anchor.dx - rect.left) / rect.width;
    final v = (anchor.dy - rect.top) / rect.height;
    final fit = fittedRect;
    final nextLeft = fit.left * next;
    final nextTop = fit.top * next;
    final nextWidth = fit.width * next;
    final nextHeight = fit.height * next;
    return ImageViewport(
      viewport: viewport,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      scale: next,
      offset: _clampOffset(
        next,
        Offset(
          anchor.dx - u * nextWidth - nextLeft,
          anchor.dy - v * nextHeight - nextTop,
        ),
      ),
    );
  }

  /// Pan by a screen-pixel delta, refusing to drag the photograph out of sight.
  ImageViewport translatedBy(Offset delta) => ImageViewport(
    viewport: viewport,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    scale: scale,
    offset: _clampOffset(scale, offset + delta),
  );

  /// Back to the whole photograph, centred.
  ImageViewport reset() => ImageViewport(
    viewport: viewport,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );

  /// The same viewport fitted to a new box, keeping zoom and the image point that
  /// was at the old centre near the new one. Used when the window is resized.
  ImageViewport resized(Size next) {
    if (next.width <= 0 || next.height <= 0) return this;
    final centre = toImage(Offset(viewport.width / 2, viewport.height / 2));
    final fresh = ImageViewport(
      viewport: next,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      scale: scale,
    );
    final rect = fresh.displayedRect;
    final target = Offset(
      next.width / 2 - centre.x * rect.width - rect.left,
      next.height / 2 - centre.y * rect.height - rect.top,
    );
    return ImageViewport(
      viewport: next,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      scale: scale,
      offset: fresh._clampOffset(scale, target),
    );
  }

  ImageViewport _withScale(double next) => ImageViewport(
    viewport: viewport,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    scale: next,
    offset: offset,
  );

  /// Keeps the photograph overlapping the viewport. An axis that fits entirely
  /// stays centred so panning back always restores the whole image; a zoomed axis
  /// may not leave a gap on either side.
  Offset _clampOffset(double nextScale, Offset candidate) {
    final fit = fittedRect;
    final width = fit.width * nextScale;
    final height = fit.height * nextScale;
    double axis(double value, double size, double extent, double start) {
      if (size <= extent) return (extent - size) / 2 - start * nextScale;
      final lower = extent - size - start * nextScale;
      final upper = -start * nextScale;
      return value.clamp(lower, upper).toDouble();
    }

    return Offset(
      axis(candidate.dx, width, viewport.width, fit.left),
      axis(candidate.dy, height, viewport.height, fit.top),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ImageViewport &&
      other.viewport == viewport &&
      other.imageWidth == imageWidth &&
      other.imageHeight == imageHeight &&
      other.scale == scale &&
      other.offset == offset;

  @override
  int get hashCode =>
      Object.hash(viewport, imageWidth, imageHeight, scale, offset);

  @override
  String toString() =>
      'ImageViewport(${viewport.width}x${viewport.height}, '
      'scale $scale, offset $offset)';
}
