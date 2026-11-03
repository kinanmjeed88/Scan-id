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
  static bool hasApprovedCrop(ImageAsset asset) => asset.hasApprovedCrop;

  /// Sets the category of a document.
  ///
  /// Choosing a category is not a size confirmation on its own, and it never
  /// replaces a size the user confirmed without an approved crop: a typed or
  /// manual size has no boundary basis that could justify replacing it. For
  /// every other item the category applies its catalog size. A known category
  /// confirms that size only when the picture has an approved crop; otherwise
  /// the catalog size stays provisional and the item is off the sheet until the
  /// crop is approved or a size is typed. "Unknown" on an unconfirmed item takes
  /// it off the sheet until a category is chosen. "Other" keeps a confirmed
  /// size. [resetSize] is the explicit way back to a catalog size.
  static Project setKind(Project project, String itemId, DocumentKind kind) {
    final item = PageLayout.item(project, itemId);
    require(!item.locked, 'العنصر مثبت؛ ألغِ التثبيت أولاً.');
    final asset = project.assets.firstWhere((a) => a.id == item.assetId);
    final size = catalogSize(project, asset, kind);
    final keepsConfirmedSize =
        item.sizeConfirmed && (size == null || !hasApprovedCrop(asset));
    if (keepsConfirmedSize) {
      return _replace(
        project,
        item.copyWith(documentKind: kind, recognitionConfidence: 0),
      );
    }
    if (size != null) {
      return _replace(
        project,
        _withCatalogSize(item, kind, size, confirmed: hasApprovedCrop(asset)),
      );
    }
    return _replace(
      project,
      item.copyWith(
        documentKind: kind,
        recognitionConfidence: 0,
        sizeConfirmed: false,
        unplaced: true,
      ),
    );
  }

  static DocumentItem _withCatalogSize(
    DocumentItem item,
    DocumentKind kind,
    PhysicalSizeMm size, {
    required bool confirmed,
  }) => item.copyWith(
    documentKind: kind,
    width: size.width,
    height: size.height,
    recognitionConfidence: 0,
    sizeConfirmed: confirmed,
    keepAspectRatio: true,
    unplaced: !confirmed,
  );

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

  /// Restores the catalog size of the document's category. This is the
  /// explicit size action; a category change alone keeps a confirmed size.
  static Project resetSize(Project project, String itemId) {
    final item = PageLayout.item(project, itemId);
    require(!item.locked, 'العنصر مثبت؛ ألغِ التثبيت أولاً.');
    require(
      project.catalog.natural(item.documentKind) != null,
      'لا يوجد مقاس محفوظ لهذا النوع؛ أدخل العرض والارتفاع يدوياً.',
    );
    final asset = project.assets.firstWhere((a) => a.id == item.assetId);
    final size = catalogSize(project, asset, item.documentKind);
    require(size != null, 'لا يوجد مقاس محفوظ لهذا النوع.');
    return _replace(
      project,
      _withCatalogSize(
        item,
        item.documentKind,
        size!,
        confirmed: hasApprovedCrop(asset),
      ),
    );
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
