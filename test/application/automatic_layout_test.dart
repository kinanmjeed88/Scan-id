import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/packing.dart';
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
    'imports are classified but unconfirmed sizes stay off the A4 sheet',
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
      expect(
        result.project.items.every((item) => item.pageIndex == null),
        isTrue,
      );
      expect(result.project.items.every((item) => !item.sizeConfirmed), isTrue);
      final national = result.project.items.singleWhere(
        (item) => item.documentKind == DocumentKind.unifiedNationalId,
      );
      final residence = result.project.items.singleWhere(
        (item) => item.documentKind == DocumentKind.residenceCard,
      );
      final passport = result.project.items.singleWhere(
        (item) => item.documentKind == DocumentKind.passport,
      );

      expect([national.width, national.height], [86, 54]);
      expect([passport.width, passport.height], [125, 88]);
      expect(residence.sizeConfirmed, isFalse);
      expect(result.unplaced, 3);
      expect(result.notDetected, 3);
      expect(result.cropped, 0);
      expect(result.warnings, hasLength(6));

      final confirmed = result.project.copyWith(
        items: [
          for (final item in result.project.items)
            item.copyWith(sizeConfirmed: true),
        ],
      );
      final proposal = proposePacking(
        confirmed,
        includeLocked: false,
        allowRotation: false,
        onlyUnplaced: true,
      );
      expect(
        proposal.result.items.every((item) => item.pageIndex == 0),
        isTrue,
      );
      expect(
        proposal.result.items.firstWhere((item) => item.id == national.id).x,
        10,
        reason: 'بعد تأكيد القياسات يبدأ الترتيب بالبطاقة الوطنية',
      );
      expect(
        proposal.result.items.firstWhere((item) => item.id == national.id).y,
        10,
      );
      expect(
        (await projects.get(created.id)).toJson(),
        result.project.toJson(),
      );
    },
  );

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
      expect(report.project.items.single.pageIndex, isNull);
      expect(report.project.items.single.sizeConfirmed, isFalse);
    },
  );
}
