/// Shared intake runner and its progress dialog.
///
/// Bringing images into a project happens in two phases: copying each picked
/// source into project storage, then running the automatic arrangement over
/// the new images. Both entry points — the project screen and the A4 editor —
/// go through [IntakeRunner], so an import behaves identically everywhere:
///
/// - **Real progress.** One step per source, emitted after that source is
///   committed or has failed, then one step per analysed image. Nothing
///   sleeps, pads or guesses a count.
/// - **Cooperative cancellation.** A cancel takes effect between safe saves:
///   images already imported stay committed, sources not yet opened are
///   simply never opened and their picker cache is released, so persistence
///   is never half-written and no image buffer leaks (ADR-009).
/// - **Deterministic final state.** The returned project is always the last
///   committed state — reloaded from storage if the arrangement phase failed —
///   never a partially applied one.
/// - **Manual fallback preserved.** A cancelled or failed analysis still
///   leaves every imported image in the project as a plain document the user
///   can crop by hand.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../application/cancellation.dart';
import '../application/contracts.dart' show StorageException;
import '../application/image_journey_report.dart';
import '../application/import_trace.dart';
import '../application/ids.dart';
import '../application/intake_stage_log.dart';
import '../application/processing_ledger.dart';
import '../application/project_service.dart';
import '../application/recognition_worker.dart';
import '../domain/image_journey.dart';
import '../domain/intake_options.dart';
import '../domain/processing_record.dart';
import '../domain/project.dart';
import 'multi_document_crop_screen.dart';

/// The outcome of one intake run.
class IntakeRun {
  const IntakeRun({
    required this.project,
    required this.import,
    this.layout,
    this.error,
    this.trace,
    this.journeyWriteFailed = false,
    this.stageReportWriteFailed = false,
    this.journeyStartBlocked = false,
    this.processingReport,
  });

  /// The last committed project state — never a half-applied one.
  final Project project;

  /// What the copy phase committed.
  final ImportReport import;

  /// What the arrangement phase produced; null when nothing new was imported
  /// or the phase did not run.
  final AutomaticLayoutReport? layout;

  /// Set when the arrangement phase failed. The imports are already committed
  /// and [project] is the reloaded committed state.
  final Object? error;

  /// The runner finishes before a screen adopts the returned saved state.
  final ImportTrace? trace;

  /// At least one checkpoint write failed after retry.
  final bool journeyWriteFailed;

  /// A diagnostic-report failure is separate from the import AND from the
  /// journey journal: each can fail on its own, and the message names the one
  /// that did instead of blaming the wrong subsystem.
  final bool stageReportWriteFailed;

  /// The initial checkpoint failed and no source was opened.
  final bool journeyStartBlocked;

  /// The detailed processing record filed for this run. Null only when the
  /// runner never started a ledger (a host without a project).
  final ProcessingReport? processingReport;
  void markUiStateApplied() => trace?.emit('ui_state_applied');

  List<ImportFailure> get failures => import.failures;
  List<ImportNotice> get notices => import.notices;
  int get importedCount => import.imported;
}

typedef ManualWorkspace =
    Future<Project?> Function(
      Project project,
      ImageAsset asset,
      IntakeOptions options,
      IntakeBatchLog? log,
      ProcessingLedger? ledger,
    );

ManualWorkspace manualWorkspace(BuildContext context, ProjectService service) =>
    (project, asset, options, log, ledger) async {
      if (!context.mounted) return null;
      return Navigator.of(context).push<Project>(
        MaterialPageRoute(
          builder: (_) => MultiDocumentCropScreen(
            project: project,
            asset: asset,
            service: service,
            options: options,
            stageLog: log,
            ledger: ledger,
          ),
        ),
      );
    };

/// Runs one intake with real progress and cooperative cancellation.
class IntakeRunner {
  IntakeRunner({
    required this.service,
    required this.project,
    this.keepPlaced = true,
    this.onTrace,
    this.options,
    this.stageLog,
    this.openManualWorkspace,
  });

  final ProjectService service;
  final Project project;
  final bool keepPlaced;

  /// The options the person chose for this batch, or null when not offered.
  final IntakeOptions? options;
  final ManualWorkspace? openManualWorkspace;

