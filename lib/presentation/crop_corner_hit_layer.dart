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
  RenderCornerHitLayer createRenderObject(BuildContext context) {
    return RenderCornerHitLayer(
      corners: corners,
      canvasSize: canvasSize,
      inset: inset,
      zoom: zoom,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDragEnd: onDragEnd,
      onDragCancel: onDragCancel,
    );
  }

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
    // Accepts the pointer on touch-down, before the enclosing viewer's pan
    // recognizer can claim it, so a corner drag is never turned into a view
    // pan. A pointer outside every radius never reaches this recognizer.
    _multi = ImmediateMultiDragGestureRecognizer()..onStart = _startDrag;
  }

  late final ImmediateMultiDragGestureRecognizer _multi;
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

  Drag? _startDrag(Offset position) {
    final index = _activeIndex;
    if (index == null) return null;
    onDragStart(index);
    return _CornerDrag(this, index);
  }

  void _dragUpdated(int index, Offset globalPosition) {
    onDragUpdate(index, globalPosition);
  }

  void _dragEnded(int index) {
    _activeIndex = null;
    onDragEnd(index);
  }

  void _dragCancelled(int index) {
    _activeIndex = null;
    onDragCancel(index);
  }

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
    final w = canvasSize.width;
    final h = canvasSize.height;
    final centres = [
      for (final c in corners) Point2(inset + c.x * w, inset + c.y * h),
    ];
    if (!position.dx.isFinite || !position.dy.isFinite) return null;
    final point = Point2(position.dx, position.dy);
    final radius = cornerCaptureRadiusPx / scale;
    return nearestCornerIndex(centres, point, radius);
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
      _multi.addPointer(event);
    }
  }

  @override
  void dispose() {
    _multi.dispose();
    super.dispose();
  }
}

/// One corner drag. Forwards every pointer update to the layer, so the drag
/// does not depend on the slop-crossing move being delivered as an update.
class _CornerDrag extends Drag {
  _CornerDrag(this._layer, this._index);

  final RenderCornerHitLayer _layer;
  final int _index;

  @override
  void update(DragUpdateDetails details) {
    _layer._dragUpdated(_index, details.globalPosition);
  }

  @override
  void end(DragEndDetails details) {
    _layer._dragEnded(_index);
  }

  @override
  void cancel() {
    _layer._dragCancelled(_index);
  }
}

class _CornerHitEntry extends BoxHitTestEntry {
  _CornerHitEntry(super.target, super.localPosition, this.index);

  final int index;
}
