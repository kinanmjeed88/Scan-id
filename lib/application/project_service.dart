import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../domain/arrangement.dart';
import '../domain/boundary_decision.dart';
import '../domain/boundary_suggestion.dart';
import '../domain/document_kind.dart';
import '../domain/image_adjustments.dart';
import '../domain/image_journey.dart';
import '../domain/image_deletion.dart';
import '../domain/image_limits.dart';
import '../domain/intake_options.dart';
import '../domain/processing_record.dart';
import '../domain/geometry.dart';
import '../domain/manual_boundary.dart';
import '../domain/manual_classification.dart';
import '../domain/recognition.dart' show SideKind;
import '../domain/project.dart';
import '../domain/quad_assessment.dart';
import '../domain/validation.dart';
import 'cancellation.dart';
import 'contracts.dart';
import 'intake_diagnostics.dart';
import 'intake_stage_log.dart';
import 'project_backups.dart';
import 'camera_capture.dart';
import 'project_recovery.dart';
import 'ids.dart';
import 'import_trace.dart';
import 'image_reader.dart';
import 'journey_log.dart';
import 'full_resolution_jpeg_cropper.dart';
import 'ocr_engine.dart';
import 'processing_ledger.dart';
import 'recognition_pipeline.dart';
import 'recognition_worker.dart';
import 'smart_recognition.dart';
import 'smart_recognition_flag.dart' as smart_recognition_flag;
import 'multi_document_segmentation_flag.dart'
    as multi_document_segmentation_flag;
import '../domain/crop_draft.dart';
import '../imaging/auto_adjustments.dart' as imaging;
import '../imaging/full_resolution_manual_crop.dart';
import '../imaging/document_segmenter.dart';
import '../imaging/image_header.dart';

class ImportSource {
  const ImportSource(this.name, this.openRead, {this.cleanup});
  final Future<void> Function()? cleanup;
  final String name;
  final Stream<List<int>> Function() openRead;
}

/// Stage label of the copy phase of an intake, reported through
/// [BatchProgress.stage] so both intake entry points read the same.
const String importStageLabel = 'استيراد الصور';

/// Reported for every source that was never opened because the user cancelled.
const String importCancelledMessage =
    'لم تُستورد هذه الصورة: أُلغيت العملية بطلب منك.';

class ImportFailure {
  const ImportFailure(this.name, this.message);
  final String name;
  final String message;
}

class ImportNotice {
  const ImportNotice(this.name, this.message);
  final String name;
  final String message;
}

/// What the copy phase did with ONE picked source.
///
/// Exactly one of [asset] and [failure] is set. This is the only place that
/// knows the true source-to-asset mapping, which is why the journey log reads it
/// from here instead of trying to reconstruct it from list order later.
class ImportedSourceResult {
  const ImportedSourceResult.success({
    required this.name,
    required ImageAsset this.asset,
    required this.durationMs,
    required this.copyDurationMs,
  }) : failure = null;

  const ImportedSourceResult.failure({
    required this.name,
    required String this.failure,
    required this.durationMs,
    this.copyDurationMs,
  }) : asset = null;

  final String name;
  final ImageAsset? asset;
  final String? failure;

  /// Total elapsed time for this attempted source; null when it was never opened.
  final int? durationMs;

  /// Aggregate work time for the journey's copy/import step: the sum of the
  /// measured file-validation, decode, dimensions, and project-copy spans.
  /// It is not a separate wall-clock interval; those constituent stages retain
  /// their own durations in the processing ledger. Null if import work did not
  /// start.
  final int? copyDurationMs;
}

class ImportReport {
  const ImportReport(
    this.project,
    this.imported,
    this.failures, {
    this.notices = const [],
  });
  final Project project;
  final int imported;
  final List<ImportFailure> failures;
  final List<ImportNotice> notices;
}

class AutomaticLayoutReport {
  AutomaticLayoutReport({
    required this.project,
    required this.cropped,
    required this.notDetected,
    this.recognized = 0,
    this.needsReview = 0,
    this.boundaryNeedsReview = 0,
    this.multiDocumentImages = 0,
    this.rejectedRegions = 0,
    Map<RegionRejection, int> rejectedByReason = const {},
    required List<String> warnings,
  }) : rejectedByReason = Map.unmodifiable(rejectedByReason),
       warnings = List.unmodifiable(warnings),
       // A count and a category breakdown that disagree would let one surface
       // tell the user a different story from another, so they are checked
       // against each other rather than trusted to have been built together.
       assert(
         rejectedByReason.values.fold(0, (sum, n) => sum + n) ==
             rejectedRegions,
         'the rejection tally must account for every refused region',
       );

  final Project project;
  final int cropped;

  /// Inputs with no usable boundary quadrilateral. A proposed boundary awaiting
  /// a human decision is counted separately in [boundaryNeedsReview].
  final int notDetected;

  /// Documents whose category (and therefore size) was recognised.
  final int recognized;

  /// Recognition records routed to the review queue (Smart Recognition).
  final int needsReview;

  /// Images with usable boundary geometry that awaits a human crop decision.
  /// This is deliberately separate from [notDetected] and type recognition.
  final int boundaryNeedsReview;

  /// Source images that were segmented into several documents.
  final int multiDocumentImages;

  /// Measured regions that candidate-quality validation REFUSED as document
  /// candidates across this batch (a frame edge, a strip, a region too small to
  /// crop, or one beyond the per-photo cap).
  ///
  /// Counted separately from [notDetected] on purpose: a refused region created
  /// no crop, no derived file, no document record and no layout item, while an
  /// unresolved one was kept for review. Both are reported in [warnings], but
  /// only one of them entered the project.
  final int rejectedRegions;

  /// The same refusals broken down by the reason that decided each one.
  ///
  /// Carried as data, not as rendered text, so every surface — the editor's
  /// status message, the project screen's intake summary, the arrangement
  /// banner — words it for its own space while reporting identical facts.
  /// Only reasons the gates actually measured appear, so this can never claim
  /// a diagnostic the pipeline did not decide.
  final Map<RegionRejection, int> rejectedByReason;

  /// ONE concise Arabic line for the whole batch: how many regions were
  /// refused, by which measured categories, and what the user can still do.
  /// Null when nothing was refused, so callers can append it unconditionally.
  String? get rejectedSummary =>
      rejectedRegionsSummary(rejectedRegions, rejectedByReason);

  /// The tally alone, for a surface that already shows the per-image warnings
  /// and only needs the refusal count and its categories to be unmissable.
  String? get rejectedHeadline =>
      rejectedRegionsHeadline(rejectedRegions, rejectedByReason);

  final List<String> warnings;

  /// Confirmed-size documents which the layout could not place on paper.
  /// Unknown size is reported independently and is not a paper overflow.
  int get unplaced => project.items
      .where((item) => item.sizeConfirmed && item.pageIndex == null)
      .length;

  /// Items waiting for a physical size before layout can be attempted.
  int get awaitingSize => project.items
      .where((item) => !item.sizeConfirmed && item.pageIndex == null)
      .length;
}

/// A replaced source: the record is saved and the aspect warning is explicit.
class ReplaceReport {
  const ReplaceReport(this.project, this.aspectChanged, {this.scalingMessage});
  final Project project;

  /// The rectangle on the sheet no longer matches the new pixel proportions.
  final bool aspectChanged;

  /// Discloses when the replacement's untouched original was sampled to a
  /// bounded working raster before processing.
  final String? scalingMessage;
}

/// Result of deleting a project: the record is gone, files normally too.
class ProjectDeletion {
  const ProjectDeletion({this.warning});
  final String? warning;
}

/// Result of deleting one image: the saved project, what was planned, and a
/// warning when the metadata was saved but the image's files could not be
/// removed right away.
class ImageDeletion {
  const ImageDeletion(this.project, this.plan, {this.warning});
  final Project project;
  final ImageDeletionPlan plan;
  final String? warning;
}

class ProjectService {
  const ProjectService(
    this.projects,
    this.assets, {
    this.imageEditor,
    this.backups,
    this.camera,
    this.recovery,
    this.maintenance,
    this.segmenter,
    this.ocr = const UnavailableOcrEngine(),
    this.fullResolutionJpegCropper = const PlatformFullResolutionJpegCropper(),
    this.journeyLog,
    this.processingJournal,
    this.smartRecognitionEnabled =
        smart_recognition_flag.smartRecognitionEnabled,
    this.multiDocumentSegmentationEnabled =
        multi_document_segmentation_flag.multiDocumentSegmentationEnabled,
  });
  final ProjectBackups? backups;
  final CameraCapture? camera;
  final ProjectRecovery? recovery;
  final ImageEditor? imageEditor;
  final StorageMaintenance? maintenance;
  final ProjectRepository projects;
  final AssetRepository assets;

  /// Optional seam for a separately qualified region detector. Null uses the
  /// safe empty default; it never invokes the legacy classical segmenter.
  final Future<SegmentationResult> Function(Uint8List previewBytes)? segmenter;

  /// Local OCR backend seam. Hosts default to unavailable; the shipped app
  /// supplies its offline engine and handles model unavailability explicitly.
  final OcrEngine ocr;

  /// Extracts a measured region from a sampled JPEG's immutable original at
  /// native density. Kept injectable because a real platform channel is not
  /// available to the Dart test runner.
  final FullResolutionJpegCropper fullResolutionJpegCropper;

  /// Bounded per-image report the Settings screen reads. Optional because a
  /// host that has no writable support directory — or a test that does not care
  /// about reports — must be able to run the pipeline unchanged.
  final JourneyLog? journeyLog;

  /// The detailed, stage-by-stage processing journal. Separate from
  /// [journeyLog] because it is a different record: the journeys say what each
  /// image became, this says which stages ran, which were bypassed and why,
  /// with the duration and the verified result of each. Optional so tests and
  /// hosts without a writable directory run the pipeline unchanged.
  final ProcessingJournal? processingJournal;

  /// Recognition gate for this host. An unspecified host defaults to false;
  /// the shipped application explicitly enables it at its composition root.
  final bool smartRecognitionEnabled;

  /// Independent import policy. It only segments candidate multi-document
  /// photos; it never enables full Smart Recognition for single-image imports.
  final bool multiDocumentSegmentationEnabled;

  /// New projects use 5 mm margins (so a 287 mm ration card fits an A4
  /// height) and inherit the editable document sizes of the most recently
  /// edited project, so a corrected residence/ration size is set only once.
  Future<Project> create(String name) async {
    final now = DateTime.now().toUtc();
    var catalog = const DocumentSizeCatalog();
    try {
      final existing = await projects.list();
      if (existing.isNotEmpty) {
        catalog = existing
            .reduce((a, b) => a.updatedAt.isAfter(b.updatedAt) ? a : b)
            .catalog;
      }
    } on Object {
      // A damaged list must not block creating a fresh project.
    }
    return projects.create(
      Project(
        id: newId(),
        name: name.trim(),
        createdAt: now,
        updatedAt: now,
        paper: PaperSettings(margins: Margins.all(5)),
        layout: LayoutSettings(strategy: ArrangementStrategy.compact),
        catalog: catalog,
      ),
    );
  }

  Future<Project> rename(Project project, String name) async =>
      projects.save(project.copyWith(name: name.trim()));

