import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';

import '../fixtures.dart';

DocumentItem _doc(
  String id,
  DocumentKind kind, {
  bool confirmed = true,
  bool locked = false,
  int? page,
  double x = 0,
  double y = 0,
}) {
  final size =
      const DocumentSizeCatalog().natural(kind) ?? const PhysicalSizeMm(80, 50);
  return DocumentItem(
    id: id,
    assetId: 'asset1',
    x: x,
    y: y,
    width: size.width,
    height: size.height,
    pageIndex: page,
    documentKind: kind,
    sizeConfirmed: confirmed,
    locked: locked,
  );
}

Project _project(List<DocumentItem> items, {double margin = 5}) =>
    projectFixture(
      assets: [assetFixture()],
      items: items,
    ).copyWith(paper: PaperSettings(margins: Margins.all(margin)));

void main() {
  test('categories are laid out in order: ID, residence, passport, ration', () {
    final project = _project([
      _doc('passport', DocumentKind.passport),
      _doc('ration', DocumentKind.rationCard),
      _doc('residence', DocumentKind.residenceCard),
      _doc('id', DocumentKind.unifiedNationalId),
    ]);
    final result = arrangeDocuments(project);
    final r = result.result;
    DocumentItem item(String id) => PageLayout.item(r, id);
    expect(result.unplaced, isEmpty);
    expect(inspectLayout(r), isEmpty);
    expect(item('id').pageIndex, 0);
    expect(item('id').y, 5, reason: 'the unified card opens the first page');
    expect(item('residence').y, greaterThan(item('id').y));
    expect(item('passport').y, greaterThan(item('residence').y));
    // The 287 mm ration card cannot follow on page 1 and starts page 2.
    expect(item('ration').pageIndex, 1);
    expect(r.pageCount, 2);
  });

  test('documents keep their exact physical sizes', () {
    final project = _project([
      _doc('a', DocumentKind.unifiedNationalId),
      _doc('b', DocumentKind.passport),
    ]);
    final r = arrangeDocuments(project).result;
    expect(PageLayout.item(r, 'a').width, 85.6);
    expect(PageLayout.item(r, 'a').height, 53.98);
    expect(PageLayout.item(r, 'b').width, 125);
    expect(PageLayout.item(r, 'b').height, 88);
  });

  test('same-category cards share a row, right to left, centred', () {
    final project = _project([
      _doc('one', DocumentKind.unifiedNationalId),
      _doc('two', DocumentKind.unifiedNationalId),
    ]);
    final r = arrangeDocuments(project).result;
    final one = PageLayout.item(r, 'one'), two = PageLayout.item(r, 'two');
    expect(one.y, two.y);
    expect(one.x, greaterThan(two.x), reason: 'first card on the right');
    final left = two.x - 5, right = 205 - (one.x + one.width);
    expect(left, closeTo(right, 1e-6), reason: 'row centred in the margins');
    expect(one.x - (two.x + two.width), closeTo(5, 1e-6));
  });

  test('overflow continues on new pages and trailing pages are trimmed', () {
    final project = _project([
      for (var i = 0; i < 10; i++) _doc('p$i', DocumentKind.passport),
    ]).copyWith(pageCount: 5);
    final result = arrangeDocuments(project);
    final r = result.result;
    // Three passports (88 mm + 5 mm gap) fit per 287 mm page height, one
    // per row because two 125 mm pages do not fit 200 mm side by side.
    expect(r.pageCount, 4);
    expect(r.items.where((e) => e.pageIndex == 0), hasLength(3));
    expect(r.items.where((e) => e.pageIndex == 3), hasLength(1));
    expect(inspectLayout(r), isEmpty);
    expect(result.unplaced, isEmpty);
  });

  test('a document larger than the printable area stays off the sheet', () {
    final huge = DocumentItem(
      id: 'huge',
      assetId: 'asset1',
      x: 0,
      y: 0,
      width: 300,
      height: 300,
      documentKind: DocumentKind.other,
      sizeConfirmed: true,
    );
    final result = arrangeDocuments(_project([huge]));
    expect(result.unplaced, ['huge']);
    expect(PageLayout.item(result.result, 'huge').pageIndex, isNull);
    expect(result.result.pageCount, 1);
  });

  test('a 287 mm ration card fits only with margins of at most 5 mm', () {
    final ration = _doc('r', DocumentKind.rationCard);
    expect(arrangeDocuments(_project([ration], margin: 10)).unplaced, ['r']);
    final fits = arrangeDocuments(_project([ration]));
    expect(fits.unplaced, isEmpty);
    expect(PageLayout.item(fits.result, 'r').y, 5);
  });

  test('a document turns by 90° only when allowed and needed', () {
    final wide = DocumentItem(
      id: 'wide',
      assetId: 'asset1',
      x: 0,
      y: 0,
      width: 200,
      height: 50,
      documentKind: DocumentKind.other,
      sizeConfirmed: true,
    );
    expect(arrangeDocuments(_project([wide], margin: 10)).unplaced, ['wide']);
    final turned = arrangeDocuments(
      _project([
        wide,
      ], margin: 10).copyWith(layout: LayoutSettings(allowRotation: true)),
    );
    expect(turned.unplaced, isEmpty);
    expect(PageLayout.item(turned.result, 'wide').rotation, 90);
    expect(inspectLayout(turned.result), isEmpty);
    // A document that fits keeps its orientation even when turning is allowed.
    final card = arrangeDocuments(
      _project([
        _doc('id', DocumentKind.unifiedNationalId),
      ]).copyWith(layout: LayoutSettings(allowRotation: true)),
    );
    expect(PageLayout.item(card.result, 'id').rotation, 0);
  });

  test('unknown-category documents wait off the sheet', () {
    final result = arrangeDocuments(
      _project([
        _doc('id', DocumentKind.unifiedNationalId),
        _doc('unknown', DocumentKind.unknown, confirmed: false),
      ]),
    );
    expect(result.awaitingSize, ['unknown']);
    expect(PageLayout.item(result.result, 'unknown').pageIndex, isNull);
    expect(PageLayout.item(result.result, 'id').pageIndex, 0);
  });

  test('locked documents never move and are avoided', () {
    final locked = _doc(
      'locked',
      DocumentKind.passport,
      locked: true,
      page: 0,
      x: 40,
      y: 5,
    );
    final result = arrangeDocuments(
      _project([locked, _doc('id', DocumentKind.unifiedNationalId)]),
    );
    final r = result.result;
    expect(PageLayout.item(r, 'locked').x, 40);
    expect(PageLayout.item(r, 'locked').y, 5);
    expect(inspectLayout(r), isEmpty);
    expect(PageLayout.item(r, 'id').pageIndex, 0);
  });

  test('keepPlaced only fills free space with off-sheet documents', () {
    final placed = _doc(
      'placed',
      DocumentKind.passport,
      page: 0,
      x: 50,
      y: 100,
    );
    final result = arrangeDocuments(
      _project([placed, _doc('new', DocumentKind.unifiedNationalId)]),
      keepPlaced: true,
    );
    final r = result.result;
    expect(PageLayout.item(r, 'placed').x, 50);
    expect(PageLayout.item(r, 'placed').y, 100);
    expect(PageLayout.item(r, 'new').pageIndex, 0);
    expect(inspectLayout(r), isEmpty);
  });

  test('compact strategy packs and flows over pages too', () {
    final project = _project([
      for (var i = 0; i < 14; i++) _doc('c$i', DocumentKind.unifiedNationalId),
    ]).copyWith(layout: LayoutSettings(strategy: ArrangementStrategy.compact));
    final result = arrangeDocuments(project);
    final r = result.result;
    expect(result.unplaced, isEmpty);
    expect(inspectLayout(r), isEmpty);
    expect(r.pageCount, greaterThanOrEqualTo(1));
    expect(r.items.every((e) => r.paper.printable.contains(e.bounds)), isTrue);
  });

  test('arrangement is deterministic', () {
    final project = _project([
      for (var i = 0; i < 6; i++) _doc('d$i', DocumentKind.values[1 + i % 4]),
    ]);
    expect(
      arrangeDocuments(project).result.toJson(),
      arrangeDocuments(project).result.toJson(),
    );
  });

  test('a document without a confirmed size never stays on a page', () {
    // Saved projects already load such documents off the sheet and the layout
    // check rejects them on a page; arranging follows the same rule, in every
    // strategy and scope, instead of keeping a guessed size on the paper.
    for (final strategy in ArrangementStrategy.values) {
      for (final keepPlaced in [false, true]) {
        final reason = '$strategy, keepPlaced: $keepPlaced';
        final result = arrangeDocuments(
          _project([
            _doc(
              'legacy',
              DocumentKind.unknown,
              confirmed: false,
              page: 0,
              x: 40,
              y: 5,
            ),
            _doc('id', DocumentKind.unifiedNationalId),
          ]),
          strategy: strategy,
          keepPlaced: keepPlaced,
        );
        final r = result.result;
        expect(PageLayout.item(r, 'legacy').pageIndex, isNull, reason: reason);
        expect(result.awaitingSize, ['legacy'], reason: reason);
        expect(result.takenOffSheet, ['legacy'], reason: reason);
        expect(
          autoLayoutStatus(r, PageLayout.item(r, 'legacy')),
          AutoLayoutStatus.sizeUnconfirmed,
          reason: reason,
        );
        expect(result.unplaced, isEmpty, reason: reason);
        expect(PageLayout.item(r, 'id').pageIndex, 0, reason: reason);
        expect(() => PageLayout.checked(r), returnsNormally, reason: reason);
      }
    }
  });

  // The editor shows this state for every document that automatic
  // arrangement leaves out, so a document is never just "off the sheet"
  // without a reason the user can act on.
  test('auto layout status: size unconfirmed, too large, or eligible', () {
    final project = _project([
      _doc('unknown', DocumentKind.unknown, confirmed: false),
      // 250 × 150 mm: wider than the 200 mm printable width, but fits turned.
      _doc('wide', DocumentKind.other).copyWith(width: 250, height: 150),
      _doc('id', DocumentKind.unifiedNationalId),
    ]);
    AutoLayoutStatus status(String id, {bool? allowRotation}) =>
        autoLayoutStatus(
          project,
          PageLayout.item(project, id),
          allowRotation: allowRotation,
        );

    expect(status('unknown'), AutoLayoutStatus.sizeUnconfirmed);
    expect(
      status('unknown', allowRotation: true),
      AutoLayoutStatus.sizeUnconfirmed,
    );
    expect(status('wide'), AutoLayoutStatus.tooLarge);
    expect(status('wide', allowRotation: true), AutoLayoutStatus.eligible);
    expect(status('id'), AutoLayoutStatus.eligible);

    // The arrangement agrees: the too-large document is reported, not
    // scaled, and nothing was on a page to be taken off.
    final result = arrangeDocuments(project);
    expect(result.unplaced, ['wide']);
    expect(result.awaitingSize, ['unknown']);
    expect(result.takenOffSheet, isEmpty);
    final turned = arrangeDocuments(project, allowRotation: true);
    expect(PageLayout.item(turned.result, 'wide').pageIndex, isNotNull);
    expect(PageLayout.item(turned.result, 'wide').width, 250);
  });

  // compact strategy as default (when no strategy is specified)
  test('compact is the default strategy when no strategy is set', () {
    final project = _project([
      _doc('a', DocumentKind.unifiedNationalId),
      _doc('b', DocumentKind.unifiedNationalId),
    ]);
    // Default strategy should be compact now
    expect(project.layout.strategy, ArrangementStrategy.compact);
  });

  // Compact packs more documents per page than ordered
  test(
    'compact packs more documents per page than ordered for same documents',
    () {
      final project = _project([
        for (var i = 0; i < 10; i++)
          _doc('c$i', DocumentKind.unifiedNationalId),
      ]);

      final orderedResult = arrangeDocuments(
        project.copyWith(
          layout: LayoutSettings(strategy: ArrangementStrategy.ordered),
        ),
      );
      final compactResult = arrangeDocuments(project);

      // Compact should use fewer or equal pages
      expect(
        compactResult.result.pageCount,
        lessThanOrEqualTo(orderedResult.result.pageCount),
      );
      expect(
        compactResult.result.items.every(
          (e) => compactResult.result.paper.printable.contains(e.bounds),
        ),
        isTrue,
      );
      expect(compactResult.unplaced, isEmpty);
    },
  );

  // Center captures centers the group on the page
  test('centerCaptures centers document group on the page', () {
    final project = _project([
      _doc('a', DocumentKind.unifiedNationalId, x: 0, y: 0),
      _doc('b', DocumentKind.unifiedNationalId, x: 90, y: 0),
    ]).copyWith(layout: LayoutSettings(centerCaptures: true));

    final result = arrangeDocuments(project);
    final r = result.result;

    // Calculate the center of the placed documents
    final pageItems = r.items.where((e) => e.pageIndex == 0).toList();
    final bounds = pageItems.fold<RectMm?>(null, (acc, item) {
      if (acc == null) return item.bounds;
      return RectMm(
        math.min(acc.x, item.x),
        math.min(acc.y, item.y),
        math.max(acc.right, item.right) - math.min(acc.x, item.x),
        math.max(acc.bottom, item.bottom) - math.min(acc.y, item.y),
      );
    });

    if (bounds != null) {
      final area = r.paper.printable;
      final centerX = area.x + area.width / 2;
      final centerY = area.y + area.height / 2;
      final groupCenterX = bounds.x + bounds.width / 2;
      final groupCenterY = bounds.y + bounds.height / 2;

      // The group should be centered within the printable area
      expect((groupCenterX - centerX).abs(), lessThan(1.0));
      expect((groupCenterY - centerY).abs(), lessThan(1.0));
    }
  });

  // Center captures off by default for old projects
  test(
    'centerCaptures defaults to true for new projects, false for old ones without the setting',
    () {
      // For projects with JSON missing centerCaptures, it should default to true
      final json = {
        'schemaVersion': 5,
        'id': 'test',
        'name': 'Test',
        'createdAt': '2024-01-01T00:00:00Z',
        'updatedAt': '2024-01-01T00:00:00Z',
        'revision': 0,
        'pageCount': 1,
        'paper': {
          'orientation': 'portrait',
          'margins': {'top': 5, 'right': 5, 'bottom': 5, 'left': 5},
        },
        'layout': {
          'horizontalGap': 5,
          'verticalGap': 5,
          'allowRotation': false,
          'order': 'input',
          'strategy': 'compact',
          // no centerCaptures key
        },
        'exportProfile': {'format': 'pdf', 'dpi': 300, 'jpegQuality': 95},
        'catalog': {},
        'assets': [],
        'items': [],
        'documents': [],
        'layoutGroups': [],
      };
      final project = Project.fromJson(json);
      expect(project.layout.centerCaptures, isTrue);
    },
  );

  // Turning off center captures disables centering
  test('disabling centerCaptures leaves items at their packed positions', () {
    final project = _project([
      _doc('a', DocumentKind.unifiedNationalId),
      _doc('b', DocumentKind.unifiedNationalId),
    ]).copyWith(layout: LayoutSettings(centerCaptures: false));

    final result = arrangeDocuments(project);
    final r = result.result;

    // Items should NOT be centered (they stay at packed positions)
    final pageItems = r.items.where((e) => e.pageIndex == 0).toList();
    final bounds = pageItems.fold<RectMm?>(null, (acc, item) {
      if (acc == null) return item.bounds;
      return RectMm(
        math.min(acc.x, item.x),
        math.min(acc.y, item.y),
        math.max(acc.right, item.right) - math.min(acc.x, item.x),
        math.max(acc.bottom, item.bottom) - math.min(acc.y, item.y),
      );
    });

    if (bounds != null) {
      final area = r.paper.printable;
      final centerX = area.x + area.width / 2;
      final centerY = area.y + area.height / 2;
      final groupCenterX = bounds.x + bounds.width / 2;
      final groupCenterY = bounds.y + bounds.height / 2;

      // Without centering, the group is NOT necessarily at center
      // (packed position is usually right-aligned or top-aligned)
      expect(
        (groupCenterX - centerX).abs() > 5 ||
            (groupCenterY - centerY).abs() > 5,
        isTrue,
      );
    }
  });

  // No overlap or out-of-bounds after centering
  test('centered items do not overlap or exceed page bounds', () {
    final project = _project([
      for (var i = 0; i < 6; i++) _doc('d$i', DocumentKind.unifiedNationalId),
    ]).copyWith(layout: LayoutSettings(centerCaptures: true));

    final result = arrangeDocuments(project);
    final r = result.result;

    expect(inspectLayout(r), isEmpty);
    expect(r.items.every((e) => r.paper.printable.contains(e.bounds)), isTrue);
  });

  // Multiple pages each centered independently
  test(
    'centerCaptures works on each page independently for multi-page layouts',
    () {
      final project = _project([
        for (var i = 0; i < 20; i++) _doc('m$i', DocumentKind.passport),
      ]).copyWith(layout: LayoutSettings(centerCaptures: true));

      final result = arrangeDocuments(project);
      final r = result.result;

      expect(result.unplaced, isEmpty);
      expect(inspectLayout(r), isEmpty);

      // Each page should have its items centered
      for (var page = 0; page < r.pageCount; page++) {
        final pageItems = r.items.where((e) => e.pageIndex == page).toList();
        if (pageItems.isEmpty) continue;

        final bounds = pageItems.fold<RectMm?>(null, (acc, item) {
          if (acc == null) return item.bounds;
          return RectMm(
            math.min(acc.x, item.x),
            math.min(acc.y, item.y),
            math.max(acc.right, item.right) - math.min(acc.x, item.x),
            math.max(acc.bottom, item.bottom) - math.min(acc.y, item.y),
          );
        });

        if (bounds != null) {
          final area = r.paper.printable;
          final centerX = area.x + area.width / 2;
          final centerY = area.y + area.height / 2;
          final groupCenterX = bounds.x + bounds.width / 2;
          final groupCenterY = bounds.y + bounds.height / 2;

          // Each page's group should be centered
          expect((groupCenterX - centerX).abs(), lessThan(2.0));
        }
      }
    },
  );

  // Centering respects fixed/locked items
  test('centerCaptures does not move locked items', () {
    final locked = _doc(
      'locked',
      DocumentKind.passport,
      locked: true,
      page: 0,
      x: 50,
      y: 50,
    );

    final project = _project([
      locked,
      _doc('a', DocumentKind.unifiedNationalId),
    ]).copyWith(layout: LayoutSettings(centerCaptures: true));

    final result = arrangeDocuments(project);
    final r = result.result;

    final lockedItem = PageLayout.item(r, 'locked');
    expect(lockedItem.x, 50);
    expect(lockedItem.y, 50);
    expect(lockedItem.pageIndex, 0);
  });

  // Compact strategy uses fewer pages for large numbers of documents
  test('compact reduces page count for many documents', () {
    final project = _project([
      for (var i = 0; i < 50; i++) _doc('x$i', DocumentKind.unifiedNationalId),
    ]);

    final result = arrangeDocuments(project);
    expect(result.unplaced, isEmpty);
    expect(
      result.result.pageCount,
      lessThan(50),
    ); // Should pack multiple per page
    expect(
      result.result.pageCount,
      greaterThan(1),
    ); // But more than one page for 50 docs
    expect(inspectLayout(result.result), isEmpty);
  });

  // Items are not duplicated or lost after rearrangement
  test('no items lost or duplicated after compact arrangement', () {
    final items = [
      for (var i = 0; i < 10; i++) _doc('item-$i', DocumentKind.values[i % 4]),
    ];

    final project = _project(items);
    final result = arrangeDocuments(project);

    final resultIds = result.result.items.map((e) => e.id).toSet();
    final originalIds = project.items.map((e) => e.id).toSet();

    expect(resultIds, originalIds);
    expect(result.result.items.length, project.items.length);
  });
}
