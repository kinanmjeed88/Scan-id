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
  final label = tester
      .widget<Text>(find.descendant(of: toggle, matching: find.byType(Text)))
      .data;
  expect(
    surface,
    findsOneWidget,
    reason:
        'the tap-mode toggle must open four-tap mode; it was at $rectBefore, '
        'label after the tap: "$label"',
  );
}
