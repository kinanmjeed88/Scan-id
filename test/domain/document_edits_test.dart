import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_edits.dart';
import 'package:scan_id/domain/document_kind.dart';
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

void main() {
  test('choosing a category applies its catalog size immediately', () {
    final p = DocumentEdits.setKind(
      _project(),
      'doc',
      DocumentKind.unifiedNationalId,
    );
    final item = PageLayout.item(p, 'doc');
    expect([item.width, item.height], [85.6, 53.98]);
    expect(item.sizeConfirmed, isTrue);
    expect(item.documentKind, DocumentKind.unifiedNationalId);
  });

  test('the catalog size follows the picture orientation', () {
    final p = DocumentEdits.setKind(_project(), 'doc', DocumentKind.rationCard);
    final item = PageLayout.item(p, 'doc');
    // The 400 × 250 picture is landscape, so the portrait card lies down.
    expect([item.width, item.height], [287, 52]);
  });

  test('"unknown" takes the document off the sheet, "other" keeps it', () {
    final placed =
        DocumentEdits.setKind(
          _project(),
          'doc',
          DocumentKind.passport,
        ).copyWith(
          items: [
            PageLayout.item(
              DocumentEdits.setKind(_project(), 'doc', DocumentKind.passport),
              'doc',
            ).copyWith(pageIndex: 0, x: 10, y: 10),
          ],
        );
    final unknown = PageLayout.item(
      DocumentEdits.setKind(placed, 'doc', DocumentKind.unknown),
      'doc',
    );
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