  /// The stage-by-stage record filled in as the batch runs.
  final IntakeBatchLog? stageLog;
  final void Function(ImportTraceEvent event)? onTrace;
  CancellationToken _token = CancellationToken();
  bool _running = false;
  ImportTrace? _lastTrace;
  ProcessingLedger? _ledger;

  /// The detailed record of the run that just finished, once finalised.
  ProcessingReport? get lastProcessingReport =>
      _ledger?.finalised == true ? _ledger!.report : null;

  bool get isRunning => _running;
  ImportTrace? get lastTrace => _lastTrace;

  /// The reports filed for the run that just finished, in pick order. Exposed
  /// so a screen can offer «افتح السجل» right where the import happened; the
  /// durable copy is the one Settings reads.
  List<ImageJourney> get lastJourneys => _lastJourneys;
  List<ImageJourney> _lastJourneys = const [];

  /// Whether a cancellation has been requested and is waiting for the next
  /// checkpoint.
  bool get isCancelling => _token.isCancelled;

  /// Requests cooperative cancellation; takes effect at the next checkpoint.
  void cancel() => _token.cancel();

  /// Runs the intake over [sources].
  Future<IntakeRun> run(
    List<ImportSource> sources, {
    void Function(BatchProgress progress)? onProgress,
  }) {
    final context = ImportTrace(onEvent: onTrace);
    return runZoned(
      () => _run(sources, context, onProgress: onProgress),
      zoneValues: {ImportTrace.zoneKey: context},
    );
  }

