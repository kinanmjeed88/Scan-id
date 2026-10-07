import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/document_kind.dart';
import '../domain/project.dart';
import 'editor_controller.dart';
import 'page_canvas.dart';
import 'project_screen.dart';
import 'shortcuts.dart';

/// Logical pixels per millimetre at 100 % zoom (96 dpi).
const pixelsPerMm = 96 / 25.4;

const _pageGap = 24.0;
const _sideMargin = 24.0;

/// Pages stacked vertically like Word's print layout, with zoom, drag and
/// keyboard nudging. The selected document is painted live from the
/// controller's colour-neutral base and a GPU colour matrix while its picture
/// sliders move.
class SheetView extends StatefulWidget {
  const SheetView({required this.controller, super.key});

  final LayoutEditorController controller;

  @override
  State<SheetView> createState() => _SheetViewState();
}

class _SheetViewState extends State<SheetView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _focus = FocusNode(debugLabel: 'sheet');
  Offset? _dragOrigin;
  double _scale = pixelsPerMm;
  double _extent = 1;

  final _pointers = <int, Offset>{};
  double? _pinchDistance;
  double? _pinchZoom;

  LayoutEditorController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _vertical.addListener(_reportPage);
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _reportPage() {
    if (!_vertical.hasClients) return;
    final position = _vertical.position;
    final probe = position.pixels + position.viewportDimension * .35;
    _c.reportVisiblePage((probe / _extent).floor());
  }

  void _scrollToPending() {
    final page = _c.pendingScrollPage;
    if (page == null || !_vertical.hasClients) return;
    _c.pendingScrollPage = null;
    final target = (page * _extent).clamp(
      0.0,
      _vertical.position.maxScrollExtent,
    );
    _vertical.jumpTo(target);
  }

  double _scaleFor(PaperSettings paper, BoxConstraints box) {
    final width = math.max(1.0, box.maxWidth - 2 * _sideMargin);
    final height = math.max(1.0, box.maxHeight - 2 * _pageGap);
    return switch (_c.zoomMode) {
      ZoomMode.custom => _c.zoom * pixelsPerMm,
      ZoomMode.pageWidth => width / paper.width,
      ZoomMode.wholePage => math.min(
        width / paper.width,
        height / paper.height,
      ),
    };
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (event.scrollDelta.dy < 0) {
        _c.zoomIn();
      } else if (event.scrollDelta.dy > 0) {
        _c.zoomOut();
      }
    });
  }

  void _pointerDown(PointerDownEvent event) {
    _focus.requestFocus();
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) {
      final points = _pointers.values.toList();
      _pinchDistance = (points[0] - points[1]).distance;
      _pinchZoom = _c.zoom;
      if (_c.dragging) _c.cancelDrag();
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    final start = _pinchDistance, zoom = _pinchZoom;
    if (_pointers.length == 2 && start != null && zoom != null && start > 0) {
      final points = _pointers.values.toList();
      _c.setZoom(zoom * (points[0] - points[1]).distance / start);
    }
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _pinchDistance = null;
      _pinchZoom = null;
    }
  }

  Widget? _liveImage(ImageAsset asset, DocumentItem item) {
    if (_c.activeAsset?.id != asset.id) return null;
    final base = _c.liveBaseFor(asset);
    if (base == null) return null;
    return ColorFiltered(
      key: const ValueKey('live-preview'),
      colorFilter: ColorFilter.matrix(_c.adjustmentsFor(asset).colorMatrix),
      child: Image.memory(
        base,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = _c.project;
    return ColoredBox(
      color: const Color(0xffe3e6ea),
      child: LayoutBuilder(
        builder: (context, box) {
          _scale = _scaleFor(project.paper, box);
          _c.reportEffectiveZoom(_scale / pixelsPerMm);
          final pageWidth = project.paper.width * _scale;
          final pageHeight = project.paper.height * _scale;
          _extent = pageHeight + _pageGap;
          final contentWidth = math.max(
            box.maxWidth,
            pageWidth + 2 * _sideMargin,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollToPending();
          });
          return Listener(
            onPointerSignal: _onPointerSignal,
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerUp,
            onPointerCancel: _pointerUp,
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: (_, event) => canvasArrowKeys(
                event,
                _c.nudge,
                enabled: _c.active != null && !_c.busy,
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _c.clearSelection,
                child: Scrollbar(
                  controller: _horizontal,
                  notificationPredicate: (n) => n.depth == 0,
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: contentWidth,
                      height: box.maxHeight,
                      child: Scrollbar(
                        controller: _vertical,
                        child: ListView.builder(
                          key: const Key('sheet-pages'),
                          controller: _vertical,
                          padding: const EdgeInsets.only(top: _pageGap / 2),
                          itemExtent: _extent,
                          itemCount: project.pageCount,
                          itemBuilder: (context, index) => Align(
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: _pageGap),
                              child: _page(project, index, pageWidth),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _page(Project project, int index, double pageWidth) => Material(
    key: Key('sheet-page-$index'),
    elevation: 2,
    color: Colors.white,
    child: IgnorePointer(
      ignoring: _c.busy,
      child: PageCanvas(
        project: project,
        pageIndex: index,
        assets: _c.service.assets,
        scale: _scale,
        selected: _c.selected,
        showGuides: _c.showGuides,
        imageBuilder: _liveImage,
        onSelect: (id, {toggle = false}) {
          _c.select(id, toggle: toggle);
          _focus.requestFocus();
        },
        onDragStart: (id, global, {required resize}) {
          if (_pointers.length > 1) return;
          _dragOrigin = global;
          _c.startDrag(id, resize: resize);
        },
        onDragUpdate: (global) {
          final origin = _dragOrigin;
          if (origin == null || _pointers.length > 1) return;
          _c.updateDrag((global - origin) / _scale);
        },
        onDragEnd: () {
          _dragOrigin = null;
          unawaited(_c.endDrag());
        },
        onDragCancel: () {
          _dragOrigin = null;
          _c.cancelDrag();
        },
      ),
    ),
  );
}

/// Bottom bar: page position, document counts, save state and zoom — the
/// Word status bar.
class EditorStatusBar extends StatelessWidget {
  const EditorStatusBar({required this.controller, super.key});

  final LayoutEditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final project = c.project;
    final scheme = Theme.of(context).colorScheme;
    final awaiting = project.items
        .where((e) => e.pageIndex == null && !e.sizeConfirmed)
        .length;
    final tooBig = project.items
        .where((e) => e.pageIndex == null && e.sizeConfirmed)
        .length;
    const style = TextStyle(fontSize: 12);
    final info = <Widget>[
      PopupMenuButton<int>(
        key: const Key('status-page'),
        tooltip: 'الانتقال إلى صفحة',
        onSelected: c.goToPage,
        itemBuilder: (_) => [
          for (var i = 0; i < project.pageCount; i++)
            PopupMenuItem(value: i, child: Text('الصفحة ${i + 1}')),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'الصفحة ${c.visiblePage + 1} من ${project.pageCount}',
            style: style,
          ),
        ),
      ),
      _divider(scheme),
      Text('${project.items.length} مستمسك', style: style),
      if (awaiting > 0) ...[
        _divider(scheme),
        Text(
          '$awaiting بانتظار تحديد النوع',
          style: style.copyWith(color: scheme.error),
        ),
      ],
      if (tooBig > 0) ...[
        _divider(scheme),
        Text(
          '$tooBig لا يتسع للورقة',
          style: style.copyWith(color: scheme.error),
        ),
      ],
      _divider(scheme),
      Text(
        c.busy ? 'جارٍ الحفظ…' : 'محفوظ',
        key: const Key('status-saved'),
        style: style,
      ),
      if (c.autoFlow) ...[
        _divider(scheme),
        const Text('ترتيب مستمر', style: style),
      ],
    ];
    return Material(
      color: scheme.surfaceContainer,
      child: SizedBox(
        height: 36,
        child: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: info),
                ),
              ),
              IconButton(
                key: const Key('status-zoom-out'),
                tooltip: 'تصغير',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: c.zoom > minZoom ? c.zoomOut : null,
                icon: const Icon(Icons.remove),
              ),
              if (box.maxWidth >= 560)
                SizedBox(
                  width: 120,
                  child: Slider(
                    key: const Key('status-zoom'),
                    value: c.zoom.clamp(minZoom, maxZoom).toDouble(),
                    min: minZoom,
                    max: maxZoom,
                    onChanged: c.setZoom,
                  ),
                ),
              IconButton(
                key: const Key('status-zoom-in'),
                tooltip: 'تكبير',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: c.zoom < maxZoom ? c.zoomIn : null,
                icon: const Icon(Icons.add),
              ),
              SizedBox(
                width: 44,
                child: Text('${(c.zoom * 100).round()}%', style: style),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _divider(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: SizedBox(
      height: 16,
      child: VerticalDivider(width: 1, color: scheme.outlineVariant),
    ),
  );
}

/// Documents that are not on any page: waiting for a category, or too large.
class OffSheetTray extends StatelessWidget {
  const OffSheetTray({required this.controller, super.key});

  final LayoutEditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final items = c.offSheet;
    if (items.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer.withValues(alpha: .35),
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'خارج الورق (${items.length})',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: InkWell(
                        key: Key('offsheet-${item.id}'),
                        onTap: () => c.select(item.id),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: c.selected.contains(item.id)
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              width: c.selected.contains(item.id) ? 2 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 44,
                                height: 40,
                                child: LocalImage(
                                  repository: c.service.assets,
                                  path: c.assetOf(item).thumbnailPath,
                                  cacheWidth: 120,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.documentKind.label,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    item.sizeConfirmed
                                        ? 'أكبر من مساحة الطباعة'
                                        : 'اختر النوع من «المستمسك»',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.error,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
