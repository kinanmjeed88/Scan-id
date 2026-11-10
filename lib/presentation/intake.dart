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
import '../application/image_journey_report.dart';
import '../application/import_trace.dart';
import '../application/project_service.dart';
import '../application/recognition_worker.dart';
import '../domain/image_journey.dart';
import '../domain/project.dart';

/// The outcome of one intake run.
class IntakeRun {
  const IntakeRun({
    required this.project,
    required this.import,
    this.layout,
    this.error,
    this.trace,
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
  void markUiStateApplied() => trace?.emit('ui_state_applied');

  List<ImportFailure> get failures => import.failures;
  List<ImportNotice> get notices => import.notices;
  int get importedCount => import.imported;
}

/// Runs one intake with real progress and cooperative cancellation.
class IntakeRunner {
  IntakeRunner({
    required this.service,
    required this.project,
    this.keepPlaced = true,
    this.onTrace,
  });

  final ProjectService service;
  final Project project;
  final bool keepPlaced;
  final void Function(ImportTraceEvent event)? onTrace;
  CancellationToken _token = CancellationToken();
  bool _running = false;
  ImportTrace? _lastTrace;

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
    final picked = <ImportedImageFact>[];
    context.emit('import_started');
    final elapsed = Stopwatch()..start();

    // Files this run's reports. Reporting is a courtesy: a full disk, a
    // revoked directory or a malformed entry must never turn a successful
    // import into a failed one, so failures here are swallowed on purpose.
    Future<void> fileJourneys(Project latest, {bool committed = true}) async {
      final log = service.journeyLog;
      if (log == null || picked.isEmpty) return;
      final journeys = buildImageJourneys(
        batchId: taskId,
        project: latest,
        images: picked,
        startedAt: startedAt,
        savedRevision: committed ? latest.revision : null,
      );
      _lastJourneys = journeys;
      try {
        await log.append(journeys);
      } on Object {
        // The import already succeeded; the report can be missing.
      }
    }

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
      final existingIds = project.assets.map((a) => a.id).toSet();
      late final ImportReport import;
      try {
        import = await service.importImages(
          project,
          sources,
          cancellation: token,
          onProgress: reportProgress,
          onSourceResult: (result) => picked.add(
            ImportedImageFact(
              name: result.name,
              assetId: result.asset?.id,
              failureMessage: result.failure,
              copyDurationMs: result.durationMs,
            ),
          ),
        );
      } catch (error) {
        trace('import', 'failed', error);
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
            if (!existingIds.contains(asset.id)) asset.id,
        ];
        try {
          latest = await service.retainUnrepresentedImports(
            latest,
            importedIds,
          );
        } on Object catch (recoveryError) {
          trace('manual-recovery', 'failed', recoveryError);
        }
        await fileJourneys(latest, committed: importedIds.isNotEmpty);
        return IntakeRun(
          project: latest,
          import: ImportReport(latest, importedIds.length, const []),
          error: error,
          trace: context,
        );
      }
      trace('import', 'completed');
      var latest = import.project;
      final importedIds = [
        for (final asset in latest.assets)
          if (!existingIds.contains(asset.id)) asset.id,
      ];
      AutomaticLayoutReport? layout;
      Object? failure;
      if (importedIds.isNotEmpty && !token.isCancelled) {
        trace('arrangement', 'started');
        var savingReported = false;
        try {
          layout = await service.arrangeImportedImages(
            latest,
            importedIds,
            keepPlaced: keepPlaced,
            cancellation: token,
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
        latest = await service.retainUnrepresentedImports(latest, importedIds);
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
      await fileJourneys(latest, committed: importedIds.isNotEmpty);
      return IntakeRun(
        project: latest,
        import: import,
        layout: layout,
        error: failure,
        trace: context,
      );
    } finally {
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
}) async {
  final runner = IntakeRunner(
    service: service,
    project: project,
    keepPlaced: keepPlaced,
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
