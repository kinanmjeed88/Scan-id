import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/import_trace.dart';
import 'package:scan_id/application/ocr_engine.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/intake.dart';

class _DelayedOcr implements OcrEngine {
  final entered = Completer<void>();
  final gate = Completer<OcrTextResult>();
  @override
  bool get isEnabled => true;
  @override
  String get version => 'fake';
  @override
  Future<OcrTextResult> recognize(Uint8List bytes, {CancellationToken? token}) {
    entered.complete();
    return gate.future;
  }
}

class _FailSave implements ProjectRepository {
  @override
  Future<Project> save(Project project) async => throw StateError('fake save');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Editor implements ImageEditor {
  _Editor(this.inner, this.boundary);
  final ImageEditor inner;
  final Future<List<Point2>?> Function() boundary;
  @override
  Future<EditorSource> open(
    ImageAsset asset, {
    CancellationToken? cancellation,
  }) => inner.open(asset, cancellation: cancellation);
  @override
  Future<List<Point2>?> suggest(Uint8List preview) => boundary();
  @override
  Future<Uint8List> preview(
    ImageAsset asset,
    ImageEditRecipe recipe, {
    CancellationToken? cancellation,
  }) => inner.preview(asset, recipe, cancellation: cancellation);
  @override
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe) =>
      inner.createRevision(asset, recipe);
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_trace_');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ImportSource source() {
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 120, height: 90)),
    );
    return ImportSource('image.png', () => Stream.value(bytes));
  }

  ProjectService service(
    Future<List<Point2>?> Function() boundary, {
    OcrEngine ocr = const UnavailableOcrEngine(),
  }) => ProjectService(
    projects,
    assets,
    imageEditor: _Editor(LocalImageEditor(projects.files), boundary),
    smartRecognitionEnabled: true,
    ocr: ocr,
  );

  test(
    'single import persists before completion and a second import works',
    () async {
      final svc = service(() async => null);
      final project = await svc.create('test');
      final firstEvents = <ImportTraceEvent>[];
      final first = await IntakeRunner(
        service: svc,
        project: project,
        onTrace: firstEvents.add,
      ).run([source()]);
      expect(first.error, isNull);
      expect(first.importedCount, 1);
      final saved = await projects.get(project.id);
      expect(saved.assets, hasLength(1));
      expect(saved.documents, hasLength(1));
      expect(saved.items, hasLength(1));
      expect(saved.documents.single.sourceImageId, saved.assets.single.id);
      expect(saved.items.single.assetId, saved.assets.single.id);
      expect(saved.items.single.documentId, saved.documents.single.id);
      expect(saved.items.single.sideId, saved.documents.single.sides.single.id);
      expect(saved.items.single.sizeConfirmed, isFalse);
      expect(saved.items.single.pageIndex, isNull);
      final names = firstEvents.map((e) => e.event).toList();
      expect(names.first, 'import_started');
      expect(
        names,
        containsAllInOrder([
          'image_decoded',
          'detection_started',
          'detection_completed',
          'recognition_completed',
          'persistence_completed',
          'import_completed',
        ]),
      );
      expect(firstEvents.map((e) => e.taskId).toSet(), hasLength(1));
      final secondEvents = <ImportTraceEvent>[];
      final second = await IntakeRunner(
        service: svc,
        project: first.project,
        onTrace: secondEvents.add,
      ).run([source()]);
      expect(second.error, isNull);
      expect(second.project.assets, hasLength(2));
      expect(second.project.documents, hasLength(2));
      expect(second.project.items, hasLength(2));
      expect(secondEvents.first.taskId, isNot(firstEvents.first.taskId));
    },
  );

  test(
    'cancelled boundary late result stays with old task and is marked late',
    () async {
      final gate = Completer<List<Point2>?>();
      final entered = Completer<void>();
      final svc = service(() {
        entered.complete();
        return gate.future;
      });
      final project = await svc.create('test');
      final events = <ImportTraceEvent>[];
      final runner = IntakeRunner(
        service: svc,
        project: project,
        onTrace: events.add,
      );
      final pending = runner.run([source()]);
      await entered.future;
      runner.cancel();
      final result = await pending;
      expect(events.any((e) => e.event == 'import_cancelled'), isTrue);
      gate.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(
        events.any((e) => e.event == 'detection_completed' && e.late),
        isTrue,
      );
      final nextEvents = <ImportTraceEvent>[];
      final next = await IntakeRunner(
        service: service(() async => null),
        project: result.project,
        onTrace: nextEvents.add,
      ).run([source()]);
      expect(next.error, isNull);
      expect(nextEvents.first.taskId, isNot(events.first.taskId));
    },
  );

  test(
    'delayed fake OCR is visible and cancellation remains distinguishable',
    () async {
      final ocr = _DelayedOcr();
      final svc = service(() async => null, ocr: ocr);
      final project = await svc.create('test');
      final events = <ImportTraceEvent>[];
      final ocrCancelled = Completer<void>();
      final runner = IntakeRunner(
        service: svc,
        project: project,
        onTrace: (event) {
          events.add(event);
          if (event.event == 'ocr_cancelled' && !ocrCancelled.isCompleted) {
            ocrCancelled.complete();
          }
        },
      );
      final pending = runner.run([source()]);
      await ocr.entered.future;
      expect(events.any((e) => e.event == 'ocr_started'), isTrue);
      expect(events.any((e) => e.event == 'ocr_completed'), isFalse);
      runner.cancel();
      await pending;
      // The caller can return before the cancelled nested pipeline unwinds.
      await ocrCancelled.future.timeout(const Duration(seconds: 5));
      expect(events.any((e) => e.event == 'ocr_cancelled'), isTrue);
      ocr.gate.complete(
        OcrTextResult.unavailable(
          unavailableReason: 'fake',
          engineVersion: 'fake',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        events.last.late || events.last.event == 'import_cancelled',
        isTrue,
      );
    },
  );

  test(
    'failed source save is traced and a subsequent import can succeed',
    () async {
      final good = service(() async => null);
      final project = await good.create('test');
      final failing = ProjectService(
        _FailSave(),
        assets,
        imageEditor: _Editor(
          LocalImageEditor(projects.files),
          () async => null,
        ),
        smartRecognitionEnabled: true,
      );
      final events = <ImportTraceEvent>[];
      final failed = await IntakeRunner(
        service: failing,
        project: project,
        onTrace: events.add,
      ).run([source()]);
      expect(failed.import.failures, isNotEmpty);
      expect(events.any((e) => e.event == 'persistence_failed'), isTrue);
      expect(events.last.event, 'import_failed');
      final retried = await IntakeRunner(
        service: good,
        project: project,
      ).run([source()]);
      expect(retried.error, isNull);
      expect(retried.project.assets, hasLength(1));
    },
  );

  test(
    'boundary failure is reported and the next import remains possible',
    () async {
      final project = await service(() async => null).create('test');
      final events = <ImportTraceEvent>[];
      final first = await IntakeRunner(
        service: service(() async => throw StateError('fake')),
        project: project,
        onTrace: events.add,
      ).run([source()]);
      expect(events.any((e) => e.event == 'detection_failed'), isTrue);
      expect(first.project.items, isNotEmpty);
      final next = await IntakeRunner(
        service: service(() async => null),
        project: first.project,
      ).run([source()]);
      expect(next.error, isNull);
      expect(next.project.assets, hasLength(2));
    },
  );
}
