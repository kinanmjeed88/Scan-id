import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../domain/geometry.dart';
import 'boundary_handle.dart';

/// Geometric input for the four corners and four edges of a crop boundary.
///
/// Only a real handle is hit; empty space remains available to the enclosing
/// [InteractiveViewer] for panning and pinching. Every accepted pointer owns a
/// separate recognizer, so a second finger cannot overwrite the active handle.
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

  /// Current viewer scale, read lazily so capture targets remain screen-sized.
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
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  }) : _corners = corners,
       _canvasSize = canvasSize,
       _inset = inset,
       _zoom = zoom;

  final Map<int, _BoundaryGestureRecognizer> _recognizers = {};

  List<Point2> get corners => _corners;
  List<Point2> _corners;
  set corners(List<Point2> value) {
    if (_samePoints(_corners, value)) return;
    _corners = value;
  }

  Size get canvasSize => _canvasSize;
  Size _canvasSize;
  set canvasSize(Size value) {
    if (_canvasSize == value) return;
    _canvasSize = value;
  }

  double get inset => _inset;
  double _inset;
  set inset(double value) => _inset = value;

  double Function() _zoom;
  set zoom(double Function() value) => _zoom = value;

  void Function(BoundaryHandle handle) onDragStart;
  void Function(BoundaryHandle handle, Offset globalPosition) onDragUpdate;
  void Function(BoundaryHandle handle) onDragEnd;
  void Function(BoundaryHandle handle) onDragCancel;

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
  /// capture region. Screen-pixel sizes are divided by the viewer scale.
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
    if (!size.contains(position)) return false;
    final handle = handleAt(position);
    if (handle == null) return false;
    result.add(_BoundaryHitEntry(this, position, handle));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, covariant HitTestEntry entry) {
    if (entry is! _BoundaryHitEntry || event is! PointerDownEvent) return;
    // Do not replace a live pointer if a framework replay delivers its down
    // event twice. Each physical pointer has exactly one owner for its lifetime.
    if (_recognizers.containsKey(event.pointer)) return;
    final recognizer = _BoundaryGestureRecognizer(this, entry.handle);
    _recognizers[event.pointer] = recognizer;
    recognizer.addAllowedPointer(event);
  }

  void _releaseRecognizer(int pointer, _BoundaryGestureRecognizer recognizer) {
    if (!identical(_recognizers[pointer], recognizer)) return;
    _recognizers.remove(pointer);
    recognizer.dispose();
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }
}

/// A pointer-specific recognizer that wins immediately only after geometric
/// hit testing has found a handle. This avoids the shared pending-handle queue
/// and the gesture-arena race of the previous multi-drag implementation.
class _BoundaryGestureRecognizer extends OneSequenceGestureRecognizer {
  _BoundaryGestureRecognizer(this._layer, this._handle);

  final RenderBoundaryHitLayer _layer;
  final BoundaryHandle _handle;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _layer.onDragStart(_handle);
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _layer.onDragUpdate(_handle, event.position);
    } else if (event is PointerUpEvent) {
      _layer.onDragEnd(_handle);
      stopTrackingPointer(event.pointer);
      _layer._releaseRecognizer(event.pointer, this);
    } else if (event is PointerCancelEvent) {
      _layer.onDragCancel(_handle);
      stopTrackingPointer(event.pointer);
      _layer._releaseRecognizer(event.pointer, this);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'crop-boundary';
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
