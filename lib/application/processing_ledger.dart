/// The writer of the processing record: it measures each stage, verifies the
/// result before calling it successful, records every bypass with the decision
/// that caused it, and emits each event to a journal as it happens.
///
/// The two rules this class exists to enforce:
///
/// 1. **No false success.** A stage returns «ناجحة» only through
///    [succeeded] or a [run] whose caller supplied a verification predicate
///    that actually passed. Not throwing is never enough.
/// 2. **No silent gap.** A stage the pipeline never reached is reported as
///    «لم تُنفَّذ» or «متوقفة» with the stage that stopped it named, and a
///    stage bypassed by a user choice is reported as «تم التجاوز» with that
///    choice named.
///
/// Every event is handed to [ProcessingJournalSink.add] the moment it happens,
/// so a crash mid-processing still leaves the stages that DID run on disk.
library;

import '../domain/document_kind.dart';
import '../domain/intake_options.dart';
import '../domain/processing_record.dart';
import '../domain/recognition.dart' show SideKind;

/// Receives one already-sanitized event. Implementations must never throw and
/// must never make the caller wait: this is diagnostics, not the result.
abstract interface class ProcessingJournalSink {
  void add(Map<String, Object?> event);
}

/// The durable, readable side of the journal: what the UI and an export use.
///
/// [ProcessingJournalSink] is the write path the pipeline touches; this is the
/// read path, kept separate so a host can provide one without the other.
abstract interface class ProcessingJournal implements ProcessingJournalSink {
  /// Newest operation first. Never throws because of unreadable content.
  Future<List<ProcessingReport>> reports();

  Future<ProcessingReport?> latest();

  Future<ProcessingReport?> reportFor(String operationId);

  /// Removes the journal files only. Projects are untouched.
  Future<void> clear();
}

/// Stable failure categories, so a report can be grouped without parsing a
/// sentence and without recording an arbitrary exception message.
class FailureCode {
  const FailureCode._();

  static const cancelled = 'cancelled';
  static const timeout = 'timeout';
  static const validation = 'validation';
  static const storage = 'storage';
  static const revisionConflict = 'revision_conflict';
  static const platform = 'platform';
  static const resultUnverified = 'result_unverified';
  static const noSource = 'no_source';
  static const unknown = 'unknown';

  /// The category of [error] from its runtime type only.
  ///
  /// Deliberately does not read `toString()` of an arbitrary object: that can
  /// carry a file path, a file name or a request URL, and this record lives on
  /// the device and is shown in Settings.
  static String of(Object? error) {
    if (error == null) return unknown;
    final type = error.runtimeType.toString();
    if (type == 'OperationCancelled') return cancelled;
    if (type == 'StageTimeout' || type == 'TimeoutException') return timeout;
    if (type == 'ValidationException') return validation;
    if (type == 'RevisionConflict') return revisionConflict;
    if (type == 'StorageException' || type == 'FileSystemException') {
      return storage;
    }
    if (type == 'PlatformException' ||
        type == 'MissingPluginException' ||
        type == 'UnsupportedError') {
      return platform;
    }
    return unknown;
  }
}

/// A bounded, path-free description of a caught error.
///
/// Names the runtime type — which is what tells a decode failure from a write
/// failure — and reuses a `StateError` message only when it is short, single
/// line and contains no path separator. It never returns `toString()` of an
/// arbitrary exception.
String describeFailure(Object? error) {
  if (error == null) return 'سبب غير محدد';
  final type = error.runtimeType.toString();
  final raw = error is StateError ? error.message : null;
  final message = raw?.trim() ?? '';
  final safe =
      message.isNotEmpty &&
      message.length <= 120 &&
      !message.contains('\n') &&
      !message.contains('\r') &&
      !message.contains('/') &&
      !message.contains('\\');
  return safe ? '$type: $message' : type;
}

typedef ProcessingClock = DateTime Function();

/// The per-operation recorder.
class ProcessingLedger {
  ProcessingLedger({
    required this.operationId,
    required this.projectId,
    required String projectName,
    this.options,
    this.sink,
    ProcessingClock? clock,
  }) : projectName = sanitizeProcessingText(projectName, maxLength: 200),
       _clock = clock ?? DateTime.now {
    startedAt = _clock().toUtc();
    _emit({
      'event': 'batch',
      'operation': operationId,
      'batch': operationId,
      'project': projectId,
      'project_name': this.projectName,
      'started_utc': startedAt.toIso8601String(),
      if (options != null) 'options': options!.traceCodes.toList(),
    });
  }

  final String operationId;
  final String projectId;
  final String projectName;
  final IntakeOptions? options;
  final ProcessingJournalSink? sink;
  final ProcessingClock _clock;
  late final DateTime startedAt;

  final Map<String, ImageProcessingLog> _images = {};
  final List<String> _warnings = [];
  StageRecord? _batchStop;
  bool _finalised = false;
  ProcessingReport? _report;
  int _eventSequence = 0;

  bool get finalised => _finalised;

  /// The report of the run that was finalised, or a live snapshot.
  ProcessingReport get report => _report ?? _snapshot(finalised: false);

  ImageProcessingLog image(
    String imageId, {
    String name = '',
    int? width,
    int? height,
  }) {
    var existing = _images[imageId];
    if (existing != null) {
      if (existing.imageName.isEmpty && name.isNotEmpty) {
        existing = ImageProcessingLog(
          operationId: operationId,
          imageId: imageId,
          imageName: name,
          startedAt: existing.startedAt,
          sourceWidth: existing.sourceWidth ?? width,
          sourceHeight: existing.sourceHeight ?? height,
          stages: existing.stages,
          documents: existing.documents,
          warnings: existing.warnings,
          endedAt: existing.endedAt,
          outcomeOverride: existing.outcomeOverride,
        );
        _images[imageId] = existing;
        _emit({
          'event': 'image_name',
          'image': imageId,
          'name': existing.imageName,
        });
      }
      return existing;
    }
    final created = ImageProcessingLog(
      operationId: operationId,
      imageId: imageId,
      imageName: name,
      sourceWidth: width,
      sourceHeight: height,
      startedAt: _clock().toUtc(),
    );
    _images[imageId] = created;
    _emit({
      'event': 'image',
      'image': imageId,
      'name': created.imageName,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      'started_utc': created.startedAt.toIso8601String(),
    });
    return created;
  }

