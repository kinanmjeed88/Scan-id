import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/presentation/boundary_hit_layer.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

// P6 + T04 + T06 (widget level). Synthetic 64x40 preview from FakeImageEditor.
// Corner centres are read from the rendered widgets, never from private state.

const _crossingMessage = 'زوايا القص تتقاطع؛ أبقيت آخر موضع صالح للزاوية.';

// Pixel tolerance for geometry checks. Layout and transforms are float64 at
// devicePixelRatio 1, so a correct handle lands within float error of its
// corner. 0.5 px is far below one pixel. It is NOT the 24 px capture radius:
// that radius decides which handle a touch selects, not where a handle sits.
const _pxTol = 0.5;

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

Rect _canvas(WidgetTester tester) {
  return tester.getRect(find.byKey(const Key('crop-source-image')));
}

Offset _handleCentre(WidgetTester tester, int i) {
  return tester.getCenter(find.byKey(Key('crop-corner-$i')));
}

/// Moves the pointer in steps, as a finger does. A single jump was observed
/// not to move the corner through the hit layer (CI run 41448139242), so the
/// tests never use one.
Future<void> dragInSteps(
  WidgetTester tester,
  Offset start,
  Offset delta,
) async {
  final gesture = await tester.startGesture(start);
  for (var step = 0; step < 10; step++) {
    await gesture.moveBy(delta / 10);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump();
}

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

bool _isController(Widget w) {
  return w is InteractiveViewer && w.transformationController != null;
}

TransformationController _viewer(WidgetTester tester) {
  final finder = find.byWidgetPredicate(_isController);
  final viewer = tester.widget<InteractiveViewer>(finder);
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
  final m = Matrix4.identity()..translateByDouble(t.dx, t.dy, 0, 1);
  m.scaleByDouble(zoom, zoom, zoom, 1);
  controller.value = m;
  await tester.pump();
}

const _fullFrame = [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)];

