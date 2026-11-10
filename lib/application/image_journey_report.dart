/// Builds the human-readable journey of every image in one intake run.
///
/// The report is derived AFTER the run from the committed project, which is the
/// only source that cannot lie: an asset that was never saved has no copy step,
/// a record that was never written has no boundary decision, and an item that
/// never reached a page has no placement. Nothing here re-runs the pipeline to
/// fill gaps, and nothing here reads recognized text — the classifier's score
/// and the recorded boundary reasons are enough to explain each decision.
library;

import '../domain/arrangement.dart';
import '../domain/document_kind.dart';
import '../domain/image_journey.dart';
import '../domain/ocr_evidence.dart';
import '../domain/project.dart';
import '../domain/recognition.dart';

/// One picked source as the copy phase saw it.
class ImportedImageFact {
  const ImportedImageFact({
    required this.name,
    this.assetId,
    this.failureMessage,
    this.copyDurationMs,
  });

  /// The name of the picked file, as the person sees it in the gallery.
  final String name;

  /// The saved asset, or null when the source was never copied.
  final String? assetId;

  /// Why the copy failed; null when it succeeded. Always a bounded Arabic
  /// sentence from the import layer, never an exception's own message.
  final String? failureMessage;

  /// Time the copy phase measured for THIS source, or null when the caller did
  /// not measure it. A missing duration is never filled in with an estimate.
  final int? copyDurationMs;
}

/// Composes one [ImageJourney] per picked image, in pick order.
///
/// [project] must be the project as it was committed at the end of the run.
/// [savedRevision] is the revision that run wrote, or null when it stopped
/// before any save — the difference between «حُفظ» and «لم يُحفظ» is reported,
/// not assumed.
List<ImageJourney> buildImageJourneys({
  required String batchId,
  required Project project,
  required List<ImportedImageFact> images,
  required DateTime startedAt,
  int? savedRevision,
}) {
  final journeys = <ImageJourney>[];
  for (var index = 0; index < images.length; index++) {
    final fact = images[index];
    final steps = _stepsFor(
      fact,
      project: project,
      savedRevision: savedRevision,
      isLast: index == images.length - 1,
    );
    journeys.add(
      ImageJourney(
        id: _journeyId(batchId, fact, index),
        batchId: batchId,
        projectId: project.id,
        projectName: project.name,
        imageName: fact.name,
        startedAt: startedAt,
        sheetRevision: savedRevision,
        steps: steps,
      ),
    );
  }
  return List.unmodifiable(journeys);
}

/// Deterministic, so writing the same run twice cannot duplicate an entry.
String _journeyId(String batchId, ImportedImageFact fact, int index) =>
    '$batchId-${fact.assetId ?? 'picked$index'}';

List<JourneyStep> _stepsFor(
  ImportedImageFact fact, {
  required Project project,
  required int? savedRevision,
  required bool isLast,
}) {
  final steps = <JourneyStep>[
    JourneyStep(
      stage: JourneyStage.selection,
      outcome: JourneyOutcome.passed,
      detail: 'اختيرت من جهازك لتُضاف إلى مشروع «${project.name}».',
    ),
  ];
  final assetId = fact.assetId;
  ImageAsset? asset;
  if (assetId != null) {
    for (final entry in project.assets) {
      if (entry.id == assetId) {
        asset = entry;
        break;
      }
    }
  }

  steps.add(_copyStep(fact, asset));
  if (asset == null) {
    steps.add(
      _notReached(JourneyStage.detection, 'لم تصل الصورة إلى المشروع.'),
    );
    steps.add(_notReached(JourneyStage.crop, 'لا صورة محفوظة لتُقصّ.'));
    steps.add(_notReached(JourneyStage.recognition, 'لا صورة محفوظة لتُقرأ.'));
    steps.add(_notReached(JourneyStage.sizing, 'لا مستند بعد.'));
    steps.add(
      JourneyStep(
        stage: JourneyStage.placement,
        outcome: JourneyOutcome.blocked,
        detail: 'لم تدخل الورقة لأن الصورة لم تُستورد.',
      ),
    );
    steps.add(_saveStep(savedRevision, isLast: isLast));
    return steps;
  }

  final records = [
    for (final record in project.documents)
      if (record.sourceImageId == asset.id) record,
  ];
  final derivedIds = {
    asset.id,
    for (final other in project.assets)
      if (other.derivedFrom == asset.id) other.id,
  };
  final items = [
    for (final item in project.items)
      if (derivedIds.contains(item.assetId)) item,
  ];

  steps.add(_detectionStep(records, items));
  steps.add(_cropStep(records));
  steps.add(_recognitionStep(records));
  steps.add(_sizingStep(items));
  steps.add(_placementStep(project, items));
  steps.add(_saveStep(savedRevision, isLast: isLast));
  return steps;
}

