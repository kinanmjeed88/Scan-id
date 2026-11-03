import 'package:flutter_test/flutter_test.dart';
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
  });

  // Spec change (PR #39 F-C/F-D): a category change never replaces or revokes
  // a size the user typed without an approved crop. The old behaviour put the
  // typed document off the sheet with a catalog guess.
  test('a category change keeps a typed size on the sheet', () {
    final typed = DocumentEdits.resize(_project(), 'doc', width: 90);
    final placed = typed.copyWith(
      items: [
        PageLayout.item(typed, 'doc').copyWith(pageIndex: 0, x: 10, y: 10),
      ],
    );
    final c = DocumentEdits.setKind(placed, 'doc', DocumentKind.passport);
    final changed = PageLayout.item(c, 'doc');
    expect(changed.documentKind, DocumentKind.passport);
    expect(changed.sizeConfirmed, isTrue);
    expect(changed.pageIndex, 0);
    expect(changed.width, 90);
  });

  test('with an approved crop, a category change applies its catalog size', () {
    final typed = DocumentEdits.setKind(
      _project().copyWith(assets: [_croppedAsset()]),
      'doc',
      DocumentKind.passport,
    );
    final changed = DocumentEdits.setKind(
      typed,
      'doc',
      DocumentKind.rationCard,
    );
    final item = PageLayout.item(changed, 'doc');
    expect([item.width, item.height], [287, 52]);
    expect(item.sizeConfirmed, isTrue);
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

  // Spec change (PR #39 F-C, A4 matrix): a typed size is a deliberate size. It
  // survives a change to "unknown" as well, because an unknown kind is not an
  // invalid crop. An unconfirmed document still goes off the sheet.
  test(
    '"unknown" keeps a typed size; an unconfirmed document leaves the sheet',
    () {
      final p = DocumentEdits.setKind(_project(), 'doc', DocumentKind.passport);
      final typed = DocumentEdits.resize(p, 'doc', width: 125);
      final item = PageLayout.item(typed, 'doc');
      final onSheet = item.copyWith(pageIndex: 0, x: 10, y: 10);
      final placed = typed.copyWith(items: [onSheet]);
      final u = DocumentEdits.setKind(placed, 'doc', DocumentKind.unknown);
      final unknown = PageLayout.item(u, 'doc');
      expect(unknown.sizeConfirmed, isTrue);
      expect(unknown.pageIndex, 0);
      expect([unknown.width, unknown.height], [125, 88]);

      final unconfirmed = _project().copyWith(
        items: [
          PageLayout.item(_project(), 'doc').copyWith(
            documentKind: DocumentKind.passport,
            pageIndex: 0,
            x: 10,
            y: 10,
          ),
        ],
      );
      final left = DocumentEdits.setKind(
        unconfirmed,
        'doc',
        DocumentKind.unknown,
      );
      expect(PageLayout.item(left, 'doc').pageIndex, isNull);
      expect(PageLayout.item(left, 'doc').sizeConfirmed, isFalse);
    },
  );

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

  test('editing the catalog resizes every document of that category', () {
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
