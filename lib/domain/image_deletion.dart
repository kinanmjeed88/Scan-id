/// Deleting an image from a project is one decision with several consequences.
/// This file computes every consequence as pure data before anything is
/// written, so the same plan can be shown to the user and then applied
/// unchanged. Nothing here touches files: the application layer commits the
/// metadata first and only then removes the folder the plan names.
library;

import 'page_layout.dart';
import 'project.dart';
import 'recognition_routing.dart';
import 'validation.dart';

/// Everything that deleting one image from a project will do.
class ImageDeletionPlan {
  const ImageDeletionPlan({
    required this.assetId,
    required this.assetDirectory,
    required this.itemIds,
    required this.lockedItemIds,
    required this.documentIds,
    required this.dismissedDocumentIds,
    required this.keptDerivedAssetIds,
  });

  final String assetId;

  /// Project-relative folder that holds every file this image owns: its
  /// original, working copy, thumbnail, crop revisions and replacements.
  final String assetDirectory;

  /// Layout elements that leave the sheet: the image's own elements, plus
  /// elements of recognition records that describe the image.
  final List<String> itemIds;

  /// The subset of [itemIds] the user had locked. They are removed too, and
  /// the confirmation says so, because the user asked for the image itself to
  /// go.
  final List<String> lockedItemIds;

  /// Recognition records removed with the image: records whose source is the
  /// image, and records whose processed file lives in its folder.
  final List<String> documentIds;

  /// The subset of [documentIds] that were dismissal tombstones. A tombstone
  /// remembers a region the user rejected. Deleting the image deletes the
  /// decision with it: nothing keeps a fingerprint of the photo, so importing
  /// the same file later may propose that region again. This is disclosed.
  final List<String> dismissedDocumentIds;

  /// Derived images (crops made from this image) that remain in the project.
  /// They keep their own files and pixels. Their `derivedFrom` still names the
  /// deleted image, which is what keeps them from being treated as photographs.
  final List<String> keptDerivedAssetIds;

  bool get removesSheetElements => itemIds.isNotEmpty;
}

/// Computes what deleting [assetId] removes. Throws [ValidationException] for
/// an image that is not part of [project].
///
/// The rule is ownership, not guesswork: a record or element belongs to the
/// image when it names the image as its source or lives in the image's own
/// folder. Derived images are never removed here, because they are independent
/// pictures the user may still use.
ImageDeletionPlan planImageDeletion(Project project, String assetId) {
  require(
    project.assets.any((asset) => asset.id == assetId),
    'الصورة ليست ضمن هذا المشروع.',
  );
  bool ownsPath(String path) => assetOwnsProjectPath(project.id, assetId, path);

  final documents = [
    for (final record in project.documents)
      if (record.sourceImageId == assetId ||
          record.sides.any(
            (side) =>
                ownsPath(side.processedAsset.workingPath) ||
                ownsPath(side.processedAsset.thumbnailPath),
          ))
        record,
  ];
  final documentIds = {for (final record in documents) record.id};
  final items = [
    for (final item in project.items)
      if (item.assetId == assetId ||
          (item.documentId != null && documentIds.contains(item.documentId)))
        item,
  ];
  return ImageDeletionPlan(
    assetId: assetId,
    assetDirectory: 'projects/${project.id}/assets/$assetId',
    itemIds: [for (final item in items) item.id],
    lockedItemIds: [
      for (final item in items)
        if (item.locked) item.id,
    ],
    documentIds: [for (final record in documents) record.id],
    dismissedDocumentIds: [
      for (final record in documents)
        if (isDismissed(record)) record.id,
    ],
    keptDerivedAssetIds: [
      for (final asset in project.assets)
        if (asset.id != assetId && asset.derivedFrom == assetId) asset.id,
    ],
  );
}

/// The project after [plan] is applied.
///
/// Sheet elements are removed through [PageLayout.remove], which already
/// cascades to recognition records and pair links exactly as the editor's own
/// delete does. The records the plan names are then removed as well (including
/// tombstones, which have no element to cascade from), and the image leaves
/// the library. Every other element, record, group and position is carried
/// over unchanged.
///
/// Refuses rather than returns a project that still points into the folder
/// about to be deleted. Sharing is therefore checked, not assumed.
Project applyImageDeletion(Project project, ImageDeletionPlan plan) {
  require(
    project.assets.any((asset) => asset.id == plan.assetId),
    'الصورة ليست ضمن هذا المشروع.',
  );
  final laid = PageLayout.remove(
    project,
    plan.itemIds.toSet(),
    allowLocked: true,
  );
  final removedDocuments = plan.documentIds.toSet();
  final next = laid.copyWith(
    assets: [
      for (final asset in laid.assets)
        if (asset.id != plan.assetId) asset,
    ],
    documents: [
      for (final record in laid.documents)
        if (!removedDocuments.contains(record.id)) record,
    ],
  );
  require(
    !_referencesFolder(next, plan.assetDirectory),
    'ملفات الصورة ما زالت مستخدمة؛ لم يُحذف شيء.',
  );
  return next;
}

/// Takes every element of [assetId] off the sheet while keeping the image in
/// the project. This is the separate, reversible-by-reinsertion counterpart of
/// deletion, offered on its own so that keeping a photo is never forced to
/// mean deleting it.
Project detachImageFromSheet(Project project, String assetId) {
  require(
    project.assets.any((asset) => asset.id == assetId),
    'الصورة ليست ضمن هذا المشروع.',
  );
  final ids = {
    for (final item in project.items)
      if (item.assetId == assetId) item.id,
  };
  require(ids.isNotEmpty, 'هذه الصورة ليست موضوعة على الورقة.');
  return PageLayout.remove(project, ids, allowLocked: true);
}

/// Whether any asset or record of [project] still names a file inside
/// [directory]. Used as the final guard before a folder is removed.
bool _referencesFolder(Project project, String directory) {
  bool inside(String path) => path.startsWith('$directory/');
  return project.assets.any(
        (asset) => [
          asset.originalPath,
          asset.workingPath,
          asset.thumbnailPath,
          asset.processingInputPath,
        ].any(inside),
      ) ||
      project.documents.any(
        (record) => record.sides.any(
          (side) =>
              inside(side.processedAsset.workingPath) ||
              inside(side.processedAsset.thumbnailPath),
        ),
      );
}
