import 'dart:math' as math;

import 'document_kind.dart';
import 'geometry.dart';
import 'packing.dart';
import 'project.dart';

/// Largest number of pages automatic arrangement may create.
const maxArrangedPages = 100;

const _eps = 1e-7;

/// Outcome of [arrangeDocuments]. Sizes never change; only positions, page
/// numbers and (when allowed) a 90° turn.
class ArrangementResult {
  ArrangementResult(
    this.original,
    this.result, {
    required List<String> unplaced,
    required List<String> awaitingSize,
  }) : unplaced = List.unmodifiable(unplaced),
       awaitingSize = List.unmodifiable(awaitingSize);

  final Project original;
  final Project result;

  /// Documents with a size that cannot fit inside the printable area of an
  /// empty page, even when turned.
  final List<String> unplaced;

  /// Documents left aside because their category/size is not set yet.
  final List<String> awaitingSize;

  int get pageCount => result.pageCount;
}

/// Arranges documents over as many A4 pages as needed.
///
/// Documents are taken in category order (unified card, residence card,
/// passport, ration card, others) and, within a category, by the project's
/// [LayoutOrder]. Locked documents never move and act as obstacles; with
/// [keepPlaced] every document already on a page stays where it is and only
/// off-sheet documents are arranged. A document whose size is not confirmed
/// is never kept on a page: like a saved project does when it is opened, it
/// waits off the sheet ([ArrangementResult.awaitingSize]) until its category
/// or size is chosen. Pages are added while needed (up to
/// [maxArrangedPages]) and empty trailing pages are removed.
ArrangementResult arrangeDocuments(
  Project project, {
  bool keepPlaced = false,
  ArrangementStrategy? strategy,
  bool? allowRotation,
}) {
  final rotate = allowRotation ?? project.layout.allowRotation;
  // The same rule as Project.fromJson and PageLayout.checked: a size that is
  // not confirmed has no place on the paper.
  final source = project.copyWith(
    items: [
      for (final item in project.items)
        if (!item.sizeConfirmed && item.pageIndex != null)
          item.copyWith(unplaced: true)
        else
          item,
    ],
  );
  final fixed = <DocumentItem>[
    for (final item in source.items)
      if (item.pageIndex != null && (item.locked || keepPlaced)) item,
  ];
  final fixedIds = {for (final item in fixed) item.id};
  final movable = <DocumentItem>[
    for (final item in source.items)
      if (item.sizeConfirmed && !item.locked && !fixedIds.contains(item.id))
        item,
  ];
  final awaiting = [
    for (final item in source.items)
      if (!item.sizeConfirmed && item.pageIndex == null) item.id,
  ];
  final inputOrder = {
    for (var i = 0; i < source.items.length; i++) source.items[i].id: i,
  };
  movable.sort((a, b) {
    final kind = a.documentKind.order.compareTo(b.documentKind.order);
    if (kind != 0) return kind;
    if (source.layout.order == LayoutOrder.area) {
      final size = (b.width * b.height).compareTo(a.width * a.height);
      if (size != 0) return size;
    }
    return inputOrder[a.id]!.compareTo(inputOrder[b.id]!);
  });

  final placed = switch (strategy ?? source.layout.strategy) {
    ArrangementStrategy.ordered => _ordered(source, fixed, movable, rotate),
    ArrangementStrategy.compact => _compact(source, movable, rotate),
  };

  final items = [
    for (final item in source.items)
      if (placed.containsKey(item.id))
        placed[item.id]!
      else if (movable.any((m) => m.id == item.id))
        item.copyWith(unplaced: true)
      else
        item,
  ];
  final lastPage = items.fold<int>(
    0,
    (last, item) => math.max(last, item.pageIndex ?? 0),
  );
  final result = source.copyWith(pageCount: lastPage + 1, items: items);
  return ArrangementResult(
    project,
    result,
    unplaced: [
      for (final item in movable)
        if (!placed.containsKey(item.id)) item.id,
    ],
    awaitingSize: awaiting,
  );
}

/// The orientation an item is arranged in: its own when it fits on an empty
/// page, otherwise turned by 90° if that is allowed and fits.
DocumentItem? _fitting(DocumentItem item, RectMm area, bool rotate) {
  for (final rotation in [
    item.rotation,
    if (rotate) (item.rotation + 90) % 360,
  ]) {
    final turned = item.copyWith(rotation: rotation);
    final b = turned.bounds;
    if (b.width <= area.width + _eps && b.height <= area.height + _eps) {
      return turned;
    }
  }
  return null;
}

/// [item] moved so its rotated bounding box starts at ([left], [top]).
DocumentItem _at(DocumentItem item, double left, double top, int page) {
  final b = item.bounds;
  return item.copyWith(
    x: left + (b.width - item.width) / 2,
    y: top + (b.height - item.height) / 2,
    pageIndex: page,
  );
}

bool _gapOverlap(RectMm a, RectMm b, double gx, double gy) =>
    a.x < b.right + gx - _eps &&
    a.right + gx > b.x + _eps &&
    a.y < b.bottom + gy - _eps &&
    a.bottom + gy > b.y + _eps;

