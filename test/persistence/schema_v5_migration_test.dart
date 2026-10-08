import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/image_limits.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/validation.dart';

/// Deterministic, non-destructive v1..v4 → v5 migration semantics
/// (docs/MIGRATION_V5.md §4). These run entirely in memory through
/// [Project.fromJson]; the snapshot + atomic persistence are covered in
/// schema_v5_snapshot_test.dart, and the full open/keep/upgrade cycle against
/// the real old serializers lives in legacy_schema_test.dart.
void main() {
  ImageAsset legacyAsset() => ImageAsset(
    id: 'a1',
    name: 'card.png',
    originalPath: 'projects/p1/assets/a1/original.png',
    workingPath: 'projects/p1/assets/a1/working.png',
    thumbnailPath: 'projects/p1/assets/a1/thumb.jpg',
    width: 400,
    height: 250,
  );

  DocumentItem signalItem({String id = 'card'}) => DocumentItem(
    id: id,
    assetId: 'a1',
    x: 20,
    y: 25,
    width: 85.6,
    height: 53.98,
    documentKind: DocumentKind.unifiedNationalId,
    recognitionConfidence: 0.9,
    sizeConfirmed: true,
  );

  DocumentItem manualItem({String id = 'note'}) => DocumentItem(
    id: id,
    assetId: 'a1',
    x: 30,
    y: 40,
    width: 60,
    height: 40,
  );

  // Build a real legacy record: take a valid v5 project's JSON, force the old
  // schemaVersion, and strip the v5-only collections so the reader must migrate.
  Map<String, Object?> legacyJson({
    required int schema,
    required List<DocumentItem> items,
  }) {
    final json = Project(
      id: 'p1',
      name: 'legacy',
      createdAt: DateTime.utc(2026, 10, 6),
      updatedAt: DateTime.utc(2026, 10, 6),
      revision: 3,
      assets: [legacyAsset()],
      items: items,
    ).toJson();
    json['schemaVersion'] = schema;
    json.remove('documents');
    json.remove('layoutGroups');
    return json;
  }

  group('migration per version', () {
    for (final schema in const [1, 2, 3, 4]) {
      test('schema $schema migrates to v5 with legacy provenance', () {
        final migrated = Project.fromJson(
          legacyJson(schema: schema, items: [signalItem(), manualItem()]),
        );
        // The stored schema number is recorded, never guessed.
        expect(migrated.documents, hasLength(1));
        final record = migrated.documents.single;
        expect(record.provenance.importedFrom, isNotNull);
        expect(record.provenance.importedFrom!.schema, schema);
        expect(record.provenance.importedFrom!.field, 'recognitionConfidence');
        expect(record.provenance.importedFrom!.migrationVersion, '5');
        // Round-trips as v5 from here on.
        expect(Project.fromJson(migrated.toJson()).toJson(), migrated.toJson());
      });
    }

    test('no-signal items stay pure manual across every schema', () {
      for (final schema in const [1, 2, 3, 4]) {
        final migrated = Project.fromJson(
          legacyJson(schema: schema, items: [manualItem()]),
        );
        expect(migrated.documents, isEmpty);
        expect(migrated.items.single.documentId, isNull);
        expect(migrated.items.single.sideId, isNull);
        expect(migrated.items.single.presetSnapshot, isNull);
      }
    });
  });

  group('deterministic ids', () {
    test('record and side ids derive from the stable item id', () {
      final migrated = Project.fromJson(
        legacyJson(schema: 4, items: [signalItem(id: 'card')]),
      );
      final record = migrated.documents.single;
      expect(record.id, 'rec-card');
      expect(record.sides.single.id, 'side-card');
      final item = migrated.items.single;
      expect(item.documentId, 'rec-card');
      expect(item.sideId, 'side-card');
      expect(record.sourceImageId, 'a1');
    });

    test('two signal items produce two distinct deterministic records', () {
      final migrated = Project.fromJson(
        legacyJson(
          schema: 4,
          items: [signalItem(id: 'card'), signalItem(id: 'pass')],
        ),
      );
      expect(migrated.documents, hasLength(2));
      expect(migrated.documents[0].id, 'rec-card');
      expect(migrated.documents[1].id, 'rec-pass');
    });
  });

  group('legacy confidence semantics', () {
    test('scalar becomes classification and final only', () {
      final migrated = Project.fromJson(
        legacyJson(schema: 4, items: [signalItem()]),
      );
      final recognition = migrated.documents.single.recognition!;
      final classification = recognition.confidences.classification!;
      expect(classification.value, 0.9);
      expect(classification.reason, 'legacy scalar (pre-v5)');
      expect(classification.producer, 'suggestDocumentType');
      expect(classification.version, 'legacy');
      final fin = recognition.confidences.finalConfidence!;
      expect(fin.value, 0.9);
      expect(fin.reason, 'legacy scalar (pre-v5)');
      // Unavailable sources are absent, not zero.
      expect(recognition.confidences.detection, isNull);
      expect(recognition.confidences.geometry, isNull);
      expect(recognition.confidences.ocr, isNull);
      // Preset confidence is absent (resolved by kind, never scored).
      expect(recognition.preset.presetConfidence, isNull);
      // Never Tier-B calibrated, and no evidence is manufactured.
      expect(recognition.validated, isFalse);
      expect(recognition.evidence, isEmpty);
      expect(recognition.status, RecognitionStatus.recognized);

      final json = recognition.confidences.toJson();
      expect(json.containsKey('detection'), isFalse);
      expect(json.containsKey('geometry'), isFalse);
      expect(json.containsKey('ocr'), isFalse);
      expect(json.containsKey('preset'), isFalse);
      expect(json.containsKey('classification'), isTrue);
      expect(json.containsKey('final'), isTrue);
    });

    test('side detection has no confidence, deterministic polygon', () {
      final migrated = Project.fromJson(
        legacyJson(schema: 4, items: [signalItem()]),
      );
      final side = migrated.documents.single.sides.single;
      expect(side.side, SideKind.unknown);
      final detection = side.detection!;
      expect(detection.detectionConfidence, isNull);
      expect(detection.producer, 'legacy-import');
      // No crop on the asset → the truthful full-frame box, never fabricated AI.
      expect(detection.polygon, isNotNull);
      expect(detection.polygon, hasLength(4));
      expect(detection.bbox, isNull);
      // No crop → no corners/output size; the working image is reused verbatim.
      expect(side.processedAsset.corners, isNull);
      expect(side.processedAsset.outputWidth, isNull);
      expect(side.processedAsset.effectiveDpi, isNull);
      expect(side.processedAsset.width, 400);
      expect(side.processedAsset.height, 250);
    });

    test('preset resolves for a known kind and awaits size for unknown', () {
      final known = Project.fromJson(
        legacyJson(schema: 4, items: [signalItem()]),
      ).documents.single;
      expect(known.recognition!.preset.awaitingSize, isFalse);
      expect(
        known.recognition!.preset.variantId,
        builtinVariantId(DocumentKind.unifiedNationalId),
      );
      final snapshot = Project.fromJson(
        legacyJson(schema: 4, items: [signalItem()]),
      ).items.single.presetSnapshot!;
      final expectedId = builtinVariantId(DocumentKind.unifiedNationalId);
      expect(snapshot.variantId, expectedId);
      expect(snapshot.status, PresetStatus.standard);
      expect(snapshot.widthMm, 85.6);
      expect(snapshot.heightMm, 53.98);
    });
  });

  group('idempotency', () {
    test('re-reading a migrated project never duplicates records', () {
      final first = Project.fromJson(
        legacyJson(schema: 4, items: [signalItem(), manualItem()]),
      );
      final json1 = first.toJson();
      final second = Project.fromJson(json1);
      expect(second.toJson(), json1);
      expect(second.documents, hasLength(1));
      expect(second.documents.single.id, 'rec-card');
    });

    test('v5 inline signal but no record stays as stored', () {
      // Freshly imported v5 (schemaVersion already 5) with documentKind set but
      // no synthesized record must NOT gain one on read.
      final json = Project(
        id: 'p1',
        name: 'v5',
        createdAt: DateTime.utc(2026, 10, 6),
        updatedAt: DateTime.utc(2026, 10, 6),
        assets: [legacyAsset()],
        items: [signalItem()],
      ).toJson();
      json['schemaVersion'] = Project.schemaVersion;
      json.remove('documents');
      json.remove('layoutGroups');
      final project = Project.fromJson(json);
      expect(project.documents, isEmpty);
      expect(project.items.single.documentId, isNull);
    });
  });

  group('schema gate', () {
    test('an unsupported future schema is rejected without touching data', () {
      final json = legacyJson(schema: 4, items: [signalItem()]);
      json['schemaVersion'] = Project.schemaVersion + 1;
      expect(() => Project.fromJson(json), throwsA(isA<ValidationException>()));
    });
  });

  group('bounds', () {
    test('records bounded by item limit — overflow throws', () {
      // One record but zero items violates documents.length <= items.length.
      expect(
        () => Project(
          id: 'p1',
          name: 'bounds',
          createdAt: DateTime.utc(2026, 10, 6),
          updatedAt: DateTime.utc(2026, 10, 6),
          items: const [],
          documents: [_minimalRecord('rec-1')],
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('too many items overflow deterministically without truncation', () {
      final items = [
        for (var i = 0; i < maxProjectItems + 1; i++)
          DocumentItem(
            id: 'i$i',
            assetId: 'a1',
            x: 0,
            y: 0,
            width: 10,
            height: 10,
          ),
      ];
      expect(
        () => Project(
          id: 'p1',
          name: 'bounds',
          createdAt: DateTime.utc(2026, 10, 6),
          updatedAt: DateTime.utc(2026, 10, 6),
          assets: [legacyAsset()],
          items: items,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('v4 behaviour', () {
    test('migration preserves the item recognition/layout fields verbatim', () {
      final migrated = Project.fromJson(
        legacyJson(schema: 4, items: [signalItem()]),
      );
      final item = migrated.items.single;
      // The layout/editor truth is untouched; only the record link is added.
      expect(item.documentKind, DocumentKind.unifiedNationalId);
      expect(item.recognitionConfidence, 0.9);
      expect(item.sizeConfirmed, isTrue);
      expect(item.width, 85.6);
      expect(item.height, 53.98);
      expect(item.documentId, 'rec-card');
    });
  });
}

DocumentRecord _minimalRecord(String id) => DocumentRecord(
  id: id,
  sourceImageId: 'a1',
  pairing: PairingState.single,
  provenance: Provenance(
    sourceImageId: 'a1',
    detectionIds: const ['a1'],
    processedAssetVersion: 'legacy-v4',
    pipelineVersion: 'legacy-v4',
  ),
  sides: [
    DocumentSide(
      id: 'side-$id',
      side: SideKind.front,
      processedAsset: ProcessedAssetRef(
        workingPath: 'projects/p1/assets/a1/working.png',
        thumbnailPath: 'projects/p1/assets/a1/thumb.jpg',
        width: 400,
        height: 250,
      ),
    ),
  ],
);
