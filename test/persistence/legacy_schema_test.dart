import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

import '../legacy_schemas/v1_1c68dbc/geometry.dart' as v1g;
import '../legacy_schemas/v1_1c68dbc/project.dart' as v1;
import '../legacy_schemas/v1_1c68dbc/validation.dart' as v1v;
import '../legacy_schemas/v2_cd58739/geometry.dart' as v2g;
import '../legacy_schemas/v2_cd58739/image_adjustments.dart' as v2a;
import '../legacy_schemas/v2_cd58739/project.dart' as v2;
import '../legacy_schemas/v2_cd58739/validation.dart' as v2v;
import '../legacy_schemas/v3a_478e098/geometry.dart' as v3ag;
import '../legacy_schemas/v3a_478e098/image_adjustments.dart' as v3aa;
import '../legacy_schemas/v3a_478e098/project.dart' as v3a;
import '../legacy_schemas/v3a_478e098/validation.dart' as v3av;
import '../legacy_schemas/v3b_90de23c/geometry.dart' as v3bg;
import '../legacy_schemas/v3b_90de23c/image_adjustments.dart' as v3ba;
import '../legacy_schemas/v3b_90de23c/project.dart' as v3b;
import '../legacy_schemas/v3b_90de23c/validation.dart' as v3bv;
import '../legacy_schemas/v3c_64d146e/document_kind.dart' as v3ck;
import '../legacy_schemas/v3c_64d146e/geometry.dart' as v3cg;
import '../legacy_schemas/v3c_64d146e/image_adjustments.dart' as v3ca;
import '../legacy_schemas/v3c_64d146e/project.dart' as v3c;
import '../legacy_schemas/v3c_64d146e/validation.dart' as v3cv;

/// Projects saved by earlier releases open in this one.
///
/// Every stored format that ever shipped on `searchidf` is written by that
/// release's own, unmodified serialization code (test/legacy_schemas, copied
/// byte for byte from the commit in each directory name) into a real Sembast
/// database, exactly as its LocalProjectRepository stored it
/// (`store('projects').record(id).put(project.toJson())`). The current
/// repository must then open it, keep every value, leave the stored record
/// alone until the user saves, and upgrade it on save without touching any
/// image file. The old reader must refuse the upgraded record instead of
/// misreading it.
///
/// Five formats exist although the version number only reached 3: schema 3
/// was extended twice without a new number (`captureId` in 90de23c; the
/// document category, recognition confidence and size confirmation in
/// 3cf6a4f, merged as 64d146e).
void main() {
  for (final legacy in _formats) {
    test('${legacy.label} opens, keeps its data and upgrades on save', () async {
      final directory = await Directory.systemTemp.createTemp('scan_legacy_');
      addTearDown(() => directory.delete(recursive: true));
      final stored = legacy.write();
      expect(stored['schemaVersion'], legacy.schema);
      // The fixture is real: the release that wrote it reads it back.
      expect(() => legacy.read(stored), returnsNormally);

      final files = await _writeAssetFiles(directory);
      await _putRaw(directory, stored);

      var repository = await LocalProjectRepository.open(directory);
      expect((await repository.list()).single.id, _projectId);
      final opened = await repository.get(_projectId);
      _expectSameData(opened, legacy);
      await repository.close();

      // Opening never rewrites the stored record.
      expect(await _getRaw(directory), stored);

      repository = await LocalProjectRepository.open(directory);
      final saved = await repository.save(opened.copyWith(name: 'بعد الحفظ'));
      expect(saved.revision, 4);
      await repository.close();

      final upgraded = (await _getRaw(directory))!;
      expect(upgraded['schemaVersion'], Project.schemaVersion);
      expect(Project.fromJson(upgraded).toJson(), saved.toJson());
      // The release that wrote the project cannot open it any more, and says
      // so instead of misreading it.
      expect(() => legacy.read(upgraded), legacy.rejects);
      for (final entry in files.entries) {
        expect(
          await File('${directory.path}/${entry.key}').readAsString(),
          entry.value,
          reason: 'image files are never rewritten by an upgrade',
        );
      }
    });
  }
}

