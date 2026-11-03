import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';

import '../fixtures.dart';

// A4 eligibility matrix (PR #39 F-C, F-K; Unknown Size audit §4). Each row is
// one state from the implementation brief. The categories are kept separate:
// boundary approval, kind, physical size, and the three decisions (manual
// placement, automatic placement, export). Every expectation is taken from
// the contract (boundary, kind and size rules), not from the current code.

final _fullFrame = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];

final _quad = [
  Point2(.1, .12),
  Point2(.9, .1),
  Point2(.88, .8),
  Point2(.12, .82),
];

ImageAsset _asset({
  CropGeometry? crop,
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
    crop: crop,
    userAuthoredCrop: userAuthored,
    suggestedCrop: suggestion,
  );
}

CropGeometry _geometry(List<Point2> corners) {
  return CropGeometry(corners: corners, outputWidth: 400, outputHeight: 250);
}

class _Case {
  const _Case({
    required this.name,
    required this.asset,
    required this.kind,
    required this.confirmed,
    this.locked = false,
    required this.boundaryApproved,
    required this.needsReview,
    required this.kindKnown,
    required this.manual,
    required this.automatic,
    required this.export,
  });

  final String name;
  final ImageAsset asset;
  final DocumentKind kind;
  final bool confirmed;
  final bool locked;
  final bool boundaryApproved;
  final bool needsReview;
  final bool kindKnown;
  final bool manual;
  final bool automatic;
  final bool export;

  Project project({int? pageIndex}) {
    return projectFixture(
      assets: [asset],
      items: [
        DocumentItem(
          id: 'doc',
          assetId: asset.id,
          x: 10,
          y: 10,
          width: 85.6,
          height: 54,
          pageIndex: pageIndex,
          documentKind: kind,
          sizeConfirmed: confirmed,
          locked: locked,
        ),
      ],
    );
  }
}

final _cases = <_Case>[
  _Case(
    name: 'no approved boundary',
    asset: _asset(),
    kind: DocumentKind.unknown,
    confirmed: false,
    boundaryApproved: false,
    needsReview: false,
    kindKnown: false,
    manual: false,
    automatic: false,
    export: false,
  ),
  _Case(
    name: 'full frame stored by an adjustment is not an approved boundary',
    asset: _asset(crop: _geometry(_fullFrame)),
    kind: DocumentKind.unknown,
    confirmed: false,
    boundaryApproved: false,
    needsReview: false,
    kindKnown: false,
    manual: false,
    automatic: false,
    export: false,
  ),
  _Case(
    name: 'approved boundary with unknown kind',
    asset: _asset(crop: _geometry(_quad), userAuthored: true),
    kind: DocumentKind.unknown,
    confirmed: false,
    boundaryApproved: true,
    needsReview: false,
    kindKnown: false,
    manual: false,
    automatic: false,
    export: false,
  ),
  _Case(
    name: 'known kind with unconfirmed size',
    asset: _asset(),
    kind: DocumentKind.passport,
    confirmed: false,
    boundaryApproved: false,
    needsReview: false,
    kindKnown: true,
    manual: false,
    automatic: false,
    export: false,
  ),
  _Case(
    name: 'manual confirmed size',
    asset: _asset(),
    kind: DocumentKind.other,
    confirmed: true,
    boundaryApproved: false,
    needsReview: false,
    kindKnown: true,
    manual: true,
    automatic: true,
    export: true,
  ),
  _Case(
    name: 'catalog confirmed size',
    asset: _asset(crop: _geometry(_quad), userAuthored: true),
    kind: DocumentKind.passport,
    confirmed: true,
    boundaryApproved: true,
    needsReview: false,
    kindKnown: true,
    manual: true,
    automatic: true,
    export: true,
  ),
  _Case(
    name: 'needs review: a saved suggestion waits for the user',
    asset: _asset(suggestion: _quad),
    kind: DocumentKind.passport,
    confirmed: false,
    boundaryApproved: false,
    needsReview: true,
    kindKnown: true,
    manual: false,
    automatic: false,
    export: false,
  ),
  _Case(
    name: 'valid for manual placement only (fixed in place)',
    asset: _asset(crop: _geometry(_quad), userAuthored: true),
    kind: DocumentKind.passport,
    confirmed: true,
    locked: true,
    boundaryApproved: true,
    needsReview: false,
    kindKnown: true,
    manual: true,
    automatic: false,
    export: true,
  ),
  _Case(
    name: 'valid for automatic placement',
    asset: _asset(crop: _geometry(_quad), userAuthored: true),
    kind: DocumentKind.passport,
    confirmed: true,
    boundaryApproved: true,
    needsReview: false,
    kindKnown: true,
    manual: true,
    automatic: true,
    export: true,
  ),
];

