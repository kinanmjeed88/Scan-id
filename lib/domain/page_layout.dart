import 'dart:math' as math;
import 'geometry.dart';
import 'project.dart';
import 'recognition.dart';
import 'recognition_routing.dart';
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
        e.pageIndex! >= 0 && e.pageIndex! < p.pageCount,
        'رقم الصفحة غير صالح.',
      );
      require(
        e.sizeConfirmed,
        'لا يمكن وضع مستمسك بقياس غير مؤكد على الورقة؛ أدخل قياسه وأكّده أولاً.',
      );
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

  /// Moves [id] to [targetPage], creating that page when it does not exist yet.
  ///
  /// The document keeps its size and (when it still fits) its position. When
  /// the current position is invalid or collides on the target page, a valid
  /// non-overlapping spot is searched; if none exists the operation is
  /// rejected with a clear reason instead of leaving the document off-page or
  /// overlapping. A document larger than the printable area is always rejected.
  static Project moveToPage(
    Project p,
    String id,
    int targetPage, {
    bool allowOverlap = false,
    bool? allowRotation,
  }) {
    final e = item(p, id);
    require(!e.locked, 'العنصر مثبت؛ ألغِ التثبيت أولاً.');
    require(targetPage >= 0 && targetPage < 100, 'رقم الصفحة غير صالح.');
    final rotate = allowRotation ?? p.layout.allowRotation;
    final area = p.paper.printable;
    final gx = p.layout.horizontalGap, gy = p.layout.verticalGap;

    DocumentItem oriented = e;
    if (!_fitsInArea(oriented, area)) {
      if (rotate) {
        final turned = e.copyWith(rotation: (e.rotation + 90) % 360);
        if (_fitsInArea(turned, area)) oriented = turned;
      }
    }
    require(
      _fitsInArea(oriented, area),
      'أبعاد المستمسك (${oriented.width.toStringAsFixed(1)}×'
      '${oriented.height.toStringAsFixed(1)} مم) لا تسمح بوضعه ضمن '
      'المساحة القابلة للطباعة (${area.width.toStringAsFixed(1)}×'
      '${area.height.toStringAsFixed(1)} مم).',
    );

    var pageCount = p.pageCount;
    if (targetPage >= pageCount) pageCount = targetPage + 1;

    final others = [
      for (final other in p.items)
        if (other.id != id && other.pageIndex == targetPage) other,
    ];

    var candidate = oriented.copyWith(pageIndex: targetPage);
    if (!_validPlacement(candidate, area, others, gx, gy, allowOverlap)) {
      candidate = _topLeftPlacement(candidate, area);
    }
    if (!_validPlacement(candidate, area, others, gx, gy, allowOverlap)) {
      final found = _findPlacement(
        candidate,
        area,
        others,
        gx,
        gy,
        allowOverlap,
      );
      if (found == null) {
        throw ValidationException(
          'لا توجد مساحة كافية في الصفحة ${targetPage + 1} لوضع المستمسك '
          'دون تداخل.',
        );
      }
      candidate = found;
    }

    final items = [
      for (final existing in p.items) existing.id == id ? candidate : existing,
    ];
    return checked(
      p.copyWith(pageCount: pageCount, items: items),
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

  /// Removes layout elements and cascades to the recognition records and pair
  /// links they alone supported. [allowLocked] is for deliberate removals that
  /// the user confirmed from a surface that is not the sheet editor (deleting
  /// an image from the project), where the lock belongs to the element that is
  /// being removed on purpose.
  static Project remove(
    Project p,
    Set<String> ids, {
    List<DocumentRecord>? documentsOverride,
    bool allowLocked = false,
  }) {
    final sourceDocuments = documentsOverride ?? p.documents;
    final removed = p.items.where((item) => ids.contains(item.id)).toList();
    require(
      allowLocked || removed.every((item) => !item.locked),
      'ألغِ تثبيت العناصر قبل حذفها.',
    );
    if (removed.isEmpty) return p;

    final removedIds = removed.map((item) => item.id).toSet();
    final items = p.items
        .where((item) => !removedIds.contains(item.id))
        .toList();
    final remainingDocumentIds = {
      for (final item in items)
        if (item.documentId != null) item.documentId!,
    };
    // A normal deletion cascades the recognition record only when its last
    // layout item is gone. New detached-dismissal tombstones survive without
    // items; legacy v5 `dismissed` overrides on linked records do not change
    // ordinary item-deletion behavior.
    final removedDocumentIds = {
      for (final record in sourceDocuments)
        if (removed.any((item) => item.documentId == record.id) &&
            !remainingDocumentIds.contains(record.id) &&
            !isDismissalTombstone(record))
          record.id,
    };

    final dissolvedPairGroups = <String>{};
    for (final record in sourceDocuments) {
      final partnerId = record.pairedDocumentId;
      if (removedDocumentIds.contains(record.id) &&
          partnerId != null &&
          !removedDocumentIds.contains(partnerId)) {
        final first = record.id.compareTo(partnerId) <= 0
            ? record.id
            : partnerId;
        dissolvedPairGroups.add('pair-$first');
      }
    }
    final documents = <DocumentRecord>[];
    for (final record in sourceDocuments) {
      if (removedDocumentIds.contains(record.id)) continue;
      if (record.pairedDocumentId != null &&
          removedDocumentIds.contains(record.pairedDocumentId)) {
        documents.add(
          record.copyWith(
            pairing: PairingState.single,
            clearPairing: true,
            overrides: [
              ...record.overrides,
              UserOverride(
                pairing: PairingState.single,
                fields: const ['pairing'],
              ),
            ],
          ),
        );
      } else {
        documents.add(record);
      }
    }

    final groups = <LayoutGroup>[];
    for (final group in p.layoutGroups) {
      final remainingIds = group.itemIds
          .where((id) => !removedIds.contains(id))
          .toList();
      if (dissolvedPairGroups.contains(group.id) ||
          remainingIds.isEmpty ||
          (group.itemIds.length > 1 && remainingIds.length < 2)) {
        continue;
      }
      groups.add(
        LayoutGroup(
          id: group.id,
          itemIds: remainingIds,
          arrangement: group.arrangement,
          keepTogether: group.keepTogether,
        ),
      );
    }
    final groupsById = {for (final group in groups) group.id: group};
    final consistentItems = [
      for (final item in items)
        if (item.groupId != null &&
            !(groupsById[item.groupId]?.itemIds.contains(item.id) ?? false))
          item.copyWith(clearGroupId: true)
        else
          item,
    ];
    return p.copyWith(
      items: consistentItems,
      documents: documents,
      layoutGroups: groups,
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

bool _fitsInArea(DocumentItem item, RectMm area) {
  final b = item.bounds;
  return b.width <= area.width + 1e-7 && b.height <= area.height + 1e-7;
}

bool _validPlacement(
  DocumentItem candidate,
  RectMm area,
  List<DocumentItem> others,
  double gx,
  double gy,
  bool allowOverlap,
) {
  if (!area.contains(candidate.bounds)) return false;
  if (allowOverlap) return true;
  for (final other in others) {
    if (_gapOverlap(candidate.bounds, other.bounds, gx, gy)) return false;
  }
  return true;
}

DocumentItem _topLeftPlacement(DocumentItem item, RectMm area) {
  final b = item.bounds;
  final x = area.x + (b.width - item.width) / 2;
  final y = area.y + (b.height - item.height) / 2;
  return item.copyWith(x: x, y: y);
}

DocumentItem? _findPlacement(
  DocumentItem item,
  RectMm area,
  List<DocumentItem> others,
  double gx,
  double gy,
  bool allowOverlap,
) {
  final b = item.bounds;
  const step = 1.0;
  for (double by = area.y; by + b.height <= area.bottom + 1e-7; by += step) {
    for (double bx = area.x; bx + b.width <= area.right + 1e-7; bx += step) {
      final candidate = item.copyWith(
        x: bx + (b.width - item.width) / 2,
        y: by + (b.height - item.height) / 2,
      );
      if (_validPlacement(candidate, area, others, gx, gy, allowOverlap)) {
        return candidate;
      }
    }
  }
  return null;
}

bool _gapOverlap(RectMm a, RectMm b, double x, double y) =>
    a.x < b.right + x - 1e-7 &&
    a.right + x > b.x + 1e-7 &&
    a.y < b.bottom + y - 1e-7 &&
    a.bottom + y > b.y + 1e-7;
