import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../domain/geometry.dart';
import 'boundary_handle.dart';

/// One geometric hit region for the four corners AND the four edges of a crop
/// boundary.
///
/// Hit testing happens in one pass, in the viewer's CONTENT coordinates:
/// a corner wins inside [cornerCaptureRadiusPx], otherwise the nearest edge
/// inside [edgeCaptureWidthPx] is selected. A pointer outside every region is
/// not hit at all, so the enclosing [InteractiveViewer] keeps panning.
///
/// The layer owns an [ImmediateMultiDragGestureRecognizer] that accepts the
/// pointer on touch-down, before the viewer's pan recognizer can claim it. The
/// handle is attached to the pointer at HIT-TEST time (where coordinates are
/// unambiguous) instead of being recomputed from a global drag position, and
/// each drag carries its own handle. That removes the shared single-pointer
/// field which used to be overwritten by a second touch mid-gesture.
///
/// Coordinates: [corners] are normalized (0..1) on the canvas; the canvas sits
/// at [inset] inside this layer's coordinate space.
class BoundaryHitLayer extends LeafRenderObjectWidget {
  const BoundaryHitLayer({
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

  /// Current viewer scale, read through a callback so the capture regions stay
  /// in SCREEN pixels without rebuilding on every zoom step.
  final double Function() zoom;

  final void Function(BoundaryHandle handle) onDragStart;
  final void Function(BoundaryHandle handle, Offset globalPosition)
  onDragUpdate;
  final void Function(BoundaryHandle handle) onDragEnd;
  final void Function(BoundaryHandle handle) onDragCancel;

  @override
  RenderBoundaryHitLayer createRenderObject(BuildContext context) =>
      RenderBoundaryHitLayer(
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
    covariant RenderBoundaryHitLayer renderObject,
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

class RenderBoundaryHitLayer extends RenderBox {
  RenderBoundaryHitLayer({
    required List<Point2> corners,
    required Size canvasSize,
    required double inset,
    required double Function() zoom,
    required void Function(BoundaryHandle handle) onDragStart,
    required void Function(BoundaryHandle handle, Offset globalPosition)
    onDragUpdate,
    required void Function(BoundaryHandle handle) onDragEnd,
    required void Function(BoundaryHandle handle) onDragCancel,
  }) : _corners = corners,
       _canvasSize = canvasSize,
       _inset = inset,
       _zoom = zoom,
       onDragStart = onDragStart,
       onDragUpdate = onDragUpdate,
       onDragEnd = onDragEnd,
       onDragCancel = onDragCancel {
    _multi = ImmediateMultiDragGestureRecognizer()..onStart = _startDrag;
  }

  late final ImmediateMultiDragGestureRecognizer _multi;

  /// Handles claimed by a pointer down but not yet handed to its drag. An
  /// immediate recognizer starts each drag synchronously, in pointer-down
  /// order, so this queue stays at most one entry deep in ordinary use.
  final Queue<BoundaryHandle> _pending = Queue<BoundaryHandle>();

  List<Point2> get corners => _corners;
  List<Point2> _corners;
  set corners(List<Point2> value) {
    if (_samePoints(_corners, value)) return;
    _corners = value;
    markNeedsPaint();
  }

  Size get canvasSize => _canvasSize;
  Size _canvasSize;
  set canvasSize(Size value) {
    if (_canvasSize == value) return;
    _canvasSize = value;
    markNeedsPaint();
  }

  double get inset => _inset;
  double _inset;
  set inset(double value) {
    if (_inset == value) return;
    _inset = value;
    markNeedsPaint();
  }

  double Function() _zoom;
  set zoom(double Function() value) => _zoom = value;

  void Function(BoundaryHandle handle) onDragStart;
  void Function(BoundaryHandle handle, Offset globalPosition) onDragUpdate;
  void Function(BoundaryHandle handle) onDragEnd;
  void Function(BoundaryHandle handle) onDragCancel;

  Drag? _startDrag(Offset _) {
    if (_pending.isEmpty) return null;
    final handle = _pending.removeFirst();
    onDragStart(handle);
    return _BoundaryDrag(this, handle);
  }

  void _dragUpdated(BoundaryHandle handle, Offset globalPosition) =>
      onDragUpdate(handle, globalPosition);

  void _dragEnded(BoundaryHandle handle) => onDragEnd(handle);

  void _dragCancelled(BoundaryHandle handle) => onDragCancel(handle);

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  /// Content-space corner centres. Kept public for widget tests.
  List<Point2> cornerCentres() {
    final w = canvasSize.width;
    final h = canvasSize.height;
    return [for (final c in corners) Point2(inset + c.x * w, inset + c.y * h)];
  }

  /// The handle under a CONTENT-space [position], or null outside every
  /// capture region. Screen-pixel sizes are divided by the viewer scale so
  /// zooming never shrinks the touch targets.
  BoundaryHandle? handleAt(Offset position) {
    if (!position.dx.isFinite || !position.dy.isFinite) return null;
    final rawZoom = _zoom();
    final scale = rawZoom.isFinite && rawZoom > 0 ? rawZoom : 1.0;
    return boundaryHandleAt(
      cornerCentres(),
      Point2(position.dx, position.dy),
      cornerRadius: cornerCaptureRadiusPx / scale,
      edgeWidth: edgeCaptureWidthPx / scale,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // The default RenderBox implementation bounds the hit to this box. Keep
    // that contract explicitly: a corner near the edge must not capture a
    // pointer that actually landed outside the canvas.
    if (!size.contains(position)) return false;
    final handle = handleAt(position);
    if (handle == null) return false;
    result.add(_BoundaryHitEntry(this, position, handle));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, covariant HitTestEntry entry) {
    if (entry is! _BoundaryHitEntry) return;
    if (event is PointerDownEvent) {
      _pending.add(entry.handle);
      _multi.addPointer(event);
    } else if (event is PointerCancelEvent && _pending.isNotEmpty) {
      // A pointer that was never accepted must not leave a stale handle for a
      // later drag.
      _pending.remove(entry.handle);
    }
  }

  @override
  void dispose() {
    _multi.dispose();
    _pending.clear();
    super.dispose();
  }
}

class _BoundaryDrag extends Drag {
  _BoundaryDrag(this._layer, this._handle);

  final RenderBoundaryHitLayer _layer;
  final BoundaryHandle _handle;

  @override
  void update(DragUpdateDetails details) {
    _layer._dragUpdated(_handle, details.globalPosition);
  }

  @override
  void end(DragEndDetails details) => _layer._dragEnded(_handle);

  @override
  void cancel() => _layer._dragCancelled(_handle);
}

class _BoundaryHitEntry extends BoxHitTestEntry {
  _BoundaryHitEntry(super.target, super.localPosition, this.handle);

  final BoundaryHandle handle;
}

bool _samePoints(List<Point2> a, List<Point2> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].x != b[i].x || a[i].y != b[i].y) return false;
  }
  return true;
}
