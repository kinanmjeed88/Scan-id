import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/contracts.dart';
import '../application/project_service.dart';
import '../domain/crop_draft.dart';
import '../domain/document_kind.dart';
import '../domain/edit_history.dart';
import '../domain/geometry.dart';
import '../domain/manual_boundary.dart';
import '../domain/project.dart';
import '../domain/quad_assessment.dart';
import '../domain/validation.dart';
import 'shared.dart';
import 'shortcuts.dart';

class CropScreen extends StatefulWidget {
  const CropScreen({
    required this.project,
    required this.asset,
    required this.service,
    this.documentKind = DocumentKind.unknown,
    this.suggestedCorners,
    this.targetItemId,
    this.confirmForSheet = false,
    this.extractDerived = false,
    super.key,
  });
  final Project project;
  final ImageAsset asset;
  final ProjectService service;

  /// Category of the document being cut; its catalog shape is the default
  /// aspect ratio so the rectified image matches the printed size exactly.
  final DocumentKind documentKind;

  /// Optional editable 4-corner proposal from a `needsReview` boundary check.
  final List<Point2>? suggestedCorners;

  /// Specific layout item to update and confirm when [confirmForSheet] is used.
  final String? targetItemId;

  /// When true, requires confirming a valid document category or custom print
  /// size before committing so the item immediately enters the A4 sheet.
  final bool confirmForSheet;

  /// When true (**Path C**), opens the full uncropped root photograph and saves
  /// the accepted region as a new independent derived document on A4 without
  /// modifying the source photograph or earlier extracted documents.
  final bool extractDerived;
  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropEditorState {
  const _CropEditorState({
    required this.draft,
    required this.selectedKind,
    required this.customWidthText,
    required this.customHeightText,
  });

  final CropDraft draft;
  final DocumentKind selectedKind;
  final String customWidthText;
  final String customHeightText;

  _CropEditorState copyWith({
    CropDraft? draft,
    DocumentKind? selectedKind,
    String? customWidthText,
    String? customHeightText,
  }) => _CropEditorState(
    draft: draft ?? this.draft,
    selectedKind: selectedKind ?? this.selectedKind,
    customWidthText: customWidthText ?? this.customWidthText,
    customHeightText: customHeightText ?? this.customHeightText,
  );
}

String _formatMillimeters(double value) {
  if ((value - value.roundToDouble()).abs() < 1e-6) {
    return value.toStringAsFixed(1);
  }
  final two = value.toStringAsFixed(2);
  return two.endsWith('0') ? two.substring(0, two.length - 1) : two;
}

class _CropScreenState extends State<CropScreen> {
  final _canvasKey = GlobalKey();
  final _view = TransformationController();
  final _customWidthController = TextEditingController(text: '85.6');
  final _customHeightController = TextEditingController(text: '54.0');
  EditorSource? _source;
  EditHistory<_CropEditorState>? _history;
  _CropEditorState? _state;
  String? _coalescedCustomField;
  Uint8List? _preview;
  String? _error;
  bool _busy = true;
  bool _showResult = false;
  bool _dirty = false;
  CropDraft? _initialReviewDraft;
  late DocumentKind _initialKind;
  late String _initialWidthText;
  late String _initialHeightText;

  CropDraft? get _draft => _state?.draft;
  DocumentKind get _selectedKind => _state?.selectedKind ?? _initialKind;
  bool get _showingReviewProposal =>
      _initialReviewDraft != null && identical(_draft, _initialReviewDraft);
  ImageEditor get _editor => widget.service.imageEditor!;

  @override
  void initState() {
    super.initState();
    var resolvedKind = widget.documentKind;
    var resolvedW = '85.6';
    var resolvedH = '54.0';
    final targetItem = widget.targetItemId == null
        ? null
        : widget.project.items
              .where((i) => i.id == widget.targetItemId)
              .firstOrNull;
    if (targetItem != null) {
      if (resolvedKind == DocumentKind.unknown &&
          targetItem.documentKind != DocumentKind.unknown) {
        resolvedKind = targetItem.documentKind;
      }
      if (targetItem.sizeConfirmed) {
        resolvedW = _formatMillimeters(targetItem.width);
        resolvedH = _formatMillimeters(targetItem.height);
      }
    }
    _initialKind = resolvedKind;
    _initialWidthText = resolvedW;
    _initialHeightText = resolvedH;
    _customWidthController.text = resolvedW;
    _customHeightController.text = resolvedH;
    unawaited(_load());
  }

