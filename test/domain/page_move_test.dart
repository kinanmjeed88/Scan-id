import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import '../fixtures.dart';

DocumentItem block(String id, double x, double y,
        {double width = 30, double height = 20, bool locked = false}) =>
    DocumentItem(
      id: id,
      assetId: 'asset1',
      x: x,
      y: y,
      width: width,
      height: height,
      locked: locked,
      sizeConfirmed: true,
    );

Project page(List<DocumentItem> items) =>
    projectFixture(assets: [assetFixture()], items: items);

void main() {
  test('moveToPage creates a new page and keeps the document printable', () {
    final p = page([block('one', 20, 20)]);
    final moved = PageLayout.moveToPage(p, 'one', 1);
    expect(moved.items.single.pageIndex, 1);
    expect(moved.pageCount, 2);
    expect(moved.paper.printable.contains(moved.items.single.bounds), isTrue);
  });

  test('moveToPage rejects a document larger than the printable area', () {
    final p = page([block('one', 20, 20, width: 250, height: 200)]);
    expect(
      () => PageLayout.moveToPage(p, 'one', 1),
      throwsA(isA<ValidationException>()),
    );
  });

  test('moveToPage keeps source and target consistent (no duplicate)', () {
    final p = page([block('one', 20, 20), block('two', 60, 20)]);
    final moved = PageLayout.moveToPage(p, 'one', 1);
    expect(moved.items.where((e) => e.id == 'one'), hasLength(1));
    expect(moved.items.firstWhere((e) => e.id == 'one').pageIndex, 1);
    expect(moved.items.firstWhere((e) => e.id == 'two').pageIndex, 0);
  });
}
