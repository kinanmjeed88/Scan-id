import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_adjustments.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/full_resolution_manual_crop.dart';
import 'package:scan_id/imaging/large_jpeg_plan.dart';
import 'package:scan_id/persistence/large_jpeg_scaler.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_recovery.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// Axis-aligned 2:1 region inside a square frame. On a 1000×1000 preview the
/// old path floors this to about 400×200. A full-density extract must not.
List<Point2> get _wideQuad => [
  Point2(0.2, 0.1),
  Point2(0.6, 0.1),
  Point2(0.6, 0.3),
  Point2(0.2, 0.3),
];

/// A tighter second crop. Replay must still read the original JPEG.
List<Point2> get _tighterQuad => [
  Point2(0.3, 0.2),
  Point2(0.5, 0.2),
  Point2(0.5, 0.3),
  Point2(0.3, 0.3),
];

/// Tilted but convex. A valid perspective must not be rejected or squared.
List<Point2> get _tiltedQuad => [
  Point2(0.20, 0.12),
  Point2(0.62, 0.10),
  Point2(0.58, 0.32),
  Point2(0.18, 0.30),
];

Uint8List _jpegSofOnly(int width, int height) => Uint8List.fromList([
  0xff,
  0xd8,
  0xff,
  0xc0,
  0,
  11,
  8,
  (height >> 8) & 255,
  height & 255,
  (width >> 8) & 255,
  width & 255,
  1,
  1,
  0x11,
  0,
  0xff,
  0xd9,
]);

Uint8List _jpegWithExifOrientation(int width, int height, int orientation) =>
    Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xe1,
      0x00,
      0x22,
      0x45,
      0x78,
      0x69,
      0x66,
      0x00,
      0x00,
      0x49,
      0x49,
      0x2a,
      0x00,
      0x08,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x12,
      0x01,
      0x03,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      orientation,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      ..._jpegSofOnly(width, height).skip(2),
    ]);

Uint8List _solidPng(int width, int height, int red, int green, int blue) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(red, green, blue));
  return Uint8List.fromList(img.encodePng(image));
}

ImageEditRecipe _recipe(
  List<Point2> corners, {
  int outputWidth = 400,
  int outputHeight = 200,
}) => ImageEditRecipe(
  CropGeometry(
    corners: corners,
    outputWidth: outputWidth,
    outputHeight: outputHeight,
  ),
  ImageAdjustments(),
);

