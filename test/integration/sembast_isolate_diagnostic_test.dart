import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// Diagnostic only: Sembast IO explicitly does not support cross-isolate use.
/// This uses a disposable root and never models the unsupported setup as safe.
void main() {
  test('characterizes a stale project list across Sembast IO isolates', () async {
    final root = await Directory.systemTemp.createTemp('sembast_isolates_');
    var owner = await LocalProjectRepository.open(root);
    try {
      // Open and populate the owner's in-memory view before the other isolate.
      expect(await owner.list(), isEmpty);
      final rootPath = root.path;
      final id = await Isolate.run(() async {
        final other = await LocalProjectRepository.open(Directory(rootPath));
        try {
          final now = DateTime.utc(2026, 1, 1);
          final project = Project(
            id: 'other_isolate',
            name: 'test',
            createdAt: now,
            updatedAt: now,
          );
          await other.create(project);
          return project.id;
        } finally {
          await other.close();
        }
      });
      // A fresh lock around this old owner would not reload its view.
      expect((await owner.list()).map((p) => p.id), isNot(contains(id)));
      await owner.close();
      owner = await LocalProjectRepository.open(root);
      expect((await owner.get(id)).id, id);
    } finally {
      await owner.close();
      await root.delete(recursive: true);
    }
  });
}
