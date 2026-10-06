import 'dart:math' as math;
import 'geometry.dart';
import 'project.dart';
import 'validation.dart';

enum PageAlignment { left, centerX, right, top, centerY, bottom }

/// A view scale, never a printer DPI. Model coordinates always remain mm.
class PageViewport {
  PageViewport(this.paper, double availableWidth, double availableHeight)
    : scale = math.min(
        availableWidth / paper.width,
        availableHeight / paper.height,
      ) {
    require(scale.isFinite && scale > 0, 'مساحة العرض غير صالحة.');
  }
  final PaperSettings paper;
  final double scale;
  Point2 toMm(double x, double y) => Point2(x / scale, y / scale);
  Point2 toView(double x, double y) => Point2(x * scale, y * scale);
}

class LayoutIssue {
  const LayoutIssue(this.itemId, this.message);
  final String itemId;
  final String message;
}

/// Shared by editor, packing and export; conservative rotated bounding boxes.
List<LayoutIssue> inspectLayout(Project project) {
  final issues = <LayoutIssue>[];
  for (var i = 0; i < project.items.length; i++) {
    final item = project.items[i];
    if (item.pageIndex == null) continue;
    if (!project.paper.printable.contains(item.bounds)) {
      issues.add(LayoutIssue(item.id, 'عنصر خارج حدود الطباعة'));
    }
    for (final other in project.items.take(i)) {
      if (item.pageIndex == other.pageIndex &&
          item.bounds.overlaps(other.bounds)) {
        issues.add(LayoutIssue(item.id, 'تداخل مع العنصر ${other.id}'));
      }
    }
  }
  return issues;
}

class PageLayout {
  static DocumentItem item(Project p, String id) =>
      p.items.firstWhere((e) => e.id == id);
  static Project replace(
    Project p,
    DocumentItem value, {
    bool allowOverlap = false,
  }) {
    final old = item(p, value.id);
    require(!old.locked, 'العنصر مثبت؛ ألغِ التثبيت أولاً.');
    return checked(
      p.copyWith(
        items: [for (final e in p.items) e.id == value.id ? value : e],
      ),
      allowOverlap: allowOverlap,
    );
  }

  static Project checked(Project p, {bool allowOverlap = false}) {
    for (final e in p.items) {
      if (e.pageIndex == null) continue;
      require(
        p.paper.printable.contains(e.bounds),
        'العنصر خارج حدود الطباعة؛ عدّل الموضع أو المقاس.',
      );
    }
    if (!allowOverlap) {
      require(
        inspectLayout(p).isEmpty,
        'تداخل عناصر؛ عدّل الموضع أو وافق صراحة على التراكب.',
      );
    }
    return p;
  }

  static Project add(
    Project p,
    DocumentItem value, {
    bool allowOverlap = false,
  }) => checked(
    p.copyWith(items: [...p.items, value]),
    allowOverlap: allowOverlap,
  );
  /// Extra copies of [item] that start unplaced, so the deterministic packing
  /// proposal decides where they fit and reports the ones that do not.
  /// Ids come from [idFactory] to keep the domain free of generation state.
  static List<DocumentItem> copies(
    DocumentItem item,
    int count,
    String Function() idFactory,
  ) {
    require(count >= 0 && count <= 200, 'عدد النسخ المطلوب غير صالح.');
    return [
      for (var index = 0; index < count; index++)
        item.copyWith(
          id: idFactory(),
          unplaced: true,
          locked: false,
          keepAspectRatio: item.keepAspectRatio,
          zIndex: item.zIndex + index + 1,
        ),
    ];
  }

  static Project addMany(
    Project p,
    Iterable<DocumentItem> values, {
    bool allowOverlap = false,
  }) => checked(
    p.copyWith(items: [...p.items, ...values]),
    allowOverlap: allowOverlap,
  );

  static Project move(
    Project p,
    String id,
    double dx,
    double dy, {
    bool allowOverlap = false,
  }) {
    final e = item(p, id);
    return replace(
      p,
      e.copyWith(x: e.x + dx, y: e.y + dy),
      allowOverlap: allowOverlap,
    );
  }

