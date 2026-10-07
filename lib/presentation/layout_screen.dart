import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../application/ids.dart';
import '../application/packing_service.dart';
import '../domain/crop_draft.dart';
import '../domain/document_kind.dart';
import '../domain/image_adjustments.dart';
import '../domain/packing.dart';
import '../application/layout_session.dart';
import '../application/project_service.dart';
import '../domain/page_layout.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'page_canvas.dart';
import 'crop_screen.dart';
import 'export_screen.dart';
import 'shared.dart';
import 'shortcuts.dart';

class LayoutScreen extends StatefulWidget {
  const LayoutScreen({
    required this.project,
    required this.service,
    this.proposeLayout = createPackingProposal,
    this.intakeSummary,
    this.intakeWarnings = const [],
    super.key,
  });
  final Project project;
  final ProjectService service;
  final PackingProposer proposeLayout;
  final String? intakeSummary;
  final List<String> intakeWarnings;
  @override
  State<LayoutScreen> createState() => _LayoutScreenState();
}

class _LayoutScreenState extends State<LayoutScreen> {
  late final _session = LayoutSession(widget.project, widget.service.projects);
  final _pageKey = GlobalKey();
  final _view = TransformationController();
  final _canvasFocus = FocusNode(debugLabel: 'layout-canvas');
  final _selected = <String>{};
  bool _busy = false, _pan = false, _overlap = false;
  String? _error;
  String? _adjustmentAssetId;
  ImageAdjustments? _adjustmentDraft;
  Project? _dragPreview;
  DocumentItem? _dragItem;
  Offset? _dragStart;
  bool _resizing = false;
  double _scale = 1;
  int _page = 0;
  // Arrow-key nudges are shown immediately and committed once the key stops
  // repeating, so holding a key does not write one revision per repeat.
  Timer? _nudgeTimer;
  String? _nudgeId;
  double _nudgeDx = 0, _nudgeDy = 0;
  Project get _project => _dragPreview ?? _session.current;
  DocumentItem? get _active => _selected.isEmpty
      ? null
      : _project.items.where((e) => e.id == _selected.last).firstOrNull;
  @override
  void dispose() {
    _nudgeTimer?.cancel();
    _canvasFocus.dispose();
    _view.dispose();
    super.dispose();
  }

  void _nudge(double dx, double dy) {
    final item = _active;
    if (item == null || item.locked || _busy || _pan || _dragItem != null) {
      return;
    }
    if (_nudgeId != item.id) {
      _nudgeId = item.id;
      _nudgeDx = 0;
      _nudgeDy = 0;
    }
    _nudgeDx += dx;
    _nudgeDy += dy;
    setState(
      () => _dragPreview = _session.current.copyWith(
        items: [
          for (final entry in _session.current.items)
            entry.id == item.id
                ? entry.copyWith(x: entry.x + _nudgeDx, y: entry.y + _nudgeDy)
                : entry,
        ],
      ),
    );
    _nudgeTimer?.cancel();
    _nudgeTimer = Timer(
      const Duration(milliseconds: 260),
      () => unawaited(_flushNudge()),
    );
  }

  Future<void> _flushNudge() async {
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    final id = _nudgeId;
    final dx = _nudgeDx, dy = _nudgeDy;
    _nudgeId = null;
    _nudgeDx = 0;
    _nudgeDy = 0;
    if (id == null || (dx == 0 && dy == 0)) {
      return;
    }
    await _apply((p) => PageLayout.move(p, id, dx, dy, allowOverlap: _overlap));
    if (mounted) {
      setState(() => _dragPreview = null);
    }
  }

  Future<void> _leave() async {
    await _flushNudge();
    if (mounted) {
      Navigator.pop(context, _session.current);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || _dragItem != null) return;
    if (_nudgeId != null) {
      await _flushNudge();
      if (!mounted) return;
    }
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
    final resizedId = _resizing ? _dragItem?.id : null;
    setState(() {
      _dragPreview = null;
      _dragItem = null;
      _dragStart = null;
      _resizing = false;
    });
    if (preview != null) {
      await _apply((_) {
        final candidate = resizedId == null
            ? preview
            : preview.copyWith(
                items: [
                  for (final item in preview.items)
                    item.id == resizedId
                        ? item.copyWith(sizeConfirmed: false, unplaced: true)
                        : item,
                ],
              );
        return PageLayout.checked(candidate, allowOverlap: _overlap);
      });
    }
  }

