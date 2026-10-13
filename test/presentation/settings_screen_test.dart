import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/export_screen.dart';
import 'package:scan_id/presentation/settings_screen.dart';

import 'editor_harness.dart';

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.dragUntilVisible(
    target,
    find.byType(CustomScrollView),
    const Offset(0, -400),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('settings contacts wrap at 320 and 360 dp in RTL and LTR', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final width in [320.0, 360.0]) {
      for (final direction in [TextDirection.rtl, TextDirection.ltr]) {
        tester.view.physicalSize = Size(width, 900);
        final repository = MemoryProjects();
        final project = await repository.create(editorProject(items: []));
        final service = ProjectService(repository, NoAssets());
        await tester.pumpWidget(
          AppShell(
            home: Directionality(
              textDirection: direction,
              child: SettingsScreen(
                project: project,
                service: service,
                pickImages: () async => [],
                recoverStorage: null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _scrollTo(tester, find.text('تواصل مع المطور'));
        await tester.pumpAndSettle();

        expect(find.text('YouTube'), findsOneWidget);
        expect(find.text('قناة Telegram'), findsOneWidget);
        expect(find.text('مراسلة المطور'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: '$width dp, $direction must not overflow',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets(
    'settings states that OTA is unavailable without simulating a check',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = MemoryProjects();
      final project = await repository.create(editorProject(items: []));
      await tester.pumpWidget(
        AppShell(
          home: SettingsScreen(
            project: project,
            service: ProjectService(repository, NoAssets()),
            pickImages: () async => [],
            recoverStorage: null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.textContaining('التحديث الهوائي غير متاح'));

      expect(find.textContaining('التحديث الهوائي غير متاح'), findsOneWidget);
      expect(find.text('فحص التحديثات'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed external-link launch is reported to the user', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = MemoryProjects();
    final project = await repository.create(editorProject(items: []));
    final service = ProjectService(repository, NoAssets());
    final attempted = <Uri>[];
    await tester.pumpWidget(
      AppShell(
        home: SettingsScreen(
          project: project,
          service: service,
          pickImages: () async => [],
          recoverStorage: null,
          launchExternalUrl: (uri) async {
            attempted.add(uri);
            return false;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('YouTube'));
    await tester.tap(find.text('YouTube'));
    await tester.pumpAndSettle();

    expect(attempted, hasLength(1));
    expect(attempted.single.scheme, 'https');
    expect(find.text('لم يتمكن النظام من فتح الرابط.'), findsOneWidget);
  });

  testWidgets('successful external-link launches do not show an error', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = MemoryProjects();
    final project = await repository.create(editorProject(items: []));
    final service = ProjectService(repository, NoAssets());
    final attempted = <Uri>[];
    await tester.pumpWidget(
      AppShell(
        home: SettingsScreen(
          project: project,
          service: service,
          pickImages: () async => [],
          recoverStorage: null,
          launchExternalUrl: (uri) async {
            attempted.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('مراسلة المطور'));
    await tester.tap(find.text('مراسلة المطور'));
    await tester.pumpAndSettle();

    expect(attempted, hasLength(1));
    expect(attempted.single.host, 't.me');
    expect(find.text('لم يتمكن النظام من فتح الرابط.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('export and backup use the project returned by the editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = MemoryProjects();
    final project = await repository.create(editorProject(items: []));
    final service = ProjectService(repository, NoAssets());
    Project? backedUp;
    await tester.pumpWidget(
      AppShell(
        home: SettingsScreen(
          project: project,
          service: service,
          pickImages: () async => [],
          recoverStorage: null,
          saveBackup: (current) async {
            backedUp = current;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('محرر ورقة A4'));
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('rb-autoflow'));
    expect(repository.values[project.id]!.layout.autoFlow, isFalse);
    await tester.tap(find.byKey(const Key('ribbon-tab-file')));
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('rb-close'));

    await tester.tap(find.text('تصدير وطباعة'));
    await tester.pumpAndSettle();
    final export = tester.widget<ExportScreen>(find.byType(ExportScreen));
    expect(export.project.layout.autoFlow, isFalse);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('نسخة احتياطية كاملة'));
    await tester.tap(find.text('نسخة احتياطية كاملة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('متابعة إلى الحفظ'));
    await tester.pumpAndSettle();

    expect(backedUp, isNotNull);
    expect(backedUp!.layout.autoFlow, isFalse);
    expect(backedUp!.revision, repository.values[project.id]!.revision);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project list refreshes after a backup is restored in settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = MemoryProjects();
    await repository.create(
      editorProject(items: []).copyWith(name: 'مشروع قبل الاستعادة'),
    );
    final service = ProjectService(repository, NoAssets());
    final restored = Project(
      id: 'restored-project',
      name: 'مشروع مستعاد حديثاً',
      createdAt: DateTime.utc(2026, 10, 13),
      updatedAt: DateTime.utc(2026, 10, 13),
    );
    await tester.pumpWidget(
      AppShell(
        home: ProjectsScreen(
          service: service,
          pickImages: () async => [],
          restoreBackup: () async {
            await repository.create(restored);
            return restored;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('الإعدادات'), findsOneWidget);
    await _scrollTo(tester, find.text('استعادة نسخة احتياطية'));
    await tester.tap(find.text('استعادة نسخة احتياطية'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('اختيار ملف'));
    await tester.pumpAndSettle();

    expect(find.text('مشروع مستعاد حديثاً'), findsOneWidget);
    expect(find.text('مشروع قبل الاستعادة'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
