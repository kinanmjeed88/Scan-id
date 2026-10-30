import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/imaging/docquad_model.dart';

Uint8List _syntheticDesk({required bool card}) {
  final image = img.Image(width: 1000, height: 700);
  img.fill(image, color: img.ColorRgb8(62, 55, 48));
  if (card) {
    img.fillRect(
      image,
      x1: 195,
      y1: 155,
      x2: 810,
      y2: 545,
      color: img.ColorRgb8(238, 235, 222),
    );
    img.fillRect(
      image,
      x1: 230,
      y1: 195,
      x2: 495,
      y2: 240,
      color: img.ColorRgb8(90, 120, 152),
    );
    img.fillRect(
      image,
      x1: 520,
      y1: 195,
      x2: 785,
      y2: 220,
      color: img.ColorRgb8(50, 60, 65),
    );
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled DocQuadNet loads and proposes a review-only quad', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final model = DocQuadNet256();
    try {
      expect(
        await model.suggestProposal(_syntheticDesk(card: false)),
        isNull,
        reason: 'uniform synthetic background must not produce a quad',
      );

      final proposal = await model.suggestProposal(_syntheticDesk(card: true));
      expect(proposal, isNotNull);
      expect(proposal!.producer, BoundaryProducer.learnedModel);
      expect(proposal.corners, hasLength(4));
      expect(proposal.modelConfidence, greaterThanOrEqualTo(.05));
      final decision = verifyBoundary(
        proposal,
        sourceWidth: 1000,
        sourceHeight: 700,
      );
      expect(decision.verification.hasUsableGeometry, isTrue);
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(decision.cropAuthorization, isNull);
    } finally {
      await model.close();
    }
  });

  testWidgets('pre-cancelled inference does not load or return a proposal', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final model = DocQuadNet256();
    final token = CancellationToken()..cancel();
    await expectLater(
      model.suggestProposal(
        _syntheticDesk(card: true),
        cancellation: token,
      ),
      throwsA(isA<OperationCancelled>()),
    );
    await model.close();
  });
}
