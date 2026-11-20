import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../application/contracts.dart';
import '../domain/geometry.dart';
import 'boundary_handle.dart';
import 'boundary_hit_layer.dart';
import 'crop_loupe.dart';

const manualTapMinSeparationPx = 20.0;
const cornerCrossingMessage = 'زوايا القص تتقاطع؛ أبقيت آخر موضع صالح للزاوية.';

/// Shared interaction surface. Callers own the document, geometry and undo
/// history; this widget owns pointer capture and the projection onto pixels.
class CropBoundaryCanvas extends StatefulWidget {
  const CropBoundaryCanvas({
    super.key,
    required this.source,
    required this.view,
    required this.corners,
    this.taps,
    this.backgrounds = const {},
    required this.onTap,
    required this.onMove,
    required this.onRefused,
    this.onDragStart,
    this.onDragEnd,
    this.onDragCancel,
    this.busy = false,
    this.imageKey = const Key('crop-source-image'),
  });
  final EditorSource source;
  final TransformationController view;
  final List<Point2> corners;
  final List<Point2>? taps;
  final Map<int, List<Point2>> backgrounds;
  final void Function(Point2, double) onTap;
  final ValueChanged<List<Point2>> onMove;
  final VoidCallback onRefused;
  final VoidCallback? onDragStart, onDragEnd, onDragCancel;
  final bool busy;
  final Key imageKey;
  @override
  State<CropBoundaryCanvas> createState() => _CropBoundaryCanvasState();
}

