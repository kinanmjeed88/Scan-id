import 'geometry.dart';
import 'document_kind.dart';
import 'image_adjustments.dart';
import 'validation.dart';
import 'image_limits.dart';
import 'recognition.dart';

enum PaperOrientation { portrait, landscape }

enum ExportFormat { pdf, png, jpg }

enum LayoutOrder { input, area }

/// How automatic arrangement fills the sheets.
///
/// [ordered] keeps the category order in rows (unified card, residence card,
/// passport, ration card…), right to left, and continues on the next page.
/// [compact] packs as many documents per page as possible (MaxRects) and
/// flows what does not fit to the following pages.
enum ArrangementStrategy { ordered, compact }

class Margins {
  Margins({this.top = 10, this.right = 10, this.bottom = 10, this.left = 10}) {
    require(
      [top, right, bottom, left].every((v) => v.isFinite && v >= 0),
      'الهوامش يجب أن تكون موجبة أو صفراً.',
    );
  }
  final double top;
  final double right;
  final double bottom;
  final double left;

  /// The same margin on all four sides.
  factory Margins.all(double value) =>
      Margins(top: value, right: value, bottom: value, left: value);

  bool get isUniform => top == right && right == bottom && bottom == left;

  Map<String, Object?> toJson() => {
    'top': top,
    'right': right,
    'bottom': bottom,
    'left': left,
  };
  factory Margins.fromJson(Object? json) {
    final m = objectMap(json);
    return Margins(
      top: finiteNumber(m['top'], 'top'),
      right: finiteNumber(m['right'], 'right'),
      bottom: finiteNumber(m['bottom'], 'bottom'),
      left: finiteNumber(m['left'], 'left'),
    );
  }
}

class PaperSettings {
  PaperSettings({
    this.orientation = PaperOrientation.portrait,
    Margins? margins,
  }) : margins = margins ?? Margins() {
    require(
      this.margins.left + this.margins.right < width &&
          this.margins.top + this.margins.bottom < height,
      'الهوامش تستهلك الورقة بالكامل.',
    );
  }
  final PaperOrientation orientation;
  final Margins margins;

  PaperSettings copyWith({PaperOrientation? orientation, Margins? margins}) =>
      PaperSettings(
        orientation: orientation ?? this.orientation,
        margins: margins ?? this.margins,
      );

  double get width => orientation == PaperOrientation.portrait ? 210 : 297;
  double get height => orientation == PaperOrientation.portrait ? 297 : 210;
  RectMm get printable => RectMm(
    margins.left,
    margins.top,
    width - margins.left - margins.right,
    height - margins.top - margins.bottom,
  );
  Map<String, Object?> toJson() => {
    'orientation': orientation.name,
    'margins': margins.toJson(),
  };
  factory PaperSettings.fromJson(Object? json) {
    final m = objectMap(json);
    return PaperSettings(
      orientation: readEnum(PaperOrientation.values, m['orientation']),
      margins: Margins.fromJson(m['margins']),
    );
  }
}

class LayoutSettings {
  LayoutSettings({
    this.horizontalGap = 5,
    this.verticalGap = 5,
    this.allowRotation = false,
    this.order = LayoutOrder.input,
    this.strategy = ArrangementStrategy.ordered,
  }) {
    require(
      [horizontalGap, verticalGap].every((v) => v.isFinite && v >= 0),
      'مسافات التخطيط غير صالحة.',
    );
  }
  final double horizontalGap;
  final double verticalGap;
  final bool allowRotation;
  final LayoutOrder order;
  final ArrangementStrategy strategy;

  LayoutSettings copyWith({
    double? horizontalGap,
    double? verticalGap,
    bool? allowRotation,
    LayoutOrder? order,
    ArrangementStrategy? strategy,
  }) => LayoutSettings(
    horizontalGap: horizontalGap ?? this.horizontalGap,
    verticalGap: verticalGap ?? this.verticalGap,
    allowRotation: allowRotation ?? this.allowRotation,
    order: order ?? this.order,
    strategy: strategy ?? this.strategy,
  );

