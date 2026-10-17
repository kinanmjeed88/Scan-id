import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';

import 'editor_harness.dart';

/// The editor names the reason for every document that automatic
/// arrangement leaves out (AutoLayoutStatus), in the off-sheet tray, in the
/// status bar and in the message after arranging. A document without a
/// confirmed size is "not eligible for automatic arrangement", a state of the
/// document, not just a place off the sheet.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'the tray and status bar say why each document is out of the arrangement',
    (tester) async {
      final editor = await EditorHarness.pump(
        tester,
        project: _mixed(),
        size: const Size(2200, 900),
      );

      expect(_reason(tester, 'unknown'), 'sizeUnconfirmed');
      expect(_reason(tester, 'huge'), 'tooLarge');
      // A copy that only lacked room fits on a page: it is not "too large".
      expect(_reason(tester, 'copy'), 'eligible');
      expect(_reason(tester, 'pair-a'), 'groupNeedsSpace');
      expect(
        autoLayoutStatus(editor.saved, itemIn(editor.saved, 'pair-b')),
        AutoLayoutStatus.groupNeedsSpace,
      );
      final pairTooltip = tester.widget<Tooltip>(
        find.descendant(
          of: find.byKey(const Key('offsheet-pair-a')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(pairTooltip.message, contains('لا تُقسَّم المجموعة'));
      expect(_reason(tester, 'locked'), 'locked');
      const lockedText = 'مثبت · خارج الترتيب التلقائي';
      expect(find.text(lockedText), findsOneWidget);
      final lockedTooltip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.text(lockedText),
          matching: find.byType(Tooltip),
        ),
      );
      expect(lockedTooltip.message, contains('أزل القفل'));
      // Counted by state, wherever the document is: the off-sheet unknown
      // one and the placed one without a confirmed size. Only the 250 mm
      // document is too large; the copy that merely lacked room is not.
      expect(find.text('2 بانتظار تحديد النوع'), findsOneWidget);
      expect(find.text('1 لا يتسع للورقة'), findsOneWidget);

      await tapKey(tester, const Key('rb-arrange'));

      // The placed document whose size was never confirmed leaves the page
      // with its reason; the ready copy is placed; nothing is scaled.
      final saved = editor.saved;
      expect(itemIn(saved, 'legacy').pageIndex, isNull);
      expect(itemIn(saved, 'copy').pageIndex, isNotNull);
      expect(itemIn(saved, 'huge').pageIndex, isNull);
      expect(itemIn(saved, 'huge').width, 250);
      expect(itemIn(saved, 'pair-a').pageIndex, isNull);
      expect(itemIn(saved, 'pair-b').pageIndex, isNull);
      expect(
        find.textContaining(
          'مستمسك بقي خارج الورقة؛ لم يُصغّر أو يُقص أي مستمسك',
        ),
        findsOneWidget,
      );
      expect(_reason(tester, 'legacy'), 'sizeUnconfirmed');
      expect(find.byKey(const Key('offsheet-copy')), findsNothing);
      expect(
        find.textContaining('1 أُبعد عن الورقة لأن مقاسه غير مؤكد'),
        findsOneWidget,
      );
      expect(find.text('2 بانتظار تحديد النوع'), findsOneWidget);
      expect(find.text('1 لا يتسع للورقة'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

/// A placed card, plus one document of each off-sheet kind and one placed
/// document whose size was never confirmed (as older data can contain).
Project _mixed() => editorProject(
  layoutGroups: [
    LayoutGroup(id: 'blocked-pair', itemIds: ['pair-a', 'pair-b']),
  ],
  items: [
    placedDocument('card', 'asset1', DocumentKind.unifiedNationalId),
    DocumentItem(
      id: 'unknown',
      assetId: 'asset2',
      x: 0,
      y: 0,
      width: 60,
      height: 40,
      pageIndex: null,
    ),
    placedDocument(
      'huge',
      'asset3',
      DocumentKind.other,
      w: 250,
      h: 250,
    ).copyWith(unplaced: true),
    placedDocument(
      'copy',
      'asset1',
      DocumentKind.unifiedNationalId,
    ).copyWith(unplaced: true),
    for (final id in ['pair-a', 'pair-b'])
      DocumentItem(
        id: id,
        assetId: 'asset2',
        x: 0,
        y: 0,
        width: 160,
        height: 160,
        pageIndex: null,
        documentKind: DocumentKind.other,
        sizeConfirmed: true,
        groupId: 'blocked-pair',
      ),
    DocumentItem(
      id: 'legacy',
      assetId: 'asset4',
      x: 5,
      y: 150,
      width: 70,
      height: 45,
    ),
    placedDocument(
      'locked',
      'asset4',
      DocumentKind.unifiedNationalId,
    ).copyWith(unplaced: true, locked: true),
  ],
);

/// The AutoLayoutStatus name shown on [id]'s off-sheet tile.
String _reason(WidgetTester tester, String id) {
  final label = tester.widget<Text>(
    find.descendant(
      of: find.byKey(Key('offsheet-$id')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('offsheet-status-'),
      ),
    ),
  );
  return (label.key! as ValueKey<String>).value.substring(
    'offsheet-status-'.length,
  );
}
