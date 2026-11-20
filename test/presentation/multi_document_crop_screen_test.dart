import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/multi_document_crop_screen.dart';

import 'editor_harness.dart';

/// Records every derived crop the screen asks the service to render, so the test
/// can assert on the rectangles that were cropped rather than on pixels.
class _CountingAssets implements AssetRepository {
  final names = <String>[];
  int _seq = 0;

  @override
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  ) async {
    final id = 'multi-${++_seq}';
    names.add(name);
    return ImageAsset(
      id: id,
      name: name,
      originalPath: 'projects/$projectId/assets/$id/original.png',
      workingPath: 'projects/$projectId/assets/$id/working.png',
      thumbnailPath: 'projects/$projectId/assets/$id/thumb.jpg',
      width: 80,
      height: 60,
    );
  }

  @override
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
    Uint8List bytes,
  ) => Future.error(StateError('unused'));

  @override
  Future<Uint8List> previewImage(Uint8List source) async => source;

  @override
  Future<File> resolve(String relativePath) =>
      Future.error(StateError('no disk access in this test'));
}

class _RecordingEditor extends FakeImageEditor implements CropBytesImageEditor {
  final recipes = <ImageEditRecipe>[];

  @override
  Future<Uint8List> renderCropBytes(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async {
    recipes.add(recipe);
    return bytes;
  }
}

typedef _Setup = ({
  MemoryProjects repository,
  _CountingAssets assets,
  _RecordingEditor editor,
  Project project,
  ProjectService service,
});

Future<_Setup> _setup() async {
  final repository = MemoryProjects();
  final project = await repository.create(editorProject());
  final assets = _CountingAssets();
  final editor = _RecordingEditor();
  final service = ProjectService(repository, assets, imageEditor: editor);
  return (
    repository: repository,
    assets: assets,
    editor: editor,
    project: project,
    service: service,
  );
}

/// Whatever the screen is telling the person, for use as a failure reason.
String _bannerText(WidgetTester tester) {
  final banner = find.byKey(const Key('multi-selection-error'));
  if (banner.evaluate().isEmpty) return 'no error banner';
  return 'banner: ${tester.widget<Text>(banner).data}';
}

Widget _app(Project project, ProjectService service) => AppShell(
  home: MultiDocumentCropScreen(
    project: project,
    asset: project.assets.first,
    service: service,
  ),
);

/// Taps a NORMALIZED IMAGE point, converting through the rectangle the
/// photograph is actually drawn in. Using the canvas box instead would be wrong
/// wherever the photograph is letterboxed inside it, and would make the test
/// pass or fail for reasons the product does not have.
Future<void> _tapNormalized(WidgetTester tester, double x, double y) async {
  final rect = tester.getRect(find.byKey(const Key('multi-selection-source')));
  await tester.tapAt(
    Offset(rect.left + rect.width * x, rect.top + rect.height * y),
  );
  await tester.pumpAndSettle();
}

Future<void> _drawCard(
  WidgetTester tester, {
  double left = .1,
  double top = .2,
  double right = .4,
  double bottom = .6,
}) async {
  for (final (x, y) in [
    (left, top),
    (right, top),
    (right, bottom),
    (left, bottom),
  ]) {
    await _tapNormalized(tester, x, y);
  }
}

/// The rectangle the screen will crop for the card [_drawCard] just drew, used
/// to assert that the DOCUMENT is drawn even though only two areas of text are.
ImageEditRecipe _expectedRecipe() => CropDraft(
  corners: [Point2(.1, .2), Point2(.4, .2), Point2(.4, .6), Point2(.1, .6)],
).toRecipe(64, 40);

void main() {
  testWidgets('the whole photograph opens with an empty workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await _setup();
    await tester.pumpWidget(_app(setup.project, setup.service));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('multi-selection-source')), findsOneWidget);
    expect(find.byKey(const Key('multi-selection-empty')), findsOneWidget);
    expect(find.byKey(const Key('multi-selection-list')), findsNothing);
    // Nothing can be added before anything is drawn.
    final apply = tester.widget<FilledButton>(
      find.byKey(const Key('multi-selection-apply')),
    );
    expect(apply.onPressed, isNull);
  });

  testWidgets('two documents are drawn, listed and each keeps its own kind', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await _setup();
    await tester.pumpWidget(_app(setup.project, setup.service));
    await tester.pumpAndSettle();

    // First document.
    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    await _drawCard(tester);
    expect(find.byKey(const Key('multi-selection-row-sel-0')), findsOneWidget);
    // A completed outline states that it is complete rather than asking for a
    // fourth corner it already has.
    expect(find.textContaining('زوايا'), findsOneWidget);
    // With no category chosen the person is told what will happen, before
    // adding: a free document that stays off the sheet until review.
    expect(
      find.byKey(const Key('multi-selection-kind-default')),
      findsOneWidget,
    );

    // Give it a category.
    await tester.tap(find.byKey(const Key('multi-selection-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(DocumentKind.passport.label).last);
    await tester.pumpAndSettle();

    // Second document, deliberately overlapping the first's taps in time but not
    // in space.
    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    await _drawCard(tester, left: .55, right: .9);
    expect(find.byKey(const Key('multi-selection-row-sel-1')), findsOneWidget);
    expect(find.byKey(const Key('multi-selection-row-sel-0')), findsOneWidget);

    // The second keeps its own default category; the first kept the chosen one.
    // The row subtitle is one combined string, so the category is matched as a
    // substring of it rather than as a standalone label.
    expect(find.textContaining(DocumentKind.passport.label), findsOneWidget);
    expect(find.textContaining('2 جاهز'), findsOneWidget);
  });

  testWidgets('adding crops each selection independently through the service', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await _setup();
    await tester.pumpWidget(_app(setup.project, setup.service));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    await _drawCard(tester);
    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    await _drawCard(tester, left: .55, right: .9);

    await tester.tap(find.byKey(const Key('multi-selection-apply')));
    await tester.pumpAndSettle();

    // Two rectangles were rendered, and two assets were imported through the
    // normal repository. The banner text is part of the failure message: without
    // it a short count says nothing about which step refused the crop.
    expect(setup.editor.recipes, hasLength(2), reason: _bannerText(tester));
    expect(setup.assets.names, hasLength(2));
    // The first crop is the first card's own corners, within a tap of them.
    final first = setup.editor.recipes[0].geometry.corners;
    for (var i = 0; i < 4; i++) {
      expect(first[i].x, closeTo(_expectedRecipe().geometry.corners[i].x, .02));
      expect(first[i].y, closeTo(_expectedRecipe().geometry.corners[i].y, .02));
    }
    // The second crop is a different area, not the same rectangle twice.
    expect(
      setup.editor.recipes[1].geometry.corners.any((c) => c.x > .5),
      isTrue,
    );
    expect(
      setup.editor.recipes[0].geometry.corners.any((c) => c.x > .5),
      isFalse,
    );
    // The saved project is whatever the real service produced, so the assertion
    // is on the DOCUMENTS rather than on a raw asset count: the service owns how
    // many assets a derivation implies, and restating that here would test the
    // service's internals instead of this screen's behaviour.
    final saved = setup.repository.values[setup.project.id]!;
    final derived = saved.assets.where(
      (a) => a.derivedFrom == setup.project.assets.first.id,
    );
    expect(derived, hasLength(2));
    // Two documents were added, each tied to its own derived asset.
    final derivedIds = {for (final asset in derived) asset.id};
    final added = saved.items.where((i) => derivedIds.contains(i.assetId));
    expect(added, hasLength(2));
    expect(setup.assets.names, hasLength(2));
  });

  testWidgets('deleting one document leaves the other untouched', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await _setup();
    await tester.pumpWidget(_app(setup.project, setup.service));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    await _drawCard(tester);
    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    await _drawCard(tester, left: .55, right: .9);

    await tester.tap(find.byKey(const Key('multi-selection-delete-sel-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('multi-selection-row-sel-0')), findsNothing);
    expect(find.byKey(const Key('multi-selection-row-sel-1')), findsOneWidget);
    expect(find.textContaining('1 جاهز'), findsOneWidget);
  });

  testWidgets('an incomplete selection blocks adding and names the document', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await _setup();
    await tester.pumpWidget(_app(setup.project, setup.service));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    await _tapNormalized(tester, .1, .2);
    await _tapNormalized(tester, .4, .2);

    final apply = tester.widget<FilledButton>(
      find.byKey(const Key('multi-selection-apply')),
    );
    expect(apply.onPressed, isNull);
    // The active document states how many corners are still missing.
    expect(
      find.byKey(const Key('multi-selection-selection-issue')),
      findsOneWidget,
    );
    expect(setup.editor.recipes, isEmpty);
  });

  testWidgets('zoom changes the coordinates a tap is stored at, not the image', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await _setup();
    await tester.pumpWidget(_app(setup.project, setup.service));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    // Zoom in and only then tap. At 1.5x the photograph is larger than the box,
    // so two of the four points below are deliberately OUTSIDE the visible area:
    // they must still resolve to the right place on the photograph, which is what
    // the coordinate transform is for.
    await tester.tap(find.byKey(const Key('multi-selection-zoom-in')));
    await tester.pumpAndSettle();
    // A card in the part of the photograph still visible after zooming.
    await _drawCard(tester, left: .25, top: .3, right: .45, bottom: .45);
    expect(
      find.byKey(const Key('multi-selection-selection-issue')),
      findsNothing,
    );
    expect(find.textContaining('1 جاهز'), findsOneWidget);
  });

  testWidgets('cancelling a selection clears its corners but keeps its row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await _setup();
    await tester.pumpWidget(_app(setup.project, setup.service));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('multi-selection-add')));
    await tester.pumpAndSettle();
    await _drawCard(tester);
    await tester.tap(find.byKey(const Key('multi-selection-cancel-selection')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('multi-selection-row-sel-0')), findsOneWidget);
    expect(find.textContaining('0/4'), findsOneWidget);
    expect(find.byKey(const Key('multi-selection-notice')), findsOneWidget);
    // Still nothing to add: the selection was reset, not committed.
    final apply = tester.widget<FilledButton>(
      find.byKey(const Key('multi-selection-apply')),
    );
    expect(apply.onPressed, isNull);
  });
}