  Future<void> _add(ImageAsset asset) async {
    final p = _session.current;
    final input = await editMeasurements(
      context,
      'المقاسات الفعلية للمستمسك',
      {
        'الصفحة (0 لغير الموضوعة)': (_page + 1).toDouble(),
        'العرض مم': 80,
        'الارتفاع مم': 80 * asset.height / asset.width,
        'س مم': p.paper.margins.left,
        'ص مم': p.paper.margins.top,
        'عدد النسخ الإضافية': 0,
      },
      notice:
          'هذه قيم مبدئية وليست قياساً مستنتجاً من الصورة. أدخل المقاس الحقيقي. النسخ الإضافية تُضاف غير موضوعة ليوزعها «اقتراح ترتيب».',
      requireSizeConfirmation: true,
    );
    if (input == null || !mounted) return;
    final values = input.values;
    final copies = _count(values['عدد النسخ الإضافية']!);
    if (copies == null) return;
    final id = newId();
    await _apply((project) {
      final prototype = DocumentItem(
        id: id,
        assetId: asset.id,
        pageIndex: _pageNumber(
          values['الصفحة (0 لغير الموضوعة)']!,
          project.pageCount,
        ),
        x: values['س مم']!,
        y: values['ص مم']!,
        width: values['العرض مم']!,
        height: values['الارتفاع مم']!,
        sizeConfirmed: input.sizeConfirmed,
        zIndex:
            project.items.fold<int>(
              0,
              (value, item) => math.max(value, item.zIndex),
            ) +
            1,
      );
      return PageLayout.addMany(project, [
        prototype,
        ...PageLayout.copies(prototype, copies, newId),
      ], allowOverlap: _overlap);
    });
    if (mounted && _session.current.items.any((e) => e.id == id)) {
      setState(
        () => _selected
          ..clear()
          ..add(id),
      );
      if (copies > 0) {
        showMessage(
          context,
          'أُضيفت $copies نسخة غير موضوعة. استخدم «اقتراح ترتيب» لتوزيعها، وسيظهر ما لا يتسع.',
        );
      }
    }
  }

  /// Copies are a count the user types; a rejected value is explained in place
  /// instead of escaping as an unhandled validation error.
  int? _count(double value) {
    if (value != value.roundToDouble() || value < 0 || value > 200) {
      showMessage(context, 'عدد النسخ يجب أن يكون عدداً صحيحاً بين 0 و200.');
      return null;
    }
    return value.toInt();
  }

  Future<void> _changeDocumentKind(DocumentItem item, DocumentKind kind) async {
    if (item.locked) return;
    final asset = _session.current.assets.firstWhere(
      (entry) => entry.id == item.assetId,
    );
    final reference = kind.publishedReferenceSize(
      landscape: item.width >= item.height,
    );
    final input = await editMeasurements(
      context,
      'أدخل القياس الحقيقي للمستمسك',
      {
        'العرض مم': reference?.width ?? item.width,
        'الارتفاع مم': reference?.height ?? item.height,
      },
      notice: kind.measurementHint,
      requireSizeConfirmation: true,
      confirmSizeLabel: reference == null
          ? 'قست النسخة الأصلية بالمسطرة وأؤكد العرض والارتفاع.'
          : 'تحققت من قياس نسختي، وأؤكد أن المرجع المعروض ينطبق عليها.',
    );
    if (input == null || !mounted) return;
    final values = input.values;
    await _apply(
      (project) => PageLayout.replace(
        project,
        item.copyWith(
          documentKind: kind,
          width: values['العرض مم']!,
          height: values['الارتفاع مم']!,
          // A user selection is explicit, not a recognition confidence score.
          recognitionConfidence: 0,
          sizeConfirmed: input.sizeConfirmed,
        ),
        allowOverlap: _overlap,
      ),
    );
    if (mounted) {
      showMessage(
        context,
        'حُفظ قياس «${asset.name}». استخدم اقتراح الترتيب بعد تأكيد المقاسات المطلوبة.',
      );
    }
  }

