import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../application/native_documents.dart';
import '../imaging/prepare_image.dart';
import 'store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReferenceAnnotatorApp());
}

class ReferenceAnnotatorApp extends StatelessWidget {
  const ReferenceAnnotatorApp({super.key, this.store});
  final ReferenceAnnotationStore? store;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'استوديو الوسوم المرجعية',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff12685e)),
      scaffoldBackgroundColor: const Color(0xfff5f7f6),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: ReferenceAnnotationStudio(store: store),
  );
}

class ReferenceAnnotationStudio extends StatefulWidget {
  const ReferenceAnnotationStudio({super.key, this.store});
  final ReferenceAnnotationStore? store;

  @override
  State<ReferenceAnnotationStudio> createState() =>
      _ReferenceAnnotationStudioState();
}

class _ReferenceAnnotationStudioState extends State<ReferenceAnnotationStudio> {
  ReferenceAnnotationStore? _store;
  Uint8List? _preview;
  String _reviewer = 'R1';
  final Map<String, String> _captureDrafts = {};
  final Map<String, String> _reviewDrafts = {};
  int _selected = 0;
  int _activeDocument = 0;
  bool _panMode = false;
  bool _editingCompleteQuad = false;
  bool _busy = false;
  String? _error;
  final TransformationController _transform = TransformationController();

  Map<String, Object?>? get _sample {
    final store = _store;
    if (store == null || _selected < 0 || _selected >= store.samples.length) {
      return null;
    }
    return store.samples[_selected];
  }

  List<Map<String, Object?>> get _documents {
    final raw = _sample?['documents'];
    if (raw is! List) return [];
    return raw.map((value) => Map<String, Object?>.from(value as Map)).toList();
  }

