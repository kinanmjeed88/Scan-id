import 'dart:typed_data';

import '../domain/project.dart';
import '../domain/validation.dart';
import '../domain/image_limits.dart';
import 'contracts.dart';
import 'ids.dart';

class ImportSource {
  const ImportSource(this.name, this.openRead);
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

class ProjectService {
  const ProjectService(this.projects, this.assets);
  final ProjectRepository projects;
  final AssetRepository assets;

  Future<Project> create(String name) {
    final now = DateTime.now().toUtc();
    return projects.create(
      Project(id: newId(), name: name.trim(), createdAt: now, updatedAt: now),
    );
  }

  Future<Project> rename(Project project, String name) =>
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
        final bytes = await _boundedRead(source.openRead());
        final asset = await assets.importImage(current.id, source.name, bytes);
        current = await projects.save(
          current.copyWith(assets: [...current.assets, asset]),
        );
        imported++;
      } on RevisionConflict catch (error) {
        failures.add(ImportFailure(source.name, error.message));
        // The in-memory project is stale; continuing would create more orphans.
        for (final skipped in sources.skip(index + 1)) {
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
      }
    }
    return ImportReport(current, imported, List.unmodifiable(failures));
  }

  Future<Project> removeAsset(Project project, String assetId) {
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
}

Future<Uint8List> _boundedRead(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    require(
      builder.length + chunk.length <= maxImportBytes,
      'الصورة أكبر من حد الاستيراد (20 MiB).',
    );
    builder.add(chunk);
  }
  return builder.takeBytes();
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
