import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/geometry.dart';

/// Places the loupe in the quadrant opposite the pointer.
///
/// Physical alignment is intentional: it does not flip with RTL. A top-right
/// drag therefore shows the loupe at bottom-left, never beneath the finger.
Alignment cropLoupeAlignment(Point2 focus) =>
    Alignment(focus.x <= .5 ? 1 : -1, focus.y <= .5 ? 1 : -1);

/// A precision loupe shown WHILE a crop corner or edge is being dragged.
///
/// It magnifies the source pixels around the exact point under the finger,
/// draws the four-sided boundary at that same scale and puts a crosshair at the
/// focus point. Without it, the finger hides the corner being adjusted and the
/// user has no way to see whether the handle sits on the physical card edge.
///
/// The loupe is a fixed, screen-space overlay (never inside the
/// [InteractiveViewer] transform), so zooming the photo cannot shrink or
/// displace the magnified view. It is always wrapped in [IgnorePointer] by the
/// caller: it is an instrument, not a control.
class CropPrecisionLoupe extends StatelessWidget {
  const CropPrecisionLoupe({
    required this.preview,
    required this.corners,
    required this.focus,
    required this.canvasSize,
    required this.zoom,
    super.key,
    this.magnification = 2.5,
    this.diameter = 116,
  });

  /// Encoded (PNG) source preview, exactly the pixels the handles sit on.
  final Uint8List preview;

  /// Current crop corners, normalized to the source.
  final List<Point2> corners;

  /// Normalized point under the pointer.
  final Point2 focus;

  /// Canvas size in the viewer's CONTENT coordinates (before zoom).
  final Size canvasSize;

  /// Current viewer scale.
  final double zoom;

  final double magnification;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final scale = zoom.isFinite && zoom > 0 ? zoom : 1.0;
    // The source is displayed at canvasSize * zoom on screen. Magnifying that
    // by [magnification] keeps the loupe honest at every zoom level: it always
    // shows a strictly closer view than the finger is looking at.
    final imageWidth = canvasSize.width * scale * magnification;
    final imageHeight = canvasSize.height * scale * magnification;
    final half = diameter / 2;
    final offset = Offset(
      half - focus.x * imageWidth,
      half - focus.y * imageHeight,
    );
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'مكبّر دقة الزاوية',
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface,
            border: Border.all(color: scheme.primary, width: 3),
            boxShadow: const [
              BoxShadow(color: Color(0x55000000), blurRadius: 8),
            ],
          ),
          child: ClipOval(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: offset.dx,
                  top: offset.dy,
                  width: imageWidth,
                  height: imageHeight,
                  child: Image.memory(
                    preview,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _LoupePainter(
                      corners: corners,
                      imageOffset: offset,
                      imageSize: Size(imageWidth, imageHeight),
                      crosshair: Offset(half, half),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LoupePainter extends CustomPainter {
  const _LoupePainter({
    required this.corners,
    required this.imageOffset,
    required this.imageSize,
    required this.crosshair,
  });

  final List<Point2> corners;
  final Offset imageOffset;
  final Size imageSize;
  final Offset crosshair;

  Offset _map(Point2 p) => Offset(
    imageOffset.dx + p.x * imageSize.width,
    imageOffset.dy + p.y * imageSize.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;
    final first = _map(corners[0]);
    final path = Path()..moveTo(first.dx, first.dy);
    for (final p in corners.skip(1)) {
      final point = _map(p);
      path.lineTo(point.dx, point.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xff12685e).withValues(alpha: .16),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff12685e)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    const arm = 13.0;
    final crossPaint = Paint()
      ..color = const Color(0xffffd54f)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(crosshair.dx - arm, crosshair.dy),
      Offset(crosshair.dx + arm, crosshair.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(crosshair.dx, crosshair.dy - arm),
      Offset(crosshair.dx, crosshair.dy + arm),
      crossPaint,
    );
    canvas.drawCircle(crosshair, 8, crossPaint);
  }

  @override
  bool shouldRepaint(covariant _LoupePainter old) =>
      !identical(old.corners, corners) ||
      old.imageOffset != imageOffset ||
      old.imageSize != imageSize ||
      old.crosshair != crosshair;
}
