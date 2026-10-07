import 'dart:math' as math;

import 'validation.dart';

/// Category of a scanned Iraqi document. The category decides the printed
/// physical size (through [DocumentSizeCatalog]) and the order on the sheet.
///
/// Recognition is offline: an explicit filename label first, then the shape of
/// the detected document boundary. The user can always change the category
/// from the ribbon; the change applies the catalog size immediately.
enum DocumentKind {
  unknown,
  unifiedNationalId,
  residenceCard,
  passport,
  rationCard,
  other,
}

/// A physical width × height in millimetres.
class PhysicalSizeMm {
  const PhysicalSizeMm(this.width, this.height);

  final double width;
  final double height;

  bool get isLandscape => width >= height;

  /// Long edge divided by short edge, independent of orientation.
  double get aspect => math.max(width, height) / math.min(width, height);

  PhysicalSizeMm get rotated => PhysicalSizeMm(height, width);

  /// This size turned so its orientation matches [landscape].
  PhysicalSizeMm oriented({required bool landscape}) =>
      isLandscape == landscape ? this : rotated;

  bool sameAs(PhysicalSizeMm other) =>
      (width - other.width).abs() < 1e-6 &&
      (height - other.height).abs() < 1e-6;

  Map<String, Object?> toJson() => {'width': width, 'height': height};

  factory PhysicalSizeMm.fromJson(Object? json) {
    final map = objectMap(json);
    return validDocumentSize(
      PhysicalSizeMm(
        finiteNumber(map['width'], 'width'),
        finiteNumber(map['height'], 'height'),
      ),
    );
  }

  @override
  String toString() => '${_mm(width)} × ${_mm(height)} مم';
}

