import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/camera_capture.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

// Audit: a manual crop is the person's decision. It has to survive the store
// being closed and reopened, a later re-recognition, and the replay of a
// camera receipt, and whenever an automatic pass leaves it alone the person
// is told so.
//
// The service-level intake (`arrangeImportedImages`) is only ever handed an
// image that has no item yet, and an image with an item is skipped; these
// tests pin the paths the app can actually reach after a manual crop.

class _Camera implements CameraPort {
  PendingCapture? photo;
  @override
  Future<PendingCapture?> capture(String projectId) async => photo;
  @override
  Future<PendingCapture?> pending() async => photo;
  @override
  Future<void> discard(String id) async {
    if (photo?.id == id) {
      await photo!.file.delete();
      photo = null;
    }
  }
}

/// One region whose corners cross: a proposal the pipeline cannot use, so the
/// document is kept for manual review.
Future<SegmentationResult> _oneUnusableQuad(Uint8List bytes) async =>
    SegmentationResult(
      multi: false,
      candidates: [
        SegmentCandidate(
          region: const [.2, .2, .8, .8],
          corners: [
            Point2(.1, .1),
            Point2(.9, .9),
            Point2(.9, .1),
            Point2(.1, .9),
          ],
          detectionConfidence: .6,
          reason: 'component-support',
        ),
      ],
    );

Uint8List _photo() {
  final source = img.Image(width: 1000, height: 1000);
  img.fill(source, color: img.ColorRgb8(50, 60, 75));
  img.fillRect(
    source,
    x1: 100,
    y1: 100,
    x2: 900,
    y2: 604,
    color: img.ColorRgb8(240, 238, 232),
  );
  return Uint8List.fromList(img.encodePng(source));
}

