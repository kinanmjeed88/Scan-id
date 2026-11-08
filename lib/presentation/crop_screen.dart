import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/cancellation.dart';
import '../application/contracts.dart';
import '../application/project_service.dart';
import '../domain/boundary_suggestion.dart';
import '../domain/crop_draft.dart';
import '../domain/document_kind.dart';
import '../domain/edit_history.dart';
import '../domain/geometry.dart';
import '../domain/image_adjustments.dart';
import '../domain/manual_boundary.dart';
import '../domain/manual_quad_selection.dart';
import '../domain/project.dart';
import '../domain/quad_assessment.dart';
import '../domain/validation.dart';
import '../imaging/prepare_image.dart';
import 'boundary_handle.dart';
import 'boundary_hit_layer.dart';
import 'crop_loupe.dart';
import 'shared.dart';
import 'shortcuts.dart';

/// Shown when a drag would make two opposite edges cross. The move is refused.
const _cornerCrossingMessage =
    'زوايا القص تتقاطع؛ أبقيت آخر موضع صالح للزاوية.';

/// New manual crop drafts start at the midpoint of the existing 0–1 sharpness
/// control. It is preview-only: the original stays unchanged until acceptance.
const initialManualCropSharpness = .5;

/// Taps closer than this many screen pixels to an already placed tap are
/// ignored. It only removes accidental double taps; it is not a detection rule.
const manualTapMinSeparationPx = 20.0;

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
    this.manualRequired = false,
  });

  final CropDraft draft;
  final DocumentKind selectedKind;
  final String customWidthText;
  final String customHeightText;

  /// Set while the frame is an unapproved full frame that has no detected
  /// boundary (detection failed or no candidate existed). Preview and accept
  /// stay blocked until four valid taps or a corner edit clears it. It is part
  /// of the history entry, so undo and redo restore it with the frame.
  final bool manualRequired;

  /// A valid boundary (a suggestion or four taps) lifts the fallback gate.
  _CropEditorState withBoundary(CropDraft boundary) {
    return copyWith(draft: boundary, manualRequired: false);
  }

  _CropEditorState copyWith({
    CropDraft? draft,
    DocumentKind? selectedKind,
    String? customWidthText,
    String? customHeightText,
    bool? manualRequired,
  }) => _CropEditorState(
    draft: draft ?? this.draft,
    selectedKind: selectedKind ?? this.selectedKind,
    customWidthText: customWidthText ?? this.customWidthText,
    customHeightText: customHeightText ?? this.customHeightText,
    manualRequired: manualRequired ?? this.manualRequired,
  );
}

/// The fallback instruction stays visible while the gate is set. Any other
/// state shows no fallback instruction.
String? _noticeFor(_CropEditorState state) {
  if (!state.manualRequired) return null;
  return manualFallbackNotice;
}

String _formatMillimeters(double value) {
  if ((value - value.roundToDouble()).abs() < 1e-6) {
    return value.toStringAsFixed(1);
  }
  final two = value.toStringAsFixed(2);
  return two.endsWith('0') ? two.substring(0, two.length - 1) : two;
}

class _SuggestedCornersResolution {
  const _SuggestedCornersResolution({this.corners, this.notice});

  final List<Point2>? corners;
  final String? notice;
}

const manualFallbackNotice =
    'الكشف التلقائي لم ينجح؛ انقر الزوايا الأربع يدوياً بأي ترتيب. '
    'المعاينة والاعتماد معطّلان حتى تكتمل الزوايا أو تُعدَّل إحداها.';

/// The fallback instruction, placed after the reason of a failed suggestion
/// when there is one, so the reason is not lost to the instruction.
String _fallbackNoticeWith(String? reason) {
  if (reason == null || reason.isEmpty) return manualFallbackNotice;
  if (reason.endsWith(manualFallbackNotice)) return reason;
  return '$reason $manualFallbackNotice';
}

bool _samePoints(List<Point2>? a, List<Point2>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].x != b[i].x || a[i].y != b[i].y) return false;
  }
  return true;
}

