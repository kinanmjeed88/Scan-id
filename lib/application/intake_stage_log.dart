import '../domain/image_journey.dart';
import '../domain/intake_options.dart';

/// One stage of one image's intake, as the pipeline actually ran it.
///
/// This is the working record the pipeline fills in while it processes an image;
/// [ImageJourney] is what it becomes once filed. Keeping them separate matters:
/// a stage is appended the moment it finishes, so if a later stage throws, the
/// stages that DID run are still reportable. Building the whole report at the
/// end would lose exactly the evidence needed when something fails.
///
/// Never carries recognized text, a path or a person's data: [fields] holds
/// dictionary codes, enum names and measured numbers only.
class IntakeStageRecord {
  IntakeStageRecord({
    required this.stage,
    required this.outcome,
    required this.detail,
    this.durationMs,
    Map<String, Object?> fields = const {},
  }) : fields = Map.unmodifiable(fields);

  final JourneyStage stage;
  final JourneyOutcome outcome;
  final String detail;
  final int? durationMs;
  final Map<String, Object?> fields;

  bool get failed => outcome == JourneyOutcome.blocked;

  JourneyStep toStep() => JourneyStep(
    stage: stage,
    outcome: outcome,
    detail: detail,
    durationMs: durationMs?.clamp(0, JourneyStep.maxDurationMs),
    fields: {
      for (final entry in fields.entries)
        if (entry.key.length <= JourneyStep.maxFieldKeyLength)
          entry.key:
              entry.value is String &&
                  (entry.value! as String).length >
                      JourneyStep.maxFieldValueLength
              ? (entry.value! as String).substring(
                  0,
                  JourneyStep.maxFieldValueLength,
                )
              : entry.value,
    },
  );
}

/// The stage-by-stage record of ONE image, in pipeline order.
///
/// The rule enforced here is the one the request states: every stage the image
/// passes through is recorded, and a stage that failed says so with its cause.
/// A stage is never silently omitted — [stepFor] decides what a stage the
/// pipeline never reached is called, and it is never «تمّت».
class IntakeStageLog {
  IntakeStageLog({required this.assetId, this.assetName = ''});

  final String assetId;

  /// The display name, for the report only. Never written to [fields].
  final String assetName;

  final List<IntakeStageRecord> _records = [];
  final Map<String, String> _failures = {};

  List<IntakeStageRecord> get records => List.unmodifiable(_records);

  /// Every stage that ended in failure or in review, in order.
  List<IntakeStageRecord> get problems => [
    for (final record in _records)
      if (record.outcome == JourneyOutcome.blocked ||
          record.outcome == JourneyOutcome.review)
        record,
  ];

  /// Whether anything actually failed (not merely needs review).
  bool get hasFailure => _records.any((record) => record.failed);

  /// Records a stage. Later calls for the same stage replace the earlier one,
  /// so a retry reports its final outcome rather than a stale failure.
  void record(IntakeStageRecord entry) {
    _records.removeWhere((existing) => existing.stage == entry.stage);
    _records.add(entry);
    _records.sort((a, b) => a.stage.index.compareTo(b.stage.index));
    if (entry.failed) {
      _failures[entry.stage.name] = entry.detail;
    } else {
      _failures.remove(entry.stage.name);
    }
  }

  /// Records a stage that could not run, with the reason.
  void block(
    JourneyStage stage,
    String reason, {
    Map<String, Object?> fields = const {},
  }) => record(
    IntakeStageRecord(
      stage: stage,
      outcome: JourneyOutcome.blocked,
      detail: reason,
      fields: fields,
    ),
  );

  /// Records a stage that ran but routed the image to a human.
  void review(
    JourneyStage stage,
    String reason, {
    Map<String, Object?> fields = const {},
  }) => record(
    IntakeStageRecord(
      stage: stage,
      outcome: JourneyOutcome.review,
      detail: reason,
      fields: fields,
    ),
  );

  /// Records a stage that completed.
  void pass(
    JourneyStage stage,
    String detail, {
    int? durationMs,
    Map<String, Object?> fields = const {},
  }) => record(
    IntakeStageRecord(
      stage: stage,
      outcome: JourneyOutcome.passed,
      detail: detail,
      durationMs: durationMs,
      fields: fields,
    ),
  );