  Future<IntakeRun> _run(
    List<ImportSource> sources,
    ImportTrace context, {
    void Function(BatchProgress progress)? onProgress,
  }) async {
    if (_running) throw StateError('IntakeRunner is already running');
    _lastTrace = context;
    _lastJourneys = const [];
    final token = _token = CancellationToken();
    final taskId = context.taskId;
    final startedAt = DateTime.now().toUtc();
    final ledger = _ledger = ProcessingLedger(
      operationId: taskId,
      projectId: project.id,
      projectName: project.name,
      options: options,
      sink: service.processingJournal,
    );
    final picked = <ImportedImageFact>[];
    var journeyWriteFailed = false;
    var stageReportWriteFailed = false;
    StageRecord? processingBatchStop;
    context.emit('import_started');
    final elapsed = Stopwatch()..start();

    /// Closes the detailed record exactly once and returns it.
    ///
    /// A failure inside the journal must never change the intake's result, so
    /// the fallback is the live snapshot rather than an exception.
    ProcessingReport finaliseLedger({
      bool cancelled = false,
      StageRecord? batchStop,
    }) {
      try {
        return ledger.finalize(
          cancelled: cancelled || token.isCancelled,
          batchStop: batchStop ?? processingBatchStop,
        );
      } on Object catch (error) {
        context.emit('processing_report_failed', error: error);
        return ledger.report;
      }
    }

    final pending = createPendingJourneys(
      batchId: taskId,
      project: project,
      names: [for (final source in sources) source.name],
      startedAt: startedAt,
    );

    // Before the first project commit a configured journal is required. Later
    // failures remain warnings and must not undo an already committed image.
    Future<bool> writeCheckpoint(List<ImageJourney> journeys) async {
      final log = service.journeyLog;
      if (log == null || journeys.isEmpty) return true;
      try {
        try {
          await log.append(journeys);
        } on Object {
          await log.append(journeys);
        }
        return true;
      } on Object catch (error) {
        journeyWriteFailed = true;
        context.emit('journey_write_failed', error: error);
        return false;
      }
    }

    /// Files the stage report for this batch, next to the journeys.
    ///
    /// Uses the SAME batch id as the journeys, so a report and the journeys it
    /// explains can be matched without guessing. A journal failure here must
    /// never undo a committed import: it is a diagnostic record, not the result.
    Future<void> fileStageReport(Project latest) async {
      final log = stageLog;
      final journal = service.journeyLog;
      if (log == null || journal == null || log.logs.isEmpty) return;
      try {
        await journal.appendStageReport(
          IntakeStageReport(
            batchId: taskId,
            projectId: latest.id,
            projectName: latest.name,
            startedAt: startedAt,
            summary: log.summary,
            logs: log.logs.toList(growable: false),
            options: log.options,
          ),
        );
      } on Object catch (error) {
        // A separate flag from journeyWriteFailed: the two can fail
        // independently and the message names the one that did.
        stageReportWriteFailed = true;
        context.emit('stage_report_write_failed', error: error);
      }
    }

    List<ImageJourney> checkpoint(
      Project latest, {
      required bool finished,
      bool committed = true,
      bool interrupted = false,
    }) {
      final built = buildImageJourneys(
        batchId: taskId,
        project: latest,
        images: picked,
        startedAt: startedAt,
        savedRevision: committed ? latest.revision : null,
        stablePickedIds: true,
        // The stages recorded while this batch ran, so the filed journey says
        // WHY a stage failed and not merely that the project holds nothing.
        stageLog: stageLog,
      );
      return [
        for (var i = 0; i < pending.length; i++)
          if (i < built.length)
            built[i].withLifecycle(
              !finished
                  ? JourneyLifecycle.processing
                  : interrupted
                  ? JourneyLifecycle.failed
                  : !built[i].imported
                  ? JourneyLifecycle.failed
                  : built[i].verdict == JourneyOutcome.passed
                  ? JourneyLifecycle.completed
                  : JourneyLifecycle.reviewRequired,
            )
          else if (!finished && i == built.length)
            pending[i].withLifecycle(JourneyLifecycle.processing)
          else
            pending[i],
      ];
    }

    Future<void> saveProgress(
      Project latest, {
      required bool finished,
      bool committed = true,
      bool interrupted = false,
    }) async {
      try {
        final journeys = checkpoint(
          latest,
          finished: finished,
          committed: committed,
          interrupted: interrupted,
        );
        if (finished) _lastJourneys = journeys;
        await writeCheckpoint(journeys);
      } on Object catch (error) {
        journeyWriteFailed = true;
        context.emit('journey_write_failed', error: error);
      }
    }

    Future<void> fileJourneys(
      Project latest, {
      bool committed = true,
      bool interrupted = false,
    }) => saveProgress(
      latest,
      finished: true,
      committed: committed,
      interrupted: interrupted,
    );

    var terminal = 'failed';
    void reportProgress(BatchProgress progress) {
      final phase = progress.stage == importStageLabel
          ? 'source'
          : progress.stage == 'تحليل الصور'
          ? 'analysis'
          : progress.stage == 'تجهيز وحفظ النتائج'
          ? 'apply-and-save'
          : 'other';
      context.emit(
        'progress_update',
        phase: phase,
        completed: progress.completed,
        total: progress.total,
      );
      onProgress?.call(progress);
    }

    void trace(String stage, String state, [Object? error]) {
      developer.log(
        'task=$taskId stage=$stage state=$state elapsedMs=${elapsed.elapsedMilliseconds}'
        '${error == null ? '' : ' errorType=${error.runtimeType}'}',
        name: 'scan_id.intake',
      );
    }

    _running = true;
    trace('import', 'started');
    try {
      // Do not start a new import without its required initial checkpoint.
      // Nothing has been committed yet, so report a refusal, not an import
      // failure after success. Hosts without a journal retain their old policy.
      if (!await writeCheckpoint(pending)) {
        await service.discardSources(sources);
        for (var index = 0; index < sources.length; index++) {
          final imageId = 'source-${index + 1}';
          ledger.image(imageId, name: sources[index].name);
          ledger.stopped(
            imageId,
            ProcessingStage.selection,
            reason: journeyStartFailure,
            actionTaken: 'لم يُفتح الملف؛ لم يبدأ الاستيراد.',
          );
        }
        return IntakeRun(
          project: project,
          import: ImportReport(project, 0, [
            for (final source in sources)
              ImportFailure(source.name, journeyStartFailure),
          ]),
          error: const StorageException(journeyStartFailure),
          trace: context,
          journeyWriteFailed: true,
          journeyStartBlocked: true,
          processingReport: finaliseLedger(),
        );
      }
      await saveProgress(project, finished: false, committed: false);
      final existingIds = project.assets.map((a) => a.id).toSet();
      Object? failure;
      final chosen = options;
      final manual = chosen?.route == IntakeRoute.manualSelections;
      Future<Project> selectManually(
        Project latest,
        ImageAsset asset,
        IntakeOptions chosen,
      ) async {
        final log = stageLog?.forAsset(asset.id, name: asset.name);
        ledger
          ..overridden(
            asset.id,
            ProcessingStage.analysis,
            reason: 'اختار المستخدم مسار التحديد اليدوي دون تحليل آلي.',
          )
          ..overridden(
            asset.id,
            ProcessingStage.detection,
            reason: 'رُسمت حدود كل مستند يدوياً؛ لم يعمل كاشف آلي.',
          )
          ..overridden(
            asset.id,
            ProcessingStage.preprocessing,
            reason: 'مسار التحديد اليدوي لا يهيئ مناطق OCR.',
          )
          ..notApplicable(
            asset.id,
            ProcessingStage.confidence,
            reason: 'لم يعمل كاشف أو مصنف آلي لإنتاج درجة ثقة.',
          )
          ..overridden(
            asset.id,
            ProcessingStage.automaticClassification,
            reason: 'يُدخل النوع يدوياً لكل مستند في مساحة التحديد.',
          )
          ..notApplicable(
            asset.id,
            ProcessingStage.userClassification,
            reason: 'اختيار النوع مسجل لكل مستند على حدة، لا للصورة كلها.',
          )
          ..notApplicable(
            asset.id,
            ProcessingStage.faceVerification,
            reason: 'اختيار الوجه والتحقق منه مسجلان لكل مستند على حدة.',
          );
        log?.skip(
          JourneyStage.detection,
          'تحديد يدوي متعدد؛ لا كشف آلي ولا مراجعة لثقة الكاشف.',
        );
        log?.skip(
          JourneyStage.recognition,
          'يُحدد النوع والوجه لكل تحديد في مساحة العمل.',
        );
        try {
          final open = openManualWorkspace;
          if (open == null) throw StateError('Manual workspace unavailable');
          final saved = await open(latest, asset, chosen, stageLog, _ledger);
          if (saved != null) return saved;
          log?.skip(
            JourneyStage.crop,
            'أُغلقت مساحة التحديد دون إضافة مستمسك.',
          );
        } catch (error) {
          failure ??= error;
          ledger.warnBatch('تعذر التحديد اليدوي: ${describeFailure(error)}');
          log?.block(
            JourneyStage.crop,
            'تعذر التحديد اليدوي: ${_causeOf(error)}',
          );
          return service.projects.get(latest.id);
        }
        return latest;
      }

      late final ImportReport import;
      try {
        import = await service.importImages(
          project,
          sources,
          cancellation: token,
          onProgress: reportProgress,
          afterSourceCommit: chosen != null && manual
              ? (saved, asset) => selectManually(saved, asset, chosen)
              : null,
          onSourceResult: (result) {
            final asset = result.asset;
            final log = stageLog?.forAsset(
              asset?.id ?? 'source-${picked.length}',
              name: result.name,
            );
            if (asset == null) {
              log?.block(
                JourneyStage.copy,
                'تعذر استيراد الصورة؛ راجع تفاصيل النسخ في سجل الصورة.',
                durationMs: result.copyDurationMs,
              );
            } else {
              log?.pass(
                JourneyStage.copy,
                'نُسخت الصورة إلى المشروع.',
                durationMs: result.copyDurationMs,
                fields: {'width': asset.width, 'height': asset.height},
              );
            }
            picked.add(
              ImportedImageFact(
                name: result.name,
                assetId: result.asset?.id,
                failureMessage: result.failure,
                copyDurationMs: result.copyDurationMs,
                // Captured now, while `asset` still describes the copy. A later
                // revision keeps this id, so its width/height can become the
                // crop's; the journey must not report the crop as the copy.
                copiedWidth: result.asset?.width,
                copiedHeight: result.asset?.height,
              ),
            );
          },
          onSourceCheckpoint: (result, current) =>
              saveProgress(current, finished: false),
          ledger: ledger,
        );
      } catch (error) {
        trace('import', 'failed', error);
        // Record it before anything else. This is the batch-level counterpart of
        // the per-image blocks below: without a row for it, the filed journey
        // could show every image «processed» while the batch itself threw, and a
        // reader would have no cause at all.
        stageLog?.failBatch(
          JourneyStage.copy,
          'توقف استيراد الدفعة: ${_causeOf(error)}',
        );
        if (!token.isCancelled) {
          processingBatchStop = ledger.failBatch(
            ProcessingStage.importCopy,
            'توقف استيراد الدفعة: ${describeFailure(error)}',
            errorCode: FailureCode.of(error),
          );
        }
        // A batch-level failure can occur after one or more commits. Reload
        // before reporting it; never present an exception as a successful run.
        var latest = project;
        try {
          latest = await service.projects.get(project.id);
        } on Object {
          // Only the last known committed state is available.
        }
        final importedIds = [
          for (final asset in latest.assets)
            if (!existingIds.contains(asset.id) && asset.derivedFrom == null)
              asset.id,
        ];
        try {
          if (options?.route != IntakeRoute.manualSelections) {
            latest = await service.retainUnrepresentedImports(
              latest,
              importedIds,
              options: options,
            );
          }
        } on Object catch (recoveryError) {
          trace('manual-recovery', 'failed', recoveryError);
        }
        await fileJourneys(
          latest,
          committed: importedIds.isNotEmpty,
          interrupted: true,
        );
        await fileStageReport(latest);
        return IntakeRun(
          project: latest,
          import: ImportReport(latest, importedIds.length, const []),
          error: error,
          trace: context,
          journeyWriteFailed: journeyWriteFailed,
          stageReportWriteFailed: stageReportWriteFailed,
          processingReport: finaliseLedger(batchStop: processingBatchStop),
        );
      }
      trace('import', 'completed');
      for (final failure in import.failures) {
        ledger.warnBatch('${failure.name}: ${failure.message}');
      }
      for (final notice in import.notices) {
        ledger.warnBatch('${notice.name}: ${notice.message}');
      }
      var latest = import.project;
      final importedIds = [
        for (final asset in latest.assets)
          if (!existingIds.contains(asset.id) && asset.derivedFrom == null)
            asset.id,
      ];
      AutomaticLayoutReport? layout;
      if (!manual && importedIds.isNotEmpty && !token.isCancelled) {
        trace('arrangement', 'started');
        var savingReported = false;
        try {
          layout = await service.arrangeImportedImages(
            latest,
            importedIds,
            keepPlaced: keepPlaced,
            cancellation: token,
            options: options,
            stageLog: stageLog,
            ledger: ledger,
            onProgress: (progress) {
              if (progress.stage == 'تحليل الصور' && progress.completed == 0) {
                trace('analysis', 'started');
              }
              if (progress.stage == 'تحليل الصور' &&
                  progress.total > 0 &&
                  progress.completed == progress.total) {
                trace('analysis', 'completed');
                savingReported = true;
                trace('apply-and-save', 'started');
                reportProgress(
                  const BatchProgress(
                    total: 1,
                    completed: 0,
                    stage: 'تجهيز وحفظ النتائج',
                  ),
                );
              } else {
                reportProgress(progress);
              }
            },
          );
          latest = layout.project;
          for (final warning in layout.warnings) {
            ledger.warnBatch(warning);
          }
          if (savingReported) trace('apply-and-save', 'completed');
          if (!token.isCancelled) {
            reportProgress(
              const BatchProgress(
                total: 1,
                completed: 1,
                stage: 'تجهيز وحفظ النتائج',
              ),
            );
          }
          trace('arrangement', 'completed');
        } catch (error) {
          trace('arrangement', 'failed', error);
          // The report carried this, but a stage record is what makes it
          // attributable per image: without it the log showed only the stages
          // that ran, with no row explaining why the batch stopped there.
          stageLog?.failBatch(
            JourneyStage.placement,
            'تعذّر ترتيب المستمسكات على الورقة: ${_causeOf(error)}',
          );
          if (!token.isCancelled) {
            processingBatchStop = ledger.failBatch(
              ProcessingStage.addToProject,
              'تعذّر ترتيب المستمسكات على الورقة: ${describeFailure(error)}',
              errorCode: FailureCode.of(error),
            );
          }
          // The imports are already committed: reload so a successful crop
          // revision is never hidden by a later arrangement failure.
          failure = error;
          try {
            latest = await service.projects.get(latest.id);
          } on Object {
            // Keep the last known committed state rather than losing it.
          }
        }
      }
      try {
        if (!manual) {
          latest = await service.retainUnrepresentedImports(
            latest,
            importedIds,
            options: options,
          );
        }
      } on Object catch (recoveryError) {
        trace('manual-recovery', 'failed', recoveryError);
        failure ??= recoveryError;
      }
      final arranged = layout;
      if (arranged != null && arranged.project.revision != latest.revision) {
        // Recovery may add pending items after the automatic report was made.
        // Its derived counts must describe the same saved project the UI uses.
        layout = AutomaticLayoutReport(
          project: latest,
          cropped: arranged.cropped,
          notDetected: arranged.notDetected,
          recognized: arranged.recognized,
          needsReview: arranged.needsReview,
          boundaryNeedsReview: arranged.boundaryNeedsReview,
          multiDocumentImages: arranged.multiDocumentImages,
          rejectedRegions: arranged.rejectedRegions,
          rejectedByReason: arranged.rejectedByReason,
          warnings: arranged.warnings,
        );
      }
      terminal = token.isCancelled
          ? 'cancelled'
          : failure != null || import.failures.isNotEmpty
          ? 'failed'
          : 'completed';
      await fileJourneys(
        latest,
        committed: importedIds.isNotEmpty,
        interrupted: failure != null || token.isCancelled,
      );
      await fileStageReport(latest);
      return IntakeRun(
        project: latest,
        import: import,
        layout: layout,
        error: failure,
        trace: context,
        journeyWriteFailed: journeyWriteFailed,
        stageReportWriteFailed: stageReportWriteFailed,
        processingReport: finaliseLedger(batchStop: processingBatchStop),
      );
    } finally {
      if (ledger.finalised == false) {
        try {
          ledger.finalize(
            cancelled: token.isCancelled,
            batchStop: processingBatchStop,
          );
        } on Object {
          // The report is diagnostics; the run's own result is already known.
        }
      }
      trace('task', terminal);
      context.finish(
        terminal == 'completed'
            ? 'import_completed'
            : terminal == 'cancelled'
            ? 'import_cancelled'
            : 'import_failed',
      );
      _running = false;
    }
  }
}

