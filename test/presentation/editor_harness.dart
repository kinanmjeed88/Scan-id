import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/layout_screen.dart';
import 'package:scan_id/presentation/page_canvas.dart';

import '../fixtures.dart';

// Shared harness for the A4 editor widget tests: the real LayoutScreen over an
// in-memory project store, with helpers to read back what was saved.

class EditorHarness {
  EditorHarness(this.repository, this.id);

  final MemoryProjects repository;
  final String id;

  Project get saved => repository.values[id]!;

  static Future<EditorHarness> pump(
    WidgetTester tester, {
    Project? project,
    ImageEditor? imageEditor,
    Future<List<ImportSource>> Function()? pickImages,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = MemoryProjects();
    final created = await repository.create(project ?? editorProject());
    final service = ProjectService(
      repository,
      NoAssets(),
      imageEditor: imageEditor,
    );
    await tester.pumpWidget(
      AppShell(
        home: LayoutScreen(
          project: created,
          service: service,
          pickImages: pickImages ?? () async => <ImportSource>[],
          adjustmentCommitDelay: const Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return EditorHarness(repository, created.id);
  }
}

/// [documents] defaults to none, so a harness project stays a plain layout
/// fixture unless a test needs recognition records.
Project editorProject({
  List<DocumentItem>? items,
  int pageCount = 1,
  List<DocumentRecord>? documents,
}) => Project(
  id: 'project1',
  name: 'مستمسكات العائلة',
  createdAt: DateTime.utc(2026, 10, 7),
  updatedAt: DateTime.utc(2026, 10, 7),
  pageCount: pageCount,
  paper: PaperSettings(margins: Margins.all(5)),
  assets: [
    for (final id in ['asset1', 'asset2', 'asset3', 'asset4'])
      assetFixture(id: id),
  ],
  documents: documents ?? const [],
  items:
      items ??
      [
        placedDocument(
          'card',
          'asset1',
          DocumentKind.unifiedNationalId,
          x: 62.2,
        ),
        placedDocument(
          'passport',
          'asset2',
          DocumentKind.passport,
          x: 42.5,
          y: 64,
        ),
        DocumentItem(
          id: 'unknown',
          assetId: 'asset3',
          x: 0,
          y: 0,
          width: 60,
          height: 40,
          pageIndex: null,
        ),
      ],
);

DocumentItem placedDocument(
  String id,
  String assetId,
  DocumentKind kind, {
  double x = 5,
  double y = 5,
  double? w,
  double? h,
  bool portrait = false,
}) {
  final size = const DocumentSizeCatalog().sizeFor(kind, landscape: !portrait);
  return DocumentItem(
    id: id,
    assetId: assetId,
    x: x,
    y: y,
    width: w ?? size!.width,
    height: h ?? size!.height,
    documentKind: kind,
    sizeConfirmed: true,
  );
}

DocumentItem itemIn(Project project, String id) =>
    project.items.firstWhere((e) => e.id == id);

ImageAsset assetIn(Project project, String id) =>
    project.assets.firstWhere((a) => a.id == id);

PageCanvas firstCanvas(WidgetTester tester) =>
    tester.widget<PageCanvas>(find.byType(PageCanvas).first);

double pageScale(WidgetTester tester) => firstCanvas(tester).scale;

Future<void> tapKey(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget, reason: '$key');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class MemoryProjects implements ProjectRepository {
  final values = <String, Project>{};
  @override
  Future<List<Project>> list() async => values.values.toList();
  @override
  Future<Project> get(String id) async => values[id]!;
  @override
  Future<Project> create(Project project) async {
    values[project.id] = project;
    return project;
  }

  @override
  Future<Project> save(Project project) async {
    if (values[project.id]?.revision != project.revision) {
      throw const RevisionConflict();
    }
    final saved = project.copyWith(revision: project.revision + 1);
    values[project.id] = saved;
    return saved;
  }

  @override
  Future<void> remove(Project project) async {
    values.remove(project.id);
  }

  @override
  Future<void> close() async {}
}

class NoAssets implements AssetRepository {
  @override
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  ) => Future.error(StateError('No import expected in this test'));
  @override
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
    Uint8List bytes,
  ) => Future.error(StateError('No replacement expected in this test'));
  @override
  Future<File> resolve(String relativePath) =>
      Future.error(StateError('Pictures are not loaded in this test'));
}

/// Records revisions; previews are a fixed small picture.
class FakeImageEditor implements ImageEditor {
  final bytes = img.encodePng(img.Image(width: 64, height: 40));
  int revisions = 0;

  @override
  Future<EditorSource> open(ImageAsset asset) async =>
      EditorSource(bytes, 64, 40);

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => [
    Point2(.1, .1),
    Point2(.9, .1),
    Point2(.9, .9),
    Point2(.1, .9),
  ];

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) async =>
      bytes;

  @override
  Future<ImageAsset> createRevision(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async {
    revisions++;
    final prefix = 'projects/project1/assets/${asset.id}';
    final turned = recipe.adjustments.quarterTurns.isOdd;
    final w = recipe.geometry.outputWidth, h = recipe.geometry.outputHeight;
    return ImageAsset(
      id: asset.id,
      name: asset.name,
      originalPath: asset.originalPath,
      workingPath: '$prefix/edited-$revisions.png',
      thumbnailPath: '$prefix/edited-$revisions-thumb.jpg',
      width: turned ? h : w,
      height: turned ? w : h,
      crop: recipe.geometry,
      adjustments: recipe.adjustments,
    );
  }
}
