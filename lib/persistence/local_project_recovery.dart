import '../application/project_recovery.dart';
import '../domain/project.dart';
import '../domain/crop_draft.dart';
import '../domain/geometry.dart';
import 'local_project_repository.dart';
import 'local_image_editor.dart';

class LocalProjectRecovery implements ProjectRecovery {
  const LocalProjectRecovery(this.projects, this.editor);
  final LocalProjectRepository projects;
  final LocalImageEditor editor;
  @override
  Future<Project> metadata(String id) => projects.metadata(id);
  @override
  String? get warning => projects.checkpoints.warning;
  @override
  Future<Project> rebuildDerived(Project project) async {
    final restored = <ImageAsset>[];
    for (final asset in project.assets) {
      final source = await editor.open(asset);
      final recipe = asset.crop != null
          ? ImageEditRecipe(asset.crop!, asset.adjustments)
          : CropDraft(
              corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
              adjustments: asset.adjustments,
            ).toRecipe(source.width, source.height);
      restored.add(await editor.createRevision(asset, recipe));
    }
    // New revisions only; crop geometry, layout and external originals stay put.
    // A missing/corrupt original aborts without changing the committed metadata.
    return projects.save(project.copyWith(assets: restored));
  }
}
