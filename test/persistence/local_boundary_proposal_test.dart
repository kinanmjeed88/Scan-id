import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/safe_files.dart';

void main() {
  test('local classical detector emits a review-only proposal without '
      'altering its preview', () async {
    final image = img.Image(width: 240, height: 180);
    img.fill(image, color: img.ColorRgb8(80, 90, 100));
    img.fillRect(
      image,
      x1: 35,
      y1: 25,
      x2: 205,
      y2: 150,
      color: img.ColorRgb8(245, 245, 240),
    );
    final bytes = img.encodePng(image);
    final originalBytes = List<int>.of(bytes);
    final editor = LocalImageEditor(
      SafeFiles(Directory.systemTemp),
    );

    final proposal = await editor.suggestProposal(bytes);

    expect(proposal, isNotNull);
    expect(proposal!.producer, BoundaryProducer.detector);
    expect(proposal.corners, hasLength(4));
    expect(proposal.modelConfidence, isNull);
    expect(proposal.minAutoAcceptConfidence, isNull);
    expect(bytes, originalBytes);
    final decision = verifyBoundary(
      proposal,
      sourceWidth: image.width,
      sourceHeight: image.height,
    );
    expect(decision.kind, BoundaryDecisionKind.needsReview);
    expect(decision.cropAuthorization, isNull);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.uncalibratedClassicalScore),
    );
  });

  test('cancelled detector work does not return a stale proposal', () async {
    final token = CancellationToken()..cancel();
    final editor = LocalImageEditor(SafeFiles(Directory.systemTemp));
    await expectLater(
      editor.suggestProposal(img.encodePng(img.Image(width: 32, height: 32)),
          cancellation: token),
      throwsA(isA<OperationCancelled>()),
    );
  });
}
