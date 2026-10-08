import 'document_kind.dart';
import 'geometry.dart';
import 'validation.dart';
import 'image_limits.dart';

/// v5 recognition/provenance domain structures (Phase 1B).
///
/// These are inert data holders plus deterministic (de)serialization. No
/// recognition runtime, OCR, detector, classifier, pairing algorithm, or review
/// UI lives here — those are later phases. Legacy import populates these through
/// [synthesizeLegacyRecords] in `project.dart`, which never manufactures
/// evidence (see docs/DESIGN_LOCK.md §2).
///
/// Design-lock owners: a [DocumentRecord] is recognition/provenance/processing
/// truth; the layout item references it. Recognition evidence is immutable once
/// written; user divergence is recorded in [UserOverride], never by editing
/// evidence.

enum SideKind { front, back, unknown }

enum RecognitionStatus { recognized, unknown, uncertain }

enum EvidenceSource { visual, ocr, geometry, structure, aspect }

enum PairingState { single, paired, ambiguous, unknown }

enum GroupArrangement { stacked, sideBySide }

/// A single confidence value. [value] is a real measurement in 0..1; it is
/// never invented. An unavailable source is represented by the ABSENCE of a
/// [Confidence], never by a zero.
class Confidence {
  Confidence({required this.value, this.reason, this.producer, this.version}) {
    require(
      value.isFinite && value >= 0 && value <= 1,
      'قيمة الثقة يجب أن تكون بين 0 و1.',
    );
    if (reason != null) validNote(reason!);
    if (producer != null) validNote(producer!);
    if (version != null) validNote(version!);
  }
  final double value;
  final String? reason;
  final String? producer;
  final String? version;

  Map<String, Object?> toJson() => {
    'value': value,
    'reason': reason,
    'producer': producer,
    'version': version,
  };
  factory Confidence.fromJson(Object? json) {
    final m = objectMap(json);
    return Confidence(
      value: finiteNumber(m['value'], 'value'),
      reason: m['reason'] == null ? null : text(m['reason'], 'reason'),
      producer: m['producer'] == null ? null : text(m['producer'], 'producer'),
      version: m['version'] == null ? null : text(m['version'], 'version'),
    );
  }
}

/// The five fusion confidence dimensions defined in AUDIT.md §F (detection,
/// geometry, ocr, classification, final). Absent entries are omitted from JSON;
/// an unavailable dimension is ABSENT, never a fabricated zero (legacy import
/// leaves detection/geometry/ocr absent). Preset confidence is NOT one of these
/// — it lives on [PresetSelection] as `presetConfidence`.
class ConfidenceSet {
  const ConfidenceSet({
    this.detection,
    this.geometry,
    this.ocr,
    this.classification,
    this.finalConfidence,
  });
  final Confidence? detection;
  final Confidence? geometry;
  final Confidence? ocr;
  final Confidence? classification;

  /// Serialized under the key `final` (`final` is a reserved word in Dart).
  final Confidence? finalConfidence;

  Map<String, Object?> toJson() => {
    if (detection != null) 'detection': detection!.toJson(),
    if (geometry != null) 'geometry': geometry!.toJson(),
    if (ocr != null) 'ocr': ocr!.toJson(),
    if (classification != null) 'classification': classification!.toJson(),
    if (finalConfidence != null) 'final': finalConfidence!.toJson(),
  };
  factory ConfidenceSet.fromJson(Object? json) {
    final m = objectMap(json);
    return ConfidenceSet(
      detection: m['detection'] == null
          ? null
          : Confidence.fromJson(m['detection']),
      geometry: m['geometry'] == null
          ? null
          : Confidence.fromJson(m['geometry']),
      ocr: m['ocr'] == null ? null : Confidence.fromJson(m['ocr']),
      classification: m['classification'] == null
          ? null
          : Confidence.fromJson(m['classification']),
      finalConfidence: m['final'] == null
          ? null
          : Confidence.fromJson(m['final']),
    );
  }
}

/// One piece of recognition evidence. It carries a score and a machine reason
/// only — never OCR text or any personal value (see ADR-007).
class RecognitionEvidence {
  RecognitionEvidence({
    required this.source,
    required this.kind,
    required this.score,
    this.reason,
  }) {
    require(
      score.isFinite && score >= 0 && score <= 1,
      'score الدليل يجب أن يكون بين 0 و1.',
    );
    validNote(kind);
    if (reason != null) validNote(reason!);
  }
  final EvidenceSource source;
  final String kind;
  final double score;
  final String? reason;