  Future<void> _resizeStep(DocumentItem item, double direction) => _apply((p) {
    final nextWidth = math.max(1.0, item.width + direction).toDouble();
    final resized = PageLayout.resize(item, nextWidth, item.height);
    return PageLayout.replace(
      p,
      resized.copyWith(sizeConfirmed: false, unplaced: true),
      allowOverlap: _overlap,
    );
  });

  Future<void> _editCrop(ImageAsset asset) async {
    if (_busy) return;
    if (_nudgeId != null) {
      await _flushNudge();
      if (!mounted) return;
    }
    final saved = await Navigator.of(context).push<Project>(
      MaterialPageRoute(
        builder: (_) => CropScreen(
          project: _session.current,
          asset: asset,
          service: widget.service,
        ),
      ),
    );
    if (saved != null && mounted) {
      await _run(() => _session.adoptSaved(saved));
    }
  }

  ImageAdjustments _adjustmentsFor(ImageAsset asset) =>
      _adjustmentAssetId == asset.id && _adjustmentDraft != null
      ? _adjustmentDraft!
      : asset.adjustments;

  void _draftAdjustments(ImageAsset asset, ImageAdjustments value) {
    setState(() {
      _adjustmentAssetId = asset.id;
      _adjustmentDraft = value;
    });
  }

  Future<void> _commitAdjustments(
    ImageAsset asset,
    ImageAdjustments value,
  ) async {
    await _run(() async {
      final currentAsset = _session.current.assets.firstWhere(
        (entry) => entry.id == asset.id,
      );
      final geometry =
          currentAsset.crop ??
          CropDraft.fullImage()
              .toRecipe(currentAsset.width, currentAsset.height)
              .geometry;
      final revised = await widget.service.createImageRevision(
        _session.current,
        currentAsset,
        ImageEditRecipe(geometry, value),
      );
      await _session.apply(
        (project) => project.copyWith(
          assets: [
            for (final entry in project.assets)
              entry.id == revised.id ? revised : entry,
          ],
        ),
      );
    });
    if (mounted) {
      setState(() {
        _adjustmentAssetId = null;
        _adjustmentDraft = null;
      });
    }
  }

  Future<void> _autoAdjustImage(ImageAsset asset) async {
    final revisionBefore = _session.current.revision;
    await _run(() async {
      final currentAsset = _session.current.assets.firstWhere(
        (entry) => entry.id == asset.id,
      );
      final adjustment = await widget.service.suggestAutoAdjustments(
        _session.current,
        currentAsset,
      );
      final geometry =
          currentAsset.crop ??
          CropDraft.fullImage()
              .toRecipe(currentAsset.width, currentAsset.height)
              .geometry;
      final revised = await widget.service.createImageRevision(
        _session.current,
        currentAsset,
        ImageEditRecipe(geometry, adjustment),
      );
      await _session.apply(
        (project) => project.copyWith(
          assets: [
            for (final entry in project.assets)
              entry.id == revised.id ? revised : entry,
          ],
        ),
      );
    });
    if (mounted) {
      setState(() {
        _adjustmentAssetId = null;
        _adjustmentDraft = null;
      });
      if (_session.current.revision > revisionBefore) {
        showMessage(
          context,
          'حُفظ التحسين التلقائي كنسخة جديدة قابلة للتراجع.',
        );
      }
    }
  }

