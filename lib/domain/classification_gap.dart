/// Explains WHY a classification ended as `unknown`, in concise Arabic, from
/// the recognition snapshot alone (status, confidence components and
/// derived evidence). Pure function of persisted, privacy-safe values: it
/// never reads or reports recognized text.
///
/// The classifier is conservative by policy — without strong, independent
/// anchors the kind stays `unknown` — but silence is not an explanation. This
/// message is what the intake warnings and the review queue show instead of
/// a bare "لم يُتعرّف على النوع": absence of readable text, text read but
/// carrying no distinctive anchor, or anchors that did not clear the
/// classification floor are three different situations with three different
/// remedies (fix the photo, pick the kind by hand, re-run recognition).
library;

import 'document_kind.dart';
import 'recognition.dart';

/// A concise, user-facing cause for an `unknown` outcome, or null when the
/// kind is not `unknown`. Never claims a probability that was not measured;
/// every number shown here comes from the snapshot itself.
String? classificationUnknownReason({
  required DocumentKind kind,
  required RecognitionStatus status,
  required ConfidenceSet confidences,
  required List<RecognitionEvidence> evidence,
}) {
  if (kind != DocumentKind.unknown) return null;

  // The classifier records one `ocr-keyword` evidence entry per kind that
  // received at least one anchor vote, with reason
  // '<kind-name>:anchor-groups=<n>'. Recovering the voted kinds from the
  // persisted evidence keeps this explanation honest: no votes means
  // no votes, and there is nothing to name.
  final voted = <DocumentKind>{};
  for (final item in evidence) {
    if (item.kind != 'ocr-keyword') continue;
    final reason = item.reason;
    if (reason == null) continue;
    final name = reason.split(':').first;
    for (final candidate in DocumentKind.values) {
      if (candidate != DocumentKind.unknown && candidate.name == name) {
        voted.add(candidate);
      }
    }
  }

  final ocr = confidences.ocr?.value;
  final readable = ocr != null;
  if (voted.length > 1) {
    final names = voted.map((candidate) => candidate.label).join('، ');
    return 'وُجدت إشارات لأكثر من نوع ($names)، '
        'ولم تحسم دون حد التصنيف';
  }
  if (voted.length == 1) {
    return 'إشارات النوع (${voted.first.label}) موجودة '
        'لكنها دون حد التصنيف المطلوب';
  }
  if (!readable) {
    return 'لم تُقرأ أسطر نصية يمكن الاعتماد عليها '
        '(محرك القراءة غير متاح، أو تجاوز المهلة، أو تعذرت القراءة، '
        'أو النص غير واضح في الصورة)';
  }
  return 'النص مقروء (ثقة ${(ocr * 100).round()}٪) لكنه لا يحمل '
      'عنواناً مميزاً لنوع معروف مع مرساة مؤكدة على سطر آخر';
}
