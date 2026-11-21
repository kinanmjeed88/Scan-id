/// The complete, auditable record of what happened to one photograph while it
/// was processed: every stage the real pipeline passes through, with a status,
/// a measured duration, the inputs it received, the result it produced, the
/// evidence that the result is real, and the cause of every skip or failure.
///
/// This model exists because "the function was called" is not evidence that a
/// stage did its job. A stage is only [StageStatus.succeeded] when the caller
/// supplied [StageEvidence.verified]; a stage the pipeline never reached is
/// never reported as successful, and a stage bypassed by a user choice is
/// reported as [StageStatus.overridden] with that choice named.
///
/// Pure Dart: no widgets, no files, no pipeline. It validates itself, refuses
/// unbounded or multi-line text, and round-trips through versioned JSON so a
/// report written by this build can be read (or safely rejected) by another.
library;

import 'document_kind.dart';
import 'intake_options.dart';
import 'recognition.dart' show SideKind;
import 'validation.dart';

/// Every stage the real intake pipeline passes through.
///
/// Declaration order IS the pipeline order, because a report is read top to
/// bottom. A stage that does not apply to a route is still reported in place —
/// with [StageStatus.notApplicable] or [StageStatus.overridden] — rather than
/// omitted, because a missing row reads as an oversight.
enum ProcessingStage {
  selection(
    'اختيار الصورة واستلامها',
    'استلام المصدر المختار والتحقق من وصوله إلى مسار الاستيراد.',
  ),
  fileValidation(
    'التحقق من الملف وصيغته',
    'التحقق من الاسم والحجم وفحص الترويسة متى أمكن قبل فك الترميز.',
  ),
  decode(
    'قراءة الصورة وفك ترميزها',
    'قراءة بايتات المصدر وفك ترميزها إلى صورة صالحة.',
  ),
  dimensions(
    'التحقق من أبعاد الصورة واتجاهها',
    'قراءة العرض والارتفاع واتجاه EXIF ومقارنتها بحدود المعالجة.',
  ),
  importCopy(
    'نسخ الصورة إلى المشروع',
    'كتابة المصدر داخل مساحة المشروع وحفظ المشروع الذي يشير إليه.',
  ),
  previewPreparation(
    'تجهيز الصورة للعرض أو المعالجة',
    'إنتاج نسخة المعاينة المحدودة التي تعمل عليها المراحل التالية.',
  ),
  preprocessing(
    'تحسين الصورة والمعالجة المسبقة',
    'قصّ منطقة القراءة وتجهيزها قبل تحليل النص.',
  ),
  analysis(
    'تحليل الصورة',
    'تشغيل مسار التحليل الكامل على معاينة الصورة.',
  ),
  detection(
    'اكتشاف المستمسك أو المستمسكات',
    'قياس المناطق التي يمكن أن تكون مستمسكات في الصورة.',
  ),
  boundaryCorners(
    'تحديد الحدود والزوايا',
    'اقتراح رباعي الزوايا للمنطقة المكتشفة أو حفظ زوايا المستخدم.',
  ),
  confidence(
    'حساب نسبة الثقة',
    'جمع درجات الثقة المقيسة التي تحكم قبول الحدود والتصنيف.',
  ),
  automaticClassification(
    'التعرف التلقائي على نوع المستمسك',
    'قراءة النص وتحليل أدلته لاستنتاج نوع المستند.',
  ),
  userClassification(
    'اعتماد النوع الذي حدده المستخدم',
    'تثبيت النوع أو الوجه الذي اختاره المستخدم بدلاً من الاستنتاج.',
  ),
  faceVerification(
    'التحقق من الوجه المحدد',
    'التحقق من الوجه (أول/ثانٍ) ومن صلاحية اقتران وجهيه.',
  ),
  boundaryReview(
    'مراجعة الحدود والموافقة على القص',
    'تقرير هل تُقبل الحدود تلقائياً أم تُعرض على المستخدم للموافقة.',
  ),
  geometryCheck(
    'التحقق الهندسي من صلاحية الحدود',
    'التحقق من الأربع زوايا: عدم التقاطع والمساحة والنسبة والالتصاق بالحافة.',
  ),
  perspective(
    'تصحيح المنظور',
    'تحويل الرباعي المقبول إلى مستطيل عبر تحويل المنظور.',
  ),
  crop(
    'تنفيذ القص',
    'إنتاج بايتات الصورة المقصوصة من المصدر الأصلي.',
  ),
  centering(
    'توسيط المستمسك عند تفعيل الخيار',
    'تطبيق خيار التوسيط المحفوظ في المشروع عند إضافة المستند.',
  ),
  outputEnhancement(
    'تحسين الصورة الناتجة',
    'تطبيق الحدة والتدوير والإعدادات المحفوظة على الصورة المقصوصة.',
  ),
  documentModel(
    'إنشاء نموذج المستند',
    'إنشاء سجل المستند الذي يربط الوجوه بالمصدر.',
  ),
  typeSideSize(
    'تمرير النوع والوجه والمقاس',
    'تثبيت النوع والوجه والمقاس على المستند والعنصر.',
  ),
  saveDocument(
    'حفظ المستند',
    'كتابة ملف المستند وحفظ المشروع الذي يشير إليه.',
  ),
  addToProject(
    'إضافته إلى المشروع',
    'إضافة المستند إلى قائمة العناصر أو إلى ورقة A4.',
  ),
  verifyAddition(
    'التحقق من نجاح الإضافة',
    'قراءة المشروع المحفوظ للتأكد من وجود الأصل والمستند والعنصر.',
  ),
  completion(
    'إنهاء العملية',
    'إغلاق عملية الصورة وإثبات نتيجتها النهائية.',
  );

  const ProcessingStage(this.label, this.description);

  /// The Arabic title shown beside the stage.
  final String label;

  /// What the stage is supposed to do, in one sentence.
  final String description;

  /// Whether this stage is recorded per document rather than per image.
  ///
  /// A photograph with four selected documents has four independent answers to
  /// «هل صُحح المنظور؟» and «هل حُفظ المستند؟», so those answers live on the
  /// document record, never averaged into one image-level claim.
  bool get documentScoped => switch (this) {
    boundaryCorners ||
    boundaryReview ||
    geometryCheck ||
    perspective ||
    crop ||
    centering ||
    outputEnhancement ||
    documentModel ||
    typeSideSize ||
    saveDocument ||
    addToProject ||
    verifyAddition => true,
    _ => false,
  };

