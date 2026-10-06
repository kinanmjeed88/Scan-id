import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/ids.dart';
import 'package:scan_id/application/output_service.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_adjustments.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/packing.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

/// One uninterrupted workflow on real storage: import, crop, place copies on an
/// A4 sheet, pack, export PDF/PNG, back up, restore, reopen and delete.
void main() {
  late Directory root;
  late Directory workspace;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late LocalProjectBackups backups;
  late ProjectService service;

  Future<String> digest(String relative) async => sha256
      .convert(await (await assets.resolve(relative)).readAsBytes())
      .toString();

  Uint8List sample(int width, int height, int seed) {
    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(
          x,
          y,
          (x * 3 + seed) % 256,
          (y * 5 + seed) % 256,
          200,
        );
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  /// Every dependency is rebuilt around [projects], so a test can reopen the
  /// store and keep working through the same service, as the app does.
  void wireService() {
    assets = LocalAssetRepository(projects.files);
    backups = LocalProjectBackups(projects, projects.files);
    service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      backups: backups,
      maintenance: LocalStorageMaintenance(projects.files),
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_workflow_store_');
    workspace = await Directory.systemTemp.createTemp('scan_workflow_output_');
    projects = await LocalProjectRepository.open(root);
    wireService();
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
    await workspace.delete(recursive: true);
  });

  test(
    'import, crop, place copies, pack, export, back up, restore and delete',
    () async {
      // 1. Import two JPEG/PNG sources; the originals are stored byte-identical.
      var project = await service.create('ملف المستمسكات');
      final first = sample(600, 400, 7);
      final second = sample(400, 600, 11);
      final report = await service.importImages(project, [
        ImportSource('هوية.png', () => Stream.value(first)),
        ImportSource('إجازة.png', () => Stream.value(second)),
      ]);
      expect(report.imported, 2);
      expect(report.failures, isEmpty);
      project = report.project;
      final originalDigest = await digest(project.assets.first.originalPath);
      final originalSize = await (await assets.resolve(
        project.assets.first.originalPath,
      )).length();

      // 2. Crop the first source with perspective, rotation and tone changes.
      final recipe = ImageEditRecipe(
        CropGeometry(
          corners: [
            Point2(.04, .05),
            Point2(.96, .03),
            Point2(.97, .95),
            Point2(.03, .96),
          ],
          outputWidth: 520,
          outputHeight: 340,
        ),
        ImageAdjustments(brightness: .08, contrast: 1.15, quarterTurns: 1),
      );
      final cropped = await service.applyCrop(
        project,
        project.assets.first,
        recipe,
      );
      final asset = cropped.assets.first;
      expect(cropped.assets.first.id, project.assets.first.id);
      expect(asset.crop?.outputWidth, 520);
      expect(asset.crop?.outputHeight, 340);
      expect({asset.width, asset.height}, {520, 340});
      expect(await digest(asset.originalPath), originalDigest);
      expect(
        await (await assets.resolve(asset.originalPath)).length(),
        originalSize,
      );
      expect(asset.workingPath, isNot(project.assets.first.workingPath));
      expect(
        await (await assets.resolve(asset.workingPath)).length(),
        greaterThan(0),
      );
      project = cropped;

      // 3. Place the documents at their real sizes and add three more copies of
      //    the ID card, which start unplaced for the packing proposal.
      final cardItem = DocumentItem(
        id: newId(),
        assetId: project.assets.first.id,
        x: 10,
        y: 10,
        width: 85.6,
        height: 53.98,
        zIndex: 1,
      );
      final sheet = DocumentItem(
        id: newId(),
        assetId: project.assets.last.id,
        x: 10,
        y: 80,
        width: 100,
        height: 140,
        zIndex: 2,
      );
      project = await projects.save(
        PageLayout.addMany(project, [
          cardItem,
          sheet,
          ...PageLayout.copies(cardItem, 3, newId),
        ]),
      );
      expect(project.items.where((e) => e.pageIndex == null), hasLength(3));
      expect(project.paper.width, 210);
      expect(project.paper.height, 297);
      expect(project.paper.printable.width, 190);
      expect(project.paper.printable.height, 277);

      // 4. The proposal is deterministic, never changes sizes, keeps every
      //    placed rectangle inside the printable area and reports what is left.
      final proposal = proposePacking(
        project,
        includeLocked: false,
        allowRotation: false,
      );
      final again = proposePacking(
        project,
        includeLocked: false,
        allowRotation: false,
      );
      expect(again.result.toJson(), proposal.result.toJson());
      expect(inspectLayout(proposal.result), isEmpty);
      expect(
        proposal.result.items
            .where((e) => e.pageIndex != null)
            .every((e) => proposal.result.paper.printable.contains(e.bounds)),
        isTrue,
      );
      for (final before in project.items) {
        final after = PageLayout.item(proposal.result, before.id);
        expect(after.width, before.width);
        expect(after.height, before.height);
      }
      expect(
        proposal.unplaced.toSet(),
        proposal.result.items
            .where((e) => e.pageIndex == null)
            .map((e) => e.id)
            .toSet(),
      );
      project = await projects.save(proposal.result);

      // 5. Export the sheet: PDF keeps real A4 points, PNG keeps 300 DPI pixels.
      final pdfPlan = ExportPlan(
        project,
        ExportProfile(format: ExportFormat.pdf, dpi: 300),
      );
      final pdf = await DocumentExporter(assets).generate(pdfPlan, workspace);
      expect(
        pdf.files.single.split(Platform.pathSeparator).last,
        'ملف المستمسكات.pdf',
        reason: 'اسم الملف يشتق من اسم المشروع',
      );
      final pdfBytes = await File(pdf.files.single).readAsBytes();
      expect(
        String.fromCharCodes(pdfBytes.take(5)),
        '%PDF-',
        reason: 'the export must be a real PDF document',
      );
      final text = String.fromCharCodes(pdfBytes);
      expect(
        RegExp(r'/Type\s*/Page(?![s])').allMatches(text).length,
        pdfPlan.pages.length,
        reason: 'one PDF page object per exported sheet',
      );
      final boxes = _mediaBoxes(pdfBytes);
      expect(boxes, isNotEmpty, reason: 'the page size must be declared');
      for (final box in boxes) {
        expect(box.$1, closeTo(210 / 25.4 * 72, .05));
        expect(box.$2, closeTo(297 / 25.4 * 72, .05));
      }
      final pngPlan = ExportPlan(
        project,
        ExportProfile(format: ExportFormat.png, dpi: 300),
      );
      final png = await DocumentExporter(assets).generate(pngPlan, workspace);
      expect(
        png.files.single.split(Platform.pathSeparator).last,
        'ملف المستمسكات-صفحة-1.png',
        reason: 'اسم كل صفحة يحمل رقمها',
      );
      final decoded = img.decodePng(await File(png.files.single).readAsBytes());
      expect(decoded, isNotNull);
      expect(decoded!.width, 2480);
      expect(decoded.height, 3508);

      // 6. Full backup and restore as an independent copy.
      final backup = await backups.create(project, workspace);
      final restored = await backups.restore(backup);
      expect(restored.id, isNot(project.id));
      expect(restored.name, project.name);
      expect(restored.pageCount, project.pageCount);
      expect(restored.assets, hasLength(project.assets.length));
      for (var index = 0; index < project.assets.length; index++) {
        final before = project.assets[index];
        final after = restored.assets[index];
        expect(after.id, before.id);
        expect(after.name, before.name);
        expect(after.width, before.width);
        expect(after.height, before.height);
        expect(after.crop?.toJson(), before.crop?.toJson());
        expect(
          await digest(after.originalPath),
          await digest(before.originalPath),
        );
        expect(
          await digest(after.workingPath),
          await digest(before.workingPath),
        );
        expect(
          await digest(after.thumbnailPath),
          await digest(before.thumbnailPath),
        );
      }
      expect(
        restored.items.map(_geometry).toList(),
        project.items.map(_geometry).toList(),
      );
      expect(
        restored.items.map((e) => e.assetId).toSet(),
        project.items.map((e) => e.assetId).toSet(),
      );

      // 7. Hand the PDF over the way Android does: real files, real names, and
      //    files that outlive the call so the receiving application can read
      //    them. Nothing is saved to a user location in this path.
      late List<String> shared;
      final output = OutputService(
        generate: DocumentExporter(assets).generate,
        temporary: () async => workspace,
        save: (_, _) async => throw StateError('not saving in this step'),
        printPdf: (_, _) async => throw StateError('not printing in this step'),
        shareTarget: ShareTarget.shareSheet,
        share: (paths, mime) async {
          shared = paths;
          expect(mime, 'application/pdf');
          return true;
        },
      );
      final shareMessage = await output.output(
        pdfPlan,
        target: OutputTarget.share,
      );
      expect(shareMessage, contains('تطبيق المشاركة'));
      expect(shared, hasLength(1));
      expect(shared.single, endsWith('ملف المستمسكات.pdf'));
      expect(
        await File(shared.single).exists(),
        isTrue,
        reason: 'لا يُحذف ملف سُلم لتطبيق آخر',
      );
      expect(
        await File(shared.single).readAsBytes(),
        await File(pdf.files.single).readAsBytes(),
      );

      // 8. Reopen the store: the project and the restored copy survive exactly.
      await projects.close();
      projects = await LocalProjectRepository.open(root);
      wireService();
      expect((await projects.get(project.id)).toJson(), project.toJson());
      expect((await projects.get(restored.id)).toJson(), restored.toJson());

      // 9. Delete the restored copy: only its own files leave the app storage.
      final deletion = await service.deleteProject(restored);
      expect(deletion.warning, isNull);
      expect(
        await Directory('${root.path}/projects/${restored.id}').exists(),
        isFalse,
      );
      expect(
        await Directory('${root.path}/projects/${project.id}').exists(),
        isTrue,
      );
      await expectLater(
        projects.get(restored.id),
        throwsA(isA<StorageException>()),
      );
      expect((await service.findOrphans()).count, 0);
      expect(
        (await projects.get(project.id)).items,
        hasLength(project.items.length),
      );
    },
  );
}

List<(double, double)> _mediaBoxes(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final pattern = RegExp(
    r'/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)',
  );
  return [
    for (final match in pattern.allMatches(text))
      (
        double.parse(match.group(3)!) - double.parse(match.group(1)!),
        double.parse(match.group(4)!) - double.parse(match.group(2)!),
      ),
  ];
}

String _geometry(DocumentItem item) => jsonEncode([
  item.x,
  item.y,
  item.width,
  item.height,
  item.rotation,
  item.pageIndex,
  item.zIndex,
]);
