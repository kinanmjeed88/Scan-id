import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';

import '../fixtures.dart';

void main() {
  final invalid = throwsA(isA<ValidationException>());

  test(
    'complete project round-trip retains physical layout and locked state',
    () {
      final project = projectFixture(
        assets: [assetFixture()],
        items: [itemFixture()],
      );
      final restored = Project.fromJson(
        jsonDecode(jsonEncode(project.toJson())),
      );
      expect(restored.toJson(), project.toJson());
      expect(restored.items.single.width, 85.6);
      expect(restored.items.single.rotation, 90);
      expect(restored.items.single.locked, isTrue);
      expect(restored.createdAt.isUtc, isTrue);
    },
  );

  test('all model collections are defensive immutable copies', () {
    final input = [assetFixture()];
    final project = projectFixture(assets: input);
    input.clear();
    expect(project.assets, hasLength(1));
    expect(() => project.assets.clear(), throwsUnsupportedError);
    expect(
      () => project.assets.single.transforms.add('rotate'),
      throwsUnsupportedError,
    );
    expect(() => project.items.add(itemFixture()), throwsUnsupportedError);
  });

  test('unknown schemas are not silently downgraded', () {
    final json = projectFixture().toJson()..['schemaVersion'] = 2;
    expect(() => Project.fromJson(json), invalid);
    expect(json['schemaVersion'], 2);
  });

  test('malformed types, dates, enums, and missing fields are rejected', () {
    for (final change in <String, Object?>{
      'name': 42,
      'createdAt': 'not-a-date',
      'revision': 1.5,
      'assets': null,
      'paper': {'orientation': 'custom', 'margins': Margins().toJson()},
    }.entries) {
      final json = projectFixture().toJson()..[change.key] = change.value;
      expect(() => Project.fromJson(json), invalid, reason: change.key);
    }
  });

  test('dangling asset references and duplicate IDs are rejected', () {
    expect(() => projectFixture(items: [itemFixture()]), invalid);
    expect(
      () => projectFixture(assets: [assetFixture(), assetFixture()]),
      invalid,
    );
    expect(
      () => projectFixture(
        assets: [assetFixture()],
        items: [itemFixture(), itemFixture()],
      ),
      invalid,
    );
  });

  test('cross-project file references are rejected', () {
    expect(
      () => projectFixture(assets: [assetFixture(projectId: 'another')]),
      invalid,
    );
  });

  test('unsafe imported metadata paths cannot escape app storage', () {
    for (final path in [
      '../secret',
      '/tmp/file',
      'C:/id.png',
      'a\\b',
      'a/../b',
      'a//b',
      './image.png',
      'file://a',
      'a/\u0000b',
      'a/%2e%2e/b',
    ]) {
      expect(() => validAssetPath(path), invalid, reason: path);
    }
    expect(
      () => validAssetPath('projects/id/assets/asset/original.png'),
      returnsNormally,
    );
  });

  test('paths are separate and IDs are path-safe', () {
    expect(() => validId('../outside'), invalid);
    expect(() => validId(''), invalid);
    expect(
      () => ImageAsset(
        id: 'asset',
        name: 'image',
        originalPath: 'same.png',
        workingPath: 'same.png',
        thumbnailPath: 'thumb.jpg',
        width: 1,
        height: 1,
      ),
      invalid,
    );
  });

  test(
    'dimensions, finite values, names and margins validated in constructors',
    () {
      expect(
        () => DocumentItem(
          id: 'i',
          assetId: 'a',
          x: double.nan,
          y: 0,
          width: 2,
          height: 3,
        ),
        invalid,
      );
      expect(
        () => DocumentItem(
          id: 'i',
          assetId: 'a',
          x: 0,
          y: 0,
          width: 0,
          height: 3,
        ),
        invalid,
      );
      expect(() => LayoutSettings(horizontalGap: double.infinity), invalid);
      expect(() => projectFixture().copyWith(name: '   '), invalid);
      expect(
        () => PaperSettings(margins: Margins(left: 105, right: 105)),
        invalid,
      );
      expect(() => Margins(top: -1), invalid);
      expect(() => ExportProfile(dpi: 72), invalid);
      expect(() => ExportProfile(jpegQuality: 101), invalid);
    },
  );

  test('image and crop allocation budgets cannot overflow native integers', () {
    final json = assetFixture().toJson()
      ..['width'] = 1 << 32
      ..['height'] = 1 << 32;
    expect(() => ImageAsset.fromJson(json), invalid);
    expect(
      () => CropGeometry(
        corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
        outputWidth: 1 << 32,
        outputHeight: 1 << 32,
      ),
      invalid,
    );
  });
  test('A4 orientation and printable coordinates use mm', () {
    final portrait = PaperSettings();
    final landscape = PaperSettings(orientation: PaperOrientation.landscape);
    expect([portrait.width, portrait.height], [210, 297]);
    expect([landscape.width, landscape.height], [297, 210]);
    expect(portrait.printable.width, 190);
    expect(portrait.printable.height, 277);
    expect(portrait.printable.contains(RectMm(10, 10, 190, 277)), isTrue);
    expect(portrait.printable.contains(RectMm(9, 10, 190, 277)), isFalse);
  });
}
