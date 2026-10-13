import 'dart:math' as math;

import 'document_kind.dart';
import 'geometry.dart';
import 'packing.dart';
import 'project.dart';
import 'recognition.dart' show GroupArrangement, LayoutGroup;

/// Largest number of pages automatic arrangement may create.
const maxArrangedPages = 100;

const _eps = 1e-7;

/// Whether automatic arrangement may place a document and, if not, why.
///
/// A state of the document itself, not of where it currently is: the editor
/// shows it for every document that automatic arrangement leaves out, so the
/// user sees the reason instead of a document that merely sits off the sheet.
enum AutoLayoutStatus {
  /// It is locked and automatic arrangement will not move it.
  locked,

  /// Automatic arrangement places it (or keeps it, when it is fixed).
  eligible,

  /// Its printed size is not confirmed: the category is unknown or the size
  /// was never confirmed. Automatic arrangement never places it and never
  /// keeps it on a page. Choosing a category or setting a size in mm makes it
  /// eligible.
  sizeUnconfirmed,

  /// Its size is confirmed but larger than the printable area of an empty
  /// page, even when turned (where turning is allowed). Documents are never
  /// scaled to fit.
  tooLarge,
}

/// The [AutoLayoutStatus] of [item] in [project]; [allowRotation] defaults
/// to the project's layout setting.
AutoLayoutStatus autoLayoutStatus(
  Project project,
  DocumentItem item, {
  bool? allowRotation,
}) {
  if (item.locked) return AutoLayoutStatus.locked;
  if (!item.sizeConfirmed) return AutoLayoutStatus.sizeUnconfirmed;
  final rotate = allowRotation ?? project.layout.allowRotation;
  return _fitting(item, project.paper.printable, rotate) == null
      ? AutoLayoutStatus.tooLarge
      : AutoLayoutStatus.eligible;
}

/// Outcome of [arrangeDocuments]. Sizes never change; only positions, page
/// numbers and (when allowed) a 90° turn.
class ArrangementResult {
  ArrangementResult(
    this.original,
    this.result, {
    required List<String> unplaced,
    required List<String> awaitingSize,
    List<String> takenOffSheet = const [],
  }) : unplaced = List.unmodifiable(unplaced),
       awaitingSize = List.unmodifiable(awaitingSize),
       takenOffSheet = List.unmodifiable(takenOffSheet);

  final Project original;
  final Project result;

  /// Documents with a size that cannot fit inside the printable area of an
  /// empty page, even when turned.
  final List<String> unplaced;

  /// Documents left aside because their category/size is not set yet
  /// ([AutoLayoutStatus.sizeUnconfirmed]), wherever they were before.
  final List<String> awaitingSize;

  /// The part of [awaitingSize] that was on a page before arranging and was
  /// taken off the sheet, so the editor can tell the user why it moved.
  final List<String> takenOffSheet;

  int get pageCount => result.pageCount;
}