JourneyStep _copyStep(ImportedImageFact fact, ImageAsset? asset) {
  final failure = fact.failureMessage;
  if (asset == null || failure != null) {
    return JourneyStep(
      stage: JourneyStage.copy,
      outcome: JourneyOutcome.blocked,
      detail: _clip(
        failure ?? 'لم تُحفظ نسخة من الصورة داخل المشروع، فلا يوجد ما يُعالج.',
      ),
    );
  }
  final scaled = asset.hasScaledLargeSource
      ? '؛ صُغّرت نسخة العمل لتبقى ضمن حد الذاكرة، والأصل محفوظ كما هو.'
      : '.';
  return JourneyStep(
    stage: JourneyStage.copy,
    outcome: JourneyOutcome.passed,
    detail:
        'نُسخت إلى مساحة التطبيق '
        '(${asset.width}×${asset.height} بكسل)$scaled',
    durationMs: fact.copyDurationMs?.clamp(0, JourneyStep.maxDurationMs),
  );
}

JourneyStep _detectionStep(
  List<DocumentRecord> records,
  List<DocumentItem> items,
) {
  if (records.isEmpty) {
    final detail = items.isEmpty
        ? 'لم يُسجَّل قرار حدود؛ لم تكتمل معالجة هذه الصورة تلقائياً.'
        : 'لم يُعثر على حدود موثوقة تلقائياً؛ بقيت الصورة كاملة لتقصّها '
              'يدوياً من «الصورة ← القص والحدود».';
    return JourneyStep(
      stage: JourneyStage.detection,
      outcome: JourneyOutcome.blocked,
      detail: detail,
    );
  }
  final detections = [
    for (final record in records)
      for (final side in record.sides)
        if (side.detection != null) side.detection!,
  ];
  if (detections.isEmpty) {
    return JourneyStep(
      stage: JourneyStage.detection,
      outcome: JourneyOutcome.review,
      detail:
          'لم تُسجَّل نتيجة كشف لهذه الصورة؛ لا يُعتمد قصّ تلقائي دون دليل.',
    );
  }
  final diagnostics = <String>{
    for (final detection in detections) ...detection.boundaryDiagnostics,
  };
  if (diagnostics.isNotEmpty) {
    final more = diagnostics.length > 1
        ? ' (و${diagnostics.length - 1} ملاحظة أخرى في بطاقة المراجعة)'
        : '';
    return JourneyStep(
      stage: JourneyStage.detection,
      outcome: JourneyOutcome.review,
      detail: _clip('${diagnostics.first}$more'),
    );
  }
  double? confidence;
  for (final detection in detections) {
    confidence = detection.detectionConfidence?.value;
    if (confidence != null) break;
  }
  if (confidence == null) {
    return JourneyStep(
      stage: JourneyStage.detection,
      outcome: JourneyOutcome.review,
      detail: 'درجة كشف الحدود غير متاحة؛ لا يُعتمد قصّ تلقائي دون دليل موثوق.',
    );
  }
  final count = detections.length > 1
      ? ' (${detections.length} مستندات في الصورة الواحدة)'
      : '';
  return JourneyStep(
    stage: JourneyStage.detection,
    outcome: JourneyOutcome.passed,
    detail: _clip('اجتازت بوابة الحدود بدرجة ${_percent(confidence)}$count.'),
  );
}