  static DocumentItem resize(DocumentItem e, double width, double height) =>
      e.copyWith(
        width: e.keepAspectRatio && width == e.width
            ? height * e.width / e.height
            : width,
        height: e.keepAspectRatio && width != e.width
            ? width * e.height / e.width
            : height,
      );
  static Project lock(Project p, String id, bool locked) => p.copyWith(
    items: [
      for (final e in p.items) e.id == id ? e.copyWith(locked: locked) : e,
    ],
  );
  static Project remove(Project p, Set<String> ids) {
    require(
      !p.items.any((e) => ids.contains(e.id) && e.locked),
      'ألغِ تثبيت العناصر قبل حذفها.',
    );
    return p.copyWith(
      items: p.items.where((e) => !ids.contains(e.id)).toList(),
    );
  }

  static Project align(
    Project p,
    Set<String> ids,
    PageAlignment alignment, {
    bool allowOverlap = false,
  }) {
    require(ids.isNotEmpty, 'حدد عناصر للمحاذاة.');
    final area = p.paper.printable;
    final changed = p.items.map((e) {
      if (!ids.contains(e.id)) return e;
      require(!e.locked, 'المحاذاة لا تغيّر العناصر المثبتة.');
      final b = e.bounds;
      final dx = switch (alignment) {
        PageAlignment.left => area.x - b.x,
        PageAlignment.centerX => area.x + (area.width - b.width) / 2 - b.x,
        PageAlignment.right => area.right - b.right,
        _ => 0.0,
      };
      final dy = switch (alignment) {
        PageAlignment.top => area.y - b.y,
        PageAlignment.centerY => area.y + (area.height - b.height) / 2 - b.y,
        PageAlignment.bottom => area.bottom - b.bottom,
        _ => 0.0,
      };
      return e.copyWith(x: e.x + dx, y: e.y + dy);
    }).toList();
    return checked(p.copyWith(items: changed), allowOverlap: allowOverlap);
  }

  static Project distribute(
    Project p,
    Set<String> ids, {
    required bool horizontal,
    bool allowOverlap = false,
  }) {
    final selected = p.items.where((e) => ids.contains(e.id)).toList();
    require(
      selected.every((e) => e.pageIndex != null) &&
          selected.map((e) => e.pageIndex).toSet().length == 1,
      'حدد عناصر من صفحة واحدة.',
    );
    require(selected.length >= 3, 'حدد ثلاثة عناصر على الأقل للتوزيع.');
    require(
      selected.every((e) => !e.locked),
      'التوزيع لا يغيّر العناصر المثبتة.',
    );
    selected.sort(
      (a, b) => horizontal
          ? a.bounds.x.compareTo(b.bounds.x)
          : a.bounds.y.compareTo(b.bounds.y),
    );
    final start = horizontal
        ? selected.first.bounds.x
        : selected.first.bounds.y;
    final end = horizontal
        ? selected.last.bounds.right
        : selected.last.bounds.bottom;
    final sum = selected.fold<double>(
      0,
      (v, e) => v + (horizontal ? e.bounds.width : e.bounds.height),
    );
    final gap = (end - start - sum) / (selected.length - 1);
    require(
      gap >= (horizontal ? p.layout.horizontalGap : p.layout.verticalGap),
      'لا تكفي المساحة للتوزيع مع الفجوة المطلوبة.',
    );
    var cursor = start;
    final changes = <String, DocumentItem>{};
    for (final e in selected) {
      final b = e.bounds;
      changes[e.id] = e.copyWith(
        x: horizontal ? e.x + cursor - b.x : e.x,
        y: horizontal ? e.y : e.y + cursor - b.y,
      );
      cursor += (horizontal ? b.width : b.height) + gap;
    }
    return checked(
      p.copyWith(items: [for (final e in p.items) changes[e.id] ?? e]),
      allowOverlap: allowOverlap,
    );
  }
}
