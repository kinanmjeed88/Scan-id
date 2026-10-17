import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/ota_update.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/update_installer.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/update_prompt.dart';

import 'editor_harness.dart';

/// A feed with one answer and no socket.
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

/// A feed whose answer arrives only when the test says so, which is how a
/// person who navigates before the check returns can be represented.
class _DeferredSource implements UpdateSource {
  final Completer<UpdateInfo?> answer = Completer<UpdateInfo?>();
  int checks = 0;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    required UpdatePlatform platform,
  }) {
    checks++;
    return answer.future;
  }
}

/// Only ever used to tell the flow that this build has a system installer.
/// The scripted service answers the install itself.
class _FakeInstaller implements UpdateInstaller {
  @override
  Future<InstallOutcome> install(String filePath) async =>
      const InstallOutcome(started: true, message: 'فُتح مثبت النظام.');
}

/// A service whose transport is a script: the download can be held open long
/// enough for the dialog's own behaviour — cancelling, reporting — to be
/// observed, without a network or a file.
class _ScriptedService extends UpdateService {
  _ScriptedService({
    required super.source,
    required this.answer,
    this.hold = false,
  }) : super(currentVersion: '0.1.0', installer: _FakeInstaller());

  final DownloadResult answer;
  final bool hold;
  final Completer<void> release = Completer<void>();

  CancellationToken? cancellation;
  bool downloadAsked = false;
  bool installAsked = false;

  @override
  Future<DownloadResult> downloadUpdate(
    UpdateInfo update, {
    required void Function(int received, int total) onProgress,
    required void Function() onCancel,
    CancellationToken? cancellation,
  }) async {
    downloadAsked = true;
    this.cancellation = cancellation;
    if (hold) await release.future;
    return answer;
  }

  @override
  Future<InstallResult> installUpdate(
    UpdateInfo update,
    String filePath,
  ) async {
    installAsked = true;
    return InstallResult.success('فُتح مثبت النظام لإكمال التحديث.');
  }
}

UpdateInfo _updateInfo() => UpdateInfo(
  currentVersion: '0.1.0',
  newVersion: '0.2.0',
  downloadUrl: 'https://github.com/x/y/releases/download/v0.2.0/app.apk',
  size: 4 * 1024 * 1024,
  sha256: 'a' * 64,
);

UpdateService _plainService(UpdateSource source) => UpdateService(
  source: source,
  currentVersion: '0.1.0',
  installer: _FakeInstaller(),
);

