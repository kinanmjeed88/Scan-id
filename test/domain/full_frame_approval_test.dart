import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_edits.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/quad_assessment.dart';
import 'package:scan_id/domain/validation.dart';

import '../fixtures.dart';

// F-K / F-M. A full frame is never an approved boundary unless the user
// approved it. Adjustment, rotation and enhancement revisions store the full
// frame in `ImageAsset.crop` without a decision, and that must not count.

final _frame = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];

ImageAsset _asset({
  List<Point2>? corners,
  bool userAuthored = false,
  List<Point2>? suggestion,
}) {
  final base = assetFixture();
  return ImageAsset(
    id: base.id,
    name: base.name,
    originalPath: base.originalPath,
    workingPath: base.workingPath,
    thumbnailPath: base.thumbnailPath,
    width: base.width,
    height: base.height,
    crop: corners == null
        ? null
        : CropGeometry(corners: corners, outputWidth: 400, outputHeight: 250),
    userAuthoredCrop: userAuthored,
    suggestedCrop: suggestion,
  );
}

Project _project(ImageAsset asset) => projectFixture(
  assets: [asset],
  items: [
    DocumentItem(
      id: 'doc',
      assetId: asset.id,
      x: 10,
      y: 10,
      width: 85.6,
      height: 54,
      pageIndex: null,
    ),
  ],
);

QuadAssessment _assess(List<Point2> corners) =>
    assessQuad(corners, sourceWidth: 400, sourceHeight: 250);

void main() {
  group('full frame approval', () {
    test('the frame is recognised in any corner order', () {
      expect(isFullFrameCorners(_frame), isTrue);
      expect(
        isFullFrameCorners([_frame[2], _frame[0], _frame[3], _frame[1]]),
        isTrue,
      );
    });

    test('a repeated corner, a moved corner, or three points are not it', () {
      expect(
        isFullFrameCorners([_frame[0], _frame[0], _frame[1], _frame[2]]),
        isFalse,
      );
      expect(
        isFullFrameCorners([Point2(.01, 0), _frame[1], _frame[2], _frame[3]]),
        isFalse,
      );
      expect(isFullFrameCorners(_frame.take(3).toList()), isFalse);
    });

    test('a stored full frame from an adjustment is not an approved crop', () {
      final stored = _asset(corners: _frame);
      expect(stored.crop, isNotNull, reason: 'the revision stores a geometry');
      expect(stored.hasApprovedCrop, isFalse);
      expect(DocumentEdits.hasApprovedCrop(stored), isFalse);
    });

    test('a full frame the user authored is an approved crop', () {
      final authored = _asset(corners: _frame, userAuthored: true);
      expect(authored.hasApprovedCrop, isTrue);
    });

    test('a non-full geometry is approved (automatic accepted boundary)', () {
      final quad = [
        Point2(.1, .12),
        Point2(.9, .1),
        Point2(.88, .8),
        Point2(.12, .82),
      ];
      expect(_asset(corners: quad).hasApprovedCrop, isTrue);
    });

    test('a suggestion is never an approved crop', () {
      final quad = [
        Point2(.1, .12),
        Point2(.9, .1),
        Point2(.88, .8),
        Point2(.12, .82),
      ];
      expect(_asset(suggestion: quad).hasApprovedCrop, isFalse);
    });

    test('a category cannot confirm a size from an adjusted full frame', () {
      final p = _project(_asset(corners: _frame));
      final kind = DocumentEdits.setKind(p, 'doc', DocumentKind.passport);
      final item = PageLayout.item(kind, 'doc');
      expect(item.sizeConfirmed, isFalse);
      expect(item.pageIndex, isNull);
      final sized = DocumentEdits.resetSize(kind, 'doc');
      expect(PageLayout.item(sized, 'doc').sizeConfirmed, isFalse);
    });
  });

  group('quad validity (same contract as the crop gate)', () {
    test('four repeated points are refused', () {
      final q = _assess([
        Point2(.5, .5),
        Point2(.5, .5),
        Point2(.5, .5),
        _frame[0],
      ]);
      expect(q.acceptable, isFalse);
    });

    test('near-coincident corners are refused as too small or degenerate', () {
      final q = _assess([
        Point2(.5, .5),
        Point2(.5 + 3 / 399, .5),
        Point2(.5 + 3 / 399, .5 + 3 / 249),
        Point2(.5, .5 + 3 / 249),
      ]);
      expect(q.acceptable, isFalse);
      expect(
        {
          QuadRejection.tooSmall,
          QuadRejection.degenerateEdges,
          QuadRejection.notConvex,
        },
        contains(q.rejection),
      );
    });

    test('a self-intersecting bow-tie is refused as not convex', () {
      final q = _assess([
        Point2(.1, .1),
        Point2(.9, .9),
        Point2(.9, .1),
        Point2(.1, .9),
      ]);
      expect(q.rejection, QuadRejection.notConvex);
    });

    test('a counter-clockwise ring breaks the clockwise contract', () {
      final q = _assess([
        Point2(.1, .1),
        Point2(.1, .9),
        Point2(.9, .9),
        Point2(.9, .1),
      ]);
      expect(q.rejection, QuadRejection.notConvex);
    });

    test('a clockwise ring starting at another corner is accepted', () {
      final q = _assess([
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
        Point2(.1, .1),
      ]);
      expect(q.acceptable, isTrue);
    });

    test('a corner outside the image is refused as out of bounds', () {
      final q = _assess([
        Point2(1.2, .1),
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
      ]);
      expect(q.rejection, QuadRejection.outOfBounds);
    });

    test('a non-finite coordinate cannot be constructed', () {
      expect(
        () => Point2(double.infinity, 0),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a valid full-frame geometry is valid but still not approved', () {
      expect(_assess(_frame).acceptable, isTrue);
      expect(_asset(corners: _frame).hasApprovedCrop, isFalse);
    });
  });
}
