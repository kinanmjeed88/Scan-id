import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/domain/acceptance_policy.dart';
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

  BoundaryProposal learned(List<Point2> corners, {double score = .4}) =>
      BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: corners,
        modelConfidence: score,
        minAutoAcceptConfidence: automaticAcceptanceThreshold,
      );

  void expectCorners(List<Point2>? actual, List<Point2> expected) {
    expect(actual, hasLength(expected.length));
    final corners = actual!;
    for (var index = 0; index < expected.length; index++) {
      expect(corners[index].x, closeTo(expected[index].x, 1e-9));
      expect(corners[index].y, closeTo(expected[index].y, 1e-9));
    }
  }

  test('a missing detector is recorded, not silently dropped', () async {
    final first = _FakeModel('docquadnet256', learned(quad()));
    final second = _FakeModel('docaligner')..fail = true;
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);

    final proposal = await cascade.suggestProposal(preview);

    expect(proposal, isNotNull);
    expect(proposal!.traces, hasLength(2));
    expect(proposal.traces.first.modelId, 'docquadnet256');
    expect(proposal.traces.first.outcome, BoundaryDetectorOutcome.proposal);
    expect(proposal.traces.first.confidence, .4);
    expect(proposal.traces.last.outcome, BoundaryDetectorOutcome.failed);
    expect(proposal.traces.last.errorType, 'StateError');
    // A lone proposal still never authorizes an automatic crop.
    expect(proposal.forceReview, isTrue);
    expect(proposal.traces.first.encode(), contains('outcome=proposal'));
  });

  test('both detectors failing keeps the trace and names the reason', () async {
    final first = _FakeModel('docquadnet256')..fail = true;
    final second = _FakeModel('docaligner');
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);

    final proposal = await cascade.suggestProposal(preview);

    expect(proposal, isNotNull);
    expect(proposal!.corners, isNull);
    expect(
      proposal.forceReviewReason,
      BoundaryReviewReason.modelNotCorroborated,
    );
    expect(proposal.traces.map((trace) => trace.outcome), [
      BoundaryDetectorOutcome.failed,
      BoundaryDetectorOutcome.noQuad,
    ]);
    final decision = verifyBoundary(
      proposal,
      sourceWidth: 1000,
      sourceHeight: 700,
    );
    expect(decision.cropAuthorization, isNull);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.noBoundary),
    );
  });

  test('runs DocAligner when DocQuadNet returns no boundary', () async {
    final first = _FakeModel('DocQuadNet');
    final second = _FakeModel('DocAligner', learned(quad()));
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);

    final proposal = await cascade.suggestProposal(preview);

    expect(first.calls, 1);
    expect(second.calls, 1);
    expectCorners(proposal?.corners, quad());
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
    expectCorners(proposal?.corners, primaryProposal.corners!);
    expect(proposal?.forceReview, isTrue);
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
      final first = _FakeModel('DocQuadNet', learned(quad(), score: .95));
      final second = _FakeModel(
        'DocAligner',
        learned(quad(left: .2, right: .96), score: .95),
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

      expectCorners(proposal.corners, quad());
      expect(proposal.forceReview, isTrue);
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.modelDisagreement),
      );
      expect(decision.cropAuthorization, isNull);
    },
  );

  test(
    'high primary cannot borrow confidence from a weak agreeing second model',
    () async {
      final cascade = BoundaryProposalCascade(
        primary: _FakeModel('primary', learned(quad(), score: .95)),
        secondary: _FakeModel('secondary', learned(quad(), score: .549)),
      );
      final proposal = await cascade.suggestProposal(preview);
      expect(proposal!.modelConfidence, .95);
      expect(
        proposal.forceReviewReason,
        BoundaryReviewReason.modelNotCorroborated,
      );
      expect(
        verifyBoundary(
          proposal,
          sourceWidth: 1000,
          sourceHeight: 700,
        ).cropAuthorization,
        isNull,
      );
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

  test(
    'a corroborated 55% proposal is accepted when geometry is safe',
    () async {
      final first = _FakeModel('DocQuadNet', learned(quad(), score: .55));
      final second = _FakeModel('DocAligner', learned(quad(), score: .75));
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
      expect(decision.cropAuthorization, isNotNull);
    },
  );

  test('retains a high-scoring lone primary only for review', () async {
    final first = _FakeModel('DocQuadNet', learned(quad(), score: .95));
    final second = _FakeModel('DocAligner')..fail = true;
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);

    final proposal = await cascade.suggestProposal(preview);
    expectCorners(proposal?.corners, quad());
    final decision = verifyBoundary(
      proposal!,
      sourceWidth: 1000,
      sourceHeight: 700,
    );
    expect(proposal.modelConfidence, .95);
    expect(decision.kind, BoundaryDecisionKind.needsReview);
    expect(decision.cropAuthorization, isNull);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.modelNotCorroborated),
    );
    expect(first.calls, 1);
    expect(second.calls, 1);
  });

  test('a high-scoring lone secondary is also review-only', () async {
    final first = _FakeModel('DocQuadNet')..fail = true;
    final second = _FakeModel('DocAligner', learned(quad(), score: .95));
    final cascade = BoundaryProposalCascade(primary: first, secondary: second);
    final proposal = await cascade.suggestProposal(preview);
    final decision = verifyBoundary(
      proposal!,
      sourceWidth: 1000,
      sourceHeight: 700,
    );
    expect(decision.cropAuthorization, isNull);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.modelNotCorroborated),
    );
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