  Map<String, Object?> toJson() => {
    'horizontalGap': horizontalGap,
    'verticalGap': verticalGap,
    'allowRotation': allowRotation,
    'order': order.name,
    'strategy': strategy.name,
  };
  factory LayoutSettings.fromJson(Object? json) {
    final m = objectMap(json);
    return LayoutSettings(
      horizontalGap: finiteNumber(m['horizontalGap'], 'horizontalGap'),
      verticalGap: finiteNumber(m['verticalGap'], 'verticalGap'),
      allowRotation: boolean(m['allowRotation'], 'allowRotation'),
      order: readEnum(LayoutOrder.values, m['order']),
      strategy: m['strategy'] == null
          ? ArrangementStrategy.ordered
          : readEnum(ArrangementStrategy.values, m['strategy']),
    );
  }
}

class ExportProfile {
  ExportProfile({
    this.format = ExportFormat.pdf,
    this.dpi = 300,
    this.jpegQuality = 95,
  }) {
    require(
      dpi == 300 || dpi == 600,
      'الدقة المدعومة في النموذج: 300 أو 600 DPI.',
    );
    require(jpegQuality >= 1 && jpegQuality <= 100, 'جودة JPEG غير صالحة.');
  }
  final ExportFormat format;
  final int dpi;
  final int jpegQuality;
  Map<String, Object?> toJson() => {
    'format': format.name,
    'dpi': dpi,
    'jpegQuality': jpegQuality,
  };
  factory ExportProfile.fromJson(Object? json) {
    final m = objectMap(json);
    return ExportProfile(
      format: readEnum(ExportFormat.values, m['format']),
      dpi: integer(m['dpi'], 'dpi'),
      jpegQuality: integer(m['jpegQuality'], 'jpegQuality'),
    );
  }
}

/// Metadata only. Image bytes live in immutable, app-owned files.
class ImageAsset {
  ImageAsset({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.workingPath,
    required this.thumbnailPath,
    required this.width,
    required this.height,
    this.crop,
    this.captureId,
    ImageAdjustments? adjustments,
    List<String> transforms = const [],
  }) : adjustments = adjustments ?? ImageAdjustments(),
       transforms = List.unmodifiable(transforms) {
    validId(id);
    if (captureId != null) {
      validId(captureId!);
    }
    validName(name);
    for (final path in [originalPath, workingPath, thumbnailPath]) {
      validAssetPath(path);
    }
    require(
      originalPath != workingPath &&
          originalPath != thumbnailPath &&
          workingPath != thumbnailPath,
      'الأصل ونسخ العمل يجب أن تكون ملفات مستقلة.',
    );
    require(
      withinImageBudget(width, height),
      'أبعاد الصورة غير صالحة أو تتجاوز حد الاستيراد.',
    );
    require(
      transforms.length <= 500 && transforms.every((t) => t.length <= 200),
      'سجل تحويلات الصورة كبير جداً.',
    );
  }
  final String? captureId;
  final String id;
  final String name;
  final String originalPath;
  final String workingPath;
  final String thumbnailPath;
  final int width;
  final int height;
  final CropGeometry? crop;
  final ImageAdjustments adjustments;
  final List<String> transforms;
  Map<String, Object?> toJson() => {
    'id': id,
    'captureId': captureId,
    'name': name,
    'originalPath': originalPath,
    'workingPath': workingPath,
    'thumbnailPath': thumbnailPath,
    'width': width,
    'height': height,
    'crop': crop?.toJson(),
    'adjustments': adjustments.toJson(),
    'transforms': transforms,
  };
  factory ImageAsset.fromJson(Object? json) {
    final m = objectMap(json);
    return ImageAsset(
      id: text(m['id'], 'id'),
      captureId: m['captureId'] == null
          ? null
          : text(m['captureId'], 'captureId'),
      name: text(m['name'], 'name'),
      originalPath: text(m['originalPath'], 'originalPath'),
      workingPath: text(m['workingPath'], 'workingPath'),
      thumbnailPath: text(m['thumbnailPath'], 'thumbnailPath'),
      width: integer(m['width'], 'width'),
      height: integer(m['height'], 'height'),
      crop: m['crop'] == null ? null : CropGeometry.fromJson(m['crop']),
      adjustments: m['adjustments'] == null
          ? ImageAdjustments()
          : ImageAdjustments.fromJson(m['adjustments']),
      transforms: objectList(
        m['transforms'],
      ).map((v) => text(v, 'transform')).toList(),
    );
  }
}

