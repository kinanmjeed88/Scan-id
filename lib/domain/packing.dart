import 'dart:math' as math;
import 'geometry.dart';
import 'project.dart';
import 'validation.dart';

class PackingProposal {
  PackingProposal(this.original, this.result, List<String> unplaced)
    : unplaced = List.unmodifiable(unplaced);
  final Project original;
  final Project result;
  final List<String> unplaced;
}

/// Deterministic MaxRects best-short-side fit, never a global optimum claim.
/// Sizes never change. Gaps are reserved to the right/bottom of each bounding
/// box, with an extra gap strip on the bin edge so border items still fit.
PackingProposal proposePacking(
  Project project, {
  required bool includeLocked,
  required bool allowRotation,
  int pageIndex = 0,
}) {
  require(
    pageIndex >= 0 && pageIndex < project.pageCount,
    'صفحة ترتيب غير موجودة.',
  );
  final area = project.paper.printable;
  final gx = project.layout.horizontalGap, gy = project.layout.verticalGap;
  var free = [RectMm(area.x, area.y, area.width + gx, area.height + gy)];
  final changes = <String, DocumentItem>{};

  final fixed = project.items
      .where((e) => e.pageIndex == pageIndex && e.locked && !includeLocked)
      .toList();
  for (final item in fixed) {
    require(
      area.contains(item.bounds),
      'عنصر مثبت خارج الهوامش؛ عدّل الورقة أو ألغِ تثبيته أولاً.',
    );
    final r = item.bounds;
    free = _subtract(free, RectMm(r.x, r.y, r.width + gx, r.height + gy));
  }
  // Reject conflicting fixed obstacles rather than claiming a valid solution.
  for (var i = 0; i < fixed.length; i++) {
    final a = fixed[i].bounds;
    for (final other in fixed.take(i)) {
      final b = other.bounds;
      require(
        !_gapOverlap(a, b, gx, gy),
        'العناصر المثبتة متداخلة أو لا تحترم الفجوات.',
      );
    }
  }
  final pending = project.items
      .where(
        (e) =>
            (e.pageIndex == pageIndex || e.pageIndex == null) &&
            (includeLocked || !e.locked),
      )
      .toList();
  if (project.layout.order == LayoutOrder.area) {
    pending.sort((a, b) {
      final size = (b.bounds.width * b.bounds.height).compareTo(
        a.bounds.width * a.bounds.height,
      );
      return size != 0 ? size : a.id.compareTo(b.id);
    });
  }
  for (final item in pending) {
    DocumentItem? best;
    RectMm? used;
    double bestShort = double.infinity, bestLong = double.infinity;
    for (final rotation in [
      item.rotation,
      if (allowRotation) (item.rotation + 90) % 360,
    ]) {
      final rotated = item.copyWith(rotation: rotation);
      final b = rotated.bounds;
      final w = b.width + gx, h = b.height + gy;
      for (final space in free) {
        if (w > space.width + 1e-7 || h > space.height + 1e-7) continue;
        final short = math.min(space.width - w, space.height - h),
            long = math.max(space.width - w, space.height - h);
        if (short > bestShort + 1e-7 ||
            (short - bestShort).abs() < 1e-7 && long >= bestLong)
          continue;
        final candidate = rotated.copyWith(
          x: space.x + (b.width - item.width) / 2,
          y: space.y + (b.height - item.height) / 2,
          pageIndex: pageIndex,
        );
        if (!area.contains(candidate.bounds)) continue;
        best = candidate;
        used = RectMm(space.x, space.y, w, h);
        bestShort = short;
        bestLong = long;
      }
    }
    if (best == null) {
      changes[item.id] = item.copyWith(unplaced: true);
    } else {
      changes[item.id] = best;
      free = _subtract(free, used!);
    }
  }
  final result = project.copyWith(
    items: [for (final item in project.items) changes[item.id] ?? item],
  );
  return PackingProposal(
    project,
    result,
    result.items.where((e) => e.pageIndex == null).map((e) => e.id).toList(),
  );
}

bool _gapOverlap(RectMm a, RectMm b, double x, double y) =>
    a.x < b.right + x - 1e-7 &&
    a.right + x > b.x + 1e-7 &&
    a.y < b.bottom + y - 1e-7 &&
    a.bottom + y > b.y + 1e-7;
List<RectMm> _subtract(List<RectMm> free, RectMm used) {
  final split = <RectMm>[];
  for (final r in free) {
    if (!r.overlaps(used)) {
      split.add(r);
      continue;
    }
    if (used.x > r.x) split.add(RectMm(r.x, r.y, used.x - r.x, r.height));
    if (used.right < r.right)
      split.add(RectMm(used.right, r.y, r.right - used.right, r.height));
    if (used.y > r.y) split.add(RectMm(r.x, r.y, r.width, used.y - r.y));
    if (used.bottom < r.bottom)
      split.add(RectMm(r.x, used.bottom, r.width, r.bottom - used.bottom));
  }
  final result = <RectMm>[];
  for (var i = 0; i < split.length; i++) {
    final r = split[i];
    if (r.width < 1e-7 || r.height < 1e-7) continue;
    var contained = false;
    for (var j = 0; j < split.length; j++) {
      if (i == j) continue;
      if (split[j].contains(r) && (!r.contains(split[j]) || j < i)) {
        contained = true;
        break;
      }
    }
    if (!contained) result.add(r);
  }
  return result;
}