/// One stored project format and the release code that wrote it.
class _Format {
  const _Format(
    this.label, {
    required this.schema,
    required this.write,
    required this.read,
    required this.rejects,
    this.adjustments = false,
    this.colour = false,
    this.pages = false,
    this.capture = false,
    this.recognition = false,
  });

  final String label;
  final int schema;
  final Map<String, Object?> Function() write;
  final void Function(Map<String, Object?> json) read;
  final Matcher rejects;

  /// Stores brightness, contrast and quarter turns.
  final bool adjustments;

  /// Also stores saturation and sharpness.
  final bool colour;

  /// Stores pageCount and per-item pageIndex.
  final bool pages;

  /// Stores ImageAsset.captureId.
  final bool capture;

  /// Stores documentKind, recognitionConfidence and sizeConfirmed.
  final bool recognition;
}

final _formats = [
  _Format(
    'schema 1 (1c68dbc)',
    schema: 1,
    write: _v1,
    read: v1.Project.fromJson,
    rejects: throwsA(isA<v1v.ValidationException>()),
  ),
  _Format(
    'schema 2 (cd58739)',
    schema: 2,
    write: _v2,
    read: v2.Project.fromJson,
    rejects: throwsA(isA<v2v.ValidationException>()),
    adjustments: true,
  ),
  _Format(
    'schema 3, first form (478e098)',
    schema: 3,
    write: _v3a,
    read: v3a.Project.fromJson,
    rejects: throwsA(isA<v3av.ValidationException>()),
    adjustments: true,
    pages: true,
  ),
  _Format(
    'schema 3 with captureId (90de23c)',
    schema: 3,
    write: _v3b,
    read: v3b.Project.fromJson,
    rejects: throwsA(isA<v3bv.ValidationException>()),
    adjustments: true,
    pages: true,
    capture: true,
  ),
  _Format(
    'schema 3 with document categories (64d146e)',
    schema: 3,
    write: _v3c,
    read: v3c.Project.fromJson,
    rejects: throwsA(isA<v3cv.ValidationException>()),
    adjustments: true,
    colour: true,
    pages: true,
    capture: true,
    recognition: true,
  ),
];

const _projectId = 'legacy1';
const _assetId = 'asset1';
const _prefix = 'projects/$_projectId/assets/$_assetId';
const _name = 'مشروع من إصدار سابق';
const _assetName = 'بطاقة.jpg';
final _created = DateTime.utc(2026, 10, 6, 9);
final _updated = DateTime.utc(2026, 10, 6, 10);
const _corners = [(.1, .1), (.9, .12), (.88, .9), (.12, .88)];
const _transforms = ['exif-orientation', 'perspective-edit:edit1'];

Map<String, Object?> _v1() => v1.Project(
  id: _projectId,
  name: _name,
  createdAt: _created,
  updatedAt: _updated,
  revision: 3,
  paper: v1.PaperSettings(
    orientation: v1.PaperOrientation.landscape,
    margins: v1.Margins(top: 8, right: 9, bottom: 10, left: 11),
  ),
  layout: v1.LayoutSettings(
    horizontalGap: 4,
    verticalGap: 6,
    allowRotation: true,
    order: v1.LayoutOrder.area,
  ),
  exportProfile: v1.ExportProfile(
    format: v1.ExportFormat.png,
    dpi: 600,
    jpegQuality: 90,
  ),
  assets: [
    v1.ImageAsset(
      id: _assetId,
      name: _assetName,
      originalPath: '$_prefix/original.jpg',
      workingPath: '$_prefix/working.png',
      thumbnailPath: '$_prefix/thumb.jpg',
      width: 1600,
      height: 1000,
      crop: v1g.CropGeometry(
        corners: [for (final (x, y) in _corners) v1g.Point2(x, y)],
        outputWidth: 1200,
        outputHeight: 760,
      ),
      transforms: _transforms,
    ),
  ],
  items: [
    v1.DocumentItem(
      id: 'card',
      assetId: _assetId,
      x: 20,
      y: 25,
      width: 85.6,
      height: 53.98,
      rotation: 90,
      zIndex: 2,
      locked: true,
      keepAspectRatio: false,
    ),
    v1.DocumentItem(
      id: 'note',
      assetId: _assetId,
      x: 30,
      y: 120,
      width: 60,
      height: 40,
      zIndex: 1,
    ),
  ],
).toJson();

