import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/document_edits.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_adjustments.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';

import '../fixtures.dart';

Project _project({bool locked = false}) => projectFixture(
  assets: [assetFixture()], // 400 × 250 landscape working image
  items: [
    DocumentItem(
      id: 'doc',
      assetId: 'asset1',
      x: 0,
      y: 0,
      width: 80,
      height: 50,
      pageIndex: null,
      locked: locked,
    ),
  ],
);

ImageAsset _croppedAsset() {
  final base = assetFixture();
  return ImageAsset(
    id: base.id,
    name: base.name,
    originalPath: base.originalPath,
    workingPath: base.workingPath,
    thumbnailPath: base.thumbnailPath,
    width: base.width,
    height: base.height,
    crop: CropGeometry(
      corners: [
        Point2(.05, .05),
        Point2(.95, .05),
        Point2(.95, .95),
        Point2(.05, .95),
      ],
      outputWidth: 400,
      outputHeight: 250,
    ),
    userAuthoredCrop: true,
  );
}

void main() {
  // Spec change (PR #39, F-C): choosing a category no longer confirms the
  // physical size by itself. Confirmation needs an approved crop.
  test('choosing a category without a crop applies the catalog size only', () {
    final p = DocumentEdits.setKind(
      _project(),
      'doc',
      DocumentKind.unifiedNationalId,
    );
    final item = PageLayout.item(p, 'doc');
    expect([item.width, item.height], [85.6, 53.98]);
    expect(item.sizeConfirmed, isFalse);
    expect(item.pageIndex, isNull);
    expect(item.documentKind, DocumentKind.unifiedNationalId);
    expect(item.hasUserSelectedKind, isTrue);
  });

  test('a suggested quadrilateral is not an approved crop', () {
    final corners = [
      Point2(.08, .12),
      Point2(.91, .14),
      Point2(.88, .78),
      Point2(.10, .81),
    ];
    final project = _project().copyWith(
      assets: [assetFixture().withSuggestedCrop(corners)],
    );
    final selected = DocumentEdits.setKind(
      project,
      'doc',
      DocumentKind.unifiedNationalId,
    );

    expect(DocumentEdits.hasApprovedCrop(selected.assets.single), isFalse);
    expect(selected.assets.single.crop, isNull);
    expect(selected.assets.single.suggestedCrop, corners);
    expect(PageLayout.item(selected, 'doc').sizeConfirmed, isFalse);
  });

  test('choosing unknown clears the previous manual-kind marker', () {
    final selected = DocumentEdits.setKind(
      _project(),
      'doc',
      DocumentKind.unifiedNationalId,
    );
    expect(PageLayout.item(selected, 'doc').hasUserSelectedKind, isTrue);
    final reset = DocumentEdits.setKind(selected, 'doc', DocumentKind.unknown);
    final item = PageLayout.item(reset, 'doc');
    expect(item.documentKind, DocumentKind.unknown);
    expect(item.hasUserSelectedKind, isFalse);
    expect(item.presetSnapshot, isNull);
  });

  test('a category with an approved crop confirms the catalog size', () {
    final project = _project().copyWith(assets: [_croppedAsset()]);
    final selected = DocumentEdits.setKind(
      project,
      'doc',
      DocumentKind.unifiedNationalId,
    );
    final item = PageLayout.item(selected, 'doc');
    expect(DocumentEdits.hasApprovedCrop(selected.assets.single), isTrue);
    expect([item.width, item.height], [85.6, 53.98]);
    expect(item.sizeConfirmed, isTrue);
    expect(item.presetSnapshot?.status, PresetStatus.user);
    expect(item.hasUserConfirmedSize, isTrue);
  });

  test('estimated sizes remain off A4 until explicitly sized', () {
    for (final kind in [DocumentKind.residenceCard, DocumentKind.rationCard]) {
      final cropped = _project().copyWith(assets: [_croppedAsset()]);
      final selected = DocumentEdits.setKind(cropped, 'doc', kind);
      final item = PageLayout.item(selected, 'doc');
      expect(item.sizeConfirmed, isFalse);
      expect(item.presetSnapshot?.status, PresetStatus.estimated);
      final arranged = arrangeDocuments(selected);
      expect(arranged.awaitingSize, contains('doc'));
      expect(PageLayout.item(arranged.result, 'doc').pageIndex, isNull);

      final measured = DocumentEdits.resize(selected, 'doc', width: 90);
      final reselected = DocumentEdits.setKind(measured, 'doc', kind);
      expect(PageLayout.item(reselected, 'doc').sizeConfirmed, isTrue);
      expect(PageLayout.item(reselected, 'doc').width, 90);
      final reset = DocumentEdits.resetSize(reselected, 'doc');
      expect(PageLayout.item(reset, 'doc').sizeConfirmed, isFalse);
      expect(PageLayout.item(reset, 'doc').pageIndex, isNull);
    }
  });

  test('reselecting a catalog type preserves its manual footprint', () {
    final cropped = _project().copyWith(assets: [_croppedAsset()]);
    final selected = DocumentEdits.setKind(
      cropped,
      'doc',
      DocumentKind.unifiedNationalId,
    );
    final measured = DocumentEdits.resize(selected, 'doc', width: 90);
    final reselected = DocumentEdits.setKind(
      measured,
      'doc',
      DocumentKind.unifiedNationalId,
    );
    final item = PageLayout.item(reselected, 'doc');
    expect(item.width, 90);
    expect(item.height, closeTo(90 * 53.98 / 85.6, 1e-9));
    expect(item.sizeConfirmed, isTrue);
    expect(item.hasUserConfirmedSize, isTrue);
    expect(item.presetSnapshot?.status, PresetStatus.user);
  });

  test('civil-status identity requires a manually measured size', () {
    final selected = DocumentEdits.setKind(
      _project(),
      'doc',
      DocumentKind.civilStatusId,
    );
    final awaiting = PageLayout.item(selected, 'doc');
    expect(awaiting.documentKind, DocumentKind.civilStatusId);
    expect(awaiting.sizeConfirmed, isFalse);
    expect(awaiting.pageIndex, isNull);
    expect(awaiting.hasUserSelectedKind, isTrue);
    expect(selected.catalog.natural(DocumentKind.civilStatusId), isNull);

    final measured = DocumentEdits.resize(selected, 'doc', width: 88);
    final item = PageLayout.item(measured, 'doc');
    expect(item.documentKind, DocumentKind.civilStatusId);
    expect(item.width, 88);
    expect(item.height, closeTo(55, 1e-9));
    expect(item.sizeConfirmed, isTrue);
    expect(item.presetSnapshot?.status, PresetStatus.user);
    expect(item.hasUserConfirmedSize, isTrue);

    final reselected = DocumentEdits.setKind(
      measured,
      'doc',
      DocumentKind.civilStatusId,
    );
    final retained = PageLayout.item(reselected, 'doc');
    expect(retained.sizeConfirmed, isTrue);
    expect(retained.width, 88);
    expect(retained.height, closeTo(55, 1e-9));

    final changedFromOther = DocumentEdits.setKind(
      DocumentEdits.resize(_project(), 'doc', width: 88),
      'doc',
      DocumentKind.civilStatusId,
    );
    final retainedOtherMeasurement = PageLayout.item(changedFromOther, 'doc');
    expect(retainedOtherMeasurement.documentKind, DocumentKind.civilStatusId);
    expect(retainedOtherMeasurement.sizeConfirmed, isTrue);
    expect(retainedOtherMeasurement.width, 88);
    expect(retainedOtherMeasurement.height, closeTo(55, 1e-9));

    final restoredProject = Project.fromJson(measured.toJson());
    final restored = PageLayout.item(restoredProject, 'doc');
    expect(restored.documentKind, DocumentKind.civilStatusId);
    expect(restored.hasUserSelectedKind, isTrue);
    expect(restored.hasUserConfirmedSize, isTrue);
    expect(restored.sizeConfirmed, isTrue);
  });

  test('manual size provenance is separate from category selection', () {
    final project = _project();
    final natural = DocumentSizeCatalog.unifiedNationalId;
    final automatic = PageLayout.item(project, 'doc').copyWith(
      documentKind: DocumentKind.unifiedNationalId,
      width: natural.width,
      height: natural.height,
      sizeConfirmed: true,
      presetSnapshot: PresetSnapshot(
        variantId: builtinVariantId(DocumentKind.unifiedNationalId),
        widthMm: natural.width,
        heightMm: natural.height,
        status: PresetStatus.standard,
      ),
    );
    final measuredProject = DocumentEdits.resize(
      project.copyWith(items: [automatic]),
      'doc',
      width: 90,
    );
    final measured = PageLayout.item(measuredProject, 'doc');
    expect(measured.width, 90);
    expect(measured.userSelectedKind, isFalse);
    expect(measured.hasUserSelectedKind, isFalse);
    expect(measured.hasUserConfirmedSize, isTrue);

    final restored = DocumentItem.fromJson(measured.toJson());
    expect(restored.userSelectedKind, isFalse);
    expect(restored.hasUserSelectedKind, isFalse);
    final legacyJson = Map<String, Object?>.from(measured.toJson())
      ..remove('userSelectedKind');
    expect(DocumentItem.fromJson(legacyJson).hasUserSelectedKind, isFalse);
  });

  test('a category change takes a confirmed uncropped item off the sheet', () {
    final typed = DocumentEdits.resize(_project(), 'doc', width: 90);
    final placed = typed.copyWith(
      items: [
        PageLayout.item(typed, 'doc').copyWith(pageIndex: 0, x: 10, y: 10),
      ],
    );
    final c = DocumentEdits.setKind(placed, 'doc', DocumentKind.passport);
    final changed = PageLayout.item(c, 'doc');
    expect(changed.sizeConfirmed, isFalse);
    expect(changed.pageIndex, isNull);
  });

  test('other without a confirmed size stays unconfirmed', () {
    final other = DocumentEdits.setKind(_project(), 'doc', DocumentKind.other);
    final item = PageLayout.item(other, 'doc');
    expect(item.sizeConfirmed, isFalse);
    expect(item.pageIndex, isNull);
  });

  test('refreshProvisionalSize re-orients only unconfirmed catalog sizes', () {
    // A portrait provisional size on a landscape picture must lie down.
    final base = PageLayout.item(_project(), 'doc');
    final passport = base.copyWith(documentKind: DocumentKind.passport);
    final portraitItem = passport.copyWith(width: 88, height: 125);
    final portrait = _project().copyWith(items: [portraitItem]);
    final refreshedDoc = DocumentEdits.refreshProvisionalSize(portrait, 'doc');
    final refreshed = PageLayout.item(refreshedDoc, 'doc');
    expect([refreshed.width, refreshed.height], [125, 88]);
    expect(refreshed.sizeConfirmed, isFalse);

    final typed = DocumentEdits.resize(_project(), 'doc', width: 90);
    final kept = DocumentEdits.refreshProvisionalSize(typed, 'doc');
    expect(PageLayout.item(kept, 'doc').width, 90);
    expect(PageLayout.item(kept, 'doc').sizeConfirmed, isTrue);
  });

  test('the catalog size follows the picture orientation', () {
    final p = DocumentEdits.setKind(_project(), 'doc', DocumentKind.rationCard);
    final item = PageLayout.item(p, 'doc');
    // The 400 × 250 picture is landscape, so the portrait card lies down.
    expect([item.width, item.height], [287, 52]);
  });

  test('"unknown" takes the document off the sheet, "other" keeps it', () {
    // A typed size is an explicit confirmation; it keeps "other" on the sheet.
    final p = DocumentEdits.setKind(_project(), 'doc', DocumentKind.passport);
    final typed = DocumentEdits.resize(p, 'doc', width: 125);
    final item = PageLayout.item(typed, 'doc');
    final onSheet = item.copyWith(pageIndex: 0, x: 10, y: 10);
    final placed = typed.copyWith(items: [onSheet]);
    final u = DocumentEdits.setKind(placed, 'doc', DocumentKind.unknown);
    final unknown = PageLayout.item(u, 'doc');
    expect(unknown.pageIndex, isNull);
    expect(unknown.sizeConfirmed, isFalse);
    final other = PageLayout.item(
      DocumentEdits.setKind(placed, 'doc', DocumentKind.other),
      'doc',
    );
    expect(other.sizeConfirmed, isTrue);
    expect(other.pageIndex, 0);
    expect([other.width, other.height], [125, 88]);
  });

  test(
    'resizing keeps the aspect ratio when locked and marks the size set',
    () {
      final p = DocumentEdits.resize(_project(), 'doc', width: 100);
      final item = PageLayout.item(p, 'doc');
      expect(item.width, 100);
      expect(item.height, closeTo(62.5, 1e-9));
      expect(item.sizeConfirmed, isTrue);
      final free = _project().copyWith(
        items: [
          PageLayout.item(_project(), 'doc').copyWith(keepAspectRatio: false),
        ],
      );
      final stretched = PageLayout.item(
        DocumentEdits.resize(free, 'doc', height: 70),
        'doc',
      );
      expect([stretched.width, stretched.height], [80, 70]);
      expect(
        () => DocumentEdits.resize(_project(), 'doc', width: 5),
        throwsA(isA<ValidationException>()),
      );
    },
  );

  test('reset restores the catalog size; rotate turns by 90°', () {
    var p = DocumentEdits.setKind(_project(), 'doc', DocumentKind.passport);
    p = DocumentEdits.resize(p, 'doc', width: 100);
    p = DocumentEdits.resetSize(p, 'doc');
    expect(PageLayout.item(p, 'doc').width, 125);
    p = DocumentEdits.rotate(p, 'doc');
    expect(PageLayout.item(p, 'doc').rotation, 90);
    p = DocumentEdits.rotate(
      DocumentEdits.rotate(DocumentEdits.rotate(p, 'doc'), 'doc'),
      'doc',
    );
    expect(PageLayout.item(p, 'doc').rotation, 0);
  });

  test('locked documents refuse edits', () {
    expect(
      () => DocumentEdits.setKind(
        _project(locked: true),
        'doc',
        DocumentKind.passport,
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => DocumentEdits.rotate(_project(locked: true), 'doc'),
      throwsA(isA<ValidationException>()),
    );
  });

  test('editing the catalog updates provisional sizes', () {
    var p = DocumentEdits.setKind(
      _project(),
      'doc',
      DocumentKind.residenceCard,
    );
    p = DocumentEdits.applyCatalog(
      p,
      p.catalog.copyWith(residenceCard: const PhysicalSizeMm(95, 65)),
    );
    final item = PageLayout.item(p, 'doc');
    expect([item.width, item.height], [95, 65]);
    expect(p.catalog.residenceCard.width, 95);
    final reopened = Project.fromJson(p.toJson());
    expect(reopened.catalog.residenceCard.height, 65);
  });

  test('editing the catalog preserves confirmed and locked footprints', () {
    final selected = DocumentEdits.setKind(
      _project(),
      'doc',
      DocumentKind.residenceCard,
    );
    final measured = DocumentEdits.resize(selected, 'doc', width: 100);
    final before = PageLayout.item(measured, 'doc');
    final updated = DocumentEdits.applyCatalog(
      measured,
      measured.catalog.copyWith(residenceCard: const PhysicalSizeMm(95, 65)),
    );
    final after = PageLayout.item(updated, 'doc');
    expect([after.width, after.height], [before.width, before.height]);
    expect(after.presetSnapshot?.widthMm, before.presetSnapshot?.widthMm);
    expect(after.sizeConfirmed, isTrue);

    final locked = selected.copyWith(
      items: [PageLayout.item(selected, 'doc').copyWith(locked: true)],
    );
    final changed = DocumentEdits.applyCatalog(locked, updated.catalog);
    expect(PageLayout.item(changed, 'doc').width, 92.4);
  });

  test('colour matrix reproduces the export colour pipeline', () {
    final a = ImageAdjustments(brightness: .1, contrast: 1.4, saturation: .6);
    final m = a.colorMatrix;
    // Export formula on normalised channels.
    List<double> export(double r, double g, double b) {
      final l = .2126 * r + .7152 * g + .0722 * b;
      double ch(double c) =>
          (((l + (c - l) * a.saturation) - .5) * a.contrast + .5 + a.brightness)
              .clamp(0, 1)
              .toDouble();
      return [ch(r), ch(g), ch(b)];
    }

    List<double> matrix(double r, double g, double b) => [
      for (var row = 0; row < 3; row++)
        ((m[row * 5] * r * 255 +
                    m[row * 5 + 1] * g * 255 +
                    m[row * 5 + 2] * b * 255 +
                    m[row * 5 + 4]) /
                255)
            .clamp(0, 1)
            .toDouble(),
    ];

    for (final rgb in const [
      (.2, .4, .6),
      (.9, .1, .3),
      (.5, .5, .5),
      (0.0, 1.0, .25),
    ]) {
      final e = export(rgb.$1, rgb.$2, rgb.$3);
      final g = matrix(rgb.$1, rgb.$2, rgb.$3);
      for (var i = 0; i < 3; i++) {
        expect(g[i], closeTo(e[i], 1e-9));
      }
    }
    expect(ImageAdjustments().colorMatrix, [
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, //
      0, 0, 1, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);
  });
}