  /// Re-runs recognition over source images that are ALREADY in the project.
  ///
  /// This is a retry, not an import: no source image is added and no original
  /// file is written. Documents this source already produced keep their ids,
  /// their layout items and their placement; only their derived image and
  /// evidence are regenerated. Documents the user confirmed are left alone.
  ///
  /// Returns null when Smart Recognition is off or no image editor is
  /// available, so callers can say so instead of pretending nothing happened.
  /// A recognition refresh, never an arrangement: a document already on the
  /// sheet keeps its page, position, size, rotation and grouping whatever the
  /// automatic-flow setting is. See [SmartIntake.reprocess].
  Future<AutomaticLayoutReport?> reprocessImages(
    Project project,
    Iterable<String> assetIds, {
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
  }) async {
    final smartEditor = imageEditor;
    if (!smartRecognitionEnabled || smartEditor == null) return null;
    return SmartIntake(
      projects: projects,
      assets: assets,
      editor: smartEditor,
      segment: segmenter ?? defaultSegment,
      ocr: ocr,
      fullResolutionJpegCropper: fullResolutionJpegCropper,
    ).reprocess(
      project,
      assetIds,
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }

  /// Each successfully imported image is committed before processing the next.
  /// A batch may partially succeed; report precisely rather than losing work.
  ///
  /// [onProgress] reports REAL work: one step per source, emitted after that
  /// source is committed (or has failed). Nothing sleeps or pads the count.
  ///
  /// [cancellation] is cooperative and takes effect BETWEEN safe saves: the
  /// images already imported stay committed, the remaining sources are never
  /// opened, and their picker cache is released — so persistence is never
  /// left half-written and no image buffer leaks (ADR-009).
  Future<ImportReport> importImages(
    Project project,
    List<ImportSource> sources, {
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
    ProcessingLedger? ledger,
    void Function(ImportedSourceResult result)? onSourceResult,
    Future<void> Function(ImportedSourceResult result, Project project)?
    onSourceCheckpoint,
    Future<Project> Function(Project saved, ImageAsset asset)?
    afterSourceCommit,
  }) async {
    var current = project;
    var imported = 0;
    final failures = <ImportFailure>[];
    final notices = <ImportNotice>[];

    void report(int completed) => onProgress?.call(
      BatchProgress(
        total: sources.length,
        completed: completed,
        stage: importStageLabel,
      ),
    );

    Future<void> reportSource(ImportedSourceResult result) async {
      try {
        onSourceResult?.call(result);
        await onSourceCheckpoint?.call(result, current);
      } catch (_) {
        // A reporting seam must never change what the import committed.
      }
    }

    report(0);
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      final pendingId = 'source-${index + 1}';
      if (cancellation?.isCancelled ?? false) {
        // Stop before opening another file: every committed image stays
        // committed and the rest are reported as not imported.
        await _cleanupSource(source);
        ledger
          ?..image(pendingId, name: source.name)
          ..cancelled(
            pendingId,
            ProcessingStage.selection,
            reason: importCancelledMessage,
            inputs: {'index': index + 1},
          );
        failures.add(ImportFailure(source.name, importCancelledMessage));
        await reportSource(
          ImportedSourceResult.failure(
            name: source.name,
            failure: importCancelledMessage,
            durationMs: null,
          ),
        );
        var skippedIndex = index + 1;
        for (final skipped in sources.skip(index + 1)) {
          skippedIndex++;
          await _cleanupSource(skipped);
          ledger
            ?..image('source-$skippedIndex', name: skipped.name)
            ..cancelled(
              'source-$skippedIndex',
              ProcessingStage.selection,
              reason: importCancelledMessage,
              inputs: {'index': skippedIndex},
            );
          failures.add(ImportFailure(skipped.name, importCancelledMessage));
          await reportSource(
            ImportedSourceResult.failure(
              name: skipped.name,
              failure: importCancelledMessage,
              durationMs: null,
            ),
          );
        }
        break;
      }
      final sourceClock = Stopwatch()..start();
      ImageAsset? committedAsset;
      ImageAsset? importedAsset;
      var stage = ProcessingStage.selection;
      final selectionClock = Stopwatch()..start();
      final validationClock = Stopwatch();
      final decodeClock = Stopwatch();
      final dimensionsClock = Stopwatch();
      final copyClock = Stopwatch();
      var copyWorkStarted = false;
      // The journey has one copy/import step, while the processing ledger splits
      // it into separately measured work. Sum those non-overlapping intervals;
      // do not present the total source wall time or duplicate it per substage.
      int? measuredCopyDurationMs() => copyWorkStarted
          ? validationClock.elapsedMilliseconds +
                decodeClock.elapsedMilliseconds +
                dimensionsClock.elapsedMilliseconds +
                copyClock.elapsedMilliseconds
          : null;
      int? finishStageClock() {
        final Stopwatch? clock = switch (stage) {
          ProcessingStage.selection => selectionClock,
          ProcessingStage.fileValidation => validationClock,
          ProcessingStage.decode => decodeClock,
          ProcessingStage.dimensions => dimensionsClock,
          ProcessingStage.importCopy => copyClock,
          _ => null,
        };
        if (clock != null && clock.isRunning) clock.stop();
        return clock?.elapsedMilliseconds;
      }

      try {
        // Create the source row before any check can fail so its filename and
        // selection are preserved even when the project is already at capacity.
        ledger?.image(pendingId, name: source.name);
        require(
          current.assets.length < maxProjectAssets,
          'وصل المشروع إلى حد 200 صورة.',
        );
        selectionClock.stop();
        // Record what already happened BEFORE the decode that might kill the
        // process: the source is received. The row uses a provisional id until
        // the repository returns the asset id.
        ledger?.succeeded(
          pendingId,
          ProcessingStage.selection,
          reason: 'استُلم المصدر المختار ووُضع في طابور الاستيراد.',
          evidence: StageEvidence(
            verified: true,
            counts: {'sources': 1, 'batch_index': index + 1},
          ),
          inputs: {'index': index + 1},
          durationMs: selectionClock.elapsedMilliseconds,
        );
        copyWorkStarted = true;
        validationClock.start();
        stage = ProcessingStage.fileValidation;
        validName(source.name);
        final bytes = await ImportTrace.stage(
          'source_read',
          () => readBoundedImage(source.openRead()),
        );
        // Header inspection is diagnostic only: an unreadable header is
        // reported as uninspected, never turned into a failed import, because
        // the repository performs the authoritative validation.
        ImageHeader? header;
        try {
          header = inspectImageHeader(bytes);
        } on Object {
          header = null;
        }
        validationClock.stop();
        final validationVerified =
            bytes.isNotEmpty && bytes.length <= maxImportBytes;
        ledger?.succeeded(
          pendingId,
          ProcessingStage.fileValidation,
          reason: header == null
              ? 'اسم الملف وحجمه صالحان؛ تعذر فحص الترويسة فبقي التشخيص ناقصاً.'
              : 'اسم الملف وحجمه صالحان، وطابقت الترويسة صيغة مدعومة.',
          evidence: StageEvidence(
            verified: validationVerified,
            checks: [
              EvidenceCheck(name: 'bytes_not_empty', passed: bytes.isNotEmpty),
              EvidenceCheck(
                name: 'size_within_limit',
                passed: bytes.length <= maxImportBytes,
                detail: '${bytes.length}',
              ),
            ],
            counts: {
              'bytes': bytes.length,
              'header_inspected': header == null ? 0 : 1,
            },
          ),
          results: {
            if (header != null) 'format': header.encoding.name,
            if (header != null) 'header_width': header.width,
            if (header != null) 'header_height': header.height,
            if (header != null) 'orientation': header.orientation,
          },
          durationMs: validationClock.elapsedMilliseconds,
        );
        decodeClock.start();
        stage = ProcessingStage.decode;
        final asset = await ImportTrace.stage(
          'asset_import',
          () => assets.importImage(current.id, source.name, bytes),
        );
        importedAsset = asset;
        decodeClock.stop();
        ledger?.rekeyImage(
          pendingId,
          asset.id,
          width: asset.width,
          height: asset.height,
        );
        ledger?.succeeded(
          asset.id,
          ProcessingStage.decode,
          reason: 'فُك ترميز المصدر وأُنتجت نسخة العمل والمصغرة.',
          evidence: StageEvidence(
            verified:
                asset.width > 0 &&
                asset.height > 0 &&
                asset.workingPath.isNotEmpty &&
                asset.thumbnailPath.isNotEmpty,
            checks: [
              EvidenceCheck(
                name: 'dimensions_positive',
                passed: asset.width > 0 && asset.height > 0,
              ),
              EvidenceCheck(
                name: 'files_named',
                passed:
                    asset.workingPath.isNotEmpty &&
                    asset.thumbnailPath.isNotEmpty,
              ),
            ],
            counts: {'working_files': 2},
          ),
          results: {
            'width': asset.width,
            'height': asset.height,
            'scaled': asset.hasScaledLargeSource,
          },
          durationMs: decodeClock.elapsedMilliseconds,
        );
        stage = ProcessingStage.dimensions;
        dimensionsClock.start();
        final dimensionsVerified =
            asset.width > 0 &&
            asset.height > 0 &&
            withinImageBudget(asset.width, asset.height);
        dimensionsClock.stop();
        ledger?.succeeded(
          asset.id,
          ProcessingStage.dimensions,
          reason: 'أبعاد الصورة صالحة وضمن حد المعالجة.',
          evidence: StageEvidence(
            verified: dimensionsVerified,
            checks: [
              EvidenceCheck(
                name: 'width_positive',
                passed: asset.width > 0,
                detail: '${asset.width}',
              ),
              EvidenceCheck(
                name: 'height_positive',
                passed: asset.height > 0,
                detail: '${asset.height}',
              ),
              EvidenceCheck(
                name: 'within_pixel_budget',
                passed: withinImageBudget(asset.width, asset.height),
              ),
            ],
          ),
          results: {
            'width': asset.width,
            'height': asset.height,
            if (header != null) 'orientation': header.orientation,
          },
          durationMs: dimensionsClock.elapsedMilliseconds,
        );
        copyClock.start();
        stage = ProcessingStage.importCopy;
        current = await ImportTrace.stage(
          'persistence',
          () => projects.save(
            current.copyWith(assets: [...current.assets, asset]),
          ),
          phase: 'source',
        );
        copyClock.stop();
        committedAsset = asset;
        ledger?.succeeded(
          asset.id,
          ProcessingStage.importCopy,
          reason: 'حُفظت الصورة داخل المشروع.',
          evidence: StageEvidence(
            verified:
                current.assets.any((entry) => entry.id == asset.id) &&
                asset.originalPath.isNotEmpty &&
                asset.workingPath.isNotEmpty,
            checks: [
              EvidenceCheck(
                name: 'project_contains_asset',
                passed: current.assets.any((entry) => entry.id == asset.id),
              ),
              EvidenceCheck(
                name: 'paths_present',
                passed:
                    asset.originalPath.isNotEmpty &&
                    asset.workingPath.isNotEmpty,
              ),
            ],
            counts: {'assets': current.assets.length},
          ),
          results: {'revision': current.revision},
          durationMs: copyClock.elapsedMilliseconds,
        );
        imported++;
        await reportSource(
          ImportedSourceResult.success(
            name: source.name,
            asset: asset,
            durationMs: sourceClock.elapsedMilliseconds,
            copyDurationMs: measuredCopyDurationMs()!,
          ),
        );
        if (asset.hasScaledLargeSource) {
          notices.add(
            ImportNotice(
              source.name,
              'حُفظ الأصل كما هو؛ صُغّرت نسخة العمل إلى '
              '${asset.width}×${asset.height} بحد أقصى 4 ملايين بكسل، '
              'وقد تقل تفاصيل النسخة المعالجة.',
            ),
          );
        }
      } on RevisionConflict catch (error) {
        final stageDurationMs = finishStageClock();
        ImportTrace.current?.emit(
          'source_failed',
          phase: 'revision-conflict',
          error: error,
        );
        ledger?.failed(
          importedAsset?.id ?? pendingId,
          stage,
          error: error,
          durationMs: stageDurationMs,
          reason: 'توقف الاستيراد عند «${stage.label}» بسبب تعارض حفظ المشروع.',
          inputs: {'index': index + 1},
          actionTaken: 'أُوقف الاستيراد لأن نسخة المشروع في الذاكرة قديمة.',
        );
        failures.add(ImportFailure(source.name, error.message));
        await reportSource(
          ImportedSourceResult.failure(
            name: source.name,
            failure: error.message,
            durationMs: sourceClock.elapsedMilliseconds,
            copyDurationMs: measuredCopyDurationMs(),
          ),
        );
        // The in-memory project is stale; continuing would create more orphans.
        var stoppedIndex = index + 1;
        for (final skipped in sources.skip(index + 1)) {
          stoppedIndex++;
          await _cleanupSource(skipped);
          const stopped =
              'لم تُستورد هذه الصورة: توقف الاستيراد بسبب تعارض '
              'حفظ المشروع.';
          ledger
            ?..image('source-$stoppedIndex', name: skipped.name)
            ..stopped(
              'source-$stoppedIndex',
              ProcessingStage.selection,
              reason: stopped,
              actionTaken: 'لم يُفتح الملف بعد توقف الدفعة.',
            );
          failures.add(ImportFailure(skipped.name, stopped));
          await reportSource(
            ImportedSourceResult.failure(
              name: skipped.name,
              failure: stopped,
              durationMs: null,
            ),
          );
        }
        break;
      } catch (error) {
        final stageDurationMs = finishStageClock();
        ImportTrace.current?.emit(
          'source_failed',
          phase: 'import',
          error: error,
        );
        ledger?.failed(
          importedAsset?.id ?? pendingId,
          stage,
          error: error,
          durationMs: stageDurationMs,
          reason:
              'تعذر استيراد الصورة عند مرحلة «${stage.label}»: '
              '${describeFailure(error)}',
          inputs: {'index': index + 1},
          actionTaken: 'لم تُضف الصورة إلى المشروع.',
        );
        final message = userError(error);
        failures.add(ImportFailure(source.name, message));
        await reportSource(
          ImportedSourceResult.failure(
            name: source.name,
            failure: message,
            durationMs: sourceClock.elapsedMilliseconds,
            copyDurationMs: measuredCopyDurationMs(),
          ),
        );
      } finally {
        await _cleanupSource(source);
        report(index + 1);
      }
      // The picker cache and source bytes are no longer needed while a
      // person draws corners. Adopt each new revision before the next copy.
      if (committedAsset != null &&
          afterSourceCommit != null &&
          cancellation?.isCancelled != true) {
        try {
          current = await afterSourceCommit(current, committedAsset);
        } catch (_) {
          await discardSources(sources.skip(index + 1));
          rethrow;
        }
      }
    }
    return ImportReport(
      current,
      imported,
      List.unmodifiable(failures),
      notices: List.unmodifiable(notices),
    );
  }

  /// The automatic intake pipeline for newly imported images.
  ///
  /// Full Smart Recognition remains behind [smartRecognitionEnabled]. The
  /// independent multi-document policy first runs only the classical local
  /// segmenter; when it finds more than one usable region, that cached result is
  /// handed to SmartIntake for derived crops and human review. Zero or one
  /// region, a pre-cropped source, or a segmentation failure keeps the existing
  /// single-document import path.
  ///
  /// [keepPlaced] defaults to true: importing a new document must not move
  /// documents that are already on a page. Sizes are never silently changed.
  Future<AutomaticLayoutReport> arrangeImportedImages(
    Project project,
    Iterable<String> assetIds, {
    bool keepPlaced = true,
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
    IntakeOptions? options,
    IntakeBatchLog? stageLog,
    ProcessingLedger? ledger,
  }) async {
    final smartEditor = imageEditor;
    // Option 4: centring. This is not a second placement algorithm — it sets
    // the project's existing, persisted `centerCaptures` switch that
    // `arrangeDocuments` already honours, so the result is identical to the app
    // centring the same documents from the layout screen. Applied before
    // arrangement so a batch arrives centred rather than being re-centred after
    // the sheet was already filled.
    var working = project;
    if (options != null &&
        options.centerDocuments != working.layout.centerCaptures) {
      working = working.copyWith(
        layout: working.layout.copyWith(
          centerCaptures: options.centerDocuments,
        ),
      );
    }
    if (options?.route == IntakeRoute.manualSelections) {
      throw StateError(
        'Manual selections must not enter automatic arrangement',
      );
    }
    final multiEnabled = options == null && multiDocumentSegmentationEnabled;
    if (smartRecognitionEnabled && smartEditor != null) {
      final report =
          await SmartIntake(
            projects: projects,
            assets: assets,
            editor: smartEditor,
            segment: segmenter ?? defaultSegment,
            ocr: ocr,
            fullResolutionJpegCropper: fullResolutionJpegCropper,
            options: options,
            stageLog: stageLog,
            ledger: ledger,
          ).run(
            working,
            assetIds,
            keepPlaced: keepPlaced,
            cancellation: cancellation,
            onProgress: onProgress,
            // This flag governs ONE thing: whether a photo holding several
            // measured regions is reported as multi-document. Without the
            // options (no sheet) the old behaviour stands, so nothing changes
            // for callers that never asked. With them, it follows the request.
            allowMultiDocument: options == null,
          );
      return report;
    }

    if (multiEnabled && smartEditor != null) {
      return _arrangeWithMultiDocumentSegmentation(
        working,
        assetIds,
        editor: smartEditor,
        keepPlaced: keepPlaced,
        cancellation: cancellation,
        onProgress: onProgress,
        stageLog: stageLog,
        ledger: ledger,
      );
    }

    return _arrangeLegacyImportedImages(
      working,
      assetIds,
      keepPlaced: keepPlaced,
      cancellation: cancellation,
      onProgress: onProgress,
      options: options,
      stageLog: stageLog,
      ledger: ledger,
    );
  }

  /// Camera receipts are committed before recognition. Replaying a receipt
  /// must neither duplicate a document nor discard an original on OCR failure.
  Future<Project> completeCameraIntake(Project project) async {
    final represented = {
      for (final item in project.items) item.assetId,
      for (final record in project.documents) record.sourceImageId,
    };
    final ids = [
      for (final asset in project.assets)
        if (asset.captureId != null && !represented.contains(asset.id))
          asset.id,
    ];
    if (ids.isEmpty) return project;
    try {
      await arrangeImportedImages(project, ids);
    } finally {
      // Always reload the committed revision; a partial analysis may have saved
      // metadata before throwing. Retain failures as pending manual items.
      final latest = await projects.get(project.id);
      await retainUnrepresentedImports(latest, ids);
    }
    return projects.get(project.id);
  }

  /// Preserve imports not represented by any layout item after an interrupted
  /// or failed automatic pass. These are pending manual decisions, not guessed
  /// types or approved boundaries; the original asset remains untouched.
  Future<Project> retainUnrepresentedImports(
    Project project,
    Iterable<String> importedAssetIds, {
    IntakeOptions? options,
  }) async {
    final ids = importedAssetIds.toSet();
    if (ids.isEmpty) return project;
    final represented = <String>{
      for (final item in project.items) item.assetId,
    };
    final linkedDocuments = {
      for (final item in project.items)
        if (item.documentId != null) item.documentId,
    };
    represented.addAll([
      for (final record in project.documents)
        if (linkedDocuments.contains(record.id)) record.sourceImageId,
      for (final asset in project.assets)
        if (represented.contains(asset.id) && asset.derivedFrom != null)
          asset.derivedFrom!,
    ]);
    final missing = project.assets
        .where(
          (asset) => ids.contains(asset.id) && !represented.contains(asset.id),
        )
        .toList();
    if (missing.isEmpty) return project;
    var nextZ = project.items.fold<int>(
      0,
      (top, item) => math.max(top, item.zIndex),
    );
    final next = project.copyWith(
      items: [
        ...project.items,
        for (final asset in missing)
          DocumentItem(
            id: newId(),
            assetId: asset.id,
            x: project.paper.margins.left,
            y: project.paper.margins.top,
            width: provisionalSize(
              width: asset.width,
              height: asset.height,
            ).width,
            height: provisionalSize(
              width: asset.width,
              height: asset.height,
            ).height,
            pageIndex: null,
            zIndex: ++nextZ,
            documentKind: DocumentKind.unknown,
            sizeConfirmed: false,
          ),
      ],
    );
    return projects.save(
      options == null
          ? next
          : attachIntakeChoices(
              next,
              next.items.skip(project.items.length),
              options,
              newId,
            ),
    );
  }

