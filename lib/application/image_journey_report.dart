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
import '../domain/boundary_decision.dart';
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
  steps.add(_cropStep(records, project.assets));
  steps.add(_recognitionStep(records));
  steps.add(_sizingStep(items, records));
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
  final traces = <String>{
    for (final detection in detections) ...detection.detectionTrace,
  };
  final diagnostics = <String>{
    for (final detection in detections) ...detection.boundaryDiagnostics,
  };
  if (traces.isNotEmpty || diagnostics.isNotEmpty) {
    final measured = _describeDetectionTrace(traces);
    final reasons = diagnostics.join(' · ');
    final detail = [
      if (measured.isNotEmpty) 'الكشف: $measured',
      if (reasons.isNotEmpty) reasons,
    ].join(' — ');
    final accepted = detections.any((detection) => detection.polygon != null);
    return JourneyStep(
      stage: JourneyStage.detection,
      outcome: accepted ? JourneyOutcome.passed : JourneyOutcome.review,
      detail: _clip(detail),
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
  final measured = _describeDetectionTrace(traces);
  return JourneyStep(
    stage: JourneyStage.detection,
    outcome: JourneyOutcome.passed,
    detail: _clip(
      'اجتازت بوابة الحدود بدرجة ${_percent(confidence)}$count.'
      '${measured.isEmpty ? '' : ' $measured.'}',
    ),
  );
}

/// Fixed, user-facing name of a detector. The raw model id stays in the record
/// for audits; a person reading the report needs the product name only.
String _detectorName(String modelId) {
  final id = modelId.toLowerCase();
  if (id.contains('docquad')) return 'DocQuadNet';
  if (id.contains('docaligner')) return 'DocAligner';
  if (id.contains('segment')) return 'مقسّم المناطق';
  return 'كاشف';
}

/// Arabic name of a measured geometry refusal.
String _quadRejectionLabel(String name) => switch (name) {
  'invalidSourceDimensions' => 'أبعاد مصدر غير صالحة',
  'nonFiniteCoordinates' => 'إحداثيات غير صالحة',
  'singularPerspective' => 'منظور غير قابل للتصحيح',
  'wrongPointCount' => 'عدد زوايا غير صحيح',
  'outOfBounds' => 'زوايا خارج الصورة',
  'notConvex' => 'شكل غير محدّب',
  'tooSmall' => 'حدود صغيرة جداً',
  'degenerateEdges' => 'أضلاع منكمشة',
  'implausibleAspect' => 'نسبة أبعاد غير معقولة',
  _ => 'رفض هندسي',
};

/// One Arabic line built from the measured detection codes: which model ran
/// and what it returned, how far its quadrilateral sat from the other one, and
/// the measured shape. Every value is a fixed id or a measured number — never
/// recognized text, a path or an error message.
String _describeDetectionTrace(Iterable<String> codes) {
  final parts = <String>[];
  for (final code in codes) {
    final trace = BoundaryDetectorTrace.decode(code);
    if (trace != null) {
      final name = _detectorName(trace.modelId);
      final score = trace.confidence == null
          ? ''
          : ' بدرجة ${_percent(trace.confidence!)}';
      if (trace.outcome == BoundaryDetectorOutcome.proposal) {
        parts.add('$name اقترح زوايا$score');
      } else if (trace.outcome == BoundaryDetectorOutcome.noQuad) {
        parts.add('$name لم يجد مستنداً');
      } else if (trace.outcome == BoundaryDetectorOutcome.geometryRejected) {
        parts.add('$name اقترح زوايا مرفوضة هندسياً$score');
      } else {
        final type = trace.errorType == null ? '' : ' (${trace.errorType})';
        parts.add('$name تعذّر تشغيله$type');
      }
      continue;
    }
    final index = code.indexOf('=');
    if (index <= 0) continue;
    final key = code.substring(0, index);
    final raw = code.substring(index + 1);
    final number = double.tryParse(raw);
    if (key == 'disagreement' && number != null) {
      parts.add('تباعد الزوايا بين الكاشفين ${_percent(number)}');
    } else if (key == 'aspect' && number != null) {
      parts.add('نسبة الحدود ${number.toStringAsFixed(2)}:1');
    } else if (key == 'area' && number != null) {
      parts.add('مساحة الحدود ${_percent(number)} من الصورة');
    } else if (key == 'geometry' && number != null) {
      parts.add('جودة الهندسة ${_percent(number)}');
    } else if (key == 'corroboration' &&
        raw == BoundaryCorroboration.classicalCatalogAspect.name) {
      parts.add('تأييد الكاشف الكلاسيكي بنسبة النوع');
    } else if (key == 'rejection') {
      parts.add(_quadRejectionLabel(raw));
    }
  }
  return parts.join(' · ');
}

JourneyStep _cropStep(List<DocumentRecord> records, List<ImageAsset> assets) {
  if (records.isEmpty) {
    return _notReached(JourneyStage.crop, 'لا حدود مقبولة لتُقصّ.');
  }
  // Four saved corners identify a perspective warp. A region extraction with
  // no corners is classified separately below, never mislabeled as a warp.
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
      detail: 'صُحّح المنظور بالزوايا الأربع وأُنتجت نسخة $size$count.',
    );
  }
  final extractedRegions = [
    for (final record in records)
      for (final side in record.sides)
        if (side.processedAsset.corners == null &&
            assets.any(
              (asset) =>
                  asset.workingPath == side.processedAsset.workingPath &&
                  asset.derivedFrom == record.sourceImageId,
            ))
          side.processedAsset,
  ];
  if (extractedRegions.isNotEmpty) {
    final first = extractedRegions.first;
    final size = '${first.width}×${first.height} بكسل';
    return JourneyStep(
      stage: JourneyStage.crop,
      outcome: JourneyOutcome.review,
      detail:
          'اقتُطعت المنطقة المقاسة دون تصحيح منظور ($size)؛ '
          'الزوايا الأربع ما زالت تحتاج مراجعة يدوية.',
    );
  }
  final hasSuggestion = records.any(
    (record) =>
        record.sides.any((side) => side.detection?.suggestedPolygon != null),
  );
  final measured = _describeDetectionTrace({
    for (final record in records)
      for (final side in record.sides) ...?side.detection?.detectionTrace,
  });
  final String detail;
  if (hasSuggestion) {
    detail =
        'لم يُقصّ تلقائياً؛ الزوايا المقترحة محفوظة لتعتمدها أو تعدّلها.'
        '${measured.isEmpty ? '' : ' القياس المقترح: $measured.'}';
  } else {
    detail =
        'لم يُقصّ تلقائياً ولا توجد زوايا مقترحة؛ '
        'حدّد الزوايا الأربع يدوياً.';
  }
  return JourneyStep(
    stage: JourneyStage.crop,
    outcome: JourneyOutcome.review,
    detail: _clip(detail),
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
    final signals = _votedKindLabels(recognition.evidence);
    final categories = _evidenceCategories(recognition.evidence);
    final suffix = categories.isEmpty ? '' : ' الأدلة المرصودة: $categories.';
    return JourneyStep(
      stage: JourneyStage.recognition,
      outcome: JourneyOutcome.review,
      detail: _clip(
        signals.isEmpty
            ? 'قُرئ النص (${_percent(ocr)}) ولم يطابق أي نوع معروف '
                  '($score)؛ اختر النوع يدوياً.'
            : 'قُرئ النص (${_percent(ocr)}) ووُجدت إشارات لـ«'
                  '${signals.join('»، «')}» لكنها دون حد القبول '
                  '($score)؛ اختر النوع يدوياً.$suffix',
      ),
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

JourneyStep _sizingStep(
  List<DocumentItem> items,
  List<DocumentRecord> records,
) {
  if (items.isEmpty) {
    return _notReached(JourneyStage.sizing, 'لا مستند بعد لتأكيد مقاسه.');
  }
  final item = items.first;
  final natural = _catalogSizeOf(item.documentKind);
  final sizeText = natural == null
      ? null
      : '${natural.width.toStringAsFixed(1)} × '
            '${natural.height.toStringAsFixed(1)} مم';
  final traces = {
    for (final record in records)
      for (final side in record.sides) ...?side.detection?.detectionTrace,
  };
  if (item.sizeConfirmed && natural != null) {
    final provenance = documentSizeRecordFor(item.documentKind).provenance;
    final basis = item.hasUserConfirmedSize
        ? 'تأكيد يدوي'
        : provenance == SizeProvenance.documented
        ? 'مقاس مطبوع موثّق'
        : 'مقاس تقديري قابل للتعديل';
    final shape = traces.contains('catalogShape=match')
        ? 'بعد تطابق شكل القص المقاس'
        : 'وفق المقاس المثبّت';
    return JourneyStep(
      stage: JourneyStage.sizing,
      outcome: JourneyOutcome.passed,
      detail:
          'ثُبِّت مقاس النوع «${item.documentKind.label}» ($basis، $shape) '
          'دون تمديد: $sizeText.',
    );
  }
  if (item.documentKind == DocumentKind.unknown) {
    return JourneyStep(
      stage: JourneyStage.sizing,
      outcome: JourneyOutcome.review,
      detail: 'النوع غير محدد، فلا مقاس مطبوع بعد؛ حدّده ليُحسب المقاس.',
    );
  }
  if (natural == null) {
    return JourneyStep(
      stage: JourneyStage.sizing,
      outcome: JourneyOutcome.review,
      detail:
          'لا مقاس منشور لنوع «${item.documentKind.label}»؛ '
          'أدخل القياس بالمليمتر وثبّته قبل الوضع على A4.',
    );
  }
  final provenance = documentSizeRecordFor(item.documentKind).provenance;
  if (provenance == SizeProvenance.estimated) {
    return JourneyStep(
      stage: JourneyStage.sizing,
      outcome: JourneyOutcome.review,
      detail:
          'مقاس «${item.documentKind.label}» تقديري قابل للتعديل ($sizeText)؛ '
          'المقاس المؤقت ${item.width.toStringAsFixed(1)} × '
          '${item.height.toStringAsFixed(1)} مم. أكّده يدوياً قبل الوضع على A4.',
    );
  }
  // A documented size exists but was not confirmed. The measured shape and
  // absence of an approved crop remain distinct reasons in the trace.
  final shapeMismatch = traces.contains('catalogShape=mismatch');
  final catalogAspectCode = traces.firstWhere(
    (code) => code.startsWith('catalogAspect='),
    orElse: () => '',
  );
  final catalogAspect = double.tryParse(
    catalogAspectCode.replaceFirst('catalogAspect=', ''),
  );
  final expectedShape = catalogAspect == null
      ? ''
      : ' بنسبة ${catalogAspect.toStringAsFixed(2)}:1';
  final reason = shapeMismatch
      ? 'النسبة المقاسة لا تطابق الكتالوج$expectedShape؛ لم يُمدَّد القص.'
      : 'لم يتوفر قصّ منظور معتمد.';
  return JourneyStep(
    stage: JourneyStage.sizing,
    outcome: JourneyOutcome.review,
    detail:
        'المقاس المرجعي لنوع «${item.documentKind.label}» هو $sizeText '
        'ولم يُثبَّت ($reason). المقاس المؤقت '
        '${item.width.toStringAsFixed(1)} × '
        '${item.height.toStringAsFixed(1)} مم؛ أكّده قبل الوضع التلقائي على A4.',
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

/// Kinds that received at least one keyword vote, named in Arabic, in the
/// order the classifier recorded them. Recovered from the fixed `reason` code
/// (`<kind>:anchor-groups=…`), so no recognized text is read.
List<String> _votedKindLabels(List<RecognitionEvidence> evidence) {
  final labels = <String>[];
  for (final item in evidence) {
    if (item.kind != 'ocr-keyword') continue;
    final reason = item.reason;
    if (reason == null) continue;
    final name = reason.split(':').first;
    for (final candidate in DocumentKind.values) {
      if (candidate == DocumentKind.unknown || candidate.name != name) continue;
      if (!labels.contains(candidate.label)) labels.add(candidate.label);
    }
  }
  return labels;
}

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
