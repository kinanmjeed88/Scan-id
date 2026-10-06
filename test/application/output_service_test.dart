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
  ExportPlan plan({ExportFormat format = ExportFormat.png}) => ExportPlan(
    projectFixture(
      assets: [assetFixture()],
      items: [itemFixture().copyWith(x: 50, y: 50)],
    ),
    ExportProfile(format: format),
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
      final message = await service.output(plan(), target: OutputTarget.print);
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
      expect(
        await service.output(plan()),
        contains('1 من 2'),
        reason: 'الحفظ الافتراضي',
      );
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
        service.output(plan()),
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
  test(
    'share hands over every generated file and keeps them readable afterwards',
    () async {
      List<String>? handed;
      String? handedMime;
      final service = OutputService(
        generate: generate,
        temporary: () async => temporary,
        save: (_, _) async => throw StateError('not saving'),
        printPdf: (_, _) async => throw StateError('not printing'),
        shareTarget: ShareTarget.shareSheet,
        share: (paths, mime) async {
          handed = paths;
          handedMime = mime;
          // The receiving application reads the file after this returns.
          for (final path in paths) {
            expect(await File(path).exists(), isTrue);
          }
          return true;
        },
      );
      final message = await service.output(plan(), target: OutputTarget.share);
      expect(handed, hasLength(2));
      expect(handedMime, 'image/png');
      expect(message, contains('تطبيق المشاركة'));
      expect(
        await temporary.list().toList(),
        isNotEmpty,
        reason: 'الملفات تبقى ليقرأها التطبيق الآخر، وتُنظَّف لاحقاً',
      );
      expect(
        await File(handed!.first).exists(),
        isTrue,
        reason: 'لا يجوز حذف ملف سُلم لتطبيق آخر',
      );
    },
  );
  test(
    'a refused or cancelled share cleans up and never claims success',
    () async {
      final service = OutputService(
        generate: generate,
        temporary: () async => temporary,
        save: (_, _) async => throw StateError('not saving'),
        printPdf: (_, _) async => throw StateError('not printing'),
        shareTarget: ShareTarget.shareSheet,
        share: (_, _) async => false,
      );
      final message = await service.output(plan(), target: OutputTarget.share);
      expect(message, contains('أُلغيت المشاركة'));
      expect(await temporary.list().toList(), isEmpty);
    },
  );
  test('a platform without sharing says so instead of pretending', () async {
    final service = OutputService(
      generate: generate,
      temporary: () async => temporary,
      save: (_, _) async => true,
      printPdf: (_, _) async => false,
    );
    await expectLater(
      service.output(plan(), target: OutputTarget.share),
      throwsA(
        isA<StorageException>().having(
          (e) => e.message,
          'message',
          contains('لا تتوفر مشاركة'),
        ),
      ),
    );
    expect(await temporary.list().toList(), isEmpty);
  });
  test('a bridge failure is reported in Arabic and leaves no debris', () async {
    final service = OutputService(
      generate: generate,
      temporary: () async => temporary,
      save: (_, _) async => true,
      printPdf: (_, _) async => false,
      shareTarget: ShareTarget.revealFolder,
      share: (_, _) async => throw StateError('no file manager'),
    );
    await expectLater(
      service.output(plan(), target: OutputTarget.share),
      throwsA(
        isA<StorageException>().having(
          (e) => e.message,
          'message',
          contains('تعذرت مشاركة الملفات'),
        ),
      ),
    );
    expect(await temporary.list().toList(), isEmpty);
  });
  test('a kept export is pruned once it is a day old, and not before', () async {
    final kept = Directory('${temporary.path}/$exportDirectoryName/old');
    await kept.create(recursive: true);
    await File('${kept.path}/page-1.png').writeAsString('old');

    OutputService service(DateTime Function() clock) => OutputService(
      generate: generate,
      temporary: () async => temporary,
      save: (_, _) async => true,
      printPdf: (_, _) async => false,
      clock: clock,
    );

    // A young folder survives, because a receiving application may still read it.
    await service(DateTime.now).output(plan());
    expect(await kept.exists(), isTrue);
    expect(await File('${kept.path}/page-1.png').exists(), isTrue);

    // A day later the next export reclaims the space and leaves nothing behind.
    await service(
      () => DateTime.now().add(const Duration(hours: 25)),
    ).output(plan());
    expect(await kept.exists(), isFalse);
    expect(await temporary.list().toList(), isEmpty);
  });
}
