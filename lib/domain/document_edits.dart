import 'document_kind.dart';
import 'page_layout.dart';
import 'project.dart';
import 'validation.dart';

/// Pure edits of documents on the sheet. Each returns a new project; callers
/// decide whether to re-run automatic arrangement afterwards.
class DocumentEdits {
  const DocumentEdits._();

  /// Size of [kind] in the orientation of [asset]'s working image, or null
  /// when the category has no catalog size.
  static PhysicalSizeMm? catalogSize(
    Project project,
    ImageAsset asset,
    DocumentKind kind,
  ) => project.catalog.sizeFor(kind, landscape: asset.width >= asset.height);

  /// Whether [asset] has an approved crop. An approved crop is the only basis
  /// on which a category choice may confirm a physical size. A saved
  /// suggestion, a detected quadrilateral, or a full-frame photo is not one.
  static bool hasApprovedCrop(ImageAsset asset) => asset.crop != null;

  /// Sets the category of a document and applies its catalog size at once.
  ///
  /// Choosing a category is not a size confirmation on its own. A known
  /// category confirms its catalog size only when the picture has an approved
  /// crop. Otherwise the item keeps the catalog size as a provisional size,
  /// stays unconfirmed, and is taken off the sheet until the crop is approved
  /// or a size is typed. "Other" keeps the current size and its confirmation.
  /// "Unknown" takes the document off the sheet until a category is chosen.
  static Project setKind(Project project, String itemId, DocumentKind kind) {
    final item = PageLayout.item(project, itemId);
    require(!item.locked, 'العنصر مثبت؛ ألغِ التثبيت أولاً.');
    final asset = project.assets.firstWhere((a) => a.id == item.assetId);
    final size = catalogSize(project, asset, kind);
    final DocumentItem next;
    if (size != null) {
      final confirmed = hasApprovedCrop(asset);
      next = item.copyWith(
        documentKind: kind,
        width: size.width,
        height: size.height,
        recognitionConfidence: 0,
        sizeConfirmed: confirmed,
        keepAspectRatio: true,
        unplaced: !confirmed,
      );
    } else if (kind == DocumentKind.other) {
      next = item.copyWith(
        documentKind: kind,
        recognitionConfidence: 0,
        sizeConfirmed: item.sizeConfirmed,
        unplaced: !item.sizeConfirmed,
      );
    } else {
      next = item.copyWith(
        documentKind: kind,
        recognitionConfidence: 0,
        sizeConfirmed: false,
        unplaced: true,
      );
    }
    return _replace(project, next);
  }

  /// Re-orients a provisional catalog size to the current picture orientation.
  ///
  /// This never confirms a size and never changes a confirmed one. A printed
  /// size that the user confirmed or typed is kept, and any change to it needs
  /// an explicit action. Used when a crop changes the picture orientation.
  static Project refreshProvisionalSize(Project project, String itemId) {
    final item = PageLayout.item(project, itemId);
    if (item.sizeConfirmed || item.locked) return project;
    final asset = project.assets.firstWhere((a) => a.id == item.assetId);
    final size = catalogSize(project, asset, item.documentKind);
    if (size == null) return project;
    return _replace(
      project,
      item.copyWith(width: size.width, height: size.height),
    );
  }

  /// Sets a document's printed size in millimetres. With a locked aspect
  /// ratio the changed edge decides the other one. A size typed by the user is
  /// a deliberate size, so the document stays on (or becomes ready for) the
  /// sheet.
  static Project resize(
    Project project,
    String itemId, {
    double? width,
    double? height,
  }) {
    final item = PageLayout.item(project, itemId);
    require(!item.locked, 'العنصر مثبت؛ ألغِ التثبيت أولاً.');
    final w = width ?? item.width, h = height ?? item.height;
    final ratio = item.width / item.height;
    final next = item.keepAspectRatio
        ? (width != null && width != item.width
              ? item.copyWith(width: w, height: w / ratio)
              : item.copyWith(width: h * ratio, height: h))
        : item.copyWith(width: w, height: h);
    validDocumentSize(PhysicalSizeMm(next.width, next.height));
    return _replace(
      project,
      next.copyWith(
        documentKind: next.documentKind == DocumentKind.unknown
            ? DocumentKind.other
            : next.documentKind,
        sizeConfirmed: true,
      ),
    );
  }

  /// Restores the catalog size of the document's category.
  static Project resetSize(Project project, String itemId) {
    final item = PageLayout.item(project, itemId);
    require(
      project.catalog.natural(item.documentKind) != null,
      'لا يوجد مقاس محفوظ لهذا النوع؛ أدخل العرض والارتفاع يدوياً.',
    );
    return setKind(project, itemId, item.documentKind);
  }

  /// Turns a document on the sheet by 90° (clockwise).
  static Project rotate(Project project, String itemId) {
    final item = PageLayout.item(project, itemId);
    require(!item.locked, 'العنصر مثبت؛ ألغِ التثبيت أولاً.');
    final turned = ((item.rotation / 90).round() * 90 + 90) % 360;
    return _replace(project, item.copyWith(rotation: turned.toDouble()));
  }

  /// Swaps width and height of every document showing [assetId], used after
  /// the image itself was turned by a quarter.
  static Project swapForTurnedImage(Project project, String assetId) =>
      project.copyWith(
        items: [
          for (final item in project.items)
            item.assetId == assetId
                ? item.copyWith(width: item.height, height: item.width)
                : item,
        ],
      );

  /// Replaces the editable catalog sizes and resizes every document of the
  /// affected categories (locked ones too, since the size is a project rule).
  static Project applyCatalog(Project project, DocumentSizeCatalog catalog) {
    final updated = project.copyWith(catalog: catalog);
    return updated.copyWith(
      items: [
        for (final item in updated.items)
          if (item.documentKind.hasEditableSize)
            () {
              final size = catalog
                  .natural(item.documentKind)!
                  .oriented(landscape: item.width >= item.height);
              return item.copyWith(width: size.width, height: size.height);
            }()
          else
            item,
      ],
    );
  }

  static Project _replace(Project project, DocumentItem value) =>
      project.copyWith(
        items: [
          for (final item in project.items) item.id == value.id ? value : item,
        ],
      );
}