/// Initial journal failure prevents starting; later failures do not undo saves.
const String journeyStartFailure =
    'لم يبدأ الاستيراد لأن سجل الرحلات الأساسي غير قابل للحفظ. تحقق من التخزين والصلاحيات ثم أعد المحاولة.';

/// A stage-report write failure. Separate sentence on purpose: telling a person
/// «تعذّر حفظ سجل الرحلات» when in fact the STAGE report failed would send them
/// to investigate the wrong record.
const String stageReportWriteWarning =
    'تعذّر حفظ تقرير مراحل المعالجة؛ تحقق من مساحة التخزين والصلاحيات. '
    'لا يعني ذلك فشل استيراد الصور.';

/// A diagnostic-log failure is separate from the outcome of the import.
const String journeyWriteWarning =
    'تعذّر حفظ سجل الرحلات؛ تحقق من مساحة التخزين والصلاحيات. لا يعني ذلك فشل استيراد الصور.';

/// The arrangement screen's intake summary: what the automatic pass produced,
/// plus — on its own line — how many regions the gates refused and why.
///
/// The tally gets its own line rather than relying on [IntakeRun]'s warnings:
/// the arrangement banner shows at most three warnings, so a batch with several
/// per-image issues could otherwise push the only mention of the refused
/// regions out of view entirely, and a refusal the user never sees is
/// indistinguishable from a document the app never looked for.
String intakeSummaryText(AutomaticLayoutReport report) {
  final counts =
      'قُصّ تلقائياً: ${report.cropped} · أنواع ذات مقاس بالكتالوج: '
      '${report.recognized} · حدود بانتظار المراجعة: '
      '${report.boundaryNeedsReview} · تصنيف قيد المراجعة: '
      '${report.needsReview} · بلا رباعي صالح: ${report.notDetected} '
      '· مقاس غير محدد: ${report.awaitingSize} · '
      'خارج الورق: ${report.unplaced}';
  final refused = report.rejectedHeadline;
  return refused == null ? counts : '$counts\n$refused';
}