  Future<AutomaticLayoutReport> _arrangeWithMultiDocumentSegmentation(
    Project project,
    Iterable<String> assetIds, {
    required ImageEditor editor,
    required bool keepPlaced,
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
    IntakeBatchLog? stageLog,
    ProcessingLedger? ledger,
  }) async {
    final ids = assetIds.toSet().toList();
    final pendingIds = <String>[];
    for (final id in ids) {
      final assetIndex = project.assets.indexWhere((entry) => entry.id == id);
      require(assetIndex >= 0, 'الصورة المراد ترتيبها ليست ضمن المشروع.');
      if (!project.items.any((item) => item.assetId == id)) pendingIds.add(id);
    }

    var current = project;
    var cropped = 0;
    var notDetected = 0;
    // SmartIntake counts text-derived suggestions when an OCR engine is
    // available. The host default is unavailable; the app supplies PP-OCRv5.
    var recognized = 0;
    var needsReview = 0;
    var boundaryNeedsReview = 0;
    var multiDocumentImages = 0;
    var rejectedRegions = 0;
    final rejectedByReason = <RegionRejection, int>{};
    final warnings = <String>[];
    final segments = <String, SegmentationResult>{};
    final segmentationWarnings = <String, String>{};

    void merge(AutomaticLayoutReport report) {
      current = report.project;
      cropped += report.cropped;
      notDetected += report.notDetected;
      recognized += report.recognized;
      needsReview += report.needsReview;
      boundaryNeedsReview += report.boundaryNeedsReview;
      multiDocumentImages += report.multiDocumentImages;
      rejectedRegions += report.rejectedRegions;
      for (final entry in report.rejectedByReason.entries) {
        rejectedByReason.update(
          entry.key,
          (value) => value + entry.value,
          ifAbsent: () => entry.value,
        );
      }
      warnings.addAll(report.warnings);
    }

    void progress(int completed, String stage) => onProgress?.call(
      BatchProgress(
        total: pendingIds.length,
        completed: completed,
        stage: stage,
      ),
    );

    progress(0, 'فحص تقسيم الصور');
    for (var index = 0; index < pendingIds.length; index++) {
      if (cancellation?.isCancelled ?? false) break;
      final id = pendingIds[index];
      final asset = project.assets.firstWhere((entry) => entry.id == id);
      // Multi-region coordinates are measured against the pristine source.
      // A manually cropped/revised asset stays on its established single-image
      // path so those coordinates can never be applied to different pixels.
      if (asset.crop == null && !asset.userAuthoredCrop) {
        try {
          final source = await editor.open(asset, cancellation: cancellation);
          final result = await (segmenter ?? defaultSegment)(source.preview);
          segments[id] = result;
          stageLog
              ?.forAsset(id, name: asset.name)
              .record(
                IntakeStageRecord(
                  stage: JourneyStage.detection,
                  outcome: result.candidates.isEmpty
                      ? JourneyOutcome.review
                      : JourneyOutcome.passed,
                  detail: result.candidates.isEmpty
                      ? 'لم يُقَس أي مستند في هذا المصدر؛ بقي للمراجعة اليدوية.'
                      : 'قِيست ${result.candidates.length} منطقة '
                            '${result.candidates.length > 1 ? '(متعددة)' : ''}.',
                  fields: {
                    'regions': result.candidates.length,
                    'rejected': result.rejected.length,
                    'multi': result.multi,
                  },
                ),
              );
        } on RevisionConflict {
          rethrow;
        } catch (error) {
          final reason = userError(error);
          segmentationWarnings[id] =
              '${asset.name}: تعذر فحص التقسيم متعدد المستمسكات؛ '
              'استُخدم مسار الاستيراد المعتاد ($reason).';
          // The batch report carried this warning, but the stage record is what
          // makes it attributable: without it the log showed only «no region
          // found», which is indistinguishable from a clean single document.
          stageLog
              ?.forAsset(id, name: asset.name)
              .block(
                JourneyStage.detection,
                'تعذّر فحص التقسيم متعدد المستمسكات: $reason',
                fields: {'errorType': error.runtimeType.toString()},
              );
        }
      }
      progress(index + 1, 'فحص تقسيم الصور');
    }

    bool isMultiDocumentSource(String id) {
      final segmentation = segments[id];
      return segmentation != null && segmentation.candidates.length > 1;
    }

    var hasNewItems = false;
    var index = 0;
    while (index < pendingIds.length && !(cancellation?.isCancelled ?? false)) {
      final id = pendingIds[index];
      if (isMultiDocumentSource(id)) {
        final segmentation = segments[id]!;
        final beforeItems = current.items.length;
        // Pass the already measured result through the existing multi-document
        // intake so it is not segmented a second time. Defer placement until all
        // sources in this import batch have staged their new items.
        final report =
            await SmartIntake(
              projects: projects,
              assets: assets,
              editor: editor,
              segment: (_) async => segmentation,
              ocr: ocr,
              fullResolutionJpegCropper: fullResolutionJpegCropper,
              stageLog: stageLog,
              ledger: ledger,
            ).run(
              current,
              [id],
              keepPlaced: keepPlaced,
              deferArrangement: true,
              cancellation: cancellation,
              onProgress: (value) =>
                  progress(index + value.completed, value.stage),
            );
        merge(report);
        hasNewItems = hasNewItems || report.project.items.length > beforeItems;
        index++;
        progress(index, 'إضافة المستمسكات');
        continue;
      }

      // Process adjacent singleton/fallback images together. This preserves the
      // legacy batch packing behavior instead of letting an earlier item from
      // the same import become a fixed obstacle for a later one.
      final firstIndex = index;
      final fallbackIds = <String>[];
      while (index < pendingIds.length &&
          !isMultiDocumentSource(pendingIds[index])) {
        fallbackIds.add(pendingIds[index]);
        index++;
      }
      final beforeItems = current.items.length;
      final report = await _arrangeLegacyImportedImages(
        current,
        fallbackIds,
        keepPlaced: keepPlaced,
        deferArrangement: true,
        cancellation: cancellation,
        onProgress: (value) =>
            progress(firstIndex + value.completed, value.stage),
        stageLog: stageLog,
        ledger: ledger,
      );
      merge(report);
      hasNewItems = hasNewItems || report.project.items.length > beforeItems;
      for (final fallbackId in fallbackIds) {
        final asset = current.assets.firstWhere(
          (entry) => entry.id == fallbackId,
        );
        final segmentation = segments[fallbackId];
        final refused = segmentation?.rejected ?? const <RejectedRegion>[];
        if (refused.isNotEmpty) {
          rejectedRegions += refused.length;
          for (final entry in rejectionTally(refused).entries) {
            rejectedByReason.update(
              entry.key,
              (value) => value + entry.value,
              ifAbsent: () => entry.value,
            );
          }
          final message = rejectedRegionsMessage(refused);
          if (message != null) warnings.add('${asset.name}: $message');
        }
        final failure = segmentationWarnings[fallbackId];
        if (failure != null) warnings.add(failure);
      }
      progress(index, 'إضافة المستمسكات');
    }

    if (hasNewItems) {
      final centeredItemIds = <String>{};
      final arrangement = arrangeDocuments(
        current,
        keepPlaced: keepPlaced,
        onCenteringPass: centeredItemIds.addAll,
      );
      current = await projects.save(arrangement.result);
      ledger?.settleCentering(
        centerEnabled: current.layout.centerCaptures,
        placed: (itemId) => current.items.any(
          (item) => item.id == itemId && item.pageIndex != null,
        ),
        centeredItemIds: centeredItemIds,
      );
      if (arrangement.unplaced.isNotEmpty) {
        warnings.add(
          '${arrangement.unplaced.length} مستمسك بقي خارج الورقة؛ '
          'راجع الأسباب الفردية التالية. لم يُصغّر أو يُقص أي مستمسك لتلائمه.',
        );
        for (final id in arrangement.unplaced) {
          final item = current.items.firstWhere((entry) => entry.id == id);
          warnings.add(unplacedDocumentMessage(current, item));
        }
      }
      for (final id in arrangement.awaitingSize) {
        final item = current.items.firstWhere((entry) => entry.id == id);
        warnings.add(unplacedDocumentMessage(current, item));
      }
    }
    if ((cancellation?.isCancelled ?? false) &&
        !warnings.any((warning) => warning.contains('أُلغيت العملية'))) {
      warnings.add(
        'أُلغيت العملية؛ بقيت الصور غير المعالجة محفوظة في المشروع.',
      );
    }

    return AutomaticLayoutReport(
      project: current,
      cropped: cropped,
      notDetected: notDetected,
      recognized: recognized,
      needsReview: needsReview,
      boundaryNeedsReview: boundaryNeedsReview,
      multiDocumentImages: multiDocumentImages,
      rejectedRegions: rejectedRegions,
      rejectedByReason: rejectedByReason,
      warnings: warnings,
    );
  }

