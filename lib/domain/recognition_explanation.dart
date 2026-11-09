/// Human-readable, evidence-derived reasons why an import was not added
/// automatically.
///
/// The app deliberately does not guess a document type from its shape, its
/// filename or an uncalibrated model score. When automatic addition fails the
/// user deserves the ACTUAL reason, not a generic "failed" sentence. Every
/// line below is derived from recorded evidence or its explicit absence; no
/// confidence is invented and no text is presented as an accuracy claim.
library;

import 'acceptance_policy.dart';
import 'recognition.dart';

String _percent(double value) =>
    '${(value.clamp(0.0, 1.0) * 100).toStringAsFixed(1)}٪';

/// Ordered Arabic explanations for [record], newest concern first.
///
/// [hasUsableSuggestion] is derived by the caller from the saved, geometrically
/// validated 4-corner proposal; it changes the recovery instruction rather
/// than the diagnosis.
List<String> recognitionFailureReasons(
  DocumentRecord? record, {
  required bool hasUsableSuggestion,
}) {
  if (record == null) {
    return [
      'لم تُجرَ عملية تعرّف تلقائي على هذه الصورة؛ اختر النوع والوجه صراحةً.',
      if (hasUsableSuggestion)
        'توجد حدود مقترحة صالحة يمكن اعتمادها مباشرة.'
      else
        'لا توجد حدود مقترحة؛ حدّد الزوايا الأربع من «الصورة ← القص والحدود».',
    ];
  }

  final recognition = record.recognition;
  final scores = recognition?.confidences;
  final reasons = <String>[];

  final classification = scores?.classification?.value;
  if (classification == null) {
    reasons.add(
      'لم يُقرأ نص كافٍ لتحديد النوع؛ التطبيق لا يخمّن النوع من الشكل أو '
      'المقاس أو اسم الملف.',
    );
  } else if (!meetsAcceptanceThreshold(
    classification,
    classificationAcceptanceThreshold,
  )) {
    reasons.add(
      'أدلة النص على النوع ضعيفة (${_percent(classification)})، حد التصنيف ${(classificationAcceptanceThreshold * 100).round()}٪؛ '
      'يحتاج القرار إلى اختيارك الصريح.',
    );
  }
  if (recognition?.status == RecognitionStatus.uncertain) {
    reasons.add('تعارضت أدلة التصنيف؛ لم يُعتمد نوع تلقائياً.');
  }

  final measuredReasons = record.sides
      .expand((side) => side.detection?.boundaryDiagnostics ?? const <String>[])
      .toSet();
  reasons.addAll(measuredReasons);

  final boundary = record.sides
      .where((side) => side.detection != null)
      .map((side) => side.detection!.detectionConfidence?.value)
      .whereType<double>()
      .firstOrNull;
  if (measuredReasons.isNotEmpty) {
    // The recorded decision is authoritative; never reconstruct it from D alone.
  } else if (boundary == null) {
    reasons.add(
      'درجة كشف الحدود غير متاحة؛ لا يُعتمد قصّ تلقائي دون دليل موثوق.',
    );
  } else if (!meetsAutomaticAcceptanceThreshold(boundary)) {
    reasons.add(
      'درجة كشف الحدود ${_percent(boundary)} أقل من حد القبول '
      '${(automaticAcceptanceThreshold * 100).round()}٪؛ حُفظت الزوايا '
      'المقترحة للمراجعة بدل القصّ التلقائي. الدرجة ليست ضماناً للدقة.',
    );
  }

  reasons.add(
    hasUsableSuggestion
        ? 'توجد زوايا قابلة للمراجعة اليدوية، وليست إذناً تلقائياً بالقص: يمكنك اعتمادها صراحةً أو '
              'ضبطها يدوياً قبل الحفظ.'
        : 'لم تتوفر حدود مقترحة صالحة؛ اضبط الزوايا الأربع يدوياً. '
              'الصورة الأصلية محفوظة كما هي.',
  );
  return List.unmodifiable(reasons);
}