/// Per-source Arabic details shared by the project and editor import paths.
String importReportDetails(ImportReport report) => [
  if (report.notices.isNotEmpty)
    'ملاحظات المعالجة:\n${report.notices.map((notice) => '${notice.name}: ${notice.message}').join('\n\n')}',
  if (report.failures.isNotEmpty)
    'تعذر استيراد بعض الصور:\n${report.failures.map((failure) => '${failure.name}: ${failure.message}').join('\n\n')}',
].join('\n\n');

/// Runs an intake inside a modal progress dialog with a cancel button.
///
/// Used by the project screen so that importing there behaves exactly like
/// importing from the editor. Returns null only if the dialog is dismissed
/// without a result, which [PopScope] prevents.
Future<IntakeRun?> runIntakeWithProgress(
  BuildContext context, {
  required ProjectService service,
  required Project project,
  required List<ImportSource> sources,
  bool keepPlaced = true,
  IntakeOptions? options,
}) async {
  final runner = IntakeRunner(
    service: service,
    project: project,
    keepPlaced: keepPlaced,
    options: options,
    stageLog: options == null
        ? null
        : IntakeBatchLog(batchId: newId(), options: options),
    openManualWorkspace: manualWorkspace(context, service),
  );
  final result = await showDialog<_IntakeDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _IntakeProgressDialog(runner: runner, sources: sources),
  );
  runner.lastTrace?.emit('dialog_route_returned');
  if (result?.error != null) {
    Error.throwWithStackTrace(result!.error!, result.stackTrace!);
  }
  return result?.run;
}