  Future<void> _addCopies(DocumentItem item) async {
    final input = await editMeasurements(
      context,
      'نسخ إضافية من العنصر',
      {'عدد النسخ الإضافية': 3},
      notice:
          'لا تتغير النسخة الأصلية. تُضاف النسخ غير موضوعة، ثم يوزعها «اقتراح ترتيب» ويُبلّغ عن كل نسخة لا تتسع لها الصفحة.',
    );
    if (input == null || !mounted) return;
    final count = _count(input.values['عدد النسخ الإضافية']!);
    if (count == null || count == 0) return;
    await _apply(
      (p) => PageLayout.addMany(
        p,
        PageLayout.copies(item, count, newId),
        allowOverlap: _overlap,
      ),
    );
    if (mounted) {
      showMessage(
        context,
        'أُضيفت $count نسخة غير موضوعة؛ رتّبها بـ«اقتراح ترتيب» أو يدوياً.',
      );
    }
  }

  Future<void> _properties(DocumentItem e) async {
    final input = await editMeasurements(
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
          ? 'النسبة مثبتة: تغيير أحد البعدين يضبط الآخر؛ عند تغيير كليهما يُعتمد العرض. القياس غير المؤكد يبقى خارج الورقة.'
          : 'تنبيه: تغيير النسبة قد يشوّه النصوص والوجوه. القياس غير المؤكد يبقى خارج الورقة.',
      offerSizeConfirmation: true,
    );
    if (input == null || !mounted) return;
    final v = input.values;
    var sizeConfirmed = false;
    await _apply((p) {
      final resized = PageLayout.resize(e, v['العرض مم']!, v['الارتفاع مم']!);
      final dimensionsChanged =
          resized.width != e.width || resized.height != e.height;
      sizeConfirmed =
          input.sizeConfirmed || (e.sizeConfirmed && !dimensionsChanged);
      final pageNumber = _pageNumber(
        v['الصفحة (0 لغير الموضوعة)']!,
        p.pageCount,
      );
      return PageLayout.replace(
        p,
        resized.copyWith(
          x: v['س مم'],
          y: v['ص مم'],
          rotation: v['الزاوية °'],
          pageIndex: sizeConfirmed ? pageNumber : null,
          unplaced: !sizeConfirmed || pageNumber == null,
          sizeConfirmed: sizeConfirmed,
        ),
        allowOverlap: _overlap,
      );
    });
    if (mounted && !sizeConfirmed) {
      showMessage(
        context,
        'حُفظ التعديل، لكن القياس غير مؤكد؛ بقي العنصر خارج الورقة حتى تؤكد قياسه.',
      );
    }
  }