  ImageProcessingLog? existingImage(String imageId) => _images[imageId];

  /// Moves the record collected under a provisional id onto the id the
  /// repository actually created.
  ///
  /// The import pipeline knows the source the moment it is read, but the asset
  /// id only after the repository writes the files. Recording the early stages
  /// under a provisional id keeps them on disk if the decode dies, and this
  /// rename re-attaches them to the real asset before any document exists, so
  /// the report still holds ONE record per image.
  void rekeyImage(String from, String to, {int? width, int? height}) {
    if (from == to) {
      image(to, width: width, height: height);
      return;
    }
    final parent = _images.remove(from);
    if (parent == null) {
      image(to, width: width, height: height);
      _emit({'event': 'image_rekey', 'from': from, 'to': to});
      return;
    }
    final target = _images[to];
    if (target != null) {
      // The real id already exists: keep its records and fill the gaps from
      // the provisional one. Never duplicate a stage that is already there.
      for (final record in parent.stages) {
        if (target.stageOf(record.stage) == null) {
          target.record(record);
          _emitStage(target, record);
        }
      }
      for (final warning in parent.warnings) {
        target.addWarning(warning);
      }
      _emit({'event': 'image_rekey', 'from': from, 'to': to});
      return;
    }
    if (parent.documents.isNotEmpty) {
      // Documents carry their own image id; re-keying them here would rewrite
      // an already-linked record. This method is for the pre-document window
      // of the import only.
      throw StateError('rekeyImage is only valid before documents exist');
    }
    final moved = ImageProcessingLog(
      operationId: parent.operationId,
      imageId: to,
      imageName: parent.imageName,
      sourceWidth: width ?? parent.sourceWidth,
      sourceHeight: height ?? parent.sourceHeight,
      startedAt: parent.startedAt,
      stages: parent.stages,
      warnings: parent.warnings,
      endedAt: parent.endedAt,
      outcomeOverride: parent.outcomeOverride,
    );
    _images[to] = moved;
    _emit({
      'event': 'image_rekey',
      'from': from,
      'to': to,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
    });
  }

  Iterable<ImageProcessingLog> get images => _images.values;

  /// Records a warning against one image, and in the batch's own list.
  void warn(String imageId, String message) {
    final parent = image(imageId);
    final safe = parent.addWarning(message);
    if (safe.isEmpty) return;
    _emit({'event': 'warning', 'image': imageId, 'message': safe});
    warnBatch(safe);
  }

  /// Records a warning that belongs to the batch as a whole rather than one
  /// image (for example, an intake notice or an arrangement summary).
  void warnBatch(String message) {
    final safe = sanitizeProcessingText(
      message,
      maxLength: StageRecord.maxReasonLength,
    );
    if (safe.isEmpty || _warnings.contains(safe) || _warnings.length >= 50) {
      return;
    }
    _warnings.add(safe);
    _emit({'event': 'warning', 'message': safe});
  }

  /// Starts a stage and records it as «قيد التنفيذ».
  StageRecord running(
    String imageId,
    ProcessingStage stage, {
    Map<String, Object?> inputs = const {},
    String reason = 'المرحلة قيد التنفيذ.',
  }) => _record(
    imageId,
    StageRecord(
      stage: stage,
      status: StageStatus.running,
      reason: reason,
      startedAt: _clock().toUtc(),
      inputs: inputs,
    ),
  );

  /// Records a stage that completed AND whose result was verified.
  StageRecord succeeded(
    String imageId,
    ProcessingStage stage, {
    required String reason,
    required StageEvidence evidence,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> results = const {},
    int? itemCount,
    int? durationMs,
    DateTime? startedAt,
    DateTime? endedAt,
    String actionTaken = '',
  }) {
    final end = (endedAt ?? _clock()).toUtc();
    final start = startedAt?.toUtc() ?? _deriveStart(end, durationMs);
    if (!evidence.supportsSuccess) {
      // The caller supplied a verification or check that did NOT pass. Recording this
      // as success would be the exact false claim this ledger exists to
      // prevent, so it is recorded as a failure with the evidence attached.
      return failed(
        imageId,
        stage,
        reason: '$reason — لم يتحقق شرط النتيجة.',
        inputs: inputs,
        results: results,
        itemCount: itemCount,
        durationMs: durationMs,
        startedAt: start,
        endedAt: end,
        errorType: 'UnverifiedResult',
        errorCode: FailureCode.resultUnverified,
        diagnostics: [
          if (!evidence.verified) 'verify_predicate_returned_false',
          if (evidence.verified) 'evidence_check_failed',
        ],
        actionTaken: actionTaken,
        evidence: evidence.asUnverified(),
      );
    }
    return _record(
      imageId,
      StageRecord(
        stage: stage,
        status: StageStatus.succeeded,
        reason: reason,
        startedAt: start,
        endedAt: end,
        durationMs: durationMs,
        inputs: inputs,
        results: results,
        itemCount: itemCount,
        actionTaken: actionTaken,
        evidence: evidence,
      ),
    );
  }

  /// Records a stage that was attempted and did not achieve its result.
  ///
  /// [error] supplies the runtime type and the stable code; [reason] may state
  /// the cause in Arabic when the caller knows it. When neither makes the cause
  /// certain, the record says so instead of inventing one.
  StageRecord failed(
    String imageId,
    ProcessingStage stage, {
    Object? error,
    String? reason,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> results = const {},
    int? itemCount,
    int? durationMs,
    DateTime? startedAt,
    DateTime? endedAt,
    String? errorType,
    String? errorCode,
    List<String> diagnostics = const [],
    String actionTaken = '',
    StageEvidence? evidence,
  }) {
    final type = errorType ?? error?.runtimeType.toString();
    final code = errorCode ?? FailureCode.of(error);
    final cause = reason ?? 'تعذّرت المرحلة: ${describeFailure(error)}';
    final notes = [...diagnostics];
    if (cause.isEmpty) {
      notes.add(StageRecord.undeterminedCause);
    }
    if (notes.isEmpty && type == null) {
      notes.add(StageRecord.undeterminedCause);
    }
    final end = (endedAt ?? _clock()).toUtc();
    final start = startedAt?.toUtc() ?? _deriveStart(end, durationMs);
    return _record(
      imageId,
      StageRecord(
        stage: stage,
        status: StageStatus.failed,
        reason: cause,
        startedAt: start,
        endedAt: end,
        durationMs: durationMs,
        inputs: inputs,
        results: results,
        itemCount: itemCount,
        errorType: type,
        errorCode: code,
        diagnostics: notes,
        actionTaken: actionTaken,
        evidence: evidence,
      ),
    );
  }

