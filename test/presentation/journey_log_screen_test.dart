import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/journey_log.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/journey_log_screen.dart';
import 'package:scan_id/presentation/settings_screen.dart';

import 'editor_harness.dart';

/// A log the widget can be pointed at: it answers from memory and records what
/// was cleared instead of touching a file.
class _FakeJourneyLog implements JourneyLog {
  _FakeJourneyLog([List<ImageJourney> initial = const []])
    : _entries = List.of(initial);

  List<ImageJourney> _entries;
  int cleared = 0;
  int reads = 0;

  @override
  Future<List<ImageJourney>> read() async {
    reads++;
    return List.of(_entries);
  }

  @override
  Future<JourneyLogStats> stats() async => JourneyLogStats(
    entries: _entries.length,
    bytes: _entries.length * 640,
  );

  @override
  Future<void> append(Iterable<ImageJourney> journeys) async {
    _entries = [...journeys, ..._entries];
  }

  @override
  Future<void> clear() async {
    cleared++;
    _entries = const [];
  }
}

JourneyStep _step(JourneyStage stage, JourneyOutcome outcome, String detail) =>
    JourneyStep(stage: stage, outcome: outcome, detail: detail);

ImageJourney _journey({
  String id = 'batch-0001-asset1',
  String image = 'البطاقة.jpg',
  String? project = 'مستمسكات العائلة',
  String batch = 'batch-0001',
  DateTime? startedAt,
  List<JourneyStep>? steps,
}) => ImageJourney(
  id: id,
  batchId: batch,
  projectId: 'project1',
  projectName: project ?? '',
  imageName: image,
  startedAt: startedAt ?? DateTime.utc(2026, 11, 9, 8, 30),
  steps:
      steps ??
      [
        _step(JourneyStage.selection, JourneyOutcome.passed, 'اختيرت من جهازك.'),
        _step(JourneyStage.copy, JourneyOutcome.passed, 'نُسخت إلى التطبيق.'),
        _step(
          JourneyStage.placement,
          JourneyOutcome.passed,
          'وُضع في الصفحة 1.',
        ),
      ],
);

