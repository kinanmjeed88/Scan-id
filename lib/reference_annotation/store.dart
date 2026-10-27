import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../application/project_service.dart';
import '../domain/image_limits.dart';
import '../imaging/image_header.dart';
import '../imaging/prepare_image.dart';

const referenceSchema = 'scan-id-local-annotations-v2';
const referenceSchemaVersion = '2.0.0';
const referenceCoordinateSystem =
    'normalized_xy_after_exif_orientation_clockwise_from_display_top_left';
const referenceExifPolicy =
    'apply EXIF orientation (tag 274) before display and measurement; coordinates are [x/width_px, y/height_px] in [0, 1]';
const referencePiiPolicy =
    'boundary and document-kind labels only; never store personal names, ID numbers, filenames, or OCR text';
const referenceImageLimitBytes = 20 * 1024 * 1024;
const referenceDatasetLimitBytes = 128 * 1024 * 1024;

const referenceDocumentKinds = [
  'unknown',
  'unifiedNationalId',
  'residenceCard',
  'passport',
  'rationCard',
  'other',
];
const referenceBoundaryStatuses = [
  'complete',
  'occluded',
  'partial',
  'undeterminable',
];
const referenceAnnotationStatuses = [
  'unannotated',
  'in_progress',
  'annotated',
  'second_review',
  'excluded',
];
const referenceSuitabilityStatuses = [
  'annotatable',
  'unreadable',
  'unclear',
  'needs_review',
];
const referenceImageSources = [
  'camera_photo',
  'screenshot',
  'collage',
  'video_frame',
  'flatbed_or_web_scan',
  'synthetic_graphic',
  'unknown',
];
const referenceDifficultyFlags = [
  'occlusion',
  'partial_truncation',
  'glare',
  'blur',
  'severe_perspective',
  'document_overlap',
  'low_light',
  'compression',
  'laminated_outer_pouch',
  'other',
];

class ReferenceImportReport {
  const ReferenceImportReport({
    this.added = 0,
    this.exactDuplicates = 0,
    this.failures = const [],
  });

  final int added;
  final int exactDuplicates;
  final List<String> failures;
}

class ReferenceMergeReport {
  const ReferenceMergeReport({
    required this.added,
    required this.replaced,
    required this.retainedImages,
  });
  final int added;
  final int replaced;
  final int retainedImages;
}

/// Local-only v2 workspace. Image files and the resumable draft live in the
/// Android app's private support directory; exported JSON never contains paths
/// or image bytes. No network API is used by this class.
class ReferenceAnnotationStore {
  ReferenceAnnotationStore._(this.root);

  final Directory root;
  late final Directory _images = Directory(p.join(root.path, 'images'));
  late final File _draft = File(p.join(root.path, 'draft-v2.json'));
  final List<Map<String, Object?>> samples = [];