/// Arranges documents over as many A4 pages as needed.
///
/// Documents are taken in category order (unified card, residence card,
/// passport, ration card, others) and, within a category, by the project's
/// [LayoutOrder]. Locked documents never move and act as obstacles; with
/// [keepPlaced] every document already on a page stays where it is and only
/// off-sheet documents are arranged. A document whose size is not confirmed
/// is not eligible for automatic arrangement ([AutoLayoutStatus]): it is
/// never kept on a page, like a saved project does when it is opened, and is
/// reported in [ArrangementResult.awaitingSize] (and
/// [ArrangementResult.takenOffSheet] when it was on a page) until its
/// category or size is chosen. Pages are added while needed (up to
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
  final takenOffSheet = [
    for (final item in project.items)
      if (!item.sizeConfirmed && item.pageIndex != null) item.id,
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

  // Treat valid, wholly movable keep-together groups as one layout unit.
  // A partial/locked group is not silently split by the automatic arranger:
  // its movable members stay off-sheet until the whole group can be handled.
  final itemById = {for (final item in source.items) item.id: item};
  final keptGroups = source.layoutGroups
      .where((group) => group.keepTogether && group.itemIds.length > 1)
      .toList()
    ..sort((a, b) {
      int firstIndex(LayoutGroup group) => source.items.indexWhere(
        (item) => group.itemIds.contains(item.id),
      );
      final order = firstIndex(a).compareTo(firstIndex(b));
      return order != 0 ? order : a.id.compareTo(b.id);
    });
  final movableIds = {for (final item in movable) item.id};
  final groupedMovableIds = <String>{};
  final blockedGroupIds = <String>{};
  final groupsToPlace = <LayoutGroup>[];
  for (final group in keptGroups) {
    final members = [for (final id in group.itemIds) itemById[id]!];
    final ownershipIsConsistent = members.every(
      (item) => item.groupId == group.id,
    );
    if (!ownershipIsConsistent ||
        members.any((item) => groupedMovableIds.contains(item.id))) {
      blockedGroupIds.addAll(members.where((item) => movableIds.contains(item.id)).map((item) => item.id));
      continue;
    }
    if (members.every((item) => movableIds.contains(item.id))) {
      groupsToPlace.add(group);
      groupedMovableIds.addAll(group.itemIds);
    } else {
      blockedGroupIds.addAll(
        members.where((item) => movableIds.contains(item.id)).map((item) => item.id),
      );
    }
  }

  final regularMovable = movable
      .where(
        (item) =>
            !groupedMovableIds.contains(item.id) &&
            !blockedGroupIds.contains(item.id),
      )
      .toList();
  final placed = switch (strategy ?? source.layout.arrangementStrategy) {
    ArrangementStrategy.ordered =>
      _ordered(source, fixed, regularMovable, rotate),
    ArrangementStrategy.compact => _compact(source, regularMovable, rotate),
  };
  _placeTogetherGroups(source, groupsToPlace, placed, rotate);
  if (source.layout.centerCaptures && placed.isNotEmpty) {
    final obstacles = <int, List<RectMm>>{};
    for (final item in source.items) {
      final pageIndex = item.pageIndex;
      if (pageIndex != null && !placed.containsKey(item.id)) {
        obstacles.putIfAbsent(pageIndex, () => []).add(item.bounds);
      }
    }
    _centerPageItems(
      placed,
      source.paper.printable,
      source.layout.horizontalGap,
      source.layout.verticalGap,
      obstacles,
    );
  }

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
    takenOffSheet: takenOffSheet,
  );
}

class _GroupMemberPlacement {
  const _GroupMemberPlacement(this.item, this.rotation, this.x, this.y);

  final DocumentItem item;
  final double rotation;
  final double x;
  final double y;
}

class _GroupShape {
  const _GroupShape(this.width, this.height, this.members);

  final double width;
  final double height;
  final List<_GroupMemberPlacement> members;
}

/// Reserves a composite rectangle for each keep-together group, then expands
/// the accepted rectangle back into its real member rectangles. The ordinary
/// items are obstacles, and a fresh page is tried before the group is left
/// unplaced; members are never split to make a partial result look successful.
void _placeTogetherGroups(
  Project project,
  List<LayoutGroup> groups,
  Map<String, DocumentItem> placed,
  bool allowRotation,
) {
  if (groups.isEmpty) return;
  final area = project.paper.printable;
  final horizontalGap = project.layout.horizontalGap;
  final verticalGap = project.layout.verticalGap;

  for (final group in groups) {
    final groupIds = group.itemIds.toSet();
    final members = [
      for (final id in group.itemIds)
        project.items.firstWhere((item) => item.id == id),
    ];
    final turns = [0, if (allowRotation) 90];
    var lastOccupiedPage = project.pageCount - 1;
    for (final item in project.items) {
      if (groupIds.contains(item.id)) continue;
      final current = placed[item.id] ?? item;
      if (current.pageIndex != null) {
        lastOccupiedPage = math.max(lastOccupiedPage, current.pageIndex!);
      }
    }
    final lastPageToTry = math.min(
      maxArrangedPages - 1,
      math.max(lastOccupiedPage + 1, 0),
    );
    var acceptedShape = _GroupShape(0, 0, const []);
    DocumentItem? acceptedBox;
    var acceptedPage = -1;

    for (var page = 0; page <= lastPageToTry && acceptedBox == null; page++) {
      for (final turn in turns) {
        final shape = _shapeGroup(
          members,
          group.arrangement,
          turn,
          horizontalGap,
          verticalGap,
        );
        if (shape.width > area.width + _eps ||
            shape.height > area.height + _eps) {
          continue;
        }
        final first = members.first;
        final composite = first.copyWith(
          x: area.x,
          y: area.y,
          width: shape.width,
          height: shape.height,
          rotation: 0,
          unplaced: true,
          sizeConfirmed: true,
          locked: false,
          clearGroupId: true,
        );
        final obstacles = <DocumentItem>[];
        for (final item in project.items) {
          if (groupIds.contains(item.id)) continue;
          final current = placed[item.id] ?? item;
          if (current.pageIndex != null) {
            obstacles.add(current.copyWith(clearGroupId: true));
          }
        }
        final temporaryProject = project.copyWith(
          pageCount: math.max(project.pageCount, page + 1),
          items: [...obstacles, composite],
          documents: const [],
          layoutGroups: const [],
        );
        final proposal = proposePacking(
          temporaryProject,
          includeLocked: false,
          allowRotation: false,
          onlyUnplaced: true,
          pageIndex: page,
        );
        final box = proposal.result.items.firstWhere(
          (item) => item.id == composite.id,
        );
        if (box.pageIndex == page) {
          acceptedShape = shape;
          acceptedBox = box;
          acceptedPage = page;
          break;
        }
      }
    }

    final box = acceptedBox;
    if (box == null) continue;
    for (final member in acceptedShape.members) {
      final originalBounds = member.item.copyWith(rotation: member.rotation).bounds;
      placed[member.item.id] = member.item.copyWith(
        x: box.x + member.x + (originalBounds.width - member.item.width) / 2,
        y: box.y + member.y + (originalBounds.height - member.item.height) / 2,
        rotation: member.rotation,
        pageIndex: acceptedPage,
      );
    }
  }
}

