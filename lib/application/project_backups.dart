import 'dart:io';
import '../domain/project.dart';

/// Portable project backup, separate from the metadata database and widgets.
abstract interface class ProjectBackups {
  Future<File> create(Project project, Directory temporary);
  Future<Project> restore(File source);
}