class DocumentItem {
  DocumentItem({
    required this.id,
    required this.assetId,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.pageIndex = 0,
    this.zIndex = 0,
    this.locked = false,
    this.keepAspectRatio = true,
    this.documentKind = DocumentKind.unknown,
    this.recognitionConfidence = 0,
    this.sizeConfirmed = false,
    this.documentId,
    this.sideId,
    this.presetSnapshot,
    this.groupId,
  }) {
    final page = pageIndex;
    require(page == null || (page >= 0 && page < 100), 'رقم الصفحة غير صالح.');
    validId(id);
    validId(assetId);
    if (documentId != null) validId(documentId!);
    if (sideId != null) validId(sideId!);
    if (groupId != null) validId(groupId!);
    require(
      [
            x,
            y,
            width,
            height,
            rotation,
            recognitionConfidence,
          ].every((v) => v.isFinite) &&
          recognitionConfidence >= 0 &&
          recognitionConfidence <= 1,
      'قيم العنصر غير صالحة.',
    );
    require(
      width > 0 &&
          height > 0 &&
          width <= 10000 &&
          height <= 10000 &&
          x.abs() <= 10000 &&
          y.abs() <= 10000 &&
          rotation >= -360 &&
          rotation <= 360,
      'أبعاد أو زاوية العنصر خارج المجال.',
    );
  }
  final String id;
  final String assetId;
  final int? pageIndex;
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final int zIndex;
  final bool locked;
  final bool keepAspectRatio;
  final DocumentKind documentKind;
  final double recognitionConfidence;
  final bool sizeConfirmed;

  /// v5 link to the recognition/provenance truth (a [DocumentRecord]); null for
  /// a pure manual item. See docs/DESIGN_LOCK.md §1.
  final String? documentId;

  /// v5 link to the side of [documentId] this layout item represents.
  final String? sideId;

  /// v5 frozen preset decision this item was sized from (write-once).
  final PresetSnapshot? presetSnapshot;

  /// v5 link to a keep-together [LayoutGroup]; null when ungrouped.
  final String? groupId;
  RectMm get bounds => RectMm(x, y, width, height).rotatedBounds(rotation);

  DocumentItem copyWith({
    String? id,
    int? pageIndex,
    bool unplaced = false,
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    int? zIndex,
    bool? locked,
    bool? keepAspectRatio,
    DocumentKind? documentKind,
    double? recognitionConfidence,
    bool? sizeConfirmed,
    String? documentId,
    String? sideId,
    PresetSnapshot? presetSnapshot,
    String? groupId,
  }) => DocumentItem(
    id: id ?? this.id,
    pageIndex: unplaced ? null : (pageIndex ?? this.pageIndex),
    assetId: assetId,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    rotation: rotation ?? this.rotation,
    zIndex: zIndex ?? this.zIndex,
    locked: locked ?? this.locked,
    keepAspectRatio: keepAspectRatio ?? this.keepAspectRatio,
    documentKind: documentKind ?? this.documentKind,
    recognitionConfidence: recognitionConfidence ?? this.recognitionConfidence,
    sizeConfirmed: sizeConfirmed ?? this.sizeConfirmed,
    documentId: documentId ?? this.documentId,
    sideId: sideId ?? this.sideId,
    presetSnapshot: presetSnapshot ?? this.presetSnapshot,
    groupId: groupId ?? this.groupId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'assetId': assetId,
    'pageIndex': pageIndex,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'rotation': rotation,
    'zIndex': zIndex,
    'locked': locked,
    'keepAspectRatio': keepAspectRatio,
    'documentKind': documentKind.name,
    'recognitionConfidence': recognitionConfidence,
    'sizeConfirmed': sizeConfirmed,
    'documentId': documentId,
    'sideId': sideId,
    'presetSnapshot': presetSnapshot?.toJson(),
    'groupId': groupId,
  };
  factory DocumentItem.fromJson(Object? json) {
    final m = objectMap(json);
    final sizeConfirmed = m['sizeConfirmed'] == null
        ? false
        : boolean(m['sizeConfirmed'], 'sizeConfirmed');
    final savedPageIndex = !m.containsKey('pageIndex')
        ? 0
        : m['pageIndex'] == null
        ? null
        : integer(m['pageIndex'], 'pageIndex');
    return DocumentItem(
      id: text(m['id'], 'id'),
      // Legacy layouts did not record whether their physical sizes were
      // measured. Keep their metadata, but move them off-sheet until reviewed.
      pageIndex: sizeConfirmed ? savedPageIndex : null,
      assetId: text(m['assetId'], 'assetId'),
      x: finiteNumber(m['x'], 'x'),
      y: finiteNumber(m['y'], 'y'),
      width: finiteNumber(m['width'], 'width'),
      height: finiteNumber(m['height'], 'height'),
      rotation: finiteNumber(m['rotation'], 'rotation'),
      zIndex: integer(m['zIndex'], 'zIndex'),
      locked: boolean(m['locked'], 'locked'),
      keepAspectRatio: boolean(m['keepAspectRatio'], 'keepAspectRatio'),
      documentKind: m['documentKind'] == null
          ? DocumentKind.unknown
          : readEnum(DocumentKind.values, m['documentKind']),
      recognitionConfidence: m['recognitionConfidence'] == null
          ? 0
          : finiteNumber(m['recognitionConfidence'], 'recognitionConfidence'),
      sizeConfirmed: sizeConfirmed,
      documentId: m['documentId'] == null
          ? null
          : text(m['documentId'], 'documentId'),
      sideId: m['sideId'] == null ? null : text(m['sideId'], 'sideId'),
      presetSnapshot: m['presetSnapshot'] == null
          ? null
          : PresetSnapshot.fromJson(m['presetSnapshot']),
      groupId: m['groupId'] == null ? null : text(m['groupId'], 'groupId'),
    );
  }
}

