import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../application/contracts.dart';
import '../application/ids.dart';
import '../domain/export_plan.dart';
import '../domain/image_limits.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import '../imaging/image_header.dart';
import '../imaging/safe_png.dart';

class ExportBundle {
  const ExportBundle(this.files);
  final List<String> files;
}

class DocumentExporter {
  const DocumentExporter(this.assets);
  final AssetRepository assets;
  Future<ExportBundle> generate(ExportPlan plan, Directory temporary) async {
    // Resolve safely on the IO layer before passing paths, not a UI/controller,
    // across the isolate boundary. Only referenced working copies are read.
    final paths = <String, String>{};
    for (final item in plan.project.items.where(plan.includes)) {
      final asset = plan.project.assets.firstWhere((a) => a.id == item.assetId);
      paths[asset.id] = (await assets.resolve(asset.workingPath)).path;
    }
    final output = Directory('${temporary.path}/scan-export-${newId()}');
    await output.create(recursive: true);
    final root = output.path;
    try {
      return await Isolate.run(() => _generate(plan, paths, root));
    } catch (_) {
      if (await output.exists()) await output.delete(recursive: true);
      rethrow;
    }
  }
}

img.Image _readWorking(String path, ImageAsset expected) {
  final file = File(path);
  require(
    file.lengthSync() > 0 && file.lengthSync() <= 128 * 1024 * 1024,
    'ملف العمل كبير جداً أو فارغ.',
  );
  final bytes = file.readAsBytesSync();
  // Working copies are PNG produced by our processor. Header preflight only
  // needs IHDR, so do not impose the compressed-original 20 MiB import limit.
  final header = inspectImageHeader(
    Uint8List.sublistView(bytes, 0, math.min(bytes.length, 33)),
  );
  require(
    header.encoding == ImageEncoding.png &&
        withinImageBudget(header.width, header.height),
    'نسخة عمل غير صالحة.',
  );
  require(
    header.width == expected.width && header.height == expected.height,
    'أبعاد نسخة العمل لا تطابق البيانات؛ أعد إنشاء النسخ من الأصول.',
  );
  final decoder = img.PngDecoder();
  final info = decoder.startDecode(safePng(bytes));
  require(
    info != null && decoder.numFrames() == 1,
    'نسخة عمل تالفة أو متحركة.',
  );
  final image = decoder.decodeFrame(0);
  require(
    image != null &&
        image.width == header.width &&
        image.height == header.height,
    'تعذر فك نسخة العمل.',
  );
  return image!;
}

