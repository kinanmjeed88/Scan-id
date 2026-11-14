/// One image's audited journey: from the moment it was picked to the moment it
/// (or its refusal) reached the A4 sheet.
///
/// This is a report for the person using the app, built ONLY from facts the
/// pipeline already persisted: the imported asset, the saved document record,
/// the recorded boundary decision, the classification confidence and the layout
/// item. Nothing is estimated to fill a gap, and no recognized text is stored —
/// a step names the stage that decided, never the content that was read. That
/// is what makes the log safe to keep beside the project and safe to show in
/// Settings.
///
/// The model is deliberately pure Dart: it validates itself, round-trips
/// through JSON, and knows nothing about widgets, files or the pipeline.
library;

import 'validation.dart';

/// One stage of the intake path.
///
/// Declaration order is the pipeline's order, because a report is read top to
/// bottom. A stage that did not run is still reported in its place — a missing
/// row would look like an omission, while «لم تُنفَّذ» states the fact.
enum JourneyStage {
  selection('اختيار الصورة'),
  copy('نسخ الصورة إلى المشروع'),
  detection('كشف الحدود'),
  crop('القص والتقويم'),
  recognition('قراءة النص وتحديد النوع'),
  sizing('تأكيد المقاس'),
  placement('الإضافة إلى ورقة A4'),
  save('حفظ المشروع');

  const JourneyStage(this.label);

  /// The Arabic title shown beside the stage in the report.
  final String label;

  /// Parses a persisted stage name; null for anything unknown, so a log
  /// written by a different build can be read without being trusted blindly.
  static JourneyStage? byName(Object? name) {
    for (final stage in values) {
      if (stage.name == name) return stage;
    }
    return null;
  }
}

/// How one stage ended.
enum JourneyOutcome {
  passed('تمّت'),
  review('تحتاج مراجعة'),
  blocked('تعذّرت'),
  skipped('لم تُنفَّذ');

  const JourneyOutcome(this.label);

  /// The Arabic word shown on the stage's status pill.
  final String label;

  /// Whether this outcome means a human still has work to do on the image.
  bool get needsAttention => this == review || this == blocked;

  static JourneyOutcome? byName(Object? name) {
    for (final outcome in values) {
      if (outcome.name == name) return outcome;
    }
    return null;
  }
}

/// One recorded stage: what happened, how it ended, and why.
class JourneyStep {
  JourneyStep({
    required this.stage,
    required this.outcome,
    required this.detail,
    this.durationMs,
    Map<String, Object?> fields = const {},
  }) : fields = Map.unmodifiable(fields) {
    require(
      detail.isNotEmpty && detail.length <= maxDetailLength,
      'تفصيل المرحلة يجب أن يكون نصاً قصيراً غير فارغ.',
    );
    require(
      !detail.contains('\n') && !detail.contains('\r'),
      'تفصيل المرحلة يجب أن يكون سطراً واحداً.',
    );
    if (durationMs != null) {
      require(
        durationMs! >= 0 && durationMs! <= maxDurationMs,
        'مدة المرحلة خارج المجال المعقول.',
      );
    }
    for (final entry in this.fields.entries) {
      require(
        maxFieldKeyLength >= entry.key.length && entry.key.isNotEmpty,
        'مفتاح حقل التشخيص غير صالح.',
      );
      final value = entry.value;
      require(
        value == null || value is num || value is bool || value is String,
        'قيمة حقل التشخيص يجب أن تكون رقماً أو نصاً أو منطقياً.',
      );
      if (value is String) {
        require(
          value.length <= maxFieldValueLength && !value.contains('\n'),
          'قيمة حقل التشخيص طويلة أو متعددة الأسطر.',
        );
      }
    }
  }

  /// Machine-readable decision facts that MUST survive verbatim.
  ///
  /// [detail] is a user-facing sentence and is clipped at [maxDetailLength];
  /// a decision's numbers and codes must never depend on that sentence. Keys
  /// and values are bounded so a caller cannot smuggle recognized text, a path
  /// or a person's data into the log: every producer here emits dictionary
  /// codes, enum names and measured numbers only.
  final Map<String, Object?> fields;

  static const int maxFieldKeyLength = 32;
  static const int maxFieldValueLength = 64;

  /// Longest detail a step may carry: a sentence, not a transcript.
  static const int maxDetailLength = 240;

  /// One hour, in milliseconds. Longer than any single image's stage.
  static const int maxDurationMs = 3600000;

  final JourneyStage stage;
  final JourneyOutcome outcome;

  /// An Arabic sentence derived from recorded evidence. Never recognized text,
  /// never a person's data, never a raw exception message.
  final String detail;