  static Future<ReferenceAnnotationStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return open(Directory(p.join(support.path, 'reference-annotation-v2')));
  }

  static Future<ReferenceAnnotationStore> open(Directory root) async {
    final store = ReferenceAnnotationStore._(root);
    await store._images.create(recursive: true);
    if (await store._draft.exists()) {
      final length = await store._draft.length();
      if (length > referenceDatasetLimitBytes) {
        throw const FormatException('مسودة الوسوم المحلية تتجاوز حد الحجم.');
      }
      final decoded = jsonDecode(await store._draft.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['draft_format'] != 'scan-id-reference-draft-v2' ||
          decoded['schema_version'] != referenceSchemaVersion ||
          decoded['samples'] is! List) {
        throw const FormatException(
          'المسودة المحلية تالفة أو من إصدار غير مدعوم.',
        );
      }
      store.samples.addAll((decoded['samples'] as List).map(_safeObjectMap));
      validateReferenceSamples(store.samples, allowUnmatchedImages: true);
    }
    return store;
  }

  Map<String, Object?> buildPayload({required String annotatorId}) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(annotatorId)) {
      throw const FormatException('رمز المراجع غير صالح.');
    }
    if (samples.isEmpty) {
      throw const FormatException('اختر صورة واحدة على الأقل قبل التصدير.');
    }
    final payload = <String, Object?>{
      'schema': referenceSchema,
      'schema_version': referenceSchemaVersion,
      'annotator_id': annotatorId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'coordinate_system': referenceCoordinateSystem,
      'exif_policy': referenceExifPolicy,
      'pii_policy': referencePiiPolicy,
      'samples': samples.map(_jsonCopy).toList(),
    };
    validateReferencePayload(payload);
    return payload;
  }

  Future<Uint8List> exportJson({
    required String annotatorId,
  }) async => Uint8List.fromList(
    utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(buildPayload(annotatorId: annotatorId))}\n',
    ),
  );

  Future<ReferenceImportReport> addImages(List<ImportSource> sources) async {
    var added = 0;
    var exactDuplicates = 0;
    final failures = <String>[];
    for (final source in sources) {
      try {
        final bytes = await _readBounded(
          source.openRead(),
          referenceImageLimitBytes,
        );
        final header = inspectImageHeader(bytes);
        final dhash = await Isolate.run(() => _validateAndHash(bytes));
        final sha = sha256.convert(bytes).toString();
        final existing = samples.indexWhere(
          (sample) => sample['image_id'] == sha,
        );
        if (existing >= 0) {
          // SHA-256 is the schema identity. Never replace an existing label just
          // because the same file was selected again; make the collision visible.
          // A JSON import may have the label but not the local image bytes, so
          // attach this exact file without changing that imported annotation.
          final sample = samples[existing];
          final oriented = header.orientation >= 5 && header.orientation <= 8;
          final width = oriented ? header.height : header.width;
          final height = oriented ? header.width : header.height;
          if (sample['raw_width_px'] != header.width ||
              sample['raw_height_px'] != header.height ||
              sample['exif_orientation'] != header.orientation ||
              sample['width_px'] != width ||
              sample['height_px'] != height ||
              sample['decode_status'] != 'ok') {
            throw const FormatException(
              'بيانات الصورة المستوردة لا تطابق الملف المطابق.',
            );
          }
          if ((sample['perceptual_dhash64'] as String? ?? '').isNotEmpty &&
              _hamming64(sample['perceptual_dhash64']! as String, dhash) > 4) {
            throw const FormatException(
              'بصمة التشابه المستوردة لا تطابق الصورة.',
            );
          }
          var metadataChanged = false;
          final format = header.encoding == ImageEncoding.jpeg ? 'jpeg' : 'png';
          if (sample['image_format'] != 'unknown' &&
              sample['image_format'] != format) {
            throw const FormatException(
              'صيغة الصورة المستوردة لا تطابق الملف المطابق.',
            );
          }
          if (sample['image_format'] == 'unknown') {
            sample['image_format'] = format;
            metadataChanged = true;
          }
          if ((sample['perceptual_dhash64'] as String? ?? '').isEmpty) {
            sample['perceptual_dhash64'] = dhash;
            metadataChanged = true;
          }
          await _writeImage(sha, format, bytes);
          if (metadataChanged) await saveDraft();
          exactDuplicates++;
          continue;
        }
        final oriented = header.orientation >= 5 && header.orientation <= 8;
        final width = oriented ? header.height : header.width;
        final height = oriented ? header.width : header.height;
        final cluster = _matchingCluster(dhash);
        final code = _nextInternalCode(samples);
        final sample = _newSample(
          imageId: sha,
          internalCode: code,
          format: header.encoding == ImageEncoding.jpeg ? 'jpeg' : 'png',
          rawWidth: header.width,
          rawHeight: header.height,
          orientation: header.orientation,
          width: width,
          height: height,
          dhash: dhash,
          duplicateCluster: cluster,
        );
        await _writeImage(sha, sample['image_format']! as String, bytes);
        samples.add(sample);
        added++;
      } catch (_) {
        // Do not write a filename, path, image bytes, exception text, or EXIF
        // string to the draft or logs. The caller gets a generic count only.
        failures.add('تعذر قراءة صورة محلية أو أن صيغتها/حجمها غير مدعومان.');
      } finally {
        try {
          await source.cleanup?.call();
        } catch (_) {
          // The selected original is never deleted; this only removes the
          // app-owned temporary copy made by Android's document picker.
        }
      }
    }
    if (added > 0) await saveDraft();
    return ReferenceImportReport(
      added: added,
      exactDuplicates: exactDuplicates,
      failures: failures,
    );
  }

  Future<void> importPayloadBytes(
    Uint8List bytes, {
    required bool replaceMatching,
  }) async {
    if (bytes.length > referenceDatasetLimitBytes) {
      throw const FormatException('ملف JSON يتجاوز حد الحجم المسموح.');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ملف JSON يجب أن يحتوي كائناً في الجذر.');
    }
    validateReferencePayload(decoded);
    final imported = (decoded['samples'] as List).map(_safeObjectMap).toList();
    final previous = samples.map(_jsonCopy).toList();
    final byId = {
      for (var i = 0; i < samples.length; i++)
        samples[i]['image_id'] as String: i,
    };
    final usedCodes = samples
        .map((sample) => sample['internal_code'])
        .whereType<String>()
        .where((code) => code.isNotEmpty)
        .toSet();
    var added = 0;
    var replaced = 0;
    var retainedImages = 0;
    try {
      for (final sample in imported) {
        final id = sample['image_id']! as String;
        final index = byId[id];
        if (index == null) {
          final code = sample['internal_code'] as String? ?? '';
          if (code.isNotEmpty && !usedCodes.add(code)) {
            final replacementCode = _nextInternalCode(samples);
            sample['internal_code'] = replacementCode;
            usedCodes.add(replacementCode);
          }
          samples.add(sample);
          byId[id] = samples.length - 1;
          added++;
        } else if (replaceMatching) {
          final localCode = samples[index]['internal_code'] as String? ?? '';
          final incomingCode = sample['internal_code'] as String? ?? '';
          if (localCode.isNotEmpty) {
            sample['internal_code'] = localCode;
          } else if (incomingCode.isNotEmpty && !usedCodes.add(incomingCode)) {
            final replacementCode = _nextInternalCode(samples);
            sample['internal_code'] = replacementCode;
            usedCodes.add(replacementCode);
          }
          samples[index] = sample;
          replaced++;
        } else {
          // Explicitly do not silently choose the incoming copy when local work
          // already exists. The UI asks before passing replaceMatching=true.
          retainedImages++;
        }
      }
      validateReferenceSamples(samples, allowUnmatchedImages: true);
      await saveDraft();
    } catch (_) {
      samples
        ..clear()
        ..addAll(previous);
      rethrow;
    }
    _lastMerge = ReferenceMergeReport(
      added: added,
      replaced: replaced,
      retainedImages: retainedImages,
    );
  }

  ReferenceMergeReport? _lastMerge;
  ReferenceMergeReport takeLastMergeReport() {
    final value = _lastMerge;
    if (value == null) throw StateError('No JSON import has completed.');
    _lastMerge = null;
    return value;
  }

  Future<void> updateSample(int index, Map<String, Object?> sample) async {
    if (index < 0 || index >= samples.length) {
      throw RangeError.index(index, samples);
    }
    final previous = samples[index];
    samples[index] = sample;
    try {
      validateReferenceSamples(samples, allowUnmatchedImages: true);
      await saveDraft();
    } catch (_) {
      samples[index] = previous;
      rethrow;
    }
  }

  Future<void> _saveTail = Future<void>.value();

  Future<void> saveDraft() {
    final saving = _saveTail.then((_) => _writeDraftAtomically());
    _saveTail = saving.catchError((Object _) {});
    return saving;
  }

  Future<void> _writeDraftAtomically() async {
    await root.create(recursive: true);
    final envelope = {
      'draft_format': 'scan-id-reference-draft-v2',
      'schema_version': referenceSchemaVersion,
      'samples': samples,
    };
    validateReferenceSamples(samples, allowUnmatchedImages: true);
    final temporary = File('${_draft.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(envelope),
      flush: true,
    );
    // Same-directory rename is atomic on Android/Linux; do not unlink the last
    // known-good draft before the replacement is ready.
    await temporary.rename(_draft.path);
  }

  Future<Uint8List?> readImage(String imageId, String format) async {
    final extension = format == 'jpeg'
        ? 'jpg'
        : format == 'png'
        ? 'png'
        : null;
    if (extension == null) return null;
    final file = File(p.join(_images.path, '$imageId.$extension'));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<bool> hasImage(Map<String, Object?> sample) async {
    final bytes = await readImage(
      sample['image_id']! as String,
      sample['image_format']! as String,
    );
    return bytes != null;
  }

  Future<void> _writeImage(
    String imageId,
    String format,
    Uint8List bytes,
  ) async {
    final extension = format == 'jpeg' ? 'jpg' : 'png';
    final file = File(p.join(_images.path, '$imageId.$extension'));
    if (await file.exists()) return;
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }

  String? _matchingCluster(String dhash) {
    for (final sample in samples) {
      final previous = sample['perceptual_dhash64'] as String? ?? '';
      if (previous.isNotEmpty && _hamming64(previous, dhash) <= 10) {
        final cluster = sample['near_duplicate_cluster_id'] as String? ?? '';
        if (cluster.isNotEmpty) return cluster;
        var sequence = 1;
        final used = samples.map((s) => s['near_duplicate_cluster_id']).toSet();
        while (used.contains(
          'dup-cluster-${sequence.toString().padLeft(2, '0')}',
        )) {
          sequence++;
        }
        final created = 'dup-cluster-${sequence.toString().padLeft(2, '0')}';
        sample['near_duplicate_cluster_id'] = created;
        return created;
      }
    }
    return null;
  }
}

