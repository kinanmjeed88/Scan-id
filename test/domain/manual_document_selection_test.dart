import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_document_selection.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/validation.dart';

/// A rectangle in normalized coordinates, given by its pixel box inside a
/// 1000 × 1000 source, so the tests read like a photograph.
List<Point2> _box(double left, double top, double right, double bottom) => [
  Point2(left / 1000, top / 1000),
  Point2(right / 1000, top / 1000),
  Point2(right / 1000, bottom / 1000),
  Point2(left / 1000, bottom / 1000),
];

ManualDocumentSelection _selection(
  String id, {
  List<Point2>? corners,
  DocumentKind kind = DocumentKind.unknown,
  SideKind side = SideKind.unknown,
}) => ManualDocumentSelection(
  id: id,
  corners: corners ?? _box(100, 100, 400, 300),
  kind: kind,
  side: side,
);

/// Point2 has no value equality, so corners are compared coordinate by
/// coordinate rather than by identity.
void _expectSameCorners(List<Point2> actual, List<Point2> expected) {
  expect(actual, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].x, expected[i].x, reason: 'corner $i x');
    expect(actual[i].y, expected[i].y, reason: 'corner $i y');
  }
}

void main() {
  group('one selection', () {
    test(
      'an empty selection is incomplete and says how many corners it needs',
      () {
        final empty = ManualDocumentSelection(id: 'a', corners: const []);
        expect(empty.isComplete, isFalse);
        expect(empty.issue, 'التحديد يحتاج 4 زاوية أخرى.');
        expect(empty.validatedCorners, isNull);
      },
    );

    test('tap order does not matter: corners are canonically ordered', () {
      // The same card tapped in a scrambled order must give the same ring.
      final scrambled = ManualDocumentSelection(
        id: 'a',
        corners: [
          Point2(.4, .3), // bottom right
          Point2(.1, .1), // top left
          Point2(.1, .3), // bottom left
          Point2(.4, .1), // top right
        ],
      );
      final ring = scrambled.validatedCorners;
      expect(ring, isNotNull);
      expect([ring![0].x, ring[0].y], [.1, .1]);
      expect([ring[1].x, ring[1].y], [.4, .1]);
      expect([ring[2].x, ring[2].y], [.4, .3]);
      expect([ring[3].x, ring[3].y], [.1, .3]);
      expect(scrambled.isValid, isTrue);
    });

    test('a corner outside the photograph is rejected with its own reason', () {
      final outside = ManualDocumentSelection(
        id: 'a',
        corners: [..._box(100, 100, 400, 300).take(3), Point2(1.2, .3)],
      );
      expect(outside.isValid, isFalse);
      expect(outside.issue, contains('خارج أبعاد الصورة'));
    });

    test(
      'a point inside the triangle of the other three is not a rectangle',
      () {
        final folded = ManualDocumentSelection(
          id: 'a',
          corners: [
            Point2(.1, .1),
            Point2(.5, .1),
            Point2(.5, .5),
            Point2(.15, .15), // lies inside the triangle, so no convex ring
          ],
        );
        expect(folded.isValid, isFalse);
        expect(folded.validatedCorners, isNull);
        expect(folded.issue, isNotNull);
      },
    );

    test('a collapsed sliver is rejected instead of cropped to nothing', () {
      // 0.8 wide by 0.00005 tall: under the shared normalized-area floor
      // (twiceArea <= 1e-4), so the geometry contract refuses it. The choice of
      // height is deliberate — 0.8 x 0.0001 is still above the floor and IS
      // accepted, which is the existing convention and not this test's subject.
      final sliver = ManualDocumentSelection(
        id: 'a',
        corners: [
          Point2(.1, .1),
          Point2(.9, .1),
          Point2(.9, .10005),
          Point2(.1, .10005),
        ],
      );
      expect(sliver.isValid, isFalse);
      expect(sliver.validatedCorners, isNull);
      expect(sliver.issue, contains('صفرية'));
    });

    test('output aspect follows the outlined shape, not a fixed ratio', () {
      // The aspect is measured on the NORMALIZED ring, so it describes the shape
      // of the outline inside the frame, not its size in source pixels.
      final wide = _selection('a', corners: _box(100, 100, 400, 300));
      final tall = _selection('b', corners: _box(100, 100, 300, 400));
      expect(wide.outputAspect, closeTo(1.5, 1e-9));
      expect(tall.outputAspect, closeTo(2 / 3, 1e-9));
      // outputAspect is nullable because an invalid selection has no shape; both
      // of these are valid, so the values are asserted non-null first.
      expect(wide.outputAspect, isNotNull);
      expect(tall.outputAspect, isNotNull);
      expect(wide.outputAspect!, greaterThan(tall.outputAspect!));
    });

    test('a per-document kind and side are kept independently', () {
      final card = _selection(
        'a',
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.front,
      );
      final ration = _selection('b', kind: DocumentKind.rationCard);
      expect(card.kind, DocumentKind.unifiedNationalId);
      expect(card.side, SideKind.front);
      expect(ration.kind, DocumentKind.rationCard);
      expect(ration.side, SideKind.unknown);
    });

    test('clearing the kind also drops a manual size measured for it', () {
      final withSize = _selection(
        'a',
        kind: DocumentKind.other,
      ).copyWith(customSizeMm: const PhysicalSizeMm(105, 72));
      expect(withSize.customSizeMm, isNotNull);
      final cleared = withSize.copyWith(
        kind: DocumentKind.unifiedNationalId,
        clearCustomSize: true,
      );
      expect(cleared.customSizeMm, isNull);
      expect(cleared.kind, DocumentKind.unifiedNationalId);
    });
  });

  group('the set of selections in one photograph', () {
    test('an empty set cannot be applied', () {
      expect(ManualSelectionSet.empty().canApply, isFalse);
    });

    test('several documents coexist without touching each other', () {
      var set = ManualSelectionSet.empty()
          .add(_selection('a', corners: _box(50, 50, 400, 300)))
          .add(_selection('b', corners: _box(450, 50, 900, 300)))
          .add(_selection('c', corners: _box(50, 400, 900, 900)));
      expect(set.length, 3);
      expect(set.valid, hasLength(3));
      expect(set.canApply, isTrue);

      // Changing one document's kind leaves the others exactly as they were.
      final before = set.byId('b')!;
      set = set.replace(set.byId('a')!.copyWith(kind: DocumentKind.passport));
      expect(set.byId('a')!.kind, DocumentKind.passport);
      expect(set.byId('b')!.kind, before.kind);
      expect(set.byId('b')!.corners, before.corners);
    });

    test('editing one corner of one document moves nothing else', () {
      var set = ManualSelectionSet.empty()
          .add(_selection('a', corners: _box(50, 50, 400, 300)))
          .add(_selection('b', corners: _box(450, 50, 900, 300)));
      final untouched = set.byId('b')!;
      set = set.moveCorner('a', 2, Point2(.44, .34));
      expect(set.byId('a')!.corners[2].x, .44);
      _expectSameCorners(set.byId('b')!.corners, untouched.corners);
    });

    test('adding a corner honours the cap, the point count and the spacing', () {
      var set = ManualSelectionSet.empty().add(
        ManualDocumentSelection(id: 'a', corners: const []),
      );
      set = set.addCorner('a', Point2(.1, .1), minSeparation: .01);
      expect(set.byId('a')!.corners, hasLength(1));
      // Too close to the first: refused rather than silently dropped.
      expect(
        () => set.addCorner('a', Point2(.1001, .1001), minSeparation: .01),
        throwsA(isA<ValidationException>()),
      );
      // Outside the photograph: refused with the point rule, not the spacing one.
      expect(
        () => set.addCorner('a', Point2(-.1, .2), minSeparation: .01),
        throwsA(isA<ValidationException>()),
      );
      set = set
          .addCorner('a', Point2(.9, .1), minSeparation: .01)
          .addCorner('a', Point2(.9, .9), minSeparation: .01)
          .addCorner('a', Point2(.1, .9), minSeparation: .01);
      expect(set.byId('a')!.isComplete, isTrue);
      // A fifth corner is refused: the document is already closed.
      expect(
        () => set.addCorner('a', Point2(.5, .5), minSeparation: .01),
        throwsA(isA<ValidationException>()),
      );
    });

    test(
      'the tenth document is allowed; the eleventh is refused with the number',
      () {
        var set = ManualSelectionSet.empty();
        for (var i = 0; i < ManualSelectionSet.maxSelections; i++) {
          set = set.add(ManualDocumentSelection(id: 's$i', corners: const []));
        }
        expect(set.length, ManualSelectionSet.maxSelections);
        expect(
          () =>
              set.add(ManualDocumentSelection(id: 'extra', corners: const [])),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              ManualSelectionSet.atCapacityMessage,
            ),
          ),
        );
      },
    );

    test('deleting one document leaves the rest intact and in order', () {
      var set = ManualSelectionSet.empty()
          .add(_selection('a', corners: _box(50, 50, 300, 300)))
          .add(_selection('b', corners: _box(350, 50, 600, 300)))
          .add(_selection('c', corners: _box(650, 50, 900, 300)));
      set = set.remove('b');
      expect(set.selections.map((s) => s.id), ['a', 'c']);
      _expectSameCorners(set.byId('a')!.corners, _box(50, 50, 300, 300));
    });

    test('two completed documents may not cover the same pixels', () {
      var set = ManualSelectionSet.empty().add(
        _selection('a', corners: _box(100, 100, 500, 400)),
      );
      expect(
        () => set.add(_selection('b', corners: _box(200, 150, 600, 450))),
        throwsA(isA<ValidationException>()),
      );
      // Directly beside it is fine: two cards can share a border.
      set = set.add(_selection('b', corners: _box(500, 100, 900, 400)));
      expect(set.length, 2);
    });

    test('an incomplete second document does not block the first', () {
      final set = ManualSelectionSet.empty()
          .add(_selection('a', corners: _box(100, 100, 400, 300)))
          .add(ManualDocumentSelection(id: 'b', corners: const []));
      expect(set.valid.map((s) => s.id), ['a']);
      expect(set.invalid.map((s) => s.id), ['b']);
      // All-or-nothing: applying only 'a' would silently drop 'b'.
      expect(set.canApply, isFalse);
    });

    test('every invalid selection is listed, not just the first', () {
      final set = ManualSelectionSet.empty()
          .add(ManualDocumentSelection(id: 'a', corners: const []))
          .add(ManualDocumentSelection(id: 'b', corners: const []));
      expect(set.invalid, hasLength(2));
      expect(set.canApply, isFalse);
    });

    test('a duplicate id and an unknown id are refused', () {
      final set = ManualSelectionSet.empty().add(_selection('a'));
      expect(
        () => set.add(_selection('a')),
        throwsA(isA<ValidationException>()),
      );
      expect(() => set.remove('missing'), throwsA(isA<ValidationException>()));
      expect(
        () => set.moveCorner('a', 9, Point2(.5, .5)),
        throwsA(isA<ValidationException>()),
      );
    });

    test('undo removes only the last corner of the active document', () {
      var set = ManualSelectionSet.empty().add(
        ManualDocumentSelection(id: 'a', corners: const []),
      );
      set = set
          .addCorner('a', Point2(.1, .1), minSeparation: .01)
          .addCorner('a', Point2(.9, .1), minSeparation: .01);
      set = set.undoCorner('a');
      expect(set.byId('a')!.corners, hasLength(1));
      expect(set.byId('a')!.corners.single.x, .1);
    });
  });

  group('overlap detection', () {
    test('separated rings do not overlap', () {
      expect(
        quadRingsOverlap(_box(0, 0, 400, 400), _box(500, 0, 900, 400)),
        isFalse,
      );
    });

    test('touching rings do not overlap', () {
      expect(
        quadRingsOverlap(_box(0, 0, 400, 400), _box(400, 0, 800, 400)),
        isFalse,
      );
    });

    test('partially overlapping rings do overlap', () {
      expect(
        quadRingsOverlap(_box(0, 0, 400, 400), _box(300, 300, 700, 700)),
        isTrue,
      );
    });

    test('one ring inside another overlaps', () {
      expect(
        quadRingsOverlap(_box(0, 0, 900, 900), _box(100, 100, 200, 200)),
        isTrue,
      );
    });

    test('rotated rings are handled, not just axis-aligned ones', () {
      // A diamond straddling the middle of a square: shapes overlap although
      // neither is axis aligned.
      final diamond = [
        Point2(.5, .1),
        Point2(.9, .5),
        Point2(.5, .9),
        Point2(.1, .5),
      ];
      expect(quadRingsOverlap(_box(0, 0, 1000, 1000), diamond), isTrue);
    });
  });
}