  /// Measured time for this stage when the caller actually measured it; null
  /// otherwise. A missing duration is reported as unknown, never as zero.
  final int? durationMs;

  Map<String, Object?> toJson() => {
    'stage': stage.name,
    'outcome': outcome.name,
    'detail': detail,
    if (durationMs != null) 'duration_ms': durationMs,
    // Omitted when empty so an older reader sees exactly the document it
    // already knows. Adding an optional key is a backward-compatible change
    // inside schema version 1: old entries simply have no `fields`.
    if (fields.isNotEmpty) 'fields': fields,
  };

  static JourneyStep fromJson(Object? json) {
    final map = objectMap(json);
    final stage = JourneyStage.byName(map['stage']);
    final outcome = JourneyOutcome.byName(map['outcome']);
    require(stage != null, 'مرحلة السجل غير معروفة.');
    require(outcome != null, 'نتيجة المرحلة غير معروفة.');
    final duration = map['duration_ms'] == null
        ? null
        : integer(map['duration_ms'], 'duration_ms');
    final rawFields = map['fields'];
    final fields = <String, Object?>{};
    if (rawFields != null) {
      for (final entry in objectMap(rawFields).entries) {
        final value = entry.value;
        require(
          value == null || value is num || value is bool || value is String,
          'قيمة حقل التشخيص في السجل غير صالحة.',
        );
        fields[entry.key] = value;
      }
    }
    return JourneyStep(
      stage: stage!,
      outcome: outcome!,
      detail: text(map['detail'], 'detail'),
      durationMs: duration,
      fields: fields,
    );
  }
}

/// A persisted intake checkpoint. Older reports have no lifecycle value.
enum JourneyLifecycle { created, processing, reviewRequired, completed, failed }

/// The complete reported path of ONE picked image.
class ImageJourney {
  ImageJourney({
    required this.id,
    required this.batchId,
    required this.projectId,
    required this.projectName,
    required this.imageName,
    required this.startedAt,
    required List<JourneyStep> steps,
    this.sheetRevision,
    this.lifecycle,
  }) : steps = List.unmodifiable(steps) {
    require(id.length >= 8 && id.length <= 160, 'معرّف رحلة الصورة غير صالح.');
    require(
      batchId.length >= 8 && batchId.length <= 160,
      'معرّف دفعة الاستيراد غير صالح.',
    );
    require(
      imageName.isNotEmpty && imageName.length <= maxNameLength,
      'اسم الصورة في السجل غير صالح.',
    );
    require(
      !imageName.contains('\n') && !imageName.contains('\r'),
      'اسم الصورة في السجل يجب أن يكون سطراً واحداً.',
    );
    require(
      projectName.isEmpty || projectName.length <= maxNameLength,
      'اسم المشروع في السجل غير صالح.',
    );
    require(
      this.steps.isNotEmpty && this.steps.length <= maxSteps,
      'عدد مراحل السجل غير صالح.',
    );
    for (var index = 1; index < this.steps.length; index++) {
      require(
        this.steps[index].stage.index >= this.steps[index - 1].stage.index,
        'مراحل السجل يجب أن تُسرد بترتيب المسار.',
      );
    }
    if (sheetRevision != null) {
      require(sheetRevision! >= 0, 'رقم مراجعة المشروع غير صالح.');
    }
  }

  /// A log entry never carries more stages than the pipeline has, even if a
  /// future build recorded the same stage for several detected regions.
  static const int maxSteps = 24;

  /// Longest image or project name an entry holds, in UTF-16 code units. It
  /// is deliberately above the 160 an imported image may carry, because a
  /// source that was REFUSED for its name is still reported under that name;
  /// whoever builds an entry shortens anything longer.
  static const int maxNameLength = 200;

  /// Current on-disk shape. Bumped only for an incompatible change.
  static const int schemaVersion = 1;

  /// Deterministic identifier (`batchId:imageKey`), so writing the same run
  /// twice cannot duplicate an entry.
  final String id;
  final String batchId;
  final String projectId;
  final String projectName;
  final String imageName;

  /// When the image was picked, in UTC with an explicit offset on disk.
  final DateTime startedAt;

  /// The stages, in pipeline order, one entry per stage that was reported.
  final List<JourneyStep> steps;

  /// The saved project revision this report describes, when the run committed.
  final int? sheetRevision;

  /// Null for reports written before lifecycle checkpoints were introduced.
  final JourneyLifecycle? lifecycle;

  ImageJourney withLifecycle(JourneyLifecycle value) => ImageJourney(
    id: id,
    batchId: batchId,
    projectId: projectId,
    projectName: projectName,
    imageName: imageName,
    startedAt: startedAt,
    sheetRevision: sheetRevision,
    steps: steps,
    lifecycle: value,
  );

