import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/crop_screen.dart';
import 'package:scan_id/presentation/export_screen.dart';
import 'package:scan_id/presentation/layout_screen.dart';
import 'package:scan_id/presentation/ribbon.dart';

import 'editor_harness.dart';

/// Every command of the A4 editor's ribbon, exercised through the UI and
/// checked against what was saved.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('Word-style tabs; contextual tabs follow the selection', (
    tester,
  ) async {
    await EditorHarness.pump(tester);
    for (final tab in ['file', 'home', 'insert', 'layout', 'view']) {
      expect(find.byKey(Key('ribbon-tab-$tab')), findsOneWidget);
    }
    expect(find.byKey(const Key('ribbon-tab-document')), findsNothing);
    expect(find.byKey(const Key('ribbon-tab-picture')), findsNothing);
    expect(find.byKey(const Key('rb-arrange')), findsOneWidget);

    await tapKey(tester, const Key('page-item-card'));
    expect(find.byKey(const Key('ribbon-tab-document')), findsOneWidget);
    expect(find.byKey(const Key('ribbon-tab-picture')), findsOneWidget);

    await tapKey(tester, const Key('ribbon-tab-layout'));
    expect(find.byKey(const Key('rb-margins')), findsOneWidget);
    expect(find.byKey(const Key('rb-arrange')), findsNothing);

    await tapKey(tester, const Key('ribbon-collapse'));
    expect(find.byKey(const Key('rb-margins')), findsNothing);
    await tapKey(tester, const Key('ribbon-tab-home'));
    expect(find.byKey(const Key('rb-arrange')), findsOneWidget);

    // A document without a category opens its contextual tab by itself.
    await tapKey(tester, const Key('offsheet-unknown'));
    expect(find.byKey(const Key('rb-kind-menu')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ribbon-tab-document')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'kind gallery applies the catalog size at once and arranges by category',
    (tester) async {
      final editor = await EditorHarness.pump(tester);
      expect(
        editor.saved.items.firstWhere((e) => e.id == 'unknown').pageIndex,
        isNull,
      );

      await tapKey(tester, const Key('offsheet-unknown'));
      await tapKey(tester, const Key('ribbon-tab-home'));
      await tapKey(tester, const Key('rb-kind-residenceCard'));

      final saved = editor.saved;
      final residence = itemIn(saved, 'unknown');
      expect(residence.documentKind, DocumentKind.residenceCard);
      expect(residence.width, 92.4);
      expect(residence.height, 62.8);
      expect(residence.sizeConfirmed, isTrue);
      expect(residence.pageIndex, 0);
      // National card, then residence card, then passport, each on its row.
      expect(itemIn(saved, 'card').y, closeTo(5, 1e-6));
      expect(residence.y, closeTo(5 + 53.98 + 5, 1e-6));
      expect(
        itemIn(saved, 'passport').y,
        closeTo(5 + 53.98 + 5 + 62.8 + 5, 1e-6),
      );
      // The sheet shows the edit immediately.
      expect(find.byKey(const Key('page-slot-unknown')), findsOneWidget);
      expect(find.byKey(const Key('offsheet-unknown')), findsNothing);
    },
  );

  testWidgets('home: undo, redo, duplicate, delete and select all', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester);
    await tapKey(tester, const Key('page-item-card'));

    await tapKey(tester, const Key('rb-duplicate'));
    expect(editor.saved.items, hasLength(4));
    await tapKey(tester, const Key('rb-undo'));
    expect(editor.saved.items, hasLength(3));
    await tapKey(tester, const Key('rb-redo'));
    expect(editor.saved.items, hasLength(4));
    await tapKey(tester, const Key('qa-undo'));
    expect(editor.saved.items, hasLength(3));
    await tapKey(tester, const Key('qa-redo'));
    expect(editor.saved.items, hasLength(4));

    await tapKey(tester, const Key('rb-select-all'));
    await tapKey(tester, const Key('rb-delete'));
    expect(editor.saved.items, isEmpty);
    await tapKey(tester, const Key('rb-undo'));
    expect(editor.saved.items, hasLength(4));

    await tapKey(tester, const Key('page-item-card'));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(editor.saved.items.any((e) => e.id == 'card'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home: arrange now, continuous arrangement and strategy', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(
      tester,
      project: editorProject(
        items: [
          placedDocument(
            'passport',
            'asset2',
            DocumentKind.passport,
            x: 40,
            y: 5,
          ),
          placedDocument(
            'card',
            'asset1',
            DocumentKind.unifiedNationalId,
            y: 150,
          ),
        ],
      ),
    );
    await tapKey(tester, const Key('rb-arrange'));
    expect(itemIn(editor.saved, 'card').y, closeTo(5, 1e-6));
    expect(itemIn(editor.saved, 'passport').y, closeTo(5 + 53.98 + 5, 1e-6));
    expect(_button(tester, 'rb-autoflow').selected, isTrue);

    await tapKey(tester, const Key('rb-autoflow'));
    expect(_button(tester, 'rb-autoflow').selected, isFalse);
    await tapKey(tester, const Key('rb-autoflow'));
    expect(_button(tester, 'rb-autoflow').selected, isTrue);

    await _choose(tester, 'rb-strategy', 'مضغوط (أكبر عدد في الصفحة)');
    expect(editor.saved.layout.strategy, ArrangementStrategy.compact);
    await _choose(tester, 'rb-strategy', 'حسب النوع (صف لكل نوع)');
    expect(editor.saved.layout.strategy, ArrangementStrategy.ordered);
    expect(tester.takeException(), isNull);
  });

  testWidgets('insert: images, pages and extra copies', (tester) async {
    var picks = 0;
    final editor = await EditorHarness.pump(
      tester,
      pickImages: () async {
        picks++;
        return <ImportSource>[];
      },
    );
    await tapKey(tester, const Key('ribbon-tab-insert'));
    await tapKey(tester, const Key('rb-insert-images'));
    expect(picks, 1);
    await tapKey(tester, const Key('ribbon-tab-file'));
    await tapKey(tester, const Key('rb-import'));
    expect(picks, 2);

    await tapKey(tester, const Key('ribbon-tab-insert'));
    await tapKey(tester, const Key('rb-add-page'));
    expect(editor.saved.pageCount, 2);
    expect(find.text('الصفحة 2 من 2'), findsOneWidget);
    await tapKey(tester, const Key('rb-remove-empty-pages'));
    expect(editor.saved.pageCount, 1);

    await tapKey(tester, const Key('page-item-card'));
    await _choose(tester, 'rb-copies', '2');
    var cards = editor.saved.items.where((e) => e.assetId == 'asset1');
    expect(cards, hasLength(3));
    expect(cards.every((e) => e.pageIndex == 0), isTrue);

    await _choose(tester, 'rb-copies', 'عدد مخصص…');
    await tester.enterText(find.byKey(const Key('measure-عدد النسخ')), '2');
    await tapKey(tester, const Key('measure-save'));
    cards = editor.saved.items.where((e) => e.assetId == 'asset1');
    expect(cards, hasLength(5));
    expect(inspectLayout(editor.saved), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page layout: margins, orientation, gaps and options', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester);
    await tapKey(tester, const Key('ribbon-tab-layout'));

    await _choose(tester, 'rb-margins', 'ضيقة جداً · 3 مم');
    expect(editor.saved.paper.margins.isUniform, isTrue);
    expect(editor.saved.paper.margins.top, 3);
    // Continuous arrangement re-flows at once.
    expect(itemIn(editor.saved, 'card').y, closeTo(3, 1e-6));

    await _choose(tester, 'rb-margins', 'هوامش مخصصة…');
    await tester.enterText(find.byKey(const Key('measure-أعلى')), '12');
    await tapKey(tester, const Key('measure-save'));
    expect(editor.saved.paper.margins.top, 12);
    expect(editor.saved.paper.margins.right, 3);
    expect(itemIn(editor.saved, 'card').y, closeTo(12, 1e-6));

    await _choose(tester, 'rb-orientation', 'A4 أفقي');
    expect(editor.saved.paper.orientation, PaperOrientation.landscape);
    await _choose(tester, 'rb-orientation', 'A4 عمودي');
    expect(editor.saved.paper.orientation, PaperOrientation.portrait);

    await _enter(tester, const Key('rb-gap-h'), '7');
    expect(editor.saved.layout.horizontalGap, 7);
    await tapKey(tester, const Key('rb-gap-v-up'));
    expect(editor.saved.layout.verticalGap, 5.5);
    await tapKey(tester, const Key('rb-gap-v-down'));
    expect(editor.saved.layout.verticalGap, 5);

    await tapKey(tester, const Key('rb-rotation'));
    expect(editor.saved.layout.allowRotation, isTrue);
    await tapKey(tester, const Key('rb-largest-first'));
    expect(editor.saved.layout.order, LayoutOrder.area);
    await tapKey(tester, const Key('rb-overlap'));
    expect(_button(tester, 'rb-overlap').selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sizes dialog shows official sizes and edits residence and ration sizes live',
    (tester) async {
      final editor = await EditorHarness.pump(
        tester,
        project: editorProject(
          items: [
            placedDocument('residence', 'asset3', DocumentKind.residenceCard),
            placedDocument(
              'ration',
              'asset4',
              DocumentKind.rationCard,
              portrait: true,
            ),
          ],
        ),
      );
      await tapKey(tester, const Key('ribbon-tab-layout'));
      await tapKey(tester, const Key('rb-catalog'));
      expect(find.textContaining('ISO/IEC 7810 ID-1'), findsOneWidget);
      expect(find.textContaining('ICAO 9303 TD3'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('catalog-residence-w')),
        '90',
      );
      await tester.enterText(
        find.byKey(const Key('catalog-residence-h')),
        '60',
      );
      await tester.enterText(find.byKey(const Key('catalog-ration-w')), '٥٠');
      await tapKey(tester, const Key('catalog-save'));

      var saved = editor.saved;
      expect(saved.catalog.residenceCard.width, 90);
      expect(saved.catalog.residenceCard.height, 60);
      expect(saved.catalog.rationCard.width, 50);
      expect(itemIn(saved, 'residence').width, 90);
      expect(itemIn(saved, 'residence').height, 60);
      expect(itemIn(saved, 'ration').width, 50);
      expect(itemIn(saved, 'ration').height, 287);

      await tapKey(tester, const Key('rb-catalog'));
      await tapKey(tester, const Key('catalog-defaults'));
      await tapKey(tester, const Key('catalog-save'));
      saved = editor.saved;
      expect(saved.catalog.residenceCard.width, 92.4);
      expect(itemIn(saved, 'residence').height, 62.8);
      expect(itemIn(saved, 'ration').width, 52);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'document tab: kind menu, size fields, aspect lock, standard size',
    (tester) async {
      final editor = await EditorHarness.pump(tester);
      await tapKey(tester, const Key('page-item-card'));
      await tapKey(tester, const Key('ribbon-tab-document'));

      await _choose(tester, 'rb-kind-menu', DocumentKind.passport.label);
      var card = itemIn(editor.saved, 'card');
      expect(card.documentKind, DocumentKind.passport);
      expect([card.width, card.height], [125, 88]);

      await _enter(tester, const Key('rb-width'), '100');
      card = itemIn(editor.saved, 'card');
      expect(card.width, 100);
      expect(card.height, closeTo(100 * 88 / 125, 1e-9));
      // The page shows the new size right away.
      final scale = pageScale(tester);
      expect(
        tester.getSize(find.byKey(const Key('page-item-card'))).width,
        closeTo(100 * scale, .01),
      );

      await tapKey(tester, const Key('rb-aspect-lock'));
      expect(itemIn(editor.saved, 'card').keepAspectRatio, isFalse);
      await _enter(tester, const Key('rb-height'), '50');
      card = itemIn(editor.saved, 'card');
      expect([card.width, card.height], [100, 50]);

      await tapKey(tester, const Key('rb-reset-size'));
      card = itemIn(editor.saved, 'card');
      expect([card.width, card.height], [125, 88]);
      expect(card.keepAspectRatio, isTrue);

      await tapKey(tester, const Key('rb-width-up'));
      card = itemIn(editor.saved, 'card');
      expect(card.width, 126);
      expect(card.height, closeTo(126 * 88 / 125, 1e-9));
      await tapKey(tester, const Key('rb-width-down'));
      expect(itemIn(editor.saved, 'card').width, 125);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('document tab: rotate, lock, stacking order and alignment', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(tester);
    await tapKey(tester, const Key('page-item-card'));
    await tapKey(tester, const Key('ribbon-tab-document'));

    await tapKey(tester, const Key('rb-rotate-sheet'));
    expect(itemIn(editor.saved, 'card').rotation, 90);
    expect(inspectLayout(editor.saved), isEmpty);

    await tapKey(tester, const Key('rb-lock'));
    expect(itemIn(editor.saved, 'card').locked, isTrue);
    expect(_button(tester, 'rb-rotate-sheet').onPressed, isNull);
    await tapKey(tester, const Key('rb-lock'));
    expect(itemIn(editor.saved, 'card').locked, isFalse);

    await tapKey(tester, const Key('rb-forward'));
    expect(itemIn(editor.saved, 'card').zIndex, 1);
    await tapKey(tester, const Key('rb-backward'));
    expect(itemIn(editor.saved, 'card').zIndex, -1);

    await _choose(tester, 'rb-align', 'محاذاة لليسار');
    expect(itemIn(editor.saved, 'card').bounds.x, closeTo(5, 1e-6));
    // Positioning by hand ends continuous arrangement, like Word's
    // "fix position on page".
    await tapKey(tester, const Key('ribbon-tab-home'));
    expect(_button(tester, 'rb-autoflow').selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document tab: distribute spaces three documents evenly', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(
      tester,
      project: editorProject(
        items: [
          placedDocument(
            'a',
            'asset1',
            DocumentKind.other,
            x: 5,
            y: 150,
            w: 30,
            h: 20,
          ),
          placedDocument(
            'b',
            'asset2',
            DocumentKind.other,
            x: 40,
            y: 150,
            w: 30,
            h: 20,
          ),
          placedDocument(
            'c',
            'asset3',
            DocumentKind.other,
            x: 150,
            y: 150,
            w: 30,
            h: 20,
          ),
        ],
      ),
    );
    await tapKey(tester, const Key('rb-select-all'));
    await tapKey(tester, const Key('ribbon-tab-document'));
    await tapKey(tester, const Key('rb-distribute-h'));
    expect(itemIn(editor.saved, 'a').x, closeTo(5, 1e-9));
    expect(itemIn(editor.saved, 'b').x, closeTo(77.5, 1e-9));
    expect(itemIn(editor.saved, 'c').x, closeTo(150, 1e-9));

    // Not enough room vertically: the command explains and changes nothing.
    final before = editor.saved;
    await tapKey(tester, const Key('rb-distribute-v'));
    expect(find.byKey(const Key('editor-error')), findsOneWidget);
    expect(editor.saved.revision, before.revision);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'picture tab: corrections show live on the document and are saved after a pause',
    (tester) async {
      final images = FakeImageEditor();
      final editor = await EditorHarness.pump(tester, imageEditor: images);
      await tapKey(tester, const Key('page-item-card'));
      await tapKey(tester, const Key('ribbon-tab-picture'));
      expect(_button(tester, 'rb-reset-adjust').onPressed, isNull);

      final slider = find.byKey(const Key('rb-brightness'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(-40, 0));
      await tester.pump();
      await tester.pump();
      // Visible immediately, before anything is written.
      expect(find.byKey(const ValueKey('live-preview')), findsOneWidget);
      final filter = tester.widget<ColorFiltered>(
        find.byKey(const ValueKey('live-preview')),
      );
      expect(filter.colorFilter, isNot(ColorFilter.matrix(_identity)));
      expect(assetIn(editor.saved, 'asset1').adjustments.brightness, 0);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final brightness = assetIn(editor.saved, 'asset1').adjustments.brightness;
      expect(brightness, isNot(0));
      expect(images.revisions, 1);

      for (final key in ['rb-contrast', 'rb-saturation', 'rb-sharpness']) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        await tester.drag(find.byKey(Key(key)), const Offset(30, 0));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      }
      final adjusted = assetIn(editor.saved, 'asset1').adjustments;
      expect(adjusted.contrast, isNot(1));
      expect(adjusted.saturation, isNot(1));
      expect(adjusted.sharpness, isNot(0));

      await tapKey(tester, const Key('rb-reset-adjust'));
      final reset = assetIn(editor.saved, 'asset1').adjustments;
      expect(reset.hasColorChange, isFalse);
      expect(reset.sharpness, 0);

      await tapKey(tester, const Key('rb-rotate-image'));
      expect(assetIn(editor.saved, 'asset1').adjustments.quarterTurns, 1);
      final turned = itemIn(editor.saved, 'card');
      expect([turned.width, turned.height], [53.98, 85.6]);

      // Auto adjust analyses the picture on a real isolate and shows an
      // indeterminate progress bar meanwhile, so the test follows the
      // business state (busy, revision saved, idle) instead of waiting for
      // animations that are meant to run until the work is done.
      final revisions = images.revisions;
      final beforeAuto = assetIn(editor.saved, 'asset1');
      final autoAdjust = find.byKey(const Key('rb-auto-adjust'));
      String saveState() =>
          tester.widget<Text>(find.byKey(const Key('status-saved'))).data!;
      await tester.ensureVisible(autoAdjust);
      await tester.pumpAndSettle();
      await tester.tap(autoAdjust);
      await tester.pump();
      // Started: the editor is busy and says so.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(saveState(), 'جارٍ الحفظ…');

      // Finished: the isolate answered, the revision is saved and the editor
      // is idle again. Real time is needed for the isolate; the loop is
      // bounded and ends as soon as that state is reached.
      bool finished() =>
          images.revisions > revisions &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty;
      for (var i = 0; i < 100 && !finished(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(finished(), isTrue, reason: 'auto adjust never completed');
      // Persisted: exactly one new picture revision, stored on the document.
      expect(images.revisions, revisions + 1);
      final revised = assetIn(editor.saved, 'asset1');
      expect(revised.workingPath, isNot(beforeAuto.workingPath));
      expect(revised.workingPath, endsWith('edited-${revisions + 1}.png'));
      // Final UI: no progress bar, saved state shown, command available again.
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(saveState(), 'محفوظ');
      expect(_button(tester, 'rb-auto-adjust').onPressed, isNotNull);

      await tapKey(tester, const Key('rb-crop'));
      expect(find.byType(CropScreen), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(CropScreen), findsNothing);
      expect(find.byKey(const Key('rb-crop')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('view tab and status bar: zoom, guides and page navigation', (
    tester,
  ) async {
    final editor = await EditorHarness.pump(
      tester,
      project: editorProject(pageCount: 2),
    );
    await tapKey(tester, const Key('ribbon-tab-view'));
    expect(_button(tester, 'rb-zoom-width').selected, isTrue);

    await tapKey(tester, const Key('rb-zoom-100'));
    expect(_zoom(tester), 1);
    expect(_button(tester, 'rb-zoom-100').selected, isTrue);
    await tapKey(tester, const Key('rb-zoom-in'));
    expect(_zoom(tester), 1.1);
    await tapKey(tester, const Key('rb-zoom-out'));
    expect(_zoom(tester), 1);
    await tapKey(tester, const Key('status-zoom-in'));
    expect(_zoom(tester), 1.1);
    await tapKey(tester, const Key('status-zoom-out'));
    expect(_zoom(tester), 1);

    await tapKey(tester, const Key('rb-zoom-page'));
    expect(_button(tester, 'rb-zoom-page').selected, isTrue);
    final whole = pageScale(tester);
    await tapKey(tester, const Key('rb-zoom-width'));
    expect(_button(tester, 'rb-zoom-width').selected, isTrue);
    expect(pageScale(tester), greaterThan(whole));

    expect(firstCanvas(tester).showGuides, isTrue);
    await tapKey(tester, const Key('rb-guides'));
    expect(firstCanvas(tester).showGuides, isFalse);
    expect(_button(tester, 'rb-guides').selected, isFalse);

    expect(find.text('الصفحة 1 من 2'), findsOneWidget);
    await tapKey(tester, const Key('status-page'));
    await tester.tap(find.text('الصفحة 2').last);
    await tester.pumpAndSettle();
    expect(find.text('الصفحة 2 من 2'), findsOneWidget);
    expect(editor.saved.pageCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file tab: print preview, shortcuts and closing the editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = MemoryProjects();
    final project = await repository.create(editorProject());
    final service = ProjectService(repository, NoAssets());
    Project? returned;
    await tester.pumpWidget(
      AppShell(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  returned = await Navigator.of(context).push<Project>(
                    MaterialPageRoute(
                      builder: (_) =>
                          LayoutScreen(project: project, service: service),
                    ),
                  );
                },
                child: const Text('فتح المحرر'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('فتح المحرر'));
    await tester.pumpAndSettle();

    await tapKey(tester, const Key('ribbon-tab-file'));
    // Without a picker the import command is disabled, not hidden.
    expect(_button(tester, 'rb-import').onPressed, isNull);

    await tapKey(tester, const Key('rb-export'));
    expect(find.byType(ExportScreen), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    await tapKey(tester, const Key('rb-shortcuts'));
    expect(find.text('اختصارات لوحة المفاتيح'), findsOneWidget);
    expect(find.text('Ctrl + Z'), findsOneWidget);
    await tester.tap(find.text('إغلاق'));
    await tester.pumpAndSettle();

    await tapKey(tester, const Key('rb-close'));
    expect(find.byType(LayoutScreen), findsNothing);
    expect(returned?.id, project.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dragging and arrow keys move a selected document in millimetres',
    (tester) async {
      final editor = await EditorHarness.pump(
        tester,
        project: editorProject(
          items: [
            placedDocument(
              'card',
              'asset1',
              DocumentKind.unifiedNationalId,
              x: 60,
            ),
            placedDocument(
              'passport',
              'asset2',
              DocumentKind.passport,
              x: 40,
              y: 150,
            ),
          ],
        ),
      );
      await tapKey(tester, const Key('page-item-card'));
      final scale = pageScale(tester);

      await tester.drag(
        find.byKey(const Key('page-item-card')),
        Offset(10 * scale, 0),
      );
      await tester.pumpAndSettle();
      expect(itemIn(editor.saved, 'card').x, closeTo(70, .05));
      expect(itemIn(editor.saved, 'card').y, closeTo(5, .05));
      expect(_button(tester, 'rb-autoflow').selected, isFalse);

      await tester.drag(
        find.byKey(const Key('resize-card')),
        Offset(10 * scale, 0),
      );
      await tester.pumpAndSettle();
      final resized = itemIn(editor.saved, 'card');
      expect(resized.width, closeTo(95.6, .05));
      expect(resized.height, closeTo(95.6 * 53.98 / 85.6, .05));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(itemIn(editor.saved, 'card').y, closeTo(6, .05));
      expect(tester.takeException(), isNull);
    },
  );
}

// ---------------------------------------------------------------------------
// Helpers

const _identity = <double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
];

RibbonButton _button(WidgetTester tester, String key) =>
    tester.widget<RibbonButton>(find.byKey(Key(key)));

double _zoom(WidgetTester tester) =>
    tester.widget<Slider>(find.byKey(const Key('status-zoom'))).value;

Future<void> _choose(WidgetTester tester, String menu, String entry) async {
  await tapKey(tester, Key(menu));
  await tester.tap(find.byKey(Key('menu-$entry')).last);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, Key field, String text) async {
  await tester.ensureVisible(find.byKey(field));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(field), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}
