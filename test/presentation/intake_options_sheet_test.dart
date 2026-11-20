import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/intake_options.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/presentation/intake_options_sheet.dart';

void main() {
  testWidgets(
    'small phone: one side row, two kind rows, one copy of each switch',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      IntakeOptions? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  answer = await showIntakeOptionsSheet(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tap(find.text('open'));
      final chips = find.byType(ChoiceChip);
      expect(chips, findsNWidgets(3 + DocumentKind.values.length));
      final heights = [
        for (var i = 0; i < chips.evaluate().length; i++)
          tester.getCenter(chips.at(i)).dy,
      ];
      expect(heights.take(3).toSet(), hasLength(1));
      expect(heights.skip(3).toSet(), hasLength(2));
      expect(find.byType(Switch), findsNWidgets(3));
      await tap(find.text('وجه ثانٍ'));
      await tap(find.text(DocumentKind.passport.label));
      await tap(find.byType(Switch).first);
      await tap(find.byType(Switch).at(1));
      await tap(find.byType(Switch).last);
      expect(
        tester.widget<Switch>(find.byType(Switch).first).onChanged,
        isNull,
      );
      await tap(find.byKey(const Key('intake-options-confirm')));
      expect(answer?.route, IntakeRoute.manualSelections);
      expect(answer?.side, SideKind.back);
      expect(answer?.kind, DocumentKind.passport);
      expect(answer?.centerDocuments, isFalse);
      expect(answer?.confirmed, IntakeOptionKey.values.toSet());
      expect(tester.takeException(), isNull);
      await tap(find.text('open'));
      await tap(find.text('وجه أول'));
      await tap(find.text('إعادة الافتراضي'));
      await tap(find.byKey(const Key('intake-options-confirm')));
      expect(answer, same(IntakeOptions.defaults));
      await tap(find.text('open'));
      await tap(find.text('إلغاء'));
      expect(answer, isNull);
    },
  );
}
