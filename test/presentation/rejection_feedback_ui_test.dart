/// Rejection feedback at the point of delivery.
///
/// `test/application/rejection_feedback_test` proves the report CARRIES the
/// tally. That is not the same as the user seeing it: before this change the
/// editor's own import command reported cropped / recognized / not-detected
/// counts only, so a photo imported from inside the A4 editor said nothing at
/// all about the regions the gates had refused — while the same import from the
/// project screen listed them as banner warnings. These tests cover the three
/// surfaces the feedback now has to survive:
///
/// - the editor's import command, through the real intake and the real
///   repositories (a stubbed segmenter only fixes the tally under test);
/// - the editor's reprocess command, same contract;
/// - the arrangement banner the project screen imports through, in Arabic RTL.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/editor_controller.dart';
import 'package:scan_id/presentation/intake.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

img.Image _canvas(int width, int height, img.ColorRgb8 background) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: background);
  return image;
}

void _rect(
  img.Image image,
  int x1,
  int y1,
  int x2,
  int y2,
  img.ColorRgb8 color,
) => img.fillRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: color);

Uint8List _png(img.Image image) => Uint8List.fromList(img.encodePng(image));

/// A mid-tone desk: recognition finds nothing to crop, so the only thing the
/// editor has to report is what was refused.
Uint8List get _blankDesk =>
    _png(_canvas(900, 1200, img.ColorRgb8(128, 122, 116)));

/// Two ID cards on a desk, measured to produce no refusal at all: the negative
/// control, so a clean import is not told about exclusions that never happened.
Uint8List get _twoCards {
  final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
  _rect(image, 150, 180, 800, 590, img.ColorRgb8(240, 238, 230));
  _rect(image, 200, 900, 851, 1311, img.ColorRgb8(232, 230, 222));
  return _png(image);
}

RejectedRegion _refused(RegionRejection rejection) => RejectedRegion(
  region: const [.1, .1, .2, .9],
  rejection: rejection,
  aspect: 12.0,
  areaFraction: .02,
  fill: 1.0,
  borderSides: rejection == RegionRejection.frameArtifact ? 2 : 0,
  cropWidth: 90,
  cropHeight: 900,
);

Future<SegmentationResult> Function(Uint8List) _stub(
  List<RejectedRegion> rejected,
) =>
    (bytes) async => SegmentationResult(
      candidates: const [],
      multi: false,
      rejected: List.unmodifiable(rejected),
    );