JourneyStep _cropStep(List<DocumentRecord> records) {
  if (records.isEmpty) {
    return _notReached(JourneyStage.crop, 'لا حدود مقبولة لتُقصّ.');
  }
  // A processed asset that carries no crop geometry is the untouched source,
  // kept so the reviewer sees something — not evidence that a crop happened.
  final processed = [
    for (final record in records)
      for (final side in record.sides)
        if (side.processedAsset.corners != null) side.processedAsset,
  ];
  if (processed.isNotEmpty) {
    final first = processed.first;
    final size =
        '${first.outputWidth ?? first.width}×'
        '${first.outputHeight ?? first.height} بكسل';
    final count = processed.length > 1
        ? ' (${processed.length} نسخ معالجة)'
        : '';
    return JourneyStep(
      stage: JourneyStage.crop,
      outcome: JourneyOutcome.passed,
      detail: 'قُصّت الزوايا الأربع وأُنتجت نسخة معالجة $size$count.',
    );
  }
  final hasSuggestion = records.any(
    (record) =>
        record.sides.any((side) => side.detection?.suggestedPolygon != null),
  );
  return JourneyStep(
    stage: JourneyStage.crop,
    outcome: JourneyOutcome.review,
    detail: hasSuggestion
        ? 'لم يُقصّ تلقائياً؛ الزوايا المقترحة محفوظة لتعتمدها أو تعدّلها.'
        : 'لم يُقصّ تلقائياً ولا توجد زوايا مقترحة؛ حدّد الزوايا الأربع يدوياً.',
  );
}

JourneyStep _recognitionStep(List<DocumentRecord> records) {
  final recognitions = [
    for (final record in records)
      if (record.recognition != null) record.recognition!,
  ];
  if (recognitions.isEmpty) {
    return _notReached(
      JourneyStage.recognition,
      'لم تُشغَّل قراءة النص لهذه الصورة؛ النوع يبقى باختيارك.',
    );
  }
  final recognition = recognitions.first;
  final ocr = recognition.confidences.ocr?.value;
  final classification = recognition.confidences.classification?.value;
  final kind = recognition.documentKind;
  if (ocr == null) {
    return JourneyStep(
      stage: JourneyStage.recognition,
      outcome: JourneyOutcome.review,
      detail:
          'لم يُقرأ نص من هذه الصورة (المحرك غير متاح أو لم يجد سطوراً)؛ '
          'النوع يحتاج اختيارك صراحةً.',
    );
  }
  if (classification == null) {
    return JourneyStep(
      stage: JourneyStage.recognition,
      outcome: JourneyOutcome.review,
      detail:
          'قُرئ النص (${_percent(ocr)}) لكن لم تكفِ الأدلة لتحديد النوع؛ '
          'اختر النوع صراحةً.',
    );
  }
  final kindLabel = kind.label;
  final score = _percent(classification);
  if (recognition.status == RecognitionStatus.uncertain) {
    final categories = _evidenceCategories(recognition.evidence);
    final suffix = categories.isEmpty ? '' : ' الأدلة المرصودة: $categories.';
    return JourneyStep(
      stage: JourneyStage.recognition,
      outcome: JourneyOutcome.review,
      detail: _clip(
        'قُرئ النص (${_percent(ocr)}) لكن أدلة النوع تعارضت '
        '($kindLabel، $score)؛ لم يُعتمد نوع تلقائياً.$suffix',
      ),
    );
  }
  if (kind == DocumentKind.unknown) {
    return JourneyStep(
      stage: JourneyStage.recognition,
      outcome: JourneyOutcome.review,
      detail:
          'قُرئ النص (${_percent(ocr)}) ولم يطابق أي نوع معروف '
          '($score)؛ اختر النوع يدوياً.',
    );
  }
  return JourneyStep(
    stage: JourneyStage.recognition,
    outcome: JourneyOutcome.passed,
    detail:
        'قُرئ النص (${_percent(ocr)}) وصُنّف النوع «$kindLabel» '
        'بدرجة $score.',
  );
}