  /// Records a stage bypassed by a choice or a routing rule.
  StageRecord overridden(
    String imageId,
    ProcessingStage stage, {
    required String reason,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> results = const {},
    int? itemCount,
    String actionTaken = '',
  }) => _record(
    imageId,
    StageRecord(
      stage: stage,
      status: StageStatus.overridden,
      reason: reason,
      inputs: inputs,
      results: results,
      itemCount: itemCount,
      actionTaken: actionTaken,
    ),
  );

  /// Records a stage that does not apply to the current route at all.
  StageRecord notApplicable(
    String imageId,
    ProcessingStage stage, {
    required String reason,
    Map<String, Object?> inputs = const {},
    String actionTaken = '',
  }) => _record(
    imageId,
    StageRecord(
      stage: stage,
      status: StageStatus.notApplicable,
      reason: reason,
      inputs: inputs,
      actionTaken: actionTaken,
    ),
  );

  /// Records a stage the process began and then abandoned before finishing.
  StageRecord stopped(
    String imageId,
    ProcessingStage stage, {
    required String reason,
    Map<String, Object?> inputs = const {},
    String actionTaken = '',
  }) => _record(
    imageId,
    StageRecord(
      stage: stage,
      status: StageStatus.stopped,
      reason: reason,
      inputs: inputs,
      actionTaken: actionTaken,
    ),
  );

  StageRecord cancelled(
    String imageId,
    ProcessingStage stage, {
    required String reason,
    Map<String, Object?> inputs = const {},
    String actionTaken = 'أُوقفت المرحلة عند أول نقطة آمنة.',
    DateTime? startedAt,
    DateTime? endedAt,
    int? durationMs,
  }) {
    final end = (endedAt ?? _clock()).toUtc();
    return _record(
      imageId,
      StageRecord(
        stage: stage,
        status: StageStatus.cancelled,
        reason: reason,
        startedAt: startedAt?.toUtc() ?? _deriveStart(end, durationMs),
        endedAt: end,
        durationMs: durationMs,
        inputs: inputs,
        errorType: 'OperationCancelled',
        errorCode: FailureCode.cancelled,
        diagnostics: const ['operation_cancelled'],
        actionTaken: actionTaken,
      ),
    );
  }

  /// Runs [action] as [stage], measuring it and VERIFYING its result.
  ///
  /// When [verify] returns false the stage is recorded as failed — even though
  /// no exception was thrown — and the value is still returned so the caller
  /// can fall back. When [action] throws, its failure (or cancellation) is
  /// recorded and rethrown.
  Future<T> run<T>(
    String imageId,
    ProcessingStage stage,
    Future<T> Function() action, {
    required bool Function(T value) verify,
    required String successReason,
    String? failureReason,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> Function(T value)? results,
    int Function(T value)? items,
    List<EvidenceCheck> Function(T value)? checks,
    String successNote = '',
    String actionTaken = '',
    String failureAction = '',
  }) async {
    final startedAt = _clock().toUtc();
    final watch = Stopwatch()..start();
    running(imageId, stage, inputs: inputs);
    try {
      final value = await action();
      final measured = results?.call(value) ?? const <String, Object?>{};
      final count = items?.call(value);
      final evidenceChecks = checks?.call(value) ?? const <EvidenceCheck>[];
      final predicatePassed = verify(value);
      final checksPassed = evidenceChecks.every((check) => check.passed);
      final evidenceMeasured = evidenceChecks.isNotEmpty || count != null;
      final verified = predicatePassed && checksPassed && evidenceMeasured;
      final evidence = StageEvidence(
        verified: verified,
        note: successNote,
        checks: evidenceChecks,
        counts: evidenceChecks.isEmpty && count != null
            ? {'items': count}
            : const {},
      );
      if (verified) {
        succeeded(
          imageId,
          stage,
          reason: successReason,
          evidence: evidence,
          inputs: inputs,
          results: measured,
          itemCount: count,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          actionTaken: actionTaken,
        );
      } else {
        failed(
          imageId,
          stage,
          reason:
              failureReason ??
              'اكتمل استدعاء المرحلة لكن ناتجها لم يحقق الشرط المطلوب.',
          inputs: inputs,
          results: measured,
          itemCount: count,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          errorType: 'UnverifiedResult',
          errorCode: FailureCode.resultUnverified,
          diagnostics: [
            if (!predicatePassed) 'verify_predicate_returned_false',
            if (!checksPassed) 'evidence_check_failed',
            if (!evidenceMeasured) 'evidence_measurement_missing',
          ],
          actionTaken: failureAction,
          evidence: evidence.asUnverified(),
        );
      }
      return value;
    } catch (error) {
      if (FailureCode.of(error) == FailureCode.cancelled) {
        cancelled(
          imageId,
          stage,
          reason: 'أُلغيت المرحلة عند أول نقطة آمنة.',
          inputs: inputs,
          actionTaken: failureAction.isEmpty
              ? 'أُوقفت المرحلة عند أول نقطة آمنة.'
              : failureAction,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
        );
      } else {
        failed(
          imageId,
          stage,
          error: error,
          inputs: inputs,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          actionTaken: failureAction,
        );
      }
      rethrow;
    }
  }

