import 'dart:io';
import '../domain/project.dart';
import '../domain/image_limits.dart';
import '../domain/validation.dart';
import 'contracts.dart';
import 'image_reader.dart';

class PendingCapture {
  PendingCapture({
    required this.id,
    required this.projectId,
    required this.file,
  }) {
    validId(id);
    validId(projectId);
  }
  final String id, projectId;
  final File file;
}

abstract interface class CameraPort {
  Future<PendingCapture?> capture(String projectId);
  Future<PendingCapture?> pending();
  Future<void> discard(String id);
}

class CameraCapture {
  const CameraCapture(this.projects, this.assets, this.port);
  final ProjectRepository projects;
  final AssetRepository assets;
  final CameraPort port;
  Future<Project?> capture(String projectId) async {
    final photo = await port.capture(projectId);
    return photo == null ? null : accept(photo, projectId);
  }

  Future<Project> accept(PendingCapture photo, String projectId) async {
    var current = await projects.get(projectId);
    if (!current.assets.any((a) => a.captureId == photo.id)) {
      require(
        current.assets.length < maxProjectAssets,
        'وصل المشروع إلى حد 200 صورة.',
      );
      final bytes = await readBoundedImage(photo.file.openRead());
      final imported = await assets.importImage(
        current.id,
        'التقاط كاميرا.jpg',
        bytes,
      );
      final asset = ImageAsset.fromJson({
        ...imported.toJson(),
        'captureId': photo.id,
      });
      current = await projects.save(
        current.copyWith(assets: [...current.assets, asset]),
      );
    }
    // A killed process between commit and acknowledgement must not duplicate a
    // photo. The receipt lives in metadata, not in the truncated edit log.
    try {
      await port.discard(photo.id);
    } catch (_) {
      /* Retain a recoverable journal; the committed project is still success. */
    }
    return current;
  }
}