_GroupShape _shapeGroup(
  List<DocumentItem> items,
  GroupArrangement arrangement,
  int turn,
  double horizontalGap,
  double verticalGap,
) {
  final rotated = [
    for (final item in items)
      item.copyWith(rotation: (item.rotation + turn) % 360),
  ];
  final bounds = [for (final item in rotated) item.bounds];
  final width = arrangement == GroupArrangement.stacked
      ? bounds.map((item) => item.width).reduce(math.max)
      : bounds.fold<double>(0, (sum, item) => sum + item.width) +
            horizontalGap * (bounds.length - 1);
  final height = arrangement == GroupArrangement.stacked
      ? bounds.fold<double>(0, (sum, item) => sum + item.height) +
            verticalGap * (bounds.length - 1)
      : bounds.map((item) => item.height).reduce(math.max);
  var cursor = 0.0;
  final placements = <_GroupMemberPlacement>[];
  for (var i = 0; i < rotated.length; i++) {
    final item = rotated[i];
    final bound = bounds[i];
    final x = arrangement == GroupArrangement.stacked
        ? (width - bound.width) / 2
        : cursor;
    final y = arrangement == GroupArrangement.stacked
        ? cursor
        : (height - bound.height) / 2;
    placements.add(_GroupMemberPlacement(items[i], item.rotation, x, y));
    cursor += arrangement == GroupArrangement.stacked
        ? bound.height + verticalGap
        : bound.width + horizontalGap;
  }
  return _GroupShape(width, height, List.unmodifiable(placements));
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
  // Center the entire group of placed items on each page.
  if (project.layout.centerCaptures && placed.isNotEmpty) {
    _centerPageItems(placed, area, gx, gy, obstacles);
  }
  return placed;
}

/// Centers the group of placed items on each page within the printable area.
void _centerPageItems(
  Map<String, DocumentItem> placed,
  RectMm area,
  double gx,
  double gy,
  Map<int, List<RectMm>> obstacles,
) {
  final pages = placed.values.map((item) => item.pageIndex).toSet();
  for (final page in pages) {
    final pageItems = placed.values
        .where((item) => item.pageIndex == page)
        .toList();
    if (pageItems.isEmpty) continue;
    final bounds = _groupBounds(pageItems);
    if (bounds == null) continue;
    // Check that centering won't cause overlap with obstacles.
    final shiftX = (area.width - bounds.width) / 2 - (bounds.x - area.x);
    final shiftY = (area.height - bounds.height) / 2 - (bounds.y - area.y);
    final shifted = pageItems.map((item) {
      final bounds = item.bounds;
      return RectMm(
        bounds.x + shiftX,
        bounds.y + shiftY,
        bounds.width,
        bounds.height,
      );
    });
    final others = obstacles[page] ?? const <RectMm>[];
    final clear = shifted.every(
      (r) => others.every((o) => !_gapOverlap(r, o, gx, gy)),
    );
    if (clear && (shiftX.abs() > _eps || shiftY.abs() > _eps)) {
      for (final item in pageItems) {
        placed[item.id] = item.copyWith(x: item.x + shiftX, y: item.y + shiftY);
      }
    }
  }
}

