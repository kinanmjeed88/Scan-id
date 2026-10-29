import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/cancellation.dart';
import '../application/contracts.dart';
import '../application/project_service.dart';
import '../domain/crop_draft.dart';
import '../domain/document_kind.dart';
import '../domain/edit_history.dart';
import '../domain/geometry.dart';
import '../domain/image_adjustments.dart';
import '../domain/manual_boundary.dart';
import '../domain/project.dart';
import '../domain/quad_assessment.dart';
import '../domain/validation.dart';
import '../imaging/prepare_image.dart';
import 'shared.dart';
import 'shortcuts.dart';

/// New manual crop drafts start at the midpoint of the existing 0–1 sharpness
/// control. It is preview-only: the original stays unchanged until acceptance.
const initialManualCropSharpness = .5;

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

  /// Category/print size of the document. It does not impose an aspect on a
  /// new crop; only an explicit user shape choice or saved recipe does.
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

class _SuggestedCornersResolution {
  const _SuggestedCornersResolution({
    this.corners,
    this.previousSavedCorners,
    this.notice,
  });

  final List<Point2>? corners;
  final List<Point2>? previousSavedCorners;
  final String? notice;
}

bool _samePoints(List<Point2>? a, List<Point2>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].x != b[i].x || a[i].y != b[i].y) return false;
  }
  return true;
}

List<Point2>? _savedSuggestionFor(Project project, ImageAsset asset) {
  final assetSuggestion = asset.suggestedCrop;
  if (assetSuggestion != null) return assetSuggestion;
  for (final record in project.documents) {
    for (final side in record.sides) {
      final saved = side.detection?.suggestedPolygon;
      if (saved == null) continue;
      if (assetOwnsProjectPath(
            project.id,
            asset.id,
            side.processedAsset.workingPath,
          ) ||
          (record.sides.length == 1 && record.sourceImageId == asset.id)) {
        return saved;
      }
    }
  }
  return null;
}

bool _usableSuggestedCorners(
  List<Point2>? corners, {
  required int sourceWidth,
  required int sourceHeight,
}) {
  if (corners == null ||
      corners.length != 4 ||
      sourceWidth < 2 ||
      sourceHeight < 2 ||
      corners.any(
        (point) =>
            !point.x.isFinite ||
            !point.y.isFinite ||
            point.x < 0 ||
            point.x > 1 ||
            point.y < 0 ||
            point.y > 1,
      )) {
    return false;
  }
  return assessQuad(
    corners,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  ).acceptable;
}

