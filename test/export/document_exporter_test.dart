import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/safe_files.dart';
import '../fixtures.dart';

void main() {
  late Directory root;
  late LocalAssetRepository assets;
  late Project project;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-export-test-');
    assets = LocalAssetRepository(SafeFiles(root));
    final image = img.Image(width: 100, height: 60);
    for (var y = 0; y < 60; y++) {
      for (var x = 0; x < 100; x++) {
        image.setPixelRgb(x, y, x < 50 ? 255 : 0, 0, x < 50 ? 0 : 255);
      }
    }
    final asset = await assets.importImage(
      'project1',
      'colors.png',
      img.encodePng(image),
    );
    project = projectFixture(assets: [asset]).copyWith(
      pageCount: 2,
      items: [
        DocumentItem(
          id: 'a',
          assetId: asset.id,
          x: 20,
          y: 30,
          width: 50,
          height: 30,
          sizeConfirmed: true,
        ),
        DocumentItem(
          id: 'b',
          assetId: asset.id,
          x: 60,
          y: 70,
          width: 50,
          height: 30,
          rotation: 90,
          pageIndex: 1,
          sizeConfirmed: true,
        ),
      ],
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  /// Anything left behind inside the dedicated export directory.
  Future<List<String>> leftovers() async {
    final exports = Directory('${root.path}/$exportDirectoryName');
    if (!await exports.exists()) {
      return const [];
    }
    final entries = await exports.list().toList();
    return [for (final entity in entries) entity.path];
  }

  Future<Project> containedProject({int width = 1200, int height = 120}) async {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(0, 0, 255));
    img.fillRect(
      image,
      x1: 0,
      y1: 0,
      x2: width ~/ 2 - 1,
      y2: height - 1,
      color: img.ColorRgb8(255, 0, 0),
    );
    final asset = await assets.importImage(
      project.id,
      'synthetic-wide.png',
      img.encodePng(image),
    );
    return project.copyWith(
      assets: [asset],
      items: [
        DocumentItem(
          id: 'contained1',
          assetId: asset.id,
          x: 10,
          y: 10,
          width: 50.8,
          height: 50.8,
          sizeConfirmed: true,
        ),
        DocumentItem(
          id: 'contained2',
          assetId: asset.id,
          x: 10,
          y: 10,
          width: 101.6,
          height: 101.6,
          rotation: 90,
          pageIndex: 1,
          sizeConfirmed: true,
        ),
      ],
    );
  }

  test('Contained DPI warnings respect page selection', () async {
    final contained = await containedProject();
    final first = ExportPlan(contained, ExportProfile(dpi: 600), pages: [0]);
    expect(first.warnings.where((warning) => warning.contains('DPI')), isEmpty);
    expect(first.warnings, hasLength(1), reason: 'Keep the margin notice');
    final second = ExportPlan(contained, ExportProfile(dpi: 600), pages: [1]);
    expect(
      second.warnings.where((warning) => warning.contains('DPI')).single,
      contains('300 DPI'),
    );
    // Changing rotation does not change native density or the empty margins.
    final unrotated = contained.copyWith(
      items: [contained.items.last.copyWith(rotation: 0)],
    );
    expect(
      ExportPlan(unrotated, ExportProfile(dpi: 600), pages: [1]).warnings,
      second.warnings,
    );
  });

  test('PDF shares the largest selected contained raster', () async {
    final contained = await containedProject();
    final before = contained.toJson();
    final asset = contained.assets.single;
    final original = await assets.resolve(asset.originalPath);
    final working = await assets.resolve(asset.workingPath);
    final originalBefore = await original.readAsBytes();
    final workingBefore = await working.readAsBytes();
    final exporter = DocumentExporter(assets);
    await Directory('diagnostics').create(recursive: true);
    for (final selection in [
      (pages: [0], dpi: 300, width: 600, height: 60),
      (pages: [0], dpi: 600, width: 1200, height: 120),
      (pages: [0, 1], dpi: 300, width: 1200, height: 120),
    ]) {
      final result = await exporter.generate(
        ExportPlan(
          contained,
          ExportProfile(dpi: selection.dpi),
          pages: selection.pages,
        ),
        root,
      );
      final pdf = await File(result.files.single).readAsBytes();
      _expectEmbeddedSize(pdf, selection.width, selection.height);
      _expectA4MediaBoxes(pdf);
      if (selection.dpi == 300) {
        final name = selection.pages.length == 1 ? 'selected' : 'proof';
        await File(
          result.files.single,
        ).copy('diagnostics/export-contain-$name.pdf');
      }
    }
    final raster = await exporter.generate(
      ExportPlan(contained, ExportProfile(format: ExportFormat.png)),
      root,
    );
    for (var page = 0; page < 2; page++) {
      await File(
        raster.files[page],
      ).copy('diagnostics/export-contain-$page.png');
    }
    expect(contained.toJson(), before);
    expect(await original.readAsBytes(), originalBefore);
    expect(await working.readAsBytes(), workingBefore);
  });

  test('PDF integer resampling retains original physical aspect', () async {
    final contained = await containedProject(width: 2049, height: 113);
    final singlePage = contained.copyWith(
      pageCount: 1,
      items: [
        contained.items.first.copyWith(width: 50, height: 50, rotation: 90),
      ],
    );
    final result = await DocumentExporter(
      assets,
    ).generate(ExportPlan(singlePage, ExportProfile()), root);
    final pdf = await File(result.files.single).readAsBytes();
    _expectEmbeddedSize(pdf, 591, 33);
    await Directory('diagnostics').create(recursive: true);
    // verify_exports.py checks the image transform with an independent PDF
    // parser, including the difference between 2049:113 and 591:33.
    await File(
      result.files.single,
    ).copy('diagnostics/export-contain-rounding.pdf');
  });

  test('PDF never upscales a genuinely low density contained source', () async {
    final contained = await containedProject(width: 80, height: 8);
    final plan = ExportPlan(contained, ExportProfile(), pages: [0]);
    expect(
      plan.warnings.where((warning) => warning.contains('DPI')).single,
      contains('40 DPI'),
    );
    final result = await DocumentExporter(assets).generate(plan, root);
    _expectEmbeddedSize(
      await File(result.files.single).readAsBytes(),
      80,
      8,
      roundingSlack: 0,
    );
  });

  test(
    'export plan enforces placement and reports real source DPI without upscaling claims',
    () {
      final plan = ExportPlan(project, ExportProfile());
      expect(plan.warnings, hasLength(2));
      expect([plan.pixelWidth, plan.pixelHeight], [2480, 3508]);
      expect(
        () => ExportPlan(
          project.copyWith(
            items: [project.items.first.copyWith(sizeConfirmed: false)],
          ),
          ExportProfile(),
        ),
        throwsA(isA<ValidationException>()),
        reason: 'لا يجوز طباعة قياس غير مؤكد',
      );
      expect(
        () => ExportPlan(project.copyWith(items: []), ExportProfile()),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ExportPlan(
          project.copyWith(items: [project.items.first.copyWith(x: 500)]),
          ExportProfile(),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ExportPlan(project, ExportProfile(), pages: []),
        throwsA(isA<ValidationException>()),
      );
    },
  );
  test(
    'PDF generation writes an actual multipage file and never mutates source or layout',
    () async {
      final before = project.toJson();
      final source = await assets.resolve(project.assets.single.workingPath);
      final bytes = await source.readAsBytes();
      final result = await DocumentExporter(
        assets,
      ).generate(ExportPlan(project, ExportProfile()), root);
      expect(
        p.basename(result.files.single),
        'مستمسكات العائلة.pdf',
        reason: 'اسم الملف يحمل اسم المشروع',
      );
      expect(
        p.split(result.files.single),
        contains(exportDirectoryName),
        reason: 'التصدير داخل المجلد المخصص للمشاركة فقط',
      );
      final pdf = await File(result.files.single).readAsBytes();
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
      expect(pdf.length, greaterThan(500));
      _expectA4MediaBoxes(pdf);
      expect(await source.readAsBytes(), bytes);
      expect(project.toJson(), before);
      await Directory('diagnostics').create(recursive: true);
      await File(result.files.single).copy('diagnostics/export-proof.pdf');
      final high = await DocumentExporter(
        assets,
      ).generate(ExportPlan(project, ExportProfile(dpi: 600)), root);
      await File(high.files.single).copy('diagnostics/export-proof-600.pdf');
    },
  );
  test(
    'PNG and JPG at 300 DPI have correct pixels, positions and rotation on both pages',
    () async {
      await Directory('diagnostics').create(recursive: true);
      for (final format in [ExportFormat.png, ExportFormat.jpg]) {
        final result = await DocumentExporter(
          assets,
        ).generate(ExportPlan(project, ExportProfile(format: format)), root);
        expect(result.files, hasLength(2));
        expect(result.files.map(p.basename), [
          'مستمسكات العائلة-صفحة-1.${format == ExportFormat.png ? 'png' : 'jpg'}',
          'مستمسكات العائلة-صفحة-2.${format == ExportFormat.png ? 'png' : 'jpg'}',
        ], reason: 'اسم لكل صفحة مع رقمها');
        expect(result.files.toSet(), hasLength(2), reason: 'لا تعارض أسماء');
        for (var page = 0; page < 2; page++) {
          final bytes = await File(result.files[page]).readAsBytes();
          final image = img.decodeImage(bytes)!;
          expect([image.width, image.height], [2480, 3508]);
          final red = image.getPixel(
            ((page == 0 ? 25 : 85) / 25.4 * 300).round(),
            ((page == 0 ? 35 : 65) / 25.4 * 300).round(),
          );
          final blue = image.getPixel(
            ((page == 0 ? 65 : 85) / 25.4 * 300).round(),
            ((page == 0 ? 35 : 105) / 25.4 * 300).round(),
          );
          expect(red.r, greaterThan(245));
          expect(red.b, lessThan(10));
          expect(blue.b, greaterThan(245));
          expect(blue.r, lessThan(10));
          expect(image.getPixel(10, 10).r, 255);
          await File(
            result.files[page],
          ).copy('diagnostics/export-proof-300-${page + 1}.${format.name}');
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    '600 DPI portrait and landscape output sizes are physical A4, with embedded density',
    () async {
      await Directory('diagnostics').create(recursive: true);
      final p = project.copyWith(
        paper: PaperSettings(orientation: PaperOrientation.landscape),
      );
      final result = await DocumentExporter(assets).generate(
        ExportPlan(
          p,
          ExportProfile(format: ExportFormat.png, dpi: 600),
          pages: [0],
        ),
        root,
      );
      final bytes = await File(result.files.single).readAsBytes();
      final info = img.PngDecoder().startDecode(bytes)! as img.PngInfo;
      expect([info.width, info.height], [7016, 4961]);
      expect(info.pixelDimensions, img.PngPhysicalPixelDimensions.dpi(600));
      expect(ExportPlan(project, ExportProfile(dpi: 600)).pixelWidth, 4961);
      expect(ExportPlan(project, ExportProfile(dpi: 600)).pixelHeight, 7016);
      await File(result.files.single).copy('diagnostics/export-proof-600.png');
      final jpeg = await DocumentExporter(assets).generate(
        ExportPlan(
          p,
          ExportProfile(format: ExportFormat.jpg, dpi: 600),
          pages: [0],
        ),
        root,
      );
      final jpgBytes = await File(jpeg.files.single).readAsBytes();
      expect(ByteData.sublistView(jpgBytes).getUint16(14), 600);
      await File(jpeg.files.single).copy('diagnostics/export-proof-600.jpg');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'missing or corrupt working copies fail explicitly without producing a final artifact',
    () async {
      final source = await assets.resolve(project.assets.single.workingPath);
      await source.writeAsBytes([0, 1, 2]);
      await expectLater(
        DocumentExporter(
          assets,
        ).generate(ExportPlan(project, ExportProfile()), root),
        throwsA(isA<ValidationException>()),
      );
      expect(await leftovers(), isEmpty, reason: 'لا بقايا بعد فشل التصدير');
      await source.delete();
      await expectLater(
        DocumentExporter(
          assets,
        ).generate(ExportPlan(project, ExportProfile()), root),
        throwsA(anything),
      );
    },
  );

  test(
    'a square slot does not stretch a wide image; the margin stays blank',
    () async {
      final image = img.Image(width: 80, height: 40);
      img.fill(image, color: img.ColorRgb8(220, 0, 0));
      final asset = await assets.importImage(
        'project1',
        'wide.png',
        img.encodePng(image),
      );
      final placed = projectFixture(
        assets: [asset],
        items: [
          DocumentItem(
            id: 'box',
            assetId: asset.id,
            x: 10,
            y: 10,
            width: 40,
            height: 40,
            pageIndex: 0,
            sizeConfirmed: true,
          ),
        ],
      );
      final fitted = containedDocumentRect(
        itemX: 10,
        itemY: 10,
        itemWidth: 40,
        itemHeight: 40,
        imageWidth: asset.width,
        imageHeight: asset.height,
      );
      expect(fitted.width / fitted.height, closeTo(2, 1e-9));
      expect(
        fitted.y,
        closeTo(20, 1e-9),
        reason: 'the unused band is a margin',
      );
      final working = await assets.resolve(asset.workingPath);
      final raster = renderPage(
        ExportPlan(placed, ExportProfile(format: ExportFormat.png)),
        0,
        {asset.id: working.path},
      );
      final scale = 300 / 25.4;
      int pixel(double mm) => (mm * scale).floor();
      final margin = raster.getPixel(pixel(30), pixel(12));
      final center = raster.getPixel(pixel(30), pixel(30));
      expect(margin.r, greaterThan(240));
      expect(margin.g, greaterThan(240));
      expect(center.r, greaterThan(180));
      expect(center.g, lessThan(30));
    },
  );

  test(
    'a 90-degree rotation still contains a wide image; it does not fill the slot',
    () async {
      final image = img.Image(width: 80, height: 40);
      img.fill(image, color: img.ColorRgb8(220, 0, 0));
      final asset = await assets.importImage(
        'project1',
        'wide-rotated.png',
        img.encodePng(image),
      );
      final placed = projectFixture(
        assets: [asset],
        items: [
          DocumentItem(
            id: 'rot',
            assetId: asset.id,
            x: 80,
            y: 80,
            width: 40,
            height: 40,
            rotation: 90,
            pageIndex: 0,
            sizeConfirmed: true,
          ),
        ],
      );
      final working = await assets.resolve(asset.workingPath);
      final raster = renderPage(
        ExportPlan(placed, ExportProfile(format: ExportFormat.png)),
        0,
        {asset.id: working.path},
      );
      final scale = 300 / 25.4;
      int pixel(double mm) => (mm * scale).floor();
      // Slot center is (100, 100). After 90 degrees the 2:1 image is a
      // vertical 20 mm band. A fill would paint the side red; no rotation
      // would leave the vertical sample white.
      final center = raster.getPixel(pixel(100), pixel(100));
      final along = raster.getPixel(pixel(100), pixel(115));
      final side = raster.getPixel(pixel(115), pixel(100));
      expect(center.r, greaterThan(180));
      expect(center.g, lessThan(30));
      expect(along.r, greaterThan(180));
      expect(along.g, lessThan(30));
      expect(side.r, greaterThan(240));
      expect(side.g, greaterThan(240));
      expect(side.b, greaterThan(240));
    },
  );
}

/// Every page dictionary must be physical A4. Points are 72 per inch.
void _expectA4MediaBoxes(List<int> pdf) {
  final text = String.fromCharCodes(pdf);
  final boxes = RegExp(r'/MediaBox\s*\[([^\]]+)\]').allMatches(text).toList();
  expect(
    boxes,
    isNotEmpty,
    reason: 'PDF page size must be an explicit MediaBox',
  );
  const a4Width = 210 * 72 / 25.4;
  const a4Height = 297 * 72 / 25.4;
  for (final box in boxes) {
    final nums = RegExp(r'-?\d+(?:\.\d+)?')
        .allMatches(box.group(1)!)
        .map((match) => double.parse(match.group(0)!))
        .toList();
    expect(nums, hasLength(4));
    expect(nums[0], closeTo(0, 0.01));
    expect(nums[1], closeTo(0, 0.01));
    expect(nums[2], closeTo(a4Width, 0.05));
    expect(nums[3], closeTo(a4Height, 0.05));
  }
}

// Image dictionaries are outside the compressed raster streams. The independent
// PyMuPDF audit additionally verifies the actual image matrices and page pixels.
void _expectEmbeddedSize(
  Uint8List pdf,
  int width,
  int height, {
  int roundingSlack = 1,
}) {
  final text = String.fromCharCodes(pdf);
  final sizes = <(int, int)>[];
  for (final match in RegExp(r'<<(.*?)>>', dotAll: true).allMatches(text)) {
    final dictionary = match.group(1)!;
    if (!RegExp(r'/Subtype\s*/Image\b').hasMatch(dictionary)) continue;
    final w = RegExp(r'/Width\s+(\d+)').firstMatch(dictionary);
    final h = RegExp(r'/Height\s+(\d+)').firstMatch(dictionary);
    expect(w, isNotNull);
    expect(h, isNotNull);
    final size = (int.parse(w!.group(1)!), int.parse(h!.group(1)!));
    // pdf 3.12.0 creates a grayscale SMask even for an opaque PNG. Validate
    // both rasters but count only the RGB embedding used by the page widgets.
    expect(size.$1, inInclusiveRange(width, width + roundingSlack));
    expect(size.$2, inInclusiveRange(height, height + roundingSlack));
    if (RegExp(r'/ColorSpace\s*/DeviceRGB\b').hasMatch(dictionary)) {
      sizes.add(size);
    }
  }
  expect(sizes, hasLength(1), reason: 'One embedding shared across pages');
}
