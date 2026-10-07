import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late ProjectService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-auto-layout-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
    );
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  test(
    'labelled imports get catalog sizes and are arranged in category order',
    () async {
      final bytes = img.encodePng(img.Image(width: 860, height: 540));
      final created = await service.create('معاملة');
      final imported = await service.importImages(created, [
        ImportSource('جواز السفر.png', () => Stream.value(bytes)),
        ImportSource('بطاقة السكن.png', () => Stream.value(bytes)),
        ImportSource('البطاقة الوطنية الموحدة.png', () => Stream.value(bytes)),
      ]);
      final result = await service.arrangeImportedImages(
        imported.project,
        imported.project.assets.map((asset) => asset.id),
      );

      expect(result.project.paper.width, 210);
      expect(result.project.paper.height, 297);
      expect(result.project.items, hasLength(3));
      expect(result.recognized, 3);
      expect(result.unplaced, 0);
      expect(result.notDetected, 3, reason: 'flat images have no boundary');
      expect(result.cropped, 0);
      expect(result.project.items.every((item) => item.sizeConfirmed), isTrue);
      expect(result.project.items.every((item) => item.pageIndex == 0), isTrue);
      expect(inspectLayout(result.project), isEmpty);
      DocumentItem kind(DocumentKind kind) =>
          result.project.items.singleWhere((item) => item.documentKind == kind);
      final national = kind(DocumentKind.unifiedNationalId);
      final residence = kind(DocumentKind.residenceCard);
      final passport = kind(DocumentKind.passport);
      expect([national.width, national.height], [85.6, 53.98]);
      expect([residence.width, residence.height], [92.4, 62.8]);
      expect([passport.width, passport.height], [125, 88]);
      expect(national.y, 5, reason: 'the unified card opens the page');
      expect(residence.y, greaterThan(national.y));
      expect(passport.y, greaterThan(residence.y));
      expect(
        (await projects.get(created.id)).toJson(),
        result.project.toJson(),
      );
    },
  );

  test(
    'the boundary shape alone recognises a card and rectifies it exactly',
    () async {
      final source = img.Image(width: 240, height: 170);
      img.fill(source, color: img.ColorRgb8(60, 45, 30));
      img.fillRect(
        source,
        x1: 40,
        y1: 35,
        x2: 199,
        y2: 135,
        color: img.ColorRgb8(235, 235, 230),
      );
      final bytes = img.encodePng(source);
      var project = await service.create('شكل');
      project = (await service.importImages(project, [
        ImportSource('IMG_2041.png', () => Stream.value(bytes)),
      ])).project;
      final report = await service.arrangeImportedImages(project, [
        project.assets.single.id,
      ]);
      final asset = report.project.assets.single;
      final item = report.project.items.single;
      expect(report.cropped, 1);
      expect(item.documentKind, DocumentKind.unifiedNationalId);
      expect(asset.width / asset.height, closeTo(85.6 / 53.98, .02));
      expect(item.pageIndex, 0);
      expect(item.sizeConfirmed, isTrue);
    },
  );

  test('an unrecognised document waits off the sheet', () async {
    final bytes = img.encodePng(img.Image(width: 400, height: 400));
    var project = await service.create('غير معروف');
    project = (await service.importImages(project, [
      ImportSource('photo.png', () => Stream.value(bytes)),
    ])).project;
    final report = await service.arrangeImportedImages(project, [
      project.assets.single.id,
    ]);
    final item = report.project.items.single;
    expect(item.documentKind, DocumentKind.unknown);
    expect(item.pageIndex, isNull);
    expect(item.sizeConfirmed, isFalse);
    expect(report.unplaced, 1);
    expect(report.recognized, 0);
  });

  test(
    'detected boundaries create a reversible crop while source bytes stay intact',
    () async {
      final source = img.Image(width: 200, height: 140);
      img.fillRect(
        source,
        x1: 25,
        y1: 20,
        x2: 175,
        y2: 120,
        color: img.ColorRgb8(245, 245, 245),
      );
      final bytes = img.encodePng(source);
      var project = await service.create('قص آلي');
      project = (await service.importImages(project, [
        ImportSource('البطاقة الوطنية الموحدة.png', () => Stream.value(bytes)),
      ])).project;
      final originalPath = project.assets.single.originalPath;
      final report = await service.arrangeImportedImages(project, [
        project.assets.single.id,
      ]);

      expect(report.cropped, 1);
      expect(report.project.assets.single.crop, isNotNull);
      expect(
        report.project.assets.single.workingPath,
        isNot(project.assets.single.workingPath),
      );
      expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);
      expect(
        report.project.items.single.documentKind,
        DocumentKind.unifiedNationalId,
      );
      expect(report.project.items.single.pageIndex, 0);
      expect(report.project.items.single.sizeConfirmed, isTrue);
      final asset = report.project.assets.single;
      expect(
        asset.width / asset.height,
        closeTo(85.6 / 53.98, .02),
        reason: 'the crop is rectified to the ID-1 shape',
      );
    },
  );
}
