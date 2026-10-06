import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/camera_capture.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';

class _Camera implements CameraPort {
  PendingCapture? photo;
  bool failAck = false;
  @override
  Future<PendingCapture?> capture(String projectId) async => photo;
  @override
  Future<PendingCapture?> pending() async => photo;
  @override
  Future<void> discard(String id) async {
    if (failAck) {
      throw const FileSystemException('ack interrupted');
    }
    if (photo?.id == id) {
      await photo!.file.delete();
      photo = null;
    }
  }
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late _Camera port;
  late CameraCapture camera;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-camera-test-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    port = _Camera();
    camera = CameraCapture(projects, assets, port);
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });
  test(
    'camera cancellation creates no image and changes no project revision',
    () async {
      final project = await ProjectService(projects, assets).create('كاميرا');
      expect(await camera.capture(project.id), isNull);
      expect((await projects.get(project.id)).toJson(), project.toJson());
    },
  );
  test(
    'capture survives commit-before-ack interruption and reopen without duplicates; crop retains receipt',
    () async {
      final service = ProjectService(
        projects,
        assets,
        imageEditor: LocalImageEditor(projects.files),
      );
      final project = await service.create('كاميرا');
      final bytes = img.encodeJpg(img.Image(width: 100, height: 60));
      final file = await File('${root.path}/capture.jpg').writeAsBytes(bytes);
      port.photo = PendingCapture(
        id: 'capture1',
        projectId: project.id,
        file: file,
      );
      port.failAck = true;
      final first = (await camera.capture(project.id))!;
      expect(first.assets.single.captureId, 'capture1');
      expect(
        await (await assets.resolve(
          first.assets.single.originalPath,
        )).readAsBytes(),
        bytes,
      );
      final cropped = await service.applyCrop(
        first,
        first.assets.single,
        CropDraft.fullImage().toRecipe(100, 60),
      );
      expect(cropped.assets.single.captureId, 'capture1');
      await projects.close();
      projects = await LocalProjectRepository.open(root);
      camera = CameraCapture(projects, assets, port);
      port.failAck = false;
      final recovered = await camera.accept(
        (await port.pending())!,
        project.id,
      );
      expect(recovered.assets, hasLength(1));
      expect(recovered.revision, cropped.revision);
      expect(await file.exists(), false);
      expect(await port.pending(), isNull);
    },
  );
  test(
    'corrupt capture remains recoverable and does not write metadata',
    () async {
      final project = await ProjectService(projects, assets).create('كاميرا');
      final file = await File(
        '${root.path}/broken.jpg',
      ).writeAsString('broken');
      port.photo = PendingCapture(
        id: 'capture2',
        projectId: project.id,
        file: file,
      );
      await expectLater(camera.capture(project.id), throwsException);
      expect(await file.exists(), true);
      expect((await projects.get(project.id)).assets, isEmpty);
      expect(await port.pending(), isNotNull);
    },
  );
}