  /// Synchronous counterpart of [run], for CPU-only stages (geometry checks,
  /// classification of already-read evidence).
  T runSync<T>(
    String imageId,
    ProcessingStage stage,
    T Function() action, {
    required bool Function(T value) verify,
    required String successReason,
    String? failureReason,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> Function(T value)? results,
    int Function(T value)? items,
    List<EvidenceCheck> Function(T value)? checks,
    String actionTaken = '',
    String failureAction = '',
  }) {
    final startedAt = _clock().toUtc();
    final watch = Stopwatch()..start();
    running(imageId, stage, inputs: inputs);
    try {
      final value = action();
      final measured = results?.call(value) ?? const <String, Object?>{};
      final count = items?.call(value);
      final evidenceChecks = checks?.call(value) ?? const <EvidenceCheck>[];
      final predicatePassed = verify(value);
      final checksPassed = evidenceChecks.every((check) => check.passed);
      final evidenceMeasured = evidenceChecks.isNotEmpty || count != null;
      final verified = predicatePassed && checksPassed && evidenceMeasured;
      if (verified) {
        succeeded(
          imageId,
          stage,
          reason: successReason,
          evidence: StageEvidence(
            verified: true,
            checks: evidenceChecks,
            counts: evidenceChecks.isEmpty && count != null
                ? {'items': count}
                : const {},
          ),
          inputs: inputs,
          results: measured,
          itemCount: count,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          actionTaken: actionTaken,
        );
      } else {
        failed(
          imageId,
          stage,
          reason:
              failureReason ??
              'اكتمل فحص المرحلة لكن ناتجها لم يحقق الشرط المطلوب.',
          inputs: inputs,
          results: measured,
          itemCount: count,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          errorType: 'UnverifiedResult',
          errorCode: FailureCode.resultUnverified,
          diagnostics: [
            if (!predicatePassed) 'verify_predicate_returned_false',
            if (!checksPassed) 'evidence_check_failed',
            if (!evidenceMeasured) 'evidence_measurement_missing',
          ],
          actionTaken: failureAction,
          evidence: StageEvidence(
            verified: false,
            checks: evidenceChecks,
            counts: evidenceChecks.isEmpty && count != null
                ? {'items': count}
                : const {},
          ),
        );
      }
      return value;
    } catch (error) {
      if (FailureCode.of(error) == FailureCode.cancelled) {
        cancelled(
          imageId,
          stage,
          reason: 'أُلغيت المرحلة عند أول نقطة آمنة.',
          inputs: inputs,
          actionTaken: failureAction.isEmpty
              ? 'أُوقفت المرحلة عند أول نقطة آمنة.'
              : failureAction,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
        );
      } else {
        failed(
          imageId,
          stage,
          error: error,
          inputs: inputs,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          actionTaken: failureAction,
        );
      }
      rethrow;
    }
  }

  /// The independent document record for one manual selection or one measured
  /// region. The same id returns the same record, so a retry updates it.
  DocumentProcessingLog document(
    String imageId, {
    required String documentId,
    int? index,
    String label = '',
    DocumentKind kind = DocumentKind.unknown,
    SideKind side = SideKind.unknown,
    RecordSource kindSource = RecordSource.unknown,
    RecordSource sideSource = RecordSource.unknown,
  }) {
    final parent = image(imageId);
    final existing = parent.documents.where((d) => d.id == documentId);
    if (existing.isNotEmpty) return existing.first;
    final created = DocumentProcessingLog(
      id: documentId,
      imageId: imageId,
      selectionIndex: index ?? parent.documents.length + 1,
      label: label,
      kind: kind,
      side: side,
      kindSource: kindSource,
      sideSource: sideSource,
      startedAt: _clock().toUtc(),
    );
    parent.replaceDocument(created);
    _emitDocument(parent, created);
    return created;
  }

  DocumentProcessingLog? existingDocument(String imageId, String documentId) {
    final parent = _images[imageId];
    if (parent == null) return null;
    for (final document in parent.documents) {
      if (document.id == documentId) return document;
    }
    return null;
  }

  /// Records a document-scoped stage on one document.
  StageRecord recordDocument(
    String imageId,
    String documentId,
    StageRecord record,
  ) {
    final parent = image(imageId);
    final document = parent.documents.where((d) => d.id == documentId).firstOrNull;
    if (document == null) {
      throw StateError('The document is not part of this image record');
    }
    document.record(record);
    final recorded = document.stageOf(record.stage)!;
    _emitDocument(parent, document);
    return recorded;
  }


  StageRecord documentSucceeded(
    String imageId,
    String documentId,
    ProcessingStage stage, {
    required String reason,
    required StageEvidence evidence,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> results = const {},
    int? itemCount,
    int? durationMs,
    DateTime? startedAt,
    DateTime? endedAt,
    String actionTaken = '',
  }) {
    final end = (endedAt ?? _clock()).toUtc();
    if (!evidence.supportsSuccess) {
      return documentFailed(
        imageId,
        documentId,
        stage,
        reason: '$reason — لم يتحقق شرط النتيجة.',
        inputs: inputs,
        results: results,
        itemCount: itemCount,
        durationMs: durationMs,
        startedAt: startedAt,
        endedAt: end,
        errorType: 'UnverifiedResult',
        errorCode: FailureCode.resultUnverified,
        diagnostics: [
          if (!evidence.verified) 'verify_predicate_returned_false',
          if (evidence.verified) 'evidence_check_failed',
        ],
        actionTaken: actionTaken,
        evidence: evidence.asUnverified(),
      );
    }
    return recordDocument(
      imageId,
      documentId,
      StageRecord(
        stage: stage,
        status: StageStatus.succeeded,
        reason: reason,
        startedAt: startedAt?.toUtc() ?? _deriveStart(end, durationMs),
        endedAt: end,
        durationMs: durationMs,
        inputs: inputs,
        results: results,
        itemCount: itemCount,
        actionTaken: actionTaken,
        evidence: evidence,
      ),
    );
  }

