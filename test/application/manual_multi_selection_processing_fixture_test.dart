import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/processing_record.dart';

void main() {
  test(
    'redacted multi-selection fixture preserves per-item size and placement reasons',
    () {
      final fixture = File(
        'test/fixtures/manual_multi_selection_review_report.json',
      );
      final report = ProcessingReport.fromJson(
        jsonDecode(fixture.readAsStringSync()),
      );

      expect(report.route.name, 'manualSelections');
      expect(report.documents, hasLength(2));
      expect(report.documents.map((document) => document.id), [
        'item-test-01',
        'item-test-02',
      ]);
      expect(report.documents.map((document) => document.layoutItemId), [
        'item-test-01',
        'item-test-02',
      ]);
      expect(report.documents.first.placed, isTrue);
      expect(report.documents.first.succeeded, isTrue);

      final second = report.documents.last;
      final size = second.stageOf(ProcessingStage.typeSideSize)!;
      final placement = second.stageOf(ProcessingStage.placement)!;
      expect(size.status, StageStatus.reviewRequired);
      expect(size.reason, contains('لا يتوفر مقاس موثق'));
      expect(size.results['sizeProvenance'], 'missing');
      expect(size.diagnostics, contains('user_measurement_missing'));
      expect(placement.status, StageStatus.reviewRequired);
      expect(placement.reason, contains('القياس غير مؤكّد'));
      expect(placement.results['placed'], isFalse);
      expect(placement.diagnostics, contains('placement_size_unconfirmed'));

      expect(report.documentsSaved, 2);
      expect(report.documentsAdded, 2);
      expect(report.documentsPlaced, 1);
      expect(report.documentsNotPlaced, 1);
      expect(report.documentsPlacementUnverified, 0);
      expect(report.documentsFailed, 0);
      expect(report.stagesReviewRequired, 3);
      expect(report.verdict, ProcessingVerdict.completedWithReview);

      final restored = ProcessingReport.fromJson(
        jsonDecode(jsonEncode(report.toJson())),
      );
      expect(restored.documents.last.id, 'item-test-02');
      expect(
        restored.documents.last.stageOf(ProcessingStage.typeSideSize)!.reason,
        size.reason,
      );
      expect(
        restored.documents.last.stageOf(ProcessingStage.placement)!.results,
        placement.results,
      );
    },
  );
}