Future<void> _pumpLog(
  WidgetTester tester,
  JourneyLog log, {
  Size size = const Size(420, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppShell(home: JourneyLogScreen(log: log)),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSettings(WidgetTester tester, JourneyLog log) async {
  tester.view.physicalSize = const Size(360, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppShell(
      home: SettingsScreen(
        service: ProjectService(MemoryProjects(), NoAssets()),
        currentVersion: '0.1.0',
        journeyLog: log,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty log explains how reports appear instead of showing a '
      'blank list', (tester) async {
    await _pumpLog(tester, _FakeJourneyLog());

    expect(find.text('سجل معالجة الصور'), findsOneWidget);
    expect(
      find.text('لم تُستورد أي صورة بعد على هذا الجهاز.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each image reports its stages in pipeline order, top to bottom',
      (tester) async {
    await _pumpLog(
      tester,
      _FakeJourneyLog([
        _journey(
          steps: [
            _step(
              JourneyStage.selection,
              JourneyOutcome.passed,
              'اختيرت من جهازك لتُضاف إلى المشروع.',
            ),
            _step(
              JourneyStage.copy,
              JourneyOutcome.passed,
              'نُسخت إلى مساحة التطبيق.',
            ),
            _step(
              JourneyStage.detection,
              JourneyOutcome.review,
              'الحافة قريبة من إطار الصورة.',
            ),
            _step(
              JourneyStage.placement,
              JourneyOutcome.passed,
              'وُضع في الصفحة 1 داخل حدود الورقة.',
            ),
          ],
        ),
      ]),
    );

    // The card starts collapsed: the file name and the conclusion are visible.
    expect(find.text('البطاقة.jpg'), findsOneWidget);
    expect(find.textContaining('أُضيفت إلى الورقة'), findsOneWidget);

    await tester.tap(find.text('البطاقة.jpg'));
    await tester.pumpAndSettle();

    final selection = tester.getTopLeft(find.text('اختيار الصورة')).dy;
    final copy = tester.getTopLeft(find.text('نسخ الصورة إلى المشروع')).dy;
    final detection = tester.getTopLeft(find.text('كشف الحدود')).dy;
    final placement = tester.getTopLeft(find.text('الإضافة إلى ورقة A4')).dy;
    expect(selection, lessThan(copy));
    expect(copy, lessThan(detection));
    expect(detection, lessThan(placement));

    expect(find.text('الحافة قريبة من إطار الصورة.'), findsOneWidget);
    expect(find.text('تحتاج مراجعة'), findsOneWidget);
    expect(find.text('تمّت'), findsWidgets);
  });

  testWidgets('a refused image says why it never reached the sheet', (
    tester,
  ) async {
    await _pumpLog(
      tester,
      _FakeJourneyLog([
        _journey(
          image: 'تالف.jpg',
          steps: [
            _step(
              JourneyStage.selection,
              JourneyOutcome.passed,
              'اختيرت من جهازك.',
            ),
            _step(
              JourneyStage.copy,
              JourneyOutcome.blocked,
              'تعذّر قراءة الملف كصورة.',
            ),
            _step(
              JourneyStage.placement,
              JourneyOutcome.blocked,
              'لم تدخل الورقة لأن الصورة لم تُستورد.',
            ),
          ],
        ),
      ]),
    );

    expect(find.text('تالف.jpg'), findsOneWidget);
    expect(find.textContaining('لم تُستورد'), findsOneWidget);
    await tester.tap(find.text('تالف.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('تعذّر قراءة الملف كصورة.'), findsOneWidget);
    expect(find.text('تعذّرت'), findsWidgets);
  });

  testWidgets('one intake run is grouped once, not once per image', (
    tester,
  ) async {
    await _pumpLog(
      tester,
      _FakeJourneyLog([
        _journey(id: 'batch-0002-b', image: 'ثانٍ.jpg', batch: 'batch-0002'),
        _journey(id: 'batch-0002-a', image: 'أول.jpg', batch: 'batch-0002'),
      ]),
    );
    expect(find.text('دفعة استيراد · مستمسكات العائلة'), findsOneWidget);
    expect(find.text('أول.jpg'), findsOneWidget);
    expect(find.text('ثانٍ.jpg'), findsOneWidget);
  });

  testWidgets('clearing asks first, then empties the log and nothing else',
      (tester) async {
    final log = _FakeJourneyLog([_journey()]);
    await _pumpLog(tester, log);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('حذف سجل معالجة الصور؟'), findsOneWidget);
    // Nothing is deleted before the confirmation.
    expect(log.cleared, 0);

    await tester.tap(find.widgetWithText(TextButton, 'إلغاء').first);
    await tester.pumpAndSettle();
    expect(log.cleared, 0);
    expect(find.text('البطاقة.jpg'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'حذف السجل'));
    await tester.pumpAndSettle();

    expect(log.cleared, 1);
    expect(find.text('البطاقة.jpg'), findsNothing);
    expect(
      find.text('لم تُستورد أي صورة بعد على هذا الجهاز.'),
      findsOneWidget,
    );
  });

  testWidgets('settings shows the log with its size and opens it on tap', (
    tester,
  ) async {
    final log = _FakeJourneyLog([_journey()]);
    await _pumpSettings(tester, log);

    expect(find.text('سجل معالجة الصور'), findsOneWidget);
    expect(find.textContaining('تقارير محفوظة: 1 صورة'), findsOneWidget);

    await tester.tap(find.text('فتح سجل معالجة الصور'));
    await tester.pumpAndSettle();

    expect(find.byType(JourneyLogScreen), findsOneWidget);
    expect(find.text('البطاقة.jpg'), findsOneWidget);
  });

  testWidgets('a host without a log says so instead of failing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppShell(
        home: SettingsScreen(
          service: ProjectService(MemoryProjects(), NoAssets()),
          currentVersion: '0.1.0',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('سجل معالجة الصور'), findsOneWidget);
    expect(find.text('السجل غير مفعّل في هذه النسخة'), findsOneWidget);
  });
}
