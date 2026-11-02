import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens four-tap mode on the crop screen when it is not already open.
///
/// The fallback gate does not switch tap mode on by itself: a frame with no
/// candidate opens with draggable corners, and the tap-mode toggle is how a
/// user (and therefore a test) enters four taps.
Future<void> ensureCropTapMode(WidgetTester tester) async {
  if (find.byKey(const Key('crop-tap-surface')).evaluate().isNotEmpty) return;
  final toggle = find.byKey(const Key('crop-tap-mode'));
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}