JourneyStep _sizingStep(List<DocumentItem> items) {
  if (items.isEmpty) {
    return _notReached(JourneyStage.sizing, 'لا مستند بعد لتأكيد مقاسه.');
  }
  final item = items.first;
  final catalogSize = item.sizeConfirmed
      ? _catalogSizeOf(item.documentKind)
      : null;
  if (catalogSize != null) {
    return JourneyStep(
      stage: JourneyStage.sizing,
      outcome: JourneyOutcome.passed,
      detail:
          'المقاس من كتالوج النوع «${item.documentKind.label}»: '
          '${catalogSize.width.toStringAsFixed(1)} × '
          '${catalogSize.height.toStringAsFixed(1)} مم.',
    );
  }
  if (item.documentKind == DocumentKind.unknown) {
    return JourneyStep(
      stage: JourneyStage.sizing,
      outcome: JourneyOutcome.review,
      detail: 'النوع غير محدد، فلا مقاس مطبوع بعد؛ حدّده ليُحسب المقاس.',
    );
  }
  return JourneyStep(
    stage: JourneyStage.sizing,
    outcome: JourneyOutcome.review,
    detail:
        'المقاس الفعلي غير مؤكّد لهذا النوع؛ لن يُوضع تلقائياً حتى '
        'تحدّده أو تدخله بالمليمتر.',
  );
}

JourneyStep _placementStep(Project project, List<DocumentItem> items) {
  if (items.isEmpty) {
    return JourneyStep(
      stage: JourneyStage.placement,
      outcome: JourneyOutcome.blocked,
      detail: 'لم يُنشأ مستند من هذه الصورة، لذلك لم تدخل الورقة.',
    );
  }
  final placed = [
    for (final item in items)
      if (item.pageIndex != null) item,
  ];
  if (placed.isNotEmpty) {
    final pages = {for (final item in placed) item.pageIndex! + 1}.toList()
      ..sort();
    final pageText = pages.length == 1
        ? 'الصفحة ${pages.single}'
        : 'الصفحات ${pages.join('، ')}';
    final count = items.length > 1 ? ' (${items.length} عناصر)' : '';
    return JourneyStep(
      stage: JourneyStage.placement,
      outcome: JourneyOutcome.passed,
      detail: 'وُضع في $pageText داخل حدود الورقة$count.',
    );
  }
  final item = items.first;
  return JourneyStep(
    stage: JourneyStage.placement,
    outcome: JourneyOutcome.review,
    detail: _clip(unplacedDocumentMessage(project, item)),
  );
}

JourneyStep _saveStep(int? savedRevision, {required bool isLast}) {
  if (savedRevision != null) {
    return JourneyStep(
      stage: JourneyStage.save,
      outcome: JourneyOutcome.passed,
      detail: 'حُفظ المشروع بعد المعالجة (مراجعة $savedRevision).',
    );
  }
  return _notReached(
    JourneyStage.save,
    isLast
        ? 'لم يصل التشغيل إلى حفظ المشروع؛ لا تغيير محفوظ لهذه الصورة.'
        : 'لم يصل هذا التشغيل إلى حفظ المشروع.',
  );
}

JourneyStep _notReached(JourneyStage stage, String detail) =>
    JourneyStep(stage: stage, outcome: JourneyOutcome.skipped, detail: detail);

PhysicalSizeMm? _catalogSizeOf(DocumentKind kind) =>
    kind == DocumentKind.unknown || kind == DocumentKind.other
    ? null
    : const DocumentSizeCatalog().natural(kind);

/// Arabic evidence categories recorded by the classifier, without repetition
/// and in the order the classifier stored them. It reads only the fixed group
/// ids in each reason — never recognized text.
String _evidenceCategories(List<RecognitionEvidence> evidence) {
  final labels = <String>[];
  for (final item in evidence) {
    if (item.kind != 'ocr-keyword') continue;
    final reason = item.reason;
    if (reason == null) continue;
    // ':groups=' — the anchor count is written as 'anchor-groups=', so the
    // leading colon is what separates the group list from the count.
    final marker = reason.indexOf(':groups=');
    if (marker < 0) continue;
    for (final raw in reason.substring(marker + ':groups='.length).split(',')) {
      final id = raw.trim();
      if (id.isEmpty) continue;
      final label = evidenceGroupLabel(id);
      if (!labels.contains(label)) labels.add(label);
    }
  }
  return labels.join('، ');
}

String _percent(double value) =>
    '${(value.clamp(0.0, 1.0) * 100).toStringAsFixed(1)}٪';

/// Keeps a detail a sentence: recorded reasons can be long, and a report step
/// must stay readable and bounded on disk.
String _clip(String value) {
  final single = value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  const limit = JourneyStep.maxDetailLength;
  if (single.length <= limit) return single;
  return '${single.substring(0, limit - 1).trimRight()}…';
}