  /// What a stage that never ran is reported as.
  ///
  /// [because] must name the earlier stage that stopped it, so a reader can
  /// follow the chain instead of seeing an unexplained gap.
  IntakeStageRecord notReached(JourneyStage stage, String because) =>
      IntakeStageRecord(
        stage: stage,
        outcome: JourneyOutcome.skipped,
        detail: because,
      );

  /// The first stage that failed, or null when none did.
  IntakeStageRecord? get firstFailure =>
      _records.where((record) => record.failed).firstOrNull;

  /// The failure cause recorded for [stage], if any.
  String? failureReason(JourneyStage stage) => _failures[stage.name];

  /// The complete journey in pipeline order, filling in stages that never ran.
  ///
  /// Filling them is deliberate: a missing row would read as an omission, while
  /// «لم تُنفَّذ» states the fact and names the stage that stopped it.
  List<JourneyStep> toSteps() {
    final recorded = {for (final record in _records) record.stage: record};
    final firstBlocked = firstFailure;
    return [
      for (final stage in JourneyStage.values)
        if (recorded[stage] != null)
          recorded[stage]!.toStep()
        else
          notReached(
            stage,
            firstBlocked == null
                ? 'لم تصل الصورة إلى هذه المرحلة.'
                : 'لم تُنفَّذ لأن مرحلة «${firstBlocked.stage.label}» تعذّرت.',
          ).toStep(),
    ];
  }

  /// A one-line summary of what went wrong, or null when nothing did.
  ///
  /// Built from the recorded stages only; it never invents a cause.
  String? get failureSummary {
    final failures = [
      for (final record in _records)
        if (record.failed) '${record.stage.label}: ${record.detail}',
    ];
    if (failures.isEmpty) return null;
    return failures.join(' · ');
  }
}

/// The batch-wide record: one [IntakeStageLog] per asset, plus the options the
/// person chose for the batch.
///
/// Answers «which image failed, at which stage, and why» for the whole run,
/// which a per-image log alone cannot do when the failure is in a batch stage
/// such as arrangement.
class IntakeBatchLog {
  IntakeBatchLog({required this.batchId, this.options});

  final String batchId;

  /// The options the person chose for this batch, or null when they were not
  /// offered any (a retry, a repair pass, or a caller that has no UI).
  final IntakeOptions? options;

  final Map<String, IntakeStageLog> _byAsset = {};
  String? _batchFailure;
  JourneyStage? _batchFailureStage;

  IntakeStageLog forAsset(String assetId, {String name = ''}) =>
      _byAsset.putIfAbsent(
        assetId,
        () => IntakeStageLog(assetId: assetId, assetName: name),
      );

  /// Records that a stage covering the WHOLE batch failed, e.g. arrangement.
  ///
  /// Attributed to every image that had already been logged: the failure
  /// genuinely affects all of them, and hiding it inside the pipeline's return
  /// value is what made these failures invisible before.
  void failBatch(JourneyStage stage, String reason) {
    _batchFailure = reason;
    _batchFailureStage = stage;
    for (final log in _byAsset.values) {
      log.block(stage, reason);
    }
  }

  String? get batchFailure => _batchFailure;
  JourneyStage? get batchFailureStage => _batchFailureStage;

  Iterable<IntakeStageLog> get logs => _byAsset.values;

  /// Every asset whose log records a failure.
  Iterable<IntakeStageLog> get failed =>
      _byAsset.values.where((log) => log.hasFailure);

  /// Assets that need a human, whether through failure or review.
  Iterable<IntakeStageLog> get needingAttention =>
      _byAsset.values.where((log) => log.problems.isNotEmpty);

  /// The batch verdict for a summary banner.
  String get summary {
    if (_byAsset.isEmpty) return 'لم تُعالَج أي صورة.';
    final failures = failed.length;
    final attention = needingAttention.length;
    if (failures > 0) {
      return 'تعذّرت معالجة $failures من ${_byAsset.length} صورة؛ '
          'التفصيل في سجل المعالجة.';
    }
    if (attention > 0) {
      return 'تحتاج $attention من ${_byAsset.length} صورة إلى مراجعة؛ '
          'التفصيل في سجل المعالجة.';
    }
    return 'اكتملت معالجة ${_byAsset.length} صورة بلا فشل.';
  }
}
