import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/imaging/boundary_proposal_cascade.dart';
import 'package:scan_id/imaging/docquad_model.dart';
import 'package:scan_id/imaging/docaligner_model.dart';

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

  testWidgets(
    'official DocAligner 1.1.1 weight is hash-pinned and runs ONNX inference',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final asset = await rootBundle.load(docAlignerAssetPath);
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      expect(bytes.length, docAlignerExpectedBytes);
      expect(sha256.convert(bytes).toString(), docAlignerExpectedSha256);

      final model = DocAlignerFastViT();
      try {
        final proposal = await model.suggestProposal(
          _syntheticDesk(card: true),
        );
        // This count increments only after session.run returns an ONNX output;
        // it cannot pass through a mocked BoundaryProposalModel.
        expect(model.inferenceRuns, 1);
        expect(model.lastOutputShape, hasLength(4));
        expect(model.lastOutputShape![0], 1);
        expect(model.lastOutputShape![1], 4);
        expect(model.lastOutputShape![2], greaterThan(0));
        expect(model.lastOutputShape![3], greaterThan(0));
        if (proposal != null) {
          expect(proposal.corners, hasLength(4));
          final decision = verifyBoundary(
            proposal,
            sourceWidth: 1000,
            sourceHeight: 700,
          );
          expect(decision.verification.hasUsableGeometry, isTrue);
          expect(decision.kind, BoundaryDecisionKind.needsReview);
          expect(decision.cropAuthorization, isNull);
        }
      } finally {
        await model.close();
      }

      final primary = DocQuadNet256();
      final actualSecondary = DocAlignerFastViT();
      try {
        await BoundaryProposalCascade(
          primary: primary,
          secondary: actualSecondary,
        ).suggestProposal(_syntheticDesk(card: true));
        expect(
          actualSecondary.inferenceRuns,
          1,
          reason: 'the production cascade must call the actual ONNX model',
        );
      } finally {
        await primary.close();
        await actualSecondary.close();
      }
    },
  );

  testWidgets('pre-cancelled inference does not load or return a proposal', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final model = DocQuadNet256();
    final token = CancellationToken()..cancel();
    await expectLater(
      model.suggestProposal(_syntheticDesk(card: true), cancellation: token),
      throwsA(isA<OperationCancelled>()),
    );
    await model.close();
  });
}
