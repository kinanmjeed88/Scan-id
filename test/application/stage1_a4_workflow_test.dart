import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/intake_diagnostics.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_edits.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/safe_files.dart';

/// Provisional heuristic floor for non-white pixel presence inside a planned
/// A4 document slot.
///
/// Governance note: this constant is NOT an independently calibrated threshold
/// derived from a reference validation dataset and must not be cited alone as
/// proof of document detail; [_assertExportedPngDocumentDetail] pairs it with
/// luminance variance, dynamic range, and spatial edge-transition checks so
/// uniform gray or dark background crops are rejected.
const double kMinPlannedItemNonWhiteRatio = 0.08;

Future<Project> _importAndArrange(
  ProjectService service,
  Project project,
  List<ImportSource> sources,
) async {
  final beforeIds = project.assets.map((a) => a.id).toSet();
  final imported = await service.importImages(project, sources);
  final addedIds = [
    for (final asset in imported.project.assets)
      if (!beforeIds.contains(asset.id)) asset.id,
  ];
  return (await service.arrangeImportedImages(
    imported.project,
    addedIds,
  )).project;
}

/// Builds a synthetic dark-desk scene with 0, 1, or 2 structured regions (no PII).
Uint8List _syntheticScenePng({
  required int width,
  required int height,
  required List<({int left, int top, int right, int bottom})> regions,
}) {
  final canvas = img.Image(width: width, height: height);
  img.fill(canvas, color: img.ColorRgb8(58, 62, 68));
  for (var idx = 0; idx < regions.length; idx++) {
    final c = regions[idx];
    img.fillRect(
      canvas,
      x1: c.left,
      y1: c.top,
      x2: c.right,
      y2: c.bottom,
      color: img.ColorRgb8(244, 246, 248),
    );
    img.drawRect(
      canvas,
      x1: c.left + 2,
      y1: c.top + 2,
      x2: c.right - 2,
      y2: c.bottom - 2,
      color: img.ColorRgb8(18, 86, 78),
      thickness: 3,
    );
    final bandBottom = math.min(
      c.bottom - 6,
      c.top + ((c.bottom - c.top) * 0.24).round(),
    );
    img.fillRect(
      canvas,
      x1: c.left + 8,
      y1: c.top + 8,
      x2: c.right - 8,
      y2: bandBottom,
      color: idx.isEven
          ? img.ColorRgb8(22, 98, 128)
          : img.ColorRgb8(116, 58, 34),
    );
    for (var row = 0; row < 4; row++) {
      final y1 = bandBottom + 10 + row * 14;
      if (y1 + 6 >= c.bottom - 8) break;
      img.fillRect(
        canvas,
        x1: c.left + 14,
        y1: y1,
        x2: c.right - 24 - (row * 10),
        y2: y1 + 6,
        color: img.ColorRgb8(36, 40, 46),
      );
    }
  }
  return Uint8List.fromList(img.encodePng(canvas));
}

/// Encodes [upright] stored in raw sensor pixels such that applying EXIF
/// [orientation] (`1..8`) restores the upright visual orientation.
Uint8List _jpegWithStoredExifOrientation(img.Image upright, int orientation) {
  final img.Image raw = switch (orientation) {
    1 => upright.clone(),
    2 => img.flipHorizontal(upright),
    3 => img.copyRotate(upright, angle: 180),
    4 => img.flipVertical(upright),
    5 => img.copyRotate(img.flipHorizontal(upright), angle: 270),
    6 => img.copyRotate(upright, angle: 270),
    7 => img.copyRotate(img.flipHorizontal(upright), angle: 90),
    8 => img.copyRotate(upright, angle: 90),
    _ => throw ArgumentError.value(orientation, 'orientation'),
  };
  raw.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(raw, quality: 95));
}

class _FailingDetectorEditor implements ImageEditor, CropBytesImageEditor {
  _FailingDetectorEditor(this._inner);
  final LocalImageEditor _inner;

  @override
  Future<EditorSource> open(ImageAsset asset) => _inner.open(asset);

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => null;

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) =>
      _inner.preview(asset, recipe);

  @override
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe) =>
      _inner.createRevision(asset, recipe);

  @override
  Future<Uint8List> renderCropBytes(ImageAsset asset, ImageEditRecipe recipe) =>
      _inner.renderCropBytes(asset, recipe);
}

class _RegionContentStats {
  const _RegionContentStats({
    required this.nonWhiteRatio,
    required this.luminanceStdDev,
    required this.luminanceRange,
    required this.lightSubstrateRatio,
    required this.darkFeatureRatio,
    required this.edgeTransitions,
  });

  final double nonWhiteRatio;
  final double luminanceStdDev;
  final double luminanceRange;
  final double lightSubstrateRatio;
  final double darkFeatureRatio;
  final int edgeTransitions;

  /// True only when the region carries genuine multi-tone document structure
  /// (substrate + darker features + spatial contrast transitions), rejecting
  /// pure white, uniform light-gray, and uniform dark-desk regions alike.
  bool get hasStructuredDetail =>
      nonWhiteRatio >= kMinPlannedItemNonWhiteRatio &&
      luminanceStdDev >= 10.0 &&
      luminanceRange >= 65.0 &&
      lightSubstrateRatio >= 0.08 &&
      darkFeatureRatio >= 0.02 &&
      edgeTransitions >= 10;
}