  /// Whether the source was copied into the project at all.
  bool get imported => _outcomeOf(JourneyStage.copy) == JourneyOutcome.passed;

  /// Whether the placement stage reports all items on the sheet. A partially
  /// placed multi-document image remains in review.
  bool get placedOnSheet =>
      _outcomeOf(JourneyStage.placement) == JourneyOutcome.passed;

  /// The single line that summarises the whole journey.
  String get conclusion {
    if (lifecycle == JourneyLifecycle.created) return 'بانتظار المعالجة';
    if (lifecycle == JourneyLifecycle.processing) {
      return 'بدأت المعالجة ولم تكتمل';
    }
    if (lifecycle == JourneyLifecycle.failed && !imported) {
      return 'تعذرت المعالجة';
    }
    if (!imported) return 'لم تُستورد';
    if (_outcomeOf(JourneyStage.save) == JourneyOutcome.skipped) {
      return 'لم يُحفظ المشروع بعد المعالجة';
    }
    if (placedOnSheet) return 'أُضيفت إلى الورقة';
    for (final step in steps) {
      if (step.stage == JourneyStage.placement &&
          step.outcome == JourneyOutcome.review &&
          step.fields['placedItems'] is int &&
          (step.fields['placedItems'] as int) > 0) {
        return 'أُضيف بعضها إلى الورقة وبقي بعضها للمراجعة';
      }
    }
    if (_outcomeOf(JourneyStage.placement) == JourneyOutcome.blocked) {
      return 'بقيت خارج الورقة';
    }
    return 'بقيت للمراجعة اليدوية';
  }

  /// The overall verdict: the worst thing that happened, so a summary can be
  /// coloured without re-reading every step.
  JourneyOutcome get verdict {
    if (lifecycle == JourneyLifecycle.created ||
        lifecycle == JourneyLifecycle.processing) {
      return JourneyOutcome.review;
    }
    if (placedOnSheet &&
        _outcomeOf(JourneyStage.save) != JourneyOutcome.skipped &&
        steps.every((step) => !step.outcome.needsAttention)) {
      return JourneyOutcome.passed;
    }
    if (!imported) return JourneyOutcome.blocked;
    return JourneyOutcome.review;
  }

  /// The first step that still needs a human, or null when nothing does.
  JourneyStep? get firstConcern {
    for (final step in steps) {
      if (step.outcome.needsAttention ||
          (step.stage == JourneyStage.save &&
              step.outcome == JourneyOutcome.skipped)) {
        return step;
      }
    }
    return null;
  }

  JourneyOutcome? _outcomeOf(JourneyStage stage) {
    for (final step in steps) {
      if (step.stage == stage) return step.outcome;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'id': id,
    'batch': batchId,
    'project': {'id': projectId, 'name': projectName},
    'image': imageName,
    'started_utc': startedAt.toUtc().toIso8601String(),
    if (lifecycle != null) 'lifecycle': lifecycle!.name,
    if (sheetRevision != null) 'revision': sheetRevision,
    'steps': [for (final step in steps) step.toJson()],
  };

  /// Parses one persisted entry. Throws [ValidationException] on a shape this
  /// build cannot trust; the store drops that entry instead of failing a read.
  static ImageJourney fromJson(Object? json) {
    final map = objectMap(json);
    final version = integer(map['version'], 'version');
    require(version == schemaVersion, 'نسخة سجل غير مدعومة.');
    final project = objectMap(map['project']);
    final started = DateTime.tryParse(text(map['started_utc'], 'started_utc'));
    require(started != null, 'وقت بدء السجل غير صالح.');
    JourneyLifecycle? lifecycle;
    if (map['lifecycle'] != null) {
      final name = text(map['lifecycle'], 'lifecycle');
      for (final value in JourneyLifecycle.values) {
        if (value.name == name) lifecycle = value;
      }
      require(lifecycle != null, 'حالة رحلة غير مدعومة.');
    }
    return ImageJourney(
      lifecycle: lifecycle,
      id: text(map['id'], 'id'),
      batchId: text(map['batch'], 'batch'),
      projectId: text(project['id'], 'project.id'),
      projectName: text(project['name'], 'project.name'),
      imageName: text(map['image'], 'image'),
      startedAt: started!.toUtc(),
      sheetRevision: map['revision'] == null
          ? null
          : integer(map['revision'], 'revision'),
      steps: [
        for (final entry in objectList(map['steps']))
          JourneyStep.fromJson(entry),
      ],
    );
  }
}