class _IntakeDialogResult {
  const _IntakeDialogResult.success(this.run) : error = null, stackTrace = null;
  const _IntakeDialogResult.failure(this.error, this.stackTrace) : run = null;
  final IntakeRun? run;
  final Object? error;
  final StackTrace? stackTrace;
}

class _IntakeProgressDialog extends StatefulWidget {
  const _IntakeProgressDialog({required this.runner, required this.sources});
  final IntakeRunner runner;
  final List<ImportSource> sources;

  @override
  State<_IntakeProgressDialog> createState() => _IntakeProgressDialogState();
}

class _IntakeProgressDialogState extends State<_IntakeProgressDialog> {
  BatchProgress? _progress;
  bool _cancelling = false;
  Timer? _elapsedTicker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    // A slow stage and a hung stage look identical in a progress bar. The
    // elapsed time tells the person which one they are looking at, and it is
    // the only honest signal the dialog can offer while a native call runs.
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = Duration(seconds: _elapsed.inSeconds + 1));
    });
    unawaited(_start());
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final run = await widget.runner.run(
        widget.sources,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      run.trace?.emit('dialog_close_requested');
      Navigator.of(context).pop(_IntakeDialogResult.success(run));
      run.trace?.emit('dialog_pop_returned');
    } catch (error, stackTrace) {
      // An unhandled exception in this unawaited callback previously left a
      // non-dismissible dialog open forever. Deliver the failure to the caller.
      if (!mounted) return;
      widget.runner.lastTrace?.emit('dialog_close_requested', error: error);
      Navigator.of(context).pop(_IntakeDialogResult.failure(error, stackTrace));
      widget.runner.lastTrace?.emit('dialog_pop_returned');
    }
  }

  String _elapsedText() {
    final minutes = _elapsed.inMinutes;
    final seconds = _elapsed.inSeconds % 60;
    return minutes == 0
        ? '$seconds ث'
        : '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final total = progress?.total ?? widget.sources.length;
    final completed = progress?.completed ?? 0;
    final value = total <= 0 ? null : completed / total;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(_cancelling ? 'جارٍ الإلغاء…' : 'جارٍ الاستيراد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(progress?.stage ?? importStageLabel),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value),
            const SizedBox(height: 8),
            Text('$completed / $total · ${_elapsedText()}'),
            if (_cancelling)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('سيُلغى الإجراء عند أول نقطة آمنة.'),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('intake-cancel'),
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    widget.runner.cancel();
                  },
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
  }
}

/// A one-line, bounded technical cause for a caught object.
///
/// Deliberately NOT `toString()` of an arbitrary exception: that can carry a
/// filesystem path, a user's file name or a request URL, and the stage report is
/// kept on the device beside the project. The runtime TYPE names the failure
/// class — which is what a reader needs to tell a decode error from a write
/// error — and a `StateError`/`FormatException` message is included only when it
/// is short, single-line and free of path separators.
String _causeOf(Object error) {
  final type = error.runtimeType.toString();
  // `StateError.message` is a String; a FormatException carries `source` and
  // `offset` instead, and `toString()` of it can quote the offending input, so
  // only a StateError's message is ever reused.
  final String? raw = error is StateError ? error.message : null;
  final message = raw?.trim() ?? '';
  final safe =
      message.isNotEmpty &&
      message.length <= 120 &&
      !message.contains('\n') &&
      !message.contains('/') &&
      !message.contains('\\');
  return safe ? '$type: $message' : type;
}