Map<String, Object?> _v2() => v2.Project(
  id: _projectId,
  name: _name,
  createdAt: _created,
  updatedAt: _updated,
  revision: 3,
  paper: v2.PaperSettings(
    orientation: v2.PaperOrientation.landscape,
    margins: v2.Margins(top: 8, right: 9, bottom: 10, left: 11),
  ),
  layout: v2.LayoutSettings(
    horizontalGap: 4,
    verticalGap: 6,
    allowRotation: true,
    order: v2.LayoutOrder.area,
  ),
  exportProfile: v2.ExportProfile(
    format: v2.ExportFormat.png,
    dpi: 600,
    jpegQuality: 90,
  ),
  assets: [
    v2.ImageAsset(
      id: _assetId,
      name: _assetName,
      originalPath: '$_prefix/original.jpg',
      workingPath: '$_prefix/working.png',
      thumbnailPath: '$_prefix/thumb.jpg',
      width: 1600,
      height: 1000,
      crop: v2g.CropGeometry(
        corners: [for (final (x, y) in _corners) v2g.Point2(x, y)],
        outputWidth: 1200,
        outputHeight: 760,
      ),
      adjustments: v2a.ImageAdjustments(
        brightness: .1,
        contrast: 1.2,
        quarterTurns: 1,
      ),
      transforms: _transforms,
    ),
  ],
  items: [
    v2.DocumentItem(
      id: 'card',
      assetId: _assetId,
      x: 20,
      y: 25,
      width: 85.6,
      height: 53.98,
      rotation: 90,
      zIndex: 2,
      locked: true,
      keepAspectRatio: false,
    ),
    v2.DocumentItem(
      id: 'note',
      assetId: _assetId,
      x: 30,
      y: 120,
      width: 60,
      height: 40,
      zIndex: 1,
    ),
  ],
).toJson();

Map<String, Object?> _v3a() => v3a.Project(
  id: _projectId,
  name: _name,
  createdAt: _created,
  updatedAt: _updated,
  revision: 3,
  pageCount: 2,
  paper: v3a.PaperSettings(
    orientation: v3a.PaperOrientation.landscape,
    margins: v3a.Margins(top: 8, right: 9, bottom: 10, left: 11),
  ),
  layout: v3a.LayoutSettings(
    horizontalGap: 4,
    verticalGap: 6,
    allowRotation: true,
    order: v3a.LayoutOrder.area,
  ),
  exportProfile: v3a.ExportProfile(
    format: v3a.ExportFormat.png,
    dpi: 600,
    jpegQuality: 90,
  ),
  assets: [
    v3a.ImageAsset(
      id: _assetId,
      name: _assetName,
      originalPath: '$_prefix/original.jpg',
      workingPath: '$_prefix/working.png',
      thumbnailPath: '$_prefix/thumb.jpg',
      width: 1600,
      height: 1000,
      crop: v3ag.CropGeometry(
        corners: [for (final (x, y) in _corners) v3ag.Point2(x, y)],
        outputWidth: 1200,
        outputHeight: 760,
      ),
      adjustments: v3aa.ImageAdjustments(
        brightness: .1,
        contrast: 1.2,
        quarterTurns: 1,
      ),
      transforms: _transforms,
    ),
  ],
  items: [
    v3a.DocumentItem(
      id: 'card',
      assetId: _assetId,
      x: 20,
      y: 25,
      width: 85.6,
      height: 53.98,
      rotation: 90,
      pageIndex: 1,
      zIndex: 2,
      locked: true,
      keepAspectRatio: false,
    ),
    v3a.DocumentItem(
      id: 'note',
      assetId: _assetId,
      x: 30,
      y: 120,
      width: 60,
      height: 40,
      pageIndex: null,
      zIndex: 1,
    ),
  ],
).toJson();