class Project {
  Project({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.revision = 0,
    this.pageCount = 1,
    PaperSettings? paper,
    LayoutSettings? layout,
    ExportProfile? exportProfile,
    this.catalog = const DocumentSizeCatalog(),
    List<ImageAsset> assets = const [],
    List<DocumentItem> items = const [],
    List<DocumentRecord> documents = const [],
    List<LayoutGroup> layoutGroups = const [],
  }) : paper = paper ?? PaperSettings(),
       layout = layout ?? LayoutSettings(),
       exportProfile = exportProfile ?? ExportProfile(),
       assets = List.unmodifiable(assets),
       items = List.unmodifiable(items),
       documents = List.unmodifiable(documents),
       layoutGroups = List.unmodifiable(layoutGroups) {
    require(pageCount > 0 && pageCount <= 100, 'عدد الصفحات غير صالح.');
    require(
      items.every((i) => i.pageIndex == null || i.pageIndex! < pageCount),
      'عنصر يشير إلى صفحة غير موجودة.',
    );
    validId(id);
    validName(name);
    require(revision >= 0, 'رقم مراجعة المشروع غير صالح.');
    require(!updatedAt.isBefore(createdAt), 'تاريخ تحديث المشروع يسبق إنشاءه.');
    require(
      assets.length <= maxProjectAssets && items.length <= maxProjectItems,
      'المشروع يتجاوز حد العناصر.',
    );
    final assetIds = assets.map((a) => a.id).toSet();
    require(
      assetIds.length == assets.length &&
          items.map((i) => i.id).toSet().length == items.length,
      'معرّفات مكررة في المشروع.',
    );
    require(
      items.every((i) => assetIds.contains(i.assetId)),
      'عنصر يشير إلى صورة مفقودة.',
    );
    for (final asset in assets) {
      final prefix = 'projects/$id/assets/${asset.id}/';
      require(
        [
          asset.originalPath,
          asset.workingPath,
          asset.thumbnailPath,
        ].every((p) => p.startsWith(prefix)),
        'الصورة ليست مملوكة لهذا المشروع.',
      );
    }
    // v5: recognition records and layout groups are bounded by the item limit
    // (each is realized through items); no new arbitrary limit is introduced.
    require(
      documents.length <= items.length &&
          documents.length <= maxProjectItems &&
          layoutGroups.length <= items.length &&
          layoutGroups.length <= maxProjectItems,
      'المشروع يتجاوز حدود المستندات أو المجموعات.',
    );
    final documentIds = documents.map((d) => d.id).toSet();
    require(documentIds.length == documents.length, 'معرّفات مستندات مكررة.');
    final groupIds = layoutGroups.map((g) => g.id).toSet();
    require(groupIds.length == layoutGroups.length, 'معرّفات مجموعات مكررة.');
    final itemIds = items.map((i) => i.id).toSet();
    // Every persisted reference resolves to a valid owner (DESIGN_LOCK §1).
    for (final item in items) {
      if (item.documentId != null) {
        final record = documents.firstWhere(
          (d) => d.id == item.documentId,
          orElse: () =>
              throw const ValidationException('عنصر يشير إلى مستند مفقود.'),
        );
        if (item.sideId != null) {
          require(
            record.sides.any((s) => s.id == item.sideId),
            'عنصر يشير إلى وجه مستند مفقود.',
          );
        }
      }
      if (item.groupId != null) {
        require(
          groupIds.contains(item.groupId),
          'عنصر يشير إلى مجموعة مفقودة.',
        );
      }
    }
    for (final group in layoutGroups) {
      require(
        group.itemIds.every(itemIds.contains),
        'مجموعة تشير إلى عنصر مفقود.',
      );
    }
    for (final record in documents) {
      require(
        assetIds.contains(record.sourceImageId),
        'مستند يشير إلى صورة مصدر مفقودة.',
      );
      for (final side in record.sides) {
        validProcessedPath(id, side.processedAsset.workingPath);
        validProcessedPath(id, side.processedAsset.thumbnailPath);
      }
      // Pairing links must resolve and be reciprocal, so a stored pair can
      // never point at a removed or unrelated record.
      final partnerId = record.pairedDocumentId;
      if (partnerId != null) {
        final partner = documents.firstWhere(
          (d) => d.id == partnerId,
          orElse: () =>
              throw const ValidationException('مستند يشير إلى قرين مفقود.'),
        );
        require(
          partner.pairedDocumentId == record.id,
          'اقتران المستندين غير متبادل.',
        );
      }
    }
  }
  static const schemaVersion = 5;
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;
  final int pageCount;
  final PaperSettings paper;
  final LayoutSettings layout;
  final ExportProfile exportProfile;