  /// Parses a persisted stage name; null for an unknown value so a report from
  /// another build is rejected instead of being trusted blindly.
  static ProcessingStage? byName(Object? value) {
    for (final stage in values) {
      if (stage.name == value) return stage;
    }
    return null;
  }
}

/// The actual state of one stage.
///
/// These are deliberately distinct: a stage the user turned off is NOT the same
/// as a stage that does not apply, and neither is the same as a stage the
/// pipeline never reached. Collapsing them would make the log unable to answer
/// «لماذا؟».
enum StageStatus {
  succeeded('ناجحة', 'نُفذت المرحلة واكتمل عملها، وتحققت النتيجة.'),
  failed('فاشلة', 'جرت محاولة تنفيذها لكنها لم تحقق النتيجة المطلوبة.'),
  overridden('تم التجاوز', 'لم تُنفذ بسبب قرار منطقي أو خيار اختاره المستخدم.'),
  notApplicable('غير مطلوبة', 'المرحلة لا تنطبق على مسار المعالجة الحالي.'),
  stopped(
    'متوقفة',
    'أُوقفت سلسلة المعالجة عند هذه المرحلة، ولم تكتمل؛ وقد لا يكون تنفيذها بدأ.',
  ),
  notReached('لم تُنفَّذ', 'لم تصل العملية إلى المرحلة.'),
  running('قيد التنفيذ', 'المرحلة تعمل حالياً ولم تظهر نتيجتها النهائية بعد.'),
  cancelled('ملغاة', 'أُلغي الطلب أو أُلغيت المرحلة لسبب خارجي.');

  const StageStatus(this.label, this.description);

  /// The Arabic word shown on the stage's status pill.
  final String label;

  /// What the status means, for the report's legend and tooltips.
  final String description;

  /// Whether a human has to act on this stage.
  bool get needsAttention =>
      this == failed ||
      this == stopped ||
      this == cancelled ||
      this == running;

  /// Whether the stage reached a settled result.
  bool get isTerminal => this != running;

  /// Whether this status is a problem rather than a decision.
  bool get isProblem =>
      this == failed || this == stopped || this == cancelled;

  /// Whether the stage actually produced the output it exists for.
  bool get delivered => this == succeeded;

  static StageStatus? byName(Object? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    return null;
  }
}

/// One measured check supporting a stage's verdict.
///
/// [name] is a dictionary code (e.g. `bytes_nonempty`), never a sentence with
/// content in it. [detail] may explain the measurement, bounded to one line.
class EvidenceCheck {
  EvidenceCheck({required this.name, required this.passed, String detail = ''})
    : detail = _oneLine(detail, maxDetailLength) {
    require(
      _codePattern.hasMatch(name) && name.length <= maxNameLength,
      'رمز دليل المرحلة غير صالح.',
    );
  }

  static const int maxNameLength = 40;
  static const int maxDetailLength = 160;

  final String name;
  final bool passed;
  final String detail;

  Map<String, Object?> toJson() => {
    'name': name,
    'passed': passed,
    if (detail.isNotEmpty) 'detail': detail,
  };

  static EvidenceCheck fromJson(Object? json) {
    final map = objectMap(json);
    return EvidenceCheck(
      name: text(map['name'], 'name'),
      passed: boolean(map['passed'], 'passed'),
      detail: map['detail'] == null ? '' : text(map['detail'], 'detail'),
    );
  }
}

/// Why a stage is believed to have worked — or to have failed.
///
/// [verified] is the single fact that separates «the call returned» from «the
/// result is real». A successful stage is rejected by [StageRecord] unless its
/// evidence is verified AND carries at least one check or count, so a caller
/// cannot mark a stage successful with an empty assertion.
class StageEvidence {
  StageEvidence({
    required this.verified,
    List<EvidenceCheck> checks = const [],
    Map<String, int> counts = const {},
    String note = '',
  }) : checks = List.unmodifiable(checks),
       counts = Map.unmodifiable(counts),
       note = _oneLine(note, maxNoteLength) {
    require(checks.length <= maxChecks, 'عدد أدلة المرحلة كبير جداً.');
    require(
      counts.length <= maxCounts,
      'عدد عدادات المرحلة كبير جداً.',
    );
    for (final entry in this.counts.entries) {
      require(
        _codePattern.hasMatch(entry.key) && entry.key.length <= 40,
        'مفتاح العداد غير صالح.',
      );
      require(entry.value >= 0, 'قيمة العداد سالبة.');
    }
    if (verified) {
      require(
        this.checks.isNotEmpty || this.counts.isNotEmpty,
        'لا يمكن إثبات نجاح مرحلة دون قياس أو عداد.',
      );
    }
  }

  static const int maxNoteLength = 200;
  static const int maxChecks = 8;
  static const int maxCounts = 12;

  final bool verified;
  final String note;
  final List<EvidenceCheck> checks;
  final Map<String, int> counts;

  /// Every check passed and at least one check exists.
  bool get allChecksPassed =>
      checks.isNotEmpty && checks.every((check) => check.passed);

  /// A success claim needs verified evidence, and every supplied check must
  /// agree with it. Counts alone are allowed when a zero/positive measurement
  /// itself is the proof for that stage.
  bool get supportsSuccess =>
      verified && (checks.isEmpty || checks.every((check) => check.passed));

  StageEvidence asUnverified() => StageEvidence(
    verified: false,
    checks: checks,
    counts: counts,
    note: note,
  );

  Map<String, Object?> toJson() => {
    'verified': verified,
    if (note.isNotEmpty) 'note': note,
    if (checks.isNotEmpty) 'checks': [for (final c in checks) c.toJson()],
    if (counts.isNotEmpty) 'counts': counts,
  };

  static StageEvidence fromJson(Object? json) {
    final map = objectMap(json);
    final checks = <EvidenceCheck>[];
    if (map['checks'] != null) {
      for (final entry in objectList(map['checks'])) {
        checks.add(EvidenceCheck.fromJson(entry));
      }
    }
    final counts = <String, int>{};
    if (map['counts'] != null) {
      for (final entry in objectMap(map['counts']).entries) {
        counts[entry.key] = integer(entry.value, 'count.${entry.key}');
      }
    }
    return StageEvidence(
      verified: boolean(map['verified'], 'verified'),
      note: map['note'] == null ? '' : text(map['note'], 'note'),
      checks: checks,
      counts: counts,
    );
  }
}