  @override
  void dispose() {
    _customWidthController.dispose();
    _customHeightController.dispose();
    _view.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final source = await _editor.open(widget.asset);
      if (!mounted) {
        return;
      }
      final crop = widget.extractDerived ? null : widget.asset.crop;
      final shape = widget.project.catalog.sizeFor(
        _initialKind,
        landscape: source.width >= source.height,
      );
      final initialAspect = shape == null ? null : shape.width / shape.height;
      final baseFull = CropDraft(
        corners: CropDraft.fullImage().corners,
        adjustments: widget.extractDerived
            ? CropDraft.fullImage().adjustments
            : widget.asset.adjustments,
        aspectRatio: initialAspect,
      );
      final proposed = crop == null && !widget.extractDerived
          ? _resolveSuggestedCorners(source.width, source.height)
          : null;
      final EditHistory<_CropEditorState> history;
      final _CropEditorState activeState;
      if (crop != null) {
        final activeDraft = CropDraft(
          corners: crop.corners,
          adjustments: widget.asset.adjustments,
          aspectRatio: crop.outputWidth / crop.outputHeight,
          preservedGeometry: crop,
        );
        activeState = _CropEditorState(
          draft: activeDraft,
          selectedKind: _initialKind,
          customWidthText: _initialWidthText,
          customHeightText: _initialHeightText,
        );
        history = EditHistory(activeState);
      } else if (proposed != null) {
        final baseState = _CropEditorState(
          draft: baseFull,
          selectedKind: _initialKind,
          customWidthText: _initialWidthText,
          customHeightText: _initialHeightText,
        );
        history = EditHistory(baseState);
        final proposedDraft = CropDraft(
          corners: proposed,
          adjustments: widget.asset.adjustments,
          aspectRatio: initialAspect,
        );
        activeState = baseState.copyWith(draft: proposedDraft);
        history.record(activeState);
      } else {
        activeState = _CropEditorState(
          draft: baseFull,
          selectedKind: _initialKind,
          customWidthText: _initialWidthText,
          customHeightText: _initialHeightText,
        );
        history = EditHistory(activeState);
      }
      setState(() {
        _source = source;
        _history = history;
        _state = activeState;
        _initialReviewDraft = proposed != null ? activeState.draft : null;
        _busy = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userError(error);
          _busy = false;
        });
      }
    }
  }

  List<Point2>? _resolveSuggestedCorners(int sourceWidth, int sourceHeight) {
    List<Point2>? candidate =
        widget.suggestedCorners ?? widget.asset.suggestedCrop;
    if (candidate == null) {
      for (final record in widget.project.documents) {
        for (final side in record.sides) {
          final sp = side.detection?.suggestedPolygon;
          if (sp == null) continue;
          if (assetOwnsProjectPath(
                widget.project.id,
                widget.asset.id,
                side.processedAsset.workingPath,
              ) ||
              (record.sides.length == 1 &&
                  record.sourceImageId == widget.asset.id)) {
            candidate = sp;
            break;
          }
        }
        if (candidate != null) break;
      }
    }
    if (candidate == null || candidate.length != 4) return null;
    final check = assessQuad(
      candidate,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    return check.acceptable ? candidate : null;
  }

  /// Whether the quadrilateral currently selected is wider than tall.
  bool get _draftLandscape {
    final source = _source!;
    final c = _draft!.corners;
    double edge(int a, int b) => math.sqrt(
      math.pow((c[a].x - c[b].x) * source.width, 2) +
          math.pow((c[a].y - c[b].y) * source.height, 2),
    );
    return edge(0, 1) + edge(3, 2) >= edge(0, 3) + edge(1, 2);
  }

  /// Catalog shapes turned to the orientation of the current selection.
  List<(String, double)> _aspectPresets() {
    final landscape = _draftLandscape;
    return [
      for (final kind in const [
        DocumentKind.unifiedNationalId,
        DocumentKind.residenceCard,
        DocumentKind.passport,
        DocumentKind.rationCard,
      ])
        () {
          final size = widget.project.catalog
              .natural(kind)!
              .oriented(landscape: landscape);
          return (kind.label, size.width / size.height);
        }(),
      ('A4', landscape ? 297 / 210 : 210 / 297),
      ('مربع', 1.0),
    ];
  }

  double? _aspectChoice() {
    final ratio = _draft!.aspectRatio;
    if (ratio == null) return null;
    for (final preset in _aspectPresets()) {
      if ((preset.$2 - ratio).abs() < 1e-6) return preset.$2;
    }
    return -1;
  }

  void _syncControllerText(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _commitState(_CropEditorState next) {
    _coalescedCustomField = null;
    _history!.record(next);
    _syncControllerText(_customWidthController, next.customWidthText);
    _syncControllerText(_customHeightController, next.customHeightText);
    setState(() {
      _state = next;
      _preview = null;
      _showResult = false;
      _dirty = true;
      _error = null;
    });
  }

  void _change(CropDraft next) {
    _commitState(_state!.copyWith(draft: next));
  }

  double? _tryParseCustomRatio(String widthText, String heightText) {
    final w = double.tryParse(widthText.trim().replaceAll(',', '.'));
    final h = double.tryParse(heightText.trim().replaceAll(',', '.'));
    if (w == null || h == null || !w.isFinite || !h.isFinite) return null;
    if (w < minDocumentEdgeMm ||
        w > maxDocumentEdgeMm ||
        h < minDocumentEdgeMm ||
        h > maxDocumentEdgeMm) {
      return null;
    }
    return w / h;
  }

  void _onCustomSizeEdited(String value, {required bool isWidth}) {
    final current = _state!;
    final previous = isWidth
        ? current.customWidthText
        : current.customHeightText;
    if (value == previous) return;
    final nextW = isWidth ? value : current.customWidthText;
    final nextH = isWidth ? current.customHeightText : value;
    final ratio = current.selectedKind == DocumentKind.other
        ? _tryParseCustomRatio(nextW, nextH)
        : null;
    final nextDraft = ratio != null && ratio != current.draft.aspectRatio
        ? CropDraft(
            corners: current.draft.corners,
            adjustments: current.draft.adjustments,
            aspectRatio: ratio,
          )
        : current.draft;
    final next = current.copyWith(
      draft: nextDraft,
      customWidthText: nextW,
      customHeightText: nextH,
    );
    final fieldKey = isWidth ? 'width' : 'height';
    if (_coalescedCustomField == fieldKey) {
      _history!.replaceCurrent(next);
    } else {
      _history!.record(next);
      _coalescedCustomField = fieldKey;
    }
    setState(() {
      _state = next;
      _preview = null;
      _showResult = false;
      _dirty = true;
      _error = null;
    });
  }

  void _undo(bool redo) {
    _coalescedCustomField = null;
    final next = redo ? _history!.redo() : _history!.undo();
    _syncControllerText(_customWidthController, next.customWidthText);
    _syncControllerText(_customHeightController, next.customHeightText);
    setState(() {
      _state = next;
      _preview = null;
      _showResult = false;
      _dirty = true;
      _error = null;
    });
  }

  ImageEditRecipe _recipe() {
    final validation = requireValidManualBoundary(
      corners: _draft!.corners,
      sourceWidth: _source!.width,
      sourceHeight: _source!.height,
      adjustments: _draft!.adjustments,
      aspectRatio: _draft!.aspectRatio,
      catalog: widget.project.catalog,
    );
    return validation.recipe!;
  }

  PhysicalSizeMm? _parseCustomSize() {
    if (_selectedKind != DocumentKind.other) return null;
    final w = double.tryParse(
      _state!.customWidthText.trim().replaceAll(',', '.'),
    );
    final h = double.tryParse(
      _state!.customHeightText.trim().replaceAll(',', '.'),
    );
    if (w == null || h == null || !w.isFinite || !h.isFinite) {
      throw const ValidationException(
        'أدخل عرض المستمسك وارتفاعه بالمليمتر بأرقام صحيحة.',
      );
    }
    return validDocumentSize(PhysicalSizeMm(w, h));
  }

  void _selectDocumentKind(DocumentKind? kind) {
    if (kind == null || kind == _selectedKind) return;
    final natural = widget.project.catalog.natural(kind);
    final double? nextRatio;
    if (natural != null) {
      final oriented = natural.oriented(landscape: _draftLandscape);
      nextRatio = oriented.width / oriented.height;
    } else if (kind == DocumentKind.other) {
      nextRatio =
          _tryParseCustomRatio(
            _state!.customWidthText,
            _state!.customHeightText,
          ) ??
          _draft!.aspectRatio;
    } else {
      nextRatio = null;
    }
    final nextDraft = nextRatio == _draft!.aspectRatio
        ? _draft!
        : CropDraft(
            corners: _draft!.corners,
            adjustments: _draft!.adjustments,
            aspectRatio: nextRatio,
          );
    _commitState(_state!.copyWith(draft: nextDraft, selectedKind: kind));
  }

  Future<void> _revertSavedCrop() async {
    setState(() => _busy = true);
    try {
      final saved = await widget.service.resetManualCrop(
        widget.project,
        widget.asset,
      );
      if (mounted) {
        Navigator.pop(context, saved);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userError(error);
          _busy = false;
        });
      }
    }
  }

  Future<void> _autoAdjust() async {
    setState(() => _busy = true);
    try {
      final value = await widget.service.suggestAutoAdjustments(
        widget.project,
        widget.asset,
      );
      if (!mounted) return;
      _change(_draft!.withAdjustments(value));
      showMessage(
        context,
        'طُبّق اقتراح تحسين محلي قابل للتعديل؛ راجع النتيجة قبل الحفظ.',
      );
    } catch (error) {
      if (mounted) setState(() => _error = userError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _suggest() async {
    setState(() => _busy = true);
    try {
      final points = await _editor.suggest(_source!.preview);
      if (!mounted) {
        return;
      }
      if (points == null) {
        showMessage(
          context,
          'لم نجد حدوداً موثوقة. حرّك الزوايا يدوياً؛ لم تتغير الصورة.',
        );
      } else {
        _change(
          CropDraft(
            corners: points,
            adjustments: _draft!.adjustments,
            aspectRatio: _draft!.aspectRatio,
          ),
        );
        showMessage(
          context,
          'اقتراح فقط: راجع الزوايا وعدّلها أو تراجع عنه قبل المعاينة.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _render() async {
    setState(() => _busy = true);
    try {
      final recipe = _recipe();
      final bytes = await _editor.preview(widget.asset, recipe);
      if (mounted) {
        setState(() {
          _preview = bytes;
          _showResult = true;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _accept() async {
    if (_preview == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final recipe = _recipe();
      final Project saved;
      final kindOrSizeChanged =
          (_selectedKind != _initialKind &&
              _selectedKind != DocumentKind.unknown) ||
          (_selectedKind == DocumentKind.other &&
              (_state!.customWidthText != _initialWidthText ||
                  _state!.customHeightText != _initialHeightText));
      if (widget.extractDerived) {
        final customSize = _parseCustomSize();
        saved = await widget.service.extractManualDerivedDocument(
          widget.project,
          widget.asset,
          recipe,
          documentKind: _selectedKind,
          customSizeMm: customSize,
          sourceWidth: _source!.width,
          sourceHeight: _source!.height,
        );
      } else if (widget.confirmForSheet || kindOrSizeChanged) {
        final customSize = _parseCustomSize();
        saved = await widget.service.confirmManualBoundary(
          widget.project,
          widget.asset,
          recipe,
          documentKind: _selectedKind,
          customSizeMm: customSize,
          targetItemId: widget.targetItemId,
          sourceWidth: _source!.width,
          sourceHeight: _source!.height,
        );
      } else {
        saved = await widget.service.applyManualCrop(
          widget.project,
          widget.asset,
          recipe,
          sourceWidth: _source!.width,
          sourceHeight: _source!.height,
        );
      }
      if (mounted) {
        Navigator.pop(context, saved);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userError(error);
          _busy = false;
        });
      }
    }
  }

  Future<void> _leave() async {
    if (_busy) {
      return;
    }
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إلغاء تعديلات القص؟'),
        content: const Text(
          'لم تُحفظ التعديلات بعد. سيبقى الأصل وآخر نسخة معتمدة كما هما.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('متابعة التحرير'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إلغاء التعديلات'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      Navigator.pop(context);
    }
  }

  List<ShortcutBinding> get _shortcuts => [
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
      keys: 'Ctrl + Z',
      description: 'تراجع عن تعديل الزوايا أو الضبط',
      run: () {
        if (_history?.canUndo ?? false) {
          _undo(false);
        }
      },
    ),
    ShortcutBinding(
      activator: const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ),
      keys: 'Ctrl + Shift + Z',
      description: 'إعادة التعديل الملغى',
      run: () {
        if (_history?.canRedo ?? false) {
          _undo(true);
        }
      },
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.keyY, control: true),
      keys: 'Ctrl + Y',
      description: 'إعادة التعديل الملغى',
      run: () {
        if (_history?.canRedo ?? false) {
          _undo(true);
        }
      },
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.enter),
      keys: 'Enter',
      description: 'إنشاء معاينة التصحيح قبل الاعتماد',
      run: () {
        if (!_busy && _source != null) {
          unawaited(_render());
        }
      },
    ),
    ShortcutBinding(
      activator: const SingleActivator(LogicalKeyboardKey.escape),
      keys: 'Esc',
      description: 'الخروج (مع تأكيد عند وجود تعديلات غير محفوظة)',
      run: () => unawaited(_leave()),
    ),
  ];

  @override
  Widget build(BuildContext context) => ScreenShortcuts(
    shortcuts: _shortcuts,
    child: PopScope<Project>(
      canPop: !_busy && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_leave());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'إلغاء القص',
            onPressed: _busy ? null : _leave,
            icon: const Icon(Icons.close),
          ),
          title: Text(
            widget.extractDerived
                ? 'استخراج مستمسك مستقل من الأصل'
                : 'قص وتصحيح المستمسك',
          ),
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
              onPressed: !_busy && (_history?.canUndo ?? false)
                  ? () => _undo(false)
                  : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'إعادة',
              onPressed: !_busy && (_history?.canRedo ?? false)
                  ? () => _undo(true)
                  : null,
              icon: const Icon(Icons.redo),
            ),
          ],
        ),
        body: _source == null
            ? Center(
                child: _busy
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error ?? 'تعذر فتح الصورة.'),
                      ),
              )
            : Column(
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_showingReviewProposal)
                    Container(
                      key: const Key('crop-proposed-banner'),
                      width: double.infinity,
                      color: Theme.of(
                        context,
                      ).colorScheme.secondaryContainer.withValues(alpha: 0.65),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: const Text(
                        'حدود مقترحة للمراجعة فقط: عدّل الزوايا الأربع عند الحاجة، ثم اضغط «معاينة التصحيح» قبل الاعتماد.',
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        if (constraints.maxWidth >= 900) {
                          return Row(
                            children: [
                              Expanded(child: _imageArea()),
                              SizedBox(
                                width: 310,
                                child: SingleChildScrollView(child: _tools()),
                              ),
                            ],
                          );
                        }
                        return ListView(
                          children: [
                            SizedBox(
                              height: math.max(
                                240,
                                math.min(440, constraints.maxHeight * .52),
                              ),
                              child: _imageArea(),
                            ),
                            _tools(),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    ),
  );

  Widget _imageArea() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('الزوايا')),
            ButtonSegment(value: true, label: Text('المعاينة')),
          ],
          selected: {_showResult},
          onSelectionChanged: _busy
              ? null
              : (values) {
                  if (values.single && _preview == null) {
                    showMessage(context, 'اضغط معاينة أولاً.');
                    return;
                  }
                  setState(() => _showResult = values.single);
                },
        ),
      ),
      Expanded(
        child: _showResult && _preview != null
            ? InteractiveViewer(
                child: Center(
                  child: Image.memory(
                    _preview!,
                    key: const Key('crop-result'),
                    fit: BoxFit.contain,
                  ),
                ),
              )
            : ClipRect(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final ratio = _source!.width / _source!.height;
                      final width = math.min(
                        box.maxWidth - 40,
                        (box.maxHeight - 40) * ratio,
                      );
                      final height = width / ratio;
                      return Center(
                        child: InteractiveViewer(
                          transformationController: _view,
                          minScale: 1,
                          maxScale: 5,
                          clipBehavior: Clip.none,
                          child: SizedBox(
                            // The hit-test box includes the entire corner handles,
                            // not just the image. Clip.none alone only expands paint.
                            width: width + 40,
                            height: height + 40,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  left: 20,
                                  top: 20,
                                  width: width,
                                  height: height,
                                  child: SizedBox(
                                    key: _canvasKey,
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: Image.memory(
                                            _source!.preview,
                                            fit: BoxFit.fill,
                                          ),
                                        ),
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: CustomPaint(
                                              painter: _CropPainter(
                                                _draft!.corners,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                for (var i = 0; i < 4; i++)
                                  Positioned(
                                    left: _draft!.corners[i].x * width,
                                    top: _draft!.corners[i].y * height,
                                    child: GestureDetector(
                                      key: Key('crop-corner-$i'),
                                      behavior: HitTestBehavior.opaque,
                                      onPanUpdate: _busy
                                          ? null
                                          : (details) {
                                              final render =
                                                  _canvasKey.currentContext!
                                                          .findRenderObject()!
                                                      as RenderBox;
                                              final local = render
                                                  .globalToLocal(
                                                    details.globalPosition,
                                                  );
                                              final next = _draft!.withCorner(
                                                i,
                                                Point2(
                                                  (local.dx / width)
                                                      .clamp(0, 1)
                                                      .toDouble(),
                                                  (local.dy / height)
                                                      .clamp(0, 1)
                                                      .toDouble(),
                                                ),
                                              );
                                              setState(() {
                                                _coalescedCustomField = null;
                                                _state = _state!.copyWith(
                                                  draft: next,
                                                );
                                                _preview = null;
                                                _showResult = false;
                                                _dirty = true;
                                                _error = null;
                                              });
                                            },
                                      onPanEnd: _busy
                                          ? null
                                          : (_) {
                                              _change(_draft!);
                                            },
                                      onPanCancel: _busy
                                          ? null
                                          : () {
                                              setState(() {
                                                _coalescedCustomField = null;
                                                _state = _history!.current;
                                              });
                                            },
                                      child: Semantics(
                                        label: 'زاوية القص ${i + 1}',
                                        child: Container(
                                          width: 40,
                                          height: 40,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: const Color(0xff12685e),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2,
                                            ),
                                          ),
                                          child: Text(
                                            '${i + 1}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
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
              ),
      ),
    ],
  );

  Widget _tools() {
    final adjustments = _draft!.adjustments;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'حرّك الزوايا الأربع. كبّر الصورة بإصبعين أو بعجلة الفأرة. لا يتغير الأصل.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _suggest,
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('اقتراح حدود المستمسك'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _autoAdjust,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('تحسين تلقائي قابل للتعديل'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _change(
                    _draft!.withAdjustments(
                      adjustments.copyWith(
                        quarterTurns: (adjustments.quarterTurns + 1) % 4,
                      ),
                    ),
                  ),
            icon: const Icon(Icons.rotate_90_degrees_cw),
            label: Text('تدوير · ${adjustments.quarterTurns * 90}°'),
          ),
          const SizedBox(height: 12),
          const Text('نوع المستمسك ومقاس الطباعة على A4'),
          DropdownButton<DocumentKind>(
            key: const Key('crop-document-kind'),
            isExpanded: true,
            value: _selectedKind,
            items: [
              DropdownMenuItem(
                value: DocumentKind.unknown,
                child: Text(
                  widget.confirmForSheet || widget.extractDerived
                      ? 'اختر النوع لتأكيد الإضافة إلى A4…'
                      : 'دون تغيير النوع على الورقة',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final kind in const [
                DocumentKind.unifiedNationalId,
                DocumentKind.residenceCard,
                DocumentKind.passport,
                DocumentKind.rationCard,
              ])
                DropdownMenuItem(
                  value: kind,
                  child: Text(kind.label, overflow: TextOverflow.ellipsis),
                ),
              const DropdownMenuItem(
                value: DocumentKind.other,
                child: Text(
                  'مقاس مخصص (مم)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            onChanged: _busy ? null : _selectDocumentKind,
          ),
          if (_selectedKind == DocumentKind.other) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('crop-custom-width-mm'),
                    controller: _customWidthController,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'العرض (مم)',
                      isDense: true,
                    ),
                    onChanged: (value) =>
                        _onCustomSizeEdited(value, isWidth: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('crop-custom-height-mm'),
                    controller: _customHeightController,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'الارتفاع (مم)',
                      isDense: true,
                    ),
                    onChanged: (value) =>
                        _onCustomSizeEdited(value, isWidth: false),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          const Text('شكل المستمسك (يحدد نسبة الأبعاد بعد التصحيح)'),
          DropdownButton<double?>(
            key: const Key('crop-aspect'),
            isExpanded: true,
            value: _aspectChoice(),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('تقدير من الزوايا'),
              ),
              for (final preset in _aspectPresets())
                DropdownMenuItem(value: preset.$2, child: Text(preset.$1)),
              const DropdownMenuItem(
                value: -1,
                enabled: false,
                child: Text('النسبة المحفوظة'),
              ),
            ],
            onChanged: _busy
                ? null
                : (ratio) => _change(
                    CropDraft(
                      corners: _draft!.corners,
                      adjustments: adjustments,
                      aspectRatio: ratio,
                    ),
                  ),
          ),
          Text('الإضاءة: ${(adjustments.brightness * 100).round()}'),
          Slider(
            key: const Key('crop-brightness'),
            value: adjustments.brightness,
            min: -.5,
            max: .5,
            divisions: 20,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _coalescedCustomField = null;
                    _state = _state!.copyWith(
                      draft: _draft!.withAdjustments(
                        adjustments.copyWith(brightness: v),
                      ),
                    );
                    _preview = null;
                    _showResult = false;
                    _dirty = true;
                  }),
            onChangeEnd: _busy ? null : (_) => _change(_draft!),
          ),
          Text('التباين: ${adjustments.contrast.toStringAsFixed(2)}'),
          Slider(
            key: const Key('crop-contrast'),
            value: adjustments.contrast,
            min: .25,
            max: 3,
            divisions: 55,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _coalescedCustomField = null;
                    _state = _state!.copyWith(
                      draft: _draft!.withAdjustments(
                        adjustments.copyWith(contrast: v),
                      ),
                    );
                    _preview = null;
                    _showResult = false;
                    _dirty = true;
                  }),
            onChangeEnd: _busy ? null : (_) => _change(_draft!),
          ),
          Text('تشبع الألوان: ${adjustments.saturation.toStringAsFixed(2)}'),
          Slider(
            key: const Key('crop-saturation'),
            value: adjustments.saturation,
            min: 0,
            max: 2,
            divisions: 20,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _coalescedCustomField = null;
                    _state = _state!.copyWith(
                      draft: _draft!.withAdjustments(
                        adjustments.copyWith(saturation: v),
                      ),
                    );
                    _preview = null;
                    _showResult = false;
                    _dirty = true;
                  }),
            onChangeEnd: _busy ? null : (_) => _change(_draft!),
          ),
          Text('حدة الصورة: ${adjustments.sharpness.toStringAsFixed(2)}'),
          Slider(
            key: const Key('crop-sharpness'),
            value: adjustments.sharpness,
            min: 0,
            max: 1,
            divisions: 20,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _coalescedCustomField = null;
                    _state = _state!.copyWith(
                      draft: _draft!.withAdjustments(
                        adjustments.copyWith(sharpness: v),
                      ),
                    );
                    _preview = null;
                    _showResult = false;
                    _dirty = true;
                  }),
            onChangeEnd: _busy ? null : (_) => _change(_draft!),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _commitState(
                    _CropEditorState(
                      draft: CropDraft.fullImage(),
                      selectedKind: _initialKind,
                      customWidthText: _initialWidthText,
                      customHeightText: _initialHeightText,
                    ),
                  ),
            child: const Text('إعادة ضبط إلى الأصل'),
          ),
          if (!widget.extractDerived &&
              widget.asset.crop != null &&
              !widget.asset.hasScaledLargeSource)
            TextButton(
              key: const Key('crop-revert-original'),
              onPressed: _busy ? null : _revertSavedCrop,
              child: const Text('استعادة الأصل المحفوظ وإلغاء القص'),
            ),
          const Text(
            'راجع النصوص والوجوه قبل الاعتماد. النسبة المقدرة لا تحدد الحجم الحقيقي ولا تضمن استعادته من الصورة.',
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _busy ? null : _render,
            child: const Text('معاينة التصحيح'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('accept-crop'),
            onPressed: _busy || _preview == null ? null : _accept,
            child: const Text('اعتماد القص وحفظ'),
          ),
        ],
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter(this.points);
  final List<Point2> points;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(points[0].x * size.width, points[0].y * size.height);
    for (final p in points.skip(1)) {
      path.lineTo(p.x * size.width, p.y * size.height);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xff12685e).withValues(alpha: .15),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff12685e)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      !identical(oldDelegate.points, points);
}
