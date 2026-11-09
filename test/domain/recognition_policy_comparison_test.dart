import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/acceptance_policy.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_classifier.dart';
import 'package:scan_id/domain/recognition_routing.dart';

// Policy tests with injected scores, NOT a labelled image/model benchmark.
void main() {
  final quad = [Point2(.1, .1), Point2(.9, .1), Point2(.9, .9), Point2(.1, .9)];
  final comparison = <Map<String, Object>>[];
  for (final threshold in [.55, .60, .70]) {
    test('independent policy comparison at $threshold', () {
      final thresholds = RecognitionThresholds(
        review: threshold,
        minClassification: threshold,
        classificationAcceptance: threshold,
      );
      var types = 0;
      var crops = 0;
      for (final score in [.54, .55, .59, .60, .69, .70, .90]) {
        final ocr = OcrTextResult.available(
          engineVersion: 'injected-policy-test',
          lines: [
            OcrLine(
              text: 'البطاقة الوطنية الموحدة الرقم الوطني',
              confidence: score,
            ),
          ],
        );
        final outcome = classifyDocument(
          ClassificationInput(
            ocrKeywords: ocrKeywordEvidence(ocr),
            ocrConfidence: ocr.confidence,
            thresholds: thresholds,
            // A weak boundary must not invalidate a readable type.
            detectionConfidence: .1,
            geometryConfidence: .1,
          ),
        );
        final expected = score >= threshold;
        expect(outcome.status == RecognitionStatus.recognized, expected);
        expect(outcome.confidences.ocr?.value, score);
        expect(
          outcome.confidences.classification?.value,
          closeTo(score, 1e-12),
        );
        expect(
          qualifiesForAutomaticPlacement(outcome, thresholds: thresholds),
          expected,
        );
        if (outcome.status == RecognitionStatus.recognized) types++;

        BoundaryDecision decision({
          List<Point2>? corners,
          bool review = false,
        }) => verifyBoundary(
          BoundaryProposal(
            producer: BoundaryProducer.learnedModel,
            corners: corners ?? quad,
            modelConfidence: score,
            minAutoAcceptConfidence: threshold,
            forceReview: review,
            forceReviewReason: BoundaryReviewReason.modelDisagreement,
          ),
          sourceWidth: 1000,
          sourceHeight: 700,
          acceptanceThreshold: threshold,
        );
        expect(decision().cropAuthorization != null, expected);
        if (decision().cropAuthorization != null) crops++;
        expect(decision(review: true).cropAuthorization, isNull);
        expect(
          decision(
            corners: [quad[0], quad[2], quad[1], quad[3]],
          ).cropAuthorization,
          isNull,
        );
        expect(
          decision(
            corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
          ).cropAuthorization,
          isNull,
        );
        expect(
          decision(
            corners: [
              Point2(.49, .49),
              Point2(.51, .49),
              Point2(.51, .51),
              Point2(.49, .51),
            ],
          ).cropAuthorization,
          isNull,
        );
      }
      final expectedCount = threshold == .55
          ? 6
          : threshold == .60
          ? 4
          : 2;
      expect(types, expectedCount);
      expect(crops, expectedCount);
      comparison.add({
        'threshold': threshold,
        'acceptedTextCases': types,
        'acceptedValidQuadCases': crops,
        'population': 7,
        'dataset': 'injected-scores-not-field-accuracy',
      });
      Directory('diagnostics').createSync(recursive: true);
      File('diagnostics/recognition-policy-comparison.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(comparison),
      );
    });
  }

  test('invalid thresholds and scores fail closed', () {
    for (final threshold in [double.nan, double.infinity, 0.0, -1.0, 1.1]) {
      expect(meetsAcceptanceThreshold(.99, threshold), isFalse);
    }
    for (final score in [double.nan, double.infinity, -.1, 1.1]) {
      expect(meetsAcceptanceThreshold(score, .55), isFalse);
    }
    expect(meetsAcceptanceThreshold(null, .55), isFalse);
  });

  test(
    'unavailable, empty, numeric-only, weak and conflicting text need manual classification',
    () {
      for (final result in [
        OcrTextResult.unavailable(
          unavailableReason: 'test',
          engineVersion: 'test',
        ),
        OcrTextResult.available(lines: [], engineVersion: 'test'),
        OcrTextResult.available(
          lines: [OcrLine(text: '١٢٣٤٥٦789', confidence: .99)],
          engineVersion: 'test',
        ),
      ]) {
        expect(
          classifyDocument(
            ClassificationInput(ocrKeywords: ocrKeywordEvidence(result)),
          ).status,
          RecognitionStatus.unknown,
        );
      }
      final conflict = classifyDocument(
        ClassificationInput(
          ocrKeywords: [
            OcrKeywordEvidence(
              kind: DocumentKind.passport,
              score: .99,
              matchedAnchorGroups: 2,
            ),
            OcrKeywordEvidence(
              kind: DocumentKind.unifiedNationalId,
              score: .99,
              matchedAnchorGroups: 2,
            ),
          ],
        ),
      );
      expect(conflict.status, RecognitionStatus.uncertain);
      expect(qualifiesForAutomaticPlacement(conflict), isFalse);
    },
  );
}
