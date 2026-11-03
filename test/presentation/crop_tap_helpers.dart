import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens four-tap mode on the crop screen when it is not already open.
///
/// The fallback gate does not switch tap mode on by itself: a frame with no
/// candidate opens with draggable corners, and the tap-mode toggle is how a
/// user (and therefore a test) enters four taps. The failure message names
/// the toggle's rectangle and label, so a tap that does not reach it, and a
/// toggle that flipped twice, are told apart in the CI log.
Future<void> ensureCropTapMode(WidgetTester tester) async {
  final surface = find.byKey(const Key('crop-tap-surface'));
  if (surface.evaluate().isNotEmpty) return;
  final toggle = find.byKey(const Key('crop-tap-mode'));
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  final rectBefore = tester.getRect(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  // In the narrow layout the canvas is the first child of a lazy list, and the
  // toggle sits below it. Reaching the toggle scrolls the canvas out of the
  // built range, so it must be scrolled back. A drag starting on the toggle
  // scrolls the list without pressing the toggle.
  await tester.drag(toggle, const Offset(0, 600));
  await tester.pumpAndSettle();
  final label = tester
      .widget<Text>(find.descendant(of: toggle, matching: find.byType(Text)))
      .data;
  int count(String key) => find.byKey(Key(key)).evaluate().length;
  expect(
    surface,
    findsOneWidget,
    reason:
        'the tap-mode toggle must open four-tap mode; it was at $rectBefore, '
        'label after the tap: "$label"; canvas ${count('crop-source-image')}, '
        'result ${count('crop-result')}, corner-0 ${count('crop-corner-0')}',
  );
}
