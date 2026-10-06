import 'dart:io';
import 'dart:typed_data';

import '../domain/project.dart';

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