Future<ExportBundle> _generate(
  ExportPlan plan,
  Map<String, String> paths,
  String directory,
) async {
  if (plan.profile.format == ExportFormat.pdf) {
    final document = pw.Document();
    // Embed each asset once, reduced only when source pixels exceed the chosen
    // output density. PDF pages remain vectors; no full-page screenshot bitmap.
    final images = <String, pw.MemoryImage>{};
    var embeddedPixels = 0, encodedBytes = 0;
    for (final id in paths.keys) {
      final placements = plan.project.items.where(
        (e) => e.assetId == id && plan.includes(e),
      );
      var wantedW = 1, wantedH = 1;
      for (final item in placements) {
        wantedW = math.max(
          wantedW,
          (item.width / 25.4 * plan.profile.dpi).ceil(),
        );
        wantedH = math.max(
          wantedH,
          (item.height / 25.4 * plan.profile.dpi).ceil(),
        );
      }
      final source = _readWorking(
        paths[id]!,
        plan.project.assets.firstWhere((a) => a.id == id),
      );
      final factor = math.min(
        1.0,
        math.max(wantedW / source.width, wantedH / source.height),
      );
      final reduced = factor < 1
          ? img.copyResize(
              source,
              width: math.max(1, (source.width * factor).ceil()),
              height: math.max(1, (source.height * factor).ceil()),
              interpolation: img.Interpolation.average,
            )
          : source;
      embeddedPixels += reduced.width * reduced.height;
      require(
        embeddedPixels <= 40000000,
        'صور PDF تتجاوز ميزانية الذاكرة. صدّر نطاق صفحات أصغر أو دقة أقل.',
      );
      final encoded = img.encodePng(reduced);
      encodedBytes += encoded.length;
      require(
        encodedBytes <= 96 * 1024 * 1024,
        'حجم صور PDF كبير؛ اختر نطاق صفحات أصغر.',
      );
      images[id] = pw.MemoryImage(encoded);
    }
    for (final page in plan.pages) {
      final items = plan.items(page);
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(
            plan.project.paper.width * PdfPageFormat.mm,
            plan.project.paper.height * PdfPageFormat.mm,
            marginAll: 0,
          ),
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.SizedBox(
            width: plan.project.paper.width * PdfPageFormat.mm,
            height: plan.project.paper.height * PdfPageFormat.mm,
            child: pw.Stack(
              children: [
                for (final item in items)
                  pw.Positioned(
                    left: item.x * PdfPageFormat.mm,
                    top: item.y * PdfPageFormat.mm,
                    child: pw.SizedBox(
                      width: item.width * PdfPageFormat.mm,
                      height: item.height * PdfPageFormat.mm,
                      child: pw.Transform.rotate(
                        angle: -item.rotation * math.pi / 180,
                        child: pw.Image(
                          images[item.assetId]!,
                          width: item.width * PdfPageFormat.mm,
                          height: item.height * PdfPageFormat.mm,
                          fit: pw.BoxFit.fill,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    final file = File('$directory/document.pdf');
    await file.writeAsBytes(await document.save(), flush: true);
    return ExportBundle([file.path]);
  }
  final result = <String>[];
  // One RGB page at a time (600 DPI ≈ 100 MiB), and one decoded source at a time.
  // Never allocate all page rasters or rotated source-sized copies together.
  for (final page in plan.pages) {
    final raster = renderPage(plan, page, paths);
    final extension = plan.profile.format == ExportFormat.png ? 'png' : 'jpg';
    final file = File('$directory/page-${page + 1}.$extension');
    await file.writeAsBytes(
      extension == 'png'
          ? img.PngEncoder(
              pixelDimensions: img.PngPhysicalPixelDimensions.dpi(
                plan.profile.dpi,
              ),
            ).encode(raster)
          : _encodeJpeg(raster, plan.profile),
      flush: true,
    );
    result.add(file.path);
  }
  return ExportBundle(List.unmodifiable(result));
}

img.Image renderPage(ExportPlan plan, int page, Map<String, String> paths) {
  final target = img.Image(
    width: plan.pixelWidth,
    height: plan.pixelHeight,
    numChannels: 3,
  );
  img.fill(target, color: img.ColorRgb8(255, 255, 255));
  final scale = plan.profile.dpi / 25.4;
  for (final item in plan.items(page)) {
    final source = _readWorking(
      paths[item.assetId]!,
      plan.project.assets.firstWhere((a) => a.id == item.assetId),
    );
    final bounds = item.bounds;
    final left = math.max(0, (bounds.x * scale).floor()),
        right = math.min(target.width, (bounds.right * scale).ceil());
    final top = math.max(0, (bounds.y * scale).floor()),
        bottom = math.min(target.height, (bounds.bottom * scale).ceil());
    final angle = item.rotation * math.pi / 180,
        c = math.cos(angle),
        s = math.sin(angle);
    final cx = item.x + item.width / 2, cy = item.y + item.height / 2;
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final dx = (x + .5) / scale - cx, dy = (y + .5) / scale - cy;
        final u = (c * dx + s * dy) / item.width + .5,
            v = (-s * dx + c * dy) / item.height + .5;
        if (u < 0 || u >= 1 || v < 0 || v >= 1) continue;
        final sample = source.getPixel(
          (u * source.width).floor().clamp(0, source.width - 1).toInt(),
          (v * source.height).floor().clamp(0, source.height - 1).toInt(),
        );
        final alpha = sample.aNormalized;
        final old = target.getPixel(x, y);
        target.setPixelRgb(
          x,
          y,
          (sample.rNormalized * 255 * alpha + old.r * (1 - alpha)).round(),
          (sample.gNormalized * 255 * alpha + old.g * (1 - alpha)).round(),
          (sample.bNormalized * 255 * alpha + old.b * (1 - alpha)).round(),
        );
      }
    }
  }
  return target;
}

Uint8List _encodeJpeg(img.Image raster, ExportProfile profile) {
  final bytes = img.encodeJpg(raster, quality: profile.jpegQuality);
  // image 4.5.4 writes a JFIF APP0 with unknown units and density 1.
  // Set actual inches/DPI; otherwise photo software cannot recover mm sizes.
  require(
    bytes.length > 18 &&
        bytes[2] == 0xff &&
        bytes[3] == 0xe0 &&
        bytes[6] == 0x4a &&
        bytes[7] == 0x46,
    'تعذر كتابة بيانات دقة JPEG.',
  );
  final data = ByteData.sublistView(bytes);
  bytes[13] = 1;
  data.setUint16(14, profile.dpi);
  data.setUint16(16, profile.dpi);
  return bytes;
}
