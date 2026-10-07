import 'dart:isolate';
import 'dart:math' as math;

import '../domain/document_kind.dart';
import '../domain/image_adjustments.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import '../domain/image_limits.dart';
import 'contracts.dart';
import 'project_backups.dart';
import 'camera_capture.dart';
import 'project_recovery.dart';
import 'ids.dart';
import 'image_reader.dart';
import 'packing_service.dart';
import '../domain/crop_draft.dart';
import '../imaging/auto_adjustments.dart' as imaging;

class ImportSource {
  const ImportSource(this.name, this.openRead, {this.cleanup});
  final Future<void> Function()? cleanup;
  final String name;
  final Stream<List<int>> Function() openRead;
}

class ImportFailure {
  const ImportFailure(this.name, this.message);
  final String name;
  final String message;
}

class ImportReport {
  const ImportReport(this.project, this.imported, this.failures);
  final Project project;
  final int imported;
  final List<ImportFailure> failures;
}

class AutomaticLayoutReport {
  AutomaticLayoutReport({
    required this.project,
    required this.cropped,
    required this.notDetected,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);

  final Project project;
  final int cropped;
  final int notDetected;
  final List<String> warnings;
  int get unplaced =>
      project.items.where((item) => item.pageIndex == null).length;
}

/// A replaced source: the record is saved and the aspect warning is explicit.
class ReplaceReport {
  const ReplaceReport(this.project, this.aspectChanged);
  final Project project;

