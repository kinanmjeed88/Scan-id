import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import '../fixtures.dart';

DocumentItem block(
  String id,
  double x,
  double y, {
  double width = 30,
  double height = 20,
  double rotation = 0,
  bool locked = false,
}) => DocumentItem(
  id: id,
  assetId: 'asset1',
  x: x,
  y: y,
  width: width,
  height: height,
  rotation: rotation,
  locked: locked,
);
Project page(List<DocumentItem> items) =>
    projectFixture(assets: [assetFixture()], items: items);
void main() {
  final invalid = throwsA(isA<ValidationException>());
  test(
    'viewport scale preserves mm independently of display density and size',
    () {
      for (final width in [210.0, 420.0, 1050.0]) {
        final v = PageViewport(PaperSettings(), width, width * 297 / 210);
        final pixel = v.toView(85.6, 53.98);
        final mm = v.toMm(pixel.x, pixel.y);
        expect(mm.x, closeTo(85.6, 1e-9));
        expect(mm.y, closeTo(53.98, 1e-9));
      }
      expect(PaperSettings(orientation: PaperOrientation.landscape).width, 297);
    },
  );
  test('moves are immutable and bounds use rotated corners', () {
    final p = page([block('one', 30, 40, rotation: 45)]);
    final moved = PageLayout.move(p, 'one', 10, 20);
    expect(p.items.single.x, 30);
    expect(moved.items.single.x, 40);
    expect(
      () => PageLayout.move(p, 'one', -25, 0),
      throwsA(isA<ValidationException>()),
    );
  });
  test(
    'locking blocks move resize rotate and deletion, unlock restores control',
    () {
      final p = page([block('one', 30, 40, locked: true)]);
      expect(
        () => PageLayout.move(p, 'one', 1, 0),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => PageLayout.replace(p, p.items.single.copyWith(rotation: 20)),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => PageLayout.remove(p, {'one'}),
        throwsA(isA<ValidationException>()),
      );
      expect(
        PageLayout.move(
          PageLayout.lock(p, 'one', false),
          'one',
          1,
          0,
        ).items.single.x,
        31,
      );
    },
  );
  test(
    'aspect lock is explicit and free dimensions do not alter source metadata',
    () {
      final e = block('one', 20, 20);
      final resized = PageLayout.resize(e, 60, 99);
      expect(resized.height, 40);
      expect(
        PageLayout.resize(e.copyWith(keepAspectRatio: false), 60, 99).height,
        99,
      );
    },
  );
  test(
    'overlap requires explicit permission; bounds can never be bypassed',
    () {
      final p = page([block('one', 20, 20), block('two', 70, 20)]);
      expect(
        () => PageLayout.move(p, 'two', -30, 0),
        throwsA(isA<ValidationException>()),
      );
      expect(
        inspectLayout(PageLayout.move(p, 'two', -30, 0, allowOverlap: true)),
        hasLength(1),
      );
      expect(
        () => PageLayout.move(p, 'two', 300, 0, allowOverlap: true),
        throwsA(isA<ValidationException>()),
      );
    },
  );
  test('alignment uses rotated bounds and paper margins', () {
    final p = page([block('one', 40, 40, rotation: 30)]);
    final left = PageLayout.align(p, {'one'}, PageAlignment.left).items.single;
    expect(left.bounds.x, closeTo(10, 1e-9));
    final center = PageLayout.align(p, {
      'one',
    }, PageAlignment.centerX).items.single;
    expect(center.bounds.x + center.bounds.width / 2, closeTo(105, 1e-9));
  });
  test('distribution gives equal edge gaps with unequal dimensions', () {
    final p = page([
      block('one', 10, 20, width: 20),
      block('two', 50, 20, width: 30),
      block('three', 160, 20, width: 40),
    ]);
    final result = PageLayout.distribute(p, {
      'one',
      'two',
      'three',
    }, horizontal: true).items;
    expect(result[1].bounds.x - result[0].bounds.right, 50);
    expect(result[2].bounds.x - result[1].bounds.right, 50);
  });
  test('distribution rejects insufficient gap or locked members', () {
    final p = page([
      block('one', 10, 20),
      block('two', 41, 20),
      block('three', 72, 20),
    ]);
    expect(
      () => PageLayout.distribute(p, {'one', 'two', 'three'}, horizontal: true),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => PageLayout.align(PageLayout.lock(p, 'one', true), {
        'one',
      }, PageAlignment.top),
      throwsA(isA<ValidationException>()),
    );
  });
  test(
    'orientation and margins change atomically rather than dropping off-page items',
    () {
      final p = page([block('one', 20, 250)]);
      expect(
        () => PageLayout.checked(
          p.copyWith(
            paper: PaperSettings(orientation: PaperOrientation.landscape),
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(p.items.single.y, 250);
    },
  );
  test('duplicate/delete retain assets and all layout fields survive JSON', () {
    final p = page([block('one', 20, 20)]);
    final next = PageLayout.add(
      p,
      p.items.single.copyWith(id: 'two', x: 80, zIndex: 2),
    );
    final loaded = Project.fromJson(next.toJson());
    expect(loaded.items[1].toJson(), next.items[1].toJson());
    expect(PageLayout.remove(loaded, {'one'}).assets, hasLength(1));
  });

  test('copies start unplaced with fresh ids and can never collide', () {
    final source = block('item1', 20, 25, rotation: 90, locked: true);
    var counter = 0;
    final copies = PageLayout.copies(source, 3, () => 'copy${counter++}');
    expect(copies.map((e) => e.id), ['copy0', 'copy1', 'copy2']);
    expect(copies.every((e) => e.pageIndex == null), isTrue);
    expect(copies.every((e) => !e.locked), isTrue);
    expect(copies.every((e) => e.rotation == 90), isTrue);
    expect(copies.every((e) => e.width == source.width), isTrue);
    expect(copies.map((e) => e.zIndex), [source.zIndex + 1, source.zIndex + 2, source.zIndex + 3]);
  });

  test('copies are rejected beyond the sheet budget and never silently dropped', () {
    final source = block('item1', 20, 25);
    expect(
      () => PageLayout.copies(source, 201, () => 'copy'),
      invalid,
    );
    expect(PageLayout.copies(source, 0, () => 'copy'), isEmpty);
  });

  test('addMany validates the whole batch before anything is accepted', () {
    final base = page([block('item1', 20, 25)]);
    final accepted = PageLayout.addMany(base, [
      block('item2', 60, 25),
      block('item3', 100, 25),
    ]);
    expect(accepted.items, hasLength(3));
    expect(
      () => PageLayout.addMany(base, [
        block('item2', 60, 25),
        block('item3', 20, 25),
      ]),
      throwsA(
        predicate(
          (Object e) => e is ValidationException && e.message.contains('تداخل'),
        ),
      ),
    );
    expect(base.items, hasLength(1));
  });
}