  Future<void> _duplicate(DocumentItem e) => _apply(
    (p) => PageLayout.add(
      p,
      e.copyWith(
        id: newId(),
        x: e.x + e.bounds.width + p.layout.horizontalGap,
        locked: false,
      ),
      allowOverlap: _overlap,
    ),
  );

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _busy) {
      return;
    }
    final ids = {..._selected};
    if (_session.current.items.any((e) => ids.contains(e.id) && e.locked)) {
      showMessage(context, 'ألغِ تثبيت العناصر المحددة قبل حذفها.');
      return;
    }
    await _apply((p) => PageLayout.remove(p, ids));
    if (mounted) {
      showMessage(
        context,
        'حُذف ${ids.length} عنصر من الورقة. يمكن التراجع بـCtrl + Z.',
      );
    }
  }

  List<ShortcutBinding> get _shortcuts => [
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
      keys: 'Ctrl + Z',
      description: 'تراجع عن آخر تغيير محفوظ',
      run: () => unawaited(_run(_session.undo)),
    ),
    ShortcutBinding(
      activator: const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ),
      keys: 'Ctrl + Shift + Z',
      description: 'إعادة التغيير الملغى',
      run: () => unawaited(_run(_session.redo)),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyY, control: true),
      keys: 'Ctrl + Y',
      description: 'إعادة التغيير الملغى',
      run: () => unawaited(_run(_session.redo)),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.delete),
      keys: 'Delete',
      description: 'حذف العناصر المحددة من الورقة',
      run: () => unawaited(_deleteSelected()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.backspace),
      keys: 'Backspace',
      description: 'حذف العناصر المحددة من الورقة',
      run: () => unawaited(_deleteSelected()),
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyD, control: true),
      keys: 'Ctrl + D',
      description: 'تكرار العنصر المحدد',
      run: () {
        final e = _active;
        if (e != null && !e.locked) {
          unawaited(_duplicate(e));
        }
      },
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.escape),
      keys: 'Esc',
      description: 'إلغاء التحديد',
      run: () {
        if (mounted) {
          setState(_selected.clear);
        }
      },
    ),
    ShortcutBinding(
      activator: const SingleActivator(
        LogicalKeyboardKey.digit0,
        control: true,
      ),
      keys: 'Ctrl + 0',
      description: 'إعادة ضبط تكبير مساحة العمل',
      run: () {
        if (mounted) {
          setState(() => _view.value = Matrix4.identity());
        }
      },
    ),
    // Handled by the canvas focus node so arrows inside menus and lists keep
    // their normal meaning; listed here for discoverability.
    const ShortcutBinding(
      activator: SingleActivator(LogicalKeyboardKey.arrowLeft),
      keys: '← → ↑ ↓',
      description:
          'تحريك العنصر المحدد 1 مم (مع Shift: 10 مم). يعمل عندما يكون التركيز على مساحة الورقة',
    ),
    const ShortcutBinding(
      activator: SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true),
      keys: 'Shift + ←',
      description: 'تحريك العنصر المحدد 10 مم',
    ),
  ];

  Future<void> _paper() async {
    final p = _project;
    final input = await editMeasurements(context, 'الهوامش والمسافات مم', {
      'أعلى': p.paper.margins.top,
      'يمين': p.paper.margins.right,
      'أسفل': p.paper.margins.bottom,
      'يسار': p.paper.margins.left,
      'فجوة أفقية': p.layout.horizontalGap,
      'فجوة عمودية': p.layout.verticalGap,
    });
    if (input == null || !mounted) return;
    final v = input.values;
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
    final options = await showDialog<_PackingChoices>(
      context: context,
      builder: (_) => const _PackingOptions(),
    );
    if (options == null || !mounted) return;
    PackingProposal? proposal;
    await _run(() async {
      proposal = await widget.proposeLayout(
        _session.current,
        includeLocked: options.includeLocked,
        allowRotation: options.allowRotation,
        onlyUnplaced: options.onlyUnplaced,
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
                Text(
                  options.onlyUnplaced
                      ? 'لم يُحفظ الاقتراح. العناصر الموضوعة لا تتحرك؛ تُرتَّب العناصر غير الموضوعة فقط. يمكن رفض الاقتراح أو التراجع بعد اعتماده. لا ضمان لترتيب أمثل.'
                      : 'لم يُحفظ الاقتراح. الاعتماد يغيّر المواضع الحالية؛ يمكن التراجع عنه وتعديله يدوياً. لا ضمان لترتيب أمثل.',
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
  Widget build(BuildContext context) => ScreenShortcuts(
    shortcuts: _shortcuts,
    child: PopScope<Project>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) {
          unawaited(_leave());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'رجوع للمشروع',
            onPressed: _busy ? null : () => unawaited(_leave()),
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('محرر A4'),
          actions: [
            IconButton(
              tooltip: 'اختصارات لوحة المفاتيح',
              onPressed: _busy
                  ? null
                  : () => showShortcuts(context, _shortcuts),
              icon: const Icon(Icons.keyboard_outlined),
            ),
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
                // Pointing at the sheet gives the arrow keys their target.
                onPointerDown: (_) => _canvasFocus.requestFocus(),
                onPointerCancel: (_) => setState(() {
                  _dragPreview = null;
                  _dragItem = null;
                  _dragStart = null;
                }),
                child: Focus(
                  focusNode: _canvasFocus,
                  autofocus: true,
                  onKeyEvent: (_, event) => canvasArrowKeys(
                    event,
                    _nudge,
                    enabled: _active != null && !_busy && !_pan,
                  ),
                  child: PageCanvas(
                    project: _project,
                    pageIndex: _page,
                    assets: widget.service.assets,
                    scale: _scale,
                    pageKey: _pageKey,
                    selected: _selected,
                    onSelect: (id) {
                      setState(
                        () => _selected
                          ..clear()
                          ..add(id),
                      );
                      _canvasFocus.requestFocus();
                    },
                    onDragStart: _start,
                    onDragUpdate: _drag,
                    onDragEnd: _end,
                  ),
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
    final activeAsset = e == null
        ? null
        : _project.assets.firstWhere((asset) => asset.id == e.assetId);
    final adjustments = activeAsset == null
        ? null
        : _adjustmentsFor(activeAsset);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.intakeSummary != null)
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(widget.intakeSummary!),
                    for (final warning in widget.intakeWarnings.take(4))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('• $warning'),
                      ),
                    if (widget.intakeWarnings.length > 4)
                      Text(
                        'وتوجد ${widget.intakeWarnings.length - 4} تنبيهات أخرى.',
                      ),
                    const Text(
                      'الحدود ونوع المستمسك اقتراحات محلية؛ راجعها وعدّل القياس قبل الطباعة.',
                    ),
                  ],
                ),
              ),
            ),
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
          Tooltip(
            message:
                'الاقتراح لا يُطبَّق تلقائياً أبداً: تختار نطاقه ثم تراجعه وتعتمده أو ترفضه. والوضع الحر يدوي دائماً',
            child: OutlinedButton.icon(
              key: const Key('packing-proposal'),
              onPressed: _busy || _project.items.isEmpty ? null : _pack,
              icon: const Icon(Icons.auto_awesome_mosaic),
              label: const Text('ترتيب تلقائي (اقتراح) أو وضع حر'),
            ),
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
                    '${_project.items.indexOf(item) + 1} · ${item.documentKind.label}${item.pageIndex == null ? (item.sizeConfirmed ? ' · غير موضوع' : ' · قياس غير مؤكد') : ''}${item.locked ? ' 🔒' : ''}',
                  ),
                  selected: _selected.contains(item.id),
                  onSelected: _busy
                      ? null
                      : (v) {
                          setState(() {
                            if (v) {
                              _selected.add(item.id);
                            } else {
                              _selected.remove(item.id);
                            }
                          });
                          // Selecting from the list is also how the arrow keys
                          // get their target.
                          _canvasFocus.requestFocus();
                        },
                ),
            ],
          ),
          if (e != null && activeAsset != null && adjustments != null) ...[
            Text(
              'س ${e.x.toStringAsFixed(1)} · ص ${e.y.toStringAsFixed(1)} مم\n${e.width.toStringAsFixed(1)} × ${e.height.toStringAsFixed(1)} مم · ${e.rotation.toStringAsFixed(1)}°',
            ),
            DropdownButton<DocumentKind>(
              isExpanded: true,
              value: e.documentKind,
              items: [
                for (final kind in DocumentKind.values)
                  DropdownMenuItem(value: kind, child: Text(kind.label)),
              ],
              onChanged: _busy || e.locked
                  ? null
                  : (kind) {
                      if (kind != null) {
                        unawaited(_changeDocumentKind(e, kind));
                      }
                    },
            ),
            OutlinedButton.icon(
              onPressed: _busy || e.locked
                  ? null
                  : () => _changeDocumentKind(e, e.documentKind),
              icon: const Icon(Icons.straighten),
              label: const Text('تأكيد النوع وإدخال القياس'),
            ),
            Text(
              e.recognitionConfidence > 0
                  ? 'اقتراح محلي من اسم الملف/نسبة الصورة: ${e.documentKind.label} · مؤشر ${(e.recognitionConfidence * 100).round()}% — راجع النوع.'
                  : e.documentKind == DocumentKind.unknown
                  ? 'لم يُحدد النوع؛ اختره يدوياً قبل الطباعة.'
                  : 'النوع اختاره المستخدم: ${e.documentKind.label}.',
            ),
            Text(
              e.sizeConfirmed
                  ? '${e.documentKind.measurementHint}\nتم تأكيد القياس لهذا المستمسك.'
                  : '${e.documentKind.measurementHint}\nالقياس المعروض غير مؤكد؛ يبقى العنصر خارج الورقة حتى تدخل قياسك وتؤكده.',
              style: TextStyle(
                color: e.sizeConfirmed
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _editCrop(activeAsset),
              icon: const Icon(Icons.crop),
              label: const Text('مراجعة القص الذكي وحدود المستمسك'),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'تصغير العرض 1 مم مع الحفاظ على النسبة',
                  onPressed: _busy || e.locked
                      ? null
                      : () => _resizeStep(e, -1),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                const Text('تغيير المقاس 1 مم'),
                IconButton(
                  tooltip: 'تكبير العرض 1 مم مع الحفاظ على النسبة',
                  onPressed: _busy || e.locked ? null : () => _resizeStep(e, 1),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            ExpansionTile(
              key: Key('image-adjustments-${activeAsset.id}'),
              title: const Text('تحسين الصورة: لون وتباين وحدّة'),
              subtitle: const Text('تلقائي قابل للتعديل يدوياً'),
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _autoAdjustImage(activeAsset),
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('اقتراح تحسين تلقائي'),
                  ),
                ),
                Text('الإضاءة ${adjustments.brightness.toStringAsFixed(2)}'),
                Slider(
                  key: Key('layout-brightness-${activeAsset.id}'),
                  value: adjustments.brightness,
                  min: -.5,
                  max: .5,
                  divisions: 20,
                  onChanged: _busy
                      ? null
                      : (value) => _draftAdjustments(
                          activeAsset,
                          adjustments.copyWith(brightness: value),
                        ),
                  onChangeEnd: _busy
                      ? null
                      : (value) => _commitAdjustments(
                          activeAsset,
                          adjustments.copyWith(brightness: value),
                        ),
                ),
                Text('التباين ${adjustments.contrast.toStringAsFixed(2)}'),
                Slider(
                  key: Key('layout-contrast-${activeAsset.id}'),
                  value: adjustments.contrast,
                  min: .25,
                  max: 3,
                  divisions: 55,
                  onChanged: _busy
                      ? null
                      : (value) => _draftAdjustments(
                          activeAsset,
                          adjustments.copyWith(contrast: value),
                        ),
                  onChangeEnd: _busy
                      ? null
                      : (value) => _commitAdjustments(
                          activeAsset,
                          adjustments.copyWith(contrast: value),
                        ),
                ),
                Text(
                  'تشبع الألوان ${adjustments.saturation.toStringAsFixed(2)}',
                ),
                Slider(
                  key: Key('layout-saturation-${activeAsset.id}'),
                  value: adjustments.saturation,
                  min: 0,
                  max: 2,
                  divisions: 20,
                  onChanged: _busy
                      ? null
                      : (value) => _draftAdjustments(
                          activeAsset,
                          adjustments.copyWith(saturation: value),
                        ),
                  onChangeEnd: _busy
                      ? null
                      : (value) => _commitAdjustments(
                          activeAsset,
                          adjustments.copyWith(saturation: value),
                        ),
                ),
                Text('حدة الصورة ${adjustments.sharpness.toStringAsFixed(2)}'),
                Slider(
                  key: Key('layout-sharpness-${activeAsset.id}'),
                  value: adjustments.sharpness,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  onChanged: _busy
                      ? null
                      : (value) => _draftAdjustments(
                          activeAsset,
                          adjustments.copyWith(sharpness: value),
                        ),
                  onChangeEnd: _busy
                      ? null
                      : (value) => _commitAdjustments(
                          activeAsset,
                          adjustments.copyWith(sharpness: value),
                        ),
                ),
              ],
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
              onPressed: _busy || e.locked ? null : () => _addCopies(e),
              child: const Text('إضافة نسخ من العنصر'),
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
              onPressed: _busy || e.locked ? null : () => _duplicate(e),
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

class MeasurementResult {
  MeasurementResult(Map<String, double> values, {required this.sizeConfirmed})
    : values = Map.unmodifiable(values);

  final Map<String, double> values;
  final bool sizeConfirmed;
}

Future<MeasurementResult?> editMeasurements(
  BuildContext context,
  String title,
  Map<String, double> values, {
  String? notice,
  bool offerSizeConfirmation = false,
  bool requireSizeConfirmation = false,
  String? confirmSizeLabel,
}) => showDialog<MeasurementResult>(
  context: context,
  builder: (_) => _MeasurementsDialog(
    title: title,
    values: values,
    notice: notice,
    offerSizeConfirmation: offerSizeConfirmation || requireSizeConfirmation,
    requireSizeConfirmation: requireSizeConfirmation,
    confirmSizeLabel: confirmSizeLabel,
  ),
);

class _MeasurementsDialog extends StatefulWidget {
  const _MeasurementsDialog({
    required this.title,
    required this.values,
    required this.notice,
    required this.offerSizeConfirmation,
    required this.requireSizeConfirmation,
    required this.confirmSizeLabel,
  });

  final String title;
  final Map<String, double> values;
  final String? notice;
  final bool offerSizeConfirmation;
  final bool requireSizeConfirmation;
  final String? confirmSizeLabel;

  @override
  State<_MeasurementsDialog> createState() => _MeasurementsDialogState();
}

class _MeasurementsDialogState extends State<_MeasurementsDialog> {
  late final _fields = {
    for (final e in widget.values.entries)
      e.key: TextEditingController(text: e.value.toStringAsFixed(2)),
  };
  String? _error;
  bool _sizeConfirmed = false;

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
            if (widget.offerSizeConfirmation)
              CheckboxListTile(
                key: const Key('confirm-size-measurement'),
                contentPadding: EdgeInsets.zero,
                value: _sizeConfirmed,
                onChanged: (value) => setState(() => _sizeConfirmed = value!),
                title: Text(
                  widget.confirmSizeLabel ??
                      'قست النسخة الأصلية بالمسطرة وأؤكد العرض والارتفاع المدخلين.',
                ),
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
        onPressed: widget.requireSizeConfirmation && !_sizeConfirmed
            ? null
            : () {
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
                    final value = double.tryParse(text);
                    require(
                      value != null && value.isFinite,
                      'أدخل أرقاماً صالحة.',
                    );
                    values[e.key] =
                        e.value.text == widget.values[e.key]!.toStringAsFixed(2)
                        ? widget.values[e.key]!
                        : value!;
                  }
                  Navigator.pop(
                    context,
                    MeasurementResult(values, sizeConfirmed: _sizeConfirmed),
                  );
                } catch (e) {
                  setState(() => _error = userError(e));
                }
              },
        child: const Text('حفظ المقاسات'),
      ),
    ],
  );
}