/// One stage as it actually ran, or as it was actually bypassed.
class StageRecord {
  StageRecord({
    required this.stage,
    required this.status,
    required String reason,
    this.startedAt,
    this.endedAt,
    int? durationMs,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> results = const {},
    this.itemCount,
    String? errorType,
    String? errorCode,
    List<String> diagnostics = const [],
    String actionTaken = '',
    this.evidence,
    int attempt = 1,
  }) : reason = _oneLine(reason, maxReasonLength),
       inputs = Map.unmodifiable(_boundedFields(inputs)),
       results = Map.unmodifiable(_boundedFields(results)),
       diagnostics = List.unmodifiable([
         for (final line in diagnostics.take(maxDiagnostics))
           if (_oneLine(line, maxDiagnosticLength) case final cleaned
               when cleaned.isNotEmpty)
             cleaned,
       ]),
       actionTaken = _oneLine(actionTaken, maxReasonLength),
       errorType = _codeOrNull(errorType, 60),
       errorCode = _codeOrNull(errorCode, 60),
       durationMs = _durationOf(startedAt, endedAt, durationMs) {
    require(this.reason.isNotEmpty, 'سبب حالة المرحلة مطلوب.');
    if (itemCount != null) {
      require(itemCount! >= 0, 'عدد عناصر المرحلة سالب.');
    }
    require(attempt >= 1 && attempt <= maxAttempt, 'رقم المحاولة غير صالح.');
    if (status == StageStatus.succeeded) {
      // The core rule of this file: success is a verified claim, never the
      // absence of an exception.
      require(
        evidence != null && evidence!.supportsSuccess,
        'لا تُسجَّل مرحلة ناجحة دون تحقق فعلي من نتيجتها.',
      );
    }
    if (status == StageStatus.failed) {
      require(
        this.errorType != null || this.diagnostics.isNotEmpty,
        'المرحلة الفاشلة تحتاج نوع الخطأ أو تفاصيل تشخيصية؛ '
        'وإن لم يُحسم السبب فسجّله صراحةً في التفاصيل.',
      );
    }
  }

  static const int maxReasonLength = 280;
  static const int maxDetailLength = 120;
  static const int maxDiagnostics = 8;
  static const int maxDiagnosticLength = 200;
  static const int maxAttempt = 20;

  /// Reason used when the evidence does not identify a cause.
  static const String undeterminedCause =
      'السبب غير محسوم؛ التفاصيل التشخيصية المتاحة مرفقة.';

  final ProcessingStage stage;
  final StageStatus status;

  /// The cause, in one bounded sentence. Always required: even a successful
  /// stage says WHAT verified it, and a bypass says WHICH decision bypassed it.
  final String reason;

  final DateTime? startedAt;
  final DateTime? endedAt;
  final int? durationMs;

  /// The inputs that mattered, as dictionary codes and measured numbers.
  final Map<String, Object?> inputs;

  /// What the stage actually produced, as codes and numbers.
  final Map<String, Object?> results;

  /// How many items this stage processed, when counting is meaningful.
  final int? itemCount;

  /// The runtime type of the caught error, when one was caught.
  final String? errorType;

  /// A stable category for the failure, when the caller can name one.
  final String? errorCode;

  /// Bounded diagnostic lines. Empty means no further information was needed.
  final List<String> diagnostics;

  /// What the system did after this result — continued, fell back, stopped.
  final String actionTaken;

  /// The measured proof that the stage worked (or did not).
  final StageEvidence? evidence;

  /// 1 for the first run; incremented when a retry replaces this record.
  final int attempt;

  StageRecord withAttempt(int value) => StageRecord(
    stage: stage,
    status: status,
    reason: reason,
    startedAt: startedAt,
    endedAt: endedAt,
    durationMs: durationMs,
    inputs: inputs,
    results: results,
    itemCount: itemCount,
    errorType: errorType,
    errorCode: errorCode,
    diagnostics: diagnostics,
    actionTaken: actionTaken,
    evidence: evidence,
    attempt: value,
  );

  Map<String, Object?> toJson() => {
    'stage': stage.name,
    'status': status.name,
    'reason': reason,
    if (startedAt != null) 'started_utc': startedAt!.toUtc().toIso8601String(),
    if (endedAt != null) 'ended_utc': endedAt!.toUtc().toIso8601String(),
    if (durationMs != null) 'duration_ms': durationMs,
    if (inputs.isNotEmpty) 'inputs': inputs,
    if (results.isNotEmpty) 'results': results,
    if (itemCount != null) 'items': itemCount,
    if (errorType != null) 'error_type': errorType,
    if (errorCode != null) 'error_code': errorCode,
    if (diagnostics.isNotEmpty) 'diagnostics': diagnostics,
    if (actionTaken.isNotEmpty) 'action': actionTaken,
    if (evidence != null) 'evidence': evidence!.toJson(),
    if (attempt != 1) 'attempt': attempt,
  };

  static StageRecord fromJson(Object? json) {
    final map = objectMap(json);
    final stage = ProcessingStage.byName(map['stage']);
    final status = StageStatus.byName(map['status']);
    require(stage != null, 'مرحلة غير معروفة في سجل المعالجة.');
    require(status != null, 'حالة مرحلة غير معروفة في سجل المعالجة.');
    DateTime? readTime(Object? value) {
      if (value == null) return null;
      final parsed = DateTime.tryParse(text(value, 'time'));
      require(parsed != null, 'وقت مرحلة غير صالح.');
      return parsed!.toUtc();
    }

    final diagnostics = <String>[];
    if (map['diagnostics'] != null) {
      for (final line in objectList(map['diagnostics'])) {
        diagnostics.add(text(line, 'diagnostic'));
      }
    }
    return StageRecord(
      stage: stage!,
      status: status!,
      reason: text(map['reason'], 'reason'),
      startedAt: readTime(map['started_utc']),
      endedAt: readTime(map['ended_utc']),
      durationMs: map['duration_ms'] == null
          ? null
          : integer(map['duration_ms'], 'duration_ms'),
      inputs: map['inputs'] == null
          ? const {}
          : objectMap(map['inputs']),
      results: map['results'] == null
          ? const {}
          : objectMap(map['results']),
      itemCount: map['items'] == null ? null : integer(map['items'], 'items'),
      errorType: map['error_type'] == null
          ? null
          : text(map['error_type'], 'error_type'),
      errorCode: map['error_code'] == null
          ? null
          : text(map['error_code'], 'error_code'),
      diagnostics: diagnostics,
      actionTaken: map['action'] == null ? '' : text(map['action'], 'action'),
      evidence: map['evidence'] == null
          ? null
          : StageEvidence.fromJson(map['evidence']),
      attempt: map['attempt'] == null ? 1 : integer(map['attempt'], 'attempt'),
    );
  }
}

