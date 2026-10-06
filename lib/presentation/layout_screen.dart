import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../application/ids.dart';
import '../application/packing_service.dart';
import '../domain/packing.dart';
import '../application/layout_session.dart';
import '../application/project_service.dart';
import '../domain/page_layout.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'page_canvas.dart';
import 'export_screen.dart';

class LayoutScreen extends StatefulWidget {
  const LayoutScreen({
    required this.project,
    required this.service,
    this.proposeLayout = createPackingProposal,
    super.key,
  });
  final Project project;
  final ProjectService service;
  final PackingProposer proposeLayout;
  @override
  State<LayoutScreen> createState() => _LayoutScreenState();
}

class _LayoutScreenState extends State<LayoutScreen> {
  late final _session = LayoutSession(widget.project, widget.service.projects);
  final _pageKey = GlobalKey();
  final _view = TransformationController();
  final _selected = <String>{};
  bool _busy = false, _pan = false, _overlap = false;
  String? _error;
  Project? _dragPreview;
  DocumentItem? _dragItem;
  Offset? _dragStart;
  bool _resizing = false;
  double _scale = 1;
  int _page = 0;
  Project get _project => _dragPreview ?? _session.current;
  DocumentItem? get _active => _selected.isEmpty
      ? null
      : _project.items.where((e) => e.id == _selected.last).firstOrNull;
  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || _dragItem != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = userError(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _page = math.min(_page, _session.current.pageCount - 1);
          _selected.removeWhere(
            (id) => !_session.current.items.any((e) => e.id == id),
          );
        });
      }
    }
  }

  Future<void> _apply(Project Function(Project) action) =>
      _run(() => _session.apply(action));
  Offset _point(Offset global) =>
      (_pageKey.currentContext!.findRenderObject()! as RenderBox).globalToLocal(
        global,
      ) /
      _scale;
  void _start(String id, Offset global, bool resize) {
    if (_busy || _pan) return;
    setState(() {
      _selected
        ..clear()
        ..add(id);
      _dragItem = PageLayout.item(_session.current, id);
      _dragStart = _point(global);
      _resizing = resize;
    });
  }

  void _drag(Offset global) {
    final old = _dragItem;
    if (old == null || _pan) return;
    final d = _point(global) - _dragStart!;
    try {
      final angle = old.rotation * math.pi / 180;
      final local = Offset(
        d.dx * math.cos(angle) + d.dy * math.sin(angle),
        -d.dx * math.sin(angle) + d.dy * math.cos(angle),
      );
      final next = _resizing
          ? PageLayout.resize(
              old,
              math.max(1, old.width + local.dx),
              math.max(1, old.height + local.dy),
            )
          : old.copyWith(x: old.x + d.dx, y: old.y + d.dy);
      setState(
        () => _dragPreview = _session.current.copyWith(
          items: [
            for (final e in _session.current.items) e.id == old.id ? next : e,
          ],
        ),
      );
    } catch (e) {
      setState(() => _error = userError(e));
    }
  }

  Future<void> _end() async {
    final preview = _dragPreview;
    setState(() {
      _dragPreview = null;
      _dragItem = null;
      _dragStart = null;
    });
    if (preview != null) {
      await _apply((_) => PageLayout.checked(preview, allowOverlap: _overlap));
    }
  }

  Future<void> _add(ImageAsset asset) async {
    final p = _session.current;
    final values = await editMeasurements(
      context,
      'المقاسات الفعلية للمستمسك',
      {
        'الصفحة (0 لغير الموضوعة)': (_page + 1).toDouble(),
        'العرض مم': 80,
        'الارتفاع مم': 80 * asset.height / asset.width,
        'س مم': p.paper.margins.left,
        'ص مم': p.paper.margins.top,
      },
      notice:
          'هذه قيم مبدئية وليست قياساً مستنتجاً من الصورة. أدخل المقاس الحقيقي.',
    );
    if (values == null || !mounted) return;
    final id = newId();
    await _apply(
      (p) => PageLayout.add(
        p,
        DocumentItem(
          id: id,
          assetId: asset.id,
          pageIndex: _pageNumber(
            values['الصفحة (0 لغير الموضوعة)']!,
            p.pageCount,
          ),
          x: values['س مم']!,
          y: values['ص مم']!,
          width: values['العرض مم']!,
          height: values['الارتفاع مم']!,
          zIndex: p.items.fold<int>(0, (v, e) => math.max(v, e.zIndex)) + 1,
        ),
        allowOverlap: _overlap,
      ),
    );
    if (mounted && _session.current.items.any((e) => e.id == id)) {
      setState(
        () => _selected
          ..clear()
          ..add(id),
      );
    }
  }

  Future<void> _properties(DocumentItem e) async {
    final v = await editMeasurements(
      context,
      'خصائص العنصر',
      {
        'الصفحة (0 لغير الموضوعة)': ((e.pageIndex ?? -1) + 1).toDouble(),
        'س مم': e.x,
        'ص مم': e.y,
        'العرض مم': e.width,
        'الارتفاع مم': e.height,
        'الزاوية °': e.rotation,
      },
      notice: e.keepAspectRatio
          ? 'النسبة مثبتة: تغيير أحد البعدين يضبط الآخر؛ عند تغيير كليهما يُعتمد العرض.'
          : 'تنبيه: تغيير النسبة قد يشوّه النصوص والوجوه.',
    );
    if (v == null || !mounted) return;
    await _apply(
      (p) => PageLayout.replace(
        p,
        PageLayout.resize(e, v['العرض مم']!, v['الارتفاع مم']!).copyWith(
          x: v['س مم'],
          y: v['ص مم'],
          rotation: v['الزاوية °'],
          pageIndex: _pageNumber(v['الصفحة (0 لغير الموضوعة)']!, p.pageCount),
          unplaced: v['الصفحة (0 لغير الموضوعة)'] == 0,
        ),
        allowOverlap: _overlap,
      ),
    );
  }

  Future<void> _paper() async {
    final p = _project;
    final v = await editMeasurements(context, 'الهوامش والمسافات مم', {
      'أعلى': p.paper.margins.top,
      'يمين': p.paper.margins.right,
      'أسفل': p.paper.margins.bottom,
      'يسار': p.paper.margins.left,
      'فجوة أفقية': p.layout.horizontalGap,
      'فجوة عمودية': p.layout.verticalGap,
    });
    if (v == null || !mounted) return;
    await _apply(
      (p) => PageLayout.checked(
        p.copyWith(
          paper: PaperSettings(
            orientation: p.paper.orientation,
            margins: Margins(
              top: v['أعلى']!,
              right: v['يمين']!,
              bottom: v['أسفل']!,
              left: v['يسار']!,
            ),
          ),
          layout: LayoutSettings(
            horizontalGap: v['فجوة أفقية']!,
            verticalGap: v['فجوة عمودية']!,
            allowRotation: p.layout.allowRotation,
            order: p.layout.order,
          ),
        ),
        allowOverlap: _overlap,
      ),
    );
  }

  int? _pageNumber(double value, int count) {
    require(
      value == value.roundToDouble() && value >= 0 && value <= count,
      'رقم الصفحة غير صالح.',
    );
    return value == 0 ? null : value.toInt() - 1;
  }

  Future<void> _pack() async {
    final options = await showDialog<(bool, bool)>(
      context: context,
      builder: (_) => const _PackingOptions(),
    );
    if (options == null || !mounted) return;
    PackingProposal? proposal;
    await _run(() async {
      proposal = await widget.proposeLayout(
        _session.current,
        includeLocked: options.$1,
        allowRotation: options.$2,
        pageIndex: _page,
      );
    });
    if (proposal == null || !mounted) return;
    final candidate = proposal!;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('مراجعة اقتراح الترتيب'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'لم يُحفظ الاقتراح. الاعتماد يغيّر المواضع الحالية؛ يمكن التراجع عنه وتعديله يدوياً. لا ضمان لترتيب أمثل.',
                ),
                Text('غير موضوعة: ${candidate.unplaced.length}'),
                for (final id in candidate.unplaced)
                  Text(
                    candidate.result.assets
                        .firstWhere(
                          (a) =>
                              a.id ==
                              PageLayout.item(candidate.result, id).assetId,
                        )
                        .name,
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 340,
                  child: LayoutBuilder(
                    builder: (_, box) {
                      final scale = PageViewport(
                        candidate.result.paper,
                        box.maxWidth,
                        box.maxHeight,
                      ).scale;
                      return Center(
                        child: PageCanvas(
                          project: candidate.result,
                          assets: widget.service.assets,
                          scale: scale,
                          pageIndex: _page,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رفض الاقتراح'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('اعتماد ومتابعة التحرير'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await _apply((p) {
        require(
          p.revision == candidate.original.revision,
          'تغير المشروع؛ أنشئ اقتراحاً جديداً.',
        );
        return candidate.result;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<Project>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_busy) Navigator.pop(context, _session.current);
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'رجوع للمشروع',
          onPressed: _busy
              ? null
              : () => Navigator.pop(context, _session.current),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('محرر A4'),
        actions: [
          IconButton(
            tooltip: 'تراجع',
            onPressed: _busy || !_session.history.canUndo
                ? null
                : () => _run(_session.undo),
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'إعادة',
            onPressed: _busy || !_session.history.canRedo
                ? null
                : () => _run(_session.redo),
            icon: const Icon(Icons.redo),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'صفحة ${_page + 1}/${_project.pageCount} · ${_project.paper.width.toInt()} × ${_project.paper.height.toInt()} مم · ${_busy ? 'جارٍ الحفظ…' : 'محفوظ محلياً'} · الفجوات ${_project.layout.horizontalGap}/${_project.layout.verticalGap} مم',
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => box.maxWidth >= 900
                  ? Row(
                      children: [
                        Expanded(child: _workspace()),
                        SizedBox(width: 320, child: _tools()),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(child: _workspace()),
                        SizedBox(
                          height: math.min(260, box.maxHeight * .45),
                          child: _tools(),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    ),
  );
  Widget _workspace() => ColoredBox(
    color: const Color(0xffdce3df),
    child: LayoutBuilder(
      builder: (context, box) {
        final view = PageViewport(
          _project.paper,
          math.max(1, box.maxWidth - 40),
          math.max(1, box.maxHeight - 40),
        );
        _scale = view.scale;
        return InteractiveViewer(
          transformationController: _view,
          panEnabled: _pan,
          scaleEnabled: _pan,
          minScale: .5,
          maxScale: 8,
          child: Center(
            child: IgnorePointer(
              ignoring: _pan || _busy,
              child: Listener(
                onPointerCancel: (_) => setState(() {
                  _dragPreview = null;
                  _dragItem = null;
                  _dragStart = null;
                }),
                child: PageCanvas(
                  project: _project,
                  pageIndex: _page,
                  assets: widget.service.assets,
                  scale: _scale,
                  pageKey: _pageKey,
                  selected: _selected,
                  onSelect: (id) => setState(
                    () => _selected
                      ..clear()
                      ..add(id),
                  ),
                  onDragStart: _start,
                  onDragUpdate: _drag,
                  onDragEnd: _end,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
  Widget _tools() {
    final e = _active;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => ExportScreen(
                        project: _session.current,
                        service: widget.service,
                        onProfile: (profile) async {
                          await _session.apply(
                            (p) => p.copyWith(exportProfile: profile),
                          );
                          if (mounted) {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ),
            icon: const Icon(Icons.print_outlined),
            label: const Text('معاينة وتصدير وطباعة'),
          ),
          DropdownButton<int>(
            isExpanded: true,
            value: _page,
            items: [
              for (var i = 0; i < _project.pageCount; i++)
                DropdownMenuItem(value: i, child: Text('الصفحة ${i + 1}')),
            ],
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _page = v!;
                    _selected.clear();
                    _view.value = Matrix4.identity();
                  }),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    await _apply((p) => p.copyWith(pageCount: p.pageCount + 1));
                    if (mounted) {
                      setState(() => _page = _session.current.pageCount - 1);
                    }
                  },
            child: const Text('إضافة صفحة A4'),
          ),
          CheckboxListTile(
            title: const Text('ترتيب الأكبر أولاً'),
            value: _project.layout.order == LayoutOrder.area,
            onChanged: _busy
                ? null
                : (v) => _apply(
                    (p) => p.copyWith(
                      layout: LayoutSettings(
                        horizontalGap: p.layout.horizontalGap,
                        verticalGap: p.layout.verticalGap,
                        allowRotation: p.layout.allowRotation,
                        order: v! ? LayoutOrder.area : LayoutOrder.input,
                      ),
                    ),
                  ),
          ),
          OutlinedButton.icon(
            key: const Key('packing-proposal'),
            onPressed: _busy || _project.items.isEmpty ? null : _pack,
            icon: const Icon(Icons.auto_awesome_mosaic),
            label: const Text('اقتراح ترتيب'),
          ),
          SwitchListTile(
            key: const Key('workspace-pan'),
            title: const Text('تكبير وتحريك مساحة العمل'),
            subtitle: const Text('لا تتحرك المستمسكات في هذا الوضع'),
            value: _pan,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _pan = v;
                    _dragPreview = null;
                    _dragItem = null;
                    _dragStart = null;
                  }),
          ),
          TextButton(
            onPressed: () => setState(() => _view.value = Matrix4.identity()),
            child: const Text('إعادة ضبط العرض'),
          ),
          DropdownButton<PaperOrientation>(
            isExpanded: true,
            value: _project.paper.orientation,
            items: const [
              DropdownMenuItem(
                value: PaperOrientation.portrait,
                child: Text('A4 عمودي'),
              ),
              DropdownMenuItem(
                value: PaperOrientation.landscape,
                child: Text('A4 أفقي'),
              ),
            ],
            onChanged: _busy
                ? null
                : (v) => _apply(
                    (p) => PageLayout.checked(
                      p.copyWith(
                        paper: PaperSettings(
                          orientation: v!,
                          margins: p.paper.margins,
                        ),
                      ),
                      allowOverlap: _overlap,
                    ),
                  ),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _paper,
            child: const Text('الهوامش والمسافات'),
          ),
          CheckboxListTile(
            title: const Text('السماح بالتراكب اليدوي صراحة'),
            value: _overlap,
            onChanged: _busy ? null : (v) => setState(() => _overlap = v!),
          ),
          PopupMenuButton<String>(
            tooltip: 'إضافة إلى الورقة',
            enabled: !_busy && _project.assets.isNotEmpty,
            onSelected: (id) =>
                _add(_project.assets.firstWhere((a) => a.id == id)),
            itemBuilder: (_) => [
              for (final a in _project.assets)
                PopupMenuItem(value: a.id, child: Text(a.name)),
            ],
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('＋ إضافة صورة إلى الورقة'),
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              for (final item in _project.items.where(
                (e) => e.pageIndex == _page || e.pageIndex == null,
              ))
                FilterChip(
                  label: Text(
                    '${_project.items.indexOf(item) + 1}${item.pageIndex == null ? ' غير موضوع' : ''}${item.locked ? ' 🔒' : ''}',
                  ),
                  selected: _selected.contains(item.id),
                  onSelected: _busy
                      ? null
                      : (v) => setState(() {
                          if (v) {
                            _selected.add(item.id);
                          } else {
                            _selected.remove(item.id);
                          }
                        }),
                ),
            ],
          ),
          if (e != null) ...[
            Text(
              'س ${e.x.toStringAsFixed(1)} · ص ${e.y.toStringAsFixed(1)} مم\n${e.width.toStringAsFixed(1)} × ${e.height.toStringAsFixed(1)} مم · ${e.rotation.toStringAsFixed(1)}°',
            ),
            CheckboxListTile(
              title: const Text('تثبيت العنصر'),
              value: e.locked,
              onChanged: _busy
                  ? null
                  : (v) => _apply((p) => PageLayout.lock(p, e.id, v!)),
            ),
            CheckboxListTile(
              title: const Text('تثبيت نسبة الأبعاد'),
              value: e.keepAspectRatio,
              onChanged: _busy || e.locked
                  ? null
                  : (v) => _apply(
                      (p) => PageLayout.replace(
                        p,
                        e.copyWith(keepAspectRatio: v),
                        allowOverlap: _overlap,
                      ),
                    ),
            ),
            OutlinedButton(
              onPressed: _busy || e.locked ? null : () => _properties(e),
              child: const Text('المقاس والموضع والتدوير'),
            ),
            OutlinedButton(
              onPressed: _busy || e.locked
                  ? null
                  : () => _apply(
                      (p) => PageLayout.replace(
                        p,
                        e.copyWith(
                          zIndex:
                              p.items.fold<int>(
                                e.zIndex,
                                (v, i) => math.max(v, i.zIndex),
                              ) +
                              1,
                        ),
                        allowOverlap: _overlap,
                      ),
                    ),
              child: const Text('إلى الأمام'),
            ),
            OutlinedButton(
              onPressed: _busy || e.locked
                  ? null
                  : () => _apply(
                      (p) => PageLayout.add(
                        p,
                        e.copyWith(
                          id: newId(),
                          x: e.x + e.bounds.width + p.layout.horizontalGap,
                        ),
                        allowOverlap: _overlap,
                      ),
                    ),
              child: const Text('تكرار العنصر'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _apply((p) => PageLayout.remove(p, _selected)),
              child: const Text('حذف المحدد من الورقة'),
            ),
          ],
          PopupMenuButton<PageAlignment>(
            tooltip: 'محاذاة المحدد',
            enabled: !_busy && _selected.isNotEmpty,
            onSelected: (a) => _apply(
              (p) => PageLayout.align(p, _selected, a, allowOverlap: _overlap),
            ),
            itemBuilder: (_) => [
              for (final a in PageAlignment.values)
                PopupMenuItem(
                  value: a,
                  child: Text(
                    [
                      'يسار',
                      'توسيط أفقي',
                      'يمين',
                      'أعلى',
                      'توسيط عمودي',
                      'أسفل',
                    ][a.index],
                  ),
                ),
            ],
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('محاذاة المحدد بالنسبة للورقة'),
            ),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _apply(
                    (p) => PageLayout.distribute(
                      p,
                      _selected,
                      horizontal: true,
                      allowOverlap: _overlap,
                    ),
                  ),
            child: const Text('توزيع أفقي'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _apply(
                    (p) => PageLayout.distribute(
                      p,
                      _selected,
                      horizontal: false,
                      allowOverlap: _overlap,
                    ),
                  ),
            child: const Text('توزيع عمودي'),
          ),
          const Text(
            'الإطار البرتقالي حدود الهوامش المختارة، وليس كشفاً آلياً لهوامش الطابعة. السحب والحجم يحفظان عند انتهاء الإيماءة. التراجع خاص بالجلسة.',
          ),
        ],
      ),
    );
  }
}

Future<Map<String, double>?> editMeasurements(
  BuildContext context,
  String title,
  Map<String, double> values, {
  String? notice,
}) => showDialog<Map<String, double>>(
  context: context,
  builder: (_) => _MeasurementsDialog(title, values, notice),
);

class _MeasurementsDialog extends StatefulWidget {
  const _MeasurementsDialog(this.title, this.values, this.notice);
  final String title;
  final Map<String, double> values;
  final String? notice;
  @override
  State<_MeasurementsDialog> createState() => _MeasurementsDialogState();
}

class _MeasurementsDialogState extends State<_MeasurementsDialog> {
  late final _fields = {
    for (final e in widget.values.entries)
      e.key: TextEditingController(text: e.value.toStringAsFixed(2)),
  };
  String? _error;
  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.notice != null) Text(widget.notice!),
            for (final e in _fields.entries)
              TextField(
                key: Key('measure-${e.key}'),
                controller: e.value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: InputDecoration(labelText: e.key),
              ),
            if (_error != null) Text(_error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final values = <String, double>{};
            for (final e in _fields.entries) {
              var text = e.value.text
                  .trim()
                  .replaceAll('٫', '.')
                  .replaceAll(',', '.');
              for (var i = 0; i < 10; i++) {
                text = text.replaceAll('٠١٢٣٤٥٦٧٨٩'[i], '$i');
              }
              final v = double.tryParse(text);
              require(v != null && v.isFinite, 'أدخل أرقاماً صالحة.');
              values[e.key] =
                  e.value.text == widget.values[e.key]!.toStringAsFixed(2)
                  ? widget.values[e.key]!
                  : v!;
            }
            Navigator.pop(context, values);
          } catch (e) {
            setState(() => _error = userError(e));
          }
        },
        child: const Text('حفظ المقاسات'),
      ),
    ],
  );
}

class _PackingOptions extends StatefulWidget {
  const _PackingOptions();
  @override
  State<_PackingOptions> createState() => _PackingOptionsState();
}

class _PackingOptionsState extends State<_PackingOptions> {
  bool _all = false, _rotate = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('نطاق الاقتراح'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'سيعاد ترتيب عناصر الصفحة والقائمة غير الموضوعة. لا تتغير المقاسات. لن يُحفظ شيء قبل مراجعة الاقتراح.',
        ),
        CheckboxListTile(
          title: const Text('جميع العناصر بما فيها المثبتة'),
          subtitle: const Text('دون التحديد: غير المثبتة فقط'),
          value: _all,
          onChanged: (v) => setState(() => _all = v!),
        ),
        CheckboxListTile(
          title: const Text('السماح بإضافة دوران 90°'),
          value: _rotate,
          onChanged: (v) => setState(() => _rotate = v!),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (_all, _rotate)),
        child: const Text('إنشاء الاقتراح'),
      ),
    ],
  );
}