Map<String, Object?> _v3b() => v3b.Project(
  id: _projectId,
  name: _name,
  createdAt: _created,
  updatedAt: _updated,
  revision: 3,
  pageCount: 2,
  paper: v3b.PaperSettings(
    orientation: v3b.PaperOrientation.landscape,
    margins: v3b.Margins(top: 8, right: 9, bottom: 10, left: 11),
  ),
  layout: v3b.LayoutSettings(
    horizontalGap: 4,
    verticalGap: 6,
    allowRotation: true,
    order: v3b.LayoutOrder.area,
  ),
  exportProfile: v3b.ExportProfile(
    format: v3b.ExportFormat.png,
    dpi: 600,
    jpegQuality: 90,
  ),
  assets: [
    v3b.ImageAsset(
      id: _assetId,
      name: _assetName,
      originalPath: '$_prefix/original.jpg',
      workingPath: '$_prefix/working.png',
      thumbnailPath: '$_prefix/thumb.jpg',
      width: 1600,
      height: 1000,
      crop: v3bg.CropGeometry(
        corners: [for (final (x, y) in _corners) v3bg.Point2(x, y)],
        outputWidth: 1200,
        outputHeight: 760,
      ),
      captureId: 'capture1',
      adjustments: v3ba.ImageAdjustments(
        brightness: .1,
        contrast: 1.2,
        quarterTurns: 1,
      ),
      transforms: _transforms,
    ),
  ],
  items: [
    v3b.DocumentItem(
      id: 'card',
      assetId: _assetId,
      x: 20,
      y: 25,
      width: 85.6,
      height: 53.98,
      rotation: 90,
      pageIndex: 1,
      zIndex: 2,
      locked: true,
      keepAspectRatio: false,
    ),
    v3b.DocumentItem(
      id: 'note',
      assetId: _assetId,
      x: 30,
      y: 120,
      width: 60,
      height: 40,
      pageIndex: null,
      zIndex: 1,
    ),
  ],
).toJson();

Map<String, Object?> _v3c() => v3c.Project(
  id: _projectId,
  name: _name,
  createdAt: _created,
  updatedAt: _updated,
  revision: 3,
  pageCount: 2,
  paper: v3c.PaperSettings(
    orientation: v3c.PaperOrientation.landscape,
    margins: v3c.Margins(top: 8, right: 9, bottom: 10, left: 11),
  ),
  layout: v3c.LayoutSettings(
    horizontalGap: 4,
    verticalGap: 6,
    allowRotation: true,
    order: v3c.LayoutOrder.area,
  ),
  exportProfile: v3c.ExportProfile(
    format: v3c.ExportFormat.png,
    dpi: 600,
    jpegQuality: 90,
  ),
  assets: [
    v3c.ImageAsset(
      id: _assetId,
      name: _assetName,
      originalPath: '$_prefix/original.jpg',
      workingPath: '$_prefix/working.png',
      thumbnailPath: '$_prefix/thumb.jpg',
      width: 1600,
      height: 1000,
      crop: v3cg.CropGeometry(
        corners: [for (final (x, y) in _corners) v3cg.Point2(x, y)],
        outputWidth: 1200,
        outputHeight: 760,
      ),
      captureId: 'capture1',
      adjustments: v3ca.ImageAdjustments(
        brightness: .1,
        contrast: 1.2,
        saturation: 1.1,
        sharpness: .3,
        quarterTurns: 1,
      ),
      transforms: _transforms,
    ),
  ],
  items: [
    v3c.DocumentItem(
      id: 'card',
      assetId: _assetId,
      x: 20,
      y: 25,
      width: 85.6,
      height: 53.98,
      rotation: 90,
      pageIndex: 1,
      zIndex: 2,
      locked: true,
      keepAspectRatio: false,
      documentKind: v3ck.DocumentKind.unifiedNationalId,
      recognitionConfidence: .98,
      sizeConfirmed: true,
    ),
    v3c.DocumentItem(
      id: 'note',
      assetId: _assetId,
      x: 30,
      y: 120,
      width: 60,
      height: 40,
      pageIndex: null,
      zIndex: 1,
    ),
  ],
).toJson();