/// The independent record of ONE document (or one manual selection).
///
/// Every value here is per-document on purpose: a photograph that produced
/// three saved selections and one failure must say so for each selection, not
/// report an average. The record is linked to its source image through
/// [imageId] and carries the ids the pipeline actually created.
class DocumentProcessingLog {
  DocumentProcessingLog({
    required this.id,
    required this.imageId,
    required this.selectionIndex,
    String label = '',
    this.kind = DocumentKind.unknown,
    this.side = SideKind.unknown,
    this.kindSource = RecordSource.unknown,
    this.sideSource = RecordSource.unknown,
    this.startedAt,
    List<StageRecord> stages = const [],
    this.derivedAssetId,
    this.documentRecordId,
    this.layoutItemId,
    String outcome = '',
  }) : stages = List.unmodifiable(stages),
       label = _oneLine(label, 120),
       outcome = _oneLine(outcome, 280) {
    require(id.isNotEmpty && id.length <= 120, 'معرّف المستند غير صالح.');
    require(imageId.isNotEmpty, 'معرّف الصورة الأصلية مطلوب.');
    require(
      selectionIndex >= 1 && selectionIndex <= 1000,
      'ترتيب تحديد المستند غير صالح.',
    );
    for (final stage in this.stages) {
      require(
        stage.stage.documentScoped,
        'مرحلة على مستوى الصورة لا تُسجل داخل سجل المستند.',
      );
    }
    require(
      _uniqueStages(this.stages),
      'مراحل المستند مكررة دون داعٍ.',
    );
  }

  final String id;
  final String imageId;
  final int selectionIndex;
  final String label;
  final DocumentKind kind;
  final SideKind side;
  final RecordSource kindSource;
  final RecordSource sideSource;
  final DateTime? startedAt;
  List<StageRecord> stages;
  String? derivedAssetId;
  String? documentRecordId;
  String? layoutItemId;

  /// The human sentence that summarises this document's result.
  String outcome;

  StageRecord? stageOf(ProcessingStage stage) {
    for (final record in stages) {
      if (record.stage == stage) return record;
    }
    return null;
  }

  StageStatus? statusOf(ProcessingStage stage) => stageOf(stage)?.status;

  /// Replaces an earlier record for the same stage (a retry reports its final
  /// result, not a stale failure) and increments its attempt counter.
  void record(StageRecord entry) {
    require(entry.stage.documentScoped, 'المرحلة ليست على مستوى المستند.');
    final index = stages.indexWhere((s) => s.stage == entry.stage);
    final next = [...stages];
    if (index < 0) {
      next.add(entry);
    } else {
      final previous = stages[index];
      final sameAttempt =
          previous.status == StageStatus.running &&
          entry.status != StageStatus.running;
      next[index] = entry.withAttempt(
        sameAttempt ? previous.attempt : previous.attempt + 1,
      );
    }
    next.sort((a, b) => a.stage.index.compareTo(b.stage.index));
    stages = List.unmodifiable(next);
  }

  /// Whether the document reached a persisted form.
  bool get saved =>
      statusOf(ProcessingStage.saveDocument) == StageStatus.succeeded;

  /// Complete means both persistence and the saved-project read-back were
  /// verified. A persisted crop that has not been linked, or an item that is
  /// still awaiting a manual crop, is not represented as a completed document.
  bool get succeeded =>
      statusOf(ProcessingStage.crop) == StageStatus.succeeded &&
      statusOf(ProcessingStage.typeSideSize) == StageStatus.succeeded &&
      saved &&
      added;

  bool get failed => stages.any((stage) => stage.status == StageStatus.failed);

  bool get needsAttention =>
      !succeeded || stages.any((stage) => stage.status.needsAttention);

  /// Every document-level stage, with gaps and downstream stops made explicit.
  List<StageRecord> filledStages() {
    final recorded = {for (final record in stages) record.stage: record};
    final blockers = stages.where((record) => record.status.isProblem).toList()
      ..sort((a, b) => a.stage.index.compareTo(b.stage.index));
    final blocking = blockers.isEmpty ? null : blockers.first;
    final lastRecorded = stages.isEmpty
        ? -1
        : stages.map((record) => record.stage.index).reduce(
            (left, right) => left > right ? left : right,
          );
    return [
      for (final stage in ProcessingStage.values)
        if (stage.documentScoped)
          if (recorded[stage] case final record?)
            record
          else if (blocking != null && stage.index > blocking.stage.index)
            StageRecord(
              stage: stage,
              status: StageStatus.stopped,
              reason:
                  'لم تُنفَّذ لأن مرحلة «${blocking.stage.label}» لم تكتمل.',
              actionTaken: 'أُوقفت مراحل هذا المستند بعد أول مرحلة غير مكتملة.',
            )
          else
            StageRecord(
              stage: stage,
              status: StageStatus.notReached,
              reason: stage.index <= lastRecorded
                  ? 'ثغرة في التسجيل: لم تُسجَّل هذه المرحلة قبل مرحلة لاحقة.'
                  : 'لم يصل هذا المستند إلى هذه المرحلة.',
              diagnostics: const ['no_record'],
              actionTaken: 'لا إجراء؛ المرحلة لم تُنفَّذ.',
            ),
    ];
  }

  List<ProcessingStage> get recordingGaps {
    final recorded = {for (final record in stages) record.stage};
    final last = stages.isEmpty
        ? -1
        : stages.map((record) => record.stage.index).reduce(
            (left, right) => left > right ? left : right,
          );
    return [
      for (final stage in ProcessingStage.values)
        if (stage.documentScoped &&
            stage.index < last &&
            !recorded.contains(stage))
          stage,
    ];
  }

  bool get added =>
      statusOf(ProcessingStage.addToProject) == StageStatus.succeeded &&
      statusOf(ProcessingStage.verifyAddition) == StageStatus.succeeded;

