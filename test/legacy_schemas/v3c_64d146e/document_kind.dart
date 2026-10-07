import 'dart:math' as math;

/// A human-confirmable category for a scanned document. Suggestions made from
/// a filename or silhouette are deliberately kept separate from the source
/// image; this app has no OCR or remote recognition service.
enum DocumentKind { unknown, unifiedNationalId, residenceCard, passport, other }

class PhysicalSizeMm {
  const PhysicalSizeMm(this.width, this.height);

  final double width;
  final double height;
}

extension DocumentKindDetails on DocumentKind {
  String get label => switch (this) {
    DocumentKind.unknown => 'غير معروف',
    DocumentKind.unifiedNationalId => 'البطاقة الوطنية الموحدة',
    DocumentKind.residenceCard => 'بطاقة السكن',
    DocumentKind.passport => 'جواز السفر',
    DocumentKind.other => 'مستمسك آخر',
  };

  /// Order requested by the common Iraqi-paper workflow.
  int get order => switch (this) {
    DocumentKind.unifiedNationalId => 0,
    DocumentKind.residenceCard => 1,
    DocumentKind.passport => 2,
    DocumentKind.unknown => 3,
    DocumentKind.other => 4,
  };

  /// Published outer-size references, not measurements verified for every
  /// edition or for the particular item in a photo. The Iraqi ordinary identity
  /// card record IRQ-BO-01001 lists 86 × 54 mm; it does not establish that every
  /// unified-national-ID edition matches it. The ordinary passport record
  /// IRQ-AO-03001 is a 2009 specimen listing 88 × 125 mm. These values are
  /// suggestions only and must be checked against the user's actual item.
  /// No single verified outer size is asserted for the Iraqi residence card.
  PhysicalSizeMm? publishedReferenceSize({
    required bool landscape,
  }) => switch (this) {
    DocumentKind.unifiedNationalId =>
      landscape ? const PhysicalSizeMm(86, 54) : const PhysicalSizeMm(54, 86),
    DocumentKind.passport =>
      landscape ? const PhysicalSizeMm(125, 88) : const PhysicalSizeMm(88, 125),
    DocumentKind.unknown ||
    DocumentKind.residenceCard ||
    DocumentKind.other => null,
  };

  bool get hasPublishedSizeReference =>
      this == DocumentKind.unifiedNationalId || this == DocumentKind.passport;

  String get measurementHint => switch (this) {
    DocumentKind.unifiedNationalId =>
      'مرجع PRADO IRQ-BO-01001 يورد 86 × 54 مم لبطاقة هوية عراقية عادية؛ لا يثبت أن كل إصدارات البطاقة الوطنية الموحدة مطابقة. تحقق من نسختك.',
    DocumentKind.passport =>
      'مرجع PRADO IRQ-AO-03001 لعينة جواز عادي إصدار 2009 يورد 88 × 125 مم؛ تحقق من إصدارك قبل اعتماد القياس.',
    DocumentKind.residenceCard =>
      'لم أجد معياراً رسمياً موحداً منشوراً لبطاقة السكن؛ قِس النسخة الأصلية بالمسطرة.',
    DocumentKind.unknown || DocumentKind.other =>
      'أدخل قياس النسخة الأصلية بالمسطرة؛ لا يمكن استنتاج المقاس الحقيقي من الصورة.',
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

/// Offline, intentionally conservative document-kind suggestion.
///
/// The filename is considered first when it contains an explicit Arabic or
/// English label. Otherwise only the cropped aspect ratio is used. This is a
/// useful sorting hint, not machine-learning/OCR identification; users should
/// confirm the type and especially the physical size before printing.
DocumentTypeSuggestion suggestDocumentType({
  required String name,
  required int width,
  required int height,
}) {
  final normalized = _normalizeName(name);
  if (_containsAny(normalized, const [
    'بطاقةالسكن',
    'السكن',
    'سكن',
    'residence',
    'housing',
  ])) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.residenceCard,
      confidence: .98,
      reason: 'اسم الملف يشير إلى بطاقة السكن',
    );
  }
  if (_containsAny(normalized, const ['جواز', 'passport'])) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.passport,
      confidence: .98,
      reason: 'اسم الملف يشير إلى جواز السفر',
    );
  }
  if (_containsAny(normalized, const [
    'البطاقةالوطنية',
    'بطاقةوطنية',
    'البطاقةالموحدة',
    'بطاقةموحدة',
    'الوطنيةالموحدة',
    'unifiednational',
    'nationalid',
  ])) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.unifiedNationalId,
      confidence: .98,
      reason: 'اسم الملف يشير إلى البطاقة الوطنية الموحدة',
    );
  }

  if (width <= 0 || height <= 0) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.unknown,
      confidence: 0,
      reason: 'أبعاد الصورة غير صالحة للتصنيف',
    );
  }
  final ratio = math.max(width, height) / math.min(width, height);
  final idRatio = 86 / 54;
  if ((ratio - idRatio).abs() <= .055) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.unifiedNationalId,
      confidence: .62,
      reason: 'نسبة الصورة قريبة من نسبة بطاقة ID-1؛ يلزم تأكيد النوع',
    );
  }
  final passportRatio = 125 / 88;
  if ((ratio - passportRatio).abs() <= .045) {
    return const DocumentTypeSuggestion(
      kind: DocumentKind.passport,
      confidence: .55,
      reason: 'نسبة الصورة قريبة من نسبة غلاف الجواز؛ يلزم تأكيد النوع',
    );
  }
  return const DocumentTypeSuggestion(
    kind: DocumentKind.unknown,
    confidence: 0,
    reason: 'لم تتوفر علامة محلية كافية لتحديد النوع',
  );
}

String _normalizeName(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll(RegExp(r'[\s_\-.]+'), '');

bool _containsAny(String value, List<String> tokens) =>
    tokens.map(_normalizeName).any(value.contains);

/// Conservative physical fallback used only to place unknown/variable-size
/// documents on the first A4 preview. It is explicitly unverified and must be
/// measured by the user; it is never described as an official size.
PhysicalSizeMm provisionalSize({required int width, required int height}) {
  final aspect = width / height;
  const longEdge = 80.0;
  final rawWidth = aspect >= 1 ? longEdge : longEdge * aspect;
  final rawHeight = aspect >= 1 ? longEdge / aspect : longEdge;
  final scale = math.min(1.0, 150 / math.max(rawWidth, rawHeight));
  return PhysicalSizeMm(rawWidth * scale, rawHeight * scale);
}
