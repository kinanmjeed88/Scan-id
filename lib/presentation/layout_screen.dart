import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../application/ids.dart';
import '../application/layout_session.dart';
import '../application/project_service.dart';
import '../domain/page_layout.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'page_canvas.dart';

class LayoutScreen extends StatefulWidget {
  const LayoutScreen({required this.project, required this.service, super.key});
  final Project project;
  final ProjectService service;
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
        'س مم': e.x,
        'ص مم': e.y,
        'العرض مم': e.width,
        'الارتفاع مم': e.height,
        'الزاوية °': e.rotation,
      },
      notice: e.keepAspectRatio
          ? 'النسبة مثبتة: تغيير العرض يحدد الارتفاع تلقائياً.'
          : 'تنبيه: تغيير النسبة قد يشوّه النصوص والوجوه.',
    );
    if (v == null || !mounted) return;
    await _apply(
      (p) => PageLayout.replace(
        p,
        PageLayout.resize(
          e,
          v['العرض مم']!,
          v['الارتفاع مم']!,
        ).copyWith(x: v['س مم'], y: v['ص مم'], rotation: v['الزاوية °']),
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
              '${_project.paper.width.toInt()} × ${_project.paper.height.toInt()} مم · ${_busy ? 'جارٍ الحفظ…' : 'محفوظ محلياً'} · الفجوات ${_project.layout.horizontalGap}/${_project.layout.verticalGap} مم',
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
              for (final item in _project.items)
                FilterChip(
                  label: Text(
                    '${_project.items.indexOf(item) + 1}${item.locked ? ' 🔒' : ''}',
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
              values[e.key] = v!;
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
