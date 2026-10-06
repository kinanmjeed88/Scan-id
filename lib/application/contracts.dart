import 'dart:io';
import 'dart:typed_data';

import '../domain/project.dart';
import '../domain/crop_draft.dart';
import '../domain/geometry.dart';

abstract interface class ProjectRepository {
  Future<List<Project>> list();
  Future<Project> get(String id);
  Future<Project> create(Project project);

  /// Optimistic revision check: stale callers never overwrite newer work.
  Future<Project> save(Project project);

  /// Removes metadata only. App-owned assets are retained for recovery.
  Future<void> remove(Project project);
  Future<void> close();
}

abstract interface class AssetRepository {
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  );
  Future<File> resolve(String relativePath);
}

class StorageException implements Exception {
  const StorageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RevisionConflict extends StorageException {
  const RevisionConflict()
    : super('تغير المشروع في عملية أخرى. أعد فتحه قبل التعديل.');
}

class EditorSource {
  const EditorSource(this.preview, this.width, this.height);
  final Uint8List preview;
  final int width;
  final int height;
}

abstract interface class ImageEditor {
  Future<EditorSource> open(ImageAsset asset);
  Future<List<Point2>?> suggest(Uint8List preview);
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe);
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe);
}