/// Row flow in category order, right to left, top to bottom, page after page.
/// A new row starts when the category changes so each category reads as one
/// group; each finished row is centred horizontally when nothing fixed is in
/// the way.
Map<String, DocumentItem> _ordered(
  Project project,
  List<DocumentItem> fixed,
  List<DocumentItem> movable,
  bool rotate,
) {
  final area = project.paper.printable;
  final gx = project.layout.horizontalGap, gy = project.layout.verticalGap;
  final obstacles = <int, List<RectMm>>{};
  for (final item in fixed) {
    obstacles.putIfAbsent(item.pageIndex!, () => []).add(item.bounds);
  }
  final placed = <String, DocumentItem>{};
  var page = 0;
  var rowTop = area.y, rowBottom = area.y;
  DocumentKind? rowKind;
  final row = <String>[];

  List<RectMm> occupied(int p) => [
    ...?obstacles[p],
    for (final item in placed.values)
      if (item.pageIndex == p) item.bounds,
  ];

  void closeRow() {
    if (row.isEmpty) return;
    final rects = [for (final id in row) placed[id]!.bounds];
    final left = rects.map((r) => r.x).reduce(math.min);
    final right = rects.map((r) => r.right).reduce(math.max);
    final shift = ((area.right - right) - (left - area.x)) / 2;
    final others = obstacles[page] ?? const <RectMm>[];
    final shifted = [
      for (final r in rects) RectMm(r.x + shift, r.y, r.width, r.height),
    ];
    final clear = shifted.every(
      (r) => others.every((o) => !_gapOverlap(r, o, gx, gy)),
    );
    if (clear && shift.abs() > _eps) {
      for (final id in row) {
        final item = placed[id]!;
        placed[id] = item.copyWith(x: item.x + shift);
      }
    }
    rowTop = rowBottom + gy;
    row.clear();
    rowKind = null;
  }

  RectMm? findInRow(double width, double height) {
    if (rowTop + height > area.bottom + _eps) return null;
    final taken = occupied(page);
    var x = area.right - width;
    while (x >= area.x - _eps) {
      final candidate = RectMm(x, rowTop, width, height);
      final blockers = taken.where((r) => _gapOverlap(candidate, r, gx, gy));
      if (blockers.isEmpty) return candidate;
      x = blockers.map((r) => r.x - gx - width).reduce(math.min);
    }
    return null;
  }

  /// The lowest point an empty row can drop to past the obstacles in its way.
  double? nextRowTop(double height) {
    final band = RectMm(area.x, rowTop, area.width, height);
    final below = [
      for (final r in obstacles[page] ?? const <RectMm>[])
        if (_gapOverlap(band, r, 0, gy) && r.bottom + gy > rowTop + _eps)
          r.bottom + gy,
    ];
    if (below.isEmpty) return null;
    return below.reduce(math.min);
  }

  for (final original in movable) {
    final item = _fitting(original, area, rotate);
    if (item == null) continue;
    final b = item.bounds;
    if (rowKind != null && rowKind != item.documentKind) closeRow();
    while (page < maxArrangedPages) {
      final spot = findInRow(b.width, b.height);
      if (spot != null) {
        placed[item.id] = _at(item, spot.x, spot.y, page);
        row.add(item.id);
        rowKind = item.documentKind;
        rowBottom = math.max(rowBottom, spot.bottom);
        break;
      }
      if (row.isNotEmpty) {
        closeRow();
        continue;
      }
      final next = nextRowTop(b.height);
      if (next != null && next + b.height <= area.bottom + _eps) {
        rowTop = next;
        rowBottom = math.max(rowBottom, next - gy);
        continue;
      }
      page++;
      rowTop = area.y;
      rowBottom = area.y;
      rowKind = null;
    }
  }
  closeRow();
  return placed;
}

/// Densest packing per page (MaxRects); whatever does not fit flows on.
Map<String, DocumentItem> _compact(
  Project project,
  List<DocumentItem> movable,
  bool rotate,
) {
  final area = project.paper.printable;
  final ids = {
    for (final item in movable)
      if (_fitting(item, area, rotate) != null) item.id,
  };
  var current = project.copyWith(
    items: [
      for (final item in project.items)
        movable.any((m) => m.id == item.id)
            ? item.copyWith(unplaced: true)
            : item,
    ],
  );
  final placed = <String, DocumentItem>{};
  var page = 0;
  while (ids.isNotEmpty && page < maxArrangedPages) {
    if (page >= current.pageCount) {
      current = current.copyWith(pageCount: page + 1);
    }
    final pageWasEmpty = !current.items.any((e) => e.pageIndex == page);
    final proposal = proposePacking(
      current,
      includeLocked: false,
      allowRotation: rotate,
      onlyUnplaced: true,
      pageIndex: page,
    );
    var progress = false;
    for (final item in proposal.result.items) {
      if (ids.contains(item.id) && item.pageIndex == page) {
        placed[item.id] = item;
        ids.remove(item.id);
        progress = true;
      }
    }
    current = proposal.result;
    if (!progress && pageWasEmpty) break;
    page++;
  }
  return placed;
}
