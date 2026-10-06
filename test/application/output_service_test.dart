import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/output_service.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/export/document_exporter.dart';
import '../fixtures.dart';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('scan-output-port-');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  ExportPlan plan() => ExportPlan(
    projectFixture(
      assets: [assetFixture()],
      items: [itemFixture().copyWith(x: 50, y: 50)],
    ),
    ExportProfile(format: ExportFormat.png),
  );
  Future<ExportBundle> generate(ExportPlan p, Directory dir) async {
    final folder = await Directory('${dir.path}/owned').create();
    final paths = <String>[];
    for (var i = 0; i < (p.profile.format == ExportFormat.pdf ? 1 : 2); i++) {
      final file = File('${folder.path}/$i.${p.profile.format.name}');
      await file.writeAsString('%PDF-test');
      paths.add(file.path);
    }
    return ExportBundle(paths);
  }

  test(
    'native print is given a PDF even when raster is selected; cancellation is not success',
    () async {
      var printed = false;
      final service = OutputService(
        generate: generate,
        temporary: () async => temporary,
        save: (_, _) async => throw StateError('not saving'),
        printPdf: (bytes, paper) async {
          printed = true;
          expect(String.fromCharCodes(bytes), '%PDF-test');
          expect(paper.width, 210);
          return false;
        },
      );
      final message = await service.output(plan(), print: true);
      expect(printed, true);
      expect(message, contains('أُلغيت'));
      expect(await temporary.list().toList(), isEmpty);
    },
  );
  test(
    'cancelled multi-file save reports partial count and cleans only its cache',
    () async {
      var calls = 0;
      final keep = File('${temporary.path}/keep');
      await keep.writeAsString('keep');
      final service = OutputService(
        generate: generate,
        temporary: () async => temporary,
        save: (_, mime) async {
          expect(mime, 'image/png');
          return calls++ == 0;
        },
        printPdf: (_, _) async => throw StateError('not printing'),
      );
      expect(await service.output(plan(), print: false), contains('1 من 2'));
      expect(await keep.readAsString(), 'keep');
    },
  );
  test(
    'storage failure reports already-saved files instead of claiming all succeeded',
    () async {
      var calls = 0;
      final service = OutputService(
        generate: generate,
        temporary: () async => temporary,
        save: (_, _) async {
          if (calls++ == 0) return true;
          throw const FileSystemException('disk full');
        },
        printPdf: (_, _) async => false,
      );
      await expectLater(
        service.output(plan(), print: false),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            contains('1 ملفات'),
          ),
        ),
      );
      expect(await temporary.list().toList(), isEmpty);
    },
  );
}