  /// The pre-existing single-document import path. Kept separate from
  /// multi-region dispatch; boundary analysis continues, while category stays
  /// `unknown` without independent OCR/visual evidence.
  Future<AutomaticLayoutReport> _arrangeLegacyImportedImages(
    Project project,
    Iterable<String> assetIds, {
    bool keepPlaced = true,
    bool deferArrangement = false,
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
    IntakeOptions? options,
    IntakeBatchLog? stageLog,
    ProcessingLedger? ledger,
  }) async {
    var current = project;
    var cropped = 0;
    var notDetected = 0;
    var boundaryNeedsReview = 0;
    // The legacy route currently has no independent kind classifier.
    var recognized = 0;
    final warnings = <String>[];
    final newItems = <DocumentItem>[];
    final ids = assetIds.toSet().toList();

    void progress(int completed) => onProgress?.call(
      BatchProgress(
        total: ids.length,
        completed: completed,
        stage: 'تحليل الصور',
      ),
    );

    progress(0);
    for (var index = 0; index < ids.length; index++) {
      if (cancellation?.isCancelled ?? false) {
        for (final skippedId in ids.skip(index)) {
          final skippedAsset = current.assets
              .where((entry) => entry.id == skippedId)
              .firstOrNull;
          ledger
            ?..image(
              skippedId,
              name: skippedAsset?.name ?? '',
              width: skippedAsset?.width,
              height: skippedAsset?.height,
            )
            ..cancelled(
              skippedId,
              ProcessingStage.previewPreparation,
              reason: 'أُلغيت عملية التحليل قبل تجهيز معاينة هذه الصورة.',
              actionTaken: 'بقيت الصورة الأصلية محفوظة دون تغيير.',
            );
        }
        break;
      }
      final id = ids[index];
      final assetIndex = current.assets.indexWhere((entry) => entry.id == id);
      require(assetIndex >= 0, 'الصورة المراد ترتيبها ليست ضمن المشروع.');
      var asset = current.assets[assetIndex];
      ledger?.image(
        id,
        name: asset.name,
        width: asset.width,
        height: asset.height,
      );
      if (current.items.any((item) => item.assetId == id)) {
        ledger
          ?..notApplicable(
            id,
            ProcessingStage.previewPreparation,
            reason: 'لم تُجهز معاينة لأن الصورة ممثلة بعنصر قائم.',
          )
          ..notApplicable(
            id,
            ProcessingStage.preprocessing,
            reason: 'لا يحتاج العنصر القائم إلى معالجة مسبقة جديدة.',
          )
          ..overridden(
            id,
            ProcessingStage.analysis,
            reason: 'الصورة ممثلة بعنصر في المشروع؛ لم يُكرر تحليل الاستيراد.',
          )
          ..notApplicable(
            id,
            ProcessingStage.detection,
            reason: 'لا يلزم إنشاء عنصر أو اكتشاف جديد للصورة الممثلة.',
          )
          ..notApplicable(
            id,
            ProcessingStage.confidence,
            reason: 'لم تُشغّل مراحل كشف أو تصنيف جديدة.',
          )
          ..notApplicable(
            id,
            ProcessingStage.automaticClassification,
            reason: 'لا توجد عملية تصنيف جديدة لهذه الصورة.',
          )
          ..notApplicable(
            id,
            ProcessingStage.userClassification,
            reason: 'لا يوجد اختيار نوع جديد لهذه الصورة.',
          )
          ..notApplicable(
            id,
            ProcessingStage.faceVerification,
            reason: 'لا يوجد مستند جديد للتحقق من وجهه.',
          );
        progress(index + 1);
        continue;
      }
      double? warpedAspect;

      final kind = options?.kind ?? DocumentKind.unknown;
      final side = options?.side ?? SideKind.unknown;
      final documentId = '${asset.id}-d0';
      final document = ledger?.document(
        id,
        documentId: documentId,
        index: index + 1,
        kind: kind,
        side: side,
        kindSource: options?.assertsKind == true
            ? RecordSource.user
            : RecordSource.unknown,
        sideSource: options?.assertsSide == true
            ? RecordSource.user
            : RecordSource.unknown,
      );
      ProcessingStage activeImageStage = ProcessingStage.previewPreparation;
      void fillUnmeasuredStages(String reason) {
        if (ledger == null) return;
        for (final stage in [
          ProcessingStage.analysis,
          ProcessingStage.detection,
          ProcessingStage.confidence,
        ]) {
          if (ledger.existingImage(id)?.stageOf(stage) == null) {
            ledger.notApplicable(id, stage, reason: reason);
          }
        }
        if (document != null) {
          for (final stage in [
            ProcessingStage.boundaryCorners,
            ProcessingStage.geometryCheck,
            ProcessingStage.boundaryReview,
            ProcessingStage.perspective,
            ProcessingStage.crop,
            ProcessingStage.outputEnhancement,
          ]) {
            if (document.statusOf(stage) == null) {
              ledger.documentNotApplicable(
                id,
                documentId,
                stage,
                reason: reason,
              );
            }
          }
        }
      }

      final editor = imageEditor;
      final stages = stageLog?.forAsset(id, name: asset.name);
      if (editor == null) {
        notDetected++;
        warnings.add('${asset.name}: كشف الحدود غير متاح في هذا البناء.');
        stages?.block(
          JourneyStage.detection,
          'كشف الحدود غير متاح في هذا البناء؛ لم تُقَس أي حدود.',
        );
        ledger
          ?..notApplicable(
            id,
            ProcessingStage.previewPreparation,
            reason: 'لا يتوفر محرر الصور لتجهيز معاينة الكشف.',
          )
          ..notApplicable(
            id,
            ProcessingStage.analysis,
            reason: 'مسار الكشف التلقائي غير متاح في هذا البناء.',
          )
          ..notApplicable(
            id,
            ProcessingStage.detection,
            reason: 'لم يتوفر كاشف حدود في هذا البناء.',
          )
          ..notApplicable(
            id,
            ProcessingStage.confidence,
            reason: 'لم تُنتج مرحلة الكشف أي درجة ثقة.',
          );
        if (document != null) {
          for (final stage in [
            ProcessingStage.boundaryCorners,
            ProcessingStage.geometryCheck,
            ProcessingStage.boundaryReview,
            ProcessingStage.perspective,
            ProcessingStage.crop,
            ProcessingStage.outputEnhancement,
          ]) {
            ledger?.documentNotApplicable(
              id,
              documentId,
              stage,
              reason: 'لا يوجد كاشف حدود يتيح تنفيذ هذه المرحلة.',
            );
          }
        }
      } else {
        try {
          final previewClock = Stopwatch()..start();
          final EditorSource source;
          try {
            source = await editor.open(asset, cancellation: cancellation);
          } on OperationCancelled {
            previewClock.stop();
            ledger?.cancelled(
              id,
              ProcessingStage.previewPreparation,
              reason: 'أُلغيت تهيئة المعاينة عند نقطة آمنة.',
              durationMs: previewClock.elapsedMilliseconds,
              actionTaken: 'بقيت الصورة الأصلية محفوظة.',
            );
            rethrow;
          } catch (error) {
            previewClock.stop();
            ledger?.failed(
              id,
              ProcessingStage.previewPreparation,
              error: error,
              durationMs: previewClock.elapsedMilliseconds,
              reason: 'تعذر تجهيز معاينة الصورة للكشف عن الحدود.',
              diagnostics: const ['preview_open_failed'],
              actionTaken: 'بقيت الصورة الأصلية محفوظة للمراجعة اليدوية.',
            );
            rethrow;
          }
          previewClock.stop();
          final previewValid =
              source.preview.isNotEmpty &&
              source.width > 0 &&
              source.height > 0;
          ledger?.succeeded(
            id,
            ProcessingStage.previewPreparation,
            reason: 'جُهزت معاينة محدودة لقياس حدود الصورة.',
            evidence: StageEvidence(
              verified: previewValid,
              checks: [
                EvidenceCheck(
                  name: 'preview_not_empty',
                  passed: source.preview.isNotEmpty,
                  detail: '${source.preview.length}',
                ),
                EvidenceCheck(
                  name: 'dimensions_positive',
                  passed: source.width > 0 && source.height > 0,
                ),
              ],
              counts: {'preview_bytes': source.preview.length},
            ),
            results: {'width': source.width, 'height': source.height},
            durationMs: previewClock.elapsedMilliseconds,
          );

          activeImageStage = ProcessingStage.analysis;
          final analysisClock = Stopwatch()..start();
          final BoundaryProposal? rawProposal;
          final List<Point2>? corners;
          try {
            rawProposal = editor is BoundaryProposalImageEditor
                ? await editor.suggestProposal(
                    source.preview,
                    cancellation: cancellation,
                  )
                : null;
            corners = editor is BoundaryProposalImageEditor
                ? rawProposal?.corners
                : await editor.suggest(source.preview);
          } on OperationCancelled {
            analysisClock.stop();
            ledger?.cancelled(
              id,
              ProcessingStage.analysis,
              reason: 'أُلغيت معالجة حدود الصورة عند نقطة آمنة.',
              durationMs: analysisClock.elapsedMilliseconds,
              actionTaken: 'بقيت الصورة الأصلية محفوظة.',
            );
            rethrow;
          } catch (error) {
            analysisClock.stop();
            ledger?.failed(
              id,
              ProcessingStage.analysis,
              error: error,
              durationMs: analysisClock.elapsedMilliseconds,
              reason: 'تعذر إكمال تحليل حدود الصورة.',
              diagnostics: const ['boundary_analysis_failed'],
              actionTaken: 'بقيت الصورة كاملة ولم يُطبق قص تلقائي.',
            );
            rethrow;
          }
          analysisClock.stop();
          ledger
            ?..succeeded(
              id,
              ProcessingStage.analysis,
              reason: 'أعاد تحليل الحدود نتيجة قابلة للتقييم.',
              evidence: StageEvidence(
                verified: true,
                checks: [
                  EvidenceCheck(name: 'proposal_call_returned', passed: true),
                ],
                counts: {'proposals': corners == null ? 0 : 1},
              ),
              results: {
                'proposal_count': corners == null ? 0 : 1,
                if (rawProposal != null) 'producer': rawProposal.producer.name,
              },
              durationMs: analysisClock.elapsedMilliseconds,
            )
            ..succeeded(
              id,
              ProcessingStage.detection,
              reason: corners == null
                  ? 'اكتمل الكشف دون اقتراح رباعي حدود.'
                  : 'قاس الكاشف اقتراحاً واحداً للحدود.',
              evidence: StageEvidence(
                verified: true,
                checks: [
                  EvidenceCheck(
                    name: 'detection_result_measured',
                    passed: true,
                  ),
                ],
                counts: {'regions': corners == null ? 0 : 1},
              ),
              results: {'proposal_present': corners != null},
              actionTaken: corners == null
                  ? 'بقيت الصورة كاملة للمراجعة اليدوية.'
                  : 'انتقل الاقتراح إلى التحقق الهندسي.',
            );
          final boundaryConfidence = rawProposal?.modelConfidence;
          if (boundaryConfidence == null) {
            ledger?.notApplicable(
              id,
              ProcessingStage.confidence,
              reason: 'لم يصدر هذا المسار درجة ثقة للحدود أو التصنيف.',
            );
          } else if (boundaryConfidence.isFinite &&
              boundaryConfidence >= 0 &&
              boundaryConfidence <= 1) {
            ledger?.succeeded(
              id,
              ProcessingStage.confidence,
              reason: 'سُجلت درجة الثقة التي أصدرها كاشف الحدود.',
              evidence: StageEvidence(
                verified: true,
                checks: [
                  EvidenceCheck(name: 'confidence_finite', passed: true),
                  EvidenceCheck(name: 'confidence_in_range', passed: true),
                ],
                counts: {'scores': 1},
                note: 'الدرجة صادرة من الكاشف وغير موصوفة بأنها معايرة.',
              ),
              results: {'boundary_model': boundaryConfidence},
            );
          } else {
            ledger?.failed(
              id,
              ProcessingStage.confidence,
              reason: 'أصدر كاشف الحدود درجة خارج المجال 0 إلى 1.',
              errorType: 'InvalidConfidence',
              errorCode: FailureCode.validation,
              diagnostics: const ['confidence_out_of_range'],
            );
          }
          if (corners == null) {
            notDetected++;
            warnings.add(
              '${asset.name}: لا يتوفر كشف تلقائي للحدود في هذا الإصدار؛ بقيت الصورة كاملة ويمكن ضبط القص يدوياً.',
            );
            stages?.block(
              JourneyStage.detection,
              'لم يُقترح أي رباعي حدود لهذه الصورة؛ لا إحداثيات لتُعتمد.',
            );
            if (document != null) {
              for (final stage in [
                ProcessingStage.boundaryCorners,
                ProcessingStage.geometryCheck,
                ProcessingStage.boundaryReview,
                ProcessingStage.perspective,
                ProcessingStage.crop,
                ProcessingStage.outputEnhancement,
              ]) {
                ledger?.documentNotApplicable(
                  id,
                  documentId,
                  stage,
                  reason: 'لم يقترح الكاشف حدوداً يمكن التحقق منها أو قصها.',
                );
              }
            }
          } else {
            if (document != null) {
              if (corners.length == 4) {
                ledger?.documentSucceeded(
                  id,
                  documentId,
                  ProcessingStage.boundaryCorners,
                  reason: 'أعاد الكاشف أربع زوايا قابلة للقياس.',
                  evidence: StageEvidence(
                    verified: true,
                    checks: [
                      EvidenceCheck(
                        name: 'four_corners',
                        passed: true,
                        detail: '${corners.length}',
                      ),
                    ],
                  ),
                  results: {
                    'producer': rawProposal?.producer.name ?? 'detector',
                  },
                );
              } else {
                ledger?.documentFailed(
                  id,
                  documentId,
                  ProcessingStage.boundaryCorners,
                  reason: 'أعاد الكاشف عدداً غير صالح من الزوايا.',
                  errorType: 'InvalidBoundaryProposal',
                  errorCode: 'invalid_boundary_proposal',
                  diagnostics: const ['corner_count_not_four'],
                  results: {'corners': corners.length},
                  actionTaken: 'لم يُسمح بالقص التلقائي.',
                );
              }
            }
            // Boundary authorization is independent of the file name,
            // document-kind classifier, OCR and catalog dimensions. A valid
            // measured quad is judged by geometry and detector review rules;
            // the accepted crop preserves its measured aspect.
            final decision = verifyBoundary(
              BoundaryProposal(
                producer:
                    rawProposal?.producer ??
                    BoundaryProducer.wholeFrameDetector,
                corners: corners,
                modelConfidence: rawProposal?.modelConfidence,
                minAutoAcceptConfidence: rawProposal?.minAutoAcceptConfidence,
                touchesFrameEdge: rawProposal?.touchesFrameEdge ?? false,
                // Keep the proposer's review demand (for example
                // modelDisagreement). Dropping it would let a disputed proposal
                // look like an ordinary one on this path.
                forceReview: rawProposal?.forceReview ?? false,
                forceReviewReason: rawProposal?.forceReviewReason,
              ),
              sourceWidth: source.width,
              sourceHeight: source.height,
            );
            // Option 3: the person ticked «موافقة على القص المقترح». That is an
            // approval of the DETECTOR's geometry, however its aspect compares
            // to the catalog — not a relaxation of any threshold. The detector
            // still refuses what it refuses: only geometry this build already
            // measured as usable is approved, and a proposal with no usable
            // geometry is still reported instead of being cropped anyway.
            final approveSuggested = options?.acceptSuggestedBoundary ?? false;
            final effective = approveSuggested
                ? decision.approvedByUser()
                : decision;
            final authorization = effective.cropAuthorization;
            if (document != null) {
              final assessment = effective.verification.assessment;
              if (corners.length == 4 && assessment?.acceptable == true) {
                ledger?.documentSucceeded(
                  id,
                  documentId,
                  ProcessingStage.geometryCheck,
                  reason: 'اجتاز رباعي الحدود القياس الهندسي.',
                  evidence: StageEvidence(
                    verified: true,
                    checks: [
                      EvidenceCheck(name: 'quad_acceptable', passed: true),
                      EvidenceCheck(
                        name: 'four_corners',
                        passed: corners.length == 4,
                      ),
                    ],
                  ),
                  results: {
                    if (assessment?.geometryConfidence != null)
                      'geometry_confidence': assessment!.geometryConfidence,
                    if (assessment?.aspect != null)
                      'aspect': assessment!.aspect,
                    if (assessment?.areaFraction != null)
                      'area_fraction': assessment!.areaFraction,
                  },
                );
              } else if (corners.length == 4 && assessment != null) {
                ledger?.documentFailed(
                  id,
                  documentId,
                  ProcessingStage.geometryCheck,
                  reason: 'رفض التحقق الهندسي رباعي الحدود المقترح.',
                  errorType: 'GeometryRejected',
                  errorCode: assessment.rejection?.name ?? 'geometry_rejected',
                  diagnostics: [
                    for (final reason in effective.verification.reasons)
                      reason.name,
                    if (effective.verification.reasons.isEmpty)
                      'quad_assessment_rejected',
                  ],
                  results: {
                    if (assessment.rejection != null)
                      'rejection': assessment.rejection!.name,
                  },
                  actionTaken: 'لم يُنفذ القص التلقائي.',
                );
              } else {
                ledger?.documentNotApplicable(
                  id,
                  documentId,
                  ProcessingStage.geometryCheck,
                  reason: 'لا يوجد رباعي من أربع زوايا لتقييمه هندسياً.',
                );
              }
              if (authorization == null) {
                ledger?.documentOverridden(
                  id,
                  documentId,
                  ProcessingStage.boundaryReview,
                  reason: effective.verification.hasUsableGeometry
                      ? 'تحتاج الحدود مراجعة أو موافقة؛ لم تُمنح صلاحية القص الآلي.'
                      : 'لم تجتز الحدود بوابة القبول؛ أُبقي المصدر كاملاً.',
                  results: {
                    'decision': effective.kind.name,
                    'reasons': effective.verification.reasons.length,
                    'userApproved': false,
                  },
                  actionTaken: 'بقيت الصورة الأصلية قابلة للقص اليدوي.',
                );
              } else if (effective.verification.userApproved) {
                ledger?.documentOverridden(
                  id,
                  documentId,
                  ProcessingStage.boundaryReview,
                  reason: 'اعتمد المستخدم الحدود المقاسة صراحةً.',
                  inputs: {'approval': 'user'},
                  results: {'decision': effective.kind.name},
                  actionTaken: 'سُمح بالقص بعد موافقة المستخدم.',
                );
              } else {
                ledger?.documentSucceeded(
                  id,
                  documentId,
                  ProcessingStage.boundaryReview,
                  reason: 'اجتازت الحدود بوابة القبول الآلي.',
                  evidence: StageEvidence(
                    verified: true,
                    checks: [
                      EvidenceCheck(name: 'crop_authorized', passed: true),
                      EvidenceCheck(
                        name: 'user_approval_required',
                        passed: true,
                      ),
                    ],
                  ),
                  results: {'decision': effective.kind.name},
                );
              }
            }
            if (approveSuggested && authorization != null) {
              stages?.pass(
                JourneyStage.detection,
                effective.verification.userApproved &&
                        decision.kind != BoundaryDecisionKind.accepted
                    ? 'اعتمد المستخدم الحدود المقترحة كما قيست، دون مراجعة.'
                    : 'قُبلت الحدود هندسياً دون الحاجة إلى اعتماد إضافي.',
                fields: {
                  'approvedByUser': effective.verification.userApproved,
                  'detectorVerdict': decision.kind.name,
                },
              );
            }
            if (IntakeDiagnostics.isActive) {
              IntakeDiagnostics.record(
                IntakeDiagnosticEntry(
                  stage: 'boundary_decision',
                  assetId: asset.id,
                  modelId: editor is BoundaryProposalImageEditor
                      ? (editor.boundaryModelId ?? 'external-boundary-proposal')
                      : 'custom-image-editor',
                  candidateCount: 1,
                  sourceWidth: source.width,
                  sourceHeight: source.height,
                  verdict: decision.kind.name,
                  documentKind: DocumentKind.unknown,
                  reasons: [
                    for (final r in decision.verification.reasons) r.name,
                  ],
                ),
              );
            }
            if (authorization == null) {
              if (decision.verification.hasUsableGeometry) {
                boundaryNeedsReview++;
              } else {
                notDetected++;
              }
              if ((rawProposal?.producer == BoundaryProducer.learnedModel ||
                      rawProposal?.producer == BoundaryProducer.detector) &&
                  decision.verification.hasUsableGeometry) {
                asset = asset.withSuggestedCrop(corners);
                current = current.copyWith(
                  assets: [
                    for (final entry in current.assets)
                      entry.id == asset.id ? asset : entry,
                  ],
                );
              }
              for (final reason in decision.verification.reasons) {
                warnings.add(
                  '${asset.name}: ${boundaryReviewReasonMessage(reason, modelConfidence: decision.proposal.modelConfidence, minAutoAcceptConfidence: decision.proposal.minAutoAcceptConfidence)}',
                );
              }
            } else {
              try {
                current = await applyAuthorizedCrop(
                  current,
                  asset,
                  authorization,
                  sourceWidth: source.width,
                  sourceHeight: source.height,
                );
              } on OperationCancelled {
                ledger?.documentCancelled(
                  id,
                  documentId,
                  ProcessingStage.perspective,
                  reason: 'أُلغيت معالجة المنظور عند نقطة آمنة.',
                  actionTaken: 'بقي المصدر الأصلي محفوظاً.',
                );
                ledger?.documentCancelled(
                  id,
                  documentId,
                  ProcessingStage.crop,
                  reason: 'أُلغيت المعالجة قبل إنتاج القص.',
                  actionTaken: 'لم يُعلن نجاح القص.',
                );
                rethrow;
              } catch (error) {
                ledger?.documentFailed(
                  id,
                  documentId,
                  ProcessingStage.perspective,
                  error: error,
                  reason: 'تعذر تصحيح منظور الحدود المقبولة.',
                  diagnostics: const ['automatic_perspective_crop_failed'],
                  actionTaken: 'بقي المصدر الأصلي دون قص.',
                );
                ledger?.documentStopped(
                  id,
                  documentId,
                  ProcessingStage.crop,
                  reason: 'لم يبدأ القص لأن تصحيح المنظور لم يكتمل.',
                  actionTaken: 'يحتاج المصدر إلى مراجعة أو إعادة محاولة.',
                );
                rethrow;
              }
              // The accepted crop creates a new revision with its measured
              // output dimensions. Use that aspect for the provisional size;
              // the pre-crop camera frame is a different image region.
              asset = current.assets.firstWhere((entry) => entry.id == id);
              warpedAspect = effective.verification.measuredAspect;
              cropped++;
              if (document != null) {
                final outputValid =
                    asset.crop != null &&
                    asset.revisionId != null &&
                    asset.width > 0 &&
                    asset.height > 0;
                final outputChecks = [
                  EvidenceCheck(
                    name: 'crop_geometry_saved',
                    passed: asset.crop != null,
                  ),
                  EvidenceCheck(
                    name: 'revision_written',
                    passed: asset.revisionId != null,
                  ),
                  EvidenceCheck(
                    name: 'output_dimensions_positive',
                    passed: asset.width > 0 && asset.height > 0,
                  ),
                ];
                ledger
                  ?..documentSucceeded(
                    id,
                    documentId,
                    ProcessingStage.perspective,
                    reason: 'حُفظت نسخة مصححة المنظور من الرباعي المقبول.',
                    evidence: StageEvidence(
                      verified: outputValid,
                      checks: outputChecks,
                    ),
                    results: {
                      'width': asset.width,
                      'height': asset.height,
                      if (asset.revisionId != null)
                        'revision': asset.revisionId!,
                    },
                  )
                  ..documentSucceeded(
                    id,
                    documentId,
                    ProcessingStage.crop,
                    reason: 'أُنتجت نسخة قص مقروءة من الصورة الأصلية.',
                    evidence: StageEvidence(
                      verified: outputValid,
                      checks: outputChecks,
                    ),
                    results: {'width': asset.width, 'height': asset.height},
                    itemCount: 1,
                  )
                  ..documentSucceeded(
                    id,
                    documentId,
                    ProcessingStage.outputEnhancement,
                    reason: 'حُفظت نسخة العمل المعدلة بإعدادات الصورة.',
                    evidence: StageEvidence(
                      verified:
                          asset.revisionId != null &&
                          asset.workingPath.isNotEmpty,
                      checks: [
                        EvidenceCheck(
                          name: 'revision_written',
                          passed: asset.revisionId != null,
                        ),
                        EvidenceCheck(
                          name: 'working_file_present',
                          passed: asset.workingPath.isNotEmpty,
                        ),
                      ],
                    ),
                    results: {
                      'quarter_turns': asset.adjustments.quarterTurns,
                      'sharpness': asset.adjustments.sharpness,
                    },
                  );
              }
            }
          }
        } on OperationCancelled {
          final currentStatus = ledger
              ?.existingImage(id)
              ?.statusOf(activeImageStage);
          if (currentStatus != StageStatus.cancelled &&
              currentStatus != StageStatus.succeeded) {
            ledger?.cancelled(
              id,
              activeImageStage,
              reason: 'أُلغيت المعالجة عند أول نقطة آمنة.',
              actionTaken: 'بقيت الصورة الأصلية محفوظة للمراجعة اليدوية.',
            );
          }
          fillUnmeasuredStages('أُوقفت المراحل التابعة بعد إلغاء المعالجة.');
          warnings.add('أُلغيت العملية؛ بقيت الصورة الأصلية محفوظة.');
          break;
        } on RevisionConflict {
          fillUnmeasuredStages('توقفت المراحل اللاحقة بسبب تعارض حفظ المشروع.');
          rethrow;
        } catch (error) {
          fillUnmeasuredStages(
            'لم تُنفذ هذه المرحلة أو ما بعدها في مسار الاسترداد اليدوي.',
          );
          notDetected++;
          warnings.add(
            '${asset.name}: تعذر تطبيق القص التلقائي؛ بقي الأصل محفوظاً (${userError(error)}).',
          );
        }
      }
      fillUnmeasuredStages('لم ينطبق كشف الحدود أو القص الآلي على هذه الصورة.');
      ledger?.notApplicable(
        id,
        ProcessingStage.preprocessing,
        reason: 'لم يُشغّل مسار OCR أو معالجة نصية في المسار القديم.',
      );
      if (options?.assertsKind == true) {
        ledger
          ?..overridden(
            id,
            ProcessingStage.automaticClassification,
            reason: 'حدّد المستخدم النوع؛ لم يُستخدم مصنّف آلي.',
            inputs: {'kind': kind.name},
          )
          ..succeeded(
            id,
            ProcessingStage.userClassification,
            reason: 'اعتُمد النوع الذي حدده المستخدم على العنصر.',
            evidence: StageEvidence(
              verified: true,
              checks: [EvidenceCheck(name: 'user_kind_asserted', passed: true)],
            ),
            inputs: {'kind': kind.name},
            results: {'source': 'user'},
          );
      } else {
        ledger
          ?..notApplicable(
            id,
            ProcessingStage.automaticClassification,
            reason: 'لا يتوفر في هذا المسار مصنّف نوع مستقل.',
          )
          ..notApplicable(
            id,
            ProcessingStage.userClassification,
            reason: 'لم يحدد المستخدم نوع المستند.',
          );
      }

      // The legacy import path has no independent OCR/visual type model. Keep
      // the measured image editable with a provisional size; never infer a
      // catalog kind from its name or aspect ratio.
      const recognitionConfidence = 0.0;
      if (options != null && options.assertsKind) {
        stages?.skip(
          JourneyStage.recognition,
          'حدّد المستخدم النوع «${kind.label}»؛ لم يُستخدم مصنّف آلي.',
          fields: {'kind': kind.name, 'assertedByUser': true},
        );
      } else {
        stages?.review(
          JourneyStage.recognition,
          'لم يحدّد المستخدم نوعاً ولم يتوفر مصنّف مستقل؛ النوع غير معروف.',
        );
      }
      final catalogSize = current.catalog.sizeForWarp(
        kind,
        measuredAspect: warpedAspect,
        landscape: asset.width >= asset.height,
      );
      final size =
          catalogSize ??
          provisionalSize(width: asset.width, height: asset.height);
      if (catalogSize != null) recognized++;
      if (kind == DocumentKind.unknown) {
        warnings.add(
          '${asset.name}: لم يُتعرّف على نوع المستمسك؛ اختر النوع من تبويب «المستمسك» ليُطبَّق مقاسه ويوضع على الورقة.',
        );
      }
      final nextZ = current.items.fold<int>(
        0,
        (value, item) => math.max(value, item.zIndex),
      );
      final createdItemId = newId();
      newItems.add(
        DocumentItem(
          id: createdItemId,
          assetId: asset.id,
          x: current.paper.margins.left,
          y: current.paper.margins.top,
          width: size.width,
          height: size.height,
          pageIndex: null,
          zIndex: nextZ + newItems.length + 1,
          documentKind: kind,
          recognitionConfidence: recognitionConfidence,
          sizeConfirmed: catalogSize != null,
        ),
      );
      if (document != null) {
        ledger?.linkDocument(
          id,
          documentId,
          itemId: createdItemId,
          outcome: catalogSize == null
              ? 'أُنشئ عنصر للصورة بانتظار مراجعة النوع أو المقاس.'
              : 'أُنشئ عنصر بحجم كتالوج مقاس.',
        );
      }
      if (IntakeDiagnostics.isActive) {
        IntakeDiagnostics.record(
          IntakeDiagnosticEntry(
            stage: 'intake_item_created',
            assetId: asset.id,
            itemId: createdItemId,
            sourceWidth: asset.width,
            sourceHeight: asset.height,
            verdict: catalogSize == null ? 'awaiting_size' : 'sized',
            documentKind: kind,
            sizeConfirmed: catalogSize != null,
            widthMm: size.width,
            heightMm: size.height,
          ),
        );
      }
      progress(index + 1);
    }

    if (cancellation?.isCancelled ?? false) {
      warnings.add(
        'أُلغيت العملية؛ بقيت الصور غير المعالجة محفوظة في المشروع.',
      );
    }
    if (newItems.isEmpty) {
      return AutomaticLayoutReport(
        project: current,
        cropped: cropped,
        notDetected: notDetected,
        recognized: recognized,
        boundaryNeedsReview: boundaryNeedsReview,
        warnings: warnings,
      );
    }
    current = current.copyWith(items: [...current.items, ...newItems]);
    if (options != null) {
      current = attachIntakeChoices(current, newItems, options, newId);
    }
    for (final stagedItem in newItems) {
      final item = current.items.firstWhere(
        (entry) => entry.id == stagedItem.id,
      );
      final documentId = '${item.assetId}-d0';
      final asset = current.assets.firstWhere(
        (entry) => entry.id == item.assetId,
      );
      final record = item.documentId == null
          ? null
          : current.documents
                .where((entry) => entry.id == item.documentId)
                .firstOrNull;
      final selectedSide = options?.side ?? SideKind.unknown;
      if (record != null &&
          ledger?.existingDocument(item.assetId, documentId) != null) {
        final sourceId = asset.derivedFrom ?? asset.id;
        final modelVerified =
            item.documentId == record.id &&
            record.sourceImageId == sourceId &&
            record.provenance.layoutItemIds.contains(item.id);
        if (modelVerified) {
          ledger?.documentSucceeded(
            item.assetId,
            documentId,
            ProcessingStage.documentModel,
            reason: 'أُنشئ سجل المستند وربط بالعنصر ومصدر الصورة.',
            evidence: StageEvidence(
              verified: true,
              checks: [
                EvidenceCheck(name: 'record_created', passed: true),
                EvidenceCheck(
                  name: 'record_linked_to_source',
                  passed: record.sourceImageId == sourceId,
                ),
                EvidenceCheck(
                  name: 'item_linked_to_record',
                  passed: item.documentId == record.id,
                ),
              ],
            ),
            results: {'record': record.id},
          );
          ledger?.linkDocument(
            item.assetId,
            documentId,
            recordId: record.id,
            itemId: item.id,
            assetId: item.assetId,
          );
        } else {
          ledger?.documentFailed(
            item.assetId,
            documentId,
            ProcessingStage.documentModel,
            reason: 'لم تتطابق روابط سجل المستند والعنصر ومصدره.',
            errorType: 'DocumentLinkMismatch',
            errorCode: 'document_link_mismatch',
            diagnostics: const ['record_item_source_mismatch'],
          );
        }
      } else {
        ledger?.documentNotApplicable(
          item.assetId,
          documentId,
          ProcessingStage.documentModel,
          reason: 'يمثل المسار القديم الصورة بعنصر دون سجل مستند مستقل.',
        );
      }
      if (item.documentKind != DocumentKind.unknown && item.sizeConfirmed) {
        ledger?.documentSucceeded(
          item.assetId,
          documentId,
          ProcessingStage.typeSideSize,
          reason: 'ثُبت النوع ومقاس الكتالوج على عنصر الصفحة.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(
                name: 'kind_assigned',
                passed: item.documentKind != DocumentKind.unknown,
              ),
              EvidenceCheck(name: 'size_confirmed', passed: item.sizeConfirmed),
            ],
          ),
          results: {
            'kind': item.documentKind.name,
            'side': selectedSide.name,
            'width_mm': item.width,
            'height_mm': item.height,
          },
        );
      } else {
        ledger?.documentStopped(
          item.assetId,
          documentId,
          ProcessingStage.typeSideSize,
          reason: 'النوع أو المقاس غير مؤكد؛ بقي القياس مؤقتاً للمراجعة.',
          inputs: {'kind': item.documentKind.name},
          actionTaken: 'لم تُسجَّل نتيجة النوع والمقاس كنجاح.',
        );
      }
      final hasMeasuredDocument =
          record?.sides.any((entry) => entry.detection != null) ?? false;
      if (selectedSide == SideKind.unknown || !hasMeasuredDocument) {
        ledger?.notApplicable(
          item.assetId,
          ProcessingStage.faceVerification,
          reason: selectedSide == SideKind.unknown
              ? 'لم يحدد المستخدم وجهاً للمستند.'
              : 'لا يوجد مستند مقاس للتحقق من الوجه المحدد.',
        );
      } else if (record!.sides.any((entry) => entry.side == selectedSide)) {
        ledger?.succeeded(
          item.assetId,
          ProcessingStage.faceVerification,
          reason: 'حُفظ الوجه الذي حدده المستخدم على سجل المستند.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(name: 'side_asserted', passed: true),
              EvidenceCheck(name: 'side_saved', passed: true),
            ],
          ),
          inputs: {'side': selectedSide.name},
        );
      } else {
        ledger?.failed(
          item.assetId,
          ProcessingStage.faceVerification,
          reason: 'لم يُحفظ الوجه الذي اختاره المستخدم على سجل المستند.',
          errorType: 'SideNotSaved',
          errorCode: 'side_not_saved',
          diagnostics: const ['side_assertion_not_persisted'],
        );
      }
      if (!current.layout.centerCaptures) {
        ledger?.documentOverridden(
          item.assetId,
          documentId,
          ProcessingStage.centering,
          reason: 'عطّل المستخدم خيار التوسيط لهذه الدفعة.',
          actionTaken: 'بقي العنصر دون توسيط آلي.',
        );
      } else {
        ledger?.documentStopped(
          item.assetId,
          documentId,
          ProcessingStage.centering,
          reason: 'ينتظر العنصر الترتيب النهائي قبل حسم التوسيط.',
          actionTaken: 'يُتحقق من وجود العنصر على الورقة بعد الحفظ.',
        );
      }
    }
    Project saved;
    try {
      if (deferArrangement) {
        saved = await projects.save(current);
      } else {
        final centeredItemIds = <String>{};
        final arrangement = arrangeDocuments(
          current,
          keepPlaced: keepPlaced,
          onCenteringPass: centeredItemIds.addAll,
        );
        saved = await projects.save(arrangement.result);
        if (arrangement.unplaced.isNotEmpty) {
          warnings.add(
            '${arrangement.unplaced.length} مستمسك بقي خارج الورقة؛ '
            'راجع الأسباب الفردية التالية. لم يُصغّر أو يُقص أي مستمسك لتلائمه.',
          );
          for (final id in arrangement.unplaced) {
            final item = saved.items.firstWhere((entry) => entry.id == id);
            warnings.add(unplacedDocumentMessage(saved, item));
          }
        }
        for (final id in arrangement.awaitingSize) {
          final item = saved.items.firstWhere((entry) => entry.id == id);
          warnings.add(unplacedDocumentMessage(saved, item));
        }
        ledger?.settleCentering(
          centerEnabled: saved.layout.centerCaptures,
          placed: (itemId) => saved.items.any(
            (item) => item.id == itemId && item.pageIndex != null,
          ),
          centeredItemIds: centeredItemIds,
        );
      }
      current = saved;
    } catch (error) {
      for (final item in newItems) {
        final documentId = '${item.assetId}-d0';
        ledger?.documentFailed(
          item.assetId,
          documentId,
          ProcessingStage.saveDocument,
          error: error,
          reason: 'تعذر حفظ عناصر المستندات في المشروع.',
          diagnostics: const ['project_save_failed'],
          actionTaken: 'لم يُعلن نجاح الإضافة إلى المشروع.',
        );
        ledger?.documentStopped(
          item.assetId,
          documentId,
          ProcessingStage.addToProject,
          reason: 'لم تُثبت إضافة العنصر لأن حفظ المشروع تعذر.',
        );
        ledger?.documentStopped(
          item.assetId,
          documentId,
          ProcessingStage.verifyAddition,
          reason: 'لم تُجر قراءة تحقق لأن حفظ المشروع تعذر.',
        );
      }
      rethrow;
    }

    for (final item in newItems) {
      final documentId = '${item.assetId}-d0';
      final savedItem = saved.items
          .where((entry) => entry.id == item.id)
          .firstOrNull;
      final savedAsset = saved.assets
          .where((entry) => entry.id == item.assetId)
          .firstOrNull;
      final recordId = savedItem?.documentId;
      final savedRecord = recordId == null
          ? null
          : saved.documents.where((entry) => entry.id == recordId).firstOrNull;
      final saveVerified =
          savedItem != null &&
          savedAsset != null &&
          savedAsset.workingPath.isNotEmpty &&
          (recordId == null || savedRecord != null);
      if (saveVerified) {
        ledger?.documentSucceeded(
          item.assetId,
          documentId,
          ProcessingStage.saveDocument,
          reason: 'حُفظ العنصر وأصل الصورة وسجل المستند المتاح.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(name: 'asset_saved', passed: savedAsset != null),
              EvidenceCheck(name: 'item_saved', passed: savedItem != null),
              EvidenceCheck(
                name: 'record_saved',
                passed: recordId == null || savedRecord != null,
              ),
            ],
          ),
          results: {'revision': saved.revision},
        );
        ledger?.documentSucceeded(
          item.assetId,
          documentId,
          ProcessingStage.addToProject,
          reason: 'أُضيف عنصر المستند إلى قائمة المشروع.',
          evidence: StageEvidence(
            verified: savedItem != null,
            checks: [
              EvidenceCheck(name: 'item_in_project', passed: savedItem != null),
            ],
            counts: {'items': saved.items.length},
          ),
        );
      } else {
        ledger?.documentFailed(
          item.assetId,
          documentId,
          ProcessingStage.saveDocument,
          reason: 'عاد الحفظ دون أحد مكونات المستند المطلوبة.',
          errorType: 'IncompleteSave',
          errorCode: 'saved_project_incomplete',
          diagnostics: const ['asset_item_or_record_missing'],
        );
        ledger?.documentFailed(
          item.assetId,
          documentId,
          ProcessingStage.addToProject,
          reason: 'لم يظهر عنصر المستند في المشروع المحفوظ.',
          errorType: 'IncompleteSave',
          errorCode: 'item_missing_after_save',
          diagnostics: const ['item_missing_after_save'],
        );
      }
      ledger?.linkDocument(
        item.assetId,
        documentId,
        recordId: recordId,
        itemId: savedItem?.id,
      );
    }

    if (ledger != null && newItems.isNotEmpty) {
      Project? readBack;
      Object? readError;
      try {
        readBack = await projects.get(saved.id);
      } on Object catch (error) {
        readError = error;
      }
      for (final item in newItems) {
        final documentId = '${item.assetId}-d0';
        final recordId = saved.items
            .where((entry) => entry.id == item.id)
            .firstOrNull
            ?.documentId;
        if (readBack == null) {
          ledger.documentFailed(
            item.assetId,
            documentId,
            ProcessingStage.verifyAddition,
            error: readError,
            errorType: 'VerificationReadFailed',
            errorCode: FailureCode.storage,
            reason: 'تعذرت قراءة المشروع المحفوظ للتحقق من الإضافة.',
            diagnostics: const ['read_back_failed'],
            actionTaken: 'بقيت الإضافة غير مؤكدة.',
          );
          continue;
        }
        final confirmedAsset = readBack.assets.any(
          (entry) => entry.id == item.assetId,
        );
        final confirmedItem = readBack.items.any(
          (entry) => entry.id == item.id,
        );
        final confirmedRecord =
            recordId == null ||
            readBack.documents.any((entry) => entry.id == recordId);
        if (confirmedAsset && confirmedItem && confirmedRecord) {
          ledger.documentSucceeded(
            item.assetId,
            documentId,
            ProcessingStage.verifyAddition,
            reason: 'أكدت قراءة المشروع وجود الأصل والعنصر وسجل المستند.',
            evidence: StageEvidence(
              verified: true,
              checks: [
                EvidenceCheck(name: 'asset_in_saved_project', passed: true),
                EvidenceCheck(name: 'item_in_saved_project', passed: true),
                EvidenceCheck(
                  name: 'record_in_saved_project',
                  passed: confirmedRecord,
                ),
              ],
              counts: {'revision': readBack.revision},
            ),
          );
          ledger.linkDocument(
            item.assetId,
            documentId,
            outcome: 'قُرئت الإضافة مجدداً من المشروع المحفوظ.',
          );
        } else {
          ledger.documentFailed(
            item.assetId,
            documentId,
            ProcessingStage.verifyAddition,
            reason: 'لم تظهر كل مكونات المستند عند قراءة المشروع مجدداً.',
            errorType: 'AdditionMissingOnReadBack',
            errorCode: 'addition_missing_on_read_back',
            diagnostics: const ['asset_item_or_record_missing_on_read_back'],
            actionTaken: 'بقيت الإضافة غير مؤكدة.',
          );
        }
      }
    }

    return AutomaticLayoutReport(
      project: current,
      cropped: cropped,
      notDetected: notDetected,
      recognized: recognized,
      boundaryNeedsReview: boundaryNeedsReview,
      warnings: warnings,
    );
  }

  /// A colour-neutral preview of [asset] (crop, quarter turns and sharpness
  /// applied). The editor shows it under a GPU colour matrix while sliders
  /// move, so brightness, contrast and saturation are visible immediately;
  /// the full-resolution revision is written once the user pauses.
  Future<Uint8List> livePreviewBase(
    ImageAsset asset,
    ImageAdjustments adjustments,
  ) {
    final editor = imageEditor;
    require(editor != null, 'خدمة معالجة الصور غير متاحة.');
    final geometry =
        asset.crop ??
        CropDraft.fullImage().toRecipe(asset.width, asset.height).geometry;
    return editor!.preview(
      asset,
      ImageEditRecipe(geometry, adjustments.colorNeutral),
    );
  }

  /// Suggests a non-destructive, local auto-enhancement preset for [asset].
  /// The existing workspace ribbon uses this on the complete image.
  /// CropScreen uses [suggestCropAutoAdjustments] so the statistics describe
  /// the reviewed document, not the surrounding tabletop or background.
  Future<ImageAdjustments> suggestAutoAdjustments(
    Project project,
    ImageAsset asset,
  ) async {
    final editor = imageEditor;
    require(editor != null, 'خدمة معالجة الصور غير متاحة.');
    _requireCurrentImage(project, asset);
    final source = await editor!.open(asset);
    return _suggestAdjustmentsForPreview(
      source.preview,
      quarterTurns: asset.adjustments.quarterTurns,
    );
  }

  /// Analyses a bounded, rectified preview of the current crop draft.
  ///
  /// Geometry is applied once with neutral tone/sharpness settings before the
  /// histogram and edge statistics are measured. The returned settings remain
  /// editable and are not saved until the user reviews and accepts the crop.
  Future<ImageAdjustments> suggestCropAutoAdjustments(
    Project project,
    ImageAsset asset,
    CropGeometry geometry, {
    required int quarterTurns,
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final editor = imageEditor;
    require(editor != null, 'خدمة معالجة الصور غير متاحة.');
    _requireCurrentImage(project, asset);
    require(quarterTurns >= 0 && quarterTurns <= 3, 'زاوية التدوير غير صالحة.');
    final neutralRecipe = ImageEditRecipe(
      geometry,
      ImageAdjustments(quarterTurns: quarterTurns),
    );
    final cropPreview = await editor!.preview(
      asset,
      neutralRecipe,
      cancellation: cancellation,
    );
    cancellation?.throwIfCancelled();
    return _suggestCropAdjustmentsIsolated(
      cropPreview,
      quarterTurns: quarterTurns,
      cancellation: cancellation,
    );
  }

  void _requireCurrentImage(Project project, ImageAsset asset) {
    require(
      project.assets.any(
        (entry) =>
            entry.id == asset.id &&
            entry.originalPath == asset.originalPath &&
            entry.workingPath == asset.workingPath,
      ),
      'الصورة لا تطابق حالة المشروع الحالية.',
    );
  }

  Future<ImageAdjustments> _suggestAdjustmentsForPreview(
    Uint8List preview, {
    required int quarterTurns,
  }) => Isolate.run(
    () => imaging.suggestAutoAdjustments(preview, quarterTurns: quarterTurns),
  );

  Future<ImageAsset> createImageRevision(
    Project project,
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async {
    final editor = imageEditor;
    require(editor != null, 'خدمة معالجة الصور غير متاحة.');
    require(
      project.assets.any(
        (entry) =>
            entry.id == asset.id &&
            entry.originalPath == asset.originalPath &&
            entry.workingPath == asset.workingPath,
      ),
      'الصورة لا تطابق حالة المشروع الحالية.',
    );
    return editor!.createRevision(asset, recipe);
  }

  /// Automatic intake crop. The recipe is built only from an accepted
  /// boundary decision. There is no catalog-aspect argument: acceptance
  /// corrects perspective and keeps the measured aspect.
  Future<Project> applyAuthorizedCrop(
    Project project,
    ImageAsset asset,
    AutomaticCropAuthorization authorization, {
    required int sourceWidth,
    required int sourceHeight,
  }) {
    final recipe = recipeFromAcceptedBoundary(
      authorization,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      adjustments: asset.adjustments,
    );
    return _applyCrop(project, asset, recipe, userAuthored: false);
  }

  /// Revision primitive used by tests and by [applyAuthorizedCrop] /
  /// [applyManualCrop]. Production intake must not call this with a detector
  /// quadrilateral; that path is [applyAuthorizedCrop]. Recovery replay and
  /// color/rotation revisions are not boundary decisions and do not come here
  /// from intake.
  Future<Project> applyCrop(
    Project project,
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) => _applyCrop(project, asset, recipe, userAuthored: false);

  Future<(int, int)> _resolveSourceDimensions(
    ImageAsset targetAsset, {
    int? sourceWidth,
    int? sourceHeight,
  }) async {
    require(
      (sourceWidth == null) == (sourceHeight == null),
      'أدخل عرض المصدر وارتفاعه معاً أو اتركهما معاً.',
    );
    if (sourceWidth != null && sourceHeight != null) {
      return (sourceWidth, sourceHeight);
    }
    final editor = imageEditor;
    require(editor != null, 'خدمة معالجة الصور غير متاحة.');
    final opened = await editor!.open(targetAsset);
    return (opened.width, opened.height);
  }

  /// Crop explicitly accepted in the manual crop editor without confirming
  /// document category or review resolution.
  ///
  /// Preserves unconfirmed manual crop semantics: updates only the [ImageAsset]
  /// revision (`userAuthoredCrop = true`, `suggestedCrop = null`) without
  /// modifying [DocumentRecord] overrides or review state, so reprocessing
  /// preserves the user's crop and emits the manual-crop preservation notice.
  Future<Project> applyManualCrop(
    Project project,
    ImageAsset asset,
    ImageEditRecipe recipe, {
    int? sourceWidth,
    int? sourceHeight,
  }) async {
    _guardLargeFrameCrop(asset, recipe);
    final (resolvedWidth, resolvedHeight) = await _resolveSourceDimensions(
      asset,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    requireValidManualBoundary(
      corners: recipe.geometry.corners,
      sourceWidth: resolvedWidth,
      sourceHeight: resolvedHeight,
      adjustments: recipe.adjustments,
      catalog: project.catalog,
    );
    var updated = await createImageRevision(project, asset, recipe);
    updated = updated.markUserAuthoredCrop().withSuggestedCrop(null);
    final next = project.copyWith(
      assets: [
        for (final current in project.assets)
          current.id == asset.id ? updated : current,
      ],
    );
    final saved = await projects.save(next);
    if (IntakeDiagnostics.isActive) {
      IntakeDiagnostics.record(
        IntakeDiagnosticEntry(
          stage: 'manual_crop_saved',
          assetId: updated.id,
          sourceWidth: updated.width,
          sourceHeight: updated.height,
          verdict: 'manual_crop_accepted',
        ),
      );
    }
    return saved;
  }

  /// Applies the 4-corner boundary recognition ALREADY measured and saved for
  /// [asset], after one explicit user decision (choosing the document type).
  ///
  /// This is not automatic cropping: without the user's approval no pixels
  /// change, and the immutable original is never touched. It delegates to
  /// [confirmManualBoundary] so validation, manual provenance, crop authorship
  /// and A4 placement stay on exactly one path. It is how an image with a
  /// perfectly good proposed boundary reaches the sheet without being forced
  /// through the manual crop editor.
  Future<Project> confirmSuggestedBoundary(
    Project project,
    ImageAsset asset, {
    required DocumentKind documentKind,
    PhysicalSizeMm? customSizeMm,
    String? targetItemId,
  }) async {
    final (width, height) = await _resolveSourceDimensions(asset);
    final suggestion = inspectSuggestedBoundary(
      project,
      asset,
      sourceWidth: width,
      sourceHeight: height,
    );
    if (!suggestion.isUsable) {
      throw const ValidationException(
        'لا توجد حدود مقترحة صالحة لهذه الصورة؛ اضبط الزوايا يدوياً.',
      );
    }
    final recipe = CropDraft(
      corners: suggestion.corners!,
      adjustments: asset.adjustments,
    ).toRecipe(width, height);
    return confirmManualBoundary(
      project,
      asset,
      recipe,
      documentKind: documentKind,
      customSizeMm: customSizeMm,
      targetItemId: targetItemId,
      sourceWidth: width,
      sourceHeight: height,
    );
  }

  /// Atomically applies a user-confirmed manual 4-corner crop, validates print
  /// size/category, records side-scoped manual provenance without altering
  /// detector evidence or partner sides, and places the confirmed item onto A4
  /// immediately (**Path B**).
  Future<Project> confirmManualBoundary(
    Project project,
    ImageAsset asset,
    ImageEditRecipe recipe, {
    required DocumentKind documentKind,
    PhysicalSizeMm? customSizeMm,
    String? targetItemId,
    int? sourceWidth,
    int? sourceHeight,
  }) async {
    _guardLargeFrameCrop(asset, recipe);
    final (resolvedWidth, resolvedHeight) = await _resolveSourceDimensions(
      asset,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    // Validate before writing. Only documented dimensions or an explicitly
    // supplied measurement can confirm millimetres. A category/estimated
    // default alone preserves the crop but leaves it off A4 until size review.
    final turned = recipe.adjustments.quarterTurns.isOdd;
    final landscape =
        (turned ? recipe.geometry.outputHeight : recipe.geometry.outputWidth) >=
        (turned ? recipe.geometry.outputWidth : recipe.geometry.outputHeight);
    final natural = project.catalog.natural(documentKind);
    final PhysicalSizeMm? resolvedSize =
        customSizeMm ??
        (natural == null ||
                !documentSizeRecordFor(documentKind).mayBeConfirmedAutomatically
            ? null
            : project.catalog.sizeFor(documentKind, landscape: landscape));
    // Print millimetres size the A4 slot, not the source pixels. Preserve the
    // exact previewed recipe (including an explicit shape choice, if any).
    // Contain at export handles a slot/image mismatch without stretching.
    final resolvedRecipe = recipe;
    requireValidManualBoundary(
      corners: resolvedRecipe.geometry.corners,
      sourceWidth: resolvedWidth,
      sourceHeight: resolvedHeight,
      adjustments: resolvedRecipe.adjustments,
      documentKind: documentKind,
      customSizeMm: resolvedSize,
      catalog: project.catalog,
      requireConfirmedSize: resolvedSize != null,
      allowUnconfirmedSize: resolvedSize == null,
    );
    final updated = await createImageRevision(project, asset, resolvedRecipe);
    final next = applyManualConfirmationToProject(
      project,
      updatedAsset: updated,
      recipe: resolvedRecipe,
      documentKind: documentKind,
      sizeMm: resolvedSize,
      nextId: newId,
      targetItemId: targetItemId,
    );
    final saved = await projects.save(next);
    if (IntakeDiagnostics.isActive) {
      final confirmedItem = targetItemId != null
          ? saved.items.where((i) => i.id == targetItemId).firstOrNull
          : saved.items.where((i) => i.assetId == updated.id).lastOrNull;
      IntakeDiagnostics.record(
        IntakeDiagnosticEntry(
          stage: 'manual_boundary_confirmed',
          assetId: updated.id,
          itemId: confirmedItem?.id,
          sourceWidth: updated.width,
          sourceHeight: updated.height,
          verdict: confirmedItem?.pageIndex != null
              ? 'placed_on_a4'
              : 'confirmed_off_sheet',
          documentKind: documentKind,
          sizeConfirmed: confirmedItem?.sizeConfirmed,
          pageIndex: confirmedItem?.pageIndex,
          widthMm: confirmedItem?.width,
          heightMm: confirmedItem?.height,
        ),
      );
    }
    return saved;
  }

  /// Extracts an independent manual 4-corner document crop from [asset] (or its
  /// root source photograph when [asset] is already derived) into a new derived
  /// [ImageAsset], auditable manual [DocumentRecord], and confirmed
  /// [DocumentItem] arranged onto A4 without overlap (**Path C**).
  ///
  /// Never mutates the root source photograph or previously extracted documents.
  Future<Project> extractManualDerivedDocument(
    Project project,
    ImageAsset asset,
    ImageEditRecipe recipe, {
    required DocumentKind documentKind,
    SideKind side = SideKind.unknown,
    String? reservedItemId,
    String? partnerItemId,
    IntakeStageLog? stages,
    bool keepPlaced = false,
    PhysicalSizeMm? customSizeMm,
    int? sourceWidth,
    int? sourceHeight,
    bool replaceUnconfirmedSourcePlaceholder = true,
    ProcessingLedger? ledger,
    String? processingDocumentId,
  }) async {
    final rootSource = asset.derivedFrom == null
        ? project.assets.firstWhere(
            (a) => a.id == asset.id,
            orElse: () => throw const ValidationException(
              'الصورة غير موجودة في المشروع.',
            ),
          )
        : project.assets.firstWhere(
            (a) => a.id == asset.derivedFrom,
            orElse: () => project.assets.firstWhere(
              (a) => a.id == asset.id,
              orElse: () => throw const ValidationException(
                'الصورة الأصلية غير موجودة في المشروع.',
              ),
            ),
          );
    if (reservedItemId != null) {
      validId(reservedItemId);
      require(
        !project.items.any((item) => item.id == reservedItemId),
        'معرّف المستمسك مستخدم بالفعل.',
      );
    }
    _guardLargeFrameCrop(rootSource, recipe);
    final editor = imageEditor;
    require(editor != null, 'خدمة معالجة الصور غير متاحة.');

    final (effectiveWidth, effectiveHeight) = await _resolveSourceDimensions(
      rootSource,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    final turned = recipe.adjustments.quarterTurns.isOdd;
    final landscape =
        (turned ? recipe.geometry.outputHeight : recipe.geometry.outputWidth) >=
        (turned ? recipe.geometry.outputWidth : recipe.geometry.outputHeight);
    final natural = project.catalog.natural(documentKind);
    final PhysicalSizeMm? resolvedSize =
        customSizeMm ??
        (natural == null ||
                !documentSizeRecordFor(documentKind).mayBeConfirmedAutomatically
            ? null
            : project.catalog.sizeFor(documentKind, landscape: landscape));
    final imageId = rootSource.id;
    final documentId =
        processingDocumentId ?? reservedItemId ?? 'manual-${newId()}';
    final document = ledger?.document(
      imageId,
      documentId: documentId,
      kind: documentKind,
      side: side,
      kindSource: RecordSource.user,
      sideSource: side == SideKind.unknown
          ? RecordSource.unknown
          : RecordSource.user,
    );
    QuadAssessment? assessment;
    try {
      assessment = assessQuad(
        recipe.geometry.corners,
        sourceWidth: effectiveWidth,
        sourceHeight: effectiveHeight,
      );
      requireValidManualBoundary(
        corners: recipe.geometry.corners,
        sourceWidth: effectiveWidth,
        sourceHeight: effectiveHeight,
        adjustments: recipe.adjustments,
        documentKind: documentKind,
        customSizeMm: resolvedSize,
        catalog: project.catalog,
        requireConfirmedSize: resolvedSize != null,
        allowUnconfirmedSize: resolvedSize == null,
      );
    } catch (error) {
      if (document != null) {
        ledger?.documentFailed(
          imageId,
          documentId,
          ProcessingStage.geometryCheck,
          error: error,
          reason: 'رُفض الرباعي المرسوم: ${describeFailure(error)}',
          diagnostics: const ['manual_boundary_rejected'],
          actionTaken: 'لم يُقص المستند ولم يُحفظ.',
        );
      }
      rethrow;
    }
    if (document != null) {
      final geometryOk = assessment?.acceptable == true;
      if (geometryOk) {
        ledger?.documentSucceeded(
          imageId,
          documentId,
          ProcessingStage.geometryCheck,
          reason: 'اجتاز الرباعي المرسوم التحقق الهندسي.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(name: 'quad_acceptable', passed: true),
              EvidenceCheck(
                name: 'four_corners',
                passed: recipe.geometry.corners.length == 4,
                detail: '${recipe.geometry.corners.length}',
              ),
            ],
          ),
          results: {
            if (assessment?.geometryConfidence != null)
              'geometry_confidence': assessment!.geometryConfidence,
            if (assessment?.aspect != null) 'aspect': assessment!.aspect,
            if (assessment?.areaFraction != null)
              'area_fraction': assessment!.areaFraction,
          },
          actionTaken: 'تابع إلى تصحيح المنظور والقص.',
        );
      } else {
        ledger?.documentFailed(
          imageId,
          documentId,
          ProcessingStage.geometryCheck,
          reason: 'لم يجتز الرباعي تقييم الهندسة رغم قبول التحقق الآخر.',
          errorType: 'GeometryRejected',
          errorCode: assessment?.rejection?.name ?? 'manual_geometry_rejected',
          diagnostics: const ['quad_assessment_rejected'],
          actionTaken: 'لم يُسمح بالقص.',
        );
      }
      ledger?.documentSucceeded(
        imageId,
        documentId,
        ProcessingStage.boundaryReview,
        reason: 'اعتمد المستخدم هذه الحدود بطلب إضافة المستمسك.',
        evidence: StageEvidence(
          verified: true,
          checks: [EvidenceCheck(name: 'user_approved', passed: true)],
          counts: {'corners': recipe.geometry.corners.length},
        ),
        results: {'origin': 'user_drawn'},
        actionTaken: 'سُمح بالقص.',
      );
    }

    if (partnerItemId != null) {
      require(
        resolvedSize != null &&
            matchingManualSidePartners(
              project,
              kind: documentKind,
              side: side,
              draftSourceId: rootSource.id,
              draftCorners: recipe.geometry.corners,
            ).any((item) => item.id == partnerItemId),
        'الوجه المقابل غير متاح لهذا التحديد؛ تحقق من النوع والمقاس والحدود.',
      );
    }
    stages?.skip(
      JourneyStage.recognition,
      'تعريف يدوي؛ لا قراءة نص ولا استنتاج للوجه.',
      fields: {'side': side.name, 'kind': documentKind.name},
    );
    final clock = Stopwatch()..start();
    final Uint8List cropBytes;
    try {
      cropBytes = editor is CropBytesImageEditor
          ? await editor.renderCropBytes(rootSource, recipe)
          : await editor!.preview(rootSource, recipe);
    } on OperationCancelled {
      clock.stop();
      if (document != null) {
        ledger
          ?..documentCancelled(
            imageId,
            documentId,
            ProcessingStage.perspective,
            reason: 'أُلغيت معالجة المنظور والقص عند أول نقطة آمنة.',
            durationMs: clock.elapsedMilliseconds,
            actionTaken: 'لم يُحفظ أي مستند لهذا التحديد.',
          )
          ..documentCancelled(
            imageId,
            documentId,
            ProcessingStage.crop,
            reason: 'أُلغيت عملية الرسم المشتركة قبل إنتاج صورة القص.',
            actionTaken: 'لم يُعلن نجاح القص.',
          );
      }
      rethrow;
    } catch (error) {
      clock.stop();
      if (document != null) {
        ledger
          ?..documentFailed(
            imageId,
            documentId,
            ProcessingStage.perspective,
            error: error,
            reason: 'تعذر تصحيح المنظور ضمن استدعاء رسم القص.',
            diagnostics: const ['perspective_crop_render_failed'],
            durationMs: clock.elapsedMilliseconds,
            actionTaken: 'بقي المصدر الأصلي ولم يُحفظ مستند مشتق.',
          )
          ..documentStopped(
            imageId,
            documentId,
            ProcessingStage.crop,
            reason: 'لم يُنتج القص لأن استدعاء تصحيح المنظور لم يكتمل.',
            actionTaken: 'يحتاج التحديد إلى مراجعة أو إعادة محاولة.',
          );
      }
      rethrow;
    }
    ImageHeader? cropHeader;
    try {
      cropHeader = inspectImageHeader(cropBytes);
    } on Object {
      cropHeader = null;
    }
    final cropValid =
        cropBytes.isNotEmpty &&
        cropHeader != null &&
        cropHeader.width > 0 &&
        cropHeader.height > 0;
    clock.stop();
    final cropMs = clock.elapsedMilliseconds;
    if (document != null) {
      if (cropValid) {
        ledger?.documentSucceeded(
          imageId,
          documentId,
          ProcessingStage.perspective,
          reason: 'صُحح المنظور من الزوايا الأربع المقبولة.',
          evidence: StageEvidence(
            verified: recipe.geometry.corners.length == 4,
            checks: [
              EvidenceCheck(
                name: 'four_corners',
                passed: recipe.geometry.corners.length == 4,
              ),
            ],
            note:
                'تصحيح المنظور والتدوير والحدة والقص ضمن استدعاء رسم واحد؛ '
                'زمنه مسجل في مرحلة القص.',
          ),
          results: {'width': cropHeader.width, 'height': cropHeader.height},
          actionTaken: 'تابع إلى قصّ الصورة الناتجة.',
        );
        ledger?.documentSucceeded(
          imageId,
          documentId,
          ProcessingStage.crop,
          reason: 'أُنتجت صورة مقصوصة قابلة للقراءة.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(
                name: 'bytes_not_empty',
                passed: cropBytes.isNotEmpty,
                detail: '${cropBytes.length}',
              ),
              EvidenceCheck(name: 'header_parsed', passed: cropHeader != null),
            ],
            counts: {'bytes': cropBytes.length},
          ),
          results: {'width': cropHeader.width, 'height': cropHeader.height},
          itemCount: 1,
          durationMs: cropMs,
          actionTaken: 'تابع إلى إنشاء المستند.',
        );
        ledger?.documentSucceeded(
          imageId,
          documentId,
          ProcessingStage.outputEnhancement,
          reason: 'طُبقت الحدة والتدوير وإعدادات الصورة على المخرج.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(
                name: 'rendered_output_parsed',
                passed: cropHeader != null,
              ),
            ],
            note:
                'التحقق من قابلية قراءة المخرج وأبعاده؛ '
                'الحدة والتدوير محمولان في وصف المعالجة وزمنهما ضمن مرحلة القص.',
          ),
        );
      } else {
        ledger?.documentFailed(
          imageId,
          documentId,
          ProcessingStage.crop,
          reason: 'لم يُنتج القص صورة قابلة للقراءة.',
          errorType: 'InvalidCropOutput',
          errorCode: 'invalid_crop_output',
          diagnostics: const ['crop_header_unreadable'],
          durationMs: cropMs,
          actionTaken: 'لم يُحفظ المستند.',
        );
      }
    }
    stages?.pass(
      JourneyStage.crop,
      'صُحح المنظور من الزوايا الأربع.',
      durationMs: cropMs,
    );
    final siblingCount = project.assets
        .where((a) => a.derivedFrom == rootSource.id)
        .length;
    final derivedName = _manualDerivedAssetName(
      rootSource.name,
      siblingCount + 1,
    );
    final derived = await assets.importImage(
      project.id,
      derivedName,
      cropBytes,
    );
    Iterable<String> centeringItems = const [];
    final placementClock = Stopwatch()..start();
    final next = appendManualDerivedDocumentToProject(
      project,
      sourceAsset: rootSource,
      derivedAsset: derived,
      recipe: recipe,
      documentKind: documentKind,
      sizeMm: resolvedSize,
      documentSide: side,
      partnerItemId: partnerItemId,
      reservedItemId: reservedItemId,
      onCenteringPass: (ids) => centeringItems = ids,
      keepPlaced: keepPlaced,
      nextId: newId,
      replaceUnconfirmedSourcePlaceholder: replaceUnconfirmedSourcePlaceholder,
    );
    final item = next.items.firstWhere((i) => i.assetId == derived.id);
    final placed = item.pageIndex != null;
    final recordId = item.documentId;
    final documentRecord = recordId == null
        ? null
        : next.documents.where((record) => record.id == recordId).firstOrNull;
    if (document != null) {
      ledger?.documentSucceeded(
        imageId,
        documentId,
        ProcessingStage.documentModel,
        reason: 'أُنشئ سجل المستند وعنصره وربطا بالمصدر.',
        evidence: StageEvidence(
          verified:
              recordId != null &&
              documentRecord != null &&
              documentRecord.sourceImageId == imageId,
          checks: [
            EvidenceCheck(name: 'record_created', passed: recordId != null),
            EvidenceCheck(
              name: 'record_linked_to_source',
              passed: documentRecord?.sourceImageId == imageId,
            ),
            EvidenceCheck(name: 'item_created', passed: true),
          ],
        ),
        results: {'kind': documentKind.name, 'side': side.name},
        actionTaken: 'تابع إلى تثبيت النوع والمقاس.',
      );
      ledger?.linkDocument(
        imageId,
        documentId,
        recordId: recordId,
        itemId: item.id,
        assetId: derived.id,
      );
      if (documentKind != DocumentKind.unknown && item.sizeConfirmed) {
        ledger?.documentSucceeded(
          imageId,
          documentId,
          ProcessingStage.typeSideSize,
          reason: 'ثُبّت النوع والوجه والمقاس المؤكد على المستند والعنصر.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(name: 'kind_required', passed: true),
              EvidenceCheck(name: 'item_present', passed: true),
              EvidenceCheck(name: 'size_confirmed', passed: true),
            ],
            counts: {'size_confirmed': 1},
          ),
          results: {
            'kind': documentKind.name,
            'side': side.name,
            'sizeConfirmed': true,
            if (partnerItemId != null) 'partner': partnerItemId,
          },
          actionTaken: 'تأكد النوع والمقاس قبل متابعة الإضافة.',
        );
      } else {
        ledger?.documentStopped(
          imageId,
          documentId,
          ProcessingStage.typeSideSize,
          reason: documentKind == DocumentKind.unknown
              ? 'لم يُحسم نوع المستند؛ بقي النوع والمقاس للمراجعة.'
              : 'المقاس مبدئي وغير مؤكد؛ بقي المستند للمراجعة.',
          actionTaken: 'لم تُسجَّل نتيجة النوع والمقاس كنجاح.',
        );
      }
      if (!next.layout.centerCaptures) {
        ledger?.documentOverridden(
          imageId,
          documentId,
          ProcessingStage.centering,
          reason: 'عطّل المستخدم خيار التوسيط لهذه الدفعة.',
          actionTaken: 'وُضع المستند دون توسيط.',
        );
      } else if (placed && centeringItems.contains(item.id)) {
        ledger?.documentSucceeded(
          imageId,
          documentId,
          ProcessingStage.centering,
          reason: 'اجتاز المستند تمرير التوسيط ووُضع على الورقة.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(name: 'center_option_enabled', passed: true),
              EvidenceCheck(name: 'item_placed', passed: true),
              EvidenceCheck(name: 'centering_pass_clear', passed: true),
            ],
          ),
          actionTaken: 'وُضع المستند موسّطاً.',
        );
      } else {
        ledger?.documentStopped(
          imageId,
          documentId,
          ProcessingStage.centering,
          reason: 'فُعّل التوسيط لكنه لم يُطبق على هذا العنصر بعد.',
          actionTaken: 'يُعاد التوسيط عند الترتيب.',
        );
      }
    }
    stages?.record(
      IntakeStageRecord(
        stage: JourneyStage.placement,
        durationMs: placementClock.elapsedMilliseconds,
        outcome: placed ? JourneyOutcome.passed : JourneyOutcome.review,
        detail: placed ? 'وُضع على الورقة.' : 'بقي المستمسك خارج الورقة.',
        fields: {
          'centerEnabled': next.layout.centerCaptures,
          'sizeConfirmed': item.sizeConfirmed,
          'centeringPass': centeringItems.contains(item.id),
          'page': item.pageIndex,
        },
      ),
    );
    clock.reset();
    final Project saved;
    try {
      saved = await projects.save(next);
    } catch (error) {
      if (document != null) {
        ledger?.documentFailed(
          imageId,
          documentId,
          ProcessingStage.saveDocument,
          error: error,
          reason: 'تعذر حفظ المشروع بعد استخراج المستند.',
          actionTaken: 'لم يُضف هذا المستند إلى المشروع المحفوظ.',
        );
      }
      rethrow;
    }
    if (document != null) {
      final savedAsset = saved.assets
          .where((entry) => entry.id == derived.id)
          .firstOrNull;
      final savedItem = saved.items
          .where((entry) => entry.id == item.id)
          .firstOrNull;
      final savedRecord = recordId == null
          ? null
          : saved.documents
                .where((record) => record.id == recordId)
                .firstOrNull;
      final saveOk =
          savedAsset != null &&
          savedItem != null &&
          (recordId == null || savedRecord != null);
      if (saveOk) {
        ledger?.documentSucceeded(
          imageId,
          documentId,
          ProcessingStage.saveDocument,
          reason: 'حُفظ المشروع وفيه أصل المستند وسجله.',
          evidence: StageEvidence(
            verified: true,
            checks: [
              EvidenceCheck(name: 'asset_saved', passed: savedAsset != null),
              EvidenceCheck(name: 'record_saved', passed: true),
              EvidenceCheck(name: 'item_saved', passed: savedItem != null),
            ],
          ),
          results: {'revision': saved.revision},
          actionTaken: 'تابع إلى التحقق من الإضافة.',
        );
      } else {
        ledger?.documentFailed(
          imageId,
          documentId,
          ProcessingStage.saveDocument,
          reason: 'حُفظ المشروع لكن أحد أجزاء المستند غير موجود فيه.',
          errorType: 'IncompleteSave',
          errorCode: 'saved_project_incomplete',
          diagnostics: const ['asset_or_record_or_item_missing'],
          actionTaken: 'يحتاج المستند إلى إعادة إضافة.',
        );
      }
      ledger?.documentSucceeded(
        imageId,
        documentId,
        ProcessingStage.addToProject,
        reason: placed
            ? 'أُضيف المستند إلى ورقة A4.'
            : 'أُضيف المستند إلى المشروع وبقي خارج الورقة.',
        evidence: StageEvidence(
          verified: savedItem != null,
          checks: [
            EvidenceCheck(name: 'item_in_project', passed: savedItem != null),
          ],
          counts: {'items': saved.items.length},
        ),
        results: {'page': savedItem?.pageIndex ?? -1},
        actionTaken: placed
            ? 'وُضع على الورقة.'
            : 'بانتظار تأكيد المقاس أو الترتيب.',
      );
      Project? readBack;
      Object? readError;
      try {
        readBack = await projects.get(saved.id);
      } on Object catch (error) {
        readError = error;
      }
      if (readBack == null) {
        ledger?.documentFailed(
          imageId,
          documentId,
          ProcessingStage.verifyAddition,
          error: readError,
          errorType: 'VerificationReadFailed',
          errorCode: FailureCode.storage,
          reason: 'تعذرت قراءة المشروع المحفوظ للتحقق.',
          diagnostics: const ['read_back_failed'],
          actionTaken: 'بقيت الإضافة غير مؤكدة.',
        );
      } else {
        final confirmedAsset = readBack.assets.any(
          (entry) => entry.id == derived.id,
        );
        final confirmedItem = readBack.items.any(
          (entry) => entry.id == item.id,
        );
        final confirmedRecord =
            recordId == null ||
            readBack.documents.any((record) => record.id == recordId);
        if (confirmedAsset && confirmedItem && confirmedRecord) {
          ledger?.documentSucceeded(
            imageId,
            documentId,
            ProcessingStage.verifyAddition,
            reason: 'أُكد وجود المستند وأصله وعنصره في المشروع المحفوظ.',
            evidence: StageEvidence(
              verified: true,
              checks: [
                EvidenceCheck(name: 'asset_in_saved_project', passed: true),
                EvidenceCheck(name: 'item_in_saved_project', passed: true),
                EvidenceCheck(name: 'record_in_saved_project', passed: true),
              ],
              counts: {'revision': readBack.revision},
            ),
            actionTaken: 'اكتملت إضافة المستند.',
          );
        } else {
          ledger?.documentFailed(
            imageId,
            documentId,
            ProcessingStage.verifyAddition,
            reason: 'المشروع المحفوظ لا يحتوي كل أجزاء المستند.',
            errorType: 'VerificationFailed',
            errorCode: 'addition_not_confirmed',
            diagnostics: const ['saved_project_missing_document_part'],
            actionTaken: 'يحتاج المستند إلى إعادة إضافة.',
          );
        }
      }
      ledger?.linkDocument(
        imageId,
        documentId,
        recordId: recordId,
        itemId: item.id,
        assetId: derived.id,
        outcome: document.failed
            ? 'فشل: ${document.firstFailure?.reason ?? 'سبب غير محسوم'}'
            : placed
            ? 'حُفظ المستند وأُضيف إلى الورقة وتحققت إضافته.'
            : 'حُفظ المستند وأُضيف خارج الورقة وتحققت إضافته.',
      );
    }
    stages?.pass(
      JourneyStage.save,
      'أُضيف المستمسك وحُفظ المشروع.',
      durationMs: clock.elapsedMilliseconds,
      fields: {
        'assetId': derived.id,
        'itemId': item.id,
        if (partnerItemId != null) 'partnerItemId': partnerItemId,
        'revision': saved.revision,
      },
    );
    if (IntakeDiagnostics.isActive) {
      final createdItem = saved.items
          .where((i) => i.assetId == derived.id)
          .lastOrNull;
      IntakeDiagnostics.record(
        IntakeDiagnosticEntry(
          stage: 'manual_derived_extracted',
          assetId: derived.id,
          itemId: createdItem?.id,
          sourceWidth: derived.width,
          sourceHeight: derived.height,
          verdict: createdItem?.pageIndex != null
              ? 'placed_on_a4'
              : 'confirmed_off_sheet',
          documentKind: documentKind,
          sizeConfirmed: createdItem?.sizeConfirmed,
          pageIndex: createdItem?.pageIndex,
          widthMm: createdItem?.width,
          heightMm: createdItem?.height,
        ),
      );
    }
    return saved;
  }

  /// Restores [asset] to its full uncropped working image from the lossless
  /// original without modifying `originalPath`, clearing cancelled manual
  /// boundary confirmation metadata and re-evaluating review/A4 state.
  Future<Project> resetManualCrop(Project project, ImageAsset asset) async {
    final editor = imageEditor;
    require(editor != null, 'خدمة معالجة الصور غير متاحة.');
    require(
      !asset.hasScaledLargeSource,
      'الصورة الكاملة أكبر من حد المعالجة كاملة الدقة (16 مليون بكسل)؛ '
      'افتح شاشة القص لتعديل حدود المنطقة المطلوبة.',
    );
    final source = await editor!.open(asset);
    final fullRecipe = CropDraft.fullImage()
        .withAdjustments(asset.adjustments)
        .toRecipe(source.width, source.height);
    final revised = await createImageRevision(project, asset, fullRecipe);
    final resetAsset = ImageAsset(
      id: revised.id,
      captureId: revised.captureId,
      revisionId: revised.revisionId,
      parentRevisionId: revised.parentRevisionId,
      revisionHistory: revised.revisionHistory,
      revisionHistoryComplete: revised.revisionHistoryComplete,
      originalWidth: revised.originalWidth,
      originalHeight: revised.originalHeight,
      derivedFrom: revised.derivedFrom,
      userAuthoredCrop: false,
      name: revised.name,
      originalPath: revised.originalPath,
      workingPath: revised.workingPath,
      thumbnailPath: revised.thumbnailPath,
      width: revised.width,
      height: revised.height,
      crop: null,
      adjustments: revised.adjustments,
      transforms: revised.transforms,
    );
    final next = revertManualCropOnProject(project, resetAsset: resetAsset);
    return projects.save(next);
  }

  void _guardLargeFrameCrop(ImageAsset asset, ImageEditRecipe recipe) {
    if (asset.hasScaledLargeSource &&
        coversOrientedFrame(manualCropBounds(recipe.geometry.corners))) {
      throw const ValidationException(
        'الصورة الكاملة أكبر من حد المعالجة كاملة الدقة (16 مليون بكسل). '
        'لن يُستخدم التصغير الصامت. حدّد منطقة المستند داخل الحد.',
      );
    }
  }

  String _manualDerivedAssetName(String sourceName, int index) {
    final dot = sourceName.lastIndexOf('.');
    final stem = dot > 0 ? sourceName.substring(0, dot) : sourceName;
    final cleanStem = stem.length > 60 ? stem.substring(0, 60) : stem;
    return '$cleanStem — مستمسك $index.png';
  }

  Future<Project> _applyCrop(
    Project project,
    ImageAsset asset,
    ImageEditRecipe recipe, {
    required bool userAuthored,
  }) async {
    _guardLargeFrameCrop(asset, recipe);
    var updated = await createImageRevision(project, asset, recipe);
    updated = userAuthored
        ? updated.markUserAuthoredCrop()
        : updated.clearUserAuthoredCrop();
    return projects.save(
      project.copyWith(
        assets: [
          for (final current in project.assets)
            current.id == asset.id ? updated : current,
        ],
      ),
    );
  }

  /// Moves an image inside the library order; the sheet itself is untouched.
  Future<Project> moveAsset(
    Project project,
    String assetId,
    int targetIndex,
  ) async {
    final from = project.assets.indexWhere((asset) => asset.id == assetId);
    require(from >= 0, 'الصورة ليست ضمن هذا المشروع.');
    return projects.save(project.reorderAssets(from, targetIndex));
  }

  /// Replaces the source pixels of an existing asset while keeping its id, so
  /// every placed copy on the sheet stays where the user put it. The previous
  /// files remain on disk; the previous crop recipe does not describe the new
  /// pixels and is therefore cleared.
  Future<ReplaceReport> replaceImage(
    Project project,
    ImageAsset asset,
    ImportSource source,
  ) async {
    final index = project.assets.indexWhere((entry) => entry.id == asset.id);
    require(index >= 0, 'الصورة ليست ضمن هذا المشروع.');
    require(
      asset.originalPath == project.assets[index].originalPath,
      'الصورة لا تطابق حالة المشروع الحالية.',
    );
    validName(source.name);
    try {
      final bytes = await readBoundedImage(source.openRead());
      final files = await assets.replaceImage(project.id, asset.id, bytes);
      final aspectChanged =
          (files.width / files.height) / (asset.width / asset.height) - 1;
      final log = [...asset.transforms, 'replaced:${files.revision}'];
      if (files.sourceScaling != null) log.add(files.sourceScaling!);
      final updated = ImageAsset(
        id: asset.id,
        captureId: asset.captureId,
        revisionId: files.revision,
        parentRevisionId: asset.revisionId,
        revisionHistory: asset.historyWithCurrent,
        revisionHistoryComplete: asset.revisionHistoryComplete,
        originalWidth: files.originalWidth,
        originalHeight: files.originalHeight,
        // Replacing the pixels of an asset never changes what it is derived
        // from; losing this would make a derived crop look like an original.
        derivedFrom: asset.derivedFrom,
        name: source.name,
        originalPath: files.originalPath,
        workingPath: files.workingPath,
        thumbnailPath: files.thumbnailPath,
        width: files.width,
        height: files.height,
        transforms: boundedTransformLog(log),
      );
      final saved = await projects.save(
        project.copyWith(
          assets: [
            for (final entry in project.assets)
              entry.id == asset.id ? updated : entry,
          ],
        ),
      );
      return ReplaceReport(
        saved,
        aspectChanged.abs() > 0.01,
        scalingMessage: files.sourceScaling == null
            ? null
            : '${source.name}: حُفظ الأصل كما هو؛ صُغّرت نسخة العمل إلى '
                  '${files.width}×${files.height} بحد أقصى 4 ملايين بكسل، '
                  'وقد تقل تفاصيل النسخة المعالجة.',
      );
    } finally {
      await _cleanupSource(source);
    }
  }

  /// Removes only a leaf revision's metadata. Files are deliberately kept;
  /// marking history incomplete prevents automatic GC from discarding them.
  /// Current revisions and parents of another recorded revision are refused.
  Future<Project> deleteHistoricalRevision(
    Project project,
    String assetId,
    String revisionId,
  ) async {
    final index = project.assets.indexWhere((asset) => asset.id == assetId);
    require(index >= 0, 'الصورة ليست ضمن هذا المشروع.');
    final asset = project.assets[index];
    require(
      asset.revisionHistoryComplete,
      'تاريخ المراجعات غير مكتمل؛ لن تُحذف أي مراجعة.',
    );
    require(asset.revisionId != revisionId, 'لا يمكن حذف المراجعة الحالية.');
    require(
      asset.revisionHistory.any((entry) => entry.id == revisionId),
      'المراجعة غير موجودة في التاريخ المحفوظ.',
    );
    require(
      asset.parentRevisionId != revisionId &&
          !asset.revisionHistory.any(
            (entry) => entry.parentRevisionId == revisionId,
          ),
      'لا يمكن حذف مراجعة لها مراجعات تابعة.',
    );
    final json = asset.toJson()
      ..['revisionHistory'] = [
        for (final entry in asset.revisionHistory)
          if (entry.id != revisionId) entry.toJson(),
      ]
      ..remove('revisionHistoryComplete');
    final updated = ImageAsset.fromJson(json);
    return projects.save(
      project.copyWith(
        assets: [
          for (final entry in project.assets)
            if (entry.id == assetId) updated else entry,
        ],
      ),
    );
  }

  /// Explicit user-requested migration; no image files are rewritten.
  Future<LegacyRevisionMigrationResult> migrateLegacyRevisionIdentities(
    String projectId,
  ) {
    final repository = projects;
    require(
      repository is LegacyRevisionMigrator,
      'ترحيل المراجعات غير متاح في هذا البناء.',
    );
    return (repository as LegacyRevisionMigrator)
        .migrateLegacyRevisionIdentities(projectId);
  }

  /// Releases picker-owned temporary copies that will not be imported.
  Future<void> discardSources(Iterable<ImportSource> sources) async {
    for (final source in sources) {
      await _cleanupSource(source);
    }
  }

  /// Takes an image off the sheet and keeps it in the project. Reversible by
  /// placing the image again; the image and its files are untouched.
  Future<Project> removeImageFromSheet(Project project, String assetId) async =>
      projects.save(detachImageFromSheet(project, assetId));

  /// Deletes an image from the project together with everything that depends
  /// on it, as one decision computed by [planImageDeletion]:
  ///
  /// 1. the image's sheet elements and the recognition records that describe
  ///    it leave the project (their cascade is the editor's own rule);
  /// 2. derived crops made from it stay in the project as independent images;
  /// 3. the project metadata is committed in ONE save, guarded by the revision,
  ///    so a second tap or a stale window fails instead of applying twice;
  /// 4. only then is the image's folder removed. If that fails, or if the
  ///    recovery copy has not been rewritten yet and still names the folder,
  ///    the image is still gone from the project and the folder is kept. The
  ///    result carries a warning. Maintenance removes the folder later, once
  ///    nothing names it. Nothing points at it.
  ///
  /// Backups made earlier keep their own copies and are never touched.
  Future<ImageDeletion> deleteImage(Project project, String assetId) async {
    final plan = planImageDeletion(project, assetId);
    require(
      project.assets
          .firstWhere((asset) => asset.id == assetId)
          .revisionHistoryComplete,
      'تاريخ الصورة غير مكتمل؛ لا يمكن حذفها بأمان مع ملفات مراجعات غير محسومة.',
    );
    final saved = await projects.save(applyImageDeletion(project, plan));
    final store = maintenance;
    if (store == null) {
      return ImageDeletion(
        saved,
        plan,
        warning:
            'حُذفت الصورة من المشروع. صيانة الملفات غير متاحة في هذا البناء؛ '
            'ستبقى ملفاتها حتى تُنظّف لاحقاً.',
      );
    }
    try {
      await store.deleteFiles([plan.assetDirectory]);
      return ImageDeletion(saved, plan);
    } catch (error) {
      // The metadata is already committed, so this must be reported as a
      // warning rather than thrown: a thrown error would leave the screen
      // showing an image that no longer exists. The cause is kept.
      return ImageDeletion(
        saved,
        plan,
        warning:
            'حُذفت الصورة من المشروع، لكن ملفاتها بقيت على الجهاز. ${_deleteFailure(error)} '
            'لن تتأثر الصور الأخرى؛ أعد التنظيف من «الإعدادات ← المساحة والاسترداد».',
      );
    }
  }

  /// Metadata is removed first, then the app-owned files of that project, so a
  /// failure can only leave unreferenced files behind, never a record pointing
  /// at missing files. Files outside the application root are unreachable here.
  Future<ProjectDeletion> deleteProject(Project project) async {
    require(
      project.assets.every((asset) => asset.revisionHistoryComplete),
      'يتضمن المشروع تاريخ مراجعات غير محسوم؛ لا يمكن حذفه بأمان.',
    );
    await projects.remove(project);
    final store = maintenance;
    if (store == null) {
      return const ProjectDeletion(
        warning:
            'حُذف المشروع من القائمة. صيانة الملفات غير متاحة في هذا البناء.',
      );
    }
    try {
      await store.deleteProjectFiles(project.id);
      return const ProjectDeletion();
    } catch (error) {
      // Same reasoning as [deleteImage]: the removal is already committed.
      return ProjectDeletion(
        warning:
            'حُذف المشروع من القائمة، لكن ملفاته بقيت على الجهاز. ${_deleteFailure(error)} '
            'لن تتأثر المشاريع الأخرى؛ أعد التنظيف من «الإعدادات ← المساحة والاسترداد».',
      );
    }
  }

  /// Files left behind by removed projects or interrupted work.
  ///
  /// Refuses while the project list cannot be read, so a damaged database can
  /// never be interpreted as "every image is orphaned".
  Future<OrphanFiles> findOrphans() async {
    final store = _maintenance();
    final projects = await this.projects.list();
    require(
      projects.isNotEmpty,
      'قائمة المشاريع فارغة؛ لن يُحسب شيء كملف يتيم. استعد قاعدة سليمة أو راجع النسخة الاحتياطية أولاً.',
    );
    return store.findOrphans(projects);
  }

  /// Projects whose recovery copy does not match their saved data. Read from
  /// the copies, so it is still true after a restart.
  Future<Set<String>> staleRecoveryPoints() =>
      _recovery().staleRecoveryPoints();

  /// Rewrites one project's recovery copy. Fails if the copy cannot be written,
  /// so the caller can say so instead of showing a false success.
  Future<void> refreshRecoveryPoint(String projectId) {
    validId(projectId);
    return _recovery().refreshRecoveryPoint(projectId);
  }

  /// Deletes exactly the paths [findOrphans] reported, after re-reading the
  /// project list so a concurrent import cannot be mistaken for an orphan.
  Future<int> deleteOrphans() async {
    final store = _maintenance();
    final projects = await this.projects.list();
    require(
      projects.isNotEmpty,
      'قائمة المشاريع فارغة؛ لن يُحذف شيء تلقائياً.',
    );
    final orphans = await store.findOrphans(projects);
    return store.deleteFiles(orphans.paths);
  }

  Future<int> pruneStaging() => _maintenance().pruneStaging();

  ProjectRecovery _recovery() {
    final store = recovery;
    require(store != null, 'استعادة نقاط الحفظ غير متاحة في هذا البناء.');
    return store!;
  }

  StorageMaintenance _maintenance() {
    final store = maintenance;
    require(store != null, 'صيانة الملفات غير متاحة في هذا البناء.');
    return store!;
  }
}