/// The production shape: the check wraps the home screen, and an injected
/// service stands in for the release feed.
Future<void> _pumpStartup(WidgetTester tester, {UpdateService? updates}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppShell(
      home: StartupUpdateCheck(
        service: updates,
        child: ProjectsScreen(
          service: ProjectService(MemoryProjects(), NoAssets()),
          pickImages: () async => <ImportSource>[],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the app checks the feed once when it opens and offers the newer version',
    (tester) async {
      final source = _FakeSource(_updateInfo());
      await _pumpStartup(tester, updates: _plainService(source));

      expect(source.checks, 1);
      expect(find.text('يتوفر إصدار أحدث'), findsOneWidget);
      expect(find.text('الإصدار الحالي: 0.1.0'), findsOneWidget);
      expect(find.text('الإصدار الجديد: 0.2.0'), findsOneWidget);
      // The card and the startup offer name versions, never the feed.
      for (final forbidden in ['github', 'GitHub', 'http', '.apk']) {
        expect(
          find.textContaining(forbidden),
          findsNothing,
          reason: 'the startup offer must not surface "$forbidden"',
        );
      }

      await tester.tap(find.text('لاحقاً'));
      await tester.pumpAndSettle();
      expect(find.text('يتوفر إصدار أحدث'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the production shell hands its update service to the check', (
    tester,
  ) async {
    final source = _FakeSource(_updateInfo());
    await tester.pumpWidget(
      ScanIdApp(
        service: ProjectService(MemoryProjects(), NoAssets()),
        pickImages: () async => <ImportSource>[],
        updateService: _plainService(source),
      ),
    );
    await tester.pumpAndSettle();

    expect(source.checks, 1);
    expect(find.text('يتوفر إصدار أحدث'), findsOneWidget);
    await tester.tap(find.text('لاحقاً'));
    await tester.pumpAndSettle();
  });

  testWidgets('a check that finds nothing says nothing', (tester) async {
    final source = _FakeSource(null);
    await _pumpStartup(tester, updates: _plainService(source));

    expect(source.checks, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a check that cannot reach the feed says nothing', (
    tester,
  ) async {
    final source = _FakeSource(
      null,
      error: const UpdateFailure(UpdateFailureKind.unavailable, 'no route'),
    );
    await _pumpStartup(tester, updates: _plainService(source));

    // A failure of a check the person did not ask for must not greet them
    // before they have done anything; the settings card still reports one.
    expect(source.checks, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.textContaining('لا يمكن الوصول إلى مصدر التحديثات'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the check is asked once, not on every rebuild', (tester) async {
    final source = _FakeSource(null);
    await _pumpStartup(tester, updates: _plainService(source));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(source.checks, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('declining the startup offer downloads nothing', (tester) async {
    final service = _ScriptedService(
      source: _FakeSource(_updateInfo()),
      answer: DownloadResult.success('/tmp/scan-id-update.apk'),
    );
    await _pumpStartup(tester, updates: service);
    await tester.tap(find.text('لاحقاً'));
    await tester.pumpAndSettle();

    expect(service.downloadAsked, isFalse);
    expect(service.installAsked, isFalse);
  });

  testWidgets('accepting the startup offer downloads, verifies and installs', (
    tester,
  ) async {
    final service = _ScriptedService(
      source: _FakeSource(_updateInfo()),
      answer: DownloadResult.success('/tmp/scan-id-update.apk'),
    );
    await _pumpStartup(tester, updates: service);

    await tester.tap(find.widgetWithText(FilledButton, 'تنزيل وتثبيت'));
    await tester.pumpAndSettle();

    expect(service.downloadAsked, isTrue);
    expect(service.installAsked, isTrue);
    expect(find.textContaining('فُتح مثبت النظام'), findsOneWidget);

    await tester.tap(find.text('تم'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    // The screen behind the dialog still reports the one sentence the flow
    // ended in, so closing the dialog never hides the outcome.
    expect(find.textContaining('فُتح مثبت النظام'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the startup download stops it before an install', (
    tester,
  ) async {
    final service = _ScriptedService(
      source: _FakeSource(_updateInfo()),
      answer: DownloadResult.error('أُلغي تنزيل التحديث.'),
      hold: true,
    );
    await _pumpStartup(tester, updates: service);

    await tester.tap(find.widgetWithText(FilledButton, 'تنزيل وتثبيت'));
    // Only pump, never settle: the indeterminate bar animates for as long as
    // the held download runs.
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('إلغاء التنزيل'), findsOneWidget);
    expect(service.cancellation, isNotNull);
    expect(service.cancellation!.isCancelled, isFalse);

    await tester.tap(find.text('إلغاء التنزيل'));
    await tester.pump();
    expect(service.cancellation!.isCancelled, isTrue);

    service.release.complete();
    await tester.pumpAndSettle();
    expect(service.installAsked, isFalse);
    expect(find.textContaining('أُلغي تنزيل التحديث'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an answer that arrives after the person moved on is dropped', (
    tester,
  ) async {
    final source = _DeferredSource();
    await _pumpStartup(tester, updates: _plainService(source));
    expect(source.checks, 1);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('الإعدادات'), findsOneWidget);

    source.answer.complete(_updateInfo());
    await tester.pumpAndSettle();
    // The offer must not cover work the person has already started; the card
    // in settings can still check on demand.
    expect(find.text('يتوفر إصدار أحدث'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