List<Point2> _manualCorners() => [
  Point2(.12, .14),
  Point2(.88, .10),
  Point2(.90, .86),
  Point2(.10, .90),
];

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-manual-audit-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ProjectService service() => ProjectService(
    projects,
    assets,
    imageEditor: LocalImageEditor(projects.files),
    smartRecognitionEnabled: true,
    segmenter: _oneUnusableQuad,
  );

  /// Import, automatic pass (kept for review), then a manual crop of the item.
  Future<(Project, String sourceId, String editedId)> manuallyCropped(
    ProjectService s,
  ) async {
    var project = await s.create('حماية القص اليدوي');
    project = (await s.importImages(project, [
      ImportSource('وثيقة.png', () => Stream.value(_photo())),
    ])).project;
    final sourceId = project.assets.single.id;
    project = (await s.arrangeImportedImages(project, [sourceId])).project;
    final edited = project.assets.firstWhere(
      (asset) => asset.id == project.items.single.assetId,
    );
    project = await s.applyManualCrop(
      project,
      edited,
      CropDraft(
        corners: _manualCorners(),
      ).toRecipe(edited.width, edited.height),
    );
    return (project, sourceId, edited.id);
  }

  test('a manual crop survives closing and reopening the store', () async {
    final (project, sourceId, editedId) = await manuallyCropped(service());
    final before = project.assets.firstWhere((asset) => asset.id == editedId);
    final cropBefore = before.crop!.toJson();
    final source = project.assets.firstWhere((asset) => asset.id == sourceId);
    final originalBytes = await (await assets.resolve(
      source.originalPath,
    )).readAsBytes();
    expect(before.userAuthoredCrop, isTrue);

    await projects.close();
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);

    final reopened = await projects.get(project.id);
    final after = reopened.assets.firstWhere((asset) => asset.id == editedId);
    expect(after.userAuthoredCrop, isTrue);
    expect(after.crop!.toJson(), cropBefore);
    expect(after.workingPath, before.workingPath);
    expect(reopened.revision, project.revision);
    expect(reopened.items.single.toJson(), project.items.single.toJson());

    // The file the sheet and the export read is the manual crop itself.
    final working = img.decodeImage(
      await (await assets.resolve(after.workingPath)).readAsBytes(),
    )!;
    expect(working.width, after.crop!.outputWidth);
    expect(working.height, after.crop!.outputHeight);
    // And the original is still the imported file, byte for byte.
    expect(
      await (await assets.resolve(
        reopened.assets
            .firstWhere((asset) => asset.id == sourceId)
            .originalPath,
      )).readAsBytes(),
      originalBytes,
    );
  });

  test('re-recognition in a new session leaves the manual crop alone and '
      'says so', () async {
    final (project, sourceId, editedId) = await manuallyCropped(service());
    final before = project.assets.firstWhere((asset) => asset.id == editedId);
    final cropBefore = before.crop!.toJson();
    final itemBefore = project.items.single.toJson();
    final recordBefore = project.documents.single.toJson();

    await projects.close();
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);

    final report = await service().reprocessImages(
      await projects.get(project.id),
      [sourceId],
    );
    final result = report!.project;
    final after = result.assets.firstWhere((asset) => asset.id == editedId);

    expect(after.userAuthoredCrop, isTrue);
    expect(after.crop!.toJson(), cropBefore);
    expect(after.workingPath, before.workingPath);
    expect(result.items.single.toJson(), itemBefore);
    expect(result.documents.single.toJson(), recordBefore);
    expect(report.cropped, 0);
    expect(report.warnings.join('\n'), contains('القص اليدوي'));
  });

  test('a second automatic pass over an image that has an item changes '
      'nothing', () async {
    final s = service();
    final (project, _, editedId) = await manuallyCropped(s);
    final before = project.assets.firstWhere((asset) => asset.id == editedId);

    final report = await s.arrangeImportedImages(project, [editedId]);
    final after = report.project.assets.firstWhere(
      (asset) => asset.id == editedId,
    );

    expect(report.cropped, 0);
    expect(after.userAuthoredCrop, isTrue);
    expect(after.crop!.toJson(), before.crop!.toJson());
    expect(after.workingPath, before.workingPath);
    expect(report.project.items, hasLength(project.items.length));
    expect(report.project.documents, hasLength(project.documents.length));
  });

  test('replaying a camera receipt never re-detects an image the person '
      'already cropped', () async {
    final port = _Camera();
    final camera = CameraCapture(projects, assets, port);
    final s = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      smartRecognitionEnabled: true,
    );
    final created = await s.create('كاميرا ثم قص يدوي');
    final file = await File(
      '${root.path}/capture.jpg',
    ).writeAsBytes(img.encodeJpg(img.Image(width: 400, height: 260)));
    port.photo = PendingCapture(
      id: 'capture-manual',
      projectId: created.id,
      file: file,
    );
    final captured = (await camera.capture(created.id))!;
    final arranged = await s.completeCameraIntake(captured);
    expect(arranged.items, hasLength(1));
    final asset = arranged.assets.firstWhere(
      (entry) => entry.id == arranged.items.single.assetId,
    );

    final cropped = await s.applyManualCrop(
      arranged,
      asset,
      CropDraft(corners: _manualCorners()).toRecipe(asset.width, asset.height),
    );
    final manual = cropped.assets.firstWhere((entry) => entry.id == asset.id);
    expect(manual.userAuthoredCrop, isTrue);
    expect(manual.captureId, 'capture-manual');

    // The receipt is replayed, as it is whenever the screen resumes.
    final replayed = await s.completeCameraIntake(
      await projects.get(cropped.id),
    );
    final after = replayed.assets.firstWhere((entry) => entry.id == asset.id);

    expect(replayed.revision, cropped.revision);
    expect(after.userAuthoredCrop, isTrue);
    expect(after.crop!.toJson(), manual.crop!.toJson());
    expect(after.workingPath, manual.workingPath);
    expect(replayed.items.single.id, cropped.items.single.id);
    expect(replayed.assets, hasLength(cropped.assets.length));
  });
}