  /// The first stage that failed, or null when none did.
  StageRecord? get firstFailure {
    for (final stage in stages) {
      if (stage.status == StageStatus.failed) return stage;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'image': imageId,
    'index': selectionIndex,
    if (label.isNotEmpty) 'label': label,
    'kind': kind.name,
    'side': side.name,
    'kind_source': kindSource.name,
    'side_source': sideSource.name,
    if (startedAt != null) 'started_utc': startedAt!.toUtc().toIso8601String(),
    if (derivedAssetId != null) 'derived_asset': derivedAssetId,
    if (documentRecordId != null) 'document_record': documentRecordId,
    if (layoutItemId != null) 'layout_item': layoutItemId,
    if (outcome.isNotEmpty) 'outcome': outcome,
    'stages': [for (final stage in stages) stage.toJson()],
  };

  static DocumentProcessingLog fromJson(Object? json) {
    final map = objectMap(json);
    return DocumentProcessingLog(
      id: text(map['id'], 'id'),
      imageId: text(map['image'], 'image'),
      selectionIndex: integer(map['index'], 'index'),
      label: map['label'] == null ? '' : text(map['label'], 'label'),
      kind: readEnum(DocumentKind.values, map['kind']),
      side: readEnum(SideKind.values, map['side']),
      kindSource: readEnum(RecordSource.values, map['kind_source']),
      sideSource: readEnum(RecordSource.values, map['side_source']),
      startedAt: map['started_utc'] == null
          ? null
          : DateTime.tryParse(text(map['started_utc'], 'started_utc'))?.toUtc(),
      derivedAssetId: map['derived_asset'] == null
          ? null
          : text(map['derived_asset'], 'derived_asset'),
      documentRecordId: map['document_record'] == null
          ? null
          : text(map['document_record'], 'document_record'),
      layoutItemId: map['layout_item'] == null
          ? null
          : text(map['layout_item'], 'layout_item'),
      outcome: map['outcome'] == null ? '' : text(map['outcome'], 'outcome'),
      stages: [
        for (final entry in objectList(map['stages']))
          StageRecord.fromJson(entry),
      ],
    );
  }
}

/// Where a value came from: the pipeline measured it, or the person asserted it.
enum RecordSource {
  unknown('غير محدد'),
  automatic('آلي'),
  user('المستخدم'),
  inherited('موروث من الخيارات');

  const RecordSource(this.label);
  final String label;

  static RecordSource byName(Object? value) {
    for (final source in values) {
      if (source.name == value) return source;
    }
    return RecordSource.unknown;
  }
}

/// The overall lifecycle of one image's processing.
enum ImageOutcome {
  running('قيد التنفيذ'),
  completed('اكتملت'),
  completedWithReview('اكتملت مع مراجعة'),
  partial('نجاح جزئي'),
  failed('فشلت'),
  cancelled('ملغاة'),
  stopped('متوقفة'),
  interrupted('انقطعت');

  const ImageOutcome(this.label);
  final String label;
  bool get needsAttention =>
      this == completedWithReview ||
      this == partial ||
      this == failed ||
      this == cancelled ||
      this == stopped ||
      this == interrupted;
}

/// The complete record of one source image: its stages and its documents.
class ImageProcessingLog {
  ImageProcessingLog({
    required this.operationId,
    required this.imageId,
    required this.startedAt,
    String imageName = '',
    this.sourceWidth,
    this.sourceHeight,
    List<StageRecord> stages = const [],
    List<DocumentProcessingLog> documents = const [],
    List<String> warnings = const [],
    this.endedAt,
    this.outcomeOverride,
  }) : stages = List.unmodifiable(stages),
       documents = List.unmodifiable(documents),
       imageName = _safeFileName(imageName, 200),
       warnings = List.unmodifiable(
         _uniqueLines(
           warnings,
           maxValues: maxWarnings,
           maxLength: StageRecord.maxReasonLength,
         ),
       ) {
    require(operationId.isNotEmpty, 'معرّف العملية مطلوب.');
    require(imageId.isNotEmpty && imageId.length <= 160, 'معرّف الصورة غير صالح.');
    require(
      sourceWidth == null || sourceWidth! > 0,
      'عرض المصدر غير صالح.',
    );
    require(
      sourceHeight == null || sourceHeight! > 0,
      'ارتفاع المصدر غير صالح.',
    );
    for (final stage in this.stages) {
      require(
        !stage.stage.documentScoped,
        'المرحلة على مستوى المستند لا تُسجل في سجل الصورة.',
      );
    }
    require(_uniqueStages(this.stages), 'مراحل الصورة مكررة دون داعٍ.');
    require(
      this.documents.map((d) => d.id).toSet().length == this.documents.length,
      'معرّفات المستندات مكررة داخل الصورة.',
    );
    for (final document in this.documents) {
      require(
        document.imageId == imageId,
        'سجل المستند مرتبط بصورة أخرى.',
      );
    }
  }

  static const int maxWarnings = 20;

  final String operationId;
  final String imageId;
  final String imageName;
  final DateTime startedAt;
  final int? sourceWidth;
  final int? sourceHeight;
  List<StageRecord> stages;
  List<DocumentProcessingLog> documents;
  List<String> warnings;
  DateTime? endedAt;

  /// Set by the recorder when the pipeline (not the statuses) decided the
  /// outcome, e.g. a batch stop that left only benign rows behind.
  ImageOutcome? outcomeOverride;

  StageRecord? stageOf(ProcessingStage stage) {
    for (final record in stages) {
      if (record.stage == stage) return record;
    }
    return null;
  }

  StageStatus? statusOf(ProcessingStage stage) => stageOf(stage)?.status;

  /// Adds or replaces a stage record. A later run for the same stage replaces
  /// the earlier one and records how many attempts it took, so a retry cannot
  /// duplicate rows.
  void record(StageRecord entry) {
    require(!entry.stage.documentScoped, 'المرحلة على مستوى المستند.');
    final index = stages.indexWhere((s) => s.stage == entry.stage);
    final next = [...stages];
    if (index < 0) {
      next.add(entry);
    } else {
      final previous = stages[index];
      final sameAttempt =
          previous.status == StageStatus.running &&
          entry.status != StageStatus.running;
      next[index] = entry.withAttempt(
        sameAttempt ? previous.attempt : previous.attempt + 1,
      );
    }
    next.sort((a, b) => a.stage.index.compareTo(b.stage.index));
    stages = List.unmodifiable(next);
  }

  DocumentProcessingLog document(String id, {int? index, String label = ''}) {
    for (final document in documents) {
      if (document.id == id) return document;
    }
    final created = DocumentProcessingLog(
      id: id,
      imageId: imageId,
      selectionIndex: index ?? documents.length + 1,
      label: label,
    );
    documents = List.unmodifiable([...documents, created]);
    return created;
  }

  /// Mutable lookup for the recorder: returns the live document object so it
  /// can add stage records, then [freezeDocument] replaces it with a validated
  /// immutable copy.
  void replaceDocument(DocumentProcessingLog document) {
    require(document.imageId == imageId, 'المستند يخص صورة أخرى.');
    final index = documents.indexWhere((d) => d.id == document.id);
    final next = [...documents];
    if (index < 0) {
      next.add(document);
    } else {
      next[index] = document;
    }
    next.sort((a, b) => a.selectionIndex.compareTo(b.selectionIndex));
    documents = List.unmodifiable(next);
  }