  /// Printed sizes per document category for this project.
  final DocumentSizeCatalog catalog;
  final List<ImageAsset> assets;
  final List<DocumentItem> items;

  /// v5 recognition/provenance/processing truth. Empty for projects that never
  /// used recognition (and for a freshly-imported v5 project until the
  /// recognition pipeline runs). See docs/DESIGN_LOCK.md §1.
  final List<DocumentRecord> documents;

  /// v5 keep-together layout groups.
  final List<LayoutGroup> layoutGroups;

  Project copyWith({
    String? name,
    DateTime? updatedAt,
    int? revision,
    int? pageCount,
    PaperSettings? paper,
    LayoutSettings? layout,
    ExportProfile? exportProfile,
    DocumentSizeCatalog? catalog,
    List<ImageAsset>? assets,
    List<DocumentItem>? items,
    List<DocumentRecord>? documents,
    List<LayoutGroup>? layoutGroups,
  }) => Project(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    revision: revision ?? this.revision,
    pageCount: pageCount ?? this.pageCount,
    paper: paper ?? this.paper,
    layout: layout ?? this.layout,
    exportProfile: exportProfile ?? this.exportProfile,
    catalog: catalog ?? this.catalog,
    assets: assets ?? this.assets,
    items: items ?? this.items,
    documents: documents ?? this.documents,
    layoutGroups: layoutGroups ?? this.layoutGroups,
  );