  StageRecord documentFailed(
    String imageId,
    String documentId,
    ProcessingStage stage, {
    Object? error,
    String? reason,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> results = const {},
    int? itemCount,
    int? durationMs,
    DateTime? startedAt,
    DateTime? endedAt,
    String? errorType,
    String? errorCode,
    List<String> diagnostics = const [],
    String actionTaken = '',
    StageEvidence? evidence,
  }) {
    final end = (endedAt ?? _clock()).toUtc();
    return recordDocument(
      imageId,
      documentId,
      StageRecord(
        stage: stage,
        status: StageStatus.failed,
        reason: reason ?? 'تعذّرت المرحلة: ${describeFailure(error)}',
        startedAt: startedAt?.toUtc() ?? _deriveStart(end, durationMs),
        endedAt: end,
        durationMs: durationMs,
        inputs: inputs,
        results: results,
        itemCount: itemCount,
        errorType: errorType ?? error?.runtimeType.toString(),
        errorCode: errorCode ?? FailureCode.of(error),
        diagnostics: diagnostics.isEmpty && errorType == null && error == null
            ? const [StageRecord.undeterminedCause]
            : diagnostics,
        actionTaken: actionTaken,
        evidence: evidence,
      ),
    );
  }

  StageRecord documentOverridden(
    String imageId,
    String documentId,
    ProcessingStage stage, {
    required String reason,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> results = const {},
    String actionTaken = '',
  }) => recordDocument(
    imageId,
    documentId,
    StageRecord(
      stage: stage,
      status: StageStatus.overridden,
      reason: reason,
      inputs: inputs,
      results: results,
      actionTaken: actionTaken,
    ),
  );

  StageRecord documentStopped(
    String imageId,
    String documentId,
    ProcessingStage stage, {
    required String reason,
    Map<String, Object?> inputs = const {},
    String actionTaken = '',
  }) => recordDocument(
    imageId,
    documentId,
    StageRecord(
      stage: stage,
      status: StageStatus.stopped,
      reason: reason,
      inputs: inputs,
      actionTaken: actionTaken,
    ),
  );

  StageRecord documentCancelled(
    String imageId,
    String documentId,
    ProcessingStage stage, {
    required String reason,
    Map<String, Object?> inputs = const {},
    String actionTaken = 'أُوقفت المرحلة عند أول نقطة آمنة.',
    DateTime? startedAt,
    DateTime? endedAt,
    int? durationMs,
  }) {
    final end = (endedAt ?? _clock()).toUtc();
    return recordDocument(
      imageId,
      documentId,
      StageRecord(
        stage: stage,
        status: StageStatus.cancelled,
        reason: reason,
        startedAt: startedAt?.toUtc() ?? _deriveStart(end, durationMs),
        endedAt: end,
        durationMs: durationMs,
        inputs: inputs,
        errorType: 'OperationCancelled',
        errorCode: FailureCode.cancelled,
        diagnostics: const ['operation_cancelled'],
        actionTaken: actionTaken,
      ),
    );
  }

  /// Links a document record to the ids the pipeline actually created.
  ///
  /// Separate from stage recording because these ids arrive at different
  /// moments: the document model exists before the asset is written, and the
  /// layout item only after placement.
  void linkDocument(
    String imageId,
    String documentId, {
    String? recordId,
    String? itemId,
    String? assetId,
    String? outcome,
  }) {
    final parent = image(imageId);
    final document = parent.documents
        .where((entry) => entry.id == documentId)
        .firstOrNull;
    if (document == null) return;
    if (recordId != null) document.documentRecordId = recordId;
    if (itemId != null) document.layoutItemId = itemId;
    if (assetId != null) document.derivedAssetId = assetId;
    if (outcome != null && outcome.isNotEmpty) document.outcome = outcome;
    _emitDocument(parent, document);
  }

  /// Resolves centring stages that were deferred to the batch arrangement.
  ///
  /// [placed] answers whether an item id ended on a page of the saved project.
  /// A document whose centring cannot be confirmed stays «متوقفة» with the
  /// reason, never silently successful.
  void settleCentering({
    required bool centerEnabled,
    required bool Function(String itemId) placed,
  }) {
    for (final parent in _images.values.toList()) {
      for (final document in [...parent.documents]) {
        if (document.statusOf(ProcessingStage.centering) !=
            StageStatus.stopped) {
          continue;
        }
        if (!centerEnabled) {
          documentOverridden(
            parent.imageId,
            document.id,
            ProcessingStage.centering,
            reason: 'عطّل المستخدم خيار التوسيط لهذه الدفعة.',
            actionTaken: 'وُضع المستند دون توسيط.',
          );
          continue;
        }
        final itemId = document.layoutItemId;
        if (itemId != null && placed(itemId)) {
          documentSucceeded(
            parent.imageId,
            document.id,
            ProcessingStage.centering,
            reason: 'فُعّل التوسيط ووُضع المستند على الورقة.',
            evidence: StageEvidence(
              verified: true,
              checks: [
                EvidenceCheck(name: 'center_option_enabled', passed: true),
                EvidenceCheck(name: 'item_placed', passed: true),
              ],
              note: 'التوسيط ينفذه محرك الترتيب نفسه؛ التحقق من تفعيله ومن '
                  'وجود العنصر على الورقة.',
            ),
            actionTaken: 'اكتمل التوسيط مع وضع المستند.',
          );
        } else {
          recordDocument(
            parent.imageId,
            document.id,
            StageRecord(
              stage: ProcessingStage.centering,
              status: StageStatus.stopped,
              reason: 'لم تُثبت إضافة المستند إلى الورقة؛ تعذر التحقق من التوسيط.',
              diagnostics: const ['item_not_placed'],
              actionTaken: 'يبقى التوسيط بانتظار الترتيب.',
            ),
          );
        }
      }
    }
  }

  StageRecord documentNotApplicable(
    String imageId,
    String documentId,
    ProcessingStage stage, {
    required String reason,
    Map<String, Object?> inputs = const {},
  }) => recordDocument(
    imageId,
    documentId,
    StageRecord(
      stage: stage,
      status: StageStatus.notApplicable,
      reason: reason,
      inputs: inputs,
    ),
  );