  Map<String, Object?>? get _document {
    final documents = _documents;
    if (_activeDocument < 0 || _activeDocument >= documents.length) return null;
    return documents[_activeDocument];
  }

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final store =
          widget.store ?? await ReferenceAnnotationStore.openDefault();
      if (!mounted) return;
      setState(() {
        _store = store;
        _error = null;
      });
      await _loadPreview();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'تعذر فتح مساحة الوسوم المحلية. لم تُحذف أي بيانات.',
        );
      }
    }
  }

  Future<void> _loadPreview() async {
    final sample = _sample;
    final store = _store;
    if (sample == null || store == null) {
      if (mounted) setState(() => _preview = null);
      return;
    }
    try {
      final bytes = await store.readImage(
        sample['image_id']! as String,
        sample['image_format']! as String,
      );
      if (bytes == null) {
        if (mounted) setState(() => _preview = null);
        return;
      }
      final preview = await Isolate.run(() => prepareBoundedPreview(bytes));
      if (mounted && _sample?['image_id'] == sample['image_id']) {
        setState(() => _preview = preview);
      }
    } catch (_) {
      if (mounted) setState(() => _preview = null);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pickImages() async {
    final store = _store;
    if (store == null || _busy) return;
    setState(() => _busy = true);
    try {
      final sources = await pickAndroidImages();
      if (sources.isEmpty) return;
      final report = await store.addImages(sources);
      if (!mounted) return;
      final newIndex = store.samples.length - 1;
      setState(() {
        if (report.added > 0) {
          _selected = newIndex;
          _activeDocument = 0;
        }
      });
      await _loadPreview();
      final parts = [
        if (report.added > 0) 'أضيفت ${report.added} صورة محلياً.',
        if (report.exactDuplicates > 0)
          'تعرّفت الأداة على ${report.exactDuplicates} صورة مطابقة تماماً؛ لم تستبدل أي وسم موجود.',
        if (report.failures.isNotEmpty)
          'تعذر قراءة ${report.failures.length} ملف/ملفات (JPEG/PNG حتى 20 MiB و16 مليون بكسل).',
        if (report.added == 0 &&
            report.exactDuplicates == 0 &&
            report.failures.isEmpty)
          'لم تُضف صور.',
      ];
      _message(parts.join(' '));
    } catch (_) {
      _message('تعذر اختيار الصور المحلية أو حفظها. لم يُرسل أي ملف إلى شبكة.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importJson() async {
    final store = _store;
    if (store == null || _busy) return;
    setState(() => _busy = true);
    File? file;
    try {
      file = await pickAndroidReferenceJson();
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != referenceSchema) {
        throw const FormatException('ملف JSON غير مدعوم.');
      }
      final rawSamples = decoded['samples'];
      if (rawSamples is! List) {
        throw const FormatException('ملف JSON لا يحتوي سجلات صور صالحة.');
      }
      final incoming = rawSamples.map((raw) {
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('سجل الصورة في JSON غير صالح.');
        }
        return Map<String, Object?>.from(raw);
      }).toList();
      final existingIds = store.samples.map((s) => s['image_id']).toSet();
      final incomingIds = incoming
          .map((s) => s['image_id'])
          .whereType<String>()
          .toSet();
      final conflicts = existingIds.intersection(incomingIds).length;
      var replace = false;
      if (conflicts > 0 && mounted) {
        replace =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('لدى الجهاز وسوم للصور نفسها'),
                content: Text(
                  'يتطابق $conflicts سجل/سجلات SHA-256 مع العمل المحلي. '
                  'يمكن الاحتفاظ بالنسخ المحلية أو استبدالها صراحةً بالملف المستورد. '
                  'لا يحدث دمج أو استبدال صامت.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('الاحتفاظ بالعمل المحلي'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('استبدال السجلات المطابقة'),
                  ),
                ],
              ),
            ) ??
            false;
      }
      await store.importPayloadBytes(bytes, replaceMatching: replace);
      if (!mounted) return;
      final report = store.takeLastMergeReport();
      setState(() {
        if (store.samples.isNotEmpty) {
          _selected = _selected.clamp(0, store.samples.length - 1).toInt();
        }
      });
      await _loadPreview();
      _message(
        'استُورد JSON v2.0.0: ${report.added} سجل جديد، '
        '${report.replaced} استبدال بموافقتك، ${report.retainedImages} سجل محلي احتُفظ به. '
        'إذا لم تظهر صورة، اختر الأصل نفسه لإرفاقه محلياً.',
      );
    } catch (_) {
      _message(
        'فشلت استعادة JSON أو لم يطابق المخطط v2.0.0؛ بقيت المسودة المحلية دون تغيير.',
      );
    } finally {
      if (file != null) {
        try {
          await removePickedFile(file);
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportJson() async {
    final store = _store;
    if (store == null || _busy) return;
    setState(() => _busy = true);
    File? temporary;
    try {
      final bytes = await store.exportJson(annotatorId: _reviewer.trim());
      final cache = await getTemporaryDirectory();
      temporary = File(
        p.join(cache.path, 'scan-id-reference-v2-${_reviewer.trim()}.json'),
      );
      await temporary.writeAsBytes(bytes, flush: true);
      final saved = await saveDocument(temporary, 'application/json');
      if (mounted) {
        _message(
          saved
              ? 'تم حفظ JSON محلياً عبر منتقي Android. اختر مجلداً محلياً آمناً؛ لا تشارك الملف.'
              : 'أُلغي اختيار مكان حفظ JSON؛ بقيت المسودة داخل مساحة التطبيق.',
        );
      }
    } catch (_) {
      _message('فشل تصدير JSON أو التحقق منه؛ بقيت المسودة المحلية دون تغيير.');
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCaptureGroup(String imageId, String value) async {
    final store = _store;
    if (store == null) return;
    final index = store.samples.indexWhere(
      (sample) => sample['image_id'] == imageId,
    );
    if (index < 0) return;
    final sample = _copyMap(store.samples[index]);
    sample['capture_group_id'] = value.trim();
    try {
      await store.updateSample(index, sample);
      if (mounted) setState(() {});
    } catch (error) {
      _message(
        error is FormatException
            ? error.message
            : 'تعذر حفظ رمز مجموعة الالتقاط.',
      );
    }
  }

  Future<void> _changeSample(
    String key,
    Object? value, {
    bool stampAnnotation = false,
  }) async {
    final store = _store;
    final current = _sample;
    if (store == null || current == null) return;
    final sample = _copyMap(current);
    sample[key] = value;
    if (key == 'annotation_status') {
      if (value == 'excluded') {
        sample['exclusion_reason'] = sample['exclusion_reason'] == ''
            ? 'boundary_unscorable'
            : sample['exclusion_reason'];
      } else {
        sample['exclusion_reason'] = '';
      }
      if (value == 'annotated' || value == 'second_review') {
        final wasFinal = [
          'annotated',
          'second_review',
        ].contains(current['annotation_status']);
        if (!wasFinal || (sample['annotator_id'] as String).isEmpty) {
          sample['annotator_id'] = _reviewer.trim();
          sample['annotated_at'] = DateTime.now().toUtc().toIso8601String();
        }
      }
    }
    if (stampAnnotation && sample['annotation_status'] == 'unannotated') {
      sample['annotation_status'] = 'in_progress';
    }
    try {
      await store.updateSample(_selected, sample);
      if (mounted) setState(() {});
    } catch (error) {
      _message(
        error is FormatException
            ? error.message
            : 'تعذر حفظ هذا التعديل محلياً.',
      );
    }
  }

  Future<void> _changeDocument(
    String key,
    Object? value, {
    bool stampAnnotation = false,
    String? boundaryStatus,
  }) async {
    final store = _store;
    final sample = _sample;
    final doc = _document;
    if (store == null || sample == null || doc == null) return;
    final changedSample = _copyMap(sample);
    final documents = (changedSample['documents'] as List)
        .map((item) => _copyMap(Map<String, Object?>.from(item as Map)))
        .toList();
    final changedDocument = documents[_activeDocument];
    changedDocument[key] = value;
    if (boundaryStatus != null) {
      changedDocument['boundary_status'] = boundaryStatus;
    }
    if (key == 'boundary_status' && value == 'undeterminable') {
      changedDocument['visible_polygon'] = <Object?>[];
      changedDocument['corners'] = null;
    }
    if (changedDocument['boundary_status'] == 'complete') {
      final polygon = changedDocument['visible_polygon'] as List;
      if (polygon.length == 4) {
        changedDocument['corners'] = _copyList(polygon);
      } else {
        changedDocument['corners'] = null;
      }
    } else {
      changedDocument['corners'] = null;
    }
    changedSample['documents'] = documents;
    changedSample['document_count'] = changedSample['no_document'] == true
        ? 0
        : documents.length;
    if (stampAnnotation &&
        changedSample['annotation_status'] == 'unannotated') {
      changedSample['annotation_status'] = 'in_progress';
    }
    try {
      await store.updateSample(_selected, changedSample);
      if (mounted) setState(() {});
    } catch (error) {
      _message(
        error is FormatException
            ? error.message
            : 'تعذر حفظ تعديل المستند محلياً.',
      );
    }
  }

  Future<void> _setNoDocument(bool value) async {
    final sample = _sample;
    if (sample == null) return;
    final updated = _copyMap(sample);
    updated['no_document'] = value;
    updated['documents'] = value
        ? <Object?>[]
        : [newReferenceDocument(updated['image_id']! as String, 1)];
    updated['document_count'] = value ? 0 : 1;
    try {
      await _store!.updateSample(_selected, updated);
      if (mounted) setState(() => _activeDocument = 0);
    } catch (_) {
      _message('تعذر حفظ حالة الصورة.');
    }
  }

  Future<void> _addDocument() async {
    final sample = _sample;
    if (sample == null || sample['no_document'] == true) return;
    final changed = _copyMap(sample);
    final docs = (changed['documents'] as List)
        .map((item) => _copyMap(Map<String, Object?>.from(item as Map)))
        .toList();
    docs.add(
      newReferenceDocument(
        changed['image_id']! as String,
        _nextDocumentOrdinal(changed['image_id']! as String, docs),
      ),
    );
    changed['documents'] = docs;
    changed['document_count'] = docs.length;
    try {
      await _store!.updateSample(_selected, changed);
      if (mounted) setState(() => _activeDocument = docs.length - 1);
    } catch (_) {
      _message('تعذر إضافة المستند.');
    }
  }

  Future<void> _removeDocument() async {
    final sample = _sample;
    if (sample == null || _documents.length <= 1) return;
    final changed = _copyMap(sample);
    final docs = (changed['documents'] as List)
        .map((item) => _copyMap(Map<String, Object?>.from(item as Map)))
        .toList();
    docs.removeAt(_activeDocument);
    changed['documents'] = docs;
    changed['document_count'] = docs.length;
    try {
      await _store!.updateSample(_selected, changed);
      if (mounted) {
        setState(
          () => _activeDocument = (_activeDocument - 1)
              .clamp(0, docs.length - 1)
              .toInt(),
        );
      }
    } catch (_) {
      _message('تعذر حذف المستند من المسودة.');
    }
  }

  Future<void> _addPoint(Offset local, Size size) async {
    if (_panMode || _sample == null || _document == null) return;
    final doc = _document!;
    if (doc['boundary_status'] == 'undeterminable') return;
    final points = (doc['visible_polygon'] as List)
        .map(
          (point) => (point as List).map((v) => (v as num).toDouble()).toList(),
        )
        .toList();
    final completingQuad =
        doc['boundary_status'] == 'complete' || _editingCompleteQuad;
    final maxPoints = completingQuad ? 4 : 12;
    if (points.length >= maxPoints) {
      _message('اكتمل عدد النقاط. اسحب رأساً لتعديله أو رتّب المضلع.');
      return;
    }
    points.add([
      (local.dx / size.width).clamp(0.0, 1.0).toDouble(),
      (local.dy / size.height).clamp(0.0, 1.0).toDouble(),
    ]);
    final completesNow = completingQuad && points.length == 4;
    final ordered = completesNow
        ? canonicalizeReferencePolygon(points)
        : _clockwisePolygon(points);
    final boundaryStatus = completesNow
        ? 'complete'
        : completingQuad
        ? 'partial'
        : doc['boundary_status']! as String;
    _editingCompleteQuad = completingQuad && !completesNow;
    await _changeDocument(
      'visible_polygon',
      ordered.map((point) => point.cast<Object?>()).toList(),
      stampAnnotation: true,
      boundaryStatus: boundaryStatus,
    );
  }

  int _hitVertex(Offset point, Size size) {
    final points =
        _dragPolygon ??
        ((_document?['visible_polygon'] as List?)
            ?.map(
              (raw) => (raw as List)
                  .map((value) => (value as num).toDouble())
                  .toList(),
            )
            .toList()) ??
        const <List<double>>[];
    var best = -1;
    var bestDistance = double.infinity;
    for (var index = 0; index < points.length; index++) {
      final value = points[index] as List;
      final candidate = Offset(
        (value[0] as num).toDouble() * size.width,
        (value[1] as num).toDouble() * size.height,
      );
      final distance = (candidate - point).distance;
      if (distance < 24 && distance < bestDistance) {
        best = index;
        bestDistance = distance;
      }
    }
    return best;
  }

  int _dragVertex = -1;
  List<List<double>>? _dragPolygon;

  void _moveVertex(Offset point, Size size) {
    final points = _dragPolygon;
    if (_panMode ||
        _dragVertex < 0 ||
        points == null ||
        _dragVertex >= points.length) {
      return;
    }
    points[_dragVertex] = [
      (point.dx / size.width).clamp(0.0, 1.0).toDouble(),
      (point.dy / size.height).clamp(0.0, 1.0).toDouble(),
    ];
    setState(() {});
  }

  Future<void> _finishDrag() async {
    final points = _dragPolygon;
    _dragPolygon = null;
    _dragVertex = -1;
    if (mounted) setState(() {});
    if (points != null) {
      await _changeDocument(
        'visible_polygon',
        points.map((point) => point.cast<Object?>()).toList(),
      );
    }
  }

  Future<void> _markAsFourCornerQuad() async {
    final points =
        (_document?['visible_polygon'] as List?)
            ?.map(
              (raw) => (raw as List)
                  .map((value) => (value as num).toDouble())
                  .toList(),
            )
            .toList() ??
        [];
    if (points.length == 4) {
      _editingCompleteQuad = false;
      await _changeDocument('boundary_status', 'complete');
    } else if (points.length < 4) {
      setState(() => _editingCompleteQuad = true);
      _message(
        'أضف ${4 - points.length} نقطة لإكمال الرباعي؛ سيُرتّب تلقائياً TL→TR→BR→BL.',
      );
    } else {
      _message('امسح النقاط الزائدة أولاً، ثم ابدأ الرباعي بأربع نقاط.');
    }
  }

  Future<void> _autoOrder() async {
    final points = (_document?['visible_polygon'] as List?)
        ?.map((raw) => (raw as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    if (points == null || points.length < 3) return;
    final ordered = canonicalizeReferencePolygon(points);
    await _changeDocument(
      'visible_polygon',
      ordered.map((point) => point.cast<Object?>()).toList(),
    );
  }

  Widget _enumField({
    required String label,
    required String value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label-${_sample?['image_id']}-$_activeDocument-$value'),
      initialValue: options.contains(value) ? value : options.first,
      decoration: InputDecoration(labelText: label, isDense: true),
      isExpanded: true,
      items: [
        for (final option in options)
          DropdownMenuItem(value: option, child: Text(_label(option))),
      ],
      onChanged: onChanged,
    ),
  );

  String _label(String value) => switch (value) {
    'unknown' => 'غير معروف / غير متحقق',
    'unifiedNationalId' => 'البطاقة الوطنية الموحدة',
    'residenceCard' => 'بطاقة السكن',
    'passport' => 'جواز السفر',
    'rationCard' => 'البطاقة التموينية',
    'other' => 'مستند آخر',
    'complete' => 'كاملة — أربع زوايا',
    'occluded' => 'محجوبة جزئياً',
    'partial' => 'مقطوعة / جزئية',
    'undeterminable' => 'غير قابلة للتحديد',
    'unannotated' => 'غير موسومة',
    'in_progress' => 'قيد التوسيم',
    'annotated' => 'موسومة بشرياً',
    'second_review' => 'مراجعة ثانية',
    'excluded' => 'مستبعدة',
    'annotatable' => 'صالحة للتوسيم',
    'unreadable' => 'غير قابلة للقراءة',
    'unclear' => 'غير واضحة',
    'needs_review' => 'تحتاج مراجعة',
    'camera_photo' => 'صورة كاميرا',
    'screenshot' => 'لقطة شاشة',
    'collage' => 'كولاج',
    'video_frame' => 'إطار فيديو',
    'flatbed_or_web_scan' => 'مسح مسطح / عينة ويب',
    'synthetic_graphic' => 'تصميم رقمي',
    'good' => 'جيدة',
    'medium' => 'متوسطة',
    'poor' => 'ضعيفة',
    'unusable' => 'غير صالحة',
    'unassessed' => 'غير مقيّمة',
    'acceptable' => 'مقبول',
    'unacceptable' => 'غير مقبول',
    'uncertain' => 'غير محسوم',
    'not_applicable' => 'لا ينطبق',
    'not_started' => 'لم تبدأ',
    'agreed' => 'اتفاق',
    'disputed' => 'خلاف مفتوح',
    'resolved' => 'حُسم بالتحكيم',
    'excluded_after_dispute' => 'استبعاد بعد خلاف',
    'none' => 'لا يوجد خلاف',
    'open_dispute' => 'خلاف مفتوح',
    'resolved_by_protocol' => 'حُسم وفق البروتوكول',
    'excluded_unresolvable' => 'غير قابل للحسم',
    'decode_failed' => 'تعذر فك الترميز',
    'exact_or_near_duplicate' => 'مكرر أو شبه مكرر',
    'video_or_ui_recording' => 'فيديو / تسجيل واجهة',
    'backup_container' => 'حاوية نسخة احتياطية',
    'synthetic_or_promotional_mockup' => 'تصميم ترويجي غير مادي',
    'pre_cropped_no_background' => 'مقصوصة مسبقاً بلا خلفية',
    'unreadable_or_extreme_blur' => 'غير مقروءة / طمس شديد',
    'boundary_unscorable' => 'حدود غير قابلة للقياس',
    'unresolved_annotator_dispute' => 'خلاف غير محسوم',
    '' => '— اختر —',
    _ => value,
  };

  Widget _flags({
    required String label,
    required List<String> all,
    required List<Object?> selected,
    required ValueChanged<List<String>> onChanged,
  }) {
    final current = selected.whereType<String>().toSet();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            children: [
              for (final flag in all)
                FilterChip(
                  label: Text(_label(flag)),
                  selected: current.contains(flag),
                  onSelected: (enabled) {
                    final next = {...current};
                    if (enabled) {
                      next.add(flag);
                    } else {
                      next.remove(flag);
                    }
                    onChanged(next.toList()..sort());
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final sample = _sample;
    final doc = _document;
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('استوديو الوسوم دون اتصال')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_off_outlined, size: 48),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _open,
                  child: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (store == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('الوسوم المرجعية · v2.0.0'),
        actions: [
          IconButton(
            tooltip: 'استيراد JSON محلي',
            onPressed: _busy ? null : _importJson,
            icon: const Icon(Icons.file_open_outlined),
          ),
          IconButton(
            tooltip: 'تصدير JSON إلى مجلد محلي',
            onPressed: _busy ? null : _exportJson,
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'أداة مستقلة دون إنترنت: لا ترفع الصور ولا تستخدم تحليلات أو خدمات خارجية. '
                  'تُحفظ الصور والمسودة داخل مساحة التطبيق الخاصة. صدّر JSON دورياً؛ '
                  'إزالة التطبيق تمسح بياناته الخاصة.',
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _pickImages,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('اختيار صور من الهاتف'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importJson,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('استعادة JSON'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _exportJson,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('حفظ JSON محلياً'),
                ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('reference-reviewer-id'),
              initialValue: _reviewer,
              decoration: const InputDecoration(
                labelText: 'رمز الموسِّم غير الشخصي',
                helperText: 'مثل R1 أو R2؛ لا تستخدم اسم شخص.',
                isDense: true,
              ),
              onChanged: (value) => _reviewer = value.trim(),
            ),
            if (store.samples.isNotEmpty && sample != null) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                key: ValueKey('image-$_selected-${store.samples.length}'),
                initialValue: _selected
                    .clamp(0, store.samples.length - 1)
                    .toInt(),
                decoration: InputDecoration(
                  labelText:
                      'الصورة ${_selected + 1} من ${store.samples.length}',
                  isDense: true,
                ),
                isExpanded: true,
                items: [
                  for (var i = 0; i < store.samples.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${store.samples[i]['internal_code'] ?? 'IMG-${i + 1}'} · '
                        '${_label(store.samples[i]['annotation_status']! as String)} · '
                        '${(store.samples[i]['image_id']! as String).substring(0, 12)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() {
                    _selected = value;
                    _activeDocument = 0;
                    _preview = null;
                    _transform.value = Matrix4.identity();
                  });
                  await _loadPreview();
                },
              ),
              const SizedBox(height: 8),
              _imageViewer(sample),
              if (sample['image_id'] != null)
                Text(
                  '${sample['width_px']}×${sample['height_px']} px بعد EXIF · '
                  'EXIF=${sample['exif_orientation']} · '
                  'SHA-256 ${(sample['image_id']! as String).substring(0, 12)}…',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              _sampleControls(sample),
              if (sample['no_document'] != true &&
                  sample['annotation_status'] != 'excluded' &&
                  doc != null)
                _documentControls(doc),
              _reviewControls(sample),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'مسودة محلية: ${store.samples.length} صورة · '
                    'الصور المختارة محفوظة داخل التطبيق · '
                    'مقترحات AI المستوردة تبقى منفصلة (${(sample['ai_suggestions'] as List?)?.length ?? 0})',
                  ),
                ),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'لا توجد صور بعد. اختر صور JPEG أو PNG من الهاتف، أو استورد ملف الوسوم أولاً. '
                  'تُحفظ الصور المختارة داخل مساحة التطبيق الخاصة كي تبقى متاحة بعد إعادة التشغيل.',
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _imageViewer(Map<String, Object?> sample) {
    final image = _preview;
    if (image == null) {
      return Container(
        height: 240,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'الصورة غير مرفقة محلياً. اختر الملف الأصلي نفسه من الهاتف لإرفاقه ببصمة SHA-256 المطابقة.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return Column(
      children: [
        Row(
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('رسم / تعديل'),
                  icon: Icon(Icons.edit_outlined),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('تحريك'),
                  icon: Icon(Icons.pan_tool_outlined),
                ),
              ],
              selected: {_panMode},
              onSelectionChanged: (value) =>
                  setState(() => _panMode = value.first),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'إعادة ضبط التكبير',
              onPressed: () => _transform.value = Matrix4.identity(),
              icon: const Icon(Icons.center_focus_strong),
            ),
          ],
        ),
        SizedBox(
          height: 390,
          child: LayoutBuilder(
            builder: (context, bounds) {
              // The stored image dimensions are already EXIF-oriented. The
              // preview is baked to the same orientation by prepareImage.dart.
              final sampleWidth = (sample['width_px']! as int).toDouble();
              final sampleHeight = (sample['height_px']! as int).toDouble();
              final fit = math
                  .min(bounds.maxWidth / sampleWidth, 390 / sampleHeight)
                  .toDouble();
              final width = sampleWidth * fit;
              final height = sampleHeight * fit;
              return Center(
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 10,
                  panEnabled: _panMode,
                  scaleEnabled: true,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(240),
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(
                          image,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.high,
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) => unawaited(
                            _addPoint(
                              details.localPosition,
                              Size(width, height),
                            ),
                          ),
                          onPanStart: _panMode
                              ? null
                              : (details) {
                                  _dragVertex = _hitVertex(
                                    details.localPosition,
                                    Size(width, height),
                                  );
                                  if (_dragVertex >= 0) {
                                    _dragPolygon =
                                        (_document!['visible_polygon'] as List)
                                            .map(
                                              (raw) => (raw as List)
                                                  .map(
                                                    (value) => (value as num)
                                                        .toDouble(),
                                                  )
                                                  .toList(),
                                            )
                                            .toList();
                                  }
                                },
                          onPanUpdate: _panMode
                              ? null
                              : (details) {
                                  if (_dragVertex >= 0) {
                                    _moveVertex(
                                      details.localPosition,
                                      Size(width, height),
                                    );
                                  }
                                },
                          onPanEnd: _panMode
                              ? null
                              : (_) => unawaited(_finishDrag()),
                          onPanCancel: _panMode
                              ? null
                              : () => unawaited(_finishDrag()),
                          child: CustomPaint(
                            painter: _AnnotationPainter(
                              documents: _documents,
                              activeDocument: _activeDocument,
                              activePolygonOverride: _dragPolygon,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const Text(
          'قرص بإصبعين للتكبير · وضع «تحريك» لسحب الصورة · المس لإضافة نقاط. '
          'المضلع الجزئي: أضف الرؤوس باتجاه عقارب الساعة.',
        ),
      ],
    );
  }

  Widget _sampleControls(Map<String, Object?> sample) {
    final status = sample['annotation_status']! as String;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _enumField(
              label: 'حالة التوسيم',
              value: status,
              options: referenceAnnotationStatuses,
              onChanged: (value) {
                if (value != null) {
                  unawaited(_changeSample('annotation_status', value));
                }
              },
            ),
            _enumField(
              label: 'صلاحية الصورة',
              value: sample['suitability_status']! as String,
              options: referenceSuitabilityStatuses,
              onChanged: (value) {
                if (value != null) {
                  unawaited(_changeSample('suitability_status', value));
                }
              },
            ),
            if (status == 'excluded')
              _enumField(
                label: 'سبب الاستبعاد',
                value: sample['exclusion_reason']! as String,
                options: const [
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
                ],
                onChanged: (value) {
                  if (value != null) {
                    unawaited(_changeSample('exclusion_reason', value));
                  }
                },
              ),
            _enumField(
              label: 'مصدر الصورة',
              value: sample['image_source']! as String,
              options: referenceImageSources,
              onChanged: (value) {
                if (value != null) {
                  unawaited(_changeSample('image_source', value));
                }
              },
            ),
            _enumField(
              label: 'جودة الصورة',
              value: sample['image_quality_level']! as String,
              options: const [
                'unassessed',
                'good',
                'medium',
                'poor',
                'unusable',
              ],
              onChanged: (value) {
                if (value != null) {
                  unawaited(_changeSample('image_quality_level', value));
                }
              },
            ),
            TextFormField(
              key: ValueKey('capture-${sample['image_id']}'),
              initialValue: sample['capture_group_id']! as String,
              decoration: const InputDecoration(
                labelText: 'رمز جلسة الالتقاط غير الشخصي (اختياري)',
                helperText: 'اضغط تم أو المس خارج الحقل لحفظ التعديل.',
                isDense: true,
              ),
              onChanged: (value) =>
                  _captureDrafts[sample['image_id']! as String] = value,
              onFieldSubmitted: (value) {
                _captureDrafts.remove(sample['image_id']! as String);
                unawaited(
                  _saveCaptureGroup(sample['image_id']! as String, value),
                );
              },
              onTapOutside: (_) {
                final imageId = sample['image_id']! as String;
                final draft =
                    _captureDrafts.remove(imageId) ??
                    sample['capture_group_id']! as String;
                unawaited(_saveCaptureGroup(imageId, draft));
                FocusManager.instance.primaryFocus?.unfocus();
              },
            ),
            _flags(
              label: 'أسباب صعوبة المشهد',
              all: referenceDifficultyFlags,
              selected: (sample['difficulty_reasons']! as List).cast<Object?>(),
              onChanged: (value) =>
                  unawaited(_changeSample('difficulty_reasons', value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('لا يوجد مستند مرئي'),
              subtitle: const Text('عينة خلفية سالبة: document_count = 0'),
              value: sample['no_document']! as bool,
              onChanged: _setNoDocument,
            ),
          ],
        ),
      ),
    );
  }

  Widget _documentControls(Map<String, Object?> doc) {
    final sample = _sample!;
    final documents = _documents;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'المستندات · ${documents.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('doc-$_activeDocument-${documents.length}'),
                    initialValue: _activeDocument
                        .clamp(0, documents.length - 1)
                        .toInt(),
                    decoration: const InputDecoration(
                      labelText: 'المستند النشط',
                      isDense: true,
                    ),
                    items: [
                      for (var i = 0; i < documents.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            'D${i + 1} · ${_label(documents[i]['document_kind']! as String)}',
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _activeDocument = value ?? 0),
                  ),
                ),
                IconButton(
                  tooltip: 'إضافة مستند',
                  onPressed: _addDocument,
                  icon: const Icon(Icons.add_circle_outline),
                ),
                IconButton(
                  tooltip: 'حذف المستند',
                  onPressed: documents.length <= 1 ? null : _removeDocument,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            _enumField(
              label: 'نوع الوثيقة',
              value: doc['document_kind']! as String,
              options: referenceDocumentKinds,
              onChanged: (value) {
                if (value != null) {
                  unawaited(_changeDocument('document_kind', value));
                }
              },
            ),
            _enumField(
              label: 'حالة الحدود المرئية',
              value: doc['boundary_status']! as String,
              options: referenceBoundaryStatuses,
              onChanged: (value) {
                if (value != null) {
                  _editingCompleteQuad = false;
                  unawaited(_changeDocument('boundary_status', value));
                }
              },
            ),
            _enumField(
              label: 'صلاحية القص المتوقع',
              value: doc['crop_quality']! as String,
              options: const [
                'uncertain',
                'acceptable',
                'unacceptable',
                'not_applicable',
              ],
              onChanged: (value) {
                if (value != null) {
                  unawaited(_changeDocument('crop_quality', value));
                }
              },
            ),
            _flags(
              label: 'صعوبات هذا المستند',
              all: referenceDifficultyFlags,
              selected: (doc['quality_flags']! as List).cast<Object?>(),
              onChanged: (value) =>
                  unawaited(_changeDocument('quality_flags', value)),
            ),
            CheckboxListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('راجعت الحدود والنوع بصرياً بنفسي'),
              value: doc['human_verified']! as bool,
              onChanged: (value) =>
                  unawaited(_changeDocument('human_verified', value ?? false)),
            ),
            Wrap(
              spacing: 8,
              children: [
                if (doc['boundary_status'] != 'complete')
                  OutlinedButton.icon(
                    onPressed: _markAsFourCornerQuad,
                    icon: const Icon(Icons.crop_free),
                    label: const Text('إكمال كرباعي'),
                  ),
                OutlinedButton.icon(
                  onPressed: _autoOrder,
                  icon: const Icon(Icons.rotate_90_degrees_ccw),
                  label: const Text('ترتيب TL→TR→BR→BL'),
                ),
                OutlinedButton.icon(
                  onPressed: (doc['visible_polygon'] as List).isEmpty
                      ? null
                      : () => unawaited(
                          _changeDocument('visible_polygon', <Object?>[]),
                        ),
                  icon: const Icon(Icons.clear),
                  label: const Text('مسح النقاط'),
                ),
              ],
            ),
            Text(
              'النقاط: ${jsonEncode(doc['visible_polygon'])}',
              textDirection: TextDirection.ltr,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'اقتراحات AI: ${(sample['ai_suggestions'] as List?)?.length ?? 0} · محفوظة في حقل مستقل ولا تُعتمد كوسم بشري.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _reviewControls(Map<String, Object?> sample) {
    final review = Map<String, Object?>.from(sample['second_review'] as Map);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'المراجعة الثانية والتحكيم',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _enumField(
              label: 'حالة المراجعة',
              value: review['status']! as String,
              options: const [
                'not_started',
                'agreed',
                'disputed',
                'resolved',
                'excluded_after_dispute',
              ],
              onChanged: (value) async {
                if (value == null) return;
                final changed = _copyMap(sample);
                final next = Map<String, Object?>.from(
                  changed['second_review'] as Map,
                );
                next['status'] = value;
                if (value == 'not_started') {
                  next['reviewer_id'] = '';
                  next['reviewed_at'] = '';
                  next['dispute_status'] = 'none';
                  next['adjudicator_id'] = '';
                  next['adjudicated_at'] = '';
                  next['resolution_code'] = '';
                } else {
                  next['reviewed_at'] = DateTime.now()
                      .toUtc()
                      .toIso8601String();
                  next['dispute_status'] = switch (value) {
                    'agreed' => 'none',
                    'disputed' => 'open_dispute',
                    'resolved' => 'resolved_by_protocol',
                    'excluded_after_dispute' => 'excluded_unresolvable',
                    _ => 'none',
                  };
                  if (value == 'excluded_after_dispute') {
                    changed['annotation_status'] = 'excluded';
                    changed['exclusion_reason'] =
                        'unresolved_annotator_dispute';
                  }
                  if (value == 'resolved') {
                    next['adjudicated_at'] = DateTime.now()
                        .toUtc()
                        .toIso8601String();
                  }
                }
                changed['second_review'] = next;
                await _saveWholeSample(changed);
              },
            ),
            TextFormField(
              key: ValueKey('reviewer2-${sample['image_id']}'),
              initialValue: review['reviewer_id']! as String,
              decoration: const InputDecoration(
                labelText: 'رمز المراجع الثاني (مختلف عن الموسِّم الأساسي)',
                isDense: true,
              ),
              onChanged: (value) =>
                  _reviewDrafts['${sample['image_id']}:reviewer_id'] = value,
              onFieldSubmitted: (value) {
                _reviewDrafts.remove('${sample['image_id']}:reviewer_id');
                unawaited(
                  _changeReviewField(
                    'reviewer_id',
                    value.trim(),
                    imageId: sample['image_id']! as String,
                  ),
                );
              },
              onTapOutside: (_) {
                final key = '${sample['image_id']}:reviewer_id';
                final value =
                    _reviewDrafts.remove(key) ??
                    review['reviewer_id']! as String;
                unawaited(
                  _changeReviewField(
                    'reviewer_id',
                    value.trim(),
                    imageId: sample['image_id']! as String,
                  ),
                );
                FocusManager.instance.primaryFocus?.unfocus();
              },
            ),
            TextFormField(
              key: ValueKey('adjudicator-${sample['image_id']}'),
              initialValue: review['adjudicator_id']! as String,
              decoration: const InputDecoration(
                labelText: 'رمز المحكّم',
                isDense: true,
              ),
              onChanged: (value) =>
                  _reviewDrafts['${sample['image_id']}:adjudicator_id'] = value,
              onFieldSubmitted: (value) {
                _reviewDrafts.remove('${sample['image_id']}:adjudicator_id');
                unawaited(
                  _changeReviewField(
                    'adjudicator_id',
                    value.trim(),
                    imageId: sample['image_id']! as String,
                  ),
                );
              },
              onTapOutside: (_) {
                final key = '${sample['image_id']}:adjudicator_id';
                final value =
                    _reviewDrafts.remove(key) ??
                    review['adjudicator_id']! as String;
                unawaited(
                  _changeReviewField(
                    'adjudicator_id',
                    value.trim(),
                    imageId: sample['image_id']! as String,
                  ),
                );
                FocusManager.instance.primaryFocus?.unfocus();
              },
            ),
            _enumField(
              label: 'قرار التحكيم',
              value: review['resolution_code']! as String,
              options: const [
                '',
                'unanimous_primary_and_secondary',
                'adjudicated_visible_boundary',
                'adjudicated_kind_to_unknown',
                'adjudicated_boundary_undeterminable',
                'excluded_due_to_ambiguity',
              ],
              onChanged: (value) => unawaited(
                _changeReviewField(
                  'resolution_code',
                  value ?? '',
                  imageId: sample['image_id']! as String,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeReviewField(
    String key,
    String value, {
    required String imageId,
  }) async {
    final store = _store;
    if (store == null) return;
    final index = store.samples.indexWhere(
      (sample) => sample['image_id'] == imageId,
    );
    if (index < 0) return;
    final changed = _copyMap(store.samples[index]);
    final review = Map<String, Object?>.from(changed['second_review'] as Map);
    review[key] = value;
    changed['second_review'] = review;
    try {
      await store.updateSample(index, changed);
      if (mounted) setState(() {});
    } catch (error) {
      _message(
        error is FormatException ? error.message : 'تعذر حفظ المراجعة محلياً.',
      );
    }
  }

  Future<void> _saveWholeSample(Map<String, Object?> sample) async {
    try {
      await _store!.updateSample(_selected, sample);
      if (mounted) setState(() {});
    } catch (error) {
      _message(
        error is FormatException ? error.message : 'تعذر حفظ المراجعة محلياً.',
      );
    }
  }
}

int _nextDocumentOrdinal(String imageId, List<Map<String, Object?>> documents) {
  final used = documents.map((doc) => doc['document_id']).toSet();
  var ordinal = 1;
  while (used.contains('$imageId-doc-${ordinal.toString().padLeft(2, '0')}')) {
    ordinal++;
  }
  return ordinal;
}

Map<String, Object?> _copyMap(Map<String, Object?> value) =>
    Map<String, Object?>.from(
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>,
    );

List<Object?> _copyList(List<Object?> value) =>
    (jsonDecode(jsonEncode(value)) as List<dynamic>).cast<Object?>();

List<List<double>> _clockwisePolygon(List<List<double>> points) {
  if (points.length < 3) return points;
  var area = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    area += a[0] * b[1] - b[0] * a[1];
  }
  return area < 0 ? points.reversed.toList() : points;
}

List<List<double>> canonicalizeReferencePolygon(List<List<double>> points) {
  if (points.length < 3) return points;
  final cx =
      points.map((point) => point[0]).reduce((a, b) => a + b) / points.length;
  final cy =
      points.map((point) => point[1]).reduce((a, b) => a + b) / points.length;
  var ordered = [...points]
    ..sort(
      (a, b) => math
          .atan2(a[1] - cy, a[0] - cx)
          .compareTo(math.atan2(b[1] - cy, b[0] - cx)),
    );
  var area = 0.0;
  for (var i = 0; i < ordered.length; i++) {
    final a = ordered[i], b = ordered[(i + 1) % ordered.length];
    area += a[0] * b[1] - b[0] * a[1];
  }
  if (area < 0) ordered = ordered.reversed.toList();
  var start = 0;
  for (var i = 1; i < ordered.length; i++) {
    final sum = double.parse(
      (ordered[i][0] + ordered[i][1]).toStringAsFixed(6),
    );
    final startSum = double.parse(
      (ordered[start][0] + ordered[start][1]).toStringAsFixed(6),
    );
    final y = double.parse(ordered[i][1].toStringAsFixed(6));
    final startY = double.parse(ordered[start][1].toStringAsFixed(6));
    if (sum < startSum || (sum == startSum && y < startY)) start = i;
  }
  return [...ordered.skip(start), ...ordered.take(start)];
}

class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter({
    required this.documents,
    required this.activeDocument,
    this.activePolygonOverride,
  });
  final List<Map<String, Object?>> documents;
  final int activeDocument;
  final List<List<double>>? activePolygonOverride;
  static const colors = [
    Color(0xffffa000),
    Color(0xff00897b),
    Color(0xff1565c0),
    Color(0xffc2185b),
    Color(0xff6a1b9a),
    Color(0xff558b2f),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var docIndex = 0; docIndex < documents.length; docIndex++) {
      final document = documents[docIndex];
      final raw = docIndex == activeDocument && activePolygonOverride != null
          ? activePolygonOverride
          : document['visible_polygon'];
      if (raw is! List || raw.isEmpty) continue;
      final points = raw.map((item) {
        final value = item as List;
        return Offset(
          (value[0] as num).toDouble() * size.width,
          (value[1] as num).toDouble() * size.height,
        );
      }).toList();
      final active = docIndex == activeDocument;
      final color = colors[docIndex % colors.length];
      final fill = Paint()
        ..color = color.withValues(alpha: active ? .18 : .08)
        ..style = PaintingStyle.fill;
      final stroke = Paint()
        ..color = color
        ..strokeWidth = active ? 2.5 : 1.5
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      if (points.length >= 3) {
        path.close();
        canvas.drawPath(path, fill);
      }
      canvas.drawPath(path, stroke);
      for (var index = 0; index < points.length; index++) {
        canvas.drawCircle(
          points[index],
          active ? 10 : 7,
          Paint()..color = active ? Colors.white : color,
        );
        canvas.drawCircle(
          points[index],
          active ? 10 : 7,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        if (active) {
          final label = document['boundary_status'] == 'complete'
              ? ['TL', 'TR', 'BR', 'BL'][index.clamp(0, 3).toInt()]
              : 'P${index + 1}';
          final painter = TextPainter(
            text: TextSpan(
              text: label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                shadows: [Shadow(color: Colors.black, blurRadius: 3)],
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          painter.paint(canvas, points[index] + const Offset(10, -16));
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) =>
      activeDocument != oldDelegate.activeDocument ||
      jsonEncode(documents) != jsonEncode(oldDelegate.documents) ||
      jsonEncode(activePolygonOverride) !=
          jsonEncode(oldDelegate.activePolygonOverride);
}
