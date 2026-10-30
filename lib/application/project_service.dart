import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../domain/arrangement.dart';
import '../domain/boundary_decision.dart';
import '../domain/document_kind.dart';
import '../domain/image_adjustments.dart';
import '../domain/image_deletion.dart';
import '../domain/image_limits.dart';
import '../domain/geometry.dart';
import '../domain/manual_boundary.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'cancellation.dart';
import 'contracts.dart';
import 'intake_diagnostics.dart';
import 'project_backups.dart';
import 'camera_capture.dart';
import 'project_recovery.dart';
import 'ids.dart';
import 'image_reader.dart';
import 'full_resolution_jpeg_cropper.dart';
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
    this.fullResolutionJpegCropper = const PlatformFullResolutionJpegCropper(),
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

  /// Extracts a measured region from a sampled JPEG's immutable original at
  /// native density. Kept injectable because a real platform channel is not
  /// available to the Dart test runner.
  final FullResolutionJpegCropper fullResolutionJpegCropper;

  /// App-level Phase 1B gate. Production defaults to the disabled build flag;
  /// tests can explicitly opt in to exercise the implementation behind it.
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

    report(0);
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      if (cancellation?.isCancelled ?? false) {
        // Stop before opening another file: every committed image stays
        // committed and the rest are reported as not imported.
        await _cleanupSource(source);
        failures.add(ImportFailure(source.name, importCancelledMessage));
        for (final skipped in sources.skip(index + 1)) {
          await _cleanupSource(skipped);
          failures.add(ImportFailure(skipped.name, importCancelledMessage));
        }
        break;
      }
      try {
        require(
          current.assets.length < maxProjectAssets,
          'وصل المشروع إلى حد 200 صورة.',
        );
        validName(source.name);
        final bytes = await readBoundedImage(source.openRead());
        final asset = await assets.importImage(current.id, source.name, bytes);
        current = await projects.save(
          current.copyWith(assets: [...current.assets, asset]),
        );
        imported++;
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
        failures.add(ImportFailure(source.name, error.message));
        // The in-memory project is stale; continuing would create more orphans.
        for (final skipped in sources.skip(index + 1)) {
          await _cleanupSource(skipped);
          failures.add(
            ImportFailure(
              skipped.name,
              'لم تُستورد هذه الصورة: توقف الاستيراد بسبب تعارض حفظ المشروع.',
            ),
          );
        }
        break;
      } catch (error) {
        failures.add(ImportFailure(source.name, userError(error)));
      } finally {
        await _cleanupSource(source);
        report(index + 1);
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
  }) async {
    final smartEditor = imageEditor;
    if (smartRecognitionEnabled && smartEditor != null) {
      return SmartIntake(
        projects: projects,
        assets: assets,
        editor: smartEditor,
        segment: segmenter ?? defaultSegment,
        fullResolutionJpegCropper: fullResolutionJpegCropper,
      ).run(
        project,
        assetIds,
        keepPlaced: keepPlaced,
        cancellation: cancellation,
        onProgress: onProgress,
      );
    }

    if (multiDocumentSegmentationEnabled && smartEditor != null) {
      return _arrangeWithMultiDocumentSegmentation(
        project,
        assetIds,
        editor: smartEditor,
        keepPlaced: keepPlaced,
        cancellation: cancellation,
        onProgress: onProgress,
      );
    }

    return _arrangeLegacyImportedImages(
      project,
      assetIds,
      keepPlaced: keepPlaced,
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }

  Future<AutomaticLayoutReport> _arrangeWithMultiDocumentSegmentation(
    Project project,
    Iterable<String> assetIds, {
    required ImageEditor editor,
    required bool keepPlaced,
    CancellationToken? cancellation,
    void Function(BatchProgress progress)? onProgress,
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
    // This intake route has no independent visual/OCR kind classifier, so its
    // recognized-category count remains zero until such evidence is added.
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
        } on RevisionConflict {
          rethrow;
        } catch (error) {
          segmentationWarnings[id] =
              '${asset.name}: تعذر فحص التقسيم متعدد المستمسكات؛ '
              'استُخدم مسار الاستيراد المعتاد (${userError(error)}).';
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
              fullResolutionJpegCropper: fullResolutionJpegCropper,
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
      final arrangement = arrangeDocuments(current, keepPlaced: keepPlaced);
      current = await projects.save(arrangement.result);
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
      if (cancellation?.isCancelled ?? false) break;
      final id = ids[index];
      final assetIndex = current.assets.indexWhere((entry) => entry.id == id);
      require(assetIndex >= 0, 'الصورة المراد ترتيبها ليست ضمن المشروع.');
      if (current.items.any((item) => item.assetId == id)) {
        progress(index + 1);
        continue;
      }
      var asset = current.assets[assetIndex];

      final editor = imageEditor;
      if (editor == null) {
        notDetected++;
        warnings.add('${asset.name}: كشف الحدود غير متاح في هذا البناء.');
      } else {
        try {
          final source = await editor.open(asset, cancellation: cancellation);
          final rawProposal = editor is BoundaryProposalImageEditor
              ? await editor.suggestProposal(
                  source.preview,
                  cancellation: cancellation,
                )
              : null;
          final corners = editor is BoundaryProposalImageEditor
              ? rawProposal?.corners
              : await editor.suggest(source.preview);
          if (corners == null) {
            notDetected++;
            warnings.add(
              '${asset.name}: لا يتوفر كشف تلقائي للحدود في هذا الإصدار؛ بقيت الصورة كاملة ويمكن ضبط القص يدوياً.',
            );
          } else {
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
              ),
              sourceWidth: source.width,
              sourceHeight: source.height,
            );
            final authorization = decision.cropAuthorization;
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
                  '${asset.name}: ${boundaryReviewReasonMessage(reason)}',
                );
              }
            } else {
              current = await applyAuthorizedCrop(
                current,
                asset,
                authorization,
                sourceWidth: source.width,
                sourceHeight: source.height,
              );
              // The accepted crop creates a new revision with its measured
              // output dimensions. Use that aspect for the provisional size;
              // the pre-crop camera frame is a different image region.
              asset = current.assets.firstWhere((entry) => entry.id == id);
              cropped++;
            }
          }
        } on RevisionConflict {
          rethrow;
        } catch (error) {
          notDetected++;
          warnings.add(
            '${asset.name}: تعذر تطبيق القص التلقائي؛ بقي الأصل محفوظاً (${userError(error)}).',
          );
        }
      }

      // The legacy import path has no independent OCR/visual type model. Keep
      // the measured image editable with a provisional size; never infer a
      // catalog kind from its name or aspect ratio.
      const kind = DocumentKind.unknown;
      const recognitionConfidence = 0.0;
      final size = provisionalSize(width: asset.width, height: asset.height);
      warnings.add(
        '${asset.name}: لم يُتعرّف على نوع المستمسك؛ اختر النوع من تبويب «المستمسك» ليُطبَّق مقاسه ويوضع على الورقة.',
      );
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
          sizeConfirmed: false,
        ),
      );
      if (IntakeDiagnostics.isActive) {
        IntakeDiagnostics.record(
          IntakeDiagnosticEntry(
            stage: 'intake_item_created',
            assetId: asset.id,
            itemId: createdItemId,
            sourceWidth: asset.width,
            sourceHeight: asset.height,
            verdict: 'awaiting_size',
            documentKind: kind,
            sizeConfirmed: false,
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
    if (deferArrangement) {
      current = await projects.save(current);
    } else {
      final arrangement = arrangeDocuments(current, keepPlaced: keepPlaced);
      current = await projects.save(arrangement.result);
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
    return runCancellableIsolate(
      () => imaging.suggestAutoAdjustments(
        cropPreview,
        quarterTurns: quarterTurns,
      ),
      cancellation: cancellation,
      debugName: 'crop-auto-adjust',
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
    final validation = requireValidManualBoundary(
      corners: recipe.geometry.corners,
      sourceWidth: resolvedWidth,
      sourceHeight: resolvedHeight,
      adjustments: recipe.adjustments,
      documentKind: documentKind,
      customSizeMm: customSizeMm,
      catalog: project.catalog,
      requireConfirmedSize: true,
    );
    final updated = await createImageRevision(project, asset, recipe);
    final natural = project.catalog.natural(documentKind);
    final resolvedSize = natural != null && customSizeMm == null
        ? project.catalog.sizeFor(
            documentKind,
            landscape: updated.width >= updated.height,
          )!
        : validation.confirmedSizeMm!;
    final next = applyManualConfirmationToProject(
      project,
      updatedAsset: updated,
      recipe: recipe,
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
    PhysicalSizeMm? customSizeMm,
    int? sourceWidth,
    int? sourceHeight,
    bool replaceUnconfirmedSourcePlaceholder = true,
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
    _guardLargeFrameCrop(rootSource, recipe);
    final editor = imageEditor;
    require(editor != null, 'خدمة معالجة الصور غير متاحة.');

    final (effectiveWidth, effectiveHeight) = await _resolveSourceDimensions(
      rootSource,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    final validation = requireValidManualBoundary(
      corners: recipe.geometry.corners,
      sourceWidth: effectiveWidth,
      sourceHeight: effectiveHeight,
      adjustments: recipe.adjustments,
      documentKind: documentKind,
      customSizeMm: customSizeMm,
      catalog: project.catalog,
      requireConfirmedSize: true,
    );

    final cropBytes = editor is CropBytesImageEditor
        ? await editor.renderCropBytes(rootSource, recipe)
        : await editor!.preview(rootSource, recipe);
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
    final natural = project.catalog.natural(documentKind);
    final resolvedSize = natural != null && customSizeMm == null
        ? project.catalog.sizeFor(
            documentKind,
            landscape: derived.width >= derived.height,
          )!
        : validation.confirmedSizeMm!;
    final next = appendManualDerivedDocumentToProject(
      project,
      sourceAsset: rootSource,
      derivedAsset: derived,
      recipe: recipe,
      documentKind: documentKind,
      sizeMm: resolvedSize,
      nextId: newId,
      replaceUnconfirmedSourcePlaceholder: replaceUnconfirmedSourcePlaceholder,
    );
    final saved = await projects.save(next);
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
    await source.cleanup?.call();
  } catch (_) {
    /* Only private picker cache; never let cleanup mask a committed import. */
  }
}