/// Single source of truth for the saved suggestion (see
/// [savedSuggestedBoundary] in the domain layer).
List<Point2>? _savedSuggestionFor(Project project, ImageAsset asset) =>
    savedSuggestedBoundary(project, asset);

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
  final _customWidthController = TextEditingController();
  final _customHeightController = TextEditingController();
  EditorSource? _source;
  EditHistory<_CropEditorState>? _history;
  _CropEditorState? _state;
  String? _coalescedCustomField;
  Uint8List? _preview;
  ImageEditRecipe? _previewRecipe;
  int _draftRevision = 0;
  int? _previewRevision;
  String? _error;

  /// Inline, field-scoped size error. A stale global error banner used to stay
  /// on screen even after the user switched to the preview tab.
  String? _sizeError;
  String? _proposalNotice;
  bool _busy = true;
  bool _busyCancelable = true;
  int _operationGeneration = 0;
  CancellationToken? _operationCancellation;
  bool _showResult = false;
  bool _dirty = false;

  /// Whether the fallback gate is set on the current state.
  bool get _manualRequired => _state?.manualRequired ?? false;
  bool _cornerDragMoved = false;
  // Non-null only while a corner or an edge is being dragged. The loupe reads
  // these directly; they carry no persistence or undo semantics.
  BoundaryHandle? _activeDragHandle;
  Offset? _dragLastLocal;
  Point2? _loupeFocus;
  // Non-null only while the user places corners by tapping. Partial taps are
  // not undo entries; the completed quadrilateral is one history entry.
  ManualQuadSelection? _tapSelection;
  // Keep the banner tied to suggestion history entries, not just the first
  // suggestion. User edits hide it; undo/redo can restore it accurately.
  final Set<CropDraft> _reviewDrafts = Set.identity();
  late DocumentKind _initialKind;
  late String _initialWidthText;
  late String _initialHeightText;
  bool _initialSizeWasUserAuthored = false;
  bool _sizeTextEdited = false;

  CropDraft? get _draft => _state?.draft;
  DocumentKind get _selectedKind => _state?.selectedKind ?? _initialKind;
  bool get _showingReviewProposal =>
      _draft != null && _reviewDrafts.contains(_draft);
  ImageEditor get _editor => widget.service.imageEditor!;

  @override
  void initState() {
    super.initState();
    _initializeInitialMetadata();
    unawaited(_load());
  }

  void _initializeInitialMetadata() {
    _initialSizeWasUserAuthored = false;
    _sizeTextEdited = false;
    var resolvedKind = widget.documentKind;
    var resolvedW = '';
    var resolvedH = '';
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
      _initialSizeWasUserAuthored = targetItem.hasUserConfirmedSize;
      if (targetItem.sizeConfirmed) {
        resolvedW = _formatMillimeters(targetItem.width);
        resolvedH = _formatMillimeters(targetItem.height);
      }
    }
    // An editable ESTIMATE is still a real catalog size. Showing it in the
    // fields (instead of blank boxes) is the difference between "change it if
    // you measured something else" and "you may not continue until you type a
    // number". A kind with no catalog size legitimately has nothing to show.
    if (resolvedW.isEmpty || resolvedH.isEmpty) {
      final natural = widget.project.catalog.natural(resolvedKind);
      if (natural != null) {
        final oriented = natural.oriented(landscape: _initialLandscape());
        resolvedW = _formatMillimeters(oriented.width);
        resolvedH = _formatMillimeters(oriented.height);
      }
    }
    _initialKind = resolvedKind;
    _initialWidthText = resolvedW;
    _initialHeightText = resolvedH;
    _customWidthController.text = resolvedW;
    _customHeightController.text = resolvedH;
  }

  /// Orientation of the source as shown before the editor opens.
  bool _initialLandscape() {
    final turned = widget.asset.adjustments.quarterTurns.isOdd;
    final width = turned ? widget.asset.height : widget.asset.width;
    final height = turned ? widget.asset.width : widget.asset.height;
    return width >= height;
  }

  /// Catalog size turned to the current crop orientation, or null when the
  /// category has no documented/estimated size at all.
  PhysicalSizeMm? _catalogSize(DocumentKind kind) {
    final natural = widget.project.catalog.natural(kind);
    if (natural == null) return null;
    return natural.oriented(
      landscape: _source == null ? _initialLandscape() : _draftLandscape,
    );
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
    _sizeError = null;
    _proposalNotice = null;
    _clearDragState();
    _busy = true;
    _busyCancelable = true;
    _dirty = false;
    _reviewDrafts.clear();
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
      // A stored full frame from an adjustment is not a saved crop (F-K).
      final crop = extractDerived || !asset.hasApprovedCrop ? null : asset.crop;
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
          ? _resolveSuggestedCorners(
              source.width,
              source.height,
              project: project,
              asset: asset,
            )
          : const _SuggestedCornersResolution();
      if (!_isCurrentOperation(operation)) return;
      final proposed = resolution.corners;
      // The untouched full frame is never an approved boundary (C1/C3). It is
      // gated until four valid taps, a valid suggestion, or a corner edit. A
      // saved crop and an explicit extraction keep their own paths.
      final gateBase = crop == null && !extractDerived;
      final needsManual = gateBase && proposed == null;
      var notice = resolution.notice;
      if (needsManual) {
        notice = '${resolution.notice ?? ''} $manualFallbackNotice'.trim();
      }
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
          manualRequired: gateBase,
        );
        history = EditHistory(baseState);
        if (proposed != null) {
          final proposedDraft = CropDraft(
            corners: proposed,
            adjustments: baseFull.adjustments,
            aspectRatio: initialAspect,
          );
          activeState = baseState.withBoundary(proposedDraft);
          history.record(activeState);
        } else {
          activeState = baseState;
        }
      }
      setState(() {
        _source = source;
        _history = history;
        _state = activeState;
        _sizeError = null;
        _clearDragState();
        _reviewDrafts.clear();
        if (proposed != null) _rememberReviewDraft(activeState.draft);
        _tapSelection = null;
        _proposalNotice = notice;
        _busy = false;
        _busyCancelable = false;
      });
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        // Do not log image content or filesystem paths.
        developer.log(
          'Failed to open crop source: ${error.runtimeType}',
          name: 'scan_id.crop',
        );
        setState(() {
          _error = 'تعذر فتح الصورة للقص. ${userError(error)}';
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

  // Show the saved suggestion immediately. Running two native models again
  // here used to delay (or block) the entire manual editor even though the
  // source was already open. A fresh suggestion is available via its button.
  _SuggestedCornersResolution _resolveSuggestedCorners(
    int sourceWidth,
    int sourceHeight, {
    required Project project,
    required ImageAsset asset,
  }) {
    final candidate =
        widget.suggestedCorners ?? _savedSuggestionFor(project, asset);
    if (candidate == null) return const _SuggestedCornersResolution();
    if (_usableSuggestedCorners(
      candidate,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    )) {
      return _SuggestedCornersResolution(
        corners: candidate,
        notice: 'الحدود المحفوظة اقتراح للمراجعة؛ عدّلها وعاين القص قبل الحفظ.',
      );
    }
    return const _SuggestedCornersResolution(
      notice: 'الحدود المحفوظة غير صالحة؛ عُرضت الصورة كاملة لضبطها يدوياً.',
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
    _clearDragState();
    _sizeError = null;
    _history!.record(next);
    _syncControllerText(_customWidthController, next.customWidthText);
    _syncControllerText(_customHeightController, next.customHeightText);
    setState(() {
      _state = next;
      _tapSelection = null;
      _clearPreview();
      _dirty = true;
      _error = null;
      _proposalNotice = _noticeFor(next);
    });
  }

  /// Commits a new draft. [clearManualRequired] is set only by a valid
  /// boundary (a suggestion, four taps, or a corner drag that ended without
  /// crossing edges); every other change keeps the gate.
  void _change(CropDraft next, {bool clearManualRequired = false}) {
    final current = _state!;
    final manual = clearManualRequired ? false : current.manualRequired;
    _commitState(current.copyWith(draft: next, manualRequired: manual));
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
    _sizeTextEdited = true;
    _sizeError = null;
    final nextW = isWidth ? value : current.customWidthText;
    final nextH = isWidth ? current.customHeightText : value;
    final ratio = _requiresManualSize(current.selectedKind)
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
      _tapSelection = null;
      _clearPreview();
      _dirty = true;
      _error = null;
      _proposalNotice = _noticeFor(next);
    });
  }

  void _undo(bool redo) {
    _coalescedCustomField = null;
    final next = redo ? _history!.redo() : _history!.undo();
    _syncControllerText(_customWidthController, next.customWidthText);
    _syncControllerText(_customHeightController, next.customHeightText);
    setState(() {
      _state = next;
      _tapSelection = null;
      _clearPreview();
      _dirty = true;
      _error = null;
      _proposalNotice = _noticeFor(next);
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

  bool _requiresManualSize(DocumentKind kind) =>
      kind != DocumentKind.unknown &&
      (widget.project.catalog.natural(kind) == null ||
          presetStatusFor(kind) == PresetStatus.estimated);

  /// The physical size to confirm, or null to let the service use the catalog
  /// default oriented to the ACTUAL rendered crop.
  ///
  /// Empty fields are not an error and never block saving: the fields are
  /// prefilled from the catalog (including editable estimates), so leaving
  /// them alone is an explicit acceptance of that default. A kind with no
  /// catalog size and no typed measurement simply keeps its footprint
  /// unconfirmed and stays off A4 until measured. Only malformed or partial
  /// input is refused, with a precise inline message.
  PhysicalSizeMm? _resolvePrintSize() {
    if (!_requiresManualSize(_selectedKind)) return null;
    final widthText = _state!.customWidthText.trim();
    final heightText = _state!.customHeightText.trim();
    if (widthText.isEmpty && heightText.isEmpty) return null;
    double? parse(String text) => double.tryParse(text.replaceAll(',', '.'));
    final w = parse(widthText);
    final h = parse(heightText);
    final defaultSize = _catalogSize(_selectedKind);
    if (defaultSize != null) {
      // One measured dimension is enough: derive the other from the catalog
      // proportion rather than refusing to save.
      if (w != null && w.isFinite && heightText.isEmpty) {
        return validDocumentSize(
          PhysicalSizeMm(w, w * defaultSize.height / defaultSize.width),
        );
      }
      if (h != null && h.isFinite && widthText.isEmpty) {
        return validDocumentSize(
          PhysicalSizeMm(h * defaultSize.width / defaultSize.height, h),
        );
      }
    }
    if (w == null || h == null || !w.isFinite || !h.isFinite) {
      throw const ValidationException(
        'أدخل العرض والارتفاع بالمليمتر بأرقام صحيحة، أو اتركهما فارغين '
        'لاستخدام المقاس الافتراضي.',
      );
    }
    return validDocumentSize(PhysicalSizeMm(w, h));
  }

  void _selectDocumentKind(DocumentKind? kind) {
    if (kind == null || kind == _selectedKind) return;
    final current = _state!;
    final natural = widget.project.catalog.natural(kind);
    // Switching category fills the fields with THAT category's catalog size;
    // a measurement the user actually typed is always preserved.
    final keepUserSize = _sizeTextEdited || _initialSizeWasUserAuthored;
    final widthText = keepUserSize
        ? current.customWidthText
        : _formatMillimeters(_catalogSize(kind)?.width ?? 0);
    final heightText = keepUserSize
        ? current.customHeightText
        : _formatMillimeters(_catalogSize(kind)?.height ?? 0);
    final hasDefaultSize = _catalogSize(kind) != null;
    final double? nextRatio;
    if (natural != null && !_requiresManualSize(kind)) {
      final oriented = natural.oriented(landscape: _draftLandscape);
      nextRatio = oriented.width / oriented.height;
    } else if (_requiresManualSize(kind) && _sizeTextEdited) {
      // Only a MEASUREMENT the user typed may reshape the warp. A prefilled
      // catalog default sizes the A4 slot; it never stretches the pixels.
      nextRatio =
          _tryParseCustomRatio(widthText, heightText) ?? _draft!.aspectRatio;
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
    _commitState(
      current.copyWith(
        draft: nextDraft,
        selectedKind: kind,
        customWidthText: hasDefaultSize || keepUserSize ? widthText : '',
        customHeightText: hasDefaultSize || keepUserSize ? heightText : '',
      ),
    );
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
      // Adjustment sliders alone are not visible feedback on the source
      // image. Render and open the corrected result in the same action so the
      // user can actually compare it, adjust it, or undo it before saving.
      await _render();
      if (mounted && _hasCurrentPreview) {
        showMessage(context, 'عُرضت نتيجة التحسين؛ عدّلها أو تراجع قبل الحفظ.');
      }
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        setState(() => _error = userError(error));
      }
    } finally {
      _finishOperation(operation);
    }
  }

  void _rememberReviewDraft(CropDraft draft) {
    // Match the history's capacity so repeated refreshes stay bounded.
    if (_reviewDrafts.length >= 50) _reviewDrafts.remove(_reviewDrafts.first);
    _reviewDrafts.add(draft);
  }

  Future<void> _suggest() async {
    final editor = _editor;
    final source = _source!;
    final draft = _draft!;
    final startState = _state;
    final operation = _beginOperation(canCancel: true);
    try {
      final List<Point2>? points;
      if (editor is BoundaryProposalImageEditor) {
        points = (await editor.suggestProposal(
          source.preview,
          cancellation: _operationCancellation,
        ))?.corners;
      } else {
        points = await editor.suggest(source.preview);
      }
      if (!mounted || operation != _operationGeneration) return;
      if (!identical(_state, startState)) {
        // The frame changed while detection ran. Applying the old result would
        // overwrite a user edit, so it is discarded.
        setState(() {
          _proposalNotice =
              'تغيّر الإطار أثناء الكشف؛ لم يُطبَّق الاقتراح القديم.';
        });
        return;
      }
      final usablePoints = _usableSuggestedCorners(
        points,
        sourceWidth: source.width,
        sourceHeight: source.height,
      );
      if (points == null) {
        setState(() {
          _proposalNotice =
              'لم يجد الكشف حدوداً مدعومة بالحواف في هذه الصورة؛ بقي الإطار الحالي كما هو. حرّك الزوايا أو الأضلاع يدوياً عند الحاجة.';
        });
        showMessage(
          context,
          'لم يُعثر على حدود مدعومة بالحواف؛ لم يتغير الإطار الحالي.',
        );
      } else if (!usablePoints) {
        setState(() {
          _proposalNotice =
              'الاقتراح لا يحتوي على أربع زوايا صالحة؛ بقي الإطار الحالي كما هو.';
        });
        showMessage(context, 'الاقتراح غير صالح؛ احتُفظ بالحدود الحالية.');
      } else {
        final suggested = CropDraft(
          corners: points,
          adjustments: draft.adjustments,
          aspectRatio: draft.aspectRatio,
        );
        _change(suggested, clearManualRequired: true);
        _rememberReviewDraft(suggested);
        setState(() {
          _proposalNotice =
              'اقتراح جديد للمراجعة فقط؛ لم يتغير الأصل. تراجع يعيد الحدود السابقة، واعرض المعاينة قبل الحفظ.';
        });
        showMessage(
          context,
          'اقتراح للمراجعة فقط؛ تراجع يستعيد الحدود السابقة. عاين النتيجة قبل الحفظ.',
        );
      }
      if (!usablePoints) _enterManualFallback();
    } catch (error) {
      if (_isCurrentOperation(operation)) {
        setState(() {
          _error = userError(error);
          _proposalNotice =
              'تعذر تحديث الاقتراح؛ بقيت الحدود الحالية ولم يتغير الأصل.';
        });
        _enterManualFallback();
      }
    } finally {
      _finishOperation(operation);
    }
  }

  /// Auto-to-manual fallback. A failed detection on an untouched full frame
  /// moves the user to four taps. Preview and accept stay blocked until four
  /// taps or a corner edit, so the full frame is never accepted as a detected
  /// crop. A user's own corners are never replaced by this fallback.
  void _enterManualFallback() {
    final current = _state;
    if (current == null) return;
    if (!_samePoints(current.draft.corners, CropDraft.fullImage().corners)) {
      return;
    }
    // Already gated (no candidate at load): keep the entry and re-enter tap
    // mode with the instruction, so a failed suggestion is never silent.
    // Otherwise replace the current entry rather than adding one, so undo
    // cannot return to an ungated full frame.
    final gated = current.manualRequired
        ? current
        : current.copyWith(manualRequired: true);
    if (!identical(gated, current)) _history!.replaceCurrent(gated);
    setState(() {
      _state = gated;
      _tapSelection = ManualQuadSelection.empty();
      _clearPreview();
      _proposalNotice = _fallbackNoticeWith(_proposalNotice);
    });
  }

  Future<void> _render() async {
    if (_manualRequired) return;
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
        _manualRequired ||
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
    // Field-level validation happens before the operation starts, so a size
    // mistake is reported next to its fields instead of leaving a red banner
    // behind on the preview tab.
    final PhysicalSizeMm? size;
    try {
      size = _resolvePrintSize();
    } on ValidationException catch (error) {
      setState(() {
        _sizeError = error.message;
        _busy = false;
        _busyCancelable = false;
      });
      return;
    }
    _sizeError = null;
    final operation = _beginOperation(canCancel: false);
    try {
      final kindOrSizeChanged =
          (selectedKind != initialKind &&
              selectedKind != DocumentKind.unknown) ||
          (_requiresManualSize(selectedKind) &&
              (_state!.customWidthText != initialWidthText ||
                  _state!.customHeightText != initialHeightText));
      // A selected category is confirmed even when its physical size is not
      // resolvable yet; the service then keeps the item off A4. Only "unknown"
      // with no size takes the plain crop path (no kind to record).
      final confirmPath =
          (confirmForSheet || kindOrSizeChanged) &&
          (selectedKind != DocumentKind.unknown || size != null);
      final Project saved;
      if (extractDerived) {
        saved = await service.extractManualDerivedDocument(
          project,
          asset,
          recipe,
          documentKind: selectedKind,
          customSizeMm: size,
          sourceWidth: source.width,
          sourceHeight: source.height,
        );
      } else if (confirmPath) {
        saved = await service.confirmManualBoundary(
          project,
          asset,
          recipe,
          documentKind: selectedKind,
          customSizeMm: size,
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
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error ?? 'تعذر فتح الصورة.'),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              key: const Key('crop-retry-open'),
                              onPressed: () {
                                setState(() {
                                  _error = null;
                                  _busy = true;
                                });
                                unawaited(_load());
                              },
                              icon: const Icon(Icons.refresh),
                              label: const Text('إعادة فتح الصورة'),
                            ),
                          ],
                        ),
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
                        // The canvas stays mounted and fixed. A lazy list
                        // culled it once the tools were scrolled into view,
                        // which lost the canvas context, the selection, and
                        // the corner finders. Only the tools scroll (F-N).
                        final preferred = math.max(
                          240.0,
                          math.min(440.0, constraints.maxHeight * .52),
                        );
                        return Column(
                          children: [
                            SizedBox(
                              height: math.min(
                                preferred,
                                constraints.maxHeight,
                              ),
                              child: _imageArea(),
                            ),
                            Expanded(
                              child: SingleChildScrollView(child: _tools()),
                            ),
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
                  setState(() {
                    _error = null;
                    _showResult = values.single;
                  });
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
                      final availableWidth = math.max(
                        1.0,
                        box.maxWidth - boundaryCanvasInsetPx * 2,
                      );
                      final availableHeight = math.max(
                        1.0,
                        box.maxHeight - boundaryCanvasInsetPx * 2,
                      );
                      final width = math.min(
                        availableWidth,
                        availableHeight * ratio,
                      );
                      final height = width / ratio;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: Center(
                              child: InteractiveViewer(
                                transformationController: _view,
                                minScale: 1,
                                maxScale: 5,
                                clipBehavior: Clip.none,
                                child: SizedBox(
                                  // The hit-test box includes the entire corner handles,
                                  // not just the image. Clip.none alone only expands paint.
                                  width: width + boundaryCanvasInsetPx * 2,
                                  height: height + boundaryCanvasInsetPx * 2,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Positioned(
                                        left: boundaryCanvasInsetPx,
                                        top: boundaryCanvasInsetPx,
                                        width: width,
                                        height: height,
                                        child: SizedBox(
                                          key: _canvasKey,
                                          child: Stack(
                                            children: [
                                              Positioned.fill(
                                                child: Image.memory(
                                                  _source!.preview,
                                                  key: const Key(
                                                    'crop-source-image',
                                                  ),
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
                                      ..._tapLayer(width, height),
                                      ..._cornerHandles(width, height),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_activeDragHandle != null &&
                              _loupeFocus != null &&
                              _source != null)
                            Positioned.fill(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Align(
                                  key: const Key('crop-loupe-alignment'),
                                  alignment: cropLoupeAlignment(_loupeFocus!),
                                  child: IgnorePointer(
                                    child: ValueListenableBuilder<Matrix4>(
                                      valueListenable: _view,
                                      builder: (context, matrix, _) =>
                                          CropPrecisionLoupe(
                                            key: const Key(
                                              'crop-precision-loupe',
                                            ),
                                            preview: _source!.preview,
                                            corners: _draft!.corners,
                                            focus: _loupeFocus!,
                                            canvasSize: Size(width, height),
                                            zoom: matrix.getMaxScaleOnAxis(),
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
      ),
    ],
  );

  void _toggleTapMode() {
    setState(() {
      _error = null;
      _tapSelection = _tapSelection == null
          ? ManualQuadSelection.empty()
          : null;
    });
  }

  void _tapCanvas(Offset global, double width, double height) {
    final render = _canvasKey.currentContext!.findRenderObject()! as RenderBox;
    final local = render.globalToLocal(global);
    _addManualTap(
      Point2(
        (local.dx / width).clamp(0, 1).toDouble(),
        (local.dy / height).clamp(0, 1).toDouble(),
      ),
      minSeparation: manualTapMinSeparationPx / width,
    );
  }

  /// Adds one tap. Completing four valid taps commits one history entry.
  /// An unsafe completed quadrilateral is rejected and the selection restarts.
  void _addManualTap(Point2 tap, {required double minSeparation}) {
    final selection = _tapSelection;
    if (selection == null) return;
    ManualQuadSelection next;
    try {
      next = selection.addTap(tap, minSeparation: minSeparation);
    } catch (error) {
      setState(() => _error = userError(error));
      return;
    }
    if (!next.isComplete) {
      setState(() {
        _tapSelection = next;
        _error = null;
      });
      return;
    }
    List<Point2> corners;
    try {
      corners = next.completedCorners();
    } catch (error) {
      setState(() {
        _tapSelection = ManualQuadSelection.empty();
        _error = userError(error);
      });
      return;
    }
    final draft = _draft!;
    _change(
      CropDraft(
        corners: corners,
        adjustments: draft.adjustments,
        aspectRatio: draft.aspectRatio,
      ),
      clearManualRequired: true,
    );
  }

  void _moveHandle(
    BoundaryHandle handle,
    Offset global,
    double width,
    double height,
  ) {
    final render = _canvasKey.currentContext!.findRenderObject()! as RenderBox;
    final local = render.globalToLocal(global);
    final focus = Point2(
      (local.dx / width).clamp(0.0, 1.0),
      (local.dy / height).clamp(0.0, 1.0),
    );
    final current = _draft!;
    final List<Point2> nextCorners;
    if (handle is CornerHandle) {
      final next = current.withCorner(handle.index, focus);
      nextCorners = [...next.corners];
    } else {
      // An EDGE drag moves both of its endpoints by the same incremental
      // delta, preserving the edge's direction and length. The first update
      // only records the anchor, which also makes a stationary press on the
      // line harmless.
      final last = _dragLastLocal;
      if (last == null) {
        _dragLastLocal = local;
        return;
      }
      final dx = (local.dx - last.dx) / width;
      final dy = (local.dy - last.dy) / height;
      // Advance the anchor even when the resulting quad is refused, so a
      // blocked step never accumulates into a jump on the next update.
      _dragLastLocal = local;
      if (dx == 0 && dy == 0) return;
      final ends = edgeCorners(handle.index);
      final corners = [...current.corners];
      for (final index in [ends.first, ends.second]) {
        final point = corners[index];
        corners[index] = Point2(
          (point.x + dx).clamp(0.0, 1.0),
          (point.y + dy).clamp(0.0, 1.0),
        );
      }
      nextCorners = corners;
    }
    final next = CropDraft(
      corners: nextCorners,
      adjustments: current.adjustments,
      aspectRatio: current.aspectRatio,
    );
    if (quadEdgesCross(next.corners)) {
      // Drag-time gate (UI only): the boundary stays at its last valid shape.
      if (_error != _cornerCrossingMessage) {
        setState(() => _error = _cornerCrossingMessage);
      }
      return;
    }
    _cornerDragMoved = true;
    // The fallback gate and the status line stay as they are during the
    // gesture; the drag end lifts the gate (see _endHandleDrag).
    setState(() {
      _coalescedCustomField = null;
      _state = _state!.copyWith(draft: next);
      _loupeFocus = focus;
      _clearPreview();
      _dirty = true;
      _error = null;
    });
  }

  void _clearDragState() {
    _activeDragHandle = null;
    _dragLastLocal = null;
    _loupeFocus = null;
  }

  void _endHandleDrag() {
    final moved = _cornerDragMoved;
    _clearDragState();
    if (!moved) return;
    // Commit only when the boundary really moved: a fully refused drag must
    // not add an undo step.
    final keepNotice = _error == _cornerCrossingMessage;
    _change(_draft!, clearManualRequired: true);
    if (keepNotice) setState(() => _error = _cornerCrossingMessage);
  }

  void _cancelHandleDrag() {
    _clearDragState();
    setState(() {
      _coalescedCustomField = null;
      _state = _history!.current;
    });
  }

  /// Tap-mode layer: a surface that receives taps, plus markers for the taps
  /// placed so far. Outside tap mode it contributes nothing.
  List<Widget> _tapLayer(double width, double height) {
    final selection = _tapSelection;
    if (selection == null) return const [];
    return [
      Positioned(
        left: boundaryCanvasInsetPx,
        top: boundaryCanvasInsetPx,
        width: width,
        height: height,
        child: GestureDetector(
          key: const Key('crop-tap-surface'),
          behavior: HitTestBehavior.opaque,
          onTapUp: _busy
              ? null
              : (details) {
                  _tapCanvas(details.globalPosition, width, height);
                },
          child: const SizedBox.expand(),
        ),
      ),
      for (var i = 0; i < selection.points.length; i++)
        Positioned(
          left:
              boundaryCanvasInsetPx + selection.points[i].x * width - 12.0,
          top:
              boundaryCanvasInsetPx + selection.points[i].y * height - 12.0,
          child: _ScreenFixedSize(controller: _view, child: _tapMarker(i)),
        ),
    ];
  }

  /// The four draggable corners. Hidden in tap mode, where no corner exists
  /// until the fourth tap completes the quadrilateral.
  ///
  /// P6: the corners are visual only (IgnorePointer). Hits come from ONE
  /// geometric layer placed last, which selects the nearest corner inside a
  /// 32 px screen radius, otherwise the nearest edge inside an 18 px band,
  /// and lets the viewer pan everywhere else.
  List<Widget> _cornerHandles(double width, double height) {
    if (_tapSelection != null) return const [];
    final corners = _draft!.corners;
    return [
      for (var i = 0; i < 4; i++)
        Positioned(
          left: boundaryCanvasInsetPx + corners[i].x * width - 20,
          top: boundaryCanvasInsetPx + corners[i].y * height - 20,
          child: _ScreenFixedSize(
            controller: _view,
            child: IgnorePointer(child: _cornerVisual(i)),
          ),
        ),
      Positioned.fill(
        child: BoundaryHitLayer(
          corners: corners,
          canvasSize: Size(width, height),
          inset: boundaryCanvasInsetPx,
          zoom: () => _view.value.getMaxScaleOnAxis(),
          onDragStart: (handle) {
            _cornerDragMoved = false;
            _activeDragHandle = handle;
            _dragLastLocal = null;
            _loupeFocus = null;
          },
          onDragUpdate: (handle, global) {
            if (_busy) return;
            _moveHandle(handle, global, width, height);
          },
          onDragEnd: (_) {
            if (_busy) return;
            _endHandleDrag();
          },
          onDragCancel: (_) {
            if (_busy) return;
            _cornerDragMoved = false;
            _cancelHandleDrag();
          },
        ),
      ),
    ];
  }

  /// Visual of one corner. Its centre sits on the corner; the wrapper keeps the
  /// visible size constant under zoom. Input is handled by the hit layer.
  Widget _cornerVisual(int i) {
    return Semantics(
      label: 'زاوية القص ${i + 1}',
      child: Container(
        key: Key('crop-corner-$i'),
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xff12685e),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Text(
          '${i + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _tapMarker(int i) {
    return Container(
      key: Key('crop-tap-$i'),
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xff12685e),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Text(
        '${i + 1}',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _tools() {
    final adjustments = _draft!.adjustments;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'حرّك الزوايا أو اسحب أي ضلع لتحريكه كاملاً. تظهر دائرة مكبّرة '
            'أثناء السحب لضبط الحد بدقة. كبّر الصورة بإصبعين أو بعجلة '
            'الفأرة. لا يتغير الأصل.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _suggest,
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('اقتراح حدود المستمسك'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('crop-auto-adjust'),
            onPressed: _busy || _manualRequired ? null : _autoAdjust,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('تحسين الصورة تلقائياً'),
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
          OutlinedButton.icon(
            key: const Key('crop-tap-mode'),
            onPressed: _busy ? null : _toggleTapMode,
            icon: const Icon(Icons.touch_app_outlined),
            label: Text(
              _tapSelection == null
                  ? 'تحديد الزوايا بالنقر'
                  : 'إلغاء التحديد بالنقر',
            ),
          ),
          if (_tapSelection != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'انقر الزوايا الأربع بأي ترتيب (${_tapSelection!.points.length}/4)؛ تُرتَّب تلقائيا.',
              ),
            ),
          const SizedBox(height: 12),
          const Text('نوع المستمسك'),
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
                DocumentKind.civilStatusId,
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
          if (_selectedKind == DocumentKind.civilStatusId ||
              presetStatusFor(_selectedKind) == PresetStatus.estimated)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _selectedKind.sizeNote(widget.project.catalog),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_requiresManualSize(_selectedKind)) ...[
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
            if (_sizeError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _sizeError!,
                  key: const Key('crop-size-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
          // A selected category already owns the output aspect ratio (from its
          // catalog size or the measurement fields above). Showing a second
          // shape selector duplicated that decision and allowed contradictory
          // values. Freeform shape selection remains available only without a
          // selected category.
          if (_selectedKind == DocumentKind.unknown) ...[
            const SizedBox(height: 12),
            const Text('شكل القص (اختياري)'),
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
          ],
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
                    _proposalNotice = _noticeFor(_state!);
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
                    _proposalNotice = _noticeFor(_state!);
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
                    _proposalNotice = _noticeFor(_state!);
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
                    _proposalNotice = _noticeFor(_state!);
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
                      // Restoring the full frame is an unapproved state, the
                      // same as Undo to the starting frame (C1). It needs four
                      // taps, a valid suggestion, or a corner edit before Preview.
                      manualRequired: true,
                    ),
                  ),
            child: const Text('إعادة ضبط إلى الأصل'),
          ),
          if (!widget.extractDerived &&
              widget.asset.hasApprovedCrop &&
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
            onPressed: _busy || _manualRequired ? null : _render,
            child: const Text('معاينة التصحيح'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('accept-crop'),
            onPressed: _busy || _manualRequired || !_hasCurrentPreview
                ? null
                : _accept,
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
    // A wide translucent band makes it clear that the WHOLE edge is draggable,
    // not just the four numbered circles.
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff12685e).withValues(alpha: .18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12,
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

/// Keeps its child at a constant on-screen size inside an [InteractiveViewer]
/// by cancelling the viewer's current scale around the child's centre.
class _ScreenFixedSize extends StatelessWidget {
  const _ScreenFixedSize({required this.controller, required this.child});

  final TransformationController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, matrix, child) {
        return Transform.scale(
          scale: 1 / math.max(1, matrix.getMaxScaleOnAxis()),
          child: child,
        );
      },
      child: child,
    );
  }
}
