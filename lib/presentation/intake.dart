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

import 'package:flutter/material.dart';

import '../application/cancellation.dart';
import '../application/project_service.dart';
import '../application/recognition_worker.dart';
import '../domain/project.dart';

/// The outcome of one intake run.
class IntakeRun {
  const IntakeRun({
    required this.project,
    required this.import,
    this.layout,
    this.error,
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

  List<ImportFailure> get failures => import.failures;
  int get importedCount => import.imported;
}

/// Runs one intake with real progress and cooperative cancellation.
class IntakeRunner {
  IntakeRunner({
    required this.service,
    required this.project,
    this.keepPlaced = false,
  });

  final ProjectService service;
  final Project project;
  final bool keepPlaced;

  CancellationToken _token = CancellationToken();
  bool _running = false;

  bool get isRunning => _running;

  /// Whether a cancellation has been requested and is waiting for the next
  /// checkpoint.
  bool get isCancelling => _token.isCancelled;

  /// Requests cooperative cancellation; takes effect at the next checkpoint.
  void cancel() => _token.cancel();

  /// Runs the intake over [sources].
  Future<IntakeRun> run(
    List<ImportSource> sources, {
    void Function(BatchProgress progress)? onProgress,
  }) async {
    final token = _token = CancellationToken();
    _running = true;
    try {
      final existingIds = project.assets.map((a) => a.id).toSet();
      final import = await service.importImages(
        project,
        sources,
        cancellation: token,
        onProgress: onProgress,
      );
      var latest = import.project;
      final importedIds = [
        for (final asset in latest.assets)
          if (!existingIds.contains(asset.id)) asset.id,
      ];
      AutomaticLayoutReport? layout;
      Object? failure;
      if (importedIds.isNotEmpty && !token.isCancelled) {
        try {
          layout = await service.arrangeImportedImages(
            latest,
            importedIds,
            keepPlaced: keepPlaced,
            cancellation: token,
            onProgress: onProgress,
          );
          latest = layout.project;
        } catch (error) {
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
      return IntakeRun(
        project: latest,
        import: import,
        layout: layout,
        error: failure,
      );
    } finally {
      _running = false;
    }
  }
}

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
  bool keepPlaced = false,
}) {
  final runner = IntakeRunner(
    service: service,
    project: project,
    keepPlaced: keepPlaced,
  );
  return showDialog<IntakeRun>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _IntakeProgressDialog(runner: runner, sources: sources),
  );
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

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final run = await widget.runner.run(
      widget.sources,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() => _progress = progress);
      },
    );
    if (!mounted) return;
    Navigator.of(context).pop(run);
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
            Text('$completed / $total'),
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