String _nextInternalCode(Iterable<Map<String, Object?>> samples) {
  final used = samples.map((sample) => sample['internal_code']).toSet();
  var sequence = 1;
  while (used.contains('IMG-${sequence.toString().padLeft(2, '0')}')) {
    sequence++;
  }
  return 'IMG-${sequence.toString().padLeft(2, '0')}';
}

Map<String, Object?> _newSample({
  required String imageId,
  required String internalCode,
  required String format,
  required int rawWidth,
  required int rawHeight,
  required int orientation,
  required int width,
  required int height,
  required String dhash,
  required String? duplicateCluster,
}) => {
  'image_id': imageId,
  'internal_code': internalCode,
  'image_format': format,
  'decode_status': 'ok',
  'raw_width_px': rawWidth,
  'raw_height_px': rawHeight,
  'exif_orientation': orientation,
  'width_px': width,
  'height_px': height,
  'perceptual_dhash64': dhash,
  'near_duplicate_cluster_id': duplicateCluster ?? '',
  'image_source': 'unknown',
  'capture_group_id': '',
  'suitability_status': 'annotatable',
  'annotation_status': 'unannotated',
  'exclusion_reason': '',
  'image_quality_level': 'unassessed',
  'difficulty_reasons': <String>[],
  'annotator_id': '',
  'annotated_at': '',
  'second_review': {
    'status': 'not_started',
    'reviewer_id': '',
    'reviewed_at': '',
    'dispute_status': 'none',
    'adjudicator_id': '',
    'adjudicated_at': '',
    'resolution_code': '',
  },
  'no_document': false,
  'document_count': 1,
  'documents': [
    {
      'document_id': '$imageId-doc-01',
      'label_origin': 'human_manual',
      'human_verified': false,
      'document_kind': 'unknown',
      'boundary_status': 'complete',
      'corners': null,
      'visible_polygon': <List<Object?>>[],
      'crop_quality': 'uncertain',
      'quality_flags': <String>[],
    },
  ],
  'ai_suggestions': <Object?>[],
};