class _RegionCall {
  const _RegionCall({
    required this.source,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.orientation,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final Uint8List source;
  final int sourceWidth;
  final int sourceHeight;
  final int orientation;
  final double left;
  final double top;
  final double right;
  final double bottom;
}

class _RecordingReader {
  _RecordingReader(this._pngForCall);
  final Uint8List Function(_RegionCall call) _pngForCall;
  final calls = <_RegionCall>[];

  Future<Uint8List> read({
    required Uint8List source,
    required int sourceWidth,
    required int sourceHeight,
    required int orientation,
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) async {
    final call = _RegionCall(
      source: Uint8List.fromList(source),
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      orientation: orientation,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
    calls.add(call);
    return _pngForCall(call);
  }
}

class _FakeScaler implements LargeJpegScaler {
  _FakeScaler(this.png);
  final Uint8List png;

  @override
  Future<Uint8List> scaleJpeg(Uint8List source, LargeJpegPlan plan) async =>
      png;
}

void main() {
  test('a tilted quad remaps into its own bounds without a new rectangle', () {
    final bounds = manualCropBounds(_tiltedQuad);
    expect(bounds.left, 0.18);
    expect(bounds.top, 0.10);
    expect(bounds.right, 0.62);
    expect(bounds.bottom, 0.32);
    final local = remapCornersIntoRegion(_tiltedQuad, bounds);
    expect(local[0].x, closeTo(0.02 / 0.44, 1e-9));
    expect(local[1].x, 1);
    expect(local[1].y, 0);
    expect(local[2].y, 1);
    expect(local[3].x, 0);
    expect(coversOrientedFrame(bounds), isFalse);
  });

  test('an oversized span is refused before any downsample', () {
    const bounds = (left: 0.05, top: 0.05, right: 0.95, bottom: 0.95);
    expect(
      () => requireFullResolutionCropFits(
        bounds: bounds,
        orientedWidth: 5000,
        orientedHeight: 5000,
      ),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('لن يُستخدم التصغير الصامت'),
        ),
      ),
    );
    expect(orientedPixelSize(4000, 5000, 6), (5000, 4000));
    expect(orientedPixelSize(4000, 5000, 1), (4000, 5000));
  });

  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late _RecordingReader reader;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-full-crop-');
    projects = await LocalProjectRepository.open(root);
    reader = _RecordingReader((call) {
      final wide = (call.right - call.left) > 0.3;
      return wide
          ? _solidPng(640, 320, 220, 20, 20)
          : _solidPng(320, 160, 20, 180, 40);
    });
    assets = LocalAssetRepository(
      projects.files,
      largeJpegScaler: _FakeScaler(_solidPng(1000, 1000, 20, 40, 220)),
    );
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ProjectService service() => ProjectService(
    projects,
    assets,
    imageEditor: LocalImageEditor(
      projects.files,
      readFullResolutionRegion: reader.read,
    ),
  );

  Future<Project> importLarge(
    Uint8List jpeg, {
    String name = 'كبير.jpg',
  }) async {
    final project = await service().create('قص كامل الدقة');
    final report = await service().importImages(project, [
      ImportSource(name, () => Stream.value(jpeg)),
    ]);
    expect(report.imported, 1);
    expect(report.project.assets.single.hasScaledLargeSource, isTrue);
    return report.project;
  }

  Future<List<int>> originalBytes(ImageAsset asset) async =>
      (await assets.resolve(asset.originalPath)).readAsBytes();

  Future<img.Image> workingImage(ImageAsset asset) async {
    final bytes = await (await assets.resolve(
      asset.workingPath,
    )).readAsBytes();
    return img.decodePng(bytes)!;
  }

  test('manual recrop uses the original JPEG, not the sample', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    final source = imported.assets.single;
    final before = source.workingPath;

    final cropped = await service().applyManualCrop(
      imported,
      source,
      _recipe(_wideQuad),
    );
    final asset = cropped.assets.single;
    final image = await workingImage(asset);

    expect(reader.calls, hasLength(1));
    expect(reader.calls.single.source, jpeg);
    expect(reader.calls.single.sourceWidth, 5000);
    expect(reader.calls.single.sourceHeight, 5000);
    expect(reader.calls.single.orientation, 1);
    expect(reader.calls.single.left, 0.2);
    expect(reader.calls.single.top, 0.1);
    expect(reader.calls.single.right, 0.6);
    expect(reader.calls.single.bottom, 0.3);
    expect([image.width, image.height], [640, 320]);
    expect(image.getPixel(320, 160).r, greaterThan(200));
    expect(image.getPixel(320, 160).b, lessThan(40));
    _expectCorners(asset.crop!.corners, _wideQuad);
    expect(asset.userAuthoredCrop, isTrue);
    expect(asset.originalPath, source.originalPath);
    expect(asset.workingPath, isNot(before));
    expect(asset.transforms, contains(startsWith('large-jpeg:')));
    expect(await originalBytes(asset), jpeg);
    // 2:1 measured pixels, not the ID-1 catalogue ratio and not the sample.
    expect(image.width / image.height, closeTo(2, 0.01));
    expect((image.width / image.height - 85.6 / 53.98).abs(), greaterThan(0.2));
  });

  test('a repeated crop still reads the original JPEG bytes', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    final first = await service().applyManualCrop(
      imported,
      imported.assets.single,
      _recipe(_wideQuad),
    );
    final second = await service().applyManualCrop(
      first,
      first.assets.single,
      _recipe(_tighterQuad, outputWidth: 200, outputHeight: 100),
    );
    final asset = second.assets.single;
    final image = await workingImage(asset);

    expect(reader.calls, hasLength(2));
    expect(reader.calls[1].source, jpeg);
    expect(reader.calls[1].left, 0.3);
    expect(reader.calls[1].right, 0.5);
    expect([image.width, image.height], [320, 160]);
    expect(image.getPixel(160, 80).g, greaterThan(150));
    expect(image.getPixel(160, 80).r, lessThan(40));
    _expectCorners(asset.crop!.corners, _tighterQuad);
    expect(await originalBytes(asset), jpeg);
  });