  Map<String, Object?> toJson() => {
    'source': source.name,
    'kind': kind,
    'score': score,
    'reason': reason,
  };
  factory RecognitionEvidence.fromJson(Object? json) {
    final m = objectMap(json);
    return RecognitionEvidence(
      source: readEnum(EvidenceSource.values, m['source']),
      kind: text(m['kind'], 'kind'),
      score: finiteNumber(m['score'], 'score'),
      reason: m['reason'] == null ? null : text(m['reason'], 'reason'),
    );
  }
}

/// The preset decision for a recognized document: either a resolved variant, or
/// an explicit "awaiting size" with candidates. No confidence is invented.
///
/// [presetConfidence] is the confidence in the *preset match* itself. It is
/// deliberately distinct from [ConfidenceSet] — it is not one of the fusion
/// dimensions and never implies detection/geometry/ocr evidence.
class PresetSelection {
  const PresetSelection({
    this.variantId,
    this.presetConfidence,
    this.awaitingSize = false,
    this.candidates = const [],
  });
  const PresetSelection.resolved(this.variantId, {this.presetConfidence})
    : awaitingSize = false,
      candidates = const [];
  const PresetSelection.awaiting({this.candidates = const []})
    : variantId = null,
      presetConfidence = null,
      awaitingSize = true;
  final String? variantId;
  final double? presetConfidence;
  final bool awaitingSize;
  final List<String> candidates;

  Map<String, Object?> toJson() => {
    'variantId': variantId,
    'presetConfidence': presetConfidence,
    'awaitingSize': awaitingSize,
    'candidates': candidates,
  };
  factory PresetSelection.fromJson(Object? json) {
    final m = objectMap(json);
    final awaiting = boolean(m['awaitingSize'], 'awaitingSize');
    final presetConfidence = m['presetConfidence'] == null
        ? null
        : finiteNumber(m['presetConfidence'], 'presetConfidence');
    if (presetConfidence != null) {
      require(
        presetConfidence >= 0 && presetConfidence <= 1,
        'ثقة الاختيار المسبق خارج المجال.',
      );
    }
    return PresetSelection(
      variantId: m['variantId'] == null
          ? null
          : text(m['variantId'], 'variantId'),
      presetConfidence: presetConfidence,
      awaitingSize: awaiting,
      candidates: m['candidates'] == null
          ? const []
          : objectList(
              m['candidates'],
            ).map((v) => text(v, 'candidate')).toList(),
    );
  }
}

/// The recognition conclusion for a document. Immutable evidence.
class RecognitionResult {
  RecognitionResult({
    required this.documentKind,
    required this.status,
    required this.confidences,
    required this.preset,
    this.evidence = const [],
    this.pipelineVersion,
    this.modelVersions = const {},
    this.validated = false,
  }) {
    validNote(pipelineVersion ?? '');
    for (final entry in modelVersions.entries) {
      validId(entry.key);
      validNote(entry.value);
    }
    for (final e in evidence) {
      require(e.score.isFinite, 'دليل غير صالح.');
    }
  }
  final DocumentKind documentKind;
  final RecognitionStatus status;
  final ConfidenceSet confidences;
  final PresetSelection preset;
  final List<RecognitionEvidence> evidence;
  final String? pipelineVersion;
  final Map<String, String> modelVersions;
  final bool validated;

  Map<String, Object?> toJson() => {
    'documentKind': documentKind.name,
    'status': status.name,
    'confidences': confidences.toJson(),
    'preset': preset.toJson(),
    'evidence': evidence.map((e) => e.toJson()).toList(),
    'pipelineVersion': pipelineVersion,
    'modelVersions': modelVersions,
    'validated': validated,
  };
  factory RecognitionResult.fromJson(Object? json) {
    final m = objectMap(json);
    final versions = objectMap(m['modelVersions']).map(
      (k, v) => MapEntry(text(k, 'modelVersion key'), text(v, 'modelVersion')),
    );
    return RecognitionResult(
      documentKind: readEnum(DocumentKind.values, m['documentKind']),
      status: readEnum(RecognitionStatus.values, m['status']),
      confidences: ConfidenceSet.fromJson(m['confidences']),
      preset: PresetSelection.fromJson(m['preset']),
      evidence: m['evidence'] == null
          ? const []
          : objectList(
              m['evidence'],
            ).map(RecognitionEvidence.fromJson).toList(),
      pipelineVersion: m['pipelineVersion'] == null
          ? null
          : text(m['pipelineVersion'], 'pipelineVersion'),
      modelVersions: versions,
      validated: m['validated'] == null
          ? false
          : boolean(m['validated'], 'validated'),
    );
  }
}

