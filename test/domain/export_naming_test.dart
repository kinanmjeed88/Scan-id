import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/export_naming.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/project.dart';
import '../fixtures.dart';

void main() {
  test('file names carry the project name so saved files are recognisable', () {
    final project = projectFixture(
      assets: [assetFixture()],
      items: [itemFixture().copyWith(x: 50, y: 50)],
    );
    final pdf = exportNames(
      ExportPlan(project, ExportProfile(format: ExportFormat.pdf)),
    );
    expect(pdf.document, 'مستمسكات العائلة.pdf');
    expect(pdf.pages, isEmpty);

    final png = exportNames(
      ExportPlan(
        project,
        ExportProfile(format: ExportFormat.png),
        pages: [0],
      ),
    );
    expect(png.document, isNull);
    expect(png.pages, ['مستمسكات العائلة-صفحة-1.png']);
  });

  test('every raster page gets its own name and none repeats', () {
    final project = projectFixture(
      assets: [assetFixture()],
      items: [itemFixture().copyWith(x: 50, y: 50)],
    ).copyWith(pageCount: 3);
    final names = exportNames(
      ExportPlan(project, ExportProfile(format: ExportFormat.jpg)),
    );
    expect(names.pages, [
      'مستمسكات العائلة-صفحة-1.jpg',
      'مستمسكات العائلة-صفحة-2.jpg',
      'مستمسكات العائلة-صفحة-3.jpg',
    ]);
    expect(names.pages.toSet(), hasLength(names.pages.length));
  });

  test('separators, control characters and trailing dots are removed', () {
    expect(exportBaseName(r'a/b\c:d*e?f"g<h>i|j'), 'a b c d e f g h i j');
    expect(exportBaseName('تقرير\u0000\u001f'), 'تقرير');
    expect(exportBaseName('  مسافات   كثيرة  '), 'مسافات كثيرة');
    expect(exportBaseName('نقاط...'), 'نقاط');
    expect(exportBaseName('اسم '), 'اسم');
    expect(exportBaseName('....'), 'مستمسكات', reason: 'اسم فارغ غير صالح');
  });

  test('reserved Windows device names never reach the file system', () {
    for (final reserved in ['con', 'CON', 'Prn', 'nul', 'COM1', 'lpt9']) {
      expect(exportBaseName(reserved), '_$reserved');
    }
    expect(exportBaseName('console'), 'console');
  });

  test('a very long name is shortened without splitting a character', () {
    final long = 'م' * 200;
    final base = exportBaseName(long);
    expect(base.length, 60);
    // A surrogate pair must never be cut in half.
    final cut = exportBaseName('${'a' * 59}😀${'b' * 10}');
    expect(cut, 'a' * 59);
    expect(cut.runes.length, cut.length, reason: 'لا وحدات بديلة يتيمة');
  });
}
