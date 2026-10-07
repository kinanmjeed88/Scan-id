import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/contracts.dart';
import '../domain/document_kind.dart';
import '../domain/project.dart';
import 'project_screen.dart';

/// Builds the picture of one document; lets the editor substitute a live,
/// not-yet-saved rendering for the selected document.
typedef DocumentImageBuilder =
    Widget? Function(ImageAsset asset, DocumentItem item);

/// One A4 page. The only place that converts millimetres to logical pixels;
/// the image rectangle and its centre rotation match the export contract.
class PageCanvas extends StatelessWidget {
  const PageCanvas({
    required this.project,
    required this.assets,
    required this.scale,
    this.selected = const {},
    this.pageIndex = 0,
    this.highQuality = false,
    this.onSelect,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
    this.imageBuilder,
    this.showGuides = true,
    super.key,
  });

  final Project project;
  final AssetRepository assets;

  /// Logical pixels per millimetre.
  final double scale;
  final int pageIndex;
  final bool highQuality;
  final Set<String> selected;

  /// Called with `toggle: true` for Ctrl/Shift-clicks.
  final void Function(String id, {bool toggle})? onSelect;

  /// Global pointer position where a move ([resize] false) or a resize
  /// through the corner handle starts.
  final void Function(String id, Offset global, {required bool resize})?
  onDragStart;

  /// Current global pointer position of the running drag.
  final void Function(Offset global)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDragCancel;
  final DocumentImageBuilder? imageBuilder;
  final bool showGuides;

  String _itemLabel(DocumentItem item, ImageAsset? asset) => asset == null
      ? 'مستمسك بلا صورة'
      : '${item.documentKind.label}: ${asset.name}';

  @override
  Widget build(BuildContext context) {
    final items = project.items.where((e) => e.pageIndex == pageIndex).toList()
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));
    final area = project.paper.printable;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: project.paper.width * scale,
        height: project.paper.height * scale,
        child: ColoredBox(
          color: Colors.white,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              if (showGuides)
                Positioned(
                  left: area.x * scale,
                  top: area.y * scale,
                  width: area.width * scale,
                  height: area.height * scale,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: .7),
                        ),
                      ),
                    ),
                  ),
                ),
              for (final item in items) _item(context, item),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, DocumentItem item) {
    final asset = project.assets.where((a) => a.id == item.assetId).firstOrNull;
    final isSelected = selected.contains(item.id);
    final draggable = onDragStart != null && !item.locked;
    return Positioned(
      key: ValueKey('page-slot-${item.id}'),
      left: item.x * scale,
      top: item.y * scale,
      width: item.width * scale,
      height: item.height * scale,
      child: Transform.rotate(
        angle: item.rotation * math.pi / 180,
        child: Semantics(
          container: true,
          selected: isSelected,
          label: _itemLabel(item, asset),
          value:
              '${item.width.toStringAsFixed(1)} في ${item.height.toStringAsFixed(1)} مم'
              '${item.locked ? '، مثبت' : ''}',
          child: _gestures(
            item: item,
            selectedAndDraggable: isSelected && draggable,
            draggable: draggable,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The picture fills the exact millimetre rectangle.
                if (asset != null)
                  imageBuilder?.call(asset, item) ??
                      FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox(
                          width: asset.width.toDouble(),
                          height: asset.height.toDouble(),
                          child: LocalImage(
                            repository: assets,
                            path: highQuality
                                ? asset.workingPath
                                : asset.thumbnailPath,
                            cacheWidth: highQuality ? 1800 : 480,
                          ),
                        ),
                      ),
                if (isSelected)
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                if (item.locked && showGuides)
                  const Positioned(
                    left: 2,
                    top: 2,
                    child: Icon(Icons.lock, size: 16, color: Colors.teal),
                  ),
                if (isSelected && draggable)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Semantics(
                      button: true,
                      label: 'مقبض تغيير حجم العنصر',
                      child: RawGestureDetector(
                        key: Key('resize-${item.id}'),
                        behavior: HitTestBehavior.opaque,
                        gestures: _eagerPan(item.id, resize: true),
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: ColoredBox(
                            color: Theme.of(context).colorScheme.primary,
                            child: const Icon(
                              Icons.open_in_full,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
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

  /// Ctrl/Shift-press on a selected document toggles it instead of moving it.
  void _start(String id, Offset global, {required bool resize}) {
    final keys = HardwareKeyboard.instance;
    if (!resize && (keys.isControlPressed || keys.isShiftPressed)) {
      onSelect?.call(id, toggle: true);
      return;
    }
    onDragStart?.call(id, global, resize: resize);
  }

  /// A selected document (and its resize handle) claims the pointer at once,
  /// so dragging it moves it instead of scrolling the pages on touch screens.
  Map<Type, GestureRecognizerFactory> _eagerPan(
    String id, {
    required bool resize,
  }) => {
    _EagerPanGestureRecognizer:
        GestureRecognizerFactoryWithHandlers<_EagerPanGestureRecognizer>(
          _EagerPanGestureRecognizer.new,
          (recognizer) {
            recognizer.onStart = (d) =>
                _start(id, d.globalPosition, resize: resize);
            recognizer.onUpdate = (d) => onDragUpdate?.call(d.globalPosition);
            recognizer.onEnd = (_) => onDragEnd?.call();
            recognizer.onCancel = () => onDragCancel?.call();
          },
        ),
  };

  Widget _gestures({
    required DocumentItem item,
    required bool selectedAndDraggable,
    required bool draggable,
    required Widget child,
  }) {
    if (selectedAndDraggable) {
      return RawGestureDetector(
        key: Key('page-item-${item.id}'),
        behavior: HitTestBehavior.opaque,
        gestures: _eagerPan(item.id, resize: false),
        child: child,
      );
    }
    return GestureDetector(
      key: Key('page-item-${item.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: onSelect == null
          ? null
          : () {
              final keys = HardwareKeyboard.instance;
              onSelect!(
                item.id,
                toggle: keys.isControlPressed || keys.isShiftPressed,
              );
            },
      onPanStart: draggable
          ? (d) => _start(item.id, d.globalPosition, resize: false)
          : null,
      onPanUpdate: draggable
          ? (d) => onDragUpdate?.call(d.globalPosition)
          : null,
      onPanEnd: draggable ? (_) => onDragEnd?.call() : null,
      onPanCancel: draggable ? () => onDragCancel?.call() : null,
      child: child,
    );
  }
}

/// Accepts the drag on pointer-down instead of waiting for the slop.
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  _EagerPanGestureRecognizer({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolvePointer(event.pointer, GestureDisposition.accepted);
  }
}
