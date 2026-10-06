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

  /// Removes the record only. ProjectService then deletes the app-owned files
  /// of that project, so a crash between the two steps can only leave
  /// unreferenced files (found later by StorageMaintenance), never a record
  /// that points at missing files.
  Future<void> remove(Project project);
  Future<void> close();
}

/// Files written for a replacement source of an existing asset.
class ReplacementFiles {
  const ReplacementFiles({
    required this.revision,
    required this.originalPath,
    required this.workingPath,
    required this.thumbnailPath,
    required this.width,
    required this.height,
  });
  final String revision;
  final String originalPath;
  final String workingPath;
  final String thumbnailPath;
  final int width;
  final int height;
}

abstract interface class AssetRepository {
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  );

  /// New files for an existing asset id; earlier files are never overwritten.
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
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

/// App-owned files that no saved project references any more.
class OrphanFiles {
  OrphanFiles(List<String> paths, this.bytes) : paths = List.unmodifiable(paths);
  final List<String> paths;
  final int bytes;
  int get count => paths.length;
}

/// Deletes app-owned files only, always by validated relative path.
///
/// Implementations must never follow symbolic links and must refuse any path
/// that resolves outside the application storage root, so user files outside
/// that root are unreachable by construction.
abstract interface class StorageMaintenance {
  /// Removes the whole app-owned directory of one removed project.
  Future<void> deleteProjectFiles(String projectId);

  /// Files under the app root that [projects] does not reference.
  Future<OrphanFiles> findOrphans(List<Project> projects);

  /// Removes the given validated relative paths; returns how many were removed.
  Future<int> deleteFiles(Iterable<String> relativePaths);

  /// Removes staging directories left behind by interrupted work.
  Future<int> pruneStaging({Duration olderThan});
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
