import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../application/contracts.dart';
import '../domain/project.dart';
import 'project_screen.dart';

/// One layout model for page display; only this view converts mm to logical px.
/// The image rectangle and its center rotation match the export contract.
class PageCanvas extends StatelessWidget {
  const PageCanvas({
    required this.project,
    required this.assets,
    required this.scale,
    this.selected = const {},
    this.onSelect,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.pageKey,
    this.showGuides = true,
    super.key,
  });
  final Project project;
  final AssetRepository assets;
  final double scale;
  final Set<String> selected;
  final void Function(String)? onSelect;
  final void Function(String, Offset, bool)? onDragStart;
  final void Function(Offset)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final GlobalKey? pageKey;
  final bool showGuides;
  @override
  Widget build(BuildContext context) {
    final items = [...project.items]
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));
    final area = project.paper.printable;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        key: pageKey,
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
                        border: Border.all(color: Colors.orange),
                      ),
                    ),
                  ),
                ),
              for (final item in items)
                Positioned(
                  left: item.x * scale,
                  top: item.y * scale,
                  width: item.width * scale,
                  height: item.height * scale,
                  child: Transform.rotate(
                    angle: item.rotation * math.pi / 180,
                    child: GestureDetector(
                      key: Key('page-item-${item.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onSelect == null ? null : () => onSelect!(item.id),
                      onPanStart: onDragStart == null || item.locked
                          ? null
                          : (d) =>
                                onDragStart!(item.id, d.globalPosition, false),
                      onPanUpdate: onDragUpdate == null || item.locked
                          ? null
                          : (d) => onDragUpdate!(d.globalPosition),
                      onPanEnd: onDragEnd == null || item.locked
                          ? null
                          : (_) => onDragEnd!(),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // The user controls aspect locking. Fill reflects the exact chosen mm rectangle.
                          FittedBox(
                            fit: BoxFit.fill,
                            child: SizedBox(
                              width: project.assets
                                  .firstWhere((a) => a.id == item.assetId)
                                  .width
                                  .toDouble(),
                              height: project.assets
                                  .firstWhere((a) => a.id == item.assetId)
                                  .height
                                  .toDouble(),
                              child: LocalImage(
                                repository: assets,
                                path: project.assets
                                    .firstWhere((a) => a.id == item.assetId)
                                    .thumbnailPath,
                                cacheWidth: 320,
                              ),
                            ),
                          ),
                          if (selected.contains(item.id))
                            IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.teal,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          if (item.locked && showGuides)
                            const Positioned(
                              left: 2,
                              top: 2,
                              child: Icon(
                                Icons.lock,
                                size: 16,
                                color: Colors.teal,
                              ),
                            ),
                          if (selected.contains(item.id) &&
                              !item.locked &&
                              onDragStart != null)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: GestureDetector(
                                key: Key('resize-${item.id}'),
                                behavior: HitTestBehavior.opaque,
                                onPanStart: (d) => onDragStart!(
                                  item.id,
                                  d.globalPosition,
                                  true,
                                ),
                                onPanUpdate: (d) =>
                                    onDragUpdate!(d.globalPosition),
                                onPanEnd: (_) => onDragEnd!(),
                                child: const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: ColoredBox(
                                    color: Colors.teal,
                                    child: Icon(
                                      Icons.open_in_full,
                                      size: 18,
                                      color: Colors.white,
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
            ],
          ),
        ),
      ),
    );
  }
}
