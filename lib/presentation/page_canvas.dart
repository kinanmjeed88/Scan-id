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
    this.toggleSelection = false,
    super.key,
  });

  final Project project;
  final AssetRepository assets;

  /// Logical pixels per millimetre.
  final double scale;
  final int pageIndex;
  final bool highQuality;
  final Set<String> selected;

  /// Called with `toggle: true` for Ctrl/Shift-clicks and, with
  /// [toggleSelection], for every tap.
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

  /// Multi-selection mode for touch screens: a tap or press adds the document
  /// to the selection or removes it, as Ctrl/Shift-click does with a mouse,
  /// and does not move it. Resize handles keep working.
  final bool toggleSelection;

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
          child: RawGestureDetector(
            key: Key('page-item-${item.id}'),
            behavior: HitTestBehavior.opaque,
            gestures: _documentGestures(
              item.id,
              selected: isSelected,
              draggable: draggable,
            ),
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
                        gestures: {
                          _DocumentPanGestureRecognizer: _pan(
                            item.id,
                            resize: true,
                            eager: true,
                            devices: _selectedDragDevices,
                          ),
                        },
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

  /// Whether a tap or press adds/removes a document instead of replacing the
  /// selection: Ctrl/Shift held, or the touch multi-selection mode.
  bool get _toggling {
    final keys = HardwareKeyboard.instance;
    return toggleSelection || keys.isControlPressed || keys.isShiftPressed;
  }

  /// A toggling press on a document changes the selection instead of moving
  /// the document.
  void _start(String id, Offset global, {required bool resize}) {
    if (!resize && _toggling) {
      onSelect?.call(id, toggle: true);
      return;
    }
    onDragStart?.call(id, global, resize: resize);
  }

  /// The gestures of one document. The same recognizers serve it selected
  /// and unselected, only their settings change, so a drag that selects the
  /// document keeps running through the rebuild instead of being dropped.
  ///
  /// * Not selected: a tap selects it. Only a mouse drags it directly, as in
  ///   Word; on touch and stylus screens the swipe scrolls the pages.
  /// * Selected: the document claims the press at once, so it follows the
  ///   finger, pen or mouse instead of the pages scrolling.
  /// * Locked: never dragged; a swipe over it scrolls the pages.
  ///
  /// A touchpad's two-finger swipe is a pan/zoom gesture and always scrolls
  /// (a touchpad click-and-drag arrives as a mouse).
  Map<Type, GestureRecognizerFactory> _documentGestures(
    String id, {
    required bool selected,
    required bool draggable,
  }) {
    final select = onSelect;
    return {
      TapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            TapGestureRecognizer.new,
            (recognizer) {
              // A selected, movable document answers presses with its pan.
              recognizer.onTap = select == null || (selected && draggable)
                  ? null
                  : () => select(id, toggle: _toggling);
            },
          ),
      _DocumentPanGestureRecognizer: _pan(
        id,
        resize: false,
        eager: selected,
        devices: !draggable
            ? const {}
            : selected
            ? _selectedDragDevices
            : _unselectedDragDevices,
      ),
    };
  }

  GestureRecognizerFactory _pan(
    String id, {
    required bool resize,
    required bool eager,
    required Set<PointerDeviceKind> devices,
  }) => GestureRecognizerFactoryWithHandlers<_DocumentPanGestureRecognizer>(
    _DocumentPanGestureRecognizer.new,
    (recognizer) {
      recognizer.eager = eager;
      recognizer.devices = devices;
      recognizer.onStart = (d) => _start(id, d.globalPosition, resize: resize);
      recognizer.onUpdate = (d) => onDragUpdate?.call(d.globalPosition);
      recognizer.onEnd = (_) => onDragEnd?.call();
      recognizer.onCancel = () => onDragCancel?.call();
    },
  );
}

/// Pointers that drag a selected document: fingers, pens and the mouse.
const _selectedDragDevices = {
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.mouse,
};

/// Pointers that drag a document that is not selected yet.
const _unselectedDragDevices = {PointerDeviceKind.mouse};

/// The pan of one document. Its settings follow the selection while one
/// instance lives as long as the document's widget, so a running drag
/// survives the rebuild its own start causes.
class _DocumentPanGestureRecognizer extends PanGestureRecognizer {
  /// Accept the drag on pointer-down instead of waiting for the pan slop.
  bool eager = false;

  /// Pointer kinds that may start a drag; empty for a locked document.
  Set<PointerDeviceKind> devices = const {};

  @override
  bool isPointerAllowed(PointerEvent event) =>
      devices.contains(event.kind) && super.isPointerAllowed(event);

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) =>
      devices.contains(event.kind) && super.isPointerPanZoomAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (eager) resolvePointer(event.pointer, GestureDisposition.accepted);
  }
}
