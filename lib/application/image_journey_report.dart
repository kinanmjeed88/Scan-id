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
import '../domain/geometry.dart';
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
    this.copiedWidth,
    this.copiedHeight,
  });

  /// The name of the picked file, as the person sees it in the gallery.
  final String name;

  /// The saved asset, or null when the source was never copied.
  final String? assetId;

  /// Pixel size of the copy as it was WRITTEN by the import.
  ///
  /// A revision keeps [assetId] (see `_saveRevision`), so by the time a journey
  /// is filed the project may hold a CROPPED asset under the same id. Reading
  /// its width/height would report the crop as if it were the copy. These two
  /// fields are captured at import time for exactly that reason; when they are
  /// null the copy step says the size is unknown instead of guessing it.
  final int? copiedWidth;
  final int? copiedHeight;

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
  // The journal stores one-line, bounded names and refuses anything else. A
  // report is filed after the import was committed, so a name the journal
  // cannot hold is described in a form it can hold; it must never be the
  // reason a report, and with it the intake that asked for it, fails.
  final projectName = _journalName(project.name, fallback: '');
  for (var index = 0; index < images.length; index++) {
    final fact = images[index];
    final steps = _stepsFor(
      fact,
      project: project,
      projectName: projectName,
      savedRevision: savedRevision,
      isLast: index == images.length - 1,
    );
    journeys.add(
      ImageJourney(
        id: _journeyId(batchId, fact, index),
        batchId: batchId,
        projectId: project.id,
        projectName: projectName,
        imageName: _journalName(fact.name, fallback: unnamedImageLabel),
        startedAt: startedAt,
        sheetRevision: savedRevision,
        steps: steps,
      ),
    );
  }
  return List.unmodifiable(journeys);
}

/// Shown for a picked image whose name is empty once made a single line.
const String unnamedImageLabel = 'صورة بلا اسم';

final RegExp _controlCharacters = RegExp(
  r'[\u0000-\u001F\u007F\u0085\u2028\u2029]+',
);

/// [raw] as one bounded line: control characters and line breaks become a
/// space, the ends are trimmed, an over-long name ends in «…», and an empty
/// result is [fallback].
String _journalName(String raw, {required String fallback}) {
  final single = raw
      .replaceAll(_controlCharacters, ' ')
      .replaceAll(RegExp(' {2,}'), ' ')
      .trim();
  if (single.isEmpty) return fallback;
  return _shortened(single, ImageJourney.maxNameLength);
}

/// [value] cut to [limit] UTF-16 units, ending in «…» when it was cut. The
/// cut never leaves half of a surrogate pair behind.
String _shortened(String value, int limit) {
  if (value.length <= limit) return value;
  var end = limit - 1;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return '${value.substring(0, end).trimRight()}…';
}

/// Deterministic, so writing the same run twice cannot duplicate an entry.
String _journeyId(String batchId, ImportedImageFact fact, int index) =>
    '$batchId-${fact.assetId ?? 'picked$index'}';