Map<String, Object?> newReferenceDocument(String imageId, int ordinal) => {
  'document_id': '$imageId-doc-${ordinal.toString().padLeft(2, '0')}',
  'label_origin': 'human_manual',
  'human_verified': false,
  'document_kind': 'unknown',
  'boundary_status': 'complete',
  'corners': null,
  'visible_polygon': <Object?>[],
  'crop_quality': 'uncertain',
  'quality_flags': <String>[],
};

Map<String, Object?> _safeObjectMap(Object? value) {
  if (value is! Map) {
    throw const FormatException('عنصر JSON ليس كائناً.');
  }
  return value.map((key, item) => MapEntry(key.toString(), item));
}

void _onlyKeys(Map<String, Object?> object, Set<String> allowed) {
  if (object.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('يحتوي الملف حقولاً غير معروفة أو غير مسموحة.');
  }
}

void _rejectPrivateFields(Object? value) {
  const forbidden = {
    'file',
    'filename',
    'basename',
    'name',
    'full_name',
    'person_name',
    'holder_name',
    'id_number',
    'national_id',
    'passport_number',
    'ration_number',
    'address',
    'birth_date',
    'dob',
    'ocr_text',
    'ocr_reference_text',
    'transcript',
    'source_name',
    'original_name',
    'path',
    'filepath',
    'local_path',
    'source_path',
    'original_path',
    'uri',
  };
  if (value is Map) {
    for (final entry in value.entries) {
      if (forbidden.contains(entry.key.toString().toLowerCase())) {
        throw const FormatException(
          'يحتوي الملف حقلاً شخصياً أو مساراً محلياً ممنوعاً.',
        );
      }
      _rejectPrivateFields(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      _rejectPrivateFields(item);
    }
  }
}

void _validateStringSet(Object? value, List<String> allowed, String label) {
  if (value is! List ||
      value.any((item) => item is! String || !allowed.contains(item)) ||
      value.toSet().length != value.length) {
    throw FormatException('$label غير صالحة أو مكررة.');
  }
}

void _validateSecondReview(
  Object? value, {
  required String annotationStatus,
  required String primaryAnnotator,
}) {
  if (value is! Map) {
    throw const FormatException('بيانات المراجعة الثانية غير مكتملة.');
  }
  final review = _safeObjectMap(value);
  _onlyKeys(review, {
    'status',
    'reviewer_id',
    'reviewed_at',
    'dispute_status',
    'adjudicator_id',
    'adjudicated_at',
    'resolution_code',
  });
  const required = {
    'status',
    'reviewer_id',
    'reviewed_at',
    'dispute_status',
    'adjudicator_id',
    'adjudicated_at',
    'resolution_code',
  };
  if (!review.keys.toSet().containsAll(required) ||
      ![
        'not_started',
        'agreed',
        'disputed',
        'resolved',
        'excluded_after_dispute',
      ].contains(review['status']) ||
      ![
        'none',
        'open_dispute',
        'resolved_by_protocol',
        'excluded_unresolvable',
      ].contains(review['dispute_status']) ||
      ![
        '',
        'unanimous_primary_and_secondary',
        'adjudicated_visible_boundary',
        'adjudicated_kind_to_unknown',
        'adjudicated_boundary_undeterminable',
        'excluded_due_to_ambiguity',
      ].contains(review['resolution_code']) ||
      review['reviewer_id'] is! String ||
      review['adjudicator_id'] is! String ||
      review['reviewed_at'] is! String ||
      review['adjudicated_at'] is! String) {
    throw const FormatException(
      'بيانات المراجعة الثانية غير متوافقة مع v2.0.0.',
    );
  }
  for (final key in ['reviewer_id', 'adjudicator_id']) {
    final id = review[key]! as String;
    if (id.isNotEmpty && !RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(id)) {
      throw const FormatException('رمز المراجع أو المحكم غير صالح.');
    }
  }
  final status = review['status'];
  final reviewer = review['reviewer_id']! as String;
  final reviewedAt = review['reviewed_at']! as String;
  final adjudicator = review['adjudicator_id']! as String;
  final adjudicatedAt = review['adjudicated_at']! as String;
  final dispute = review['dispute_status'];
  final resolution = review['resolution_code'];
  if (reviewedAt.length > 40 ||
      adjudicatedAt.length > 40 ||
      (status == 'not_started' &&
          (annotationStatus == 'second_review' ||
              dispute != 'none' ||
              resolution != '')) ||
      (status != 'not_started' &&
          (reviewer.isEmpty ||
              reviewedAt.isEmpty ||
              reviewer == primaryAnnotator)) ||
      (status == 'disputed' && dispute != 'open_dispute') ||
      (status == 'resolved' &&
          (dispute != 'resolved_by_protocol' ||
              adjudicator.isEmpty ||
              adjudicatedAt.isEmpty ||
              resolution == '')) ||
      (status == 'excluded_after_dispute' &&
          (annotationStatus != 'excluded' ||
              dispute != 'excluded_unresolvable'))) {
    throw const FormatException('حالة المراجعة لا تحقق بروتوكول v2.0.0.');
  }
}

bool _validPolygon(List<dynamic> points, int width, int height) {
  if (points.length < 3 ||
      points.length > 12 ||
      points.any(
        (point) =>
            point is! List ||
            point.length != 2 ||
            point.any(
              (value) =>
                  value is! num || !value.isFinite || value < 0 || value > 1,
            ),
      )) {
    return false;
  }
  final xy = points
      .map(
        (point) => [(point[0] as num).toDouble(), (point[1] as num).toDouble()],
      )
      .toList();
  for (var i = 0; i < xy.length; i++) {
    for (var j = i + 1; j < xy.length; j++) {
      final dx = xy[i][0] - xy[j][0];
      final dy = xy[i][1] - xy[j][1];
      if (dx * dx + dy * dy < 0.005 * 0.005 ||
          math.sqrt(dx * dx * width * width + dy * dy * height * height) < 2) {
        return false;
      }
    }
  }
  var area = 0.0;
  for (var i = 0; i < xy.length; i++) {
    final a = xy[i], b = xy[(i + 1) % xy.length];
    area += a[0] * b[1] - b[0] * a[1];
  }
  if (area < 0.0002) return false;
  for (var i = 0; i < xy.length; i++) {
    for (var j = i + 1; j < xy.length; j++) {
      if (j == i + 1 || (i == 0 && j == xy.length - 1)) continue;
      if (_segmentsIntersectOrTouch(
        xy[i],
        xy[(i + 1) % xy.length],
        xy[j],
        xy[(j + 1) % xy.length],
      )) {
        return false;
      }
    }
  }
  return true;
}

bool _segmentsIntersectOrTouch(
  List<double> a,
  List<double> b,
  List<double> c,
  List<double> d,
) {
  double orient(List<double> p, List<double> q, List<double> r) =>
      (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
  bool onSegment(List<double> p, List<double> q, List<double> r) =>
      q[0] >= math.min(p[0], r[0]) - 1e-12 &&
      q[0] <= math.max(p[0], r[0]) + 1e-12 &&
      q[1] >= math.min(p[1], r[1]) - 1e-12 &&
      q[1] <= math.max(p[1], r[1]) + 1e-12;
  final o1 = orient(a, b, c), o2 = orient(a, b, d);
  final o3 = orient(c, d, a), o4 = orient(c, d, b);
  if (o1 * o2 < 0 && o3 * o4 < 0) return true;
  return (o1.abs() <= 1e-12 && onSegment(a, c, b)) ||
      (o2.abs() <= 1e-12 && onSegment(a, d, b)) ||
      (o3.abs() <= 1e-12 && onSegment(c, a, d)) ||
      (o4.abs() <= 1e-12 && onSegment(c, b, d));
}

Map<String, Object?> _jsonCopy(Map<String, Object?> map) =>
    _safeObjectMap(jsonDecode(jsonEncode(map)));

Future<Uint8List> _readBounded(Stream<List<int>> stream, int limit) async {
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in stream) {
    total += chunk.length;
    if (total > limit) throw const FormatException('تجاوز الملف الحد المسموح.');
    builder.add(chunk);
  }
  return builder.takeBytes();
}

String _validateAndHash(Uint8List bytes) {
  final image = decodeForProcessing(bytes);
  return _dhash64(image);
}

String _dhash64(img.Image image) {
  // Match validate_local_annotations.py: EXIF-orient, convert to grayscale,
  // then bilinear-resize to 9x8 and compare adjacent pixels left-to-right.
  final gray = image.convert(numChannels: 1);
  final resized = img.copyResize(
    gray,
    width: 9,
    height: 8,
    interpolation: img.Interpolation.linear,
  );
  var bits = BigInt.zero;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      bits =
          (bits << 1) |
          (resized.getPixel(x + 1, y).r > resized.getPixel(x, y).r
              ? BigInt.one
              : BigInt.zero);
    }
  }
  return bits.toRadixString(16).padLeft(16, '0');
}