/// A reference to a detection that produced a side. The boundary geometry lives
/// in the source crop / processed asset (single source of truth), so this only
/// records identity, producer, version, and the detection confidence when one
/// exists. Legacy import leaves [detectionConfidence] absent.
class DetectionRef {
  DetectionRef({
    required this.detectionId,
    required this.producer,
    required this.version,
    this.detectionConfidence,
    this.polygon,
    this.bbox,
  }) {
    validId(detectionId);
    validNote(producer);
    validNote(version);
    // Optional detector geometry (SCHEMA_V5 §4.6). Absent for legacy-imported
    // sides and for manual/deterministic sources that have no detector output.
    if (polygon != null) {
      require(polygon!.isNotEmpty, 'مضلع الكشف يجب أن يحتوي نقاطاً.');
      for (final p in polygon!) {
        require(p.x.isFinite && p.y.isFinite, 'نقاط الكشف غير صالحة.');
      }
    }
  }
  final String detectionId;
  final Confidence? detectionConfidence;
  final String producer;
  final String version;

  /// Detector polygon in source-image normalized coordinates, if produced.
  final List<Point2>? polygon;

  /// Detector bounding box in millimetres, if produced.
  final RectMm? bbox;

  Map<String, Object?> toJson() => {
    'detectionId': detectionId,
    'detectionConfidence': detectionConfidence?.toJson(),
    'producer': producer,
    'version': version,
    if (polygon != null) 'polygon': polygon!.map((p) => p.toJson()).toList(),
    if (bbox != null) 'bbox': bbox!.toJson(),
  };
  factory DetectionRef.fromJson(Object? json) {
    final m = objectMap(json);
    return DetectionRef(
      detectionId: text(m['detectionId'], 'detectionId'),
      detectionConfidence: m['detectionConfidence'] == null
          ? null
          : Confidence.fromJson(m['detectionConfidence']),
      producer: text(m['producer'], 'producer'),
      version: text(m['version'], 'version'),
      polygon: m['polygon'] == null
          ? null
          : objectList(m['polygon']).map(Point2.fromJson).toList(),
      bbox: m['bbox'] == null ? null : RectMm.fromJson(m['bbox']),
    );
  }
}

/// A reference to a derived, processed image. The persisted reference is the
/// authoritative part (DESIGN_LOCK.md §3); the file is a regenerable-in-
/// principle cache. [width]/[height] are the processed pixel dimensions.
class ProcessedAssetRef {
  ProcessedAssetRef({
    required this.workingPath,
    required this.thumbnailPath,
    required this.width,
    required this.height,
    this.orientation = 0,
    this.processingVersion,
    this.corners,
    this.outputWidth,
    this.outputHeight,
    this.effectiveDpi,
  }) {
    validAssetPath(workingPath);
    validAssetPath(thumbnailPath);
    require(
      workingPath != thumbnailPath,
      'مسارات الأصل المعالج يجب أن تكون مستقلة.',
    );
    require(withinImageBudget(width, height), 'أبعاد الأصل المعالج غير صالحة.');
    require(
      orientation >= 0 && orientation <= 3,
      'اتجاه الأصل المعالج غير صالح.',
    );
    if (processingVersion != null) validNote(processingVersion!);
    // Optional crop/deskew outputs (SCHEMA_V5 §4.5 / ADR-008). Absent means the
    // processed asset carried no crop geometry — never a fabricated rectangle.
    if (corners != null) {
      require(corners!.length == 4, 'يجب تحديد أربع زوايا.');
      for (final p in corners!) {
        require(p.x.isFinite && p.y.isFinite, 'زوايا الأصل المعالج غير صالحة.');
      }
    }
    if (outputWidth != null) {
      require(outputWidth! > 0, 'عرض مخرج المعالجة يجب أن يكون موجباً.');
    }
    if (outputHeight != null) {
      require(outputHeight! > 0, 'ارتفاع مخرج المعالجة يجب أن يكون موجباً.');
    }
    if (outputWidth != null && outputHeight != null) {
      require(
        withinImageBudget(outputWidth!, outputHeight!),
        'أبعاد مخرج المعالجة تتجاوز حد المعالجة الآمن.',
      );
    }
    if (effectiveDpi != null) {
      require(effectiveDpi! > 0, 'الدقة الفعلية يجب أن تكون موجبة.');
    }
  }
  final String workingPath;
  final String thumbnailPath;
  final int width;
  final int height;
  final int orientation;
  final String? processingVersion;

