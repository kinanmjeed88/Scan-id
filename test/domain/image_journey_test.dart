import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/domain/validation.dart';

JourneyStep step(
  JourneyStage stage,
  JourneyOutcome outcome, {
  String detail = 'تفصيل المرحلة.',
  int? durationMs,
}) => JourneyStep(
  stage: stage,
  outcome: outcome,
  detail: detail,
  durationMs: durationMs,
);

ImageJourney journey({
  String id = 'batch0001:asset0001',
  List<JourneyStep>? steps,
}) => ImageJourney(
  id: id,
  batchId: 'batch0001',
  projectId: 'project1',
  projectName: 'مستمسكات العائلة',
  imageName: 'بطاقة.png',
  startedAt: DateTime.utc(2026, 11, 9, 8, 30),
  steps:
      steps ??
      [
        step(JourneyStage.selection, JourneyOutcome.passed),
        step(JourneyStage.copy, JourneyOutcome.passed, durationMs: 240),
        step(JourneyStage.placement, JourneyOutcome.passed),
        step(JourneyStage.save, JourneyOutcome.passed),
      ],
);

void main() {
  group('image journey model', () {
    test('round-trips through JSON without losing a stage', () {
      final original = journey();
      final decoded = ImageJourney.fromJson(original.toJson());
      expect(decoded.id, original.id);
      expect(decoded.batchId, original.batchId);
      expect(decoded.projectId, original.projectId);
      expect(decoded.projectName, original.projectName);
      expect(decoded.imageName, original.imageName);
      expect(decoded.startedAt, original.startedAt);
      expect(decoded.steps, hasLength(original.steps.length));
      for (var index = 0; index < original.steps.length; index++) {
        expect(decoded.steps[index].stage, original.steps[index].stage);
        expect(decoded.steps[index].outcome, original.steps[index].outcome);
        expect(decoded.steps[index].detail, original.steps[index].detail);
        expect(
          decoded.steps[index].durationMs,
          original.steps[index].durationMs,
        );
      }
    });

    test('a report keeps its stages in pipeline order', () {
      expect(
        () => journey(
          steps: [
            step(JourneyStage.copy, JourneyOutcome.passed),
            step(JourneyStage.selection, JourneyOutcome.passed),
          ],
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('steps must be present and are read-only', () {
      expect(
        () => journey(steps: const []),
        throwsA(isA<ValidationException>()),
      );
      final report = journey();
      expect(
        () => report.steps.add(
          step(JourneyStage.save, JourneyOutcome.passed),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('a detail is one bounded sentence, never a transcript', () {
      expect(
        () => step(
          JourneyStage.copy,
          JourneyOutcome.passed,
          detail: 'سطر أول\nسطر ثانٍ',
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => step(
          JourneyStage.copy,
          JourneyOutcome.passed,
          detail: 'ط' * (JourneyStep.maxDetailLength + 1),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('an unmeasured duration is unknown, never a fabricated zero', () {
      final unmeasured = step(JourneyStage.copy, JourneyOutcome.passed);
      expect(unmeasured.durationMs, isNull);
      expect(unmeasured.toJson().containsKey('duration_ms'), isFalse);
      expect(
        () => step(
          JourneyStage.copy,
          JourneyOutcome.passed,
          durationMs: -1,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('an unknown stage, outcome or version is refused', () {
      final json = journey().toJson();
      final unknownStage = {
        ...json,
        'steps': [
          {'stage': 'teleport', 'outcome': 'passed', 'detail': 'x'},
        ],
      };
      expect(
        () => ImageJourney.fromJson(unknownStage),
        throwsA(isA<ValidationException>()),
      );
      final unknownOutcome = {
        ...json,
        'steps': [
          {'stage': 'copy', 'outcome': 'maybe', 'detail': 'x'},
        ],
      };
      expect(
        () => ImageJourney.fromJson(unknownOutcome),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ImageJourney.fromJson({...json, 'version': 99}),
        throwsA(isA<ValidationException>()),
      );
    });

    test('conclusion follows the recorded stages, not the header', () {
      final placed = journey();
      expect(placed.placedOnSheet, isTrue);
      expect(placed.conclusion, 'أُضيفت إلى الورقة');
      expect(placed.verdict, JourneyOutcome.passed);
      expect(placed.firstConcern, isNull);

      final refusedImport = journey(
        steps: [
          step(JourneyStage.selection, JourneyOutcome.passed),
          step(JourneyStage.copy, JourneyOutcome.blocked),
          step(JourneyStage.placement, JourneyOutcome.blocked),
        ],
      );
      expect(refusedImport.imported, isFalse);
      expect(refusedImport.conclusion, 'لم تُستورد');
      expect(refusedImport.verdict, JourneyOutcome.blocked);
      expect(refusedImport.firstConcern?.stage, JourneyStage.copy);

      final waitingForReview = journey(
        steps: [
          step(JourneyStage.selection, JourneyOutcome.passed),
          step(JourneyStage.copy, JourneyOutcome.passed),
          step(JourneyStage.placement, JourneyOutcome.review),
        ],
      );
      expect(waitingForReview.conclusion, 'بقيت للمراجعة اليدوية');
      expect(waitingForReview.verdict, JourneyOutcome.review);
      expect(waitingForReview.firstConcern?.stage, JourneyStage.placement);

      final outsideSheet = journey(
        steps: [
          step(JourneyStage.selection, JourneyOutcome.passed),
          step(JourneyStage.copy, JourneyOutcome.passed),
          step(JourneyStage.placement, JourneyOutcome.blocked),
        ],
      );
      expect(outsideSheet.conclusion, 'بقيت خارج الورقة');
    });

    test('a placed image with a reviewed earlier stage is not reported as '
        'fully clean', () {
      final reviewed = journey(
        steps: [
          step(JourneyStage.selection, JourneyOutcome.passed),
          step(JourneyStage.copy, JourneyOutcome.passed),
          step(JourneyStage.detection, JourneyOutcome.review),
          step(JourneyStage.placement, JourneyOutcome.passed),
        ],
      );
      expect(reviewed.placedOnSheet, isTrue);
      expect(reviewed.verdict, JourneyOutcome.review);
      expect(reviewed.firstConcern?.stage, JourneyStage.detection);
    });

    test('a missing stage reads as «not reached», never as success', () {
      final missing = journey(
        steps: [step(JourneyStage.selection, JourneyOutcome.passed)],
      );
      expect(missing.imported, isFalse);
      expect(missing.placedOnSheet, isFalse);
      expect(missing.verdict, JourneyOutcome.blocked);
    });
  });
}