int _hamming64(String a, String b) =>
    (BigInt.parse(a, radix: 16) ^ BigInt.parse(b, radix: 16))
        .toRadixString(2)
        .replaceAll('0', '')
        .length;

void validateReferencePayload(Map<String, dynamic> payload) {
  _rejectPrivateFields(payload);
  _onlyKeys(payload, {
    'schema',
    'schema_version',
    'annotator_id',
    'created_at',
    'coordinate_system',
    'exif_policy',
    'pii_policy',
    'samples',
  });
  if (payload['schema'] != referenceSchema ||
      payload['schema_version'] != referenceSchemaVersion ||
      payload['coordinate_system'] != referenceCoordinateSystem ||
      payload['created_at'] is! String ||
      (payload['created_at'] as String).trim().length < 10 ||
      (payload['created_at'] as String).length > 40 ||
      payload['exif_policy'] is! String ||
      (payload['exif_policy'] as String).trim().length < 10 ||
      (payload['exif_policy'] as String).length > 400 ||
      payload['pii_policy'] is! String ||
      (payload['pii_policy'] as String).trim().length < 10 ||
      (payload['pii_policy'] as String).length > 400 ||
      payload['samples'] is! List ||
      (payload['samples'] as List).isEmpty) {
    throw const FormatException('ملف JSON ليس مخطط v2.0.0 مدعوماً.');
  }
  final id = payload['annotator_id'];
  if (id is! String || !RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(id)) {
    throw const FormatException('رمز الموسِّم في الملف غير صالح.');
  }
  validateReferenceSamples(
    (payload['samples'] as List).map(_safeObjectMap).toList(),
  );
}