_RegionContentStats _measureRegionContent(
  img.Image pagePng, {
  required int left,
  required int top,
  required int right,
  required int bottom,
}) {
  final x0 = left.clamp(0, pagePng.width - 1);
  final y0 = top.clamp(0, pagePng.height - 1);
  final x1 = right.clamp(x0 + 1, pagePng.width);
  final y1 = bottom.clamp(y0 + 1, pagePng.height);

  var nonWhite = 0;
  var lightSubstrate = 0;
  var darkFeature = 0;
  var total = 0;
  var sumLum = 0.0;
  var sumLumSq = 0.0;
  var minLum = 255.0;
  var maxLum = 0.0;
  var transitions = 0;

  for (var y = y0; y < y1; y++) {
    double? prevLum;
    for (var x = x0; x < x1; x++) {
      final p = pagePng.getPixel(x, y);
      final lum = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b;
      total++;
      sumLum += lum;
      sumLumSq += lum * lum;
      if (lum < minLum) minLum = lum;
      if (lum > maxLum) maxLum = lum;
      if (p.r < 248 || p.g < 248 || p.b < 248) nonWhite++;
      if (lum >= 185.0) lightSubstrate++;
      if (lum <= 145.0) darkFeature++;
      if (prevLum != null && (lum - prevLum).abs() >= 28.0) {
        transitions++;
      }
      prevLum = lum;
    }
  }

  if (total == 0) {
    return const _RegionContentStats(
      nonWhiteRatio: 0,
      luminanceStdDev: 0,
      luminanceRange: 0,
      lightSubstrateRatio: 0,
      darkFeatureRatio: 0,
      edgeTransitions: 0,
    );
  }
  final mean = sumLum / total;
  final variance = math.max(0.0, (sumLumSq / total) - (mean * mean));
  return _RegionContentStats(
    nonWhiteRatio: nonWhite / total,
    luminanceStdDev: math.sqrt(variance),
    luminanceRange: maxLum - minLum,
    lightSubstrateRatio: lightSubstrate / total,
    darkFeatureRatio: darkFeature / total,
    edgeTransitions: transitions,
  );
}

/// 1. Geometric layout verification: item count, confirmed sizes, printable
/// bounds, and non-overlap on A4.
void _assertPlannedA4Geometry({
  required Project project,
  required int expectedPlannedItems,
}) {
  final plan = ExportPlan(
    project,
    ExportProfile(format: ExportFormat.png, dpi: 300),
  );
  final planned = plan.items(0);
  expect(planned, hasLength(expectedPlannedItems));
  expect(
    inspectLayout(project),
    isEmpty,
    reason: 'no disallowed overlap on A4',
  );
  for (var i = 0; i < planned.length; i++) {
    final item = planned[i];
    expect(item.sizeConfirmed, isTrue);
    expect(item.documentKind, isNot(DocumentKind.unknown));
    expect(
      validDocumentSize(PhysicalSizeMm(item.width, item.height)),
      isA<PhysicalSizeMm>(),
    );
    expect(project.paper.printable.contains(item.bounds), isTrue);
    for (var j = i + 1; j < planned.length; j++) {
      expect(item.bounds.overlaps(planned[j].bounds), isFalse);
    }
  }
}

