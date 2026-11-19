import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/intake_stage_log.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/domain/intake_options.dart';
import 'package:scan_id/domain/recognition.dart';

void main() {
  group('IntakeOptions defaults', () {
    test('an untouched batch asserts nothing', () {
      const options = IntakeOptions.defaults;
      // No side assertion: «بدون تحديد يُعتبر وجه واحد» is one side, and it is
      // NOT a claim that the side is the front.
      expect(options.side, SideKind.unknown);
      expect(options.assertsSide, isFalse);
      // No category assertion: the automatic recogniser decides.
      expect(options.kind, DocumentKind.unknown);
      expect(options.assertsKind, isFalse);
      // The suggested boundary is NOT auto-accepted without the person's say.
      expect(options.acceptSuggestedBoundary, isFalse);
      // Centring is the behaviour the app already had, so it stays on.
      expect(options.centerDocuments, isTrue);
      // Multi-document detection is off and unavailable in this build.
      expect(options.multiDocument, isFalse);
      expect(IntakeOptions.multiDocumentAvailable, isFalse);
      expect(options.hasConfirmations, isFalse);
    });

    test('asking for multi-document detection reports it cannot run', () {
      final options = IntakeOptions.defaults.copyWith(multiDocument: true);
      expect(options.multiDocument, isTrue);
      expect(options.multiDocumentRuns, isFalse);
      expect(options.multiDocumentRequestedButUnavailable, isTrue);
    });
  });

  group('IntakeOptions confirmations', () {
    test('only a ticked option is recorded as confirmed', () {
      final options = IntakeOptions.defaults
          .withSide(SideKind.front)
          .withConfirmed(IntakeOptionKey.side);
      expect(options.confirmed, {IntakeOptionKey.side});
      // Setting a value is not the same as confirming it.
      expect(
        options.confirmed.contains(IntakeOptionKey.centerDocuments),
        isFalse,
      );
    });

    test('un-ticking removes the confirmation', () {
      final ticked = IntakeOptions.defaults.withConfirmed(
        IntakeOptionKey.acceptSuggestedBoundary,
      );
      final unticked = ticked.withConfirmed(
        IntakeOptionKey.acceptSuggestedBoundary,
        value: false,
      );
      expect(ticked.confirmed, contains(IntakeOptionKey.acceptSuggestedBoundary));
      expect(unticked.confirmed, isEmpty);
    });

    test('confirming does not mutate the receiver', () {
      const original = IntakeOptions.defaults;
      original.withConfirmed(IntakeOptionKey.kind);
      expect(original.confirmed, isEmpty);
    });
  });

  group('IntakeOptions trace', () {
    test('carries codes and enum names only, never free text', () {
      final options = IntakeOptions.defaults
          .withSide(SideKind.back)
          .withKind(DocumentKind.passport)
          .copyWith(multiDocument: true)
          .withConfirmed(IntakeOptionKey.kind);
      final codes = options.traceCodes.toList();
      expect(codes, contains('side=back'));
      expect(codes, contains('kind=passport'));
      expect(codes, contains('multiRequested=true'));
      expect(codes, contains('multiApplied=false'));
      expect(codes, contains('confirmed.kind=true'));
      // Every code is bounded and single-line: this is what keeps the log safe
      // to keep beside the project.
      for (final code in codes) {
        expect(code.contains('\n'), isFalse);
        expect(code.length, lessThan(120));
      }
    });
  });

  group('IntakeStageLog', () {
    test('records each stage once, in pipeline order', () {
      final log = IntakeStageLog(assetId: 'asset-1');
      log.pass(JourneyStage.copy, 'نُسخت إلى مساحة التطبيق.');
      log.pass(JourneyStage.selection, 'اختيرت.');
      expect(log.records.map((r) => r.stage), [
        JourneyStage.selection,
        JourneyStage.copy,
      ]);
    });

    test('a failing stage is reported with its cause', () {
      final log = IntakeStageLog(assetId: 'asset-1');
      log.block(
        JourneyStage.detection,
        'تعذّر فحص التقسيم متعدد المستمسكات: صورة غير صالحة',
        fields: {'errorType': 'FormatException'},
      );
      expect(log.hasFailure, isTrue);
      expect(
        log.failureReason(JourneyStage.detection),
        contains('تعذّر فحص التقسيم'),
      );
      expect(
        log.failureSummary,
        contains('تعذّر فحص التقسيم متعدد المستمسكات'),
      );
    });

    test('stages that never ran are reported as not run, never as passed', () {
      final log = IntakeStageLog(assetId: 'asset-1');
      log.block(JourneyStage.detection, 'لا حدود.');
      final steps = log.toSteps();
      // One step per stage: a missing row would read as an omission.
      expect(steps, hasLength(JourneyStage.values.length));
      final detection = steps.firstWhere(
        (s) => s.stage == JourneyStage.detection,
      );
      expect(detection.outcome, JourneyOutcome.blocked);
      // Every later stage names the stage that stopped the chain.
      for (final step in steps) {
        if (step.stage.index <= JourneyStage.detection.index) continue;
        expect(step.outcome, JourneyOutcome.skipped);
        expect(step.detail, contains('كشف الحدود'));
      }
    });

    test('a stage recorded twice keeps its final outcome', () {
      final log = IntakeStageLog(assetId: 'asset-1');
      log.block(JourneyStage.detection, 'فشل أول.');
      log.pass(JourneyStage.detection, 'نجح في المحاولة الثانية.');
      expect(log.hasFailure, isFalse);
      expect(log.records.where((r) => r.stage == JourneyStage.detection), hasLength(1));
    });

    test('fields too long for the journal are clipped, not rejected', () {
      final log = IntakeStageLog(assetId: 'asset-1');
      log.pass(
        JourneyStage.detection,
        'قيست منطقة واحدة.',
        fields: {'note': 'x' * 400},
      );
      final step = log.toSteps().firstWhere(
        (s) => s.stage == JourneyStage.detection,
      );
      expect(
        (step.fields['note']! as String).length,
        JourneyStep.maxFieldValueLength,
      );
    });
  });

  group('IntakeBatchLog', () {
    test('a batch failure is attributed to every image already logged', () {
      final batch = IntakeBatchLog(batchId: 'batch-1');
      batch.forAsset('a1', name: 'one');
      batch.forAsset('a2', name: 'two');
      batch.failBatch(JourneyStage.placement, 'تعذّر الترتيب.');
      for (final log in batch.logs) {
        expect(log.hasFailure, isTrue);
        expect(log.failureReason(JourneyStage.placement), 'تعذّر الترتيب.');
      }
      expect(batch.summary, contains('2'));
    });

    test('a clean batch says so', () {
      final batch = IntakeBatchLog(batchId: 'batch-1');
      final log = batch.forAsset('a1');
      log.pass(JourneyStage.copy, 'نُسخت.');
      expect(batch.failed, isEmpty);
      expect(batch.summary, contains('بلا فشل'));
    });

    test('carries the options it was given', () {
      final options = IntakeOptions.defaults.withSide(SideKind.front);
      final batch = IntakeBatchLog(batchId: 'batch-1', options: options);
      expect(batch.options?.side, SideKind.front);
    });
  });
}