  /// The rectangle on the sheet no longer matches the new pixel proportions.
  final bool aspectChanged;
}

/// Result of deleting a project: the record is gone, files normally too.
class ProjectDeletion {
  const ProjectDeletion({this.warning});
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
  });
  final ProjectBackups? backups;
  final CameraCapture? camera;
  final ProjectRecovery? recovery;
  final ImageEditor? imageEditor;
  final StorageMaintenance? maintenance;
  final ProjectRepository projects;
  final AssetRepository assets;

  Future<Project> create(String name) async {
    final now = DateTime.now().toUtc();
    return projects.create(
      Project(id: newId(), name: name.trim(), createdAt: now, updatedAt: now),
    );
  }

  Future<Project> rename(Project project, String name) async =>
      projects.save(project.copyWith(name: name.trim()));

  /// Each successfully imported image is committed before processing the next.
  /// A batch may partially succeed; report precisely rather than losing work.
  Future<ImportReport> importImages(
    Project project,
    List<ImportSource> sources,
  ) async {
    var current = project;
    var imported = 0;
    final failures = <ImportFailure>[];
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
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
      }
    }
    return ImportReport(current, imported, List.unmodifiable(failures));
  }

  /// Runs the local boundary proposal for newly imported images, stores a
  /// reversible crop revision when one is found, assigns an explicitly
  /// reviewable type/size suggestion, then packs only size-confirmed items.
  /// Imported items remain off-sheet until the user confirms their dimensions;
  /// existing hand-arranged, confirmed items are immutable obstacles.
  Future<AutomaticLayoutReport> arrangeImportedImages(
    Project project,
    Iterable<String> assetIds,
  ) async {
    var current = project;
    var cropped = 0;
    var notDetected = 0;
    final warnings = <String>[];
    final newItems = <DocumentItem>[];
    final uniqueIds = assetIds.toSet();

    for (final id in uniqueIds) {
      final assetIndex = current.assets.indexWhere((entry) => entry.id == id);
      require(assetIndex >= 0, 'الصورة المراد ترتيبها ليست ضمن المشروع.');
      if (current.items.any((item) => item.assetId == id)) continue;
      var asset = current.assets[assetIndex];

      final editor = imageEditor;
      if (editor == null) {
        notDetected++;
        warnings.add('${asset.name}: كشف الحدود غير متاح في هذا البناء.');
      } else {
        try {
          final source = await editor.open(asset);
          final corners = await editor.suggest(source.preview);
          if (corners == null) {
            notDetected++;
            warnings.add(
              '${asset.name}: لم تُكتشف حدود موثوقة؛ أبقينا الصورة كاملة.',
            );
          } else {
            current = await applyCrop(
              current,
              asset,
              CropDraft(
                corners: corners,
                adjustments: asset.adjustments,
              ).toRecipe(source.width, source.height),
            );
            asset = current.assets.firstWhere((entry) => entry.id == id);
            cropped++;
          }
        } on RevisionConflict {
          rethrow;
        } catch (error) {
          notDetected++;
          warnings.add(
            '${asset.name}: تعذر تطبيق اقتراح القص؛ بقي الأصل محفوظاً (${userError(error)}).',
          );
        }
      }

      final suggestion = suggestDocumentType(
        name: asset.name,
        width: asset.width,
        height: asset.height,
      );
      final reference = suggestion.kind.publishedReferenceSize(
        landscape: asset.width >= asset.height,
      );
      final size =
          reference ??
          provisionalSize(width: asset.width, height: asset.height);
      final nextZ = current.items.fold<int>(
        0,
        (value, item) => math.max(value, item.zIndex),
      );
      newItems.add(
        DocumentItem(
          id: newId(),
          assetId: asset.id,
          x: current.paper.margins.left,
          y: current.paper.margins.top,
          width: size.width,
          height: size.height,
          pageIndex: null,
          zIndex: nextZ + newItems.length + 1,
          documentKind: suggestion.kind,
          recognitionConfidence: suggestion.confidence,
          // A type/name/ratio guess or published reference is not confirmation
          // that this particular document edition has the entered dimensions.
          sizeConfirmed: false,
        ),
      );
      warnings.add(
        reference == null
            ? '${asset.name}: الحجم المعروض مؤقت فقط؛ أدخل القياس الحقيقي وأكّده قبل وضعه على A4.'
            : '${asset.name}: عُرض مرجع قياس خاص بإصدار منشور؛ تحقّق من مطابقة نسختك وأكّد القياس قبل وضعه على A4.',
      );
    }

    if (newItems.isEmpty) {
      return AutomaticLayoutReport(
        project: current,
        cropped: cropped,
        notDetected: notDetected,
        warnings: warnings,
      );
    }
    current = current.copyWith(items: [...current.items, ...newItems]);
    try {
      final proposal = await createPackingProposal(
        current,
        includeLocked: false,
        allowRotation: false,
        onlyUnplaced: true,
        pageIndex: 0,
      );
      current = await projects.save(proposal.result);
      if (proposal.unplaced.isNotEmpty) {
        warnings.add(
          'تعذر وضع ${proposal.unplaced.length} مستمسكاً في الصفحة الأولى دون تغيير مقاسه؛ بقي غير موضوع.',
        );
      }
    } on RevisionConflict {
      rethrow;
    } catch (error) {
      // Do not lose imported references if a legacy page has an invalid fixed
      // obstacle. Keep the new items unplaced and let the user repair the page.
      current = await projects.save(current);
      warnings.add(
        'تعذر ترتيب الصفحة تلقائياً؛ حُفظت المستمسكات غير موضوعة لتعديلها يدوياً (${userError(error)}).',
      );
    }
    return AutomaticLayoutReport(
      project: current,
      cropped: cropped,
      notDetected: notDetected,
      warnings: warnings,
    );
  }

  /// Suggests a non-destructive, local auto-enhancement preset for manual
  /// review. The returned values can still be changed independently by sliders.
  Future<ImageAdjustments> suggestAutoAdjustments(
    Project project,
    ImageAsset asset,
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
    final source = await editor!.open(asset);
    return Isolate.run(
      () => imaging.suggestAutoAdjustments(
        source.preview,
        quarterTurns: asset.adjustments.quarterTurns,
      ),
    );
  }

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

  Future<Project> applyCrop(
    Project project,
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async {
    final updated = await createImageRevision(project, asset, recipe);
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
      final updated = ImageAsset(
        id: asset.id,
        captureId: asset.captureId,
        name: source.name,
        originalPath: files.originalPath,
        workingPath: files.workingPath,
        thumbnailPath: files.thumbnailPath,
        width: files.width,
        height: files.height,
        transforms: log.skip(math.max(0, log.length - 500)).toList(),
      );
      final saved = await projects.save(
        project.copyWith(
          assets: [
            for (final entry in project.assets)
              entry.id == asset.id ? updated : entry,
          ],
        ),
      );
      return ReplaceReport(saved, aspectChanged.abs() > 0.01);
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

  Future<Project> removeAsset(Project project, String assetId) async {
    require(
      project.assets.any((asset) => asset.id == assetId),
      'الصورة ليست ضمن هذا المشروع.',
    );
    require(
      !project.items.any((item) => item.assetId == assetId),
      'الصورة مستخدمة داخل الورقة؛ أزل العناصر المرتبطة أولاً.',
    );
    return projects.save(
      project.copyWith(
        assets: project.assets.where((a) => a.id != assetId).toList(),
      ),
    );
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
    } catch (_) {
      return const ProjectDeletion(
        warning:
            'حُذف المشروع من القائمة، وتعذر حذف ملفاته الآن. لن تتأثر المشاريع الأخرى؛ أعد المحاولة من «صيانة المساحة».',
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

  StorageMaintenance _maintenance() {
    final store = maintenance;
    require(store != null, 'صيانة الملفات غير متاحة في هذا البناء.');
    return store!;
  }
}

/// Never expose absolute filesystem paths / personal filenames from IO errors.
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
