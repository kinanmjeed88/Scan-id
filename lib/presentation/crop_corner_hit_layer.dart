import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../domain/geometry.dart';

/// Capture radius of a corner, in SCREEN logical pixels. Independent of zoom:
/// the radius is divided by the viewer scale inside the layout coordinates.
const double cornerCaptureRadiusPx = 24;

/// One geometric hit region for all four crop corners (P6).
///
/// The previous design put four opaque `GestureDetector`s on top of each other,
/// so overlap was resolved by child order rather than by distance. This layer
/// instead answers a hit only when a pointer lies within
/// [cornerCaptureRadiusPx] of a corner, and then selects the NEAREST corner
/// (lowest index on exact ties, via [nearestCornerIndex]). A pointer outside
/// every radius is not hit at all, so the enclosing [InteractiveViewer] keeps
/// panning.
///
/// Coordinates: [corners] are normalized (0..1) on the canvas; the canvas sits
/// at [inset] inside this layer's coordinate space, which is the coordinate
/// space hit tests use (already transformed by the viewer).
class CornerHitLayer extends LeafRenderObjectWidget {
  const CornerHitLayer({
    super.key,
    required this.corners,
    required this.canvasSize,
    required this.inset,
    required this.zoom,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final List<Point2> corners;
  final Size canvasSize;
  final double inset;

  /// Current viewer scale, read at hit-test time through a callback so the
  /// radius stays in screen pixels without rebuilding on every zoom step.
  final double Function() zoom;

  final ValueChanged<int> onDragStart;
  final void Function(int index, Offset globalPosition) onDragUpdate;
  final ValueChanged<int> onDragEnd;
  final ValueChanged<int> onDragCancel;

  @override
  RenderCornerHitLayer createRenderObject(BuildContext context) =>
      RenderCornerHitLayer(
        corners: corners,
        canvasSize: canvasSize,
        inset: inset,
        zoom: zoom,
        onDragStart: onDragStart,
        onDragUpdate: onDragUpdate,
        onDragEnd: onDragEnd,
        onDragCancel: onDragCancel,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderCornerHitLayer renderObject,
  ) {
    renderObject
      ..corners = corners
      ..canvasSize = canvasSize
      ..inset = inset
      ..zoom = zoom
      ..onDragStart = onDragStart
      ..onDragUpdate = onDragUpdate
      ..onDragEnd = onDragEnd
      ..onDragCancel = onDragCancel;
  }
}

class RenderCornerHitLayer extends RenderBox {
  RenderCornerHitLayer({
    required this.corners,
    required this.canvasSize,
    required this.inset,
    required this.zoom,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  }) {
    _pan = PanGestureRecognizer(debugOwner: this)
      ..onStart = (_) {
        final index = _activeIndex;
        if (index != null) onDragStart(index);
      }
      ..onUpdate = (details) {
        final index = _activeIndex;
        if (index != null) onDragUpdate(index, details.globalPosition);
      }
      ..onEnd = (_) {
        final index = _activeIndex;
        _activeIndex = null;
        if (index != null) onDragEnd(index);
      }
      ..onCancel = () {
        final index = _activeIndex;
        _activeIndex = null;
        if (index != null) onDragCancel(index);
      };
  }

  late final PanGestureRecognizer _pan;
  int? _activeIndex;

  // Mutable so the owning widget can update them without recreating the box.
  List<Point2> corners;
  Size canvasSize;
  double inset;
  double Function() zoom;
  ValueChanged<int> onDragStart;
  void Function(int index, Offset globalPosition) onDragUpdate;
  ValueChanged<int> onDragEnd;
  ValueChanged<int> onDragCancel;

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  /// Index of the corner to capture for [position], or null outside all
  /// radii. The radius is measured in content units, i.e. screen pixels
  /// divided by the current zoom.
  int? cornerAt(Offset position) {
    final rawZoom = zoom();
    final scale = rawZoom.isFinite && rawZoom > 0 ? rawZoom : 1.0;
    final centres = [
      for (final c in corners)
        Point2(
          inset + c.x * canvasSize.width,
          inset + c.y * canvasSize.height,
        ),
    ];
    if (!position.dx.isFinite || !position.dy.isFinite) return null;
    return nearestCornerIndex(
      centres,
      Point2(position.dx, position.dy),
      cornerCaptureRadiusPx / scale,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final index = cornerAt(position);
    if (index == null) return false;
    result.add(_CornerHitEntry(this, position, index));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, covariant HitTestEntry entry) {
    if (event is PointerDownEvent && entry is _CornerHitEntry) {
      _activeIndex = entry.index;
      _pan.addPointer(event);
    }
  }

  @override
  void dispose() {
    _pan.dispose();
    super.dispose();
  }
}

class _CornerHitEntry extends BoxHitTestEntry {
  _CornerHitEntry(super.target, super.localPosition, this.index);

  final int index;
}