Future<bool> _hasDecodablePreview(
  Uint8List bytes, {
  CancellationToken? cancellation,
}) => runCancellableIsolate(
  () {
    try {
      final decoded = decodeForProcessing(bytes);
      return decoded.width > 0 && decoded.height > 0;
    } catch (_) {
      return false;
    }
  },
  cancellation: cancellation,
  debugName: 'crop-preview-validation',
);

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
  ImageEditRecipe? _previewRecipe;
  int _draftRevision = 0;
  int? _previewRevision;
  String? _error;
  String? _proposalNotice;
  bool _busy = true;
  bool _busyCancelable = true;
  int _operationGeneration = 0;
  CancellationToken? _operationCancellation;
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
    _initializeInitialMetadata();
    unawaited(_load());
  }

  void _initializeInitialMetadata() {
    var resolvedKind = widget.documentKind;
    var resolvedW = '85.6';
    var resolvedH = '54.0';
    final targetItem = widget.targetItemId == null
        ? null
        : widget.project.items
              .where((item) => item.id == widget.targetItemId)
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
  }

  bool _sameGeometry(CropGeometry? a, CropGeometry? b) {
    if (identical(a, b)) return true;
    if (a == null ||
        b == null ||
        a.outputWidth != b.outputWidth ||
        a.outputHeight != b.outputHeight) {
      return false;
    }
    return _samePoints(a.corners, b.corners);
  }

  bool _sameAdjustments(ImageAdjustments a, ImageAdjustments b) =>
      a.brightness == b.brightness &&
      a.contrast == b.contrast &&
      a.saturation == b.saturation &&
      a.sharpness == b.sharpness &&
      a.quarterTurns == b.quarterTurns;

  bool get _hasCurrentPreview {
    final preview = _preview;
    return preview != null &&
        preview.isNotEmpty &&
        _previewRecipe != null &&
        _previewRevision == _draftRevision &&
        _source != null &&
        _draft != null;
  }

  bool _sameCropTarget(CropScreen a, CropScreen b) {
    final oldAsset = a.asset;
    final newAsset = b.asset;
    if (a.project.id != b.project.id ||
        a.service != b.service ||
        oldAsset.id != newAsset.id ||
        oldAsset.originalPath != newAsset.originalPath ||
        oldAsset.workingPath != newAsset.workingPath ||
        oldAsset.thumbnailPath != newAsset.thumbnailPath ||
        oldAsset.width != newAsset.width ||
        oldAsset.height != newAsset.height ||
        oldAsset.derivedFrom != newAsset.derivedFrom ||
        oldAsset.userAuthoredCrop != newAsset.userAuthoredCrop ||
        !_sameAdjustments(oldAsset.adjustments, newAsset.adjustments) ||
        !_sameGeometry(oldAsset.crop, newAsset.crop) ||
        !_samePoints(oldAsset.suggestedCrop, newAsset.suggestedCrop) ||
        !_samePoints(
          _savedSuggestionFor(a.project, oldAsset),
          _savedSuggestionFor(b.project, newAsset),
        ) ||
        a.documentKind != b.documentKind ||
        !_samePoints(a.suggestedCorners, b.suggestedCorners) ||
        a.targetItemId != b.targetItemId ||
        a.confirmForSheet != b.confirmForSheet ||
        a.extractDerived != b.extractDerived ||
        !identical(a.project.catalog, b.project.catalog)) {
      return false;
    }
    final oldItem = a.targetItemId == null
        ? null
        : a.project.items
              .where((item) => item.id == a.targetItemId)
              .firstOrNull;
    final newItem = b.targetItemId == null
        ? null
        : b.project.items
              .where((item) => item.id == b.targetItemId)
              .firstOrNull;
    return oldItem?.documentKind == newItem?.documentKind &&
        oldItem?.sizeConfirmed == newItem?.sizeConfirmed &&
        oldItem?.width == newItem?.width &&
        oldItem?.height == newItem?.height;
  }

  @override
  void didUpdateWidget(covariant CropScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameCropTarget(oldWidget, widget)) return;
    _operationCancellation?.cancel();
    _operationCancellation = null;
    ++_operationGeneration;
    _source = null;
    _history = null;
    _state = null;
    _coalescedCustomField = null;
    _clearPreview();
    _error = null;
    _proposalNotice = null;
    _busy = true;
    _busyCancelable = true;
    _dirty = false;
    _initialReviewDraft = null;
    _view.value = Matrix4.identity();
    _initializeInitialMetadata();
    unawaited(_load());
  }

  @override
  void dispose() {
    ++_operationGeneration;
    _operationCancellation?.cancel();
    _operationCancellation = null;
    _customWidthController.dispose();
    _customHeightController.dispose();
    _view.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final operation = ++_operationGeneration;
    final cancellation = _operationCancellation = CancellationToken();
    _busyCancelable = true;
    final asset = widget.asset;
    final project = widget.project;
    final service = widget.service;
    final extractDerived = widget.extractDerived;
    final initialKind = _initialKind;
    final initialWidthText = _initialWidthText;
    final initialHeightText = _initialHeightText;
    try {
      final editor = service.imageEditor!;
      final source = await awaitCancellable(
        editor.open(asset, cancellation: cancellation),
        cancellation: cancellation,
      );
      if (!_isCurrentOperation(operation)) return;
      final crop = extractDerived ? null : asset.crop;
      // A category/print size is not permission to reshape pixels. Only an
      // explicit shape choice in this session (or a preserved saved recipe)
      // imposes an aspect; a new draft keeps the measured quadrilateral.
      const double? initialAspect = null;
      final startingAdjustments = extractDerived
          ? ImageAdjustments(sharpness: initialManualCropSharpness)
          : crop == null && asset.adjustments.sharpness == 0
          ? asset.adjustments.copyWith(sharpness: initialManualCropSharpness)
          : asset.adjustments;
      final baseFull = CropDraft(
        corners: CropDraft.fullImage().corners,
        adjustments: startingAdjustments,
        aspectRatio: initialAspect,
      );
      final resolution = crop == null && !extractDerived
          ? await _resolveSuggestedCorners(
              source.preview,
              source.width,
              source.height,
              project: project,
              asset: asset,
              service: service,
              cancellation: cancellation,
            )
          : const _SuggestedCornersResolution();
      if (!_isCurrentOperation(operation)) return;
      final proposed = resolution.corners;
      final EditHistory<_CropEditorState> history;
      final _CropEditorState activeState;
      if (crop != null) {
        final activeDraft = CropDraft(
          corners: crop.corners,
          adjustments: asset.adjustments,
          aspectRatio: crop.outputWidth / crop.outputHeight,
          preservedGeometry: crop,
        );
        activeState = _CropEditorState(
          draft: activeDraft,
          selectedKind: initialKind,
          customWidthText: initialWidthText,
          customHeightText: initialHeightText,
        );
        history = EditHistory(activeState);
      } else {
        final baseState = _CropEditorState(
          draft: baseFull,
          selectedKind: initialKind,
          customWidthText: initialWidthText,
          customHeightText: initialHeightText,
        );
        history = EditHistory(baseState);
        final previous = resolution.previousSavedCorners;
        if (previous != null) {
          history.record(
            baseState.copyWith(
              draft: CropDraft(
                corners: previous,
                adjustments: baseFull.adjustments,
                aspectRatio: initialAspect,
              ),
            ),
          );
        }
        if (proposed != null) {
          final proposedDraft = CropDraft(
            corners: proposed,
            adjustments: baseFull.adjustments,
            aspectRatio: initialAspect,
          );
          activeState = baseState.copyWith(draft: proposedDraft);
          history.record(activeState);
        } else {
          activeState = baseState;
        }
      }
      setState(() {
        _source = source;
        _history = history;
        _state = activeState;
        _initialReviewDraft = proposed != null ? activeState.draft : null;
        _proposalNotice = resolution.notice;
        _busy = false;
        _busyCancelable = false;
      });
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        setState(() {
          _error = userError(error);
          _busy = false;
          _busyCancelable = false;
        });
      }
    }
  }

  bool _isCurrentOperation(int operation) =>
      mounted && operation == _operationGeneration;

  int _beginOperation({required bool canCancel}) {
    _operationCancellation?.cancel();
    _operationCancellation = CancellationToken();
    final operation = ++_operationGeneration;
    setState(() {
      _busy = true;
      _busyCancelable = canCancel;
      _error = null;
    });
    return operation;
  }

  void _finishOperation(int operation) {
    if (!_isCurrentOperation(operation)) return;
    _operationCancellation = null;
    setState(() {
      _busy = false;
      _busyCancelable = false;
    });
  }

  void _clearPreview() {
    ++_draftRevision;
    _preview = null;
    _previewRecipe = null;
    _previewRevision = null;
    _showResult = false;
  }

  bool _cancelCancelableOperation() {
    if (!_busy || !_busyCancelable) return false;
    _operationCancellation?.cancel();
    _operationCancellation = null;
    ++_operationGeneration;
    setState(() {
      _busy = false;
      _busyCancelable = false;
    });
    return true;
  }

  Future<_SuggestedCornersResolution> _resolveSuggestedCorners(
    Uint8List preview,
    int sourceWidth,
    int sourceHeight, {
    required Project project,
    required ImageAsset asset,
    required ProjectService service,
    required CancellationToken cancellation,
  }) async {
    final explicit = widget.suggestedCorners;
    final candidate = explicit ?? _savedSuggestionFor(project, asset);
    if (candidate == null) return const _SuggestedCornersResolution();

    String? notice;
    if (explicit == null) {
      final editor = service.imageEditor;
      if (editor is BoundaryProposalImageEditor) {
        try {
          final refreshed = await editor.suggestProposal(
            preview,
            cancellation: cancellation,
          );
          final freshCorners = refreshed?.corners;
          if (_usableSuggestedCorners(
            freshCorners,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
          )) {
            final previous = _usableSuggestedCorners(
              candidate,
              sourceWidth: sourceWidth,
              sourceHeight: sourceHeight,
            );
            final changed = !_samePoints(freshCorners, candidate);
            return _SuggestedCornersResolution(
              corners: freshCorners,
              previousSavedCorners: changed && previous ? candidate : null,
              notice: changed
                  ? 'حُدّث الاقتراح المحلي للمراجعة فقط؛ تراجع يعيد الحدود المحفوظة السابقة. لم يُحفظ أي قص.'
                  : 'الحدود المعروضة اقتراح للمراجعة فقط؛ لا يُعتمد قص قبل المعاينة والحفظ.',
            );
          }
          notice = freshCorners == null
              ? 'لم يظهر اقتراح جديد؛ أُبقيت الحدود المحفوظة للمراجعة اليدوية.'
              : 'الاقتراح المحدّث غير صالح؛ أُبقيت الحدود المحفوظة للمراجعة اليدوية.';
        } catch (_) {
          notice =
              'تعذر تحديث الاقتراح؛ أُبقيت الحدود المحفوظة للمراجعة اليدوية.';
        }
      }
    }

    if (_usableSuggestedCorners(
      candidate,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    )) {
      return _SuggestedCornersResolution(corners: candidate, notice: notice);
    }
    return _SuggestedCornersResolution(
      notice: notice == null
          ? 'الحدود المحفوظة غير صالحة؛ عُرضت الصورة كاملة لضبطها يدوياً.'
          : '$notice الحدود المحفوظة غير صالحة؛ عُرضت الصورة كاملة لضبطها يدوياً.',
    );
  }

  /// Whether the quadrilateral currently selected is wider than tall.
  bool get _draftLandscape {
    final source = _source!;
    final c = _draft!.corners;
    final sx = math.max(1, source.width - 1);
    final sy = math.max(1, source.height - 1);
    double edge(int a, int b) => math.sqrt(
      math.pow((c[a].x - c[b].x) * sx, 2) + math.pow((c[a].y - c[b].y) * sy, 2),
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
      _clearPreview();
      _dirty = true;
      _error = null;
      _proposalNotice = null;
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
      _clearPreview();
      _dirty = true;
      _error = null;
      _proposalNotice = null;
    });
  }

  void _undo(bool redo) {
    _coalescedCustomField = null;
    final next = redo ? _history!.redo() : _history!.undo();
    _syncControllerText(_customWidthController, next.customWidthText);
    _syncControllerText(_customHeightController, next.customHeightText);
    setState(() {
      _state = next;
      _clearPreview();
      _dirty = true;
      _error = null;
      _proposalNotice = null;
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
    final service = widget.service;
    final project = widget.project;
    final asset = widget.asset;
    final operation = _beginOperation(canCancel: false);
    try {
      final saved = await service.resetManualCrop(project, asset);
      if (!mounted || operation != _operationGeneration) return;
      Navigator.pop(context, saved);
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        setState(() {
          _error = userError(error);
          _busy = false;
          _busyCancelable = false;
        });
      }
    }
  }

  Future<void> _autoAdjust() async {
    final service = widget.service;
    final project = widget.project;
    final asset = widget.asset;
    final draft = _draft!;
    final operation = _beginOperation(canCancel: true);
    try {
      final recipe = _recipe();
      final value = await awaitCancellable(
        service.suggestCropAutoAdjustments(
          project,
          asset,
          recipe.geometry,
          quarterTurns: draft.adjustments.quarterTurns,
          cancellation: _operationCancellation,
        ),
        cancellation: _operationCancellation,
      );
      if (!mounted || operation != _operationGeneration) return;
      _change(draft.withAdjustments(value));
      showMessage(
        context,
        'طُبّق اقتراح تحسين محلي قابل للتعديل؛ راجع النتيجة قبل الحفظ.',
      );
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        setState(() => _error = userError(error));
      }
    } finally {
      _finishOperation(operation);
    }
  }

  Future<void> _suggest() async {
    final editor = _editor;
    final source = _source!;
    final draft = _draft!;
    final operation = _beginOperation(canCancel: true);
    try {
      final List<Point2>? points;
      if (editor is BoundaryProposalImageEditor) {
        points =
            (await editor.suggestProposal(
              source.preview,
              cancellation: _operationCancellation,
            ))?.corners;
      } else {
        points = await editor.suggest(source.preview);
      }
      if (!mounted || operation != _operationGeneration) return;
      if (points == null) {
        setState(() {
          _proposalNotice =
              'لا يتوفر اقتراح تلقائي في هذا الإصدار؛ بقي الإطار الحالي كما هو. حرّك الزوايا يدوياً عند الحاجة.';
        });
        showMessage(
          context,
          'لا يتوفر كشف تلقائي في هذا الإصدار؛ لم يتغير الإطار الحالي.',
        );
      } else if (!_usableSuggestedCorners(
        points,
        sourceWidth: source.width,
        sourceHeight: source.height,
      )) {
        setState(() {
          _proposalNotice =
              'الاقتراح لا يحتوي على أربع زوايا صالحة؛ بقي الإطار الحالي كما هو.';
        });
        showMessage(context, 'الاقتراح غير صالح؛ احتُفظ بالحدود الحالية.');
      } else {
        _change(
          CropDraft(
            corners: points,
            adjustments: draft.adjustments,
            aspectRatio: draft.aspectRatio,
          ),
        );
        setState(() {
          _proposalNotice =
              'اقتراح جديد للمراجعة فقط؛ لم يتغير الأصل. تراجع يعيد الحدود السابقة، واعرض المعاينة قبل الحفظ.';
        });
        showMessage(
          context,
          'اقتراح للمراجعة فقط؛ تراجع يستعيد الحدود السابقة. عاين النتيجة قبل الحفظ.',
        );
      }
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        setState(() {
          _error = userError(error);
          _proposalNotice =
              'تعذر تحديث الاقتراح؛ بقيت الحدود الحالية ولم يتغير الأصل.';
        });
      }
    } finally {
      _finishOperation(operation);
    }
  }

  Future<void> _render() async {
    final asset = widget.asset;
    final operation = _beginOperation(canCancel: true);
    final draftRevision = _draftRevision;
    try {
      final recipe = _recipe();
      final bytes = await awaitCancellable(
        _editor.preview(asset, recipe, cancellation: _operationCancellation),
        cancellation: _operationCancellation,
      );
      if (!mounted ||
          operation != _operationGeneration ||
          draftRevision != _draftRevision) {
        return;
      }
      final previewBytes = Uint8List.fromList(bytes);
      final validPreview =
          previewBytes.isNotEmpty &&
          await _hasDecodablePreview(
            previewBytes,
            cancellation: _operationCancellation,
          );
      if (!mounted ||
          operation != _operationGeneration ||
          draftRevision != _draftRevision) {
        return;
      }
      if (!validPreview) {
        throw const ValidationException(
          'معاينة القص غير صالحة؛ لم يُسمح بالاعتماد.',
        );
      }
      setState(() {
        _preview = previewBytes;
        _previewRecipe = recipe;
        _previewRevision = draftRevision;
        _showResult = true;
        _error = null;
      });
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        setState(() => _error = userError(error));
      }
    } finally {
      _finishOperation(operation);
    }
  }

  Future<void> _accept() async {
    final preview = _preview;
    final recipe = _previewRecipe;
    final source = _source;
    if (preview == null ||
        recipe == null ||
        source == null ||
        !_hasCurrentPreview) {
      return;
    }
    final service = widget.service;
    final project = widget.project;
    final asset = widget.asset;
    final targetItemId = widget.targetItemId;
    final confirmForSheet = widget.confirmForSheet;
    final extractDerived = widget.extractDerived;
    final selectedKind = _selectedKind;
    final initialKind = _initialKind;
    final initialWidthText = _initialWidthText;
    final initialHeightText = _initialHeightText;
    final operation = _beginOperation(canCancel: false);
    try {
      final kindOrSizeChanged =
          (selectedKind != initialKind &&
              selectedKind != DocumentKind.unknown) ||
          (selectedKind == DocumentKind.other &&
              (_state!.customWidthText != initialWidthText ||
                  _state!.customHeightText != initialHeightText));
      final Project saved;
      if (extractDerived) {
        saved = await service.extractManualDerivedDocument(
          project,
          asset,
          recipe,
          documentKind: selectedKind,
          customSizeMm: _parseCustomSize(),
          sourceWidth: source.width,
          sourceHeight: source.height,
        );
      } else if (confirmForSheet || kindOrSizeChanged) {
        saved = await service.confirmManualBoundary(
          project,
          asset,
          recipe,
          documentKind: selectedKind,
          customSizeMm: _parseCustomSize(),
          targetItemId: targetItemId,
          sourceWidth: source.width,
          sourceHeight: source.height,
        );
      } else {
        saved = await service.applyManualCrop(
          project,
          asset,
          recipe,
          sourceWidth: source.width,
          sourceHeight: source.height,
        );
      }
      if (!mounted || operation != _operationGeneration) return;
      Navigator.pop(context, saved);
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        setState(() {
          _error = userError(error);
          _busy = false;
          _busyCancelable = false;
        });
      }
    }
  }

  Future<void> _leave() async {
    if (_busy) {
      if (!_cancelCancelableOperation()) return;
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
            tooltip: _busy
                ? (_busyCancelable
                      ? 'إلغاء العملية والخروج'
                      : 'انتظر انتهاء الحفظ')
                : 'إلغاء القص',
            onPressed: _busy && !_busyCancelable ? null : _leave,
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
                  if (_proposalNotice != null)
                    Padding(
                      key: const Key('crop-proposal-status'),
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _proposalNotice!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      key: const Key('crop-error'),
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
                                                _clearPreview();
                                                _dirty = true;
                                                _error = null;
                                                _proposalNotice = null;
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
                child: Text('مقاس مخصص (مم)', overflow: TextOverflow.ellipsis),
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
                    _clearPreview();
                    _dirty = true;
                    _proposalNotice = null;
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
                    _clearPreview();
                    _dirty = true;
                    _proposalNotice = null;
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
                    _clearPreview();
                    _dirty = true;
                    _proposalNotice = null;
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
                    _clearPreview();
                    _dirty = true;
                    _proposalNotice = null;
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
            onPressed: _busy || !_hasCurrentPreview ? null : _accept,
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
