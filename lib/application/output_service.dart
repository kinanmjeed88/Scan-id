import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:path/path.dart' as p;

import '../domain/export_plan.dart';
import '../domain/project.dart';
import '../export/document_exporter.dart';
import 'contracts.dart';
import 'native_documents.dart';

/// What the user asked the export to do with the files it generated.
enum OutputTarget { save, print, share }

class OutputService {
  const OutputService({
    required this.generate,
    required this.temporary,
    required this.save,
    required this.printPdf,
    this.share,
    this.shareTarget = ShareTarget.none,
    this.clock = DateTime.now,
  });
  factory OutputService.native(AssetRepository assets) => OutputService(
    generate: DocumentExporter(assets).generate,
    temporary: getTemporaryDirectory,
    save: saveDocument,
    printPdf: _print,
    share: shareDocuments,
    shareTarget: shareTargetOnThisPlatform,
  );
  final Future<ExportBundle> Function(ExportPlan, Directory) generate;
  final Future<Directory> Function() temporary;
  final Future<bool> Function(File, String) save;
  final Future<bool> Function(Uint8List, PaperSettings) printPdf;

  /// Returns whether the platform accepted the files. Null when the platform
  /// has no share surface, which is why [shareTarget] exists.
  final Future<bool> Function(List<String> paths, String mime)? share;
  final ShareTarget shareTarget;

  /// Injected in tests so the age of a kept export is deterministic.
  final DateTime Function() clock;

  static Future<bool> _print(Uint8List bytes, PaperSettings paper) =>
      Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'Scan ID',
        format: PdfPageFormat(
          paper.width * PdfPageFormat.mm,
          paper.height * PdfPageFormat.mm,
          marginAll: 0,
        ),
        dynamicLayout: false,
        usePrinterSettings: false,
      );

  Future<String> output(
    ExportPlan plan, {
    OutputTarget target = OutputTarget.save,
  }) async {
    ExportBundle? bundle;
    var saved = 0;
    var retained = false;
    try {
      final request = target == OutputTarget.print
          ? ExportPlan(
              plan.project,
              ExportProfile(dpi: plan.profile.dpi),
              pages: plan.pages,
            )
          : plan;
      final temporaryDirectory = await temporary();
      await _pruneKeptExports(temporaryDirectory, clock());
      bundle = await generate(request, temporaryDirectory);
      switch (target) {
        case OutputTarget.print:
          final sent = await printPdf(
            await File(bundle.files.single).readAsBytes(),
            plan.project.paper,
          );
          return sent
              ? 'أُرسلت مهمة الطباعة للنظام. قِس الناتج فعلياً؛ الإرسال ليس تأكيداً لخروج الورق.'
              : 'أُلغيت الطباعة أو لم يقبلها النظام.';
        case OutputTarget.share:
          final hand = share;
          if (hand == null || shareTarget == ShareTarget.none) {
            throw const StorageException(
              'لا تتوفر مشاركة على هذه المنصة؛ استخدم «تصدير الملفات» للحفظ محلياً.',
            );
          }
          final bool sent;
          try {
            sent = await hand(bundle.files, _mimeOf(bundle.files.first));
          } catch (_) {
            throw const StorageException(
              'تعذرت مشاركة الملفات؛ استخدم «تصدير الملفات» لحفظها محلياً.',
            );
          }
          // A receiving application opens the handed-over file after this call
          // returns, so a shared export must outlive it. Kept folders are pruned
          // by the next export and never mixed with saved user files.
          retained = sent;
          if (!sent) {
            return 'أُلغيت المشاركة أو لم يقبلها النظام.';
          }
          return shareTarget == ShareTarget.shareSheet
              ? 'أُرسلت الملفات إلى تطبيق المشاركة إرسالاً محلياً. لا يصل تنبيه عند استلام الطرف الآخر، وتُنظَّف النسخ المؤقتة تلقائياً.'
              : 'فُتح موقع الملفات في مدير الملفات. انسخها إلى مكانك الآن؛ النسخ المؤقتة تُنظَّف تلقائياً.';
        case OutputTarget.save:
          for (final path in bundle.files) {
            if (!await save(File(path), _mimeOf(path))) break;
            saved++;
          }
          return 'تم حفظ $saved من ${bundle.files.length} ملفات.';
      }
    } catch (_) {
      if (saved > 0) {
        throw StorageException(
          'تم حفظ $saved ملفات قبل حدوث خطأ. الملفات المحفوظة باقية؛ تحقق من المساحة والصلاحيات.',
        );
      }
      rethrow;
    } finally {
      if (!retained && bundle != null) {
        await _cleanup(bundle);
      }
    }
  }

  static String _mimeOf(String path) => path.endsWith('.pdf')
      ? 'application/pdf'
      : path.endsWith('.png')
      ? 'image/png'
      : 'image/jpeg';

  /// Removes one finished export's own directory, then its shared parent when
  /// nothing else is in flight there.
  static Future<void> _cleanup(ExportBundle bundle) async {
    if (bundle.files.isEmpty) {
      return;
    }
    try {
      final directory = bundle.directory;
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      // Only the dedicated export folder is ever removed here; the surrounding
      // cache directory belongs to the operating system, not to this app.
      final root = directory.parent;
      if (p.basename(root.path) == exportDirectoryName &&
          await root.exists() &&
          await root.list().isEmpty) {
        await root.delete();
      }
    } catch (_) {
      /* A retained OS handle is not permission to remove unrelated paths. */
    }
  }

  /// Drops export folders kept for a share once they are a day old.
  ///
  /// Only folders this service created are considered. Each of them is written
  /// once and never rewritten, so its own timestamp is a faithful age; the
  /// surrounding cache directory is left alone.
  static Future<void> _pruneKeptExports(
    Directory temporaryDirectory,
    DateTime now,
  ) async {
    try {
      final root = Directory(
        '${temporaryDirectory.path}/$exportDirectoryName',
      );
      if (!await root.exists()) {
        return;
      }
      final cutoff = now.toUtc().subtract(const Duration(hours: 24));
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }
        if ((await entity.stat()).modified.toUtc().isAfter(cutoff)) {
          continue;
        }
        await entity.delete(recursive: true);
      }
      if (await root.exists() && await root.list().isEmpty) {
        await root.delete();
      }
    } catch (_) {
      /* Cleanup must never block an export the user asked for. */
    }
  }
}