  /// Ordered TL, TR, BR, BL crop corners used to produce this asset, if any.
  final List<Point2>? corners;
  final int? outputWidth;
  final int? outputHeight;
  final int? effectiveDpi;

  Map<String, Object?> toJson() => {
    'workingPath': workingPath,
    'thumbnailPath': thumbnailPath,
    'width': width,
    'height': height,
    'orientation': orientation,
    'processingVersion': processingVersion,
    if (corners != null) 'corners': corners!.map((p) => p.toJson()).toList(),
    if (outputWidth != null) 'outputWidth': outputWidth,
    if (outputHeight != null) 'outputHeight': outputHeight,
    if (effectiveDpi != null) 'effectiveDpi': effectiveDpi,
  };
  factory ProcessedAssetRef.fromJson(Object? json) {
    final m = objectMap(json);
    return ProcessedAssetRef(
      workingPath: text(m['workingPath'], 'workingPath'),
      thumbnailPath: text(m['thumbnailPath'], 'thumbnailPath'),
      width: integer(m['width'], 'width'),
      height: integer(m['height'], 'height'),
      orientation: m['orientation'] == null
          ? 0
          : integer(m['orientation'], 'orientation'),
      processingVersion: m['processingVersion'] == null
          ? null
          : text(m['processingVersion'], 'processingVersion'),
      corners: m['corners'] == null
          ? null
          : objectList(m['corners']).map(Point2.fromJson).toList(),
      outputWidth: m['outputWidth'] == null
          ? null
          : integer(m['outputWidth'], 'outputWidth'),
      outputHeight: m['outputHeight'] == null
          ? null
          : integer(m['outputHeight'], 'outputHeight'),
      effectiveDpi: m['effectiveDpi'] == null
          ? null
          : integer(m['effectiveDpi'], 'effectiveDpi'),
    );
  }
}

/// One physical side (page) of a recognized document: front, back, or unknown.
class DocumentSide {
  DocumentSide({
    required this.id,
    required this.side,
    required this.processedAsset,
    this.detection,
  }) {
    validId(id);
  }
  final String id;
  final SideKind side;
  final ProcessedAssetRef processedAsset;
  final DetectionRef? detection;

  Map<String, Object?> toJson() => {
    'id': id,
    'side': side.name,
    'processedAsset': processedAsset.toJson(),
    'detection': detection?.toJson(),
  };
  factory DocumentSide.fromJson(Object? json) {
    final m = objectMap(json);
    return DocumentSide(
      id: text(m['id'], 'id'),
      side: readEnum(SideKind.values, m['side']),
      processedAsset: ProcessedAssetRef.fromJson(m['processedAsset']),
      detection: m['detection'] == null
          ? null
          : DetectionRef.fromJson(m['detection']),
    );
  }
}

/// Marks a record that was synthesized from a legacy (≤4) project, so it can
/// never be mistaken for modern detection/OCR/geometry analysis (DESIGN_LOCK
/// §2). No evidence is manufactured.
class LegacyImport {
  const LegacyImport({
    required this.schema,
    required this.field,
    required this.migrationVersion,
  });
  final int schema;
  final String field;
  final String migrationVersion;

  Map<String, Object?> toJson() => {
    'schema': schema,
    'field': field,
    'migrationVersion': migrationVersion,
  };
  factory LegacyImport.fromJson(Object? json) {
    final m = objectMap(json);
    return LegacyImport(
      schema: integer(m['schema'], 'schema'),
      field: text(m['field'], 'field'),
      migrationVersion: text(m['migrationVersion'], 'migrationVersion'),
    );
  }
}