void validateReferenceSamples(
  List<Map<String, Object?>> values, {
  bool allowUnmatchedImages = false,
}) {
  final imageIds = <String>{};
  final internalCodes = <String>{};
  final documentIds = <String>{};
  final suggestionIds = <String>{};
  for (final sample in values) {
    _onlyKeys(sample, {
      'image_id',
      'internal_code',
      'image_format',
      'decode_status',
      'raw_width_px',
      'raw_height_px',
      'exif_orientation',
      'width_px',
      'height_px',
      'perceptual_dhash64',
      'near_duplicate_cluster_id',
      'image_source',
      'capture_group_id',
      'suitability_status',
      'annotation_status',
      'exclusion_reason',
      'image_quality_level',
      'difficulty_reasons',
      'annotator_id',
      'annotated_at',
      'second_review',
      'no_document',
      'document_count',
      'documents',
      'ai_suggestions',
    });
    const required = {
      'image_id',
      'image_format',
      'decode_status',
      'raw_width_px',
      'raw_height_px',
      'exif_orientation',
      'width_px',
      'height_px',
      'image_source',
      'capture_group_id',
      'suitability_status',
      'annotation_status',
      'exclusion_reason',
      'image_quality_level',
      'difficulty_reasons',
      'annotator_id',
      'annotated_at',
      'second_review',
      'no_document',
      'document_count',
      'documents',
    };
    if (!sample.keys.toSet().containsAll(required)) {
      throw const FormatException('حقول الصورة المطلوبة غير مكتملة.');
    }
    final imageId = sample['image_id'];
    if (imageId is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(imageId) ||
        !imageIds.add(imageId)) {
      throw const FormatException('معرّف صورة مكرر أو غير صالح.');
    }
    final format = sample['image_format'];
    if (!['jpeg', 'png', 'webp', 'bmp', 'unknown'].contains(format) ||
        !['ok', 'failed'].contains(sample['decode_status'])) {
      throw const FormatException('صيغة صورة أو حالة فك ترميز غير صالحة.');
    }
    final code = sample['internal_code'];
    if (code != null &&
        code != '' &&
        (code is! String ||
            !RegExp(r'^[A-Z]{2,8}-[0-9]{2,5}$').hasMatch(code) ||
            !internalCodes.add(code))) {
      throw const FormatException('الرمز الداخلي للصورة غير صالح أو مكرر.');
    }
    final dhash = sample['perceptual_dhash64'];
    if (dhash != null &&
        dhash != '' &&
        (dhash is! String || !RegExp(r'^[0-9a-f]{16}$').hasMatch(dhash))) {
      throw const FormatException('بصمة التشابه غير صالحة.');
    }
    for (final key in ['capture_group_id', 'near_duplicate_cluster_id']) {
      final value = sample[key];
      final pattern = key == 'near_duplicate_cluster_id'
          ? r'^[A-Za-z0-9_.-]{1,64}$'
          : r'^[A-Za-z0-9_.-]{1,80}$';
      if (value != null &&
          value != '' &&
          (value is! String || !RegExp(pattern).hasMatch(value))) {
        throw const FormatException('رمز مجموعة الالتقاط أو التشابه غير صالح.');
      }
    }
    if (![
      'good',
      'medium',
      'poor',
      'unusable',
      'unassessed',
    ].contains(sample['image_quality_level'])) {
      throw const FormatException('تقييم جودة الصورة غير صالح.');
    }
    _validateStringSet(
      sample['difficulty_reasons'],
      referenceDifficultyFlags,
      'أسباب صعوبة الصورة',
    );
    for (final key in [
      'raw_width_px',
      'raw_height_px',
      'width_px',
      'height_px',
    ]) {
      if (sample[key] is! int || (sample[key] as int) < 0) {
        throw const FormatException('أبعاد الصورة غير صالحة.');
      }
    }
    final orientation = sample['exif_orientation'];
    if (orientation is! int || orientation < 0 || orientation > 8) {
      throw const FormatException('توجيه EXIF غير صالح.');
    }
    if (!referenceImageSources.contains(sample['image_source']) ||
        !referenceAnnotationStatuses.contains(sample['annotation_status']) ||
        !referenceSuitabilityStatuses.contains(sample['suitability_status']) ||
        ![
          '',
          'decode_failed',
          'exact_or_near_duplicate',
          'video_or_ui_recording',
          'backup_container',
          'synthetic_or_promotional_mockup',
          'pre_cropped_no_background',
          'unreadable_or_extreme_blur',
          'boundary_unscorable',
          'unresolved_annotator_dispute',
        ].contains(sample['exclusion_reason']) ||
        sample['no_document'] is! bool ||
        sample['annotator_id'] is! String ||
        (sample['annotator_id'] as String).isNotEmpty &&
            !RegExp(
              r'^[A-Za-z0-9_-]{1,32}$',
            ).hasMatch(sample['annotator_id'] as String) ||
        sample['annotated_at'] is! String ||
        (sample['annotated_at'] as String).length > 40) {
      throw const FormatException(
        'مصدر الصورة أو حالتها أو بيانات المراجعة غير صالحة.',
      );
    }
    final status = sample['annotation_status']! as String;
    final primaryAnnotator = sample['annotator_id']! as String;
    final annotatedAt = sample['annotated_at']! as String;
    if (['annotated', 'second_review'].contains(status) &&
        (primaryAnnotator.isEmpty || annotatedAt.isEmpty)) {
      throw const FormatException(
        'الوسم المعتمد يحتاج رمز موسِّم ووقت اعتماد.',
      );
    }
    _validateSecondReview(
      sample['second_review'],
      annotationStatus: status,
      primaryAnnotator: primaryAnnotator,
    );
    final noDocument = sample['no_document'] == true;
    final documents = sample['documents'];
    if (documents is! List ||
        sample['document_count'] is! int ||
        sample['document_count'] != (noDocument ? 0 : documents.length) ||
        (noDocument && documents.isNotEmpty)) {
      throw const FormatException('عدد المستندات لا يطابق القائمة.');
    }
    final finalHuman = [
      'annotated',
      'second_review',
    ].contains(sample['annotation_status']);
    if (finalHuman && sample['suitability_status'] == 'unreadable') {
      throw const FormatException(
        'الصورة غير المقروءة لا يمكن اعتمادها؛ استبعدها بدلاً من ذلك.',
      );
    }
    if (finalHuman && !noDocument && documents.isEmpty) {
      throw const FormatException(
        'الوسم النهائي يحتاج مستنداً واحداً على الأقل أو تحديد عينة خلفية.',
      );
    }
    if (sample['annotation_status'] == 'excluded' &&
            (sample['exclusion_reason'] is! String ||
                (sample['exclusion_reason'] as String).isEmpty) ||
        sample['annotation_status'] != 'excluded' &&
            sample['exclusion_reason'] != '') {
      throw const FormatException('سبب الاستبعاد لا يطابق حالة الصورة.');
    }
    if (sample['decode_status'] == 'ok') {
      if (sample['raw_width_px'] == 0 ||
          sample['raw_height_px'] == 0 ||
          sample['width_px'] == 0 ||
          sample['height_px'] == 0) {
        throw const FormatException(
          'أبعاد الصورة القابلة للقراءة يجب أن تكون موجبة.',
        );
      }
      final swapped = orientation >= 5 && orientation <= 8;
      if (sample['width_px'] !=
              (swapped ? sample['raw_height_px'] : sample['raw_width_px']) ||
          sample['height_px'] !=
              (swapped ? sample['raw_width_px'] : sample['raw_height_px'])) {
        throw const FormatException(
          'الأبعاد الموجهة لا تطابق EXIF والأبعاد الخام.',
        );
      }
    } else if (sample['raw_width_px'] != 0 ||
        sample['raw_height_px'] != 0 ||
        sample['width_px'] != 0 ||
        sample['height_px'] != 0 ||
        sample['annotation_status'] != 'excluded' ||
        sample['exclusion_reason'] != 'decode_failed' ||
        sample['suitability_status'] != 'unreadable') {
      throw const FormatException(
        'فشل فك الترميز يتطلب أبعاداً صفراً واستبعاد الصورة.',
      );
    }
    final suggestions = sample['ai_suggestions'];
    if (suggestions != null) {
      if (suggestions is! List) {
        throw const FormatException('مقترحات الذكاء الاصطناعي غير صالحة.');
      }
      for (final rawSuggestion in suggestions) {
        final suggestion = _safeObjectMap(rawSuggestion);
        _onlyKeys(suggestion, {
          'suggestion_id',
          'proposal_source',
          'corners',
          'region_bbox',
          'confidence',
          'gate_verdict',
        });
        final suggestionId = suggestion['suggestion_id'];
        final confidence = suggestion['confidence'];
        if (suggestionId is! String ||
            !RegExp(r'^[A-Za-z0-9_.:-]{3,80}$').hasMatch(suggestionId) ||
            !suggestionIds.add(suggestionId) ||
            ![
              'frozen_ai_hybrid',
              'classical_only',
              'external_detector',
            ].contains(suggestion['proposal_source']) ||
            confidence is! num ||
            !confidence.isFinite ||
            confidence < 0 ||
            confidence > 1 ||
            ![
              'accepted',
              'needsReview',
              'rejected',
              'unknown',
            ].contains(suggestion['gate_verdict'])) {
          throw const FormatException('اقتراح آلي غير متوافق مع v2.0.0.');
        }
        final suggestedCorners = suggestion['corners'];
        if (suggestedCorners != null &&
            (suggestedCorners is! List ||
                suggestedCorners.length != 4 ||
                !_validPolygon(
                  suggestedCorners,
                  sample['width_px']! as int,
                  sample['height_px']! as int,
                ))) {
          throw const FormatException('زوايا الاقتراح الآلي غير صالحة.');
        }
        final bbox = suggestion['region_bbox'];
        if (bbox != null &&
            (bbox is! List ||
                bbox.length != 4 ||
                bbox.any((v) => v is! num || !v.isFinite || v < 0 || v > 1) ||
                (bbox[2] as num) <= (bbox[0] as num) ||
                (bbox[3] as num) <= (bbox[1] as num))) {
          throw const FormatException('صندوق الاقتراح الآلي غير صالح.');
        }
      }
    }
    for (final rawDocument in documents) {
      final document = _safeObjectMap(rawDocument);
      _onlyKeys(document, {
        'document_id',
        'label_origin',
        'human_verified',
        'document_kind',
        'boundary_status',
        'corners',
        'visible_polygon',
        'crop_quality',
        'quality_flags',
      });
      const requiredDocumentKeys = {
        'document_id',
        'label_origin',
        'human_verified',
        'document_kind',
        'boundary_status',
        'corners',
        'visible_polygon',
        'crop_quality',
        'quality_flags',
      };
      if (!document.keys.toSet().containsAll(requiredDocumentKeys)) {
        throw const FormatException('حقول المستند المطلوبة غير مكتملة.');
      }
      final docId = document['document_id'];
      if (docId is! String ||
          !RegExp(r'^[A-Za-z0-9_.:-]{3,80}$').hasMatch(docId) ||
          !documentIds.add(docId)) {
        throw const FormatException('معرّف مستند مكرر أو غير صالح.');
      }
      if (!referenceDocumentKinds.contains(document['document_kind']) ||
          !referenceBoundaryStatuses.contains(document['boundary_status']) ||
          ![
            'human_manual',
            'human_verified_from_suggestion',
          ].contains(document['label_origin']) ||
          document['human_verified'] is! bool) {
        throw const FormatException('تصنيف أو حد أو مصدر وسم غير صالح.');
      }
      final polygon = document['visible_polygon'];
      if (polygon is! List || polygon.length > 12) {
        throw const FormatException('المضلع المرئي غير صالح.');
      }
      for (final point in polygon) {
        if (point is! List ||
            point.length != 2 ||
            point.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
          throw const FormatException('إحداثيات نقطة خارج [0, 1].');
        }
      }
      final boundary = document['boundary_status'];
      final corners = document['corners'];
      if (boundary == 'undeterminable') {
        if (corners != null || polygon.isNotEmpty) {
          throw const FormatException(
            'الحد غير المحدد يجب أن يبقى بلا مضلع أو زوايا.',
          );
        }
      } else if (boundary == 'complete') {
        if (polygon.isEmpty && corners == null && !finalHuman) {
          // A blank draft is valid until the annotator completes it.
        } else if (polygon.length != 4 ||
            !_validClockwiseQuad(
              polygon,
              sample['width_px']! as int,
              sample['height_px']! as int,
            )) {
          throw const FormatException(
            'الرباعي الكامل يجب أن يكون TL→TR→BR→BL صالحاً.',
          );
        } else if (corners is! List ||
            jsonEncode(corners) != jsonEncode(polygon)) {
          throw const FormatException('قائمة الزوايا لا تطابق المضلع المرئي.');
        }
      } else {
        if (corners != null &&
            (corners is! List ||
                corners.length != 4 ||
                !_validClockwiseQuad(
                  corners,
                  sample['width_px']! as int,
                  sample['height_px']! as int,
                ))) {
          throw const FormatException(
            'زوايا المستند المحجوب/المقطوع غير صالحة.',
          );
        }
        if (polygon.length < 3 && finalHuman) {
          throw const FormatException(
            'الوسم النهائي يحتاج مضلعاً مرئياً من 3 نقاط على الأقل.',
          );
        }
        if (polygon.length >= 3 &&
            !_validPolygon(
              polygon,
              sample['width_px']! as int,
              sample['height_px']! as int,
            )) {
          throw const FormatException('مضلع الجزء المرئي غير صالح.');
        }
      }
      if (document['crop_quality'] is! String ||
          ![
            'acceptable',
            'unacceptable',
            'uncertain',
            'not_applicable',
          ].contains(document['crop_quality'])) {
        throw const FormatException('صلاحية القص غير صالحة.');
      }
      _validateStringSet(
        document['quality_flags'],
        referenceDifficultyFlags,
        'أسباب صعوبة المستند',
      );
      if (finalHuman &&
          (document['human_verified'] != true ||
              sample['suitability_status'] == 'unreadable')) {
        throw const FormatException(
          'اعتماد الوسم يتطلب تحققاً بشرياً وصورة قابلة للقراءة.',
        );
      }
      if (sample['decode_status'] == 'failed' &&
          (sample['raw_width_px'] != 0 ||
              sample['raw_height_px'] != 0 ||
              sample['width_px'] != 0 ||
              sample['height_px'] != 0)) {
        throw const FormatException('صورة فشل فكها يجب أن تسجل أبعاداً صفرية.');
      }
      if (!allowUnmatchedImages &&
          sample['decode_status'] == 'ok' &&
          sample['width_px'] == 0) {
        throw const FormatException('أبعاد صورة قابلة للقراءة فارغة.');
      }
    }
  }
}

bool _validClockwiseQuad(List<dynamic> points, int width, int height) {
  if (points.length != 4 || !_validPolygon(points, width, height)) return false;
  final xy = points
      .map(
        (point) => [(point[0] as num).toDouble(), (point[1] as num).toDouble()],
      )
      .toList();
  for (var i = 0; i < 4; i++) {
    final a = xy[i], b = xy[(i + 1) % 4], c = xy[(i + 2) % 4];
    final cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    if (cross <= 0.000001) return false;
  }
  var start = 0;
  for (var i = 1; i < 4; i++) {
    final sum = double.parse((xy[i][0] + xy[i][1]).toStringAsFixed(6));
    final startSum = double.parse(
      (xy[start][0] + xy[start][1]).toStringAsFixed(6),
    );
    final y = double.parse(xy[i][1].toStringAsFixed(6));
    final startY = double.parse(xy[start][1].toStringAsFixed(6));
    if (sum < startSum || (sum == startSum && y < startY)) start = i;
  }
  final firstSum = xy[0][0] + xy[0][1];
  final expectedSum = xy[start][0] + xy[start][1];
  return start == 0 || firstSum - expectedSum <= 1e-4;
}