  /// Runs [action] for one document, verifying its result exactly like [run].
  Future<T> runDocument<T>(
    String imageId,
    String documentId,
    ProcessingStage stage,
    Future<T> Function() action, {
    required bool Function(T value) verify,
    required String successReason,
    String? failureReason,
    Map<String, Object?> inputs = const {},
    Map<String, Object?> Function(T value)? results,
    int Function(T value)? items,
    List<EvidenceCheck> Function(T value)? checks,
    String actionTaken = '',
    String failureAction = '',
  }) async {
    final startedAt = _clock().toUtc();
    final watch = Stopwatch()..start();
    final parent = image(imageId);
    final document = parent.documents
        .where((entry) => entry.id == documentId)
        .firstOrNull;
    if (document == null) {
      throw StateError('The document is not part of this image record');
    }
    document.record(
      StageRecord(
        stage: stage,
        status: StageStatus.running,
        reason: 'المرحلة قيد التنفيذ.',
        startedAt: startedAt,
        inputs: inputs,
      ),
    );
    _emitDocument(parent, document);
    try {
      final value = await action();
      final measured = results?.call(value) ?? const <String, Object?>{};
      final count = items?.call(value);
      final evidenceChecks = checks?.call(value) ?? const <EvidenceCheck>[];
      final predicatePassed = verify(value);
      final checksPassed = evidenceChecks.every((check) => check.passed);
      final evidenceMeasured = evidenceChecks.isNotEmpty || count != null;
      final verified = predicatePassed && checksPassed && evidenceMeasured;
      if (verified) {
        documentSucceeded(
          imageId,
          documentId,
          stage,
          reason: successReason,
          evidence: StageEvidence(
            verified: true,
            checks: evidenceChecks,
            counts: evidenceChecks.isEmpty && count != null
                ? {'items': count}
                : const {},
          ),
          inputs: inputs,
          results: measured,
          itemCount: count,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          actionTaken: actionTaken,
        );
      } else {
        documentFailed(
          imageId,
          documentId,
          stage,
          reason:
              failureReason ??
              'اكتمل استدعاء المرحلة لكن ناتجها لم يحقق الشرط المطلوب.',
          inputs: inputs,
          results: measured,
          itemCount: count,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          errorType: 'UnverifiedResult',
          errorCode: FailureCode.resultUnverified,
          diagnostics: [
            if (!predicatePassed) 'verify_predicate_returned_false',
            if (!checksPassed) 'evidence_check_failed',
            if (!evidenceMeasured) 'evidence_measurement_missing',
          ],
          actionTaken: failureAction,
          evidence: StageEvidence(
            verified: false,
            checks: evidenceChecks,
            counts: evidenceChecks.isEmpty && count != null
                ? {'items': count}
                : const {},
          ),
        );
      }
      return value;
    } catch (error) {
      if (FailureCode.of(error) == FailureCode.cancelled) {
        documentCancelled(
          imageId,
          documentId,
          stage,
          reason: 'أُلغيت المرحلة عند أول نقطة آمنة.',
          inputs: inputs,
          actionTaken: failureAction.isEmpty
              ? 'أُوقفت المرحلة عند أول نقطة آمنة.'
              : failureAction,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
        );
      } else {
        documentFailed(
          imageId,
          documentId,
          stage,
          error: error,
          inputs: inputs,
          startedAt: startedAt,
          durationMs: watch.elapsedMilliseconds,
          actionTaken: failureAction,
        );
      }
      rethrow;
    }
  }

  /// Closes every image record and files the batch report.
  ///
  /// Images that already recorded their own [ProcessingStage.completion] keep
  /// it. Every other image gets a completion row that states what actually
  /// happened: cancelled, stopped by a named batch stage, or ended with the
  /// outcome its stages produced. Completion itself is verified by the fact
  /// that the statuses were counted, so it is never an empty claim.
  ProcessingReport finalize({
    bool cancelled = false,
    String cancellationReason =
        'أُلغيت العملية قبل إنهاء هذه الصورة عند أول نقطة آمنة.',
    StageRecord? batchStop,
    DateTime? endedAt,
  }) {
    if (_finalised) return _report!;
    if (batchStop != null) _batchStop = batchStop;
    final stop = batchStop ?? _batchStop;
    final end = (endedAt ?? _clock()).toUtc();
    for (final image in _images.values) {
      image.endedAt ??= end;
      final existingCompletion = image.stageOf(ProcessingStage.completion);
      if (existingCompletion != null) {
        if (existingCompletion.status == StageStatus.failed) {
          image.outcomeOverride ??= ImageOutcome.failed;
        }
        continue;
      }
      if (cancelled) {
        image.outcomeOverride = ImageOutcome.cancelled;
        image.record(
          StageRecord(
            stage: ProcessingStage.completion,
            status: StageStatus.cancelled,
            reason: cancellationReason,
            startedAt: end,
            endedAt: end,
            actionTaken: 'حُفظ ما أُنجز، وبقيت الصورة في المشروع.',
          ),
        );
      } else if (stop != null) {
        image.outcomeOverride = ImageOutcome.stopped;
        image.record(
          StageRecord(
            stage: ProcessingStage.completion,
            status: StageStatus.stopped,
            reason:
                'توقفت العملية قبل إنهاء هذه الصورة: ${stop.reason}',
            startedAt: end,
            endedAt: end,
            actionTaken: 'حُفظت الحالة الأخيرة ولم تُدَّعَ نتيجة نهائية.',
          ),
        );
      } else {
        final outcome = image.outcome;
        image.outcomeOverride ??= outcome;
        final completionStatus = switch (outcome) {
          ImageOutcome.cancelled => StageStatus.cancelled,
          ImageOutcome.stopped || ImageOutcome.interrupted =>
            StageStatus.stopped,
          _ => StageStatus.succeeded,
        };
        image.record(
          StageRecord(
            stage: ProcessingStage.completion,
            status: completionStatus,
            reason: 'أُنهيت العملية بنتيجة: ${outcome.label}.',
            startedAt: end,
            endedAt: end,
            evidence: completionStatus == StageStatus.succeeded
                ? StageEvidence(
                    verified: true,
                    counts: {
                      'stages': image.stages.length,
                      'documents': image.documents.length,
                      'image_outcome': outcome.index,
                    },
                  )
                : null,
            actionTaken: switch (outcome) {
              ImageOutcome.completed => 'لا إجراء مطلوب.',
              ImageOutcome.completedWithReview => 'الصورة بانتظار مراجعة بشرية.',
              ImageOutcome.partial => 'حُفظ ما نجح، وبقي ما فشل للمعالجة.',
              ImageOutcome.cancelled => 'حُفظ ما أُنجز قبل الإلغاء.',
              ImageOutcome.stopped => 'حُفظت الحالة الأخيرة دون ادعاء الاكتمال.',
              ImageOutcome.interrupted => 'أُشير إلى انقطاع العملية.',
              _ => 'سُجلت النتيجة دون ادّعاء نجاح.',
            },
          ),
        );
      }
      _emitStage(image, image.stageOf(ProcessingStage.completion)!);
    }
    _finalised = true;
    _report = _snapshot(finalised: true, endedAt: end);
    _emit({'event': 'report', 'report': _report!.toJson()});
    return _report!;
  }