String _mm(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');

/// Smallest and largest editable document edge, in millimetres.
const minDocumentEdgeMm = 10.0;
const maxDocumentEdgeMm = 400.0;

PhysicalSizeMm validDocumentSize(PhysicalSizeMm size) {
  require(
    size.width.isFinite &&
        size.height.isFinite &&
        size.width >= minDocumentEdgeMm &&
        size.height >= minDocumentEdgeMm &&
        size.width <= maxDocumentEdgeMm &&
        size.height <= maxDocumentEdgeMm,
    'مقاس المستمسك يجب أن يكون بين ${minDocumentEdgeMm.toInt()} و${maxDocumentEdgeMm.toInt()} مم.',
  );
  return size;
}

/// Printed sizes per document category.
///
/// The unified national card (ISO/IEC 7810 ID-1) and the passport data page
/// (ICAO Doc 9303 TD3) have official, fixed dimensions. No official outer size
/// is published for the residence card or the paper ration card, so their
/// sizes are editable defaults stored with each project.
class DocumentSizeCatalog {
  const DocumentSizeCatalog({
    this.residenceCard = defaultResidenceCard,
    this.rationCard = defaultRationCard,
  });

  /// ISO/IEC 7810 ID-1.
  static const unifiedNationalId = PhysicalSizeMm(85.6, 53.98);

  /// ICAO Doc 9303 TD3 passport data page.
  static const passport = PhysicalSizeMm(125, 88);

  /// Editable default, not an official dimension.
  static const defaultResidenceCard = PhysicalSizeMm(92.4, 62.8);

  /// Editable default (portrait paper card), not an official dimension.
  static const defaultRationCard = PhysicalSizeMm(52, 287);

  final PhysicalSizeMm residenceCard;
  final PhysicalSizeMm rationCard;

  /// Size in the document's natural orientation, or null when the category
  /// has no defined size.
  PhysicalSizeMm? natural(DocumentKind kind) => switch (kind) {
    DocumentKind.unifiedNationalId => unifiedNationalId,
    DocumentKind.residenceCard => residenceCard,
    DocumentKind.passport => passport,
    DocumentKind.rationCard => rationCard,
    DocumentKind.unknown || DocumentKind.other => null,
  };

  /// Size turned to the orientation of the cropped image.
  PhysicalSizeMm? sizeFor(DocumentKind kind, {required bool landscape}) =>
      natural(kind)?.oriented(landscape: landscape);

  DocumentSizeCatalog copyWith({
    PhysicalSizeMm? residenceCard,
    PhysicalSizeMm? rationCard,
  }) => DocumentSizeCatalog(
    residenceCard: validDocumentSize(residenceCard ?? this.residenceCard),
    rationCard: validDocumentSize(rationCard ?? this.rationCard),
  );

  Map<String, Object?> toJson() => {
    'residenceCard': residenceCard.toJson(),
    'rationCard': rationCard.toJson(),
  };

  /// Missing entries fall back to the defaults so older projects open.
  factory DocumentSizeCatalog.fromJson(Object? json) {
    if (json == null) {
      return const DocumentSizeCatalog();
    }
    final map = objectMap(json);
    return DocumentSizeCatalog(
      residenceCard: map['residenceCard'] == null
          ? defaultResidenceCard
          : PhysicalSizeMm.fromJson(map['residenceCard']),
      rationCard: map['rationCard'] == null
          ? defaultRationCard
          : PhysicalSizeMm.fromJson(map['rationCard']),
    );
  }
}

extension DocumentKindDetails on DocumentKind {
  String get label => switch (this) {
    DocumentKind.unknown => 'غير محدد',
    DocumentKind.unifiedNationalId => 'البطاقة الوطنية الموحدة',
    DocumentKind.residenceCard => 'بطاقة السكن',
    DocumentKind.passport => 'جواز السفر',
    DocumentKind.rationCard => 'البطاقة التموينية',
    DocumentKind.other => 'مستمسك آخر',
  };

  /// Sheet order: unified card, residence card, passport, ration card, then
  /// everything else.
  int get order => switch (this) {
    DocumentKind.unifiedNationalId => 0,
    DocumentKind.residenceCard => 1,
    DocumentKind.passport => 2,
    DocumentKind.rationCard => 3,
    DocumentKind.unknown => 4,
    DocumentKind.other => 5,
  };

  /// Only standardised dimensions are described as official.
  bool get hasOfficialSize =>
      this == DocumentKind.unifiedNationalId || this == DocumentKind.passport;

  /// Whether the user may edit this category's catalog size.
  bool get hasEditableSize =>
      this == DocumentKind.residenceCard || this == DocumentKind.rationCard;

  String sizeNote(DocumentSizeCatalog catalog) => switch (this) {
    DocumentKind.unifiedNationalId =>
      'مقاس رسمي ثابت (ISO/IEC 7810 ID-1): ${catalog.natural(this)}',
    DocumentKind.passport =>
      'مقاس رسمي ثابت لصفحة بيانات الجواز (ICAO 9303 TD3): ${catalog.natural(this)}',
    DocumentKind.residenceCard || DocumentKind.rationCard =>
      'مقاس افتراضي قابل للتعديل: ${catalog.natural(this)}',
    DocumentKind.unknown =>
      'اختر نوع المستمسك ليُطبَّق مقاسه ويُرتَّب على الورقة.',
    DocumentKind.other => 'مقاس يدوي؛ عدّل العرض والارتفاع من الشريط.',
  };
}

class DocumentTypeSuggestion {
  const DocumentTypeSuggestion({
    required this.kind,
    required this.confidence,
    required this.reason,
  });

  final DocumentKind kind;
  final double confidence;
  final String reason;
}

/// Relative aspect tolerance for recognising a category from the boundary
/// shape. Perspective-corrected crops are typically within 2 %; the nearest
/// candidates (residence 1.471 and passport 1.420) are 3.6 % apart.
const shapeTolerance = .04;

/// Frame shapes of common cameras (4:3, 3:2, 16:9). An uncropped photo with
/// one of these shapes says nothing about the document inside it.
const _cameraFrames = [4 / 3, 3 / 2, 16 / 9];

/// Offline document category recognition.
///
/// An explicit Arabic or English filename label wins. Otherwise the aspect
/// ratio of the document boundary is matched against the catalog sizes.
/// [fullFrame] marks an image in which no boundary was detected: it may be an
/// already-cut scan (its shape is the document's) or a whole camera frame, so
/// camera frame shapes are rejected instead of guessed.
DocumentTypeSuggestion suggestDocumentType({
  required String name,
  required int width,
  required int height,
  DocumentSizeCatalog catalog = const DocumentSizeCatalog(),
  bool fullFrame = false,
}) {
  final normalized = _normalizeName(name);
  for (final entry in _nameTokens.entries) {
    if (_containsAny(normalized, entry.value)) {
      return DocumentTypeSuggestion(
        kind: entry.key,
        confidence: .98,
        reason: 'اسم الملف يشير إلى ${entry.key.label}',
      );
    }
  }
  if (width <= 0 || height <= 0) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.unknown,
      confidence: 0,
      reason: 'أبعاد الصورة غير صالحة للتصنيف',
    );
  }
  final ratio = math.max(width, height) / math.min(width, height);
  if (fullFrame &&
      _cameraFrames.any((frame) => (ratio / frame - 1).abs() < .01)) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.unknown,
      confidence: 0,
      reason: 'لم تُكتشف حدود المستمسك؛ اختر النوع أو صحّح القص يدوياً',
    );
  }
  DocumentKind? best;
  var bestError = double.infinity;
  var secondError = double.infinity;
  for (final kind in const [
    DocumentKind.unifiedNationalId,
    DocumentKind.residenceCard,
    DocumentKind.passport,
    DocumentKind.rationCard,
  ]) {
    final error = (ratio / catalog.natural(kind)!.aspect - 1).abs();
    if (error < bestError) {
      secondError = bestError;
      bestError = error;
      best = kind;
    } else if (error < secondError) {
      secondError = error;
    }
  }
  if (best == null || bestError > shapeTolerance) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.unknown,
      confidence: 0,
      reason: 'شكل الحدود لا يطابق أي مقاس معروف',
    );
  }
  // Confidence falls with distance from the reference shape and with
  // ambiguity against the runner-up category.
  final closeness = 1 - bestError / shapeTolerance;
  final separation = secondError.isFinite
      ? ((secondError - bestError) / shapeTolerance).clamp(0.0, 1.0)
      : 1.0;
  return DocumentTypeSuggestion(
    kind: best,
    confidence: (.5 + .45 * closeness * separation).clamp(.5, .95).toDouble(),
    reason: 'شكل الحدود يطابق مقاس ${best.label}',
  );
}

