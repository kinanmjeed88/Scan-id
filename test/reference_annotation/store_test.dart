import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/reference_annotation/store.dart';

void main() {
  late Directory temporaryRoot;
  late Uint8List syntheticPng;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'scan-id-reference-test-',
    );
    final image = img.Image(width: 160, height: 120);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(
          x,
          y,
          (x * 255 ~/ image.width),
          (y * 255 ~/ image.height),
          ((x + y) * 255 ~/ (image.width + image.height)),
        );
      }
    }
    syntheticPng = Uint8List.fromList(img.encodePng(image));
  });

  tearDown(() async {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  ImportSource source([Uint8List? bytes]) => ImportSource(
    'synthetic-image.png',
    () => Stream<List<int>>.value(bytes ?? syntheticPng),
  );

  test(
    'stores a synthetic image privately and never auto-merges SHA duplicates',
    () async {
      final store = await ReferenceAnnotationStore.open(temporaryRoot);
      final first = await store.addImages([source()]);
      expect(first.added, 1);
      expect(first.exactDuplicates, 0);
      expect(store.samples, hasLength(1));
      expect(store.samples.single['perceptual_dhash64'], 'ffffffffffffffff');
      expect(await store.hasImage(store.samples.single), isTrue);

      final duplicate = await store.addImages([source()]);
      expect(duplicate.added, 0);
      expect(duplicate.exactDuplicates, 1);
      expect(store.samples, hasLength(1));

      final reopened = await ReferenceAnnotationStore.open(temporaryRoot);
      expect(reopened.samples, hasLength(1));
      expect(await reopened.hasImage(reopened.samples.single), isTrue);
    },
  );

  test(
    'exports schema v2.0.0 without paths or image bytes and restores labels',
    () async {
      final store = await ReferenceAnnotationStore.open(temporaryRoot);
      await store.addImages([source()]);
      final sample = _deepCopy(store.samples.single);
      final document = Map<String, Object?>.from(
        (sample['documents'] as List).single as Map,
      );
      final corners = <Object?>[
        <Object?>[0.15, 0.2],
        <Object?>[0.85, 0.2],
        <Object?>[0.85, 0.8],
        <Object?>[0.15, 0.8],
      ];
      document
        ..['document_kind'] = 'unifiedNationalId'
        ..['visible_polygon'] = corners
        ..['corners'] = corners
        ..['human_verified'] = true;
      sample
        ..['documents'] = [document]
        ..['annotation_status'] = 'annotated'
        ..['annotator_id'] = 'R1'
        ..['annotated_at'] = DateTime.now().toUtc().toIso8601String();
      await store.updateSample(0, sample);

      final exported = await store.exportJson(annotatorId: 'R1');
      final payload = jsonDecode(utf8.decode(exported)) as Map<String, dynamic>;
      expect(payload['schema'], referenceSchema);
      expect(payload['schema_version'], referenceSchemaVersion);
      final text = utf8.decode(exported);
      expect(text, isNot(contains('local_path')));
      expect(text, isNot(contains('image_bytes')));
      expect(text, isNot(contains('synthetic-image.png')));

      final restoredRoot = Directory('${temporaryRoot.path}-restore');
      addTearDown(() async {
        if (await restoredRoot.exists()) {
          await restoredRoot.delete(recursive: true);
        }
      });
      final restored = await ReferenceAnnotationStore.open(restoredRoot);
      await restored.importPayloadBytes(exported, replaceMatching: false);
      expect(restored.samples, hasLength(1));
      expect(restored.samples.single['annotation_status'], 'annotated');
      expect(await restored.hasImage(restored.samples.single), isFalse);

      final attach = await restored.addImages([source()]);
      expect(attach.added, 0);
      expect(attach.exactDuplicates, 1);
      expect(await restored.hasImage(restored.samples.single), isTrue);
    },
  );

  test(
    'rejects forbidden source and personal fields without changing local data',
    () async {
      final store = await ReferenceAnnotationStore.open(temporaryRoot);
      await store.addImages([source()]);
      final clean = store.buildPayload(annotatorId: 'R1');
      final malicious = _deepCopy(clean)..['filename'] = 'synthetic-person.jpg';
      await expectLater(
        store.importPayloadBytes(
          Uint8List.fromList(utf8.encode(jsonEncode(malicious))),
          replaceMatching: true,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(store.samples, hasLength(1));
      expect(await store.hasImage(store.samples.single), isTrue);
    },
  );
}

Map<String, Object?> _deepCopy(Map<String, Object?> value) =>
    (jsonDecode(jsonEncode(value)) as Map<String, dynamic>)
        .cast<String, Object?>();
