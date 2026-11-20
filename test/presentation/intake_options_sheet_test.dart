import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/intake_options.dart';
import 'package:scan_id/domain/manual_classification.dart';
import 'package:scan_id/presentation/side_partner_field.dart';
import 'editor_harness.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/presentation/intake_options_sheet.dart';

void main() {
  testWidgets(
    'one back can choose a saved front but a batch cannot share one partner',
    (tester) async {
      const kind = DocumentKind.unifiedNationalId;
      final base = editorProject(
        items: [placedDocument('front', 'asset1', kind)],
      );
      var ids = 0;
      final project = attachIntakeChoices(
        base,
        base.items,
        const IntakeOptions(kind: kind, side: SideKind.front),
        () => 'id${ids++}',
      );
      IntakeOptions? answer;
      for (final (count, selectedKind) in [
        (1, DocumentKind.unknown),
        (1, kind),
        (2, kind),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    answer = await showIntakeOptionsSheet(
                      context,
                      project: project,
                      imageCount: count,
                      initial: IntakeOptions(
                        kind: selectedKind,
                        side: SideKind.back,
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('intake-side-partner'));
        if (count == 1) {
          await tester.ensureVisible(field);
          await tester.tap(field);
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .textContaining(
                  manualPartnerLabel(project, project.items.first),
                )
                .last,
          );
          await tester.pumpAndSettle();
        } else {
          expect(field, findsNothing);
        }
        final confirm = find.byKey(const Key('intake-options-confirm'));
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(answer?.partnerChoice?.itemId, count == 1 ? 'front' : null);
      }
    },
  );
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