const _nameTokens = {
  DocumentKind.rationCard: ['تموين', 'تموينيه', 'التموينيه', 'ration'],
  DocumentKind.residenceCard: [
    'بطاقةالسكن',
    'السكن',
    'سكن',
    'residence',
    'housing',
  ],
  DocumentKind.passport: ['جواز', 'passport'],
  DocumentKind.unifiedNationalId: [
    'البطاقةالوطنية',
    'بطاقةوطنية',
    'البطاقةالموحدة',
    'بطاقةموحدة',
    'الوطنيةالموحدة',
    'الهويه',
    'unifiednational',
    'nationalid',
  ],
};

String _normalizeName(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll(RegExp(r'[\s_\-.]+'), '');

bool _containsAny(String value, List<String> tokens) =>
    tokens.map(_normalizeName).any(value.contains);

/// Starting size for a document whose category is not known yet. It keeps the
/// image's proportions and is never described as a real measurement; such
/// items stay off the sheet until the user picks a category or a size.
PhysicalSizeMm provisionalSize({required int width, required int height}) {
  final aspect = width / height;
  const longEdge = 80.0;
  final rawWidth = aspect >= 1 ? longEdge : longEdge * aspect;
  final rawHeight = aspect >= 1 ? longEdge / aspect : longEdge;
  final scale = math.min(1.0, 150 / math.max(rawWidth, rawHeight));
  return PhysicalSizeMm(rawWidth * scale, rawHeight * scale);
}