/// True when [action] completes; false when it refuses with a
/// [ValidationException], the production refusal for an ineligible item.
bool _accepts(void Function() action) {
  try {
    action();
    return true;
  } on ValidationException {
    return false;
  }
}

/// The page-placed copy of [c]: manual placement and export are checked on
/// a project where the item already sits on page 0.
Project _placed(_Case c) => c.project(pageIndex: 0);

void main() {
  for (final c in _cases) {
    test('matrix: ${c.name}', () {
      final project = c.project();
      final item = project.items.single;
      final asset = project.assets.single;
      // Facts read from the model.
      expect(asset.hasApprovedCrop, c.boundaryApproved, reason: 'boundary');
      expect(
        !asset.hasApprovedCrop && asset.suggestedCrop != null,
        c.needsReview,
        reason: 'needs review',
      );
      expect(item.documentKind != DocumentKind.unknown, c.kindKnown);
      expect(item.sizeConfirmed, c.confirmed, reason: 'physical size');
      // Decisions taken by the production paths.
      expect(
        _accepts(() => PageLayout.checked(_placed(c))),
        c.manual,
        reason: 'manual placement (PageLayout.checked)',
      );
      expect(
        autoLayoutStatus(project, item) == AutoLayoutStatus.eligible,
        c.automatic,
        reason: 'automatic placement (autoLayoutStatus)',
      );
      expect(
        _accepts(() => ExportPlan(_placed(c), ExportProfile())),
        c.export,
        reason: 'export (ExportPlan)',
      );
    });

    test('reload keeps the decision: ${c.name}', () {
      final before = c.project(pageIndex: 0);
      final after = Project.fromJson(before.toJson());
      final item = after.items.single;
      expect(item.sizeConfirmed, c.confirmed);
      // fromJson keeps a page only for a confirmed size. An unconfirmed item
      // is off the sheet after reload, which is the rule to keep.
      if (c.confirmed) {
        expect(item.pageIndex, 0);
      } else {
        expect(item.pageIndex, isNull, reason: 'an unconfirmed item leaves');
      }
      expect(
        after.assets.single.hasApprovedCrop,
        before.assets.single.hasApprovedCrop,
      );
      expect(
        autoLayoutStatus(after, item),
        autoLayoutStatus(before, before.items.single),
      );
    });
  }

  test('an unconfirmed size is never placed on a valid boundary', () {
    final valid = _cases[2];
    expect(valid.project().assets.single.hasApprovedCrop, isTrue);
    expect(_accepts(() => PageLayout.checked(_placed(valid))), isFalse);
    expect(
      autoLayoutStatus(valid.project(), valid.project().items.single),
      AutoLayoutStatus.sizeUnconfirmed,
    );
    expect(
      _accepts(() => ExportPlan(_placed(valid), ExportProfile())),
      isFalse,
    );
  });

  test('a missing asset cannot hold an item: Project refuses it', () {
    final orphan = DocumentItem(
      id: 'doc',
      assetId: 'missing',
      x: 10,
      y: 10,
      width: 85.6,
      height: 54,
    );
    expect(
      () => projectFixture(items: [orphan]),
      throwsA(isA<ValidationException>()),
    );
  });
}