  /// Records a batch-level failure. It is attached to every image already
  /// recorded, because a stopped batch genuinely affects all of them.
  StageRecord failBatch(
    ProcessingStage stage,
    String reason, {
    String? errorCode,
  }) {
    final record = StageRecord(
      stage: stage,
      status: StageStatus.failed,
      reason: reason,
      errorType: 'BatchFailure',
      errorCode: errorCode,
      diagnostics: errorCode == null
          ? const [StageRecord.undeterminedCause]
          : const [],
      actionTaken: 'أُوقفت الدفعة؛ حُفظ ما أُنجز.',
    );
    _batchStop = record;
    final safeReason = record.reason;
    _emit({
      'event': 'batch_stop',
      'stage': stage.name,
      'record': record.toJson(),
    });
    for (final image in _images.values) {
      if (stage.documentScoped) {
        for (final document in [...image.documents]) {
          final existing = document.stageOf(stage);
          if (existing != null && existing.status != StageStatus.running) {
            image.addWarning(safeReason);
            _emit({
              'event': 'warning',
              'image': image.imageId,
              'message': safeReason,
            });
            continue;
          }
          document.record(record);
          _emitDocument(image, document);
        }
        continue;
      }
      final existing = image.stageOf(stage);
      if (existing != null && existing.status != StageStatus.running) {
        image.addWarning(safeReason);
        _emit({
          'event': 'warning',
          'image': image.imageId,
          'message': safeReason,
        });
        continue;
      }
      image.record(record);
      _emitStage(image, image.stageOf(stage)!);
    }
    warnBatch(safeReason);
    return record;
  }

  ProcessingReport _snapshot({required bool finalised, DateTime? endedAt}) {
    return ProcessingReport(
      batchId: operationId,
      projectId: projectId,
      projectName: projectName,
      startedAt: startedAt,
      endedAt: endedAt,
      options: options,
      optionCodes: options?.traceCodes.toList() ?? const [],
      warnings: List.unmodifiable(_warnings),
      images: List.unmodifiable(_images.values),
      recovered: false,
      finalised: finalised,
    );
  }

  DateTime? _deriveStart(DateTime end, int? durationMs) {
    if (durationMs == null) return null;
    final safe = durationMs < 0 ? 0 : durationMs;
    return end.subtract(Duration(milliseconds: safe));
  }

  StageRecord _record(String imageId, StageRecord record) {
    final parent = image(imageId);
    parent.record(record);
    final recorded = parent.stageOf(record.stage)!;
    _emitStage(parent, recorded);
    return recorded;
  }

  void _emitStage(ImageProcessingLog image, StageRecord record) {
    _emit({
      'event': 'stage',
      'image': image.imageId,
      'stage': record.stage.name,
      'record': record.toJson(),
    });
  }

  void _emitDocument(
    ImageProcessingLog image,
    DocumentProcessingLog document,
  ) {
    _emit({
      'event': 'document',
      'image': image.imageId,
      'document': document.id,
      'record': document.toJson(),
    });
  }

  void _emit(Map<String, Object?> event) {
    final sink = this.sink;
    if (sink == null) return;
    try {
      sink.add({
        ...event,
        'batch': operationId,
        'seq': ++_eventSequence,
        'utc': _clock().toUtc().toIso8601String(),
      });
    } catch (_) {
      // Diagnostics must never change what the pipeline did.
    }
  }

  /// Rebuilds a report from appended events after a crash, a kill or a lost
  /// final write. The replay is deliberately tolerant: an unreadable event is
  /// skipped, never fatal, and the result is marked [recovered] so a reader
  /// knows it was reconstructed rather than filed by a completed run.
  ///
  /// Returns null only when no event identifies the batch.
  static ProcessingReport? tryRecover(
    String batchId,
    Iterable<Map<String, Object?>> events,
  ) {
    try {
      return _recover(batchId, events);
    } catch (_) {
      return null;
    }
  }