  /// Moves one image inside the library order, which is the order the editor
  /// and the packing proposal present to the user. Layout items are untouched.
  Project reorderAssets(int from, int to) {
    require(
      from >= 0 && from < assets.length && to >= 0 && to < assets.length,
      'ترتيب الصور المطلوب خارج القائمة.',
    );
    if (from == to) {
      return this;
    }
    final next = [...assets];
    next.insert(to, next.removeAt(from));
    return copyWith(assets: next);
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'revision': revision,
    'pageCount': pageCount,
    'paper': paper.toJson(),
    'layout': layout.toJson(),
    'exportProfile': exportProfile.toJson(),
    'catalog': catalog.toJson(),
    'assets': assets.map((a) => a.toJson()).toList(),
    'items': items.map((i) => i.toJson()).toList(),
    'documents': documents.map((d) => d.toJson()).toList(),
    'layoutGroups': layoutGroups.map((g) => g.toJson()).toList(),
  };
  factory Project.fromJson(Object? json) {
    final m = objectMap(json);
    final version = integer(m['schemaVersion'], 'schemaVersion');
    require(
      [1, 2, 3, 4, schemaVersion].contains(version),
      'إصدار المشروع غير مدعوم؛ لم يتم تعديل البيانات.',
    );
    final created = DateTime.tryParse(text(m['createdAt'], 'createdAt'));
    final updated = DateTime.tryParse(text(m['updatedAt'], 'updatedAt'));
    require(created != null && updated != null, 'تواريخ المشروع غير صالحة.');
    final catalog = DocumentSizeCatalog.fromJson(m['catalog']);
    final assets = objectList(m['assets']).map(ImageAsset.fromJson).toList();
    final items = objectList(m['items']).map(DocumentItem.fromJson).toList();
    final documents = m['documents'] == null
        ? const <DocumentRecord>[]
        : objectList(m['documents']).map(DocumentRecord.fromJson).toList();
    final layoutGroups = m['layoutGroups'] == null
        ? const <LayoutGroup>[]
        : objectList(m['layoutGroups']).map(LayoutGroup.fromJson).toList();
    // Migration: only legacy (≤4) records synthesize DocumentRecords from their
    // inline recognition fields. A v5 record is read verbatim (idempotent), so a
    // freshly-imported v5 project with an inline signal but no record is left
    // exactly as stored — no behavior change.
    var finalDocuments = documents;
    var finalItems = items;
    if (version < schemaVersion) {
      final synthesized = synthesizeLegacyRecords(
        assets: assets,
        items: items,
        catalog: catalog,
        sourceSchema: version,
      );
      finalDocuments = synthesized.documents;
      finalItems = synthesized.items;
    }
    return Project(
      id: text(m['id'], 'id'),
      name: text(m['name'], 'name'),
      createdAt: created!,
      updatedAt: updated!,
      revision: integer(m['revision'], 'revision'),
      pageCount: m['pageCount'] == null
          ? 1
          : integer(m['pageCount'], 'pageCount'),
      paper: PaperSettings.fromJson(m['paper']),
      layout: LayoutSettings.fromJson(m['layout']),
      exportProfile: ExportProfile.fromJson(m['exportProfile']),
      catalog: catalog,
      assets: assets,
      items: finalItems,
      documents: finalDocuments,
      layoutGroups: layoutGroups,
    );
  }
}

/// Deterministic, idempotent synthesis of v5 [DocumentRecord]s from the inline
/// recognition fields of a legacy (≤4) project.
///
/// For every item that carries a recognition signal (`documentKind != unknown`
/// or `recognitionConfidence > 0`) and is not already linked, a record is
/// created that reuses the asset's existing working image (no new file) and
/// records ONLY the legacy classification/final confidence — detection,
/// geometry, OCR and preset confidence are left absent and never manufactured
/// (docs/DESIGN_LOCK.md §2). Items without a signal stay pure manual items.
///
/// Ids are derived from the stable item id (`rec-<itemId>`, `side-<itemId>`), so
/// re-running is a no-op and the result is deterministic. The raw old record is
/// never mutated here; the pre-upgrade snapshot and atomic write live in the
/// repository.
({List<DocumentRecord> documents, List<DocumentItem> items})
synthesizeLegacyRecords({
  required List<ImageAsset> assets,
  required List<DocumentItem> items,
  required DocumentSizeCatalog catalog,
  required int sourceSchema,
}) {
  final assetById = {for (final asset in assets) asset.id: asset};
  final documents = <DocumentRecord>[];
  final nextItems = <DocumentItem>[];
  final usedIds = <String>{};
  for (final item in items) {
    final hasSignal =
        item.documentKind != DocumentKind.unknown ||
        item.recognitionConfidence > 0;
    if (item.documentId != null || !hasSignal) {
      nextItems.add(item);
      continue;
    }
    final asset = assetById[item.assetId];
    // A dangling asset reference is rejected by the Project constructor; leave
    // the item untouched here so that safe refusal (not a crash) happens there.
    if (asset == null) {
      nextItems.add(item);
      continue;
    }
    final record = _synthesizeRecord(item, asset, catalog, sourceSchema);
    // Defensive: a synthesized id colliding with an existing record is a safe
    // refusal, never a silent overwrite. Impossible in the ≤4 path (no records
    // exist pre-v5), but enforced anyway.
    if (!usedIds.add(record.id)) {
      nextItems.add(item);
      continue;
    }
    documents.add(record);
    nextItems.add(
      item.copyWith(
        documentId: record.id,
        sideId: record.sides.single.id,
        presetSnapshot: _snapshotFor(item, catalog),
      ),
    );
  }
  return (documents: documents, items: nextItems);
}

