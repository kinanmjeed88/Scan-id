import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/ota_update.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/update_installer.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/shared.dart';
import 'package:scan_id/presentation/settings_screen.dart';

import 'editor_harness.dart';

/// A feed the card can be pointed at: one answer, no network.
class _FakeSource implements UpdateSource {
  _FakeSource(this.answer, {this.error});

  final UpdateInfo? answer;
  final Object? error;
  int checks = 0;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    required UpdatePlatform platform,
  }) async {
    checks++;
    final failure = error;
    if (failure != null) throw failure;
    return answer;
  }
}

class _FakeInstaller implements UpdateInstaller {
  String? receivedPath;

  @override
  Future<InstallOutcome> install(String filePath) async {
    receivedPath = filePath;
    return const InstallOutcome(started: true, message: 'فُتح مثبت النظام.');
  }
}

UpdateInfo _updateInfo({int size = 4 * 1024 * 1024}) => UpdateInfo(
  currentVersion: '0.1.0',
  newVersion: '0.2.0',
  downloadUrl: 'https://github.com/x/y/releases/download/v0.2.0/app.apk',
  summary: 'see https://example.com for the package',
  size: size,
  sha256: 'a' * 64,
);

Future<void> _pumpSettings(
  WidgetTester tester, {
  ProjectService? service,
  Size size = const Size(360, 900),
  SaveBackup? saveBackup,
  Future<Project?> Function()? restoreBackup,
  ExternalUrlLauncher? launchExternalUrl,
  UpdateSource? updateSource,
  UpdateInstaller? updateInstaller,
  TextDirection direction = TextDirection.rtl,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final shown = service ?? ProjectService(MemoryProjects(), NoAssets());
  await tester.pumpWidget(
    AppShell(
      home: Directionality(
        textDirection: direction,
        child: SettingsScreen(
          service: shown,
          saveBackup: saveBackup,
          restoreBackup: restoreBackup,
          launchExternalUrl: launchExternalUrl,
          updateSource: updateSource,
          updateInstaller: updateInstaller,
          currentVersion: '0.1.0',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.dragUntilVisible(
    target,
    find.byType(CustomScrollView),
    const Offset(0, -400),
  );
  await tester.pumpAndSettle();
}

Finder _toolRow(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(ExplainedAction),
);

/// Storage maintenance the widget can be pointed at: it records what was
/// deleted instead of touching files, so the test can prove the confirmation is
/// what stands between the button and the disk.
class _FakeMaintenance implements StorageMaintenance {
  _FakeMaintenance(this.orphanPaths);

  final List<String> orphanPaths;
  final List<String> deleted = [];

  @override
  Future<OrphanFiles> findOrphans(List<Project> projects) async =>
      OrphanFiles(orphanPaths, orphanPaths.length * 1024);

  @override
  Future<int> deleteFiles(Iterable<String> relativePaths) async {
    deleted.addAll(relativePaths);
    return relativePaths.length;
  }

  @override
  Future<void> deleteProjectFiles(String projectId) async {}

  @override
  Future<int> pruneStaging({
    Duration olderThan = const Duration(days: 1),
  }) async => 0;
}

void main() {
  testWidgets('settings opens with no project and shows no project tools', (
    tester,
  ) async {
    await _pumpSettings(tester);

    expect(find.text('النسخ والاستعادة'), findsOneWidget);
    expect(find.text('المساحة والاسترداد'), findsOneWidget);
    expect(find.text('البيانات الشخصية للمطور'), findsOneWidget);
    expect(find.text('تحديث التطبيق'), findsOneWidget);
    // The screen is about the app: no project name, and no tool that would edit
    // one from here.
    expect(find.text('مشروع حالي'), findsNothing);
    expect(find.text('محرر ورقة A4'), findsNothing);
    expect(find.text('تصدير وطباعة'), findsNothing);
    expect(find.text('إصلاح النسخ من الأصول'), findsNothing);
    expect(find.text('استرداد التقاط معلق'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every tool explains itself, and explaining never acts', (
    tester,
  ) async {
    var backups = 0;
    await _pumpSettings(
      tester,
      saveBackup: (project) async {
        backups++;
        return true;
      },
    );
    await _scrollTo(tester, find.text('نسخة احتياطية كاملة'));

    await tester.tap(
      find.descendant(
        of: _toolRow('نسخة احتياطية كاملة'),
        matching: find.byIcon(Icons.info_outline),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('فهمت'), findsOneWidget);
    expect(
      find.textContaining('ما الذي يُنسخ'),
      findsOneWidget,
      reason: 'the explanation names what the tool reads and what it leaves',
    );
    expect(backups, 0);
    await tester.tap(find.text('فهمت'));
    await tester.pumpAndSettle();
    expect(find.text('فهمت'), findsNothing);

    // A long press on the row answers the same question, so a person who is not
    // sure what the row even is does not have to hit a small icon to learn.
    await tester.longPress(find.text('نسخة احتياطية كاملة'));
    await tester.pumpAndSettle();
    expect(find.text('فهمت'), findsOneWidget);
    await tester.tap(find.text('فهمت'));
    await tester.pumpAndSettle();
    expect(backups, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('storage and recovery tools are explained too', (tester) async {
    await _pumpSettings(tester);
    await _scrollTo(tester, find.text('صيانة المساحة والملفات غير المرتبطة'));

    await tester.tap(
      find.descendant(
        of: _toolRow('صيانة المساحة والملفات غير المرتبطة'),
        matching: find.byIcon(Icons.info_outline),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('ما الذي يُحذف'), findsOneWidget);
    await tester.tap(find.text('فهمت'));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('استرداد قاعدة المشاريع من نقاط الحفظ'));
    await tester.tap(
      find.descendant(
        of: _toolRow('استرداد قاعدة المشاريع من نقاط الحفظ'),
        matching: find.byIcon(Icons.info_outline),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('القاعدة القديمة وصور المشاريع تبقى'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('backup with nothing to back up says so instead of writing', (
    tester,
  ) async {
    await _pumpSettings(tester);
    await _scrollTo(tester, find.text('نسخة احتياطية كاملة'));
    await tester.tap(find.text('نسخة احتياطية كاملة'));
    await tester.pumpAndSettle();

    expect(
      find.text('لا يوجد مشروع بعد؛ أنشئ مشروعاً أولاً ثم احفظ نسخة عنه.'),
      findsOneWidget,
    );
    expect(find.text('متابعة إلى الحفظ'), findsNothing);
  });

  testWidgets('several projects are chosen by name, not by list order', (
    tester,
  ) async {
    final repository = MemoryProjects();
    final first = await repository.create(
      editorProject(items: []).copyWith(name: 'مشروع الجواز'),
    );
    final second = await repository.create(
      editorProject(items: []).copyWith(name: 'مشروع الهوية'),
    );
    Project? chosen;
    await _pumpSettings(
      tester,
      service: ProjectService(repository, NoAssets()),
      saveBackup: (project) async {
        chosen = project;
        return true;
      },
    );
    await _scrollTo(tester, find.text('نسخة احتياطية كاملة'));
    await tester.tap(find.text('نسخة احتياطية كاملة'));
    await tester.pumpAndSettle();

    expect(find.text('أي مشروع تنسخه؟'), findsOneWidget);
    expect(find.text('مشروع الجواز'), findsOneWidget);
    await tester.tap(find.text('مشروع الهوية').last);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('نسخة احتياطية كاملة لـ«مشروع الهوية»'),
      findsOneWidget,
    );
    await tester.tap(find.text('متابعة إلى الحفظ'));
    await tester.pumpAndSettle();
    expect(chosen?.id, second.id);
    expect(chosen?.id, isNot(first.id));
    expect(find.text('حُفظت نسخة «مشروع الهوية».'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one project needs no extra question', (tester) async {
    final repository = MemoryProjects();
    final only = await repository.create(
      editorProject(items: []).copyWith(name: 'مشروع واحد'),
    );
    Project? chosen;
    await _pumpSettings(
      tester,
      service: ProjectService(repository, NoAssets()),
      saveBackup: (project) async {
        chosen = project;
        return true;
      },
    );
    await _scrollTo(tester, find.text('نسخة احتياطية كاملة'));
    await tester.tap(find.text('نسخة احتياطية كاملة'));
    await tester.pumpAndSettle();

    expect(find.text('أي مشروع تنسخه؟'), findsNothing);
    await tester.tap(find.text('متابعة إلى الحفظ'));
    await tester.pumpAndSettle();
    expect(chosen?.id, only.id);
  });

  testWidgets('cancel at the confirmation copies nothing', (tester) async {
    var backups = 0;
    final repository = MemoryProjects();
    await repository.create(editorProject(items: []));
    await _pumpSettings(
      tester,
      service: ProjectService(repository, NoAssets()),
      saveBackup: (project) async {
        backups++;
        return true;
      },
    );
    await _scrollTo(tester, find.text('نسخة احتياطية كاملة'));
    await tester.tap(find.text('نسخة احتياطية كاملة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(backups, 0);
    expect(find.text('حُفظت نسخة'), findsNothing);
  });

  testWidgets('three contact marks share one row at every phone width', (
    tester,
  ) async {
    for (final width in [320.0, 360.0]) {
      for (final direction in [TextDirection.rtl, TextDirection.ltr]) {
        await _pumpSettings(
          tester,
          size: Size(width, 900),
          direction: direction,
        );
        await _scrollTo(tester, find.text('YouTube'));

        final tops = [
          'YouTube',
          'Telegram',
          'مراسلة المطور',
        ].map((label) => tester.getTopLeft(find.text(label)).dy).toList();
        expect(
          tops.toSet(),
          hasLength(1),
          reason: '$width dp $direction: three marks, one row, no wrapping',
        );
        expect(find.text('YouTube'), findsOneWidget);
        expect(find.text('قناة تيليجرام'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('a contact mark opens its own link and reports a failure', (
    tester,
  ) async {
    final attempted = <Uri>[];
    await _pumpSettings(
      tester,
      launchExternalUrl: (uri) async {
        attempted.add(uri);
        return false;
      },
    );
    await _scrollTo(tester, find.text('مراسلة المطور'));
    await tester.tap(find.text('مراسلة المطور'));
    await tester.pumpAndSettle();

    expect(attempted.single.host, 't.me');
    expect(find.text('لم يتمكن النظام من فتح الرابط.'), findsOneWidget);
  });

  testWidgets('the update card speaks versions, never sources', (tester) async {
    final source = _FakeSource(_updateInfo());
    await _pumpSettings(
      tester,
      updateSource: source,
      updateInstaller: _FakeInstaller(),
    );
    await _scrollTo(tester, find.text('التحقق من التحديث'));
    await tester.tap(find.text('التحقق من التحديث'));
    await tester.pumpAndSettle();

    expect(find.text('يتوفر إصدار أحدث'), findsOneWidget);
    expect(find.text('الإصدار الحالي: 0.1.0'), findsOneWidget);
    expect(find.text('الإصدار الجديد: 0.2.0'), findsOneWidget);
    expect(find.textContaining('0.2.0'), findsWidgets);
    // No repository, host, package filename or release-notes link reaches the
    // person using the app: the update card answers a question, it does not
    // hand over a task the app could have done.
    for (final forbidden in [
      'github',
      'GitHub',
      'http',
      '.apk',
      'example.com',
      'Scan-id',
      'releases',
    ]) {
      expect(
        find.textContaining(forbidden),
        findsNothing,
        reason: 'the card must not surface "$forbidden"',
      );
    }
    expect(find.text('فتح صفحة الإصدارات'), findsNothing);
    expect(find.byIcon(Icons.open_in_new), findsNothing);

    await tester.tap(find.text('لاحقاً'));
    await tester.pumpAndSettle();
    expect(source.checks, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed check explains itself without a link', (tester) async {
    await _pumpSettings(
      tester,
      updateSource: _FakeSource(
        null,
        error: const UpdateFailure(
          UpdateFailureKind.unavailable,
          'no route',
        ),
      ),
    );
    await _scrollTo(tester, find.text('التحقق من التحديث'));
    await tester.tap(find.text('التحقق من التحديث'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('لا يمكن الوصول إلى مصدر التحديثات'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the update card explains what it asks for', (
    tester,
  ) async {
    await _pumpSettings(tester, updateSource: _FakeSource(null));
    await _scrollTo(tester, find.text('تحديث التطبيق'));

    await tester.tap(find.byTooltip('كيف يعمل التحديث؟'));
    await tester.pumpAndSettle();
    expect(find.textContaining('لا يُثبَّت شيء بصمت'), findsOneWidget);
    expect(find.textContaining('رقم الإصدار فقط'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('maintenance says so when there is nothing to delete', (
    tester,
  ) async {
    final repository = MemoryProjects();
    await repository.create(editorProject(items: []));
    final maintenance = _FakeMaintenance(const <String>[]);
    await _pumpSettings(
      tester,
      service: ProjectService(
        repository,
        NoAssets(),
        maintenance: maintenance,
      ),
    );
    await _scrollTo(tester, find.text('صيانة المساحة والملفات غير المرتبطة'));
    await tester.tap(find.text('صيانة المساحة والملفات غير المرتبطة'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('لا ملفات غير مرتبطة بمشاريعك'),
      findsOneWidget,
    );
    expect(find.text('حذف الملفات'), findsNothing);
    expect(maintenance.deleted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('maintenance refuses politely when there is no project at all', (
    tester,
  ) async {
    // Settings must stay usable with nothing in it: the honest answer here is
    // that there is no list to compute an orphan set from — not a crash, and
    // not a delete that would treat an unreadable database as an empty one.
    final maintenance = _FakeMaintenance(['nothing.jpg']);
    await _pumpSettings(
      tester,
      service: ProjectService(
        MemoryProjects(),
        NoAssets(),
        maintenance: maintenance,
      ),
    );
    await _scrollTo(tester, find.text('صيانة المساحة والملفات غير المرتبطة'));
    await tester.tap(find.text('صيانة المساحة والملفات غير المرتبطة'));
    await tester.pumpAndSettle();

    expect(find.textContaining('قائمة المشاريع فارغة'), findsOneWidget);
    expect(find.text('حذف الملفات'), findsNothing);
    expect(maintenance.deleted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('maintenance counts the files first, then deletes on confirm', (
    tester,
  ) async {
    final repository = MemoryProjects();
    await repository.create(editorProject(items: []));
    final maintenance = _FakeMaintenance(['loose.jpg', 'old-work.jpg']);
    await _pumpSettings(
      tester,
      service: ProjectService(
        repository,
        NoAssets(),
        maintenance: maintenance,
      ),
    );
    await _scrollTo(tester, find.text('صيانة المساحة والملفات غير المرتبطة'));
    await tester.tap(find.text('صيانة المساحة والملفات غير المرتبطة'));
    await tester.pumpAndSettle();

    expect(find.text('حذف الملفات غير المرتبطة؟'), findsOneWidget);
    expect(find.textContaining('عدد العناصر: 2'), findsOneWidget);
    expect(maintenance.deleted, isEmpty);
    await tester.tap(find.text('حذف الملفات'));
    await tester.pumpAndSettle();

    expect(find.textContaining('أُزيل 2 من 2 عناصر'), findsOneWidget);
    expect(maintenance.deleted, ['loose.jpg', 'old-work.jpg']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a database recovery runs only on the confirmation', (
    tester,
  ) async {
    var restored = 0;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppShell(
        home: SettingsScreen(
          service: ProjectService(MemoryProjects(), NoAssets()),
          recoverStorage: () async => restored++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('استرداد قاعدة المشاريع من نقاط الحفظ'));
    await tester.tap(find.text('استرداد قاعدة المشاريع من نقاط الحفظ'));
    await tester.pumpAndSettle();
    expect(find.textContaining('لا تُفتح قائمة المشاريع'), findsOneWidget);
    expect(restored, 0);
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();
    expect(restored, 0);

    await tester.tap(find.text('استرداد قاعدة المشاريع من نقاط الحفظ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('استرداد القاعدة'));
    await tester.pumpAndSettle();
    expect(restored, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('install wording appears only where an installer can run', (
    tester,
  ) async {
    await _pumpSettings(tester, updateSource: _FakeSource(_updateInfo()));
    await _scrollTo(tester, find.text('التحقق من التحديث'));
    await tester.tap(find.text('التحقق من التحديث'));
    await tester.pumpAndSettle();
    expect(find.text('تنزيل وتحقّق'), findsWidgets);
    expect(find.text('تنزيل وتثبيت'), findsNothing);
    expect(
      find.textContaining('لا يُشغَّل شيء تلقائياً'),
      findsOneWidget,
      reason: 'a build that cannot install must not promise an install',
    );
    await tester.tap(find.text('لاحقاً'));
    await tester.pumpAndSettle();

    await _pumpSettings(
      tester,
      updateSource: _FakeSource(_updateInfo()),
      updateInstaller: _FakeInstaller(),
    );
    await _scrollTo(tester, find.text('التحقق من التحديث'));
    await tester.tap(find.text('التحقق من التحديث'));
    await tester.pumpAndSettle();
    expect(find.text('تنزيل وتثبيت'), findsWidgets);
    expect(find.textContaining('تفتح شاشة التثبيت'), findsOneWidget);
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

  testWidgets('settings opens from an empty home screen', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = ProjectService(MemoryProjects(), NoAssets());
    await tester.pumpWidget(
      AppShell(
        home: ProjectsScreen(service: service, pickImages: () async => []),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('الإعدادات'), findsOneWidget);
    expect(find.text('أنشئ مشروعاً أولاً للوصول إلى الإعدادات.'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
