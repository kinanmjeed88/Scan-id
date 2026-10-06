import 'geometry.dart';
import 'image_adjustments.dart';
import 'validation.dart';
import 'image_limits.dart';

enum PaperOrientation { portrait, landscape }

enum ExportFormat { pdf, png, jpg }

enum LayoutOrder { input, area }

T readEnum<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw const ValidationException('خيار غير معروف في بيانات المشروع.');
}

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
  Map<String, Object?> toJson() => {
    'horizontalGap': horizontalGap,
    'verticalGap': verticalGap,
    'allowRotation': allowRotation,
    'order': order.name,
  };
  factory LayoutSettings.fromJson(Object? json) {
    final m = objectMap(json);
    return LayoutSettings(
      horizontalGap: finiteNumber(m['horizontalGap'], 'horizontalGap'),
      verticalGap: finiteNumber(m['verticalGap'], 'verticalGap'),
      allowRotation: boolean(m['allowRotation'], 'allowRotation'),
      order: readEnum(LayoutOrder.values, m['order']),
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
  }) {
    final page = pageIndex;
    require(page == null || (page >= 0 && page < 100), 'رقم الصفحة غير صالح.');
    validId(id);
    validId(assetId);
    require(
      [x, y, width, height, rotation].every((v) => v.isFinite),
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
  };
  factory DocumentItem.fromJson(Object? json) {
    final m = objectMap(json);
    return DocumentItem(
      id: text(m['id'], 'id'),
      pageIndex: !m.containsKey('pageIndex')
          ? 0
          : m['pageIndex'] == null
          ? null
          : integer(m['pageIndex'], 'pageIndex'),
      assetId: text(m['assetId'], 'assetId'),
      x: finiteNumber(m['x'], 'x'),
      y: finiteNumber(m['y'], 'y'),
      width: finiteNumber(m['width'], 'width'),
      height: finiteNumber(m['height'], 'height'),
      rotation: finiteNumber(m['rotation'], 'rotation'),
      zIndex: integer(m['zIndex'], 'zIndex'),
      locked: boolean(m['locked'], 'locked'),
      keepAspectRatio: boolean(m['keepAspectRatio'], 'keepAspectRatio'),
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
    List<ImageAsset> assets = const [],
    List<DocumentItem> items = const [],
  }) : paper = paper ?? PaperSettings(),
       layout = layout ?? LayoutSettings(),
       exportProfile = exportProfile ?? ExportProfile(),
       assets = List.unmodifiable(assets),
       items = List.unmodifiable(items) {
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
  }
  static const schemaVersion = 3;
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;
  final int pageCount;
  final PaperSettings paper;
  final LayoutSettings layout;
  final ExportProfile exportProfile;
  final List<ImageAsset> assets;
  final List<DocumentItem> items;

  Project copyWith({
    String? name,
    DateTime? updatedAt,
    int? revision,
    int? pageCount,
    PaperSettings? paper,
    LayoutSettings? layout,
    ExportProfile? exportProfile,
    List<ImageAsset>? assets,
    List<DocumentItem>? items,
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
    assets: assets ?? this.assets,
    items: items ?? this.items,
  );

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
    'assets': assets.map((a) => a.toJson()).toList(),
    'items': items.map((i) => i.toJson()).toList(),
  };
  factory Project.fromJson(Object? json) {
    final m = objectMap(json);
    require(
      [
        1,
        2,
        schemaVersion,
      ].contains(integer(m['schemaVersion'], 'schemaVersion')),
      'إصدار المشروع غير مدعوم؛ لم يتم تعديل البيانات.',
    );
    final created = DateTime.tryParse(text(m['createdAt'], 'createdAt'));
    final updated = DateTime.tryParse(text(m['updatedAt'], 'updatedAt'));
    require(created != null && updated != null, 'تواريخ المشروع غير صالحة.');
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
      assets: objectList(m['assets']).map(ImageAsset.fromJson).toList(),
      items: objectList(m['items']).map(DocumentItem.fromJson).toList(),
    );
  }
}