  static ProcessingReport? _recover(
    String batchId,
    Iterable<Map<String, Object?>> events,
  ) {
    String? operationId;
    String? projectId;
    String projectName = '';
    DateTime? startedAt;
    IntakeOptions? options;
    final images = <String, ImageProcessingLog>{};
    final warnings = <String>[];
    var lastUtc = DateTime.now().toUtc();
    Map<String, Object?>? filedReport;
    StageRecord? batchStop;
    for (final event in events) {
      final utc = event['utc'];
      if (utc is String) {
        final parsed = DateTime.tryParse(utc);
        if (parsed != null) lastUtc = parsed.toUtc();
      }
      final type = event['event'];
      if (type == 'batch') {
        operationId = event['operation'] is String
            ? event['operation'] as String
            : operationId;
        projectId = event['project'] is String
            ? event['project'] as String
            : projectId;
        final name = event['project_name'];
        if (name is String) projectName = name;
        final start = event['started_utc'];
        if (start is String) startedAt = DateTime.tryParse(start)?.toUtc();
        final rawOptions = event['options'];
        if (rawOptions is List) {
          options = IntakeOptions.fromTraceCodes(rawOptions);
        }
      } else if (type == 'image') {
        final id = event['image'];
        if (id is! String || id.isEmpty) continue;
        final start = event['started_utc'];
        final parsed = start is String ? DateTime.tryParse(start) : null;
        images.putIfAbsent(
          id,
          () => ImageProcessingLog(
            operationId:
                operationId ??
                (event['batch'] is String ? event['batch'] as String : batchId),
            imageId: id,
            imageName: event['name'] is String ? event['name'] as String : '',
            sourceWidth: event['width'] is int ? event['width'] as int : null,
            sourceHeight: event['height'] is int ? event['height'] as int : null,
            startedAt: parsed?.toUtc() ?? lastUtc,
          ),
        );
      } else if (type == 'image_name') {
        final id = event['image'];
        final name = event['name'];
        if (id is String && name is String && images.containsKey(id)) {
          final image = images[id]!;
          images[id] = ImageProcessingLog(
            operationId: image.operationId,
            imageId: image.imageId,
            imageName: name,
            sourceWidth: image.sourceWidth,
            sourceHeight: image.sourceHeight,
            startedAt: image.startedAt,
            stages: image.stages,
            documents: image.documents,
            warnings: image.warnings,
            endedAt: image.endedAt,
            outcomeOverride: image.outcomeOverride,
          );
        }
      } else if (type == 'stage') {
        final id = event['image'];
        final raw = event['record'];
        if (id is! String || raw is! Map) continue;
        final image = images.putIfAbsent(
          id,
          () => ImageProcessingLog(
            operationId: operationId ?? batchId,
            imageId: id,
            startedAt: lastUtc,
          ),
        );
        try {
          final record = StageRecord.fromJson(raw);
          if (!record.stage.documentScoped) image.record(record);
        } catch (_) {
          // An event this build cannot read is skipped, not trusted.
        }
      } else if (type == 'document') {
        final id = event['image'];
        final raw = event['record'];
        if (id is! String || raw is! Map) continue;
        final image = images.putIfAbsent(
          id,
          () => ImageProcessingLog(
            operationId: operationId ?? batchId,
            imageId: id,
            startedAt: lastUtc,
          ),
        );
        try {
          image.replaceDocument(DocumentProcessingLog.fromJson(raw));
        } catch (_) {}
      } else if (type == 'image_rekey') {
        final from = event['from'];
        final to = event['to'];
        if (from is String && to is String && from != to) {
          final parent = images.remove(from);
          if (parent != null) {
            final target = images[to];
            if (target == null) {
              images[to] = ImageProcessingLog(
                operationId: parent.operationId,
                imageId: to,
                imageName: parent.imageName,
                sourceWidth: event['width'] is int
                    ? event['width'] as int
                    : parent.sourceWidth,
                sourceHeight: event['height'] is int
                    ? event['height'] as int
                    : parent.sourceHeight,
                startedAt: parent.startedAt,
                stages: parent.stages,
                warnings: parent.warnings,
                endedAt: parent.endedAt,
                outcomeOverride: parent.outcomeOverride,
              );
            } else {
              for (final record in parent.stages) {
                if (target.stageOf(record.stage) == null) target.record(record);
              }
            }
          }
        }
      } else if (type == 'batch_stop') {
        final raw = event['record'];
        if (raw is Map) {
          try {
            batchStop = StageRecord.fromJson(raw);
          } catch (_) {}
        }
      } else if (type == 'warning') {
        final message = event['message'];
        if (message is String && message.isNotEmpty) {
          final id = event['image'];
          if (id is String) images[id]?.addWarning(message);
          if (!warnings.contains(message)) warnings.add(message);
        }
      } else if (type == 'report') {
        final raw = event['report'];
        if (raw is Map) filedReport = Map<String, Object?>.from(raw);
      }
    }
    if (operationId == null && images.isEmpty && filedReport == null) {
      return null;
    }
    if (filedReport != null) {
      try {
        final report = ProcessingReport.fromJson(filedReport);
        return ProcessingReport(
          batchId: report.batchId,
          projectId: report.projectId,
          projectName: report.projectName,
          startedAt: report.startedAt,
          endedAt: report.endedAt,
          options: report.options,
          optionCodes: report.optionCodes,
          warnings: report.warnings,
          images: report.finalised
              ? report.images
              : [
                  for (final image in report.images)
                    image.stageOf(ProcessingStage.completion) == null
                        ? _interrupted(image)
                        : image,
                ],
          // A filed summary was completed normally; merely reading it back is
          // not an interruption recovery. Only an event-only replay below is.
          recovered: report.recovered,
          finalised: report.finalised,
        );
      } catch (_) {
        // Fall through to replaying the individual events.
      }
    }
    final ordered = images.values.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return ProcessingReport(
      batchId: batchId,
      projectId: projectId ?? 'unknown',
      projectName: projectName,
      startedAt: startedAt ?? (ordered.isEmpty ? lastUtc : ordered.first.startedAt),
      endedAt: lastUtc,
      options: options,
      optionCodes: options?.traceCodes.toList() ?? const [],
      warnings: List.unmodifiable([
        ...warnings,
        if (batchStop != null && !warnings.contains(batchStop.reason))
          batchStop.reason,
      ]),
      images: [
        for (final image in ordered)
          if (batchStop != null &&
              image.stageOf(ProcessingStage.completion) == null)
            _batchStopped(image, batchStop)
          else if (image.stageOf(ProcessingStage.completion) == null)
            _interrupted(image)
          else
            image,
      ],
      recovered: true,
      // A durable batch_stop event is terminal even if the process died before
      // it could append the compact final report event. Ordinary incomplete
      // journals remain interrupted.
      finalised: batchStop != null,
    );
  }

  /// An image whose completion was never recorded did not finish; its outcome
  /// says so instead of defaulting to success.
  static ImageProcessingLog _batchStopped(
    ImageProcessingLog image,
    StageRecord stop,
  ) =>
      ImageProcessingLog(
        operationId: image.operationId,
        imageId: image.imageId,
        imageName: image.imageName,
        startedAt: image.startedAt,
        sourceWidth: image.sourceWidth,
        sourceHeight: image.sourceHeight,
        stages: image.stages,
        documents: image.documents,
        warnings: [...image.warnings, stop.reason],
        endedAt: image.endedAt,
        outcomeOverride: ImageOutcome.stopped,
      );

  static ImageProcessingLog _interrupted(ImageProcessingLog image) =>
      ImageProcessingLog(
        operationId: image.operationId,
        imageId: image.imageId,
        imageName: image.imageName,
        startedAt: image.startedAt,
        sourceWidth: image.sourceWidth,
        sourceHeight: image.sourceHeight,
        stages: image.stages,
        documents: image.documents,
        warnings: image.warnings,
        endedAt: image.endedAt,
        outcomeOverride: ImageOutcome.interrupted,
      );
}
