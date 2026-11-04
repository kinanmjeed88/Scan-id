import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/application/smart_recognition.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// The reported failure, reproduced as a regression: an import that reaches
/// «تحليل الصور» and never leaves `0 / 1` because a native stage never answers.
///
/// The batch must always finish. An image whose analysis expires is kept as a
/// manual document (the original is already saved), the remaining images are
/// still processed, and the progress counter reaches the total.
Uint8List _cardPhoto() {
  final image = img.Image(width: 320, height: 200);
  img.fill(image, color: img.ColorRgb8(210, 210, 205));
  img.fillRect(
    image,
    x1: 20,
    y1: 20,
    x2: 300,
    y2: 180,
    color: img.ColorRgb8(246, 246, 240),
  );
  return Uint8List.fromList(img.encodePng(image));
}

/// An editor whose `open` never completes for one asset id, like a native call
/// that fails without replying. Every other asset opens normally.
class _SelectiveEditor implements ImageEditor {
  _SelectiveEditor(this.inner, {this.stalledAssetId});

  final ImageEditor inner;
  final String? stalledAssetId;
  int stalls = 0;

  @override
  Future<EditorSource> open(
    ImageAsset asset, {
    CancellationToken? cancellation,
  }) {
    if (asset.id == stalledAssetId) {
      stalls++;
      return Completer<EditorSource>().future;
    }
    return inner.open(asset, cancellation: cancellation);
  }

  @override
  Future<List<Point2>?> suggest(Uint8List preview) => inner.suggest(preview);

  @override
  Future<Uint8List> preview(
    ImageAsset asset,
    ImageEditRecipe recipe, {
    CancellationToken? cancellation,
  }) => inner.preview(asset, recipe, cancellation: cancellation);

  @override
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe) =>
      inner.createRevision(asset, recipe);
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_id_stall');
    projects = await LocalProjectRepository.open(
      Directory('${root.path}/store'),
    );
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  Future<(ProjectService, Project, List<ImageAsset>)> seed(int images) async {
    final service = ProjectService(projects, assets);
    var project = await service.create('استيراد صورة واحدة');
    for (var index = 0; index < images; index++) {
      final bytes = _cardPhoto();
      project = (await service.importImages(project, [
        ImportSource('image_$index.png', () => Stream.value(bytes)),
      ])).project;
    }
    return (service, project, project.assets);
  }

  SmartIntake intakeWith(ImageEditor editor, {String? stalledAssetId}) =>
      SmartIntake(
        projects: projects,
        assets: assets,
        editor: _SelectiveEditor(editor, stalledAssetId: stalledAssetId),
        segment: (_) async =>
            const SegmentationResult(multi: false, candidates: []),
        analysisBudget: const Duration(milliseconds: 80),
      );

  test('one stalled image still completes the import', () async {
    final (_, project, assetsInProject) = await seed(1);
    final assetId = assetsInProject.single.id;
    final intake = intakeWith(
      LocalImageEditor(projects.files),
      stalledAssetId: assetId,
    );
    BatchProgress? last;

    final report = await intake.run(project, [
      assetId,
    ], onProgress: (progress) => last = progress);

    expect(last, isNotNull);
    expect(
      last!.completed,
      1,
      reason: 'the lane finished, so the dialog can close',
    );
    expect(last!.total, 1);
    expect(report.warnings, isNotEmpty);
    expect(
      report.warnings.join(' '),
      contains('تجاوزت المعالجة المهلة'),
      reason: 'the device timed out; the image is not blamed',
    );
    expect(report.project.items, hasLength(1));
    expect(
      report.project.items.single.documentKind,
      DocumentKind.unknown,
      reason: 'a timed-out analysis never guesses a kind',
    );
    expect(
      report.project.assets.single.crop,
      isNull,
      reason: 'the original is kept untouched for a manual crop',
    );
  });

  test('a stalled image does not stop the images after it', () async {
    final (_, project, assetsInProject) = await seed(2);
    final stalled = assetsInProject.first.id;
    final editor = _SelectiveEditor(
      LocalImageEditor(projects.files),
      stalledAssetId: stalled,
    );
    final intake = SmartIntake(
      projects: projects,
      assets: assets,
      editor: editor,
      segment: (_) async =>
          const SegmentationResult(multi: false, candidates: []),
      analysisBudget: const Duration(milliseconds: 80),
    );
    BatchProgress? last;

    final report = await intake.run(project, [
      stalled,
      assetsInProject.last.id,
    ], onProgress: (progress) => last = progress);

    expect(editor.stalls, 1);
    expect(last!.completed, 2, reason: 'both images reached a final outcome');
    expect(report.project.items, hasLength(2));
    expect(report.project.items.map((item) => item.assetId).toSet(), {
      stalled,
      assetsInProject.last.id,
    });
    expect(report.warnings, isNotEmpty);
  });

  test('cancelling a stalled import returns instead of hanging', () async {
    final (_, project, assetsInProject) = await seed(2);
    final token = CancellationToken();
    final editor = _SelectiveEditor(
      LocalImageEditor(projects.files),
      stalledAssetId: assetsInProject.first.id,
    );
    final intake = SmartIntake(
      projects: projects,
      assets: assets,
      editor: editor,
      segment: (_) async =>
          const SegmentationResult(multi: false, candidates: []),
      // The stalled native wait ends at the budget; the cancel request then
      // stops the batch at the next safe point instead of starting image two.
      analysisBudget: const Duration(milliseconds: 120),
    );

    final pending = intake.run(project, [
      assetsInProject.first.id,
      assetsInProject.last.id,
    ], cancellation: token);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel();

    final report = await pending.timeout(const Duration(seconds: 10));
    expect(report.warnings.join(' '), contains('أُلغيت'));
    expect(editor.stalls, 1, reason: 'the second image was never opened');
  });
}
