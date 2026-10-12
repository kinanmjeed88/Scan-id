import '../domain/project.dart';

abstract interface class ProjectRecovery {
  Future<Project> metadata(String id);
  Future<Project> rebuildDerived(Project project);
  String? get warning;

  /// Projects whose recovery copy is missing or does not match saved data.
  Future<Set<String>> staleRecoveryPoints();

  /// Rewrites one project's recovery copy from the saved data.
  Future<void> refreshRecoveryPoint(String projectId);
}
