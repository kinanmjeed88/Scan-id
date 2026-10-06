import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/packing.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import '../fixtures.dart';

DocumentItem card(
  String id,
  double w,
  double h, {
  bool locked = false,
  int? page = 0,
  double x = 10,
  double y = 10,
  double rotation = 0,
}) => DocumentItem(
  id: id,
  assetId: 'asset1',
  x: x,
  y: y,
  width: w,
  height: h,
  locked: locked,
  pageIndex: page,
  rotation: rotation,
);
Project page(List<DocumentItem> items) =>
    projectFixture(assets: [assetFixture()], items: items);
void assertSafe(Project p) {
  expect(inspectLayout(p), isEmpty);
  final items = p.items.where((e) => e.pageIndex != null).toList();
  for (var i = 0; i < items.length; i++) {
    final a = items[i].bounds;
    for (final other in items.take(i)) {
      if (other.pageIndex != items[i].pageIndex) continue;
      final b = other.bounds;
      final separate =
          a.right + p.layout.horizontalGap <= b.x + 1e-6 ||
          b.right + p.layout.horizontalGap <= a.x + 1e-6 ||
          a.bottom + p.layout.verticalGap <= b.y + 1e-6 ||
          b.bottom + p.layout.verticalGap <= a.y + 1e-6;
      expect(separate, true, reason: '${items[i].id} / ${other.id}');
    }
  }
}

void main() {
  test(
    'proposal preserves original snapshot and places unequal sizes with exact gaps',
    () {
      final p = page([card('a', 80, 50), card('b', 70, 40), card('c', 40, 90)]);
      final before = p.toJson();
      final result = proposePacking(
        p,
        includeLocked: false,
        allowRotation: false,
      );
      expect(p.toJson(), before);
      expect(result.unplaced, isEmpty);
      assertSafe(result.result);
      for (var i = 0; i < p.items.length; i++) {
        expect(result.result.items[i].width, p.items[i].width);
        expect(result.result.items[i].height, p.items[i].height);
      }
    },
  );
  test(
    'oversize and insufficient area are reported and retained as unplaced metadata',
    () {
      final p = page([
        card('oversize', 400, 300),
        card('a', 180, 260),
        card('b', 180, 260),
      ]);
      final proposal = proposePacking(
        p,
        includeLocked: false,
        allowRotation: false,
      );
      expect(proposal.unplaced, contains('oversize'));
      expect(proposal.unplaced, hasLength(2));
      expect(proposal.result.items, hasLength(3));
      final reopened = Project.fromJson(proposal.result.toJson());
      expect(reopened.items.where((e) => e.pageIndex == null), hasLength(2));
      assertSafe(reopened);
    },
  );
  test('optional rotation fits a document without scaling it', () {
    final p = page([card('a', 250, 160)]);
    expect(
      proposePacking(p, includeLocked: false, allowRotation: false).unplaced,
      ['a'],
    );
    final rotated = proposePacking(
      p,
      includeLocked: false,
      allowRotation: true,
    );
    expect(rotated.unplaced, isEmpty);
    expect(rotated.result.items.single.rotation, 90);
    expect(rotated.result.items.single.width, 250);
    assertSafe(rotated.result);
  });
  test('unlocked mode preserves locked obstacles and all mode is explicit', () {
    final p = page([
      card('fixed', 50, 40, locked: true, x: 80, y: 80),
      card('moving', 60, 50),
    ]);
    final proposal = proposePacking(
      p,
      includeLocked: false,
      allowRotation: true,
    );
    expect(proposal.result.items.first.toJson(), p.items.first.toJson());
    assertSafe(proposal.result);
    final all = proposePacking(p, includeLocked: true, allowRotation: false);
    expect(all.result.items.first.locked, true);
    assertSafe(all.result);
  });
  test(
    'invalid fixed obstacles are rejected, never advertised as a solution',
    () {
      expect(
        () => proposePacking(
          page([
            card('a', 50, 50, locked: true),
            card('b', 50, 50, locked: true),
          ]),
          includeLocked: false,
          allowRotation: false,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => proposePacking(
          page([card('a', 300, 300, locked: true)]),
          includeLocked: false,
          allowRotation: false,
        ),
        throwsA(isA<ValidationException>()),
      );
    },
  );
  test(
    'other pages are unchanged and unplaced items can move to another page',
    () {
      final p = page([
        card('a', 40, 40, page: 0),
        card('b', 40, 40, page: null),
      ]).copyWith(pageCount: 2);
      final result = proposePacking(
        p,
        includeLocked: false,
        allowRotation: false,
        pageIndex: 1,
      ).result;
      expect(result.items.first.toJson(), p.items.first.toJson());
      expect(result.items.last.pageIndex, 1);
      assertSafe(result);
    },
  );
  test(
    'schema two migrates to page zero and invalid page references are rejected',
    () {
      final old = page([card('a', 40, 30)]).toJson()
        ..['schemaVersion'] = 2
        ..remove('pageCount');
      ((old['items'] as List).single as Map).remove('pageIndex');
      expect(Project.fromJson(old).items.single.pageIndex, 0);
      expect(
        () => page([card('a', 40, 30, page: 5)]),
        throwsA(isA<ValidationException>()),
      );
    },
  );
  test(
    'seeded mixed-size and rotated cases never violate margins gaps or fixed sizes',
    () {
      final random = Random(20261006);
      for (var sample = 0; sample < 25; sample++) {
        final p = page([
          for (var i = 0; i < 30; i++)
            card(
              'item$i',
              15 + random.nextDouble() * 130,
              15 + random.nextDouble() * 100,
              rotation: i % 3 == 0 ? 30 : 0,
            ),
        ]);
        final result = proposePacking(
          p,
          includeLocked: false,
          allowRotation: true,
        ).result;
        assertSafe(result);
        expect(result.items.map((e) => e.width), p.items.map((e) => e.width));
        expect(result.items.map((e) => e.height), p.items.map((e) => e.height));
      }
    },
  );
}