/// 2. Visual content-detail verification on rendered A4 PNG: pure-white page
/// margins outside items + structured internal detail inside each item's
/// contained placement rect (not merely non-white/gray/dark background).
Future<void> _assertExportedPngDocumentDetail({
  required Project project,
  required LocalAssetRepository assets,
  required Directory exportDir,
}) async {
  final pngProfile = ExportProfile(format: ExportFormat.png, dpi: 300);
  final plan = ExportPlan(project, pngProfile);
  final planned = plan.items(0);
  final exporter = DocumentExporter(assets);
  final pngOut = await exporter.generate(plan, exportDir);
  final pngImage = img.decodePng(
    await File(pngOut.files.single).readAsBytes(),
  )!;
  expect(
    [pngImage.width, pngImage.height],
    [plan.pixelWidth, plan.pixelHeight],
  );

  final topMarginPx = millimetersToPixels(
    project.paper.margins.top * 0.8,
    pngProfile.dpi,
  ).floor();
  if (topMarginPx > 2) {
    final marginStats = _measureRegionContent(
      pngImage,
      left: 0,
      top: 0,
      right: pngImage.width,
      bottom: topMarginPx,
    );
    expect(
      marginStats.nonWhiteRatio,
      0.0,
      reason: 'A4 page margin outside items must stay pure white',
    );
  }

  for (final item in planned) {
    final asset = project.assets.firstWhere((a) => a.id == item.assetId);
    final slot = item.bounds;
    final placedRect = containedDocumentRect(
      itemX: slot.x,
      itemY: slot.y,
      itemWidth: slot.width,
      itemHeight: slot.height,
      imageWidth: item.rotation % 180 == 0 ? asset.width : asset.height,
      imageHeight: item.rotation % 180 == 0 ? asset.height : asset.width,
    );
    final left = millimetersToPixels(placedRect.x, pngProfile.dpi).round();
    final top = millimetersToPixels(placedRect.y, pngProfile.dpi).round();
    final right = millimetersToPixels(
      placedRect.x + placedRect.width,
      pngProfile.dpi,
    ).round();
    final bottom = millimetersToPixels(
      placedRect.y + placedRect.height,
      pngProfile.dpi,
    ).round();
    final stats = _measureRegionContent(
      pngImage,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
    expect(
      stats.hasStructuredDetail,
      isTrue,
      reason:
          'item ${item.id} (${item.documentKind.name}) must render internal '
          'document detail, not blank/uniform gray/dark pixels '
          '(nonWhite=${stats.nonWhiteRatio.toStringAsFixed(3)}, '
          'std=${stats.luminanceStdDev.toStringAsFixed(2)}, '
          'range=${stats.luminanceRange.toStringAsFixed(1)}, '
          'edges=${stats.edgeTransitions})',
    );
  }
}

class _ParsedPdfObject {
  const _ParsedPdfObject({required this.dict, this.decodedStream});
  final String dict;
  final String? decodedStream;
}

Map<int, _ParsedPdfObject> _parsePdfObjects(Uint8List pdfBytes) {
  final latin = latin1.decode(pdfBytes);
  final result = <int, _ParsedPdfObject>{};
  final objHeader = RegExp(r'(\d+)\s+0\s+obj\b');
  for (final match in objHeader.allMatches(latin)) {
    final id = int.parse(match.group(1)!);
    final bodyStart = match.end;
    final objEnd = latin.indexOf('endobj', bodyStart);
    if (objEnd < 0) continue;
    final body = latin.substring(bodyStart, objEnd);
    final streamStartMatch = RegExp(r'stream(?:\r\n|\n)').firstMatch(body);
    if (streamStartMatch == null) {
      result[id] = _ParsedPdfObject(dict: body);
      continue;
    }
    final dict = body.substring(0, streamStartMatch.start);
    final absStreamStart = bodyStart + streamStartMatch.end;
    final endStreamRel = body.lastIndexOf('endstream');
    if (endStreamRel < streamStartMatch.end) {
      result[id] = _ParsedPdfObject(dict: dict);
      continue;
    }
    var absStreamEnd = bodyStart + endStreamRel;
    final directLen = RegExp(r'/Length\s+(\d+)\b(?!\s+0\s+R)').firstMatch(dict);
    if (directLen != null) {
      final declared = int.parse(directLen.group(1)!);
      if (absStreamStart + declared <= absStreamEnd) {
        absStreamEnd = absStreamStart + declared;
      }
    } else {
      if (absStreamEnd >= 2 &&
          pdfBytes[absStreamEnd - 2] == 13 &&
          pdfBytes[absStreamEnd - 1] == 10) {
        absStreamEnd -= 2;
      } else if (absStreamEnd >= 1 &&
          (pdfBytes[absStreamEnd - 1] == 10 ||
              pdfBytes[absStreamEnd - 1] == 13)) {
        absStreamEnd -= 1;
      }
    }
    final rawSlice = Uint8List.sublistView(
      pdfBytes,
      absStreamStart,
      absStreamEnd,
    );
    String? decoded;
    if (RegExp(r'/Filter\s*(?:\[\s*)?/FlateDecode\b').hasMatch(dict)) {
      try {
        decoded = latin1.decode(zlib.decode(rawSlice), allowInvalid: true);
      } catch (_) {
        decoded = null;
      }
    } else {
      decoded = latin1.decode(rawSlice, allowInvalid: true);
    }
    result[id] = _ParsedPdfObject(dict: dict, decodedStream: decoded);
  }
  return result;
}

/// 3. Structural PDF export verification: A4 MediaBox in points, unique
/// `/DeviceRGB` `/Subtype /Image` XObject count (respecting shared `assetId`),
/// `/XObject` resource-dictionary linkage, and decompressed page content stream
/// `cm` transformation matrices + `/Name Do` invocations.
///
/// Honest scope note: this verifies PDF structure, resource binding, and page
/// stream placement in pure Dart; independent pixel rasterization of PDF pages
/// (`PyMuPDF` / `fitz` in `tool/verify_exports.py`) requires Python packages
/// not installed in the local sandbox.
Future<void> _assertExportedPdfStructureAndStreamPlacement({
  required Project project,
  required LocalAssetRepository assets,
  required Directory exportDir,
  required int expectedPlannedItems,
}) async {
  final pdfPlan = ExportPlan(
    project,
    ExportProfile(format: ExportFormat.pdf, dpi: 300),
  );
  final planned = pdfPlan.items(0);
  expect(planned, hasLength(expectedPlannedItems));
  final uniqueAssetIds = planned.map((i) => i.assetId).toSet();

  final exporter = DocumentExporter(assets);
  final pdfOut = await exporter.generate(pdfPlan, exportDir);
  final pdfBytes = await File(pdfOut.files.single).readAsBytes();
  expect(String.fromCharCodes(pdfBytes.take(5)), '%PDF-');

  final objects = _parsePdfObjects(pdfBytes);
  expect(objects, isNotEmpty);

  // Verify A4 MediaBox (210 x 297 mm -> 595.28 x 841.89 pt).
  const a4WidthPt = 210.0 * 72.0 / 25.4;
  const a4HeightPt = 297.0 * 72.0 / 25.4;
  final pageObjects = objects.entries
      .where((e) => RegExp(r'/Type\s*/Page\b(?!s)').hasMatch(e.value.dict))
      .toList();
  expect(pageObjects, hasLength(pdfPlan.pages.length));

  final rgbImageObjIds = <int>{
    for (final entry in objects.entries)
      if (RegExp(r'/Subtype\s*/Image\b').hasMatch(entry.value.dict) &&
          RegExp(r'/ColorSpace\s*/DeviceRGB\b').hasMatch(entry.value.dict))
        entry.key,
  };
  expect(
    rgbImageObjIds,
    hasLength(uniqueAssetIds.length),
    reason: 'one DeviceRGB Image XObject per unique referenced assetId',
  );

  // Map resource names (/Im1, /Image2, ...) -> object ID across dictionaries.
  final imageResourceNames = <String>{};
  for (final entry in objects.values) {
    for (final m in RegExp(
      r'/([A-Za-z0-9_.-]+)\s+(\d+)\s+0\s+R\b',
    ).allMatches(entry.dict)) {
      final resName = m.group(1)!;
      final targetObj = int.parse(m.group(2)!);
      if (rgbImageObjIds.contains(targetObj)) {
        imageResourceNames.add(resName);
      }
    }
  }
  expect(
    imageResourceNames,
    isNotEmpty,
    reason: 'RGB Image XObjects must be bound in /Resources /XObject',
  );

  final page0 = pageObjects.first.value.dict;
  final mediaBoxMatch =
      RegExp(r'/MediaBox\s*\[([^\]]+)\]').firstMatch(page0) ??
      objects.values
          .map((o) => RegExp(r'/MediaBox\s*\[([^\]]+)\]').firstMatch(o.dict))
          .whereType<RegExpMatch>()
          .firstOrNull;
  expect(mediaBoxMatch, isNotNull);
  final boxNums = RegExp(r'-?\d+(?:\.\d+)?')
      .allMatches(mediaBoxMatch!.group(1)!)
      .map((m) => double.parse(m.group(0)!))
      .toList();
  expect(boxNums, hasLength(4));
  expect(boxNums[0], closeTo(0, 0.01));
  expect(boxNums[1], closeTo(0, 0.01));
  expect(boxNums[2], closeTo(a4WidthPt, 0.05));
  expect(boxNums[3], closeTo(a4HeightPt, 0.05));

  // Resolve /Contents stream(s) of page 0 and verify `/Name Do` + `cm` matrices.
  final contentIds = <int>[];
  final arrayContents = RegExp(r'/Contents\s*\[([^\]]+)\]').firstMatch(page0);
  if (arrayContents != null) {
    for (final r in RegExp(
      r'(\d+)\s+0\s+R',
    ).allMatches(arrayContents.group(1)!)) {
      contentIds.add(int.parse(r.group(1)!));
    }
  } else {
    final singleContents = RegExp(
      r'/Contents\s+(\d+)\s+0\s+R',
    ).firstMatch(page0);
    expect(
      singleContents,
      isNotNull,
      reason: 'Page 0 must reference /Contents',
    );
    contentIds.add(int.parse(singleContents!.group(1)!));
  }

  final streamBuffer = StringBuffer();
  for (final cId in contentIds) {
    final decoded = objects[cId]?.decodedStream;
    expect(decoded, isNotNull, reason: 'Page content stream $cId must decode');
    streamBuffer.writeln(decoded);
  }
  final contentStream = streamBuffer.toString();

  final invokedImages = <String>[
    for (final m in RegExp(
      r'/([A-Za-z0-9_.-]+)\s+Do\b',
    ).allMatches(contentStream))
      if (imageResourceNames.contains(m.group(1)!)) m.group(1)!,
  ];
  expect(
    invokedImages,
    hasLength(expectedPlannedItems),
    reason: 'each planned item on A4 must execute a /XObject Do draw operator',
  );

  final cmMatrices = RegExp(
    r'(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+'
    r'(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+'
    r'(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+cm\b',
  ).allMatches(contentStream).toList();
  expect(
    cmMatrices.length,
    greaterThanOrEqualTo(expectedPlannedItems),
    reason: 'content stream must position/scale placed images via cm matrices',
  );
  for (final cm in cmMatrices) {
    for (var g = 1; g <= 6; g++) {
      expect(double.parse(cm.group(g)!).isFinite, isTrue);
    }
  }
}

Future<void> _assertAllThreeExportLayers({
  required Project project,
  required LocalAssetRepository assets,
  required Directory exportDir,
  required int expectedPlannedItems,
}) async {
  _assertPlannedA4Geometry(
    project: project,
    expectedPlannedItems: expectedPlannedItems,
  );
  await _assertExportedPngDocumentDetail(
    project: project,
    assets: assets,
    exportDir: exportDir,
  );
  await _assertExportedPdfStructureAndStreamPlacement(
    project: project,
    assets: assets,
    exportDir: exportDir,
    expectedPlannedItems: expectedPlannedItems,
  );
}

void main() {
  test(
    'content-detail verifier rejects pure-white, uniform-gray, and uniform-dark regions while accepting structured document crops',
    () {
      final white = img.Image(width: 240, height: 160);
      img.fill(white, color: img.ColorRgb8(255, 255, 255));
      expect(
        _measureRegionContent(
          white,
          left: 0,
          top: 0,
          right: 240,
          bottom: 160,
        ).hasStructuredDetail,
        isFalse,
      );

      // Uniform off-white/light-gray rectangle has nonWhiteRatio == 1.0, yet
      // carries zero internal document detail and MUST fail content verification.
      final uniformGray = img.Image(width: 240, height: 160);
      img.fill(uniformGray, color: img.ColorRgb8(232, 236, 240));
      final grayStats = _measureRegionContent(
        uniformGray,
        left: 0,
        top: 0,
        right: 240,
        bottom: 160,
      );
      expect(grayStats.nonWhiteRatio, 1.0);
      expect(grayStats.hasStructuredDetail, isFalse);

      // Uniform dark desk crop also has nonWhiteRatio == 1.0 and MUST fail.
      final uniformDark = img.Image(width: 240, height: 160);
      img.fill(uniformDark, color: img.ColorRgb8(58, 62, 68));
      expect(
        _measureRegionContent(
          uniformDark,
          left: 0,
          top: 0,
          right: 240,
          bottom: 160,
        ).hasStructuredDetail,
        isFalse,
      );

      final structuredBytes = _syntheticScenePng(
        width: 400,
        height: 260,
        regions: const [(left: 10, top: 10, right: 390, bottom: 250)],
      );
      final structuredImg = img.decodePng(structuredBytes)!;
      expect(
        _measureRegionContent(
          structuredImg,
          left: 10,
          top: 10,
          right: 390,
          bottom: 250,
        ).hasStructuredDetail,
        isTrue,
      );
    },
  );

  test(
    'Path A: imported source stays whole until explicit user confirmation, then exports placements',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('stage1_path_a_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final editor = LocalImageEditor(files);
      final service = ProjectService(projects, assets, imageEditor: editor);

      final fixtureBytes = File(
        'test/fixtures/synthetic_card.png',
      ).readAsBytesSync();

      var project = await service.create('Path A synthetic boundary');
      project = await _importAndArrange(service, project, [
        ImportSource('capture.png', () => Stream.value(fixtureBytes)),
      ]);
      expect(project.items.single.documentKind, DocumentKind.unknown);
      expect(project.items.single.sizeConfirmed, isFalse);
      expect(project.items.single.pageIndex, isNull);
      // Simulate a generic user confirmation; no type or print size is inferred.
      project = await projects.save(
        arrangeDocuments(
          DocumentEdits.setKind(
            project,
            project.items.single.id,
            DocumentKind.other,
          ),
        ).result,
      );
      expect(project.items.single.documentKind, DocumentKind.other);
      expect(project.items.single.sizeConfirmed, isTrue);
      expect(project.items.single.pageIndex, 0);

      final exportDir1 = await Directory(
        '${tempDir.path}/exp_a1',
      ).create(recursive: true);
      await _assertAllThreeExportLayers(
        project: project,
        assets: assets,
        exportDir: exportDir1,
        expectedPlannedItems: 1,
      );

      // Duplicate the placed item so 2 planned items share 1 assetId: PDF must
      // embed 1 shared DeviceRGB Image XObject while drawing 2 Do placements.
      final duplicated = arrangeDocuments(
        PageLayout.addMany(
          project,
          PageLayout.copies(project.items.single, 1, () => 'dup-item-2'),
        ),
      ).result;
      expect(duplicated.items, hasLength(2));
      expect(duplicated.items.map((i) => i.assetId).toSet(), hasLength(1));
      final exportDirShared = await Directory(
        '${tempDir.path}/exp_shared',
      ).create(recursive: true);
      await _assertAllThreeExportLayers(
        project: duplicated,
        assets: assets,
        exportDir: exportDirShared,
        expectedPlannedItems: 2,
      );

      // Case A2: a synthetic rectangle remains unknown. The following call
      // simulates an explicit generic user confirmation; it is not a human
      // label or evidence about the fixture.
      var project2 = await service.create('المسار A تأكيد المقاس');
      final nonCatalogScene = _syntheticScenePng(
        width: 500,
        height: 400,
        regions: const [(left: 70, top: 100, right: 430, bottom: 300)],
      );
      project2 = await _importAndArrange(service, project2, [
        ImportSource('IMG_20261022.png', () => Stream.value(nonCatalogScene)),
      ]);
      final itemBefore = project2.items.single;
      if (!itemBefore.sizeConfirmed) {
        project2 = await projects.save(
          arrangeDocuments(
            DocumentEdits.setKind(project2, itemBefore.id, DocumentKind.other),
          ).result,
        );
      }
      final itemAfter = project2.items.single;
      expect(itemAfter.documentKind, DocumentKind.other);
      expect(itemAfter.sizeConfirmed, isTrue);
      expect(itemAfter.pageIndex, 0);
      expect(
        [itemAfter.width, itemAfter.height],
        [itemBefore.width, itemBefore.height],
      );

      final exportDir2 = await Directory(
        '${tempDir.path}/exp_a2',
      ).create(recursive: true);
      await _assertAllThreeExportLayers(
        project: project2,
        assets: assets,
        exportDir: exportDir2,
        expectedPlannedItems: 1,
      );
    },
  );

  test(
    'Path B + Defect 2 regression: manual confirmation enters A4, and resetManualCrop clears UserOverride boundary fields, removes full-frame corners, restores full image pixels, and returns unresolved item off-sheet',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('stage1_path_b_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final editor = LocalImageEditor(files);
      final service = ProjectService(
        projects,
        assets,
        imageEditor: editor,
        smartRecognitionEnabled: true,
        segmenter: (_) async => const SegmentationResult(
          multi: false,
          candidates: <SegmentCandidate>[],
        ),
      );

      final truncatedBytes = File(
        'test/fixtures/synthetic_truncated_card.png',
      ).readAsBytesSync();
      final emptyDeskBytes = _syntheticScenePng(
        width: 480,
        height: 360,
        regions: const [],
      );

      var project = await service.create('Path B synthetic manual boundary');
      project = await _importAndArrange(service, project, [
        ImportSource('truncated.png', () => Stream.value(truncatedBytes)),
        ImportSource('empty-scene.png', () => Stream.value(emptyDeskBytes)),
      ]);

      expect(project.items, hasLength(2));
      expect(project.items.every((i) => !i.sizeConfirmed), isTrue);
      expect(project.items.every((i) => i.pageIndex == null), isTrue);

      final truncAsset = project.assets[0];
      final uncroppedWorkingBytes = await (await assets.resolve(
        truncAsset.workingPath,
      )).readAsBytes();
      final uncroppedDecoded = img.decodePng(uncroppedWorkingBytes)!;

      final truncItem = project.items.firstWhere(
        (i) => i.assetId == truncAsset.id,
      );
      final sourceInfo = await editor.open(truncAsset);
      final manualRecipe = CropDraft(
        corners: [
          Point2(0.08, 0.14),
          Point2(0.92, 0.14),
          Point2(0.92, 0.86),
          Point2(0.08, 0.86),
        ],
      ).toRecipe(sourceInfo.width, sourceInfo.height);

      // The generic user choice and dimensions below are synthetic test input,
      // not ground-truth annotations for the fixture image.
      project = await service.confirmManualBoundary(
        project,
        truncAsset,
        manualRecipe,
        documentKind: DocumentKind.other,
        customSizeMm: const PhysicalSizeMm(80, 50),
        targetItemId: truncItem.id,
        sourceWidth: sourceInfo.width,
        sourceHeight: sourceInfo.height,
      );

      final confirmedItem = project.items.firstWhere(
        (i) => i.id == truncItem.id,
      );
      final confirmedRecord = project.documents.firstWhere(
        (d) => d.id == confirmedItem.documentId,
      );
      expect(confirmedItem.sizeConfirmed, isTrue);
      expect(confirmedItem.pageIndex, 0);
      expect(hasManualBoundaryOverride(confirmedRecord), isTrue);
      expect(hasUnresolvedBoundary(confirmedRecord), isFalse);

      final exportDir = await Directory(
        '${tempDir.path}/exp_b',
      ).create(recursive: true);
      await _assertAllThreeExportLayers(
        project: project,
        assets: assets,
        exportDir: exportDir,
        expectedPlannedItems: 1,
      );

      // Defect 2 regression: resetManualCrop must clear manual boundary override,
      // clear processedAsset corners, restore full pixel content, and take the
      // now-unresolved item off the A4 sheet back to review.
      final reset = await service.resetManualCrop(
        project,
        project.assets.firstWhere((a) => a.id == truncAsset.id),
      );
      final resetAsset = reset.assets.firstWhere((a) => a.id == truncAsset.id);
      final resetItem = reset.items.firstWhere((i) => i.id == truncItem.id);
      final resetRecord = reset.documents.firstWhere(
        (d) => d.id == resetItem.documentId,
      );

      expect(resetAsset.crop, isNull);
      expect(resetAsset.userAuthoredCrop, isFalse);
      expect(resetAsset.originalPath, truncAsset.originalPath);
      expect(
        await (await assets.resolve(resetAsset.originalPath)).readAsBytes(),
        truncatedBytes,
      );

      // Verify restored working image pixel content matches uncropped original.
      final restoredDecoded = img.decodePng(
        await (await assets.resolve(resetAsset.workingPath)).readAsBytes(),
      )!;
      expect(
        [restoredDecoded.width, restoredDecoded.height],
        [uncroppedDecoded.width, uncroppedDecoded.height],
      );
      for (final sample in const [(5, 5), (80, 60), (150, 110)]) {
        final sx = sample.$1.clamp(0, restoredDecoded.width - 1);
        final sy = sample.$2.clamp(0, restoredDecoded.height - 1);
        final a = restoredDecoded.getPixel(sx, sy);
        final b = uncroppedDecoded.getPixel(sx, sy);
        expect([a.r, a.g, a.b], [b.r, b.g, b.b]);
      }

      expect(resetRecord.sides.single.processedAsset.corners, isNull);
      expect(hasManualBoundaryOverride(resetRecord), isFalse);
      expect(hasUnresolvedBoundary(resetRecord), isTrue);
      expect(isUserResolved(resetRecord), isFalse);
      expect(resetItem.sizeConfirmed, isFalse);
      expect(resetItem.pageIndex, isNull);
    },
  );

  test(
    'Defect 1 regression: unconfirmed applyManualCrop preserves recordBefore.toJson() and manual-crop warning across reprocessImages',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('stage1_def1_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final editor = LocalImageEditor(files);
      // Segmenter returns 1 candidate with self-intersecting corners -> rejected quad.
      final service = ProjectService(
        projects,
        assets,
        imageEditor: editor,
        smartRecognitionEnabled: true,
        segmenter: (_) async => SegmentationResult(
          multi: false,
          candidates: [
            SegmentCandidate(
              region: const <double>[0.1, 0.1, 0.9, 0.9],
              reason: 'test-crossed-candidate',
              corners: [
                Point2(0.1, 0.1),
                Point2(0.9, 0.9),
                Point2(0.9, 0.1),
                Point2(0.1, 0.9),
              ],
            ),
          ],
        ),
      );

      final sceneBytes = _syntheticScenePng(
        width: 600,
        height: 450,
        regions: const [(left: 60, top: 60, right: 540, bottom: 390)],
      );
      var project = await service.create('فحص إعادة المعالجة');
      project = (await service.importImages(project, [
        ImportSource('region.png', () => Stream.value(sceneBytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final first = (await service.arrangeImportedImages(project, [
        sourceId,
      ])).project;

      final recordBefore = first.documents.single;
      final itemBefore = first.items.single;
      final derived = first.assets.firstWhere(
        (a) => a.id == itemBefore.assetId,
      );

      final manuallyCropped = await service.applyManualCrop(
        first,
        derived,
        CropDraft(
          corners: [
            Point2(0.10, 0.12),
            Point2(0.90, 0.12),
            Point2(0.90, 0.88),
            Point2(0.10, 0.88),
          ],
        ).toRecipe(derived.width, derived.height),
      );
      expect(
        hasManualBoundaryOverride(manuallyCropped.documents.single),
        isFalse,
        reason:
            'applyManualCrop must not fabricate manual confirmation override',
      );
      expect(manuallyCropped.documents.single.toJson(), recordBefore.toJson());

      final report = await service.reprocessImages(manuallyCropped, [sourceId]);
      final recordAfter = report!.project.documents.single;
      expect(recordAfter.toJson(), recordBefore.toJson());
      expect(recordsNeedingReview(report.project), hasLength(1));
      expect(report.warnings.join('\n'), contains('القص اليدوي'));
    },
  );

  test(
    'Defect 3 regression: PairingState.paired confirmManualBoundary on front asset never overwrites back side or resolves paired record prematurely',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('stage1_def3_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final editor = LocalImageEditor(files);
      final service = ProjectService(projects, assets, imageEditor: editor);

      final frontBytes = _syntheticScenePng(
        width: 600,
        height: 420,
        regions: const [(left: 60, top: 60, right: 540, bottom: 360)],
      );
      final backBytes = _syntheticScenePng(
        width: 560,
        height: 400,
        regions: const [(left: 50, top: 55, right: 510, bottom: 345)],
      );

      var project = await service.create('مستند مزدوج الوجهين');
      project = (await service.importImages(project, [
        ImportSource('front.png', () => Stream.value(frontBytes)),
        ImportSource('back.png', () => Stream.value(backBytes)),
      ])).project;
      final frontAsset = project.assets[0];
      final backAsset = project.assets[1];

      final frontSide = DocumentSide(
        id: 'side-f',
        side: SideKind.front,
        processedAsset: ProcessedAssetRef(
          workingPath: frontAsset.workingPath,
          thumbnailPath: frontAsset.thumbnailPath,
          width: frontAsset.width,
          height: frontAsset.height,
        ),
        detection: DetectionRef(
          detectionId: 'det-f',
          producer: 'synthetic-boundary-proposer',
          version: '1.0',
          polygon: null,
        ),
      );
      final backSide = DocumentSide(
        id: 'side-b',
        side: SideKind.back,
        processedAsset: ProcessedAssetRef(
          workingPath: backAsset.workingPath,
          thumbnailPath: backAsset.thumbnailPath,
          width: backAsset.width,
          height: backAsset.height,
        ),
        detection: DetectionRef(
          detectionId: 'det-b',
          producer: 'synthetic-boundary-proposer',
          version: '1.0',
          polygon: null,
        ),
      );
      final backSideBeforeJson = backSide.toJson();

      final pairedRecord = DocumentRecord(
        id: 'doc-pair',
        sourceImageId: frontAsset.id,
        sides: [frontSide, backSide],
        pairing: PairingState.paired,
        recognition: RecognitionResult(
          documentKind: DocumentKind.unknown,
          status: RecognitionStatus.unknown,
          confidences: ConfidenceSet(),
          preset: const PresetSelection.awaiting(),
        ),
        provenance: Provenance(
          sourceImageId: frontAsset.id,
          detectionIds: const ['det-f', 'det-b'],
          processedAssetVersion: 'smart-1',
          pipelineVersion: 'smart-1',
        ),
      );
      project = await projects.save(
        project.copyWith(
          documents: [pairedRecord],
          items: [
            DocumentItem(
              id: 'item-f',
              assetId: frontAsset.id,
              x: 10,
              y: 10,
              width: 80,
              height: 55,
              pageIndex: null,
              documentKind: DocumentKind.unknown,
              sizeConfirmed: false,
              documentId: pairedRecord.id,
              sideId: frontSide.id,
            ),
            DocumentItem(
              id: 'item-b',
              assetId: backAsset.id,
              x: 10,
              y: 70,
              width: 80,
              height: 55,
              pageIndex: null,
              documentKind: DocumentKind.unknown,
              sizeConfirmed: false,
              documentId: pairedRecord.id,
              sideId: backSide.id,
            ),
          ],
        ),
      );

      final frontRecipe = CropDraft(
        corners: [
          Point2(60 / 600, 60 / 420),
          Point2(540 / 600, 60 / 420),
          Point2(540 / 600, 360 / 420),
          Point2(60 / 600, 360 / 420),
        ],
      ).toRecipe(600, 420);

      project = await service.confirmManualBoundary(
        project,
        frontAsset,
        frontRecipe,
        documentKind: DocumentKind.other,
        customSizeMm: const PhysicalSizeMm(80, 55),
        targetItemId: 'item-f',
      );

      final rec = project.documents.single;
      expect(rec.sides[1].toJson(), backSideBeforeJson);
      expect(sideHasUnresolvedBoundary(rec, rec.sides[0]), isFalse);
      expect(sideHasUnresolvedBoundary(rec, rec.sides[1]), isTrue);
      expect(hasUnresolvedBoundary(rec), isTrue);
      expect(project.items.firstWhere((i) => i.id == 'item-f').pageIndex, 0);
      expect(
        project.items.firstWhere((i) => i.id == 'item-b').pageIndex,
        isNull,
      );
    },
  );

  test(
    'Defect 4 regression: programmatic applyManualCrop and confirmManualBoundary without sourceWidth/sourceHeight on an already-cropped EXIF-6 asset use true oriented source dimensions',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('stage1_def4_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final editor = LocalImageEditor(files);
      final service = ProjectService(projects, assets, imageEditor: editor);

      // Upright 1000 x 800 scene encoded with EXIF Orientation = 6 (stored raw 800 x 1000).
      final basePng = _syntheticScenePng(
        width: 1000,
        height: 800,
        regions: const [(left: 100, top: 100, right: 860, bottom: 640)],
      );
      final exif6Jpeg = _jpegWithStoredExifOrientation(
        img.decodePng(basePng)!,
        6,
      );

      var project = await service.create('إعادة قص برمجية بدون أبعاد');
      project = (await service.importImages(project, [
        ImportSource('exif6_full.jpg', () => Stream.value(exif6Jpeg)),
      ])).project;

      // First crop shrinks working copy to ~50 x 40 pixels (normalized area
      // 0.05 x 0.05 = 0.0025 >= minManualAreaFraction 0.002)!
      final tinyFirstRecipe = CropDraft(
        corners: [
          Point2(0.20, 0.20),
          Point2(0.25, 0.20),
          Point2(0.25, 0.25),
          Point2(0.20, 0.25),
        ],
      ).toRecipe(1000, 800);
      project = await service.applyManualCrop(
        project,
        project.assets.single,
        tinyFirstRecipe,
      );
      final shrunkAsset = project.assets.single;
      expect(shrunkAsset.width, lessThan(55));
      expect(shrunkAsset.height, lessThan(45));

      // Second crop has normalized span 0.06 x 0.08 (= 60 x 64 px on the true
      // 1000 x 800 oriented source, valid; if wrongly measured against shrunk
      // 44 x 32 working copy, 0.06 * 43 = 2.58 px < 4 px would be rejected!).
      final secondRecipe = CropDraft(
        corners: [
          Point2(0.30, 0.30),
          Point2(0.36, 0.30),
          Point2(0.36, 0.38),
          Point2(0.30, 0.38),
        ],
      ).toRecipe(1000, 800);
      project = await service.applyManualCrop(
        project,
        shrunkAsset,
        secondRecipe,
      );
      expect(project.assets.single.userAuthoredCrop, isTrue);

      // Third synthetic region crop via confirmManualBoundary, without explicit
      // sourceWidth/sourceHeight; the generic size is test-only user input.
      final regionRecipe = CropDraft(
        corners: [
          Point2(0.10, 0.125),
          Point2(0.86, 0.125),
          Point2(0.86, 0.80),
          Point2(0.10, 0.80),
        ],
      ).toRecipe(1000, 800);
      project = await service.confirmManualBoundary(
        project,
        project.assets.single,
        regionRecipe,
        documentKind: DocumentKind.other,
        customSizeMm: const PhysicalSizeMm(80, 50),
      );
      expect(project.items.single.pageIndex, 0);
      expect(project.items.single.sizeConfirmed, isTrue);
    },
  );

  test(
    'Path C: synthetic adjacent regions with detection disabled -> manual extraction creates 2 independent A4 items',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('stage1_path_c_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final failingEditor = _FailingDetectorEditor(LocalImageEditor(files));
      final service = ProjectService(
        projects,
        assets,
        imageEditor: failingEditor,
        segmenter: (_) async => const SegmentationResult(
          multi: false,
          candidates: <SegmentCandidate>[],
        ),
      );

      final twoRegionBytes = _syntheticScenePng(
        width: 900,
        height: 600,
        regions: const [
          (left: 40, top: 90, right: 442, bottom: 350),
          (left: 448, top: 90, right: 860, bottom: 374),
        ],
      );

      var project = await service.create('Path C synthetic regions');
      project = await _importAndArrange(service, project, [
        ImportSource('scene.png', () => Stream.value(twoRegionBytes)),
      ]);

      expect(project.items, hasLength(1));
      expect(project.items.single.pageIndex, isNull);
      final sourcePhoto = project.assets.single;

      final recipe1 = CropDraft(
        corners: [
          Point2(40 / 900, 90 / 600),
          Point2(442 / 900, 90 / 600),
          Point2(442 / 900, 350 / 600),
          Point2(40 / 900, 350 / 600),
        ],
      ).toRecipe(900, 600);
      project = await service.extractManualDerivedDocument(
        project,
        sourcePhoto,
        recipe1,
        documentKind: DocumentKind.other,
        customSizeMm: const PhysicalSizeMm(105, 72),
        sourceWidth: 900,
        sourceHeight: 600,
      );

      final recipe2 = CropDraft(
        corners: [
          Point2(448 / 900, 90 / 600),
          Point2(860 / 900, 90 / 600),
          Point2(860 / 900, 374 / 600),
          Point2(448 / 900, 374 / 600),
        ],
      ).toRecipe(900, 600);
      project = await service.extractManualDerivedDocument(
        project,
        sourcePhoto,
        recipe2,
        documentKind: DocumentKind.other,
        customSizeMm: const PhysicalSizeMm(105, 72),
        sourceWidth: 900,
        sourceHeight: 600,
      );

      expect(project.assets, hasLength(3));
      expect(
        await (await assets.resolve(sourcePhoto.originalPath)).readAsBytes(),
        twoRegionBytes,
      );
      expect(
        project.assets.where((a) => a.derivedFrom == sourcePhoto.id),
        hasLength(2),
      );
      expect(reconcileDerivedProvenance(project).changed, isFalse);

      final exportDir = await Directory(
        '${tempDir.path}/exp_c',
      ).create(recursive: true);
      await _assertAllThreeExportLayers(
        project: project,
        assets: assets,
        exportDir: exportDir,
        expectedPlannedItems: 2,
      );
    },
  );

  test(
    'EXIF camera rotation modes 1, 3, 6, 8 preserve upright manual crop geometry onto A4',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('stage1_exif_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final editor = LocalImageEditor(files);
      final service = ProjectService(projects, assets, imageEditor: editor);

      final basePng = _syntheticScenePng(
        width: 600,
        height: 440,
        regions: const [(left: 90, top: 80, right: 510, bottom: 350)],
      );
      final upright = img.decodePng(basePng)!;

      for (final exifMode in const [6, 1, 3, 8]) {
        final jpegBytes = _jpegWithStoredExifOrientation(upright, exifMode);
        var project = await service.create('EXIF $exifMode');
        project = (await service.importImages(project, [
          ImportSource('cam_exif$exifMode.jpg', () => Stream.value(jpegBytes)),
        ])).project;

        final asset = project.assets.single;
        final opened = await editor.open(asset);
        expect(
          [opened.width, opened.height],
          [600, 440],
          reason: 'EXIF mode $exifMode normalized to upright 600x440',
        );

        final recipe = CropDraft(
          corners: [
            Point2(90 / 600, 80 / 440),
            Point2(510 / 600, 80 / 440),
            Point2(510 / 600, 350 / 440),
            Point2(90 / 600, 350 / 440),
          ],
        ).toRecipe(opened.width, opened.height);

        project = await service.confirmManualBoundary(
          project,
          asset,
          recipe,
          documentKind: DocumentKind.other,
          customSizeMm: const PhysicalSizeMm(80, 50),
        );
        final item = project.items.single;
        expect(item.documentKind, DocumentKind.other);
        expect(item.pageIndex, 0);
        expect([item.width, item.height], [80, 50]);

        final exportDir = await Directory(
          '${tempDir.path}/exp_exif_$exifMode',
        ).create(recursive: true);
        await _assertAllThreeExportLayers(
          project: project,
          assets: assets,
          exportDir: exportDir,
          expectedPlannedItems: 1,
        );
      }
    },
  );

  test(
    'Defect 5A regression: IntakeDiagnostics stays disabled by default, refuses recording under Release guard even when enabled=true, and logs zero PII in debug',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('stage1_diag_');
      addTearDown(() async {
        IntakeDiagnostics.enabled = false;
        IntakeDiagnostics.debugSimulateReleaseBuild = false;
        IntakeDiagnostics.clear();
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final editor = LocalImageEditor(files);
      final service = ProjectService(projects, assets, imageEditor: editor);

      final scene = _syntheticScenePng(
        width: 400,
        height: 300,
        regions: const [(left: 40, top: 40, right: 360, bottom: 260)],
      );

      // 1. Disabled by default.
      IntakeDiagnostics.clear();
      expect(IntakeDiagnostics.enabled, isFalse);
      expect(IntakeDiagnostics.isActive, isFalse);
      var project = await service.create('تشخيص آمن');
      project = await _importAndArrange(service, project, [
        ImportSource('private-fixture-marker.png', () => Stream.value(scene)),
      ]);
      expect(IntakeDiagnostics.entries, isEmpty);

      // 2. Release guard blocks recording even if enabled = true.
      IntakeDiagnostics.enabled = true;
      IntakeDiagnostics.debugSimulateReleaseBuild = true;
      expect(IntakeDiagnostics.isActive, isFalse);
      final asset = project.assets.single;
      final recipe = CropDraft(
        corners: [
          Point2(0.1, 0.13),
          Point2(0.9, 0.13),
          Point2(0.9, 0.87),
          Point2(0.1, 0.87),
        ],
      ).toRecipe(400, 300);
      project = await service.confirmManualBoundary(
        project,
        asset,
        recipe,
        documentKind: DocumentKind.other,
        customSizeMm: const PhysicalSizeMm(80, 50),
        targetItemId: project.items.single.id,
        sourceWidth: 400,
        sourceHeight: 300,
      );
      expect(
        IntakeDiagnostics.entries,
        isEmpty,
        reason: 'Release builds must never record diagnostics even if enabled',
      );

      // 3. Debug mode when explicitly enabled records internal IDs only (zero PII).
      IntakeDiagnostics.debugSimulateReleaseBuild = false;
      expect(IntakeDiagnostics.isActive, isTrue);
      await service.applyManualCrop(
        project,
        project.assets.single,
        recipe,
        sourceWidth: 400,
        sourceHeight: 300,
      );
      expect(IntakeDiagnostics.entries, isNotEmpty);
      for (final e in IntakeDiagnostics.entries) {
        expect(e.assetId, asset.id);
        expect(e.verdict, isNot(contains('sensitive_person_name')));
      }
    },
  );
}
