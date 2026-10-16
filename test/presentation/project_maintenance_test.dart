import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_recovery.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/project_screen.dart';
import 'package:scan_id/presentation/shared.dart';

import 'editor_harness.dart';

/// The tools that need a project live with that project. They were also offered
/// in settings, where no project is selected — which meant they acted on
/// whichever project happened to be first. This file holds the guarantee that
/// moving them did not change when they run.
void main() {
  testWidgets(
    'the project repair tool explains itself, and never acts on cancel',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = MemoryProjects();
      final project = await repository.create(editorProject(items: []));
      final recovery = _TestRecovery(project);
      await tester.pumpWidget(
        AppShell(
          home: ProjectScreen(
            project: project,
            service: ProjectService(
              repository,
              NoAssets(),
              recovery: recovery,
            ),
            pickImages: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('البيانات والصيانة'));
      await tester.pumpAndSettle();
      expect(find.text('إصلاح النسخ من الأصول'), findsOneWidget);

      final row = find.ancestor(
        of: find.text('إصلاح النسخ من الأصول'),
        matching: find.byType(ExplainedAction),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byIcon(Icons.info_outline)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('بالوصفة المحفوظة'),
        findsOneWidget,
        reason: 'the row must say what it rebuilds and what it leaves alone',
      );
      expect(recovery.rebuildCount, 0, reason: 'reading is not running');
      await tester.tap(find.text('فهمت'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('إصلاح النسخ من الأصول'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(recovery.rebuildCount, 0);

      await tester.tap(find.text('إصلاح النسخ من الأصول'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إعادة إنشاء النسخ'));
      await tester.pumpAndSettle();
      expect(recovery.rebuildCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

class _TestRecovery implements ProjectRecovery {
  _TestRecovery(this.project);

  final Project project;
  int rebuildCount = 0;

  @override
  Future<Project> metadata(String id) async => project;

  @override
  Future<Project> rebuildDerived(Project value) async {
    rebuildCount++;
    return value;
  }

  @override
  String? get warning => null;

  @override
  Future<Set<String>> staleRecoveryPoints() async => const <String>{};

  @override
  Future<void> refreshRecoveryPoint(String projectId) async {}
}