/// Compact provenance chain. Carries no OCR text.
class Provenance {
  Provenance({
    required this.sourceImageId,
    required this.detectionIds,
    required this.processedAssetVersion,
    required this.pipelineVersion,
    this.modelVersions = const {},
    this.presetVariantId,
    this.overrideFields = const [],
    this.layoutItemIds = const [],
    this.importedFrom,
  }) {
    validId(sourceImageId);
    for (final id in detectionIds) {
      validId(id);
    }
    for (final id in layoutItemIds) {
      validId(id);
    }
    for (final f in overrideFields) {
      validNote(f);
    }
    validNote(processedAssetVersion);
    validNote(pipelineVersion);
    if (presetVariantId != null) validId(presetVariantId!);
    for (final entry in modelVersions.entries) {
      validId(entry.key);
      validNote(entry.value);
    }
  }
  final String sourceImageId;
  final List<String> detectionIds;
  final String processedAssetVersion;
  final String pipelineVersion;
  final Map<String, String> modelVersions;
  final String? presetVariantId;
  final List<String> overrideFields;
  final List<String> layoutItemIds;
  final LegacyImport? importedFrom;

  Map<String, Object?> toJson() => {
    'sourceImageId': sourceImageId,
    'detectionIds': detectionIds,
    'processedAssetVersion': processedAssetVersion,
    'pipelineVersion': pipelineVersion,
    'modelVersions': modelVersions,
    'presetVariantId': presetVariantId,
    'overrideFields': overrideFields,
    'layoutItemIds': layoutItemIds,
    'importedFrom': importedFrom?.toJson(),
  };
  factory Provenance.fromJson(Object? json) {
    final m = objectMap(json);
    final versions = objectMap(m['modelVersions']).map(
      (k, v) => MapEntry(text(k, 'modelVersion key'), text(v, 'modelVersion')),
    );
    return Provenance(
      sourceImageId: text(m['sourceImageId'], 'sourceImageId'),
      detectionIds: m['detectionIds'] == null
          ? const []
          : objectList(
              m['detectionIds'],
            ).map((v) => text(v, 'detectionId')).toList(),
      processedAssetVersion: text(
        m['processedAssetVersion'],
        'processedAssetVersion',
      ),
      pipelineVersion: text(m['pipelineVersion'], 'pipelineVersion'),
      modelVersions: versions,
      presetVariantId: m['presetVariantId'] == null
          ? null
          : text(m['presetVariantId'], 'presetVariantId'),
      overrideFields: m['overrideFields'] == null
          ? const []
          : objectList(
              m['overrideFields'],
            ).map((v) => text(v, 'field')).toList(),
      layoutItemIds: m['layoutItemIds'] == null
          ? const []
          : objectList(
              m['layoutItemIds'],
            ).map((v) => text(v, 'itemId')).toList(),
      importedFrom: m['importedFrom'] == null
          ? null
          : LegacyImport.fromJson(m['importedFrom']),
    );
  }
}

/// A deliberate user divergence from recognition evidence. It records what the
/// user chose; it never erases or mutates the recognition evidence itself.
class UserOverride {
  UserOverride({
    this.documentKind,
    this.presetVariantId,
    this.corners,
    this.side,
    this.pairing,
    this.dismissed,
    this.fields = const [],
  }) {
    if (presetVariantId != null) validId(presetVariantId!);
    for (final f in fields) {
      validNote(f);
    }
  }
  final DocumentKind? documentKind;
  final String? presetVariantId;
  final List<Point2>? corners;
  final SideKind? side;
  final PairingState? pairing;
  final bool? dismissed;
  final List<String> fields;

  Map<String, Object?> toJson() => {
    'documentKind': documentKind?.name,
    'presetVariantId': presetVariantId,
    'corners': corners?.map((p) => p.toJson()).toList(),
    'side': side?.name,
    'pairing': pairing?.name,
    'dismissed': dismissed,
    'fields': fields,
  };
  factory UserOverride.fromJson(Object? json) {
    final m = objectMap(json);
    return UserOverride(
      documentKind: m['documentKind'] == null
          ? null
          : readEnum(DocumentKind.values, m['documentKind']),
      presetVariantId: m['presetVariantId'] == null
          ? null
          : text(m['presetVariantId'], 'presetVariantId'),
      corners: m['corners'] == null
          ? null
          : objectList(m['corners']).map(Point2.fromJson).toList(),
      side: m['side'] == null ? null : readEnum(SideKind.values, m['side']),
      pairing: m['pairing'] == null
          ? null
          : readEnum(PairingState.values, m['pairing']),
      dismissed: m['dismissed'] == null
          ? null
          : boolean(m['dismissed'], 'dismissed'),
      fields: m['fields'] == null
          ? const []
          : objectList(m['fields']).map((v) => text(v, 'field')).toList(),
    );
  }
}