class _CropBoundaryCanvasState extends State<CropBoundaryCanvas> {
  final _canvasKey = GlobalKey();
  TransformationController get _view => widget.view;
  BoundaryHandle? _activeDragHandle;
  Offset? _dragLastLocal;
  Point2? _loupeFocus;
  @override
  Widget build(BuildContext context) => ClipRect(
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: LayoutBuilder(
        builder: (context, box) {
          final ratio = widget.source.width / widget.source.height;
          final availableWidth = math.max(
            1.0,
            box.maxWidth - boundaryCanvasInsetPx * 2,
          );
          final availableHeight = math.max(
            1.0,
            box.maxHeight - boundaryCanvasInsetPx * 2,
          );
          final width = math.min(availableWidth, availableHeight * ratio);
          final height = width / ratio;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Center(
                  child: InteractiveViewer(
                    transformationController: _view,
                    minScale: 1,
                    maxScale: 5,
                    clipBehavior: Clip.none,
                    child: SizedBox(
                      // The hit-test box includes the entire corner handles,
                      // not just the image. Clip.none alone only expands paint.
                      width: width + boundaryCanvasInsetPx * 2,
                      height: height + boundaryCanvasInsetPx * 2,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: boundaryCanvasInsetPx,
                            top: boundaryCanvasInsetPx,
                            width: width,
                            height: height,
                            child: SizedBox(
                              key: _canvasKey,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: Image.memory(
                                      widget.source.preview,
                                      key: widget.imageKey,
                                      fit: BoxFit.fill,
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: _CropPainter(
                                          widget.corners,
                                          widget.backgrounds,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          ..._tapLayer(width, height),
                          ..._cornerHandles(width, height),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_activeDragHandle != null && _loupeFocus != null)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Align(
                      key: const Key('crop-loupe-alignment'),
                      alignment: cropLoupeAlignment(_loupeFocus!),
                      child: IgnorePointer(
                        child: ValueListenableBuilder<Matrix4>(
                          valueListenable: _view,
                          builder: (context, matrix, _) => CropPrecisionLoupe(
                            key: const Key('crop-precision-loupe'),
                            preview: widget.source.preview,
                            corners: widget.corners,
                            focus: _loupeFocus!,
                            canvasSize: Size(width, height),
                            zoom: matrix.getMaxScaleOnAxis(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
  void _tapCanvas(Offset global, double width, double height) {
    final render = _canvasKey.currentContext!.findRenderObject()! as RenderBox;
    final local = render.globalToLocal(global);
    widget.onTap(
      Point2(
        (local.dx / width).clamp(0, 1).toDouble(),
        (local.dy / height).clamp(0, 1).toDouble(),
      ),
      manualTapMinSeparationPx / (width * _view.value.getMaxScaleOnAxis()),
    );
  }

  void _moveHandle(
    BoundaryHandle handle,
    Offset global,
    double width,
    double height,
  ) {
    final render = _canvasKey.currentContext!.findRenderObject()! as RenderBox;
    final local = render.globalToLocal(global);
    final focus = Point2(
      (local.dx / width).clamp(0.0, 1.0),
      (local.dy / height).clamp(0.0, 1.0),
    );
    final cornersBefore = widget.corners;
    final List<Point2> nextCorners;
    if (handle is CornerHandle) {
      nextCorners = [...cornersBefore]..[handle.index] = focus;
    } else {
      // An EDGE drag moves both of its endpoints by the same incremental
      // delta, preserving the edge's direction and length. The first update
      // only records the anchor, which also makes a stationary press on the
      // line harmless.
      final last = _dragLastLocal;
      if (last == null) {
        _dragLastLocal = local;
        return;
      }
      final dx = (local.dx - last.dx) / width;
      final dy = (local.dy - last.dy) / height;
      // Advance the anchor even when the resulting quad is refused, so a
      // blocked step never accumulates into a jump on the next update.
      _dragLastLocal = local;
      if (dx == 0 && dy == 0) return;
      final ends = edgeCorners(handle.index);
      final corners = [...cornersBefore];
      for (final index in [ends.first, ends.second]) {
        final point = corners[index];
        corners[index] = Point2(
          (point.x + dx).clamp(0.0, 1.0),
          (point.y + dy).clamp(0.0, 1.0),
        );
      }
      nextCorners = corners;
    }
    if (quadEdgesCross(nextCorners)) {
      widget.onRefused();
      return;
    }
    setState(() => _loupeFocus = focus);
    widget.onMove(nextCorners);
  }

  void _clearDragState() {
    _activeDragHandle = null;
    _dragLastLocal = null;
    _loupeFocus = null;
  }

  /// Tap-mode layer: a surface that receives taps, plus markers for the taps
  /// placed so far. Outside tap mode it contributes nothing.
  List<Widget> _tapLayer(double width, double height) {
    final selection = widget.taps;
    if (selection == null) return const [];
    return [
      Positioned(
        left: boundaryCanvasInsetPx,
        top: boundaryCanvasInsetPx,
        width: width,
        height: height,
        child: GestureDetector(
          key: const Key('crop-tap-surface'),
          behavior: HitTestBehavior.opaque,
          onTapUp: widget.busy
              ? null
              : (details) {
                  _tapCanvas(details.globalPosition, width, height);
                },
          child: const SizedBox.expand(),
        ),
      ),
      for (var i = 0; i < selection.length; i++)
        Positioned(
          left: boundaryCanvasInsetPx + selection[i].x * width - 12.0,
          top: boundaryCanvasInsetPx + selection[i].y * height - 12.0,
          child: _ScreenFixedSize(controller: _view, child: _tapMarker(i)),
        ),
    ];
  }

  /// The four draggable corners. Hidden in tap mode, where no corner exists
  /// until the fourth tap completes the quadrilateral.
  ///
  /// P6: the corners are visual only (IgnorePointer). Hits come from ONE
  /// geometric layer placed last, which selects the nearest corner inside a
  /// 32 px screen radius, otherwise the nearest edge inside an 18 px band,
  /// and lets the viewer pan everywhere else.
  List<Widget> _cornerHandles(double width, double height) {
    if (widget.taps != null || widget.corners.length != 4) return const [];
    final corners = widget.corners;
    return [
      for (var i = 0; i < 4; i++)
        Positioned(
          left: boundaryCanvasInsetPx + corners[i].x * width - 20,
          top: boundaryCanvasInsetPx + corners[i].y * height - 20,
          child: _ScreenFixedSize(
            controller: _view,
            child: IgnorePointer(child: _cornerVisual(i)),
          ),
        ),
      Positioned.fill(
        child: BoundaryHitLayer(
          corners: corners,
          canvasSize: Size(width, height),
          inset: boundaryCanvasInsetPx,
          zoom: () => _view.value.getMaxScaleOnAxis(),
          onDragStart: (handle) {
            widget.onDragStart?.call();
            _activeDragHandle = handle;
            _dragLastLocal = null;
            _loupeFocus = null;
          },
          onDragUpdate: (handle, global) {
            if (widget.busy) return;
            _moveHandle(handle, global, width, height);
          },
          onDragEnd: (_) {
            if (widget.busy) return;
            setState(_clearDragState);
            widget.onDragEnd?.call();
          },
          onDragCancel: (_) {
            if (widget.busy) return;
            setState(_clearDragState);
            widget.onDragCancel?.call();
          },
        ),
      ),
    ];
  }

  /// Visual of one corner. Its centre sits on the corner; the wrapper keeps the
  /// visible size constant under zoom. Input is handled by the hit layer.
  Widget _cornerVisual(int i) {
    return Semantics(
      label: 'زاوية القص ${i + 1}',
      child: Container(
        key: Key('crop-corner-$i'),
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xff12685e),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Text(
          '${i + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _tapMarker(int i) {
    return Container(
      key: Key('crop-tap-$i'),
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xff12685e),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Text(
        '${i + 1}',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter(this.points, this.backgrounds);
  final Map<int, List<Point2>> backgrounds;
  final List<Point2> points;
  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in backgrounds.entries) {
      final ring = entry.value;
      if (ring.isEmpty) continue;
      final path = Path()
        ..addPolygon([
          for (final p in ring) Offset(p.x * size.width, p.y * size.height),
        ], ring.length >= 3);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white70,
      );
      final label = TextPainter(
        text: TextSpan(
          text: '${entry.key}',
          style: const TextStyle(
            color: Colors.white,
            backgroundColor: Colors.black54,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(ring.first.x * size.width, ring.first.y * size.height),
      );
      label.dispose();
    }
    if (points.length != 4) return;
    final path = Path()
      ..moveTo(points[0].x * size.width, points[0].y * size.height);
    for (final p in points.skip(1)) {
      path.lineTo(p.x * size.width, p.y * size.height);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xff12685e).withValues(alpha: .15),
    );
    // A wide translucent band makes it clear that the WHOLE edge is draggable,
    // not just the four numbered circles.
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff12685e).withValues(alpha: .18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12,
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
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.backgrounds != backgrounds;
}

/// Keeps its child at a constant on-screen size inside an [InteractiveViewer]
/// by cancelling the viewer's current scale around the child's centre.
class _ScreenFixedSize extends StatelessWidget {
  const _ScreenFixedSize({required this.controller, required this.child});

  final TransformationController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, matrix, child) {
        return Transform.scale(
          scale: 1 / math.max(1, matrix.getMaxScaleOnAxis()),
          child: child,
        );
      },
      child: child,
    );
  }
}