  String addWarning(String warning) {
    final safe = _oneLine(warning, StageRecord.maxReasonLength);
    if (safe.isEmpty ||
        warnings.length >= maxWarnings ||
        warnings.contains(safe)) {
      return safe;
    }
    warnings = List.unmodifiable([...warnings, safe]);
    return safe;
  }

  /// The first stage that failed, or null when none did.
  StageRecord? get firstFailure {
    for (final record in stages) {
      if (record.status == StageStatus.failed) return record;
    }
    return null;
  }

  /// The stage that stopped the chain, if any.
  StageRecord? get firstStop {
    for (final record in stages) {
      if (record.status.isProblem && record.status != StageStatus.failed) {
        return record;
      }
    }
    return firstFailure;
  }

  /// All image-level stages in pipeline order, with every stage the pipeline
  /// never reached filled in by a fact — never by «ناجحة».
  ///
  /// [stopCause] names the stage that stopped the chain for reasons the image
  /// itself does not carry (a cancelled batch, a failed batch stage).
  List<StageRecord> filledStages({StageRecord? stopCause}) {
    final recorded = {for (final record in stages) record.stage: record};
    final blocking = _firstBlocking(stopCause);
    final lastRecorded = stages.isEmpty
        ? -1
        : stages.map((s) => s.stage.index).reduce((a, b) => a > b ? a : b);
    final filled = <StageRecord>[];
    for (final stage in ProcessingStage.values) {
      if (stage.documentScoped) continue;
      final record = recorded[stage];
      if (record != null) {
        filled.add(record);
        continue;
      }
      if (blocking != null && stage.index > blocking.stage.index) {
        filled.add(
          StageRecord(
            stage: stage,
            status: StageStatus.stopped,
            reason:
                'لم تُنفَّذ لأن مرحلة «${blocking.stage.label}» لم تكتمل.',
            actionTaken: 'أُوقفت السلسلة عند أول مرحلة غير مكتملة.',
          ),
        );
        continue;
      }
      filled.add(
        StageRecord(
          stage: stage,
          status: StageStatus.notReached,
          reason: stage.index <= lastRecorded
              ? 'ثغرة في التسجيل: لم تُسجَّل هذه المرحلة قبل مرحلة لاحقة.'
              : 'لم تصل العملية إلى هذه المرحلة.',
          diagnostics: const ['no_record'],
          actionTaken: 'لا إجراء؛ المرحلة لم تُنفَّذ.',
        ),
      );
    }
    return filled;
  }

  /// Stages that were expected before a later stage but have no record.
  List<ProcessingStage> get recordingGaps {
    final recorded = {for (final record in stages) record.stage};
    var last = -1;
    for (final record in stages) {
      if (record.stage.index > last) last = record.stage.index;
    }
    return [
      for (final stage in ProcessingStage.values)
        if (!stage.documentScoped && stage.index < last && !recorded.contains(stage))
          stage,
    ];
  }

  StageRecord? _firstBlocking(StageRecord? stopCause) {
    final problems = stages.where((record) => record.status.isProblem).toList()
      ..sort((a, b) => a.stage.index.compareTo(b.stage.index));
    if (problems.isEmpty) return stopCause;
    if (stopCause == null) return problems.first;
    return stopCause.stage.index < problems.first.stage.index
        ? stopCause
        : problems.first;
  }

  ImageOutcome get outcome {
    if (outcomeOverride != null) return outcomeOverride!;
    final filled = filledStages();
    if (stages.any((s) => s.status == StageStatus.cancelled) ||
        documents.any(
          (document) => document.stages.any(
            (stage) => stage.status == StageStatus.cancelled,
          ),
        )) {
      return ImageOutcome.cancelled;
    }
    final imageFailure = filled.any(
      (s) => s.stage == ProcessingStage.completion
          ? false
          : s.status == StageStatus.failed,
    );
    final documentFailures = documents.where((d) => d.failed).length;
    final documentsSucceeded = documents.where((d) => d.succeeded).length;
    if (documentFailures > 0 && documentsSucceeded > 0) {
      return ImageOutcome.partial;
    }
    if (imageFailure || documentFailures > 0) return ImageOutcome.failed;
    if (stageOf(ProcessingStage.completion) == null && endedAt == null) {
      return ImageOutcome.running;
    }
    final stopped = filled.any(
      (s) => s.status == StageStatus.stopped && s.stage.index > _lastRealIndex,
    );
    if (stopped) return ImageOutcome.stopped;
    final needsReview =
        filled.any(
          (stage) =>
              stage.status == StageStatus.running ||
              stage.status == StageStatus.notReached,
        ) ||
        documents.any((document) => document.needsAttention);
    return needsReview
        ? ImageOutcome.completedWithReview
        : ImageOutcome.completed;
  }

  int get _lastRealIndex => stages.isEmpty
      ? -1
      : stages.map((s) => s.stage.index).reduce((a, b) => a > b ? a : b);

  Map<String, Object?> toJson() => {
    'operation': operationId,
    'image': imageId,
    if (imageName.isNotEmpty) 'name': imageName,
    if (sourceWidth != null) 'source_width': sourceWidth,
    if (sourceHeight != null) 'source_height': sourceHeight,
    'started_utc': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'ended_utc': endedAt!.toUtc().toIso8601String(),
    'outcome': outcome.name,
    if (outcomeOverride != null) 'outcome_forced': outcomeOverride!.name,
    'stages': [for (final record in stages) record.toJson()],
    if (documents.isNotEmpty)
      'documents': [for (final document in documents) document.toJson()],
    if (warnings.isNotEmpty) 'warnings': warnings,
  };

