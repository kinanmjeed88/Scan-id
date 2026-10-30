import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/boundary_proposal_cascade.dart';
import 'package:scan_id/imaging/docquad_model.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/safe_files.dart';

void main() {
  final preview = Uint8List.fromList(
    img.encodePng(img.Image(width: 1000, height: 700)),
  );

  Uint8List syntheticCard() {
    final image = img.Image(width: 1000, height: 700);
    img.fill(image, color: img.ColorRgb8(62, 55, 48));
    img.fillRect(
      image,
      x1: 195,
      y1: 155,
      x2: 810,
      y2: 545,
      color: img.ColorRgb8(238, 235, 222),
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  List<Point2> quad({double left = .12, double right = .88}) => [
    Point2(left, .12),
    Point2(right, .12),
    Point2(right, .88),
    Point2(left, .88),
  ];

  BoundaryProposal learned(List<Point2> corners) => BoundaryProposal(
    producer: BoundaryProducer.learnedModel,
    corners: corners,
    modelConfidence: .4,
    minAutoAcceptConfidence: 1.01,
  );

  test('runs DocAligner when DocQuadNet returns no boundary', () async {
    final first = _FakeModel('DocQuadNet');
    final second = _FakeModel('DocAligner', learned(quad()));
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);

    final proposal = await cascade.suggestProposal(preview);

    expect(first.calls, 1);
    expect(second.calls, 1);
    expect(proposal?.corners, equals(quad()));
    expect(
      verifyBoundary(proposal!, sourceWidth: 1000, sourceHeight: 700).kind,
      BoundaryDecisionKind.needsReview,
    );
  });

  test('runs DocAligner even when DocQuadNet geometry is valid', () async {
    final primaryProposal = learned(quad());
    final first = _FakeModel('DocQuadNet', primaryProposal);
    final second = _FakeModel('DocAligner', learned(quad()));
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);

    final proposal = await cascade.suggestProposal(preview);

    expect(first.calls, 1);
    expect(second.calls, 1);
    expect(proposal, same(primaryProposal));
    expect(
      verifyBoundary(
        proposal!,
        sourceWidth: 1000,
        sourceHeight: 700,
      ).cropAuthorization,
      isNull,
    );
  });

  test(
    'flags materially different model boundaries without averaging',
    () async {
      final first = _FakeModel('DocQuadNet', learned(quad()));
      final second = _FakeModel(
        'DocAligner',
        learned(quad(left: .2, right: .96)),
      );
      final cascade = BoundaryProposalCascade(
        primary: first,
        secondary: second,
      );

      final proposal = await cascade.suggestProposal(preview);
      final decision = verifyBoundary(
        proposal!,
        sourceWidth: 1000,
        sourceHeight: 700,
      );

      expect(proposal.corners, equals(quad()));
      expect(proposal.forceReview, isTrue);
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.modelDisagreement),
      );
      expect(decision.cropAuthorization, isNull);
    },
  );

  test('both AI failures reach the existing classical detector', () async {
    final first = _FakeModel('DocQuadNet')..fail = true;
    final second = _FakeModel('DocAligner')..fail = true;
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);
    final editor = LocalImageEditor(
      SafeFiles(Directory.systemTemp),
      boundaryProposer: cascade,
    );

    final proposal = await editor.suggestProposal(syntheticCard());

    expect(first.calls, 1);
    expect(second.calls, 1);
    expect(proposal?.producer, BoundaryProducer.detector);
    expect(
      verifyBoundary(proposal!, sourceWidth: 1000, sourceHeight: 700).kind,
      BoundaryDecisionKind.needsReview,
    );
  });

  test('drops a lone primary result when DocAligner fails', () async {
    final first = _FakeModel('DocQuadNet', learned(quad()));
    final second = _FakeModel('DocAligner')..fail = true;
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);

    expect(await cascade.suggestProposal(preview), isNull);
    expect(first.calls, 1);
    expect(second.calls, 1);
  });

  test('cancellation from the first model is not swallowed', () async {
    final first = _FakeModel('DocQuadNet')..cancel = true;
    final second = _FakeModel('DocAligner');
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);

    await expectLater(
      cascade.suggestProposal(preview),
      throwsA(isA<OperationCancelled>()),
    );
    expect(second.calls, 0);
  });
}

class _FakeModel implements BoundaryProposalModel {
  _FakeModel(this.modelId, [this.proposal]);

  @override
  final String modelId;
  final BoundaryProposal? proposal;
  int calls = 0;
  bool fail = false;
  bool cancel = false;

  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  }) async {
    calls++;
    if (cancel) throw const OperationCancelled();
    if (fail) throw StateError('synthetic model failure');
    return proposal;
  }
}