/// Never expose absolute filesystem paths / personal filenames from IO errors.
/// Why file removal failed, in words that fit a deletion: the storage layer's
/// own sentences are kept, anything else gets a deletion-specific hint.
String _deleteFailure(Object error) => switch (error) {
  ValidationException(:final message) => message,
  StorageException(:final message) => message,
  _ => 'تعذر حذف الملفات الآن؛ تحقق من الصلاحيات والمساحة.',
};

String userError(Object error) {
  if (error is ValidationException) {
    return error.message;
  }
  if (error is StorageException) {
    return error.message;
  }
  return 'تعذرت العملية. تحقق من سلامة الملفات، والصلاحيات والمساحة المتاحة. لم يتم استبدال الأصل.';
}

Future<void> _cleanupSource(ImportSource source) async {
  try {
    await ImportTrace.stage('cleanup', () async {
      await source.cleanup?.call();
    });
  } catch (_) {
    /* Only private picker cache; never let cleanup mask a committed import. */
  }
}

// Keep the ProjectService (which owns native OCR/editor resources) out of the
// isolate message, including Dart's closure-context over-capture.
Future<ImageAdjustments> _suggestCropAdjustmentsIsolated(
  Uint8List preview, {
  required int quarterTurns,
  CancellationToken? cancellation,
}) => runCancellableIsolate(
  () => imaging.suggestAutoAdjustments(preview, quarterTurns: quarterTurns),
  cancellation: cancellation,
  debugName: 'crop-auto-adjust',
);