  static ImageProcessingLog fromJson(Object? json) {
    final map = objectMap(json);
    final started = DateTime.tryParse(text(map['started_utc'], 'started_utc'));
    require(started != null, 'وقت بدء الصورة غير صالح.');
    final forced = map['outcome_forced'] == null
        ? null
        : readEnum(ImageOutcome.values, map['outcome_forced']);
    return ImageProcessingLog(
      operationId: text(map['operation'], 'operation'),
      imageId: text(map['image'], 'image'),
      imageName: map['name'] == null ? '' : text(map['name'], 'name'),
      sourceWidth: map['source_width'] == null
          ? null
          : integer(map['source_width'], 'source_width'),
      sourceHeight: map['source_height'] == null
          ? null
          : integer(map['source_height'], 'source_height'),
      startedAt: started!.toUtc(),
      endedAt: map['ended_utc'] == null
          ? null
          : DateTime.tryParse(text(map['ended_utc'], 'ended_utc'))?.toUtc(),
      outcomeOverride: forced,
      stages: [
        for (final entry in objectList(map['stages']))
          StageRecord.fromJson(entry),
      ],
      documents: [
        for (final entry in objectList(map['documents'] ?? const []))
          DocumentProcessingLog.fromJson(entry),
      ],
      warnings: [
        for (final entry in objectList(map['warnings'] ?? const []))
          text(entry, 'warning'),
      ],
    );
  }
}

/// The final report for one processing operation (one batch).
class ProcessingReport {
  ProcessingReport({
    required this.batchId,
    required this.projectId,
    required String projectName,
    required this.startedAt,
    required List<ImageProcessingLog> images,
    this.endedAt,
    this.options,
    this.optionCodes = const [],
    this.warnings = const [],
    this.recovered = false,
    this.finalised = true,
  }) : images = List.unmodifiable(images),
       optionCodes = List.unmodifiable(optionCodes),
       warnings = List.unmodifiable(
         _uniqueLines(
           warnings,
           maxValues: 50,
           maxLength: StageRecord.maxReasonLength,
         ),
       ),
       projectName = _oneLine(projectName, 200) {
    require(batchId.isNotEmpty && batchId.length <= 160, 'معرّف الدفعة غير صالح.');
    require(projectId.isNotEmpty, 'معرّف المشروع مطلوب.');
    require(
      this.images.map((image) => image.imageId).toSet().length ==
          this.images.length,
      'صور مكررة في التقرير.',
    );
  }

  static const int schemaVersion = 1;

  final String batchId;
  final String projectId;
  final String projectName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<ImageProcessingLog> images;
  final IntakeOptions? options;

  /// The option codes as they were recorded, including for older reports whose
  /// options cannot be reconstructed.
  final List<String> optionCodes;

  final List<String> warnings;

  /// True when the report was rebuilt from appended events after a crash or a
  /// cancellation, instead of being filed by a completed run.
  final bool recovered;

  /// False while the operation is still running.
  final bool finalised;

  IntakeRoute get route =>
      options?.route ??
      (optionCodes.any((code) => code == 'route=manualSelections')
          ? IntakeRoute.manualSelections
          : IntakeRoute.singleAutomaticKind);

  List<DocumentProcessingLog> get documents => [
    for (final image in images) ...image.documents,
  ];

  /// Number of documents the pipeline measured or the user selected.
  int get documentsMeasured => documents.length;

  /// Documents whose crop produced a valid image.
  int get documentsCropped => documents
      .where(
        (document) =>
            document.statusOf(ProcessingStage.crop) == StageStatus.succeeded,
      )
      .length;

  /// Documents whose save stage succeeded.
  int get documentsSaved => documents.where((document) => document.saved).length;

  /// Documents confirmed present in the saved project.
  int get documentsAdded => documents.where((document) => document.added).length;

  /// Documents that failed at any document-level stage.
  int get documentsFailed => documents.where((document) => document.failed).length;

  /// Stages that succeeded, over every image and document.
  int get stagesSucceeded => _stageRecords
      .where((record) => record.status == StageStatus.succeeded)
      .length;
  int get stagesFailed => _stageRecords
      .where((record) => record.status == StageStatus.failed)
      .length;
  int get stagesOverridden => _stageRecords
      .where((record) => record.status == StageStatus.overridden)
      .length;
  int get stagesNotApplicable => _stageRecords
      .where((record) => record.status == StageStatus.notApplicable)
      .length;
  int get stagesStopped => _stageRecords
      .where((record) => record.status == StageStatus.stopped)
      .length;
  int get stagesNotReached => _stageRecords
      .where((record) => record.status == StageStatus.notReached)
      .length;
  int get stagesCancelled => _stageRecords
      .where((record) => record.status == StageStatus.cancelled)
      .length;

  int get totalDurationMs {
    final start = startedAt;
    final end = endedAt;
    if (end == null) return 0;
    final value = end.difference(start).inMilliseconds;
    return value < 0 ? 0 : value;
  }

  /// Sum of measured stage durations, by stage, over every image and document.
  Map<ProcessingStage, int> get stageDurations {
    final totals = <ProcessingStage, int>{};
    for (final record in _stageRecords) {
      if (record.durationMs == null) continue;
      totals.update(
        record.stage,
        (value) => value + record.durationMs!,
        ifAbsent: () => record.durationMs!,
      );
    }
    return totals;
  }

  Iterable<StageRecord> get _stageRecords sync* {
    for (final image in images) {
      yield* image.filledStages();
      for (final document in image.documents) {
        yield* document.filledStages();
      }
    }
  }

  /// Every image whose processing did not complete cleanly.
  List<ImageProcessingLog> get problemImages => [
    for (final image in images)
      if (image.outcome.needsAttention) image,
  ];

  /// The report's overall verdict, derived from recorded statuses only.
  ProcessingVerdict get verdict {
    if (!finalised || images.any((image) => image.outcome == ImageOutcome.running)) {
      return recovered ? ProcessingVerdict.interrupted : ProcessingVerdict.running;
    }
    if (stagesCancelled > 0) return ProcessingVerdict.cancelled;
    if (images.any((image) => image.outcome == ImageOutcome.interrupted)) {
      return ProcessingVerdict.interrupted;
    }
    final anyFailure = images.any(
      (image) =>
          image.outcome == ImageOutcome.partial ||
          image.outcome == ImageOutcome.failed,
    );
    if (anyFailure) {
      // «نجاح جزئي» claims something DID succeed. A batch where everything
      // failed is a failure, not a partial success.
      final anySaved = documentsSaved > 0;
      final anyImageCompleted = images.any(
        (image) =>
            image.outcome == ImageOutcome.completed ||
            image.outcome == ImageOutcome.completedWithReview,
      );
      return anySaved || anyImageCompleted
          ? ProcessingVerdict.partial
          : ProcessingVerdict.failed;
    }
    if (images.isNotEmpty &&
        images.every((image) => image.outcome == ImageOutcome.stopped)) {
      return ProcessingVerdict.stopped;
    }
    if (stagesFailed > 0) return ProcessingVerdict.failed;
    if (stagesStopped > 0) return ProcessingVerdict.completedWithReview;
    final review = images.any(
      (image) => image.outcome == ImageOutcome.completedWithReview,
    );
    return review
        ? ProcessingVerdict.completedWithReview
        : ProcessingVerdict.completed;
  }

