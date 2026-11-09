import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_edits.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_adjustments.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';

import '../fixtures.dart';
import '../presentation/editor_harness.dart';

// F-D: a re-crop changes the picture, not the printed size. A confirmed size
// (catalog or typed) stays, a re-crop never confirms a size, and the aspect
// conflict is reported by the existing export warning, not a second one.

final _landscape = CropGeometry(
  corners: [Point2(.1, .1), Point2(.9, .1), Point2(.9, .7), Point2(.1, .7)],
  outputWidth: 400,
  outputHeight: 250,
);

final _square = CropGeometry(
  corners: [Point2(.1, .1), Point2(.9, .1), Point2(.9, .9), Point2(.1, .9)],
  outputWidth: 300,
  outputHeight: 300,
);

const _mismatch = 'نسبة المستطيل تختلف عن الصورة';

DocumentItem _doc() {
  return DocumentItem(
    id: 'doc',
    assetId: 'asset1',
    x: 10,
    y: 10,
    width: 85.6,
    height: 54,
    pageIndex: null,
  );
}

class _Harness {
  _Harness() {
    service = ProjectService(repo, NoAssets(), imageEditor: editor);
  }

  final MemoryProjects repo = MemoryProjects();
  final FakeImageEditor editor = FakeImageEditor();
  late ProjectService service;

  Future<Project> start() {
    final project = projectFixture(
      assets: [assetFixture(id: 'asset1')],
      items: [_doc()],
    );
    return repo.create(project);
  }

  Future<Project> recrop(Project p, CropGeometry geometry) {
    return service.applyManualCrop(
      p,
      p.assets.single,
      ImageEditRecipe(geometry, ImageAdjustments()),
      sourceWidth: 400,
      sourceHeight: 250,
    );
  }

  Future<Project> recropTurned(Project p, CropGeometry geometry) {
    final turned = ImageAdjustments().copyWith(quarterTurns: 1);
    return service.applyManualCrop(
      p,
      p.assets.single,
      ImageEditRecipe(geometry, turned),
      sourceWidth: 400,
      sourceHeight: 250,
    );
  }

  /// Saves [p] with the passport category applied, as the user would choose it.
  Future<Project> passport(Project p) {
    return repo.save(DocumentEdits.setKind(p, 'doc', DocumentKind.passport));
  }
}

Project _placed(Project p) {
  return p.copyWith(
    items: [PageLayout.item(p, 'doc').copyWith(pageIndex: 0, x: 10, y: 10)],
  );
}

bool _warns(Project p) {
  final warnings = ExportPlan(_placed(p), ExportProfile()).warnings;
  return warnings.any((w) => w.contains(_mismatch));
}

void _expectPassportOnSheet(Project reloaded) {
  final item = PageLayout.item(reloaded, 'doc');
  expect([item.width, item.height], [125, 88]);
  expect(item.sizeConfirmed, isTrue);
  expect(item.pageIndex, 0);
  expect(_warns(reloaded), isTrue);
}

void main() {
  test(
    'choosing an estimated kind alone never confirms print millimetres',
    () async {
      final h = _Harness();
      final project = await h.start();
      final saved = await h.service.confirmManualBoundary(
        project,
        project.assets.single,
        ImageEditRecipe(_square, ImageAdjustments()),
        documentKind: DocumentKind.residenceCard,
        targetItemId: 'doc',
        sourceWidth: 400,
        sourceHeight: 250,
      );
      expect(saved.items.single.sizeConfirmed, isFalse);
      expect(saved.items.single.pageIndex, isNull);
      expect(saved.assets.single.crop!.outputWidth, 300);
      expect(saved.assets.single.crop!.outputHeight, 300);
      expect(
        saved.assets.single.originalPath,
        project.assets.single.originalPath,
      );
    },
  );

  test(
    'manual confirmation never replaces preview geometry with print aspect',
    () async {
      for (final kind in [
        DocumentKind.unifiedNationalId,
        DocumentKind.residenceCard,
        DocumentKind.rationCard,
        DocumentKind.other,
      ]) {
        final h = _Harness();
        final project = await h.start();
        final original = project.assets.single.originalPath;
        final recipe = ImageEditRecipe(_square, ImageAdjustments());
        final saved = await h.service.confirmManualBoundary(
          project,
          project.assets.single,
          recipe,
          documentKind: kind,
          customSizeMm: kind == DocumentKind.other
              ? PhysicalSizeMm(120, 80)
              : presetStatusFor(kind) == PresetStatus.estimated
              ? const DocumentSizeCatalog().natural(kind)
              : null,
          targetItemId: 'doc',
          sourceWidth: 400,
          sourceHeight: 250,
        );
        final asset = saved.assets.single;
        expect(asset.originalPath, original);
        expect(asset.crop!.outputWidth, 300);
        expect(asset.crop!.outputHeight, 300);
        expect(asset.width / asset.height, 1);
        expect(saved.items.single.sizeConfirmed, isTrue);
        final reloaded = await h.repo.get(saved.id);
        expect(reloaded.assets.single.crop!.outputWidth, 300);
        expect(reloaded.assets.single.crop!.outputHeight, 300);
        expect(reloaded.items.single.width, saved.items.single.width);
      }
    },
  );

  test('a confirmed catalog size survives a re-crop', () async {
    final h = _Harness();
    var p = await h.start();
    p = await h.recrop(p, _landscape);
    p = await h.passport(p);
    final before = PageLayout.item(p, 'doc');
    expect(before.sizeConfirmed, isTrue);

    p = await h.recrop(p, _square);
    final after = PageLayout.item(p, 'doc');
    expect([after.width, after.height], [before.width, before.height]);
    expect(after.sizeConfirmed, isTrue);
    expect(after.documentKind, DocumentKind.passport);
    expect(_warns(p), isTrue);
  });

  test('a typed size survives a re-crop', () async {
    final h = _Harness();
    var p = await h.start();
    p = await h.recrop(p, _landscape);
    p = await h.repo.save(DocumentEdits.resize(p, 'doc', width: 90));
    p = await h.recrop(p, _square);
    final item = PageLayout.item(p, 'doc');
    expect(item.width, 90);
    expect(item.sizeConfirmed, isTrue);
  });

  test('a re-crop never confirms a provisional size silently', () async {
    final h = _Harness();
    var p = await h.start();
    p = await h.passport(p);
    expect(PageLayout.item(p, 'doc').sizeConfirmed, isFalse);

    p = await h.recrop(p, _square);
    final item = PageLayout.item(p, 'doc');
    expect(item.sizeConfirmed, isFalse);
    expect(item.pageIndex, isNull);
  });

  test('a turned picture keeps the printed size', () async {
    final h = _Harness();
    var p = await h.start();
    p = await h.recrop(p, _landscape);
    p = await h.passport(p);
    final before = PageLayout.item(p, 'doc');
    p = await h.recropTurned(p, _landscape);
    final item = PageLayout.item(p, 'doc');
    expect([item.width, item.height], [before.width, before.height]);
    expect(p.assets.single.width < p.assets.single.height, isTrue);
    expect(_warns(p), isTrue);
  });

  test('the size and the conflict survive save and reload', () async {
    final h = _Harness();
    var p = await h.start();
    p = await h.recrop(p, _landscape);
    p = await h.passport(p);
    p = await h.recrop(p, _square);
    final stored = await h.repo.save(_placed(p));

    final reopened = await h.repo.get(stored.id);
    _expectPassportOnSheet(reopened);
    _expectPassportOnSheet(Project.fromJson(reopened.toJson()));
  });
}