void _expectSameData(Project p, _Format legacy) {
  expect(p.id, _projectId);
  expect(p.name, _name);
  expect(p.createdAt, _created);
  expect(p.updatedAt, _updated);
  expect(p.revision, 3);
  expect(p.pageCount, legacy.pages ? 2 : 1);
  expect(p.paper.orientation, PaperOrientation.landscape);
  expect(p.paper.margins.toJson(), {
    'top': 8,
    'right': 9,
    'bottom': 10,
    'left': 11,
  });
  expect(p.layout.horizontalGap, 4);
  expect(p.layout.verticalGap, 6);
  expect(p.layout.allowRotation, isTrue);
  expect(p.layout.order, LayoutOrder.area);
  expect(p.layout.strategy, ArrangementStrategy.ordered);
  expect(p.exportProfile.format, ExportFormat.png);
  expect(p.exportProfile.dpi, 600);
  expect(p.exportProfile.jpegQuality, 90);
  expect(p.catalog.toJson(), const DocumentSizeCatalog().toJson());

  final asset = p.assets.single;
  expect(asset.id, _assetId);
  expect(asset.name, _assetName);
  expect(asset.originalPath, '$_prefix/original.jpg');
  expect(asset.workingPath, '$_prefix/working.png');
  expect(asset.thumbnailPath, '$_prefix/thumb.jpg');
  expect([asset.width, asset.height], [1600, 1000]);
  expect([
    for (final c in asset.crop!.corners) (c.x, c.y),
  ], _corners);
  expect([asset.crop!.outputWidth, asset.crop!.outputHeight], [1200, 760]);
  expect(asset.transforms, _transforms);
  expect(asset.captureId, legacy.capture ? 'capture1' : isNull);
  final a = asset.adjustments;
  expect(a.brightness, legacy.adjustments ? .1 : 0);
  expect(a.contrast, legacy.adjustments ? 1.2 : 1);
  expect(a.quarterTurns, legacy.adjustments ? 1 : 0);
  expect(a.saturation, legacy.colour ? 1.1 : 1);
  expect(a.sharpness, legacy.colour ? .3 : 0);

  final card = p.items.firstWhere((e) => e.id == 'card');
  expect(card.assetId, _assetId);
  expect([card.x, card.y, card.width, card.height], [20, 25, 85.6, 53.98]);
  expect(card.rotation, 90);
  expect(card.zIndex, 2);
  expect(card.locked, isTrue);
  expect(card.keepAspectRatio, isFalse);
  if (legacy.recognition) {
    expect(card.documentKind, DocumentKind.unifiedNationalId);
    expect(card.recognitionConfidence, .98);
    expect(card.sizeConfirmed, isTrue);
    expect(card.pageIndex, 1);
  } else {
    // Older formats never recorded whether a size was measured. Since
    // 64d146e (before this branch) such documents open off the sheet with
    // their position and size kept, and the user confirms the category.
    expect(card.documentKind, DocumentKind.unknown);
    expect(card.recognitionConfidence, 0);
    expect(card.sizeConfirmed, isFalse);
    expect(card.pageIndex, isNull);
  }

  final note = p.items.firstWhere((e) => e.id == 'note');
  expect([note.x, note.y, note.width, note.height], [30, 120, 60, 40]);
  expect(note.zIndex, 1);
  expect(note.locked, isFalse);
  expect(note.keepAspectRatio, isTrue);
  expect(note.documentKind, DocumentKind.unknown);
  expect(note.sizeConfirmed, isFalse);
  expect(note.pageIndex, isNull);
}

/// The three files of the asset, with contents the test checks afterwards.
Future<Map<String, String>> _writeAssetFiles(Directory directory) async {
  final files = {
    '$_prefix/original.jpg': 'original bytes',
    '$_prefix/working.png': 'working bytes',
    '$_prefix/thumb.jpg': 'thumbnail bytes',
  };
  for (final entry in files.entries) {
    final file = File('${directory.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  return files;
}

final _store = stringMapStoreFactory.store('projects');

Future<void> _putRaw(Directory directory, Map<String, Object?> json) async {
  final db = await databaseFactoryIo.openDatabase(
    '${directory.path}/projects.db',
  );
  await _store.record(_projectId).put(db, json);
  await db.close();
}

Future<Map<String, Object?>?> _getRaw(Directory directory) async {
  final db = await databaseFactoryIo.openDatabase(
    '${directory.path}/projects.db',
  );
  final value = await _store.record(_projectId).get(db);
  await db.close();
  return value == null ? null : Map<String, Object?>.of(value);
}
