import '../domain/project.dart';

abstract interface class ProjectRecovery {
  Future<Project> metadata(String id);
  Future<Project> rebuildDerived(Project project);
  String? get warning;
}