/// Densest packing per page (MaxRects); whatever does not fit flows on.
///
/// When the user's within-category order is input order, a second deterministic
/// largest-first pass is tried only for mixed-size categories. It replaces the
/// first pass only when it places more documents or uses fewer pages. This is a
/// bounded heuristic improvement, not an optimality guarantee.
Map<String, DocumentItem> _compact(
  Project project,
  List<DocumentItem> movable,
  bool rotate,
) {
  final preferred = _compactPass(
    project,
    movable,
    rotate,
    orderOverride: project.layout.order,
  );
  if (project.layout.order != LayoutOrder.input ||
      !_hasMixedAreaWithinCategory(movable)) {
    return preferred;
  }
  final largestFirst = _compactPass(
    project,
    movable,
    rotate,
    orderOverride: LayoutOrder.area,
  );
  return _compactResultIsBetter(
    largestFirst,
    preferred,
    movable,
    project.paper.printable,
    rotate,
  )
      ? largestFirst
      : preferred;
}

bool _hasMixedAreaWithinCategory(List<DocumentItem> items) {
  final areaByKind = <DocumentKind, double>{};
  for (final item in items) {
    final area = item.width * item.height;
    final previous = areaByKind[item.documentKind];
    if (previous != null && (previous - area).abs() > _eps) return true;
    areaByKind[item.documentKind] = area;
  }
  return false;
}

bool _compactResultIsBetter(
  Map<String, DocumentItem> candidate,
  Map<String, DocumentItem> current,
  List<DocumentItem> movable,
  RectMm area,
  bool rotate,
) {
  final eligible = movable
      .where((item) => _fitting(item, area, rotate) != null)
      .length;
  final candidateUnplaced = eligible - candidate.length;
  final currentUnplaced = eligible - current.length;
  if (candidateUnplaced != currentUnplaced) {
    return candidateUnplaced < currentUnplaced;
  }
  final candidatePages = candidate.values.map((item) => item.pageIndex).toSet();
  final currentPages = current.values.map((item) => item.pageIndex).toSet();
  if (candidatePages.length != currentPages.length) {
    return candidatePages.length < currentPages.length;
  }
  int lastPage(Set<int?> pages) {
    var last = 0;
    for (final page in pages.whereType<int>()) {
      if (page > last) last = page;
    }
    return last;
  }

  return lastPage(candidatePages) < lastPage(currentPages);
}

Map<String, DocumentItem> _compactPass(
  Project project,
  List<DocumentItem> movable,
  bool rotate, {
  required LayoutOrder orderOverride,
}) {
  final area = project.paper.printable;
  final movableIds = {for (final item in movable) item.id};
  final ids = {
    for (final item in movable)
      if (_fitting(item, area, rotate) != null) item.id,
  };
  var current = project.copyWith(
    items: [
      for (final item in project.items)
        if (movableIds.contains(item.id))
          item.copyWith(unplaced: true)
        else if (item.pageIndex == null && item.sizeConfirmed)
          item.copyWith(locked: true)
        else
          item,
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
      orderOverride: orderOverride,
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
  // Center the group of placed items on each page, preserving relative
  // positions from the packing algorithm and never colliding with items
  // that stayed put (locked or keep-placed).
  if (project.layout.centerCaptures && placed.isNotEmpty) {
    final obstacles = <int, List<RectMm>>{};
    for (final item in project.items) {
      final pageIndex = item.pageIndex;
      if (pageIndex != null && !placed.containsKey(item.id)) {
        obstacles.putIfAbsent(pageIndex, () => []).add(item.bounds);
      }
    }
    _centerPageItems(
      placed,
      area,
      project.layout.horizontalGap,
      project.layout.verticalGap,
      obstacles,
    );
  }
  return placed;
}

/// Computes the bounding box of a group of items.
RectMm? _groupBounds(List<DocumentItem> items) {
  if (items.isEmpty) return null;
  double left = double.infinity, top = double.infinity;
  double right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final item in items) {
    final b = item.bounds;
    left = math.min(left, b.x);
    top = math.min(top, b.y);
    right = math.max(right, b.right);
    bottom = math.max(bottom, b.bottom);
  }
  return RectMm(left, top, right - left, bottom - top);
}
