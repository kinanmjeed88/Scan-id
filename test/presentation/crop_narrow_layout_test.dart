import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

// F-N, narrow layout. The canvas is fixed and only the tools scroll. A lazy
// list culled the canvas once the tap-mode toggle was reached, which lost the
// canvas, the corner handles, and the manual selection. These tests scroll the
// tools and check that the canvas and the four taps survive.

Future<void> _pumpNarrow(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = MemoryProjects();
  final asset = assetFixture(id: 'asset-narrow');
  final project = await repository.create(projectFixture(assets: [asset]));
  final service = ProjectService(
    repository,
    NoAssets(),
    imageEditor: FakeImageEditor(),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: CropScreen(project: project, asset: asset, service: service),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<Offset> _corners(WidgetTester tester) => [
  for (var i = 0; i < 4; i++)
    tester.getCenter(find.byKey(Key('crop-corner-$i'))),
];

/// Drags the tools panel that holds [control] by [delta], starting near its
/// top-left corner where no slider or field sits.
Future<void> _scrollTools(
  WidgetTester tester,
  Finder control,
  Offset delta,
) async {
  final tools = find.ancestor(
    of: control,
    matching: find.byType(SingleChildScrollView),
  );
  final start = tester.getTopLeft(tools.first) + const Offset(6, 6);
  await tester.dragFrom(start, delta);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the canvas and four taps survive tool scrolling', (
    tester,
  ) async {
    await _pumpNarrow(tester);
    final toggle = find.byKey(const Key('crop-tap-mode'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // Reaching the toggle must not cull the canvas (the regression).
    expect(find.byKey(const Key('crop-source-image')), findsOneWidget);
    expect(find.byKey(const Key('crop-tap-surface')), findsOneWidget);

    final rect = tester.getRect(find.byKey(const Key('crop-tap-surface')));
    for (final (fx, fy) in const [
      (0.35, 0.35),
      (0.65, 0.35),
      (0.65, 0.65),
      (0.35, 0.65),
    ]) {
      await tester.tapAt(
        Offset(rect.left + rect.width * fx, rect.top + rect.height * fy),
      );
      await tester.pumpAndSettle();
    }
    final before = _corners(tester);

    // Scroll the tools to the bottom and back up.
    await _scrollTools(tester, toggle, const Offset(0, -600));
    expect(find.byKey(const Key('crop-source-image')), findsOneWidget);
    // Four taps finish tap mode (as in the C3 lifecycle test), so the surface
    // is closed. The canvas and corner handles that hold the selection stay.
    expect(find.byKey(const Key('crop-tap-surface')), findsNothing);
    expect(find.byKey(const Key('crop-corner-0')), findsOneWidget);
    await _scrollTools(tester, toggle, const Offset(0, 600));
    expect(find.byKey(const Key('crop-source-image')), findsOneWidget);

    final after = _corners(tester);
    for (var i = 0; i < 4; i++) {
      expect(
        (after[i] - before[i]).distance,
        lessThan(0.5),
        reason: 'corner $i must keep its tapped position',
      );
    }
  });
}
