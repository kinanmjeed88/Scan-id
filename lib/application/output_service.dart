import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import '../domain/export_plan.dart';
import '../domain/project.dart';
import '../export/document_exporter.dart';
import 'contracts.dart';
import 'native_documents.dart';

class OutputService {
  const OutputService({
    required this.generate,
    required this.temporary,
    required this.save,
    required this.printPdf,
  });
  factory OutputService.native(AssetRepository assets) => OutputService(
    generate: DocumentExporter(assets).generate,
    temporary: getTemporaryDirectory,
    save: saveDocument,
    printPdf: _print,
  );
  final Future<ExportBundle> Function(ExportPlan, Directory) generate;
  final Future<Directory> Function() temporary;
  final Future<bool> Function(File, String) save;
  final Future<bool> Function(Uint8List, PaperSettings) printPdf;
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
  Future<String> output(ExportPlan plan, {required bool print}) async {
    ExportBundle? bundle;
    var saved = 0;
    try {
      final request = print
          ? ExportPlan(
              plan.project,
              ExportProfile(dpi: plan.profile.dpi),
              pages: plan.pages,
            )
          : plan;
      bundle = await generate(request, await temporary());
      if (print) {
        final sent = await printPdf(
          await File(bundle.files.single).readAsBytes(),
          plan.project.paper,
        );
        return sent
            ? 'أُرسلت مهمة الطباعة للنظام. قِس الناتج فعلياً؛ الإرسال ليس تأكيداً لخروج الورق.'
            : 'أُلغيت الطباعة أو لم يقبلها النظام.';
      }
      for (final path in bundle.files) {
        final mime = path.endsWith('.pdf')
            ? 'application/pdf'
            : path.endsWith('.png')
            ? 'image/png'
            : 'image/jpeg';
        if (!await save(File(path), mime)) break;
        saved++;
      }
      return 'تم حفظ $saved من ${bundle.files.length} ملفات.';
    } catch (_) {
      if (saved > 0) {
        throw StorageException(
          'تم حفظ $saved ملفات قبل حدوث خطأ. الملفات المحفوظة باقية؛ تحقق من المساحة والصلاحيات.',
        );
      }
      rethrow;
    } finally {
      if (bundle != null && bundle.files.isNotEmpty) {
        try {
          await File(bundle.files.first).parent.delete(recursive: true);
        } catch (_) {
          /* A retained OS handle is not permission to remove unrelated paths. */
        }
      }
    }
  }
}