void main() {
  group('the editor\'s own commands report refusals', () {
    late Directory root;
    late LocalProjectRepository projects;
    late LocalAssetRepository assets;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('scan-rejection-ui-');
      projects = await LocalProjectRepository.open(root);
      assets = LocalAssetRepository(projects.files);
    });

    tearDown(() async {
      await projects.close();
      await root.delete(recursive: true);
    });

    ProjectService service({
      Future<SegmentationResult> Function(Uint8List)? segmenter,
    }) => ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      segmenter: segmenter,
    );

    /// Drives the real controller command and collects what it told the user.
    Future<List<String>> runImport(
      ProjectService s,
      Uint8List bytes, {
      String name = 'صورة.png',
    }) async {
      final project = await s.create('محرر الورقة');
      final controller = LayoutEditorController(
        project: project,
        service: s,
        pickImages: () async => [
          ImportSource(name, () => Stream<List<int>>.value(bytes)),
        ],
      );
      addTearDown(controller.dispose);
      final said = <String>[];
      controller.onMessage = said.add;
      await controller.importImages();
      expect(controller.error, isNull, reason: '${controller.error}');
      return said;
    }

    test('importing names the count, categories and way back', () async {
      final said = await runImport(
        service(
          segmenter: _stub([
            _refused(RegionRejection.frameArtifact),
            _refused(RegionRejection.implausibleAspect),
          ]),
        ),
        _blankDesk,
      );

      expect(said, hasLength(1), reason: '$said');
      final message = said.single;
      // The counts the editor always reported are still there.
      expect(message, contains('قُصّ'));
      expect(message, contains('تُعرّف على'));
      // And so is the refusal, with the categories the gates measured and the
      // promise that nothing was lost by it.
      expect(message, contains('استُبعدت 2 منطقة'));
      expect(
        message,
        contains(regionRejectionLabel(RegionRejection.frameArtifact)),
      );
      expect(
        message,
        contains(regionRejectionLabel(RegionRejection.implausibleAspect)),
      );
      expect(message, contains(rejectedRegionsRecoveryHint));
      // One aggregated line for two refusals, never one message each.
      expect('استُبعدت'.allMatches(message), hasLength(1));
    });

    test('a clean import does not invent a refusal', () async {
      final said = await runImport(
        service(segmenter: (bytes) async => segmentDocumentBytes(bytes)),
        _twoCards,
      );

      expect(said, hasLength(1), reason: '$said');
      expect(said.single, contains('قُصّ 2'));
      expect(said.single, isNot(contains('استُبعدت')));
      expect(said.single, isNot(contains('تجاهل التقسيم')));
    });

    test('reprocessing reports the same tally as importing did', () async {
      final s = service(
        segmenter: _stub([_refused(RegionRejection.unusableCrop)]),
      );
      final imported = await runImport(s, _blankDesk);
      expect(imported.single, contains('استُبعدت 1 منطقة'));

      final saved = (await s.projects.list()).single;
      final controller = LayoutEditorController(project: saved, service: s);
      addTearDown(controller.dispose);
      final said = <String>[];
      controller.onMessage = said.add;
      await controller.reprocessImages([
        for (final asset in saved.assets) asset.id,
      ]);

      expect(said, hasLength(1), reason: '$said');
      expect(said.single, contains('أُعيد التعرف'));
      expect(said.single, contains('استُبعدت 1 منطقة'));
      expect(
        said.single,
        contains(regionRejectionLabel(RegionRejection.unusableCrop)),
      );
    });
  });

  group('delivery to the user', () {
    testWidgets('the arrangement banner shows the tally, in RTL', (
      tester,
    ) async {
      const tally = {
        RegionRejection.frameArtifact: 1,
        RegionRejection.implausibleAspect: 2,
      };
      final report = AutomaticLayoutReport(
        project: projectFixture(),
        cropped: 2,
        notDetected: 1,
        recognized: 2,
        rejectedRegions: 3,
        rejectedByReason: tally,
        warnings: const ['تنبيه واحد'],
      );
      final summary = intakeSummaryText(report);

      // The counts lead, the refusal tally follows on its own line, and the
      // per-image warnings are still passed alongside it.
      expect(summary, contains('قُصّ تلقائياً: 2'));
      expect(summary, contains('خارج الورق: 0'));
      expect(summary, contains('\nاستُبعدت 3 منطقة'));
      expect(
        summary,
        contains(regionRejectionLabel(RegionRejection.implausibleAspect)),
      );

      await EditorHarness.pump(
        tester,
        intakeSummary: summary,
        intakeWarnings: report.warnings,
      );
      final banner = find.textContaining('استُبعدت 3 منطقة');
      expect(banner, findsOneWidget);
      expect(
        Directionality.of(tester.element(banner)),
        TextDirection.rtl,
        reason: 'the tally is Arabic and must render right-to-left',
      );
      // The warnings the banner already showed are not displaced by it.
      expect(find.textContaining('تنبيه واحد'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a summary with nothing refused adds no line', (tester) async {
      final report = AutomaticLayoutReport(
        project: projectFixture(),
        cropped: 2,
        notDetected: 0,
        recognized: 2,
        warnings: const [],
      );
      final summary = intakeSummaryText(report);
      expect(summary, isNot(contains('\n')));
      expect(summary, isNot(contains('استُبعدت')));

      await EditorHarness.pump(tester, intakeSummary: summary);
      expect(find.textContaining('قُصّ تلقائياً: 2'), findsOneWidget);
      expect(find.textContaining('استُبعدت'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a recognition command reaches the user as a SnackBar', (
      tester,
    ) async {
      // The delivery half of the reprocess command: the same `_say` that now
      // carries the refusal tally is what puts a message on screen at all.
      // With no image editor the command reports that recognition is off, so
      // this needs no files and no recognition run.
      //
      // Frames are pumped a bounded number of times rather than settled, and
      // the SnackBar is dismissed through its messenger. `showMessage` gives it
      // a six-second duration, and both a timer left running and an animation
      // that never settles are reported against the test AFTER its body has
      // already passed, which reaches the log only as "see exception logs
      // above" — unreadable through the annotation channel CI has. Bounded
      // pumps make neither possible.
      // TEMPORARY DIAGNOSTIC — remove once the cause is known. Whatever the
      // framework reports against this test, including anything it raises after
      // the body has finished, is captured here and republished as a failure
      // detail, because the exception block the reporter prints ABOVE the
      // failure marker is not part of the annotation channel CI exposes.
      final captured = <String>[];
      final previousHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        captured.add('${details.exception}');
        previousHandler?.call(details);
      };
      addTearDown(() {
        FlutterError.onError = previousHandler;
        expect(
          captured,
          isEmpty,
          reason: 'captured ${captured.length}: $captured',
        );
      });

      await EditorHarness.pump(tester);
      final button = find.byKey(const Key('rb-reprocess'));
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(button);
      // The command itself is a chain of microtasks, which the first pump
      // drains; the rest let the SnackBar's entrance run to completion.
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final snack = find.byType(SnackBar);
      expect(snack, findsOneWidget);
      expect(
        find.text('التعرف الذكي غير مفعّل في هذا البناء.'),
        findsOneWidget,
      );

      // Cancels the duration timer instead of waiting it out.
      ScaffoldMessenger.of(tester.element(snack)).clearSnackBars();
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(SnackBar), findsNothing);
      // Last, so it names anything the frames above recorded in the failure
      // detail rather than only in a log this sandbox cannot read.
      expect(tester.takeException(), isNull, reason: 'see the actual value');
    });
  });
}
