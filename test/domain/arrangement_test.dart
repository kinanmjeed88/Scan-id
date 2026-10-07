import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/document_kind.dart';
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
}