  /// One Arabic line that states the outcome without hiding a failure.
  String get headline {
    if (images.isEmpty) return 'لم تُعالَج أي صورة.';
    switch (verdict) {
      case ProcessingVerdict.running:
        return 'المعالجة قيد التنفيذ؛ ${images.length} صورة.';
      case ProcessingVerdict.interrupted:
        return 'انقطعت المعالجة؛ ${images.length} صورة، والتقرير مُستعاد.';
      case ProcessingVerdict.cancelled:
        return 'أُلغيت المعالجة؛ ${images.length} صورة.';
      case ProcessingVerdict.completed:
        return 'اكتملت معالجة ${images.length} صورة بلا فشل.';
      case ProcessingVerdict.completedWithReview:
        return 'اكتملت ${images.length} صورة، وبقيت مراحل تحتاج مراجعة.';
      case ProcessingVerdict.partial:
        return 'نجاح جزئي: ${documentsSaved} مستنداً حُفظ، '
            'و${documentsFailed} فشل.';
      case ProcessingVerdict.failed:
        return 'تعذّرت المعالجة: ${stagesFailed} مرحلة فاشلة.';
      case ProcessingVerdict.stopped:
        return 'توقفت المعالجة قبل إتمام العمل؛ بقيت المراحل المنجزة محفوظة.';
    }
  }

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'batch': batchId,
    'project': {'id': projectId, 'name': projectName},
    'started_utc': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'ended_utc': endedAt!.toUtc().toIso8601String(),
    if (options != null) 'options': options!.traceCodes.toList(),
    if (optionCodes.isNotEmpty) 'option_codes': optionCodes,
    'recovered': recovered,
    'finalised': finalised,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'images': [for (final image in images) image.toJson()],
  };

  static ProcessingReport fromJson(Object? json) {
    final map = objectMap(json);
    final version = integer(map['version'], 'version');
    require(version == schemaVersion, 'نسخة تقرير معالجة غير مدعومة.');
    final project = objectMap(map['project']);
    final started = DateTime.tryParse(text(map['started_utc'], 'started_utc'));
    require(started != null, 'وقت بدء التقرير غير صالح.');
    final options = IntakeOptions.fromTraceCodes(map['options']);
    return ProcessingReport(
      batchId: text(map['batch'], 'batch'),
      projectId: text(project['id'], 'project.id'),
      projectName: text(project['name'], 'project.name'),
      startedAt: started!.toUtc(),
      endedAt: map['ended_utc'] == null
          ? null
          : DateTime.tryParse(text(map['ended_utc'], 'ended_utc'))?.toUtc(),
      options: options,
      optionCodes: [
        for (final entry in objectList(map['option_codes'] ?? const []))
          text(entry, 'option_code'),
      ],
      recovered: map['recovered'] == true,
      finalised: map['finalised'] != false,
      warnings: [
        for (final entry in objectList(map['warnings'] ?? const []))
          text(entry, 'warning'),
      ],
      images: [
        for (final entry in objectList(map['images']))
          ImageProcessingLog.fromJson(entry),
      ],
    );
  }
}

enum ProcessingVerdict {
  running('قيد التنفيذ'),
  completed('اكتملت'),
  completedWithReview('اكتملت مع مراجعة'),
  partial('نجاح جزئي'),
  failed('فشلت'),
  stopped('متوقفة'),
  cancelled('ملغاة'),
  interrupted('انقطعت');

  const ProcessingVerdict(this.label);
  final String label;
}

final RegExp _codePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');
final RegExp _pathToken = RegExp(r'(?:[A-Za-z]:)?[^\s]*[/\\][^\s]*');

/// [value] as one bounded line: control characters become spaces, the ends are
/// trimmed, and an over-long value is cut. A diagnostic is never allowed to
/// become a second failure just because it was long.
/// Sanitizes user-visible report text before it is copied into journal events.
///
/// Removes path-like tokens, line breaks and unbounded tails; use this at event
/// boundaries as well as when constructing a [ProcessingReport].
String sanitizeProcessingText(String value, {int maxLength = 280}) =>
    _oneLine(value, maxLength);

String _oneLine(String value, int limit) {
  final single = value
      .replaceAll(RegExp(r'[\r\n\u0000]+'), ' ')
      .replaceAll(RegExp(' {2,}'), ' ')
      .replaceAll(_pathToken, '[مسار محذوف]')
      .trim();
  if (single.length <= limit) return single;
  return single.substring(0, limit).trimRight();
}

List<String> _uniqueLines(
  Iterable<String> values, {
  required int maxValues,
  required int maxLength,
}) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    if (result.length >= maxValues) break;
    final safe = _oneLine(value, maxLength);
    if (safe.isNotEmpty && seen.add(safe)) result.add(safe);
  }
  return result;
}

String _safeFileName(String value, int limit) {
  final basename = value.replaceAll('\\', '/').split('/').last;
  return _oneLine(basename, limit);
}

/// A stable machine code: letters, digits and underscores only. A value that
/// cannot be made into one is reported as null rather than recorded verbatim.
String? _codeOrNull(String? value, int limit) {
  if (value == null) return null;
  final cleaned = value.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '').trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= limit ? cleaned : cleaned.substring(0, limit);
}

bool _uniqueStages(List<StageRecord> stages) =>
    stages.map((stage) => stage.stage).toSet().length == stages.length;

int? _durationOf(DateTime? startedAt, DateTime? endedAt, int? durationMs) {
  if (startedAt != null && endedAt != null) {
    final measured = endedAt.difference(startedAt).inMilliseconds;
    require(measured >= 0, 'وقت انتهاء المرحلة قبل وقت بدئها.');
    // The two timestamps are the authoritative measurement; a separately
    // supplied duration is redundant and must never turn a diagnostic into a
    // failure. The stopwatch and the wall clock can legitimately differ.
    return measured;
  }
  if (durationMs != null) {
    require(durationMs >= 0, 'مدة المرحلة سالبة.');
  }
  return durationMs;
}

/// Dictionary codes and measured values only: bounded keys, scalar values,
/// single-line, no path separators. This is what keeps recognized text and
/// personal data out of a log that is shown in Settings.
Map<String, Object?> _boundedFields(Map<String, Object?> input) {
  final output = <String, Object?>{};
  for (final entry in input.entries.take(16)) {
    if (!_codePattern.hasMatch(entry.key) || entry.key.length > 40) continue;
    final value = entry.value;
    if (value == null || (value is num && value.isFinite) || value is bool) {
      output[entry.key] = value;
    } else if (value is String) {
      output[entry.key] = _oneLine(value, 80);
    }
  }
  return output;
}
