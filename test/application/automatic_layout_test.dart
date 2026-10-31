import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/document_edits.dart';
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
    'legacy imports stay unknown when names and aspects resemble catalog kinds',
    () async {
      final bytes = img.encodePng(img.Image(width: 860, height: 540));
      final created = await service.create('synthetic import');
      final orderedProject = await projects.save(
        created.copyWith(
          layout: created.layout.copyWith(
            strategy: ArrangementStrategy.ordered,
          ),
        ),
      );
      final imported = await service.importImages(orderedProject, [
        ImportSource('Passport-scan.png', () => Stream.value(bytes)),
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
      expect(result.project.documents, isEmpty);
      expect(
        result.project.items.every((item) => item.documentId == null),
        isTrue,
      );
      expect(result.recognized, 0);
      expect(
        result.unplaced,
        0,
        reason: 'unknown sizes are not paper overflow',
      );
      expect(result.awaitingSize, 3);
      expect(result.notDetected, 3, reason: 'flat images have no boundary');
      expect(result.cropped, 0);
      expect(result.project.items.every((item) => !item.sizeConfirmed), isTrue);
      expect(
        result.project.items.every((item) => item.pageIndex == null),
        isTrue,
      );
      expect(
        result.project.items.every(
          (item) => item.documentKind == DocumentKind.unknown,
        ),
        isTrue,
      );
      expect(
        result.project.items.map((item) => item.assetId),
        imported.project.assets.map((asset) => asset.id),
      );
      expect(
        (await projects.get(created.id)).toJson(),
        result.project.toJson(),
      );
    },
  );

  test(
    'adding another document leaves previously placed documents unchanged',
    () async {
      final bytes = img.encodePng(img.Image(width: 860, height: 540));
      var project = await service.create('حفظ الترتيب الموجود');
      project = (await service.importImages(project, [
        ImportSource(
          'البطاقة الوطنية الموحدة الأولى.png',
          () => Stream.value(bytes),
        ),
      ])).project;
      final first = await service.arrangeImportedImages(project, [
        project.assets.single.id,
      ]);
      final existing = first.project.items.single;

      final imported = await service.importImages(first.project, [
        ImportSource(
          'البطاقة الوطنية الموحدة الثانية.png',
          () => Stream.value(bytes),
        ),
      ]);
      final second = await service.arrangeImportedImages(imported.project, [
        imported.project.assets.last.id,
      ]);

      expect(
        second.project.items
            .firstWhere((item) => item.id == existing.id)
            .toJson(),
        existing.toJson(),
      );
      expect(second.project.items, hasLength(2));
      expect(second.project.items.last.pageIndex, isNull);
      expect(second.project.items.last.documentKind, DocumentKind.unknown);
      expect(second.project.items.last.sizeConfirmed, isFalse);
      expect(inspectLayout(second.project), isEmpty);
    },
  );

  test('manual size confirmation preserves printable overflow', () async {
    final bytes = img.encodePng(img.Image(width: 300, height: 400));
    var project = await service.create('synthetic manual size');
    project = await projects.save(
      project.copyWith(paper: PaperSettings(margins: Margins.all(20))),
    );
    project = (await service.importImages(project, [
      ImportSource('IMG_2041.png', () => Stream.value(bytes)),
    ])).project;

    final report = await service.arrangeImportedImages(project, [
      project.assets.single.id,
    ]);
    final unclassified = report.project.items.single;
    expect(unclassified.documentKind, DocumentKind.unknown);
    expect(unclassified.sizeConfirmed, isFalse);

    final manuallySized = DocumentEdits.resize(
      report.project,
      unclassified.id,
      width: 180,
    );
    final arrangement = arrangeDocuments(manuallySized);
    final item = arrangement.result.items.single;
    expect(item.documentKind, DocumentKind.other);
    expect(item.sizeConfirmed, isTrue);
    expect([item.width, item.height], [180, 240]);
    expect(item.pageIndex, isNull);
    expect(arrangement.unplaced, contains(item.id));
    expect(
      unplacedDocumentMessage(arrangement.result, item),
      allOf(
        contains('لا يلائم المساحة القابلة للطباعة'),
        contains('بلا تصغير أو قص'),
      ),
    );
  });

  test('Phase 1B reprocessing is disabled unless explicitly enabled', () async {
    final bytes = img.encodePng(img.Image(width: 120, height: 90));
    final created = await service.create('بدون تعرف');
    final imported = await service.importImages(created, [
      ImportSource('photo.png', () => Stream.value(bytes)),
    ]);
    expect(imported.project.documents, isEmpty);

    final report = await service.reprocessImages(imported.project, [
      imported.project.assets.single.id,
    ]);

    expect(report, isNull);
    expect(
      (await projects.get(created.id)).toJson(),
      imported.project.toJson(),
    );
  });

  test(
    'a document-shaped scene gets a review-only boundary proposal',
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
      var project = await service.create('synthetic boundary');
      project = (await service.importImages(project, [
        ImportSource('IMG_2041.png', () => Stream.value(bytes)),
      ])).project;
      final originalPath = project.assets.single.originalPath;
      final report = await service.arrangeImportedImages(project, [
        project.assets.single.id,
      ]);
      final asset = report.project.assets.single;
      final item = report.project.items.single;
      expect(report.cropped, 0);
      expect(report.notDetected, 0);
      expect(report.boundaryNeedsReview, 1);
      expect(asset.crop, isNull);
      expect(asset.suggestedCrop, hasLength(4));
      expect(item.documentKind, DocumentKind.unknown);
      expect(item.sizeConfirmed, isFalse);
      expect(item.pageIndex, isNull);
      expect([asset.width, asset.height], [240, 170]);
      expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);
      expect(report.recognized, 0);
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
    expect(report.unplaced, 0);
    expect(report.awaitingSize, 1);
    expect(report.recognized, 0);
  });

  test('filename does not alter a review-only geometric proposal', () async {
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
    var project = await service.create('مراجعة يدوية');
    project = (await service.importImages(project, [
      ImportSource('البطاقة الوطنية الموحدة.png', () => Stream.value(bytes)),
    ])).project;
    final originalPath = project.assets.single.originalPath;
    final report = await service.arrangeImportedImages(project, [
      project.assets.single.id,
    ]);

    expect(report.cropped, 0);
    expect(report.notDetected, 0);
    expect(report.boundaryNeedsReview, 1);
    final asset = report.project.assets.single;
    expect(asset.crop, isNull);
    expect(asset.suggestedCrop, hasLength(4));
    expect(asset.userAuthoredCrop, isFalse);
    expect(asset.workingPath, project.assets.single.workingPath);
    expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);
    final item = report.project.items.single;
    expect(item.documentKind, DocumentKind.unknown);
    expect(item.pageIndex, isNull);
    expect(item.sizeConfirmed, isFalse);
    expect([asset.width, asset.height], [200, 140]);
    expect(report.recognized, 0);
  });
}