void main() {
  for (final zoom in [1.0, 3.0, 5.0]) {
    testWidgets('T04 zoom $zoom: handle 40 px on corner', (tester) async {
      await _pumpCrop(tester);
      await _setZoom(tester, zoom);

      final r = _canvas(tester);
      for (var i = 0; i < 4; i++) {
        final handle = tester.getRect(find.byKey(Key('crop-corner-$i')));
        expect(handle.width, closeTo(40, _pxTol), reason: 'corner $i width');
        expect(handle.height, closeTo(40, _pxTol), reason: 'corner $i height');

        final expected = Offset(
          r.left + _fullFrame[i].dx * r.width,
          r.top + _fullFrame[i].dy * r.height,
        );
        expect(
          (handle.center - expected).distance,
          lessThan(_pxTol),
          reason: 'corner $i centre on its corner',
        );
        // Normalized corners are unchanged by zoom: zoom is a view property.
        final n = _normalized(tester, i);
        expect(
          n.dx,
          closeTo(_fullFrame[i].dx, _pxTol / r.width),
          reason: 'x$i',
        );
        expect(
          n.dy,
          closeTo(_fullFrame[i].dy, _pxTol / r.height),
          reason: 'y$i',
        );
      }
    });
  }

  for (var corner = 0; corner < 4; corner++) {
    testWidgets('corner $corner captures a press arriving from outside', (
      tester,
    ) async {
      await _pumpCrop(tester);
      final outward = switch (corner) {
        0 => const Offset(-18, -18),
        1 => const Offset(18, -18),
        2 => const Offset(18, 18),
        _ => const Offset(-18, 18),
      };
      final before = _normalized(tester, corner);
      final start = _handleCentre(tester, corner) + outward;
      final hitPath = tester.hitTestOnBinding(start).path;
      expect(
        hitPath.any((entry) => entry.target is RenderBoundaryHitLayer),
        isTrue,
        reason: 'outside press $start must reach the boundary; path: $hitPath',
      );

      // Continue past the original corner into the image. Ending at -outward
      // would correctly restore the original point and prove no movement.
      await dragInSteps(tester, start, -outward * 2);

      final after = _normalized(tester, corner);
      expect((after - before).distance, greaterThan(.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('T04 pan: the dragged corner follows', (tester) async {
    await _pumpCrop(tester);
    await _setZoom(tester, 3, topLeftInViewer: const Offset(120, 80));

    final before = _viewer(tester).value.getTranslation();
    final r = _canvas(tester);
    final start = _handleCentre(tester, 0);
    final handle = tester.getRect(find.byKey(const Key('crop-corner-0')));
    expect(handle.width, closeTo(40, _pxTol));

    const delta = Offset(30, 20);
    await dragInSteps(tester, start, delta);

    // The corner is placed at the pointer. The press starts on the handle
    // centre, which sits on the corner to within _pxTol, so the final error is
    // that same offset. A corner that did not move is ~36 px away.
    // The pointer maps onto the canvas as it was during the gesture, which is
    // the canvas measured before the press: the status line leaves at the drag
    // end, and the release shift moves corner and canvas together.
    final moved = _normalized(tester, 0);
    final target = Offset(
      (start.dx + delta.dx - r.left) / r.width,
      (start.dy + delta.dy - r.top) / r.height,
    );
    final errorPx = Offset(
      (moved.dx - target.dx) * r.width,
      (moved.dy - target.dy) * r.height,
    ).distance;
    expect(errorPx, lessThan(_pxTol), reason: 'corner must follow the pointer');
    // Other corners do not move, and the view does not pan.
    expect(_normalized(tester, 1).dx, closeTo(1, _pxTol / r.width));
    expect(_normalized(tester, 2).dy, closeTo(1, _pxTol / r.height));
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

  testWidgets('T04 panned handles stay on corners', (tester) async {
    await _pumpCrop(tester);
    final viewport = tester.getRect(find.byType(InteractiveViewer).first);
    final r0 = _canvas(tester);
    await _setZoom(
      tester,
      3,
      topLeftInViewer: Offset(
        viewport.width / 2 - 1.5 * r0.width,
        viewport.height / 2 - 1.5 * r0.height,
      ),
    );
    // Pan from an empty area (no handle within 24 px of the press).
    await tester.dragFrom(viewport.center, const Offset(-60, 0));
    await tester.pump();

    // After the pan, each handle centre still equals its canvas corner.
    final r = _canvas(tester);
    for (var i = 0; i < 4; i++) {
      final centre = _handleCentre(tester, i);
      final expected = Offset(
        r.left + _fullFrame[i].dx * r.width,
        r.top + _fullFrame[i].dy * r.height,
      );
      expect(
        (centre - expected).distance,
        lessThan(_pxTol),
        reason: 'corner $i',
      );
    }
  });

  testWidgets('T04 hit picks the nearest handle', (tester) async {
    await _pumpCrop(tester);
    final viewport = tester.getRect(find.byType(InteractiveViewer).first);
    final r0 = _canvas(tester);
    // Bottom-left corner (index 3) at the viewport centre, so it is on screen.
    await _setZoom(
      tester,
      5,
      topLeftInViewer: Offset(
        viewport.width / 2,
        viewport.height / 2 - 5 * r0.height,
      ),
    );

    // 8 px right and 8 px up of the handle centre: about 11 px away, inside the
    // 24 px radius of corner 3 only. Other corners are hundreds of px away.
    final start = _handleCentre(tester, 3) + const Offset(8, -8);
    final before = [for (var i = 0; i < 4; i++) _normalized(tester, i)];
    final layout = _canvas(tester);
    const delta = Offset(40, -30);
    await dragInSteps(tester, start, delta);

    // The pointer maps onto the canvas as it was during the gesture (measured
    // before the press). The status line leaves at the drag end, so the release
    // shift moves corner and canvas together and the normalized corner stays.
    final moved = _normalized(tester, 3);
    final target = Offset(
      (start.dx + delta.dx - layout.left) / layout.width,
      (start.dy + delta.dy - layout.top) / layout.height,
    );
    final errorPx = Offset(
      (moved.dx - target.dx) * layout.width,
      (moved.dy - target.dy) * layout.height,
    ).distance;
    expect(errorPx, lessThan(_pxTol), reason: 'corner 3 follows the pointer');
    for (var i = 0; i < 3; i++) {
      final now = _normalized(tester, i);
      expect(now.dx, closeTo(before[i].dx, 1e-9), reason: 'x$i unchanged');
      expect(now.dy, closeTo(before[i].dy, 1e-9), reason: 'y$i unchanged');
    }
  });

  testWidgets('the live loupe stays opposite the dragged top-right corner', (
    tester,
  ) async {
    await _pumpCrop(tester);
    final gesture = await tester.startGesture(_handleCentre(tester, 1));
    await gesture.moveBy(const Offset(-12, 12));
    await tester.pump();

    final alignment = tester.widget<Align>(
      find.byKey(const Key('crop-loupe-alignment')),
    );
    expect(alignment.alignment, Alignment.bottomLeft);
    final loupe = tester.getRect(find.byKey(const Key('crop-precision-loupe')));
    final finger = _handleCentre(tester, 1);
    expect(loupe.center.dy, greaterThan(finger.dy));
    expect(loupe.center.dx, lessThan(finger.dx));

    await gesture.up();
    await tester.pump();
    expect(find.byKey(const Key('crop-precision-loupe')), findsNothing);
  });

  testWidgets('T06 widget: a crossing drag is refused', (tester) async {
    await _pumpCrop(tester);
    final r = _canvas(tester);

    // Step 1 (valid): corner 0 moves down the left edge.
    await dragInSteps(
      tester,
      _handleCentre(tester, 0),
      Offset(0, 0.2 * r.height),
    );
    await tester.pump();
    expect(_normalized(tester, 0).dy, greaterThan(0.1));
    expect(find.text(_crossingMessage), findsNothing);
    expect(quadEdgesCross(_quadFromHandles(tester)), isFalse);

    // Step 2 (crossing): corner 2 is dragged towards (0.5, 0), which would make
    // edges 0-1 and 2-3 cross. The gate holds it at its last valid position.
    await dragInSteps(
      tester,
      _handleCentre(tester, 2),
      Offset(-0.5 * r.width, -1.0 * r.height),
    );
    await tester.pump();
    expect(quadEdgesCross(_quadFromHandles(tester)), isFalse);
    expect(find.text(_crossingMessage), findsOneWidget);
    expect(_normalized(tester, 2).dy, greaterThan(0.05));

    // Step 3 (valid again): the corner moves back; the notice clears.
    await dragInSteps(
      tester,
      _handleCentre(tester, 2),
      Offset(0.3 * r.width, 0.3 * r.height),
    );
    await tester.pump();
    expect(quadEdgesCross(_quadFromHandles(tester)), isFalse);
    expect(find.text(_crossingMessage), findsNothing);
    expect(_normalized(tester, 2).dx, greaterThan(0.7));
  });

  testWidgets('dragging a side midpoint moves both of its corners together', (
    tester,
  ) async {
    await _pumpCrop(tester);
    final r = _canvas(tester);
    final topMidpoint = Offset((r.left + r.right) / 2, r.top);
    await dragInSteps(tester, topMidpoint, Offset(0, 0.2 * r.height));
    await tester.pump();

    final y0 = _normalized(tester, 0).dy;
    expect(y0, greaterThan(0.15));
    expect(_normalized(tester, 1).dy, closeTo(y0, 1e-9));
    expect(_normalized(tester, 2).dy, closeTo(1.0, _pxTol / r.height));
    expect(_normalized(tester, 3).dy, closeTo(1.0, _pxTol / r.height));
    expect(tester.takeException(), isNull);
  });
}
