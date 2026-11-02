import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

// P6 + T04 + T06 (widget level). Synthetic 64x40 preview from FakeImageEditor.
// Corner centres are read from the rendered widgets, never from private state.

const _crossingMessage = 'زوايا القص تتقاطع؛ أبقيت آخر موضع صالح للزاوية.';

Future<void> _pumpCrop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1100, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repository = MemoryProjects();
  final asset = assetFixture(id: 'asset-corner-hit');
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

Rect _canvas(WidgetTester tester) =>
    tester.getRect(find.byKey(const Key('crop-source-image')));

Offset _handleCentre(WidgetTester tester, int i) =>
    tester.getCenter(find.byKey(Key('crop-corner-$i')));

/// Normalized canvas position of corner [i], read from the rendered handle.
Offset _normalized(WidgetTester tester, int i) {
  final r = _canvas(tester);
  final c = _handleCentre(tester, i);
  return Offset((c.dx - r.left) / r.width, (c.dy - r.top) / r.height);
}

List<Point2> _quadFromHandles(WidgetTester tester) {
  final quad = <Point2>[];
  for (var i = 0; i < 4; i++) {
    final n = _normalized(tester, i);
    quad.add(Point2(n.dx, n.dy));
  }
  return quad;
}

TransformationController _viewer(WidgetTester tester) {
  final viewer = tester.widget<InteractiveViewer>(
    find.byWidgetPredicate(
      (w) => w is InteractiveViewer && w.transformationController != null,
    ),
  );
  return viewer.transformationController!;
}

/// Sets zoom [zoom] and places the canvas top-left at [topLeftInViewer]
/// (viewer-local). Default: keep the identity placement (zoom about it).
Future<void> _setZoom(
  WidgetTester tester,
  double zoom, {
  Offset? topLeftInViewer,
}) async {
  final controller = _viewer(tester);
  controller.value = Matrix4.identity();
  await tester.pump();
  final viewerTopLeft = tester.getTopLeft(find.byType(InteractiveViewer).first);
  // At identity, screen = viewer origin + child-local, so this is child-local.
  final c0 = _canvas(tester).topLeft - viewerTopLeft;
  final target = topLeftInViewer ?? c0;
  // M = T(t) * S(zoom): M * c0 = zoom * c0 + t must equal the target.
  final t = target - c0 * zoom;
  controller.value = Matrix4.identity()..translate(t.dx, t.dy)..scale(zoom);
  await tester.pump();
}

const _fullFrame = [
  Offset(0, 0),
  Offset(1, 0),
  Offset(1, 1),
  Offset(0, 1),
];

void main() {
  for (final zoom in [1.0, 3.0, 5.0]) {
    testWidgets('T04 zoom $zoom: handle 40 px on corner', (tester) async {
      await _pumpCrop(tester);
      await _setZoom(tester, zoom);

      final r = _canvas(tester);
      for (var i = 0; i < 4; i++) {
        final handle = tester.getRect(find.byKey(Key('crop-corner-$i')));
        expect(handle.width, closeTo(40, 1.0), reason: 'corner $i width');
        expect(handle.height, closeTo(40, 1.0), reason: 'corner $i height');

        final expected = Offset(
          r.left + _fullFrame[i].dx * r.width,
          r.top + _fullFrame[i].dy * r.height,
        );
        expect(
          (handle.center - expected).distance,
          lessThan(1.5),
          reason: 'corner $i centre on its corner',
        );
        // Normalized corners are unchanged by zoom: zoom is a view property.
        final n = _normalized(tester, i);
        expect(n.dx, closeTo(_fullFrame[i].dx, 0.005), reason: 'x$i');
        expect(n.dy, closeTo(_fullFrame[i].dy, 0.005), reason: 'y$i');
      }
    });
  }

  testWidgets('T04 pan: the dragged corner follows the pointer', (tester) async {
    await _pumpCrop(tester);
    await _setZoom(tester, 3, topLeftInViewer: const Offset(120, 80));

    final before = _viewer(tester).value.getTranslation();
    final r = _canvas(tester);
    final handle = tester.getRect(find.byKey(const Key('crop-corner-0')));
    expect(handle.width, closeTo(40, 1.0));

    await tester.dragFrom(_handleCentre(tester, 0), const Offset(30, 20));
    await tester.pump();

    final moved = _normalized(tester, 0);
    expect(moved.dx, closeTo(30 / r.width, 0.01));
    expect(moved.dy, closeTo(20 / r.height, 0.01));
    // Other corners do not move, and the view does not pan.
    expect(_normalized(tester, 1).dx, closeTo(1, 0.005));
    expect(_normalized(tester, 2).dy, closeTo(1, 0.005));
    expect(_viewer(tester).value.getTranslation(), before);
  });

  testWidgets('T04 far pan: pans, moves no corner', (tester) async {
    await _pumpCrop(tester);
    final r0 = _canvas(tester);
    final viewport = tester.getRect(find.byType(InteractiveViewer).first);
    // Centre the zoomed canvas so its centre is the viewport centre.
    await _setZoom(
      tester,
      3,
      topLeftInViewer: Offset(
        viewport.width / 2 - 1.5 * r0.width,
        viewport.height / 2 - 1.5 * r0.height,
      ),
    );

    final before = _viewer(tester).value.getTranslation();
    await tester.dragFrom(viewport.center, const Offset(-60, 0));
    await tester.pump();

    expect(_viewer(tester).value.getTranslation().x, lessThan(before.x));
    for (var i = 0; i < 4; i++) {
      expect(_normalized(tester, i).dx, closeTo(_fullFrame[i].dx, 0.01));
      expect(_normalized(tester, i).dy, closeTo(_fullFrame[i].dy, 0.01));
    }
  });

  testWidgets('T06 widget: a crossing drag is refused', (tester) async {
    await _pumpCrop(tester);
    final r = _canvas(tester);

    // Step 1 (valid): corner 0 to (0, 0.2).
    await tester.dragFrom(
      _handleCentre(tester, 0),
      Offset(0, 0.2 * r.height),
    );
    await tester.pump();
    expect(_normalized(tester, 0).dy, closeTo(0.2, 0.01));
    expect(find.text(_crossingMessage), findsNothing);

    // Step 2 (crossing): corner 2 to (0.5, 0) would make edges 0-1 and 2-3
    // cross. The corner must stay at its last valid position (1, 1).
    await tester.dragFrom(
      _handleCentre(tester, 2),
      Offset(-0.5 * r.width, -1.0 * r.height),
    );
    await tester.pump();
    expect(_normalized(tester, 2).dx, closeTo(1, 0.01));
    expect(_normalized(tester, 2).dy, closeTo(1, 0.01));
    expect(find.text(_crossingMessage), findsOneWidget);
    expect(quadEdgesCross(_quadFromHandles(tester)), isFalse);

    // Step 3 (valid again): the same corner moves; the notice clears.
    await tester.dragFrom(
      _handleCentre(tester, 2),
      Offset(-0.1 * r.width, -0.1 * r.height),
    );
    await tester.pump();
    expect(_normalized(tester, 2).dx, closeTo(0.9, 0.01));
    expect(_normalized(tester, 2).dy, closeTo(0.9, 0.01));
    expect(find.text(_crossingMessage), findsNothing);
  });
}