DocumentRecord _synthesizeRecord(
  DocumentItem item,
  ImageAsset asset,
  DocumentSizeCatalog catalog,
  int sourceSchema,
) {
  final recognized = item.documentKind != DocumentKind.unknown;
  final variantId = catalog.natural(item.documentKind) != null
      ? builtinVariantId(item.documentKind)
      : null;
  final legacy = 'legacy-v$sourceSchema';
  final legacyConfidence = Confidence(
    value: item.recognitionConfidence,
    reason: 'legacy scalar (pre-v5)',
    producer: 'suggestDocumentType',
    version: 'legacy',
  );
  final crop = asset.crop;
  // The detection region is deterministic, never AI-derived: the user's crop
  // corners when a crop exists, otherwise the truthful full-frame box. No
  // detector ran, so no detection *confidence* is invented (MIGRATION_V5 §4,
  // SCHEMA_V5 §4.6). Point2 is not const-constructible (it validates), so the
  // fallback box is a plain list.
  final detectionPolygon = crop != null
      ? crop.corners
      : <Point2>[Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];
  final side = DocumentSide(
    id: 'side-${item.id}',
    // Legacy Scan-id never distinguished front from back.
    side: SideKind.unknown,
    processedAsset: ProcessedAssetRef(
      workingPath: asset.workingPath,
      thumbnailPath: asset.thumbnailPath,
      width: crop?.outputWidth ?? asset.width,
      height: crop?.outputHeight ?? asset.height,
      orientation: asset.adjustments.quarterTurns,
      processingVersion: legacy,
      // Crop geometry carried verbatim from the asset; absent when the asset has
      // no crop (never fabricated). effectiveDpi is unknown for legacy, so it
      // stays absent (SCHEMA_V5 §4.5).
      corners: crop?.corners,
      outputWidth: crop?.outputWidth,
      outputHeight: crop?.outputHeight,
    ),
    detection: DetectionRef(
      detectionId: item.id,
      // No modern detector ran: the detection confidence is ABSENT, not zero.
      detectionConfidence: null,
      producer: 'legacy-import',
      version: legacy,
      // Deterministic region (crop corners or full-frame box); no bbox — legacy
      // never computed one (MIGRATION_V5 §4, SCHEMA_V5 §4.6).
      polygon: detectionPolygon,
    ),
  );
  return DocumentRecord(
    id: 'rec-${item.id}',
    sourceImageId: asset.id,
    sides: [side],
    recognition: RecognitionResult(
      documentKind: item.documentKind,
      status: recognized
          ? RecognitionStatus.recognized
          : RecognitionStatus.unknown,
      confidences: ConfidenceSet(
        classification: legacyConfidence,
        finalConfidence: legacyConfidence,
      ),
      preset: variantId != null
          ? PresetSelection.resolved(variantId)
          : const PresetSelection.awaiting(),
      evidence: const [],
      pipelineVersion: legacy,
      modelVersions: const {},
      validated: false,
    ),
    pairing: PairingState.single,
    provenance: Provenance(
      sourceImageId: asset.id,
      detectionIds: [item.id],
      processedAssetVersion: legacy,
      pipelineVersion: legacy,
      modelVersions: const {},
      presetVariantId: variantId,
      overrideFields: const [],
      layoutItemIds: [item.id],
      importedFrom: LegacyImport(
        schema: sourceSchema,
        field: 'recognitionConfidence',
        migrationVersion: '${Project.schemaVersion}',
      ),
    ),
    overrides: const [],
  );
}

PresetSnapshot _snapshotFor(DocumentItem item, DocumentSizeCatalog catalog) {
  final variantId = catalog.natural(item.documentKind) != null
      ? builtinVariantId(item.documentKind)
      : null;
  return PresetSnapshot(
    variantId: variantId,
    widthMm: item.width,
    heightMm: item.height,
    status: presetStatusFor(item.documentKind),
  );
}