typedef _PackingChoices = ({
  bool includeLocked,
  bool allowRotation,
  bool onlyUnplaced,
});

class _PackingOptions extends StatefulWidget {
  const _PackingOptions();
  @override
  State<_PackingOptions> createState() => _PackingOptionsState();
}

class _PackingOptionsState extends State<_PackingOptions> {
  bool _all = false, _rotate = false, _onlyUnplaced = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('نطاق الاقتراح'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'لا تتغير المقاسات، ولا يُحذف أو يُصغَّر عنصر. ما لا يتسع يُبلَّغ عنه. لن يُحفظ شيء قبل مراجعة الاقتراح.',
        ),
        CheckboxListTile(
          key: const Key('packing-only-unplaced'),
          title: const Text('عدم تحريك العناصر الموضوعة'),
          subtitle: const Text(
            '«الوضع الحر»: يبقى ما رتّبته يدوياً في مكانه، وتُرتب العناصر غير الموضوعة فقط',
          ),
          value: _onlyUnplaced,
          onChanged: (v) => setState(() => _onlyUnplaced = v!),
        ),
        CheckboxListTile(
          title: const Text('جميع العناصر بما فيها المثبتة'),
          subtitle: const Text('دون التحديد: غير المثبتة فقط'),
          value: _all,
          onChanged: _onlyUnplaced ? null : (v) => setState(() => _all = v!),
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
        onPressed: () => Navigator.pop(context, (
          includeLocked: _all,
          allowRotation: _rotate,
          onlyUnplaced: _onlyUnplaced,
        )),
        child: const Text('إنشاء الاقتراح'),
      ),
    ],
  );
}