  test('rotation after a crop does not resample the preview', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    final cropped = await service().applyManualCrop(
      imported,
      imported.assets.single,
      _recipe(_wideQuad),
    );
    final turned = await service().createImageRevision(
      cropped,
      cropped.assets.single,
      ImageEditRecipe(
        cropped.assets.single.crop!,
        ImageAdjustments(quarterTurns: 1),
      ),
    );
    final image = await workingImage(turned);

    expect(reader.calls, hasLength(2));
    expect(reader.calls.last.source, jpeg);
    expect([image.width, image.height], [320, 640]);
    expect(image.getPixel(160, 320).r, greaterThan(200));
    expect(await originalBytes(turned), jpeg);
  });

  test('a user-imposed aspect is kept on the full-density extract', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    // 400/252 is the preview recipe's imposed ratio, not a pixel reshape of
    // the measured 2:1 quad into catalogue millimetres.
    final saved = await service().applyManualCrop(
      imported,
      imported.assets.single,
      _recipe(_wideQuad, outputWidth: 400, outputHeight: 252),
    );
    final image = await workingImage(saved.assets.single);

    expect(reader.calls.single.source, jpeg);
    expect(image.width / image.height, closeTo(400 / 252, 0.02));
    expect(image.width, greaterThan(450));
    expect(
      image.getPixel(image.width ~/ 2, image.height ~/ 2).r,
      greaterThan(200),
    );
  });

  test('EXIF orientation is passed through without remapping', () async {
    final jpeg = _jpegWithExifOrientation(4000, 5000, 6);
    assets = LocalAssetRepository(
      projects.files,
      largeJpegScaler: _FakeScaler(_solidPng(1000, 800, 20, 40, 220)),
    );
    final imported = await importLarge(jpeg, name: 'موجّه.jpg');
    final saved = await service().applyManualCrop(
      imported,
      imported.assets.single,
      _recipe(_wideQuad),
    );
    final call = reader.calls.single;

    expect(call.orientation, 6);
    expect(call.sourceWidth, 4000);
    expect(call.sourceHeight, 5000);
    expect(call.left, 0.2);
    expect(call.top, 0.1);
    expect(call.right, 0.6);
    expect(call.bottom, 0.3);
    expect(call.source, jpeg);
    expect((await workingImage(saved.assets.single)).width, 640);
  });

  test('a tilted quad is warped, not replaced by a rectangle', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    final saved = await service().applyManualCrop(
      imported,
      imported.assets.single,
      _recipe(_tiltedQuad, outputWidth: 420, outputHeight: 210),
    );
    final asset = saved.assets.single;

    expect(reader.calls.single.left, 0.18);
    expect(reader.calls.single.top, 0.10);
    expect(reader.calls.single.right, 0.62);
    expect(reader.calls.single.bottom, 0.32);
    _expectCorners(asset.crop!.corners, _tiltedQuad);
    expect(asset.width, greaterThan(500));
    expect((await workingImage(asset)).getPixel(200, 100).r, greaterThan(200));
  });

  test('an oversized region fails and leaves the files untouched', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    final source = imported.assets.single;
    final workingBefore = await (await assets.resolve(
      source.workingPath,
    )).readAsBytes();

    expect(
      () => service().applyManualCrop(
        imported,
        source,
        _recipe([
          Point2(0.05, 0.05),
          Point2(0.95, 0.05),
          Point2(0.95, 0.95),
          Point2(0.05, 0.95),
        ], outputWidth: 900, outputHeight: 900),
      ),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('لن يُستخدم التصغير الصامت'),
        ),
      ),
    );
    expect(reader.calls, isEmpty);
    expect(await originalBytes(source), jpeg);
    expect(
      await (await assets.resolve(source.workingPath)).readAsBytes(),
      workingBefore,
    );
    expect(
      (await projects.get(imported.id)).assets.single.workingPath,
      source.workingPath,
    );
  });

  test('the whole large frame is refused, not silently sampled', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    expect(
      () => service().applyManualCrop(
        imported,
        imported.assets.single,
        _recipe([
          Point2(0, 0),
          Point2(1, 0),
          Point2(1, 1),
          Point2(0, 1),
        ], outputWidth: 1000, outputHeight: 1000),
      ),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('الصورة الكاملة'),
        ),
      ),
    );
    expect(reader.calls, isEmpty);
  });

  test('a missing JPEG reader is an error, not a sample fallback', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    final plain = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
    );
    expect(
      () => plain.applyManualCrop(
        imported,
        imported.assets.single,
        _recipe(_wideQuad),
      ),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('لن يُستخدم التصغير الصامت'),
        ),
      ),
    );
  });

  test('cropped large JPEG recovery replays the original region', () async {
    final jpeg = _jpegSofOnly(5000, 5000);
    final imported = await importLarge(jpeg);
    final editor = LocalImageEditor(
      projects.files,
      readFullResolutionRegion: reader.read,
    );
    final cropped = await ProjectService(
      projects,
      assets,
      imageEditor: editor,
    ).applyManualCrop(imported, imported.assets.single, _recipe(_wideQuad));
    await (await assets.resolve(cropped.assets.single.workingPath)).delete();

    final repaired = await LocalProjectRecovery(
      projects,
      editor,
    ).rebuildDerived(cropped);
    final image = await workingImage(repaired.assets.single);

    expect(reader.calls, hasLength(2));
    expect(reader.calls.last.source, jpeg);
    expect(reader.calls.last.left, 0.2);
    expect([image.width, image.height], [640, 320]);
    expect(image.getPixel(320, 160).r, greaterThan(200));
    _expectCorners(repaired.assets.single.crop!.corners, _wideQuad);
    expect(await originalBytes(repaired.assets.single), jpeg);
  });

  test('an ordinary image does not go through the