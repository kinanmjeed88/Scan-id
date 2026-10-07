import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';

import 'editor_harness.dart';

/// Pointer and keyboard input on the A4 sheet. Android is used by touch and
/// Windows by mouse, keyboard and touchpad, so each rule is checked per
/// device: what moves a document, what resizes it, what scrolls the pages and
/// what zooms. Expected positions are exact millimetres.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'touch: a selected document follows the finger and the pages stay put',
    (tester) async {
      final editor = await EditorHarness.pump(tester, project: _twoCards());
      await tapKey(tester, const Key('page-item-card'));
      final scale = pageScale(tester);
      final scrolled = _scrollOffset(tester);

      // Upwards, the direction in which the pages could scroll.
      await _swipe(
        tester,
        _centre(tester, 'card'),
        _steps(Offset(0, -15 * scale)),
        PointerDeviceKind.touch,
      );

      final card = itemIn(editor.saved, 'card');
      expect(card.x, closeTo(10, .05));
      expect(card.y, closeTo(15, .05));
      expect(_scrollOffset(tester), scrolled);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'touch: swiping over the paper or an unselected document scrolls the pages',
    (tester) async {
      final editor = await EditorHarness.pump(tester, project: _twoCards());
      final revision = editor.saved.revision;

      var scrolled = _scrollOffset(tester);
      await _swipe(
        tester,
        _emptyPaper(tester),
        _steps(const Offset(0, -150)),
        PointerDeviceKind.touch,
      );
      expect(_scrollOffset(tester), greaterThan(scrolled));

      scrolled = _scrollOffset(tester);
      await _swipe(
        tester,
        _centre(tester, 'card'),
        _steps(const Offset(0, -150)),
        PointerDeviceKind.touch,
      );
      expect(_scrollOffset(tester), greaterThan(scrolled));

      expect(editor.saved.revision, revision, reason: 'nothing was edited');
      expect(firstCanvas(tester).selected, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'touch: a sideways swipe over an unselected document does not move it',
    (tester) async {
      final editor = await EditorHarness.pump(tester, project: _twoCards());
      final revision = editor.saved.revision;

      await _swipe(
        tester,
        _centre(tester, 'card'),
        _steps(const Offset(120, 0)),
        PointerDeviceKind.touch,
      );

      expect(itemIn(editor.saved, 'card').x, 10);
      expect(editor.saved.revision, revision, reason: 'nothing was edited');
      expect(firstCanvas(tester).selected, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('touch: the resize handle resizes; it neither moves nor scrolls', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester, project: _twoCards());
    await tapKey(tester, const Key('page-item-card'));
    final scale = pageScale(tester);
    final scrolled = _scrollOffset(tester);

    await _swipe(
      tester,
      tester.getCenter(find.byKey(const Key('resize-card'))),
      _steps(Offset(0, -10 * scale)),
      PointerDeviceKind.touch,
    );

    // The aspect ratio is locked, so the dragged height decides the width.
    final card = itemIn(editor.saved, 'card');
    expect(card.height, closeTo(43.98, .05));
    expect(card.width, closeTo(43.98 * 85.6 / 53.98, .05));
    expect(card.sizeConfirmed, isTrue);
    expect(_scrollOffset(tester), scrolled);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a turned document moves in page millimetres and resizes along its edges',
    (tester) async {
      final editor = await EditorHarness.pump(
        tester,
        project: _twoCards(cardRotation: 90, cardY: 25),
      );
      // The whole page in view keeps both handles on screen.
      await tapKey(tester, const Key('ribbon-tab-view'));
      await tapKey(tester, const Key('rb-zoom-page'));
      await tapKey(tester, const Key('page-item-card'));
      final scale = pageScale(tester);

      await _swipe(
        tester,
        _centre(tester, 'card'),
        _steps(Offset(10 * scale, 0)),
        PointerDeviceKind.touch,
      );
      var card = itemIn(editor.saved, 'card');
      expect(card.x, closeTo(20, .05));
      expect(card.y, closeTo(25, .05));
      expect(card.rotation, 90);

      // Turned by 90°, the document's own width runs down the screen.
      await _swipe(
        tester,
        tester.getCenter(find.byKey(const Key('resize-card'))),
        _steps(Offset(0, 10 * scale)),
        PointerDeviceKind.touch,
      );
      card = itemIn(editor.saved, 'card');
      expect(card.width, closeTo(95.6, .05));
      expect(card.height, closeTo(95.6 * 53.98 / 85.6, .05));
      expect(card.rotation, 90);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a locked document never moves: no handle, drags scroll, keys do nothing',
    (tester) async {
      final editor = await EditorHarness.pump(
        tester,
        project: _twoCards(cardLocked: true),
      );
      final revision = editor.saved.revision;
      await tapKey(tester, const Key('page-item-card'));
      expect(firstCanvas(tester).selected, {'card'});
      expect(find.byKey(const Key('resize-card')), findsNothing);

      final scrolled = _scrollOffset(tester);
      await _swipe(
        tester,
        _centre(tester, 'card'),
        _steps(const Offset(0, -150)),
        PointerDeviceKind.touch,
      );
      expect(_scrollOffset(tester), greaterThan(scrolled));

      await _swipe(
        tester,
        _centre(tester, 'card'),
        _steps(const Offset(80, 0)),
        PointerDeviceKind.mouse,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final card = itemIn(editor.saved, 'card');
      expect([card.x, card.y], [10, 30]);
      expect(editor.saved.revision, revision, reason: 'nothing was edited');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Ctrl-click builds a multi-selection; a drag moves only the grabbed one',
    (tester) async {
      final editor = await EditorHarness.pump(tester, project: _twoCards());
      await tapKey(tester, const Key('page-item-card'));
      await _ctrlClick(tester, 'residence');
      expect(firstCanvas(tester).selected, {'card', 'residence'});
      expect(find.byKey(const Key('resize-card')), findsOneWidget);
      expect(find.byKey(const Key('resize-residence')), findsOneWidget);

      final scale = pageScale(tester);
      await _swipe(
        tester,
        _centre(tester, 'residence'),
        _steps(Offset(0, -10 * scale)),
        PointerDeviceKind.touch,
      );
      expect(itemIn(editor.saved, 'residence').y, closeTo(20, .05));
      expect(itemIn(editor.saved, 'card').y, 30);

      // Ctrl-press on a selected document takes it out of the selection
      // instead of moving it.
      await _ctrlClick(tester, 'card');
      expect(firstCanvas(tester).selected, {'residence', 'card'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await _swipe(
        tester,
        _centre(tester, 'card'),
        _steps(Offset(10 * scale, 0)),
        PointerDeviceKind.mouse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(firstCanvas(tester).selected, {'residence'});
      expect(itemIn(editor.saved, 'card').x, 10);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mouse: any unlocked document drags at once; dragging the paper never scrolls',
    (tester) async {
      final editor = await EditorHarness.pump(tester, project: _twoCards());
      final scale = pageScale(tester);

      // Unselected: the drag starts once the 2 px mouse slop is passed.
      await _swipe(tester, _centre(tester, 'card'), [
        const Offset(4, 0),
        ..._steps(Offset(10 * scale, 0)),
      ], PointerDeviceKind.mouse);
      expect(itemIn(editor.saved, 'card').x, closeTo(20, .05));
      expect(firstCanvas(tester).selected, {'card'});

      // Selected: the drag starts on the press itself.
      await _swipe(
        tester,
        _centre(tester, 'card'),
        _steps(Offset(0, -10 * scale)),
        PointerDeviceKind.mouse,
      );
      expect(itemIn(editor.saved, 'card').y, closeTo(20, .05));

      final revision = editor.saved.revision;
      final scrolled = _scrollOffset(tester);
      await _swipe(
        tester,
        _emptyPaper(tester),
        _steps(const Offset(0, -150)),
        PointerDeviceKind.mouse,
      );
      expect(_scrollOffset(tester), scrolled);
      expect(editor.saved.revision, revision, reason: 'nothing was edited');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('touchpad: two-finger swipes scroll and never move documents', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester, project: _twoCards());
    await tapKey(tester, const Key('page-item-card'));
    final revision = editor.saved.revision;

    await _touchpadSwipe(tester, _centre(tester, 'card'), const Offset(120, 0));
    await _touchpadSwipe(
      tester,
      _centre(tester, 'residence'),
      const Offset(-120, 0),
    );
    expect(itemIn(editor.saved, 'card').x, 10);
    expect(itemIn(editor.saved, 'residence').x, 112);

    final scrolled = _scrollOffset(tester);
    await _touchpadSwipe(tester, _centre(tester, 'card'), const Offset(0, -150));
    expect(_scrollOffset(tester), isNot(scrolled));
    expect(editor.saved.revision, revision, reason: 'nothing was edited');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'touch: pinching over a selected document zooms and leaves it in place',
    (tester) async {
      final editor = await EditorHarness.pump(tester, project: _twoCards());
      await tapKey(tester, const Key('page-item-card'));
      final revision = editor.saved.revision;
      final zoom = _zoom(tester);

      final centre = _centre(tester, 'card');
      final left = await tester.startGesture(centre - const Offset(40, 0));
      final right = await tester.startGesture(centre + const Offset(40, 0));
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await left.moveBy(const Offset(-12, 0));
        await right.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();

      expect(_zoom(tester), greaterThan(zoom * 1.5));
      final card = itemIn(editor.saved, 'card');
      expect([card.x, card.y], [10, 30]);
      expect(editor.saved.revision, revision, reason: 'nothing was edited');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'arrow keys nudge 1 mm, Shift makes it 10 mm, Ctrl+Z undoes the last nudge',
    (tester) async {
      final editor = await EditorHarness.pump(tester, project: _twoCards());
      await tapKey(tester, const Key('page-item-card'));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(itemIn(editor.saved, 'card').x, closeTo(11, 1e-9));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(itemIn(editor.saved, 'card').y, closeTo(40, 1e-9));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final card = itemIn(editor.saved, 'card');
      expect(card.y, closeTo(30, 1e-9));
      expect(card.x, closeTo(11, 1e-9));
      expect(tester.takeException(), isNull);
    },
  );
}

/// A unified card and a residence card side by side near the top of page 1
/// of a two-page project, so the pages can always scroll.
Project _twoCards({
  bool cardLocked = false,
  double cardRotation = 0,
  double cardY = 30,
}) => editorProject(
  pageCount: 2,
  items: [
    placedDocument(
      'card',
      'asset1',
      DocumentKind.unifiedNationalId,
      x: 10,
      y: cardY,
    ).copyWith(locked: cardLocked, rotation: cardRotation),
    placedDocument('residence', 'asset2', DocumentKind.residenceCard, x: 112, y: 30),
  ],
);

double _scrollOffset(WidgetTester tester) => tester
    .widget<ListView>(find.byKey(const Key('sheet-pages')))
    .controller!
    .offset;

double _zoom(WidgetTester tester) =>
    tester.widget<Slider>(find.byKey(const Key('status-zoom'))).value;

Offset _centre(WidgetTester tester, String id) =>
    tester.getCenter(find.byKey(Key('page-item-$id')));

/// A point on page 1, left of every document, halfway down the view.
Offset _emptyPaper(WidgetTester tester) {
  final page = tester.getRect(find.byKey(const Key('sheet-page-0')));
  final view = tester.getRect(find.byKey(const Key('sheet-pages')));
  return Offset(page.left + 20, view.center.dy);
}

/// [total] split into five equal moves.
List<Offset> _steps(Offset total) => List.filled(5, total / 5);

Future<void> _swipe(
  WidgetTester tester,
  Offset from,
  List<Offset> moves,
  PointerDeviceKind kind,
) async {
  final gesture = await tester.startGesture(from, kind: kind);
  await tester.pump();
  for (final move in moves) {
    await gesture.moveBy(move);
    await tester.pump();
  }
  await gesture.up();
  if (kind == PointerDeviceKind.mouse) await gesture.removePointer();
  await tester.pumpAndSettle();
}

/// A two-finger touchpad swipe: a pan/zoom gesture, not a pointer press.
Future<void> _touchpadSwipe(
  WidgetTester tester,
  Offset at,
  Offset total,
) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
  await gesture.panZoomStart(at);
  await tester.pump();
  for (var i = 1; i <= 5; i++) {
    await gesture.panZoomUpdate(at, pan: total * (i / 5));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _ctrlClick(WidgetTester tester, String id) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.tap(
    find.byKey(Key('page-item-$id')),
    kind: PointerDeviceKind.mouse,
  );
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}
