import 'dart:io';
import 'dart:typed_data';

import '../domain/boundary_decision.dart';
import '../domain/project.dart';
import '../domain/crop_draft.dart';
import '../domain/geometry.dart';
import 'cancellation.dart';

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
    this.sourceScaling,
  });
  final String revision;
  final String originalPath;
  final String workingPath;
  final String thumbnailPath;
  final int width;
  final int height;

  /// Source-size reduction applied before preparing a large replacement.
  final String? sourceScaling;
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

  /// Returns a small display image without decoding an over-budget source in
  /// Dart. Large JPEGs use the same sampled native path as imports.
  Future<Uint8List> previewImage(Uint8List source);

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
///
/// [paths] are unlinked and safe to remove. [retained] are unlinked by every
/// saved project but still named by a recovery copy or a pre-upgrade snapshot;
/// they stay until that copy is rewritten, because removing them would leave
/// the copy pointing at missing files.
class OrphanFiles {
  OrphanFiles(
    List<String> paths,
    this.bytes, {
    List<String> retained = const [],
  }) : paths = List.unmodifiable(paths),
       retained = List.unmodifiable(retained);
  final List<String> paths;
  final List<String> retained;
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

/// How a platform can hand generated files to another application, if at all.
enum ShareTarget {
  /// No share surface; saving and printing still work.
  none,

  /// Android: the system chooser receives read-only content URIs.
  shareSheet,

  /// Windows: the generated files are revealed in the file manager.
  revealFolder,
}

class EditorSource {
  const EditorSource(this.preview, this.width, this.height);
  final Uint8List preview;
  final int width;
  final int height;
}

abstract interface class ImageEditor {
  Future<EditorSource> open(ImageAsset asset, {CancellationToken? cancellation});
  Future<List<Point2>?> suggest(Uint8List preview);
  Future<Uint8List> preview(
    ImageAsset asset,
    ImageEditRecipe recipe, {
    CancellationToken? cancellation,
  });
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe);
}

/// Optional metadata capability for a future, separately qualified boundary
/// proposer. The current production editor does not implement this interface;
/// automatic detection is disabled and imports remain available for manual
/// crop/review. Keeping the contract allows proposal provenance to remain
/// explicit without making any detector a fallback.
abstract interface class BoundaryProposalImageEditor implements ImageEditor {
  Future<BoundaryProposal?> suggestProposal(Uint8List preview);
  String? get boundaryModelId;
}

/// Optional capability for rendering an accepted perspective crop directly to
/// lossless PNG bytes at full source resolution (including native EXIF-oriented
/// region extraction on >16 MP JPEGs) without mutating the source [ImageAsset].
///
/// Used when extracting independent derived documents from a multi-document
/// source photograph (**Path C**).
abstract interface class CropBytesImageEditor implements ImageEditor {
  Future<Uint8List> renderCropBytes(ImageAsset asset, ImageEditRecipe recipe);
}
