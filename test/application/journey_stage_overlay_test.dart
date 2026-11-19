import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/image_journey_report.dart';
import 'package:scan_id/application/intake_stage_log.dart';
import 'package:scan_id/domain/image_journey.dart';

/// The filed journey is built from the committed project, and then reconciled
/// with the stages the pipeline recorded while it ran.
///
/// The rule these tests pin: a failure recorded by a stage must reach the
/// person reading the log, and a failure the project itself shows must not be
/// erased by a stage that claimed success. Getting either direction wrong makes
/// the log confidently wrong, which is worse than silent.
void main() {
  IntakeBatchLog batch() => IntakeBatchLog(batchId: 'batch-0001');

  test('a recorded failure is preserved even when the project derives a pass', () {
    final log = batch();
    log
        .forAsset('asset-1')
        .block(
          JourneyStage.detection,
          'تعذّر فحص التقسيم متعدد المستمسكات: صورة غير صالحة',
        );

    // The project side has nothing to reason about, so every derived step is a
    // placeholder. The recorded block must survive the merge.
    final steps = overlayStageLogForTest(
      [
        JourneyStep(
          stage: JourneyStage.detection,
          outcome: JourneyOutcome.passed,
          detail: 'قِيست منطقة واحدة.',
        ),
      ],
      log,
      'asset-1',
    );
    expect(steps.first.outcome, JourneyOutcome.blocked);
    expect(steps.first.detail, contains('تعذّر فحص التقسيم'));
  });

  test('a recorded pass does not erase a failure the project shows', () {
    final log = batch();
    log.forAsset('asset-1').pass(JourneyStage.placement, 'أُضيفت إلى الورقة.');

    final steps = overlayStageLogForTest(
      [
        JourneyStep(
          stage: JourneyStage.placement,
          outcome: JourneyOutcome.blocked,
          detail: 'لم يدخل الورقة.',
        ),
      ],
      log,
      'asset-1',
    );
    expect(steps.single.outcome, JourneyOutcome.blocked);
    expect(steps.single.detail, 'لم يدخل الورقة.');
  });

  test('stages only the record knows about are added, in pipeline order', () {
    final log = batch();
    // A batch-wide arrangement failure lands on every image.
    log.forAsset('asset-1').pass(JourneyStage.copy, 'نُسخت.');
    log.failBatch(JourneyStage.placement, 'تعذّر ترتيب المستمسكات على الورقة.');

    final steps = overlayStageLogForTest(
      [
        JourneyStep(
          stage: JourneyStage.copy,
          outcome: JourneyOutcome.passed,
          detail: 'نُسخت.',
        ),
      ],
      log,
      'asset-1',
    );
    final stages = steps.map((step) => step.stage).toList();
    // Ordered, and the batch failure is present rather than dropped.
    for (var i = 1; i < stages.length; i++) {
      expect(stages[i].index >= stages[i - 1].index, isTrue);
    }
    expect(stages, contains(JourneyStage.placement));
    final placement = steps.firstWhere(
      (step) => step.stage == JourneyStage.placement,
    );
    expect(placement.outcome, JourneyOutcome.blocked);
  });

  test('another image\'s record never leaks into this journey', () {
    final log = batch();
    log.forAsset('asset-2').block(JourneyStage.detection, 'فشل صورة أخرى.');

    final derived = [
      JourneyStep(
        stage: JourneyStage.detection,
        outcome: JourneyOutcome.passed,
        detail: 'قِيست منطقة واحدة.',
      ),
    ];
    final steps = overlayStageLogForTest(derived, log, 'asset-1');
    expect(steps.single.outcome, JourneyOutcome.passed);
    expect(steps.single.detail, 'قِيست منطقة واحدة.');
  });

  test("a stage the log never recorded keeps the project's verdict", () {
    final log = batch();
    // Only the copy stage was recorded. `toSteps` fills the rest as `skipped`,
    // which means «this log kept no record», NOT «the stage did not run».
    log.forAsset('asset-1').pass(JourneyStage.copy, 'نُسخت إلى مساحة التطبيق.');

    final derived = [
      JourneyStep(
        stage: JourneyStage.copy,
        outcome: JourneyOutcome.passed,
        detail: 'نُسخت إلى مساحة التطبيق.',
      ),
      JourneyStep(
        stage: JourneyStage.placement,
        outcome: JourneyOutcome.passed,
        detail: 'وُضعت على الورقة.',
      ),
    ];
    final steps = overlayStageLogForTest(derived, log, 'asset-1');
    final placement = steps.firstWhere(
      (step) => step.stage == JourneyStage.placement,
    );
    // The project shows the item on the page; a placeholder must not deny it.
    expect(placement.outcome, JourneyOutcome.passed);
    expect(placement.detail, 'وُضعت على الورقة.');
  });

  test('no stage log leaves the derived journey exactly as it was', () {
    final derived = [
      JourneyStep(
        stage: JourneyStage.selection,
        outcome: JourneyOutcome.passed,
        detail: 'اختيرت.',
      ),
    ];
    final steps = overlayStageLogForTest(derived, null, 'asset-1');
    expect(steps, same(derived));
  });
}