List<JourneyStep> _stepsFor(
  ImportedImageFact fact, {
  required Project project,
  required String projectName,
  required int? savedRevision,
  required bool isLast,
}) {
  final steps = <JourneyStep>[
    JourneyStep(
      stage: JourneyStage.selection,
      outcome: JourneyOutcome.passed,
      detail: _clip('اختيرت من جهازك لتُضاف إلى مشروع «$projectName».'),
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
  steps.add(_placementStep(project, items, records));
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
  // The copy's own size, captured when it was written. `asset` is looked up by
  // id and a revision keeps that id, so its width/height may already describe a
  // later crop; reporting those would misattribute the crop to the copy.
  final width = fact.copiedWidth;
  final height = fact.copiedHeight;
  final size = width == null || height == null
      ? 'حُفظت نسخة داخل مساحة التطبيق (الأبعاد غير مسجّلة)$scaled'
      : 'نُسخت إلى مساحة التطبيق ($width×$height بكسل)$scaled';
  return JourneyStep(
    stage: JourneyStage.copy,
    outcome: JourneyOutcome.passed,
    detail: size,
    durationMs: fact.copyDurationMs?.clamp(0, JourneyStep.maxDurationMs),
    // Recorded even when the sentence had to fall back to "unknown", so the
    // size of the copy is always machine-readable.
    fields: {
      if (width != null) 'copiedWidth': width,
      if (height != null) 'copiedHeight': height,
      'scaledWorkingCopy': asset.hasScaledLargeSource,
    },
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
      fields: records.length > 1 || records.single.sides.length > 1
          ? _readEachDetection(records).fields
          : const {},
    );
  }
  final traces = <String>{
    for (final detection in detections) ...detection.detectionTrace,
  };
  final diagnostics = <String>{
    for (final detection in detections) ...detection.boundaryDiagnostics,
  };
  if (traces.isNotEmpty || diagnostics.isNotEmpty) {
    final accepted =
        detections.every(_hasAcceptedBoundary) &&
        detections.length ==
            records.fold<int>(
              0,
              (count, record) => count + record.sides.length,
            );
    final String sentence;
    final Map<String, Object?> fields;
    if (records.length == 1 && records.single.sides.length == 1) {
      final measured = _readDetectionTrace(traces);
      sentence = measured.sentence;
      fields = {
        ...measured.fields,
        if (diagnostics.isNotEmpty) 'reasons': diagnostics.length,
        if (accepted) 'accepted': true,
      };
    } else {
      // Several documents were found in this ONE image, each measured and
      // decided on its own. Their facts are never merged: a shared `aspect`
      // or `accepted` key would describe a decision that was never taken,
      // the shape of one document beside the verdict of another.
      final each = _readEachDetection(records);
      sentence = each.sentence;
      fields = each.fields;
    }
    final reasons = diagnostics.join(' · ');
    final described = [
      if (sentence.isNotEmpty) 'الكشف: $sentence',
      if (reasons.isNotEmpty) reasons,
    ].join(' — ');
    // Codes that carry numbers only (or codes this build does not name) leave
    // nothing to say in a sentence; the step is still recorded, with fields.
    final detail = described.trim().isEmpty
        ? 'سُجّل قرار الحدود؛ القياسات في الحقول المنظَّمة.'
        : described;
    return JourneyStep(
      stage: JourneyStage.detection,
      outcome: accepted ? JourneyOutcome.passed : JourneyOutcome.review,
      detail: _clip(detail),
      // The full decision evidence, never clipped. `reasons` is the refusal
      // trail in the app's own message form; `fields` holds the numbers.
      fields: fields,
    );
  }
  final sideCount = records.fold<int>(
    0,
    (count, record) => count + record.sides.length,
  );
  final accepted =
      detections.length == sideCount && detections.every(_hasAcceptedBoundary);
  final confidence = detections.length == 1
      ? detections.single.detectionConfidence?.value
      : null;
  return JourneyStep(
    stage: JourneyStage.detection,
    outcome: accepted ? JourneyOutcome.passed : JourneyOutcome.review,
    fields: records.length > 1 || records.single.sides.length > 1
        ? _readEachDetection(records).fields
        : {if (accepted) 'accepted': true},
    detail: accepted
        ? confidence == null
              ? 'حُفظت حدود مقبولة؛ درجة الكشف غير متاحة.'
              : 'حُفظت حدود مقبولة بدرجة كشف ${_percent(confidence)}.'
        : 'لا توجد حدود مقبولة وصالحة لكل أوجه المستندات؛ راجع الحدود.',
  );
}

/// The stored accepted polygon is a decision, not merely a score or a
/// suggestion. Migration synthesizes full-frame polygons for legacy records;
/// those describe a region, not a detector acceptance.
bool _hasAcceptedBoundary(DetectionRef detection) {
  final polygon = detection.polygon;
  return detection.producer != 'legacy-import' &&
      polygon != null &&
      normalizedQuadIssue(polygon) == null;
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

/// The detection facts of an image that held several documents: the counts
/// for the image, then every document's own facts under its own numbered
/// prefix (`d1_`, `d2_`, … in the order the documents were recorded).
///
/// The keys inside a prefix are the ones a single-document image carries
/// unprefixed, so one reader serves both shapes.
({String sentence, Map<String, Object?> fields}) _readEachDetection(
  List<DocumentRecord> records,
) {
  final fields = <String, Object?>{'documents': records.length};
  final parts = <String>[];
  var acceptedCount = 0;
  for (var index = 0; index < records.length; index++) {
    final record = records[index];
    final number = index + 1;
    var allAccepted = true;
    for (var sideIndex = 0; sideIndex < record.sides.length; sideIndex++) {
      final detection = record.sides[sideIndex].detection;
      final prefix = record.sides.length == 1
          ? 'd${number}_'
          : 'd${number}_s${sideIndex + 1}_';
      if (detection == null) {
        allAccepted = false;
        fields['${prefix}missing'] = true;
        continue;
      }
      final measured = _readDetectionTrace(detection.detectionTrace);
      for (final entry in measured.fields.entries) {
        fields['$prefix${entry.key}'] = entry.value;
      }
      if (detection.boundaryDiagnostics.isNotEmpty) {
        fields['${prefix}reasons'] = detection.boundaryDiagnostics.length;
      }
      final accepted = _hasAcceptedBoundary(detection);
      if (accepted) fields['${prefix}accepted'] = true;
      if (!accepted) allAccepted = false;
      if (measured.sentence.isNotEmpty) {
        parts.add('المستند $number: ${measured.sentence}');
      }
    }
    if (allAccepted) acceptedCount++;
  }
  fields['acceptedDocuments'] = acceptedCount;
  final summary =
      '${records.length} مستندات في الصورة الواحدة، '
      '$acceptedCount منها بحدود مقبولة';
  return (sentence: [summary, ...parts].join(' · '), fields: fields);
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
String _describeDetectionTrace(Iterable<String> codes) =>
    _readDetectionTrace(codes).sentence;

/// The same evidence in two shapes: an Arabic [sentence] for a person, and
/// [fields] carrying every number and code verbatim.
///
/// The sentence is what [JourneyStep.detail] holds and is therefore clipped;
/// the fields are what a decision must be read from, so nothing that identifies
/// a detector's outcome, score or the measured shape can be lost to that clip.
({String sentence, Map<String, Object?> fields}) _readDetectionTrace(
  Iterable<String> codes,
) {
  final parts = <String>[];
  final fields = <String, Object?>{};
  var reviewReasons = 0;
  var detectorIndex = 0;
  final seenSlots = <String>{};
  for (final code in codes) {
    final trace = BoundaryDetectorTrace.decode(code);
    if (trace != null) {
      final name = _detectorName(trace.modelId);
      final slot = _detectorSlot(trace.modelId);
      final score = trace.confidence == null
          ? ''
          : ' بدرجة ${_percent(trace.confidence!)}';
      detectorIndex++;
      final run = 'run$detectorIndex';
      // Numbered runs keep repeated families and unknown detectors separate.
      // Retain the first family alias for existing readers; never mix its
      // optional fields with a later run.
      final safeId =
          (RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(trace.modelId) ||
              (trace.modelId.length <= JourneyStep.maxFieldValueLength &&
                  RegExp(
                    r'^DocQuadNet-[A-Za-z0-9_.-]+/ORT-[A-Za-z0-9_.-]+$',
                  ).hasMatch(trace.modelId)))
          ? trace.modelId
          : 'unknown';
      fields['${run}_model'] = safeId;
      fields['${run}_outcome'] = trace.outcome.name;
      if (trace.confidence != null) {
        fields['${run}_confidence'] = _round4(trace.confidence!);
      }
      if (trace.errorType != null) {
        fields['${run}_error'] = _boundedCode(trace.errorType!);
      }
      if (seenSlots.add(slot)) {
        fields['${slot}_outcome'] = trace.outcome.name;
        if (trace.confidence != null) {
          fields['${slot}_confidence'] = _round4(trace.confidence!);
        }
        if (trace.errorType != null) {
          fields['${slot}_error'] = _boundedCode(trace.errorType!);
        }
      }
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
      fields['disagreement'] = _round4(number);
      parts.add('تباعد الزوايا بين الكاشفين ${_percent(number)}');
    } else if (key == 'aspect' && number != null) {
      fields['aspect'] = _round4(number);
      parts.add('نسبة الحدود ${number.toStringAsFixed(2)}:1');
    } else if (key == 'area' && number != null) {
      fields['area'] = _round4(number);
      parts.add('مساحة الحدود ${_percent(number)} من الصورة');
    } else if (key == 'geometry' && number != null) {
      fields['geometry'] = _round4(number);
      parts.add('جودة الهندسة ${_percent(number)}');
    } else if (key == 'corroboration' &&
        raw == BoundaryCorroboration.classicalCatalogAspect.name) {
      fields['corroboration'] = raw;
      parts.add('تأييد الكاشف الكلاسيكي بنسبة النوع');
    } else if (key == 'rejection') {
      fields['rejection'] = _boundedCode(raw);
      parts.add(_quadRejectionLabel(raw));
    } else if (key == 'catalogAspect' && number != null) {
      fields['catalogAspect'] = _round4(number);
    } else if (key == 'catalogShape') {
      fields['catalogShape'] = _boundedCode(raw);
    } else if (key == 'review') {
      // The decision's own reason codes, one numbered key each: a JSON object
      // cannot repeat a key, and a joined list could outgrow the per-value
      // bound. The person-facing sentences for the same reasons are appended
      // to the detail and may be clipped there; these never are.
      reviewReasons++;
      fields['review_$reviewReasons'] = _boundedCode(raw);
    }
  }
  return (sentence: parts.join(' · '), fields: fields);
}

/// Detector identity reduced to a stable field prefix.
///
/// Matched by family and without regard to case, exactly as [_detectorName]
/// does: the shipped ids are `DocQuadNet-256/ORT-1.28` and
/// `docaligner-1.1.1-fastvit-sa24-7f9f5a89`, and a prefix test written for a
/// capitalised look-alike filed the second model under the generic slot. A
/// model this build does not name keeps that generic slot.
String _detectorSlot(String modelId) {
  final id = modelId.toLowerCase();
  if (id.contains('docquad')) return 'docquadnet';
  if (id.contains('docaligner')) return 'docaligner';
  if (id.contains('segment')) return 'segmenter';
  return 'detector';
}

double _round4(double value) => (value * 10000).roundToDouble() / 10000;

/// Trimmed to the schema's per-value bound. Values here are enum names and
/// model error type names, never recognized text.
String _boundedCode(String value) =>
    value.length <= JourneyStep.maxFieldValueLength
    ? value
    : value.substring(0, JourneyStep.maxFieldValueLength);

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
  if (records.length > 1 || records.single.sides.length > 1) {
    final sideCount = records.fold<int>(
      0,
      (count, record) => count + record.sides.length,
    );
    final fields = <String, Object?>{
      'outputs': processed.length,
      'sides': sideCount,
    };
    for (var i = 0; i < records.length; i++) {
      for (var j = 0; j < records[i].sides.length; j++) {
        final output = records[i].sides[j].processedAsset;
        final prefix = 'd${i + 1}_s${j + 1}_';
        fields['${prefix}warped'] = output.corners != null;
        if (output.corners != null) {
          fields['${prefix}width'] = output.outputWidth ?? output.width;
          fields['${prefix}height'] = output.outputHeight ?? output.height;
        }
      }
    }
    return JourneyStep(
      stage: JourneyStage.crop,
      outcome: processed.length == sideCount
          ? JourneyOutcome.passed
          : JourneyOutcome.review,
      detail:
          'صُحّح منظور ${processed.length} من $sideCount أوجه.'
          '${processed.length == sideCount ? '' : ' البقية تحتاج مراجعة.'}',
      fields: fields,
    );
  }
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
      // The rendered size of the warp's own output, read from the processed
      // asset rather than the source, so copy and crop can never be confused.
      fields: {
        'crop': 'perspective-warp',
        'outputWidth': first.outputWidth ?? first.width,
        'outputHeight': first.outputHeight ?? first.height,
        'outputs': processed.length,
      },
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
  if (records.length > 1) {
    final steps = [
      for (final record in records) _recognitionStep([record]),
    ];
    final passed = steps
        .where((step) => step.outcome == JourneyOutcome.passed)
        .length;
    return JourneyStep(
      stage: JourneyStage.recognition,
      outcome: passed == steps.length
          ? JourneyOutcome.passed
          : JourneyOutcome.review,
      detail:
          'اكتمل تصنيف $passed من ${steps.length} مستندات؛ '
          '${passed == steps.length ? 'صُنّفت جميعها.' : 'البقية تحتاج مراجعة.'}',
      fields: {
        'documents': steps.length,
        'classifiedDocuments': passed,
        for (var i = 0; i < steps.length; i++) ...{
          'd${i + 1}_outcome': steps[i].outcome.name,
          if (records[i].recognition != null)
            'd${i + 1}_kind': records[i].recognition!.documentKind.name,
        },
      },
    );
  }
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
  if (recognition.status == RecognitionStatus.unknown &&
      kind != DocumentKind.unknown) {
    return JourneyStep(
      stage: JourneyStage.recognition,
      outcome: JourneyOutcome.review,
      detail: 'حالة التصنيف غير مؤكدة رغم وجود نوع مسجّل؛ راجع المستند.',
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
  if (items.length > 1) {
    final steps = [
      for (final item in items)
        _sizingStep(
          [item],
          [
            for (final record in records)
              if (record.id == item.documentId) record,
          ],
        ),
    ];
    final passed = steps
        .where((step) => step.outcome == JourneyOutcome.passed)
        .length;
    return JourneyStep(
      stage: JourneyStage.sizing,
      outcome: passed == steps.length
          ? JourneyOutcome.passed
          : JourneyOutcome.review,
      detail:
          'ثُبّت مقاس $passed من ${steps.length} عناصر؛ '
          '${passed == steps.length ? 'ثُبّتت جميع المقاسات.' : 'البقية تحتاج مراجعة.'}',
      fields: {
        'items': steps.length,
        'sizedItems': passed,
        for (var i = 0; i < steps.length; i++) ...{
          'i${i + 1}_outcome': steps[i].outcome.name,
          'i${i + 1}_kind': items[i].documentKind.name,
          if (records.indexWhere(
                (record) => record.id == items[i].documentId,
              ) >=
              0)
            'i${i + 1}_document':
                records.indexWhere(
                  (record) => record.id == items[i].documentId,
                ) +
                1,
        },
      },
    );
  }
  final item = items.first;
  final natural = _catalogSizeOf(item.documentKind);
  final sizeText = natural == null
      ? null
      : '${natural.width.toStringAsFixed(1)} × '
            '${natural.height.toStringAsFixed(1)} مم';
  final traces = {
    for (final record in records)
      if (item.documentId == null
          ? records.length == 1
          : record.id == item.documentId)
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
      detail: _clip(
        'ثُبِّت مقاس النوع «${item.documentKind.label}» ($basis، $shape) '
        'دون تمديد: $sizeText.',
      ),
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
      detail: _clip(
        'مقاس «${item.documentKind.label}» تقديري قابل للتعديل ($sizeText)؛ '
        'المقاس المؤقت ${item.width.toStringAsFixed(1)} × '
        '${item.height.toStringAsFixed(1)} مم. أكّده يدوياً قبل الوضع على A4.',
      ),
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
    detail: _clip(
      'المقاس المرجعي لنوع «${item.documentKind.label}» هو $sizeText '
      'ولم يُثبَّت ($reason). المقاس المؤقت '
      '${item.width.toStringAsFixed(1)} × '
      '${item.height.toStringAsFixed(1)} مم؛ أكّده قبل الوضع التلقائي على A4.',
    ),
  );
}

JourneyStep _placementStep(
  Project project,
  List<DocumentItem> items,
  List<DocumentRecord> records,
) {
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
  final itemFields = <String, Object?>{
    'items': items.length,
    'placedItems': placed.length,
    for (var i = 0; i < items.length; i++) ...{
      'i${i + 1}_placed': items[i].pageIndex != null,
      if (items[i].pageIndex != null) 'i${i + 1}_page': items[i].pageIndex! + 1,
      if (records.indexWhere((record) => record.id == items[i].documentId) >= 0)
        'i${i + 1}_document':
            records.indexWhere((record) => record.id == items[i].documentId) +
            1,
    },
  };
  if (placed.isNotEmpty && placed.length != items.length) {
    return JourneyStep(
      stage: JourneyStage.placement,
      outcome: JourneyOutcome.review,
      detail:
          'وُضع ${placed.length} من ${items.length} عناصر على الورقة؛ '
          'البقية خارجها وتحتاج مراجعة.',
      fields: itemFields,
    );
  }
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
      detail: _clip('وُضع في $pageText داخل حدود الورقة$count.'),
      fields: items.length > 1 ? itemFields : const {},
    );
  }
  final item = items.first;
  return JourneyStep(
    stage: JourneyStage.placement,
    outcome: JourneyOutcome.review,
    detail: _clip(unplacedDocumentMessage(project, item)),
    fields: items.length > 1 ? itemFields : const {},
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
  // A step refuses an empty detail; "nothing to add" is said explicitly.
  if (single.isEmpty) return 'لا تفصيل مسجَّل لهذه المرحلة.';
  return _shortened(single, JourneyStep.maxDetailLength);
}