/// Recognition/provenance/processing truth for one document. Referenced by
/// layout items through `documentId`/`sideId`.
class DocumentRecord {
  DocumentRecord({
    required this.id,
    required this.sourceImageId,
    required this.sides,
    required this.pairing,
    required this.provenance,
    this.recognition,
    this.overrides = const [],
  }) {
    validId(id);
    validId(sourceImageId);
    require(
      sides.isNotEmpty && sides.length <= 2,
      'المستند يجب أن يحتوي وجهاً واحداً أو وجهين.',
    );
    require(
      sides.map((s) => s.id).toSet().length == sides.length,
      'أوجه المستند مكررة.',
    );
  }
  final String id;
  final String sourceImageId;
  final List<DocumentSide> sides;
  final RecognitionResult? recognition;
  final PairingState pairing;
  final Provenance provenance;
  final List<UserOverride> overrides;

  Map<String, Object?> toJson() => {
    'id': id,
    'sourceImageId': sourceImageId,
    'sides': sides.map((s) => s.toJson()).toList(),
    'recognition': recognition?.toJson(),
    'pairing': pairing.name,
    'provenance': provenance.toJson(),
    'overrides': overrides.map((o) => o.toJson()).toList(),
  };
  factory DocumentRecord.fromJson(Object? json) {
    final m = objectMap(json);
    return DocumentRecord(
      id: text(m['id'], 'id'),
      sourceImageId: text(m['sourceImageId'], 'sourceImageId'),
      sides: objectList(m['sides']).map(DocumentSide.fromJson).toList(),
      recognition: m['recognition'] == null
          ? null
          : RecognitionResult.fromJson(m['recognition']),
      pairing: readEnum(PairingState.values, m['pairing']),
      provenance: Provenance.fromJson(m['provenance']),
      overrides: m['overrides'] == null
          ? const []
          : objectList(m['overrides']).map(UserOverride.fromJson).toList(),
    );
  }
}

/// A keep-together grouping of layout items. Membership is owned here; items
/// reference it through `groupId`. No keep-together runtime in Phase 1B.
class LayoutGroup {
  LayoutGroup({
    required this.id,
    required this.itemIds,
    this.arrangement = GroupArrangement.stacked,
    this.keepTogether = true,
  }) {
    validId(id);
    require(
      itemIds.isNotEmpty && itemIds.length <= maxProjectItems,
      'مجموعة التخطيط خارج الحد.',
    );
    require(
      itemIds.toSet().length == itemIds.length,
      'عناصر مكررة في مجموعة التخطيط.',
    );
    for (final itemId in itemIds) {
      validId(itemId);
    }
  }
  final String id;
  final List<String> itemIds;
  final GroupArrangement arrangement;
  final bool keepTogether;

  Map<String, Object?> toJson() => {
    'id': id,
    'itemIds': itemIds,
    'arrangement': arrangement.name,
    'keepTogether': keepTogether,
  };
  factory LayoutGroup.fromJson(Object? json) {
    final m = objectMap(json);
    return LayoutGroup(
      id: text(m['id'], 'id'),
      itemIds: objectList(m['itemIds']).map((v) => text(v, 'itemId')).toList(),
      arrangement: m['arrangement'] == null
          ? GroupArrangement.stacked
          : readEnum(GroupArrangement.values, m['arrangement']),
      keepTogether: m['keepTogether'] == null
          ? true
          : boolean(m['keepTogether'], 'keepTogether'),
    );
  }
}

/// A processed-asset path must be owned by [projectId] and live under its
/// `assets/` (reused working image) or `processed/` subtree.
void validProcessedPath(String projectId, String path) {
  validAssetPath(path);
  require(
    path.startsWith('projects/$projectId/assets/') ||
        path.startsWith('projects/$projectId/processed/'),
    'مسار الأصل المعالج خارج ملكية المشروع.',
  );
}

/// Shared short-string check for producer/version/field/reason values: bounded,
/// no NUL, never empty when required.
void validNote(String value) => require(
  value.length <= 200 && !value.contains('\u0000'),
  'قيمة نصية غير صالحة.',
);
