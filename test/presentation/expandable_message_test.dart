/// The one-line + tap-to-expand contract for every long message surface.
///
/// The intake banner and the snackbar used to wrap multi-line messages and
/// clip them with a maxLines budget, so half of the per-image warnings was
/// invisible. These tests pin the replacement behavior: exactly one line,
/// and the full message one tap away.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/presentation/shared.dart';

import 'editor_harness.dart';

const _summary =
    'قُصّ تلقائياً: 0 · أنواع بالكتالوج: 0 · حدود بانتظار المراجعة: 2 · '
    'تصنيف قيد المراجعة: 2 · بلا رباعي صالح: 0 · مقاس غير محدد: 2 · خارج الورق: 0';
const _warning =
    'images (14).jpeg: ثقة كشف الذكاء الاصطناعي دون حد القبول؛ '
    'حُفظت الزوايا المقترحة للمراجعة والتعديل اليدوي دون قصّ صامت.';
const _warningTwo =
    'images (9).jpeg: لم يُتعرّف على النوع — لم تُقرأ أسطر؛ '
    'اختر النوع من تبويب «المستمسك».';

void main() {
  testWidgets('oneLineMessage collapses lines without losing content', (
    tester,
  ) async {
    expect(oneLineMessage('الأول\nالثاني\nالثالث'), 'الأول ؛ الثاني ؛ الثالث');
    expect(oneLineMessage('سطر واحد'), 'سطر واحد');
    expect(oneLineMessage('\n الأول \n\n الثاني \n'), 'الأول ؛ الثاني');
    expect(oneLineMessage('\n\n'), '');
  });

  testWidgets('a long snackbar stays one line; tap opens the full text', (
    tester,
  ) async {
    const message = '$_summary\n$_warning';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const Key('show'),
                onPressed: () => showMessage(context, message),
                child: const Text('اعرض'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('show')));
    await tester.pumpAndSettle();

    final line = tester.widget<Text>(
      find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)),
    );
    expect(line.maxLines, 1);
    expect(line.overflow, TextOverflow.ellipsis);

    await tester.tap(find.byType(ExpandableMessage));
    await tester.pumpAndSettle();
    final full = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(full.data, message);
    expect(full.data, contains('\n'));
    await tester.tap(find.text('إغلاق'));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold)),
    ).clearSnackBars();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the intake banner is one line; tap opens the full text', (
    tester,
  ) async {
    await EditorHarness.pump(
      tester,
      intakeSummary: _summary,
      intakeWarnings: const [_warning, _warningTwo],
    );
    final banner = find.byKey(const Key('intake-summary'));
    expect(banner, findsOneWidget);

    final line = tester.widget<Text>(
      find.descendant(of: banner, matching: find.byType(Text)).first,
    );
    expect(line.maxLines, 1);
    expect(line.overflow, TextOverflow.ellipsis);

    await tester.tap(
      find.descendant(of: banner, matching: find.byType(ExpandableMessage)),
    );
    await tester.pumpAndSettle();
    final full = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(full.data, contains(_summary));
    expect(full.data, contains('images (14).jpeg'));
    expect(full.data, contains('images (9).jpeg'));
    expect(full.data, contains('\n'));
    await tester.tap(find.text('إغلاق'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
