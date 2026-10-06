import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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
        ),
      ],
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test(
    'export plan enforces placement and reports real source DPI without upscaling claims',
    () {
      final plan = ExportPlan(project, ExportProfile());
      expect(plan.warnings, hasLength(2));
      expect([plan.pixelWidth, plan.pixelHeight], [2480, 3508]);
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
      final pdf = await File(result.files.single).readAsBytes();
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
      expect(pdf.length, greaterThan(500));
      expect(await source.readAsBytes(), bytes);
      expect(project.toJson(), before);
      await Directory('diagnostics').create(recursive: true);
      await File(result.files.single).copy('diagnostics/export-proof.pdf');
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
      expect(
        await root
            .list()
            .where(
              (e) =>
                  e is Directory &&
                  e.path
                      .split(Platform.pathSeparator)
                      .last
                      .startsWith('scan-export-') &&
                  !e.path.endsWith(root.path),
            )
            .toList(),
        isEmpty,
      );
      await source.delete();
      await expectLater(
        DocumentExporter(
          assets,
        ).generate(ExportPlan(project, ExportProfile()), root),
        throwsA(anything),
      );
    },
  );
}
