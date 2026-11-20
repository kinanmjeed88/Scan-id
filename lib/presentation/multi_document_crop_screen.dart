import 'dart:async';

import 'package:flutter/material.dart';

import '../application/contracts.dart';
import '../application/intake_stage_log.dart';
import '../domain/image_journey.dart';
import '../domain/intake_options.dart';
import '../application/project_service.dart';
import '../domain/crop_draft.dart';
import '../domain/document_kind.dart';
import '../domain/geometry.dart';
import '../domain/image_adjustments.dart';
import '../domain/manual_document_selection.dart';
import '../domain/project.dart';
import '../domain/recognition.dart';
import '../domain/validation.dart';
import 'crop_boundary_canvas.dart';
import 'crop_screen.dart' show initialManualCropSharpness;
import 'side_partner_field.dart';
import '../domain/manual_classification.dart';
import '../application/ids.dart';
import 'shared.dart';

/// Outlines several documents in ONE photograph and adds each as its own
/// document.
///
/// This is the manual counterpart to the (disabled) automatic segmenter: nothing
/// here guesses where a document is. The person sees the whole original
/// photograph, taps four corners per document, and every tap is stored as a
/// normalized point on the ORIGINAL image, so zoom and pan cannot move what they
/// picked.
///
/// Each selection is cropped through `ProjectService.extractManualDerivedDocument`,
/// the same call the single-document extract path uses. That path validates the
/// quadrilateral, rectifies perspective, resolves centring and physical size,
/// imports the derived asset and saves the project. This screen adds no storage
/// of its own and changes no other option's behaviour.
class MultiDocumentCropScreen extends StatefulWidget {
  const MultiDocumentCropScreen({
    required this.project,
    required this.asset,
    required this.service,
    this.options,
    this.stageLog,
    super.key,
  });

  final IntakeOptions? options;
  final IntakeBatchLog? stageLog;
  final Project project;
  final ImageAsset asset;
  final ProjectService service;

  @override
  State<MultiDocumentCropScreen> createState() =>
      _MultiDocumentCropScreenState();
}

class _MultiDocumentCropScreenState extends State<MultiDocumentCropScreen> {
  Project? _saved;
  EditorSource? _source;
  ManualSelectionSet _set = ManualSelectionSet.empty();
  String? _activeId;
  int _nextId = 0;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _notice;

  final _view = TransformationController();
  ManualDocumentSelection? _beforeDrag;
  // UI row IDs survive edits; reserve actual layout IDs so that pairing a
  // pending face needs neither positional lookup nor a placeholder record.
  final _itemIds = <String, String>{};
  final _partners = <String, String>{};
  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final clock = Stopwatch()..start();
    try {
      final editor = widget.service.imageEditor;
      require(editor != null, 'خدمة معالجة الصور غير متاحة.');
      final source = await editor!.open(widget.asset);
      if (!mounted) return;
      widget.stageLog
          ?.forAsset(widget.asset.id)
          .pass(
            JourneyStage.selection,
            'فُتحت الصورة الأصلية لمساحة التحديد اليدوي.',
            durationMs: clock.elapsedMilliseconds,
          );
      setState(() {
        _appendSelection();
        _source = source;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      widget.stageLog
          ?.forAsset(widget.asset.id)
          .block(
            JourneyStage.selection,
            'تعذر فتح الصورة للتحديد.',
            fields: {'errorType': error.runtimeType.toString()},
          );
      setState(() {
        _loading = false;
        _error = userError(error);
      });
    }
  }

  void _addSelection() => setState(_appendSelection);
  void _appendSelection() {
    final id = 'sel-${_nextId++}';
    _itemIds[id] = newId();
    _set = _set.add(
      ManualDocumentSelection(
        id: id,
        corners: const [],
        kind: widget.options?.kind ?? DocumentKind.unknown,
        side: widget.options?.side ?? SideKind.unknown,
      ),
    );
    _activeId = id;
    _error = null;
    _notice = null;
  }

  void _select(String id) => setState(() {
    _activeId = id;
    _error = null;
  });

  void _delete(String id) {
    setState(() {
      _forgetPartner(id);
      _itemIds.remove(id);
      _set = _set.remove(id);
      if (_activeId == id) {
        _activeId = _set.isEmpty ? null : _set.selections.last.id;
      }
      _error = null;
    });
  }

  ManualDocumentSelection? get _active =>
      _activeId == null ? null : _set.byId(_activeId!);

  void _changeBoundary(ManualSelectionSet Function() change) {
    try {
      final next = change();
      setState(() {
        _set = next;
        _error = null;
        _notice = null;
      });
    } on ValidationException catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _forgetPartner(String id) => _partners.removeWhere(
    (owner, target) => owner == id || target == _itemIds[id],
  );
  bool _canConfirm(ManualDocumentSelection selection) =>
      selection.customSizeMm != null ||
      (widget.project.catalog.natural(selection.kind) != null &&
          documentSizeRecordFor(selection.kind).mayBeConfirmedAutomatically);
  Map<String, String> _candidates(ManualDocumentSelection active) {
    final project = _saved ?? widget.project;
    if (!_canConfirm(active) ||
        active.side == SideKind.unknown ||
        _partners.containsValue(_itemIds[active.id])) {
      return {};
    }
    final reserved = {
      for (final entry in _partners.entries)
        if (entry.key != active.id) entry.value,
    };
    return {
      for (final item in matchingManualSidePartners(
        project,
        kind: active.kind,
        side: active.side,
        draftSourceId: widget.asset.id,
        draftCorners: active.validatedCorners,
      ))
        if (!reserved.contains(item.id))
          item.id: manualPartnerLabel(project, item),
      for (final other in _set.selections)
        if (other.isValid &&
            _canConfirm(other) &&
            other.kind == active.kind &&
            oppositeManualSides(other.side, active.side) &&
            !_partners.containsKey(other.id) &&
            !reserved.contains(_itemIds[other.id]))
          _itemIds[other.id]!: _labelFor(other.id),
    };
  }

  void _undoCorner() {
    final active = _active;
    if (active == null || active.corners.isEmpty) return;
    setState(() {
      _set = _set.undoCorner(active.id);
      _error = null;
    });
  }

  /// Clears the active selection's corners but keeps its row, so starting over
  /// does not lose the document's place in the list.
  void _cancelSelection() {
    final active = _active;
    if (active == null) return;
    setState(() {
      _set = _set.replace(active.copyWith(corners: const []));
      _error = null;
      _notice = 'أُلغيت زوايا «${_labelFor(active.id)}»؛ يمكن رسمها من جديد.';
    });
  }

  void _setKind(DocumentKind kind) {
    final active = _active;
    if (active == null || active.kind == kind) return;
    setState(() {
      // A category change must not keep a manual size measured for the old one.
      _forgetPartner(active.id);
      _set = _set.replace(active.copyWith(kind: kind, clearCustomSize: true));
      _error = null;
    });
  }

  void _setSide(SideKind side) {
    final active = _active;
    if (active == null || active.side == side) return;
    setState(() {
      _forgetPartner(active.id);
      _set = _set.replace(active.copyWith(side: side));
    });
  }

  /// Crops every selection through the existing derived-document path.
  ///
  /// Sequential on purpose: each call saves the project and returns the new one,
  /// and the next call must see it. Running them concurrently would race on the
  /// same project record.
  Future<void> _apply() async {
    if (_busy) return;
    final source = _source;
    if (source == null) return;
    final invalid = _set.invalid;
    if (_set.isEmpty || invalid.isNotEmpty) {
      setState(() {
        _error = invalid.isEmpty
            ? 'أضف مستمسكاً واحداً على الأقل.'
            : 'أكمل المستمسكات التالية قبل الإضافة: '
                  '${invalid.map((s) => _labelFor(s.id)).join('، ')}.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    var project = _saved ?? widget.project;
    if (widget.options case final chosen?) {
      project = project.copyWith(
        layout: project.layout.copyWith(centerCaptures: chosen.centerDocuments),
      );
    }
    final failures = <String>[];
    // Link only to a committed target. A failed target leaves its dependent
    // retryable; unrelated successful documents stay committed.
    final ordered = [
      for (final s in _set.selections)
        if (!_partners.containsKey(s.id)) s,
      for (final s in _set.selections)
        if (_partners.containsKey(s.id)) s,
    ];
    for (final selection in ordered) {
      final key = '${widget.asset.id}-${selection.id}';
      final log = widget.stageLog?.forAsset(key, name: selection.id);
      try {
        final ring = selection.validatedCorners;
        require(ring != null, 'التحديد «${_labelFor(selection.id)}» غير صالح.');
        final recipe = CropDraft(
          corners: ring!,
          adjustments: ImageAdjustments(sharpness: initialManualCropSharpness),
        ).toRecipe(source.width, source.height);
        project = await widget.service.extractManualDerivedDocument(
          project,
          widget.asset,
          recipe,
          documentKind: selection.kindForExtraction,
          side: selection.side,
          reservedItemId: _itemIds[selection.id],
          partnerItemId: _partners[selection.id],
          stages: log,
          keepPlaced: true,
          customSizeMm: selection.customSizeMm,
          sourceWidth: source.width,
          sourceHeight: source.height,
        );
        _saved = project;
        _partners.remove(selection.id);
        _itemIds.remove(selection.id);
        _set = _set.remove(selection.id);
      } catch (error) {
        failures.add('${_labelFor(selection.id)}: ${userError(error)}');
        log?.block(
          JourneyStage.save,
          'تعذر إكمال استخراج المستمسك.',
          fields: {'errorType': error.runtimeType.toString()},
        );
      }
      if (!mounted) return;
    }
    if (failures.isEmpty) {
      Navigator.of(context).pop(project);
    } else {
      setState(() {
        _busy = false;
        _activeId = _set.selections.first.id;
        _error = failures.join('\n');
      });
    }
  }

  /// A stable, human label. The list, the messages and the overlay numbers all
  /// use it, so «المستمسك 3» means the same row everywhere.
  String _labelFor(String id) {
    final index = _set.selections.indexWhere((s) => s.id == id);
    return index < 0 ? id : 'المستمسك ${index + 1}';
  }

  bool get _untouched =>
      _set.isEmpty ||
      (_set.length == 1 &&
          _set.selections.single.corners.isEmpty &&
          _partners.isEmpty &&
          _set.selections.single.kind ==
              (widget.options?.kind ?? DocumentKind.unknown) &&
          _set.selections.single.side ==
              (widget.options?.side ?? SideKind.unknown));

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy && _untouched && _saved == null,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _busy) return;
        final discard = await confirm(
          context,
          'إلغاء تحديد المستمسكات؟',
          'ستُترك التحديدات غير المحفوظة. تبقى الصورة الأصلية والمستمسكات المحفوظة.',
          confirmLabel: 'إلغاء التحديد',
          destructive: true,
        );
        if (discard && context.mounted) Navigator.of(context).pop(_saved);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تحديد عدة مستمسكات'),
          actions: [
            TextButton(
              key: const Key('multi-selection-add'),
              onPressed: _busy || _source == null ? null : _addSelection,
              child: const Text('مستمسك جديد'),
            ),
          ],
        ),
        body: SafeArea(
          child: AbsorbPointer(absorbing: _busy, child: _body(context)),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('multi-selection-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_source == null) {
      return Center(
        key: const Key('multi-selection-unavailable'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error ?? 'تعذّر فتح الصورة.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(flex: 3, child: _canvasArea()),
        if (_error != null) _banner(_error!, isError: true),
        if (_notice != null && _error == null) _banner(_notice!),
        if (_active != null) _activeControls(_active!),
        Expanded(flex: 2, child: _selectionList()),
        _footer(),
      ],
    );
  }

  Widget _banner(String message, {bool isError = false}) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: isError
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        message,
        key: Key(isError ? 'multi-selection-error' : 'multi-selection-notice'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: isError ? theme.colorScheme.onErrorContainer : null,
        ),
      ),
    );
  }

  Widget _canvasArea() {
    final active = _active;
    final ring = active?.validatedCorners;
    return Stack(
      key: const Key('multi-selection-canvas'),
      children: [
        Positioned.fill(
          child: CropBoundaryCanvas(
            key: ValueKey(_activeId),
            source: _source!,
            view: _view,
            imageKey: const Key('multi-selection-source'),
            corners: ring ?? const [],
            taps: active != null && ring == null ? active.corners : null,
            backgrounds: {
              for (final (i, s) in _set.selections.indexed)
                if (s.id != _activeId) i + 1: s.validatedCorners ?? s.corners,
            },
            onTap: (point, separation) {
              if (active != null) {
                _changeBoundary(
                  () => _set.addCorner(
                    active.id,
                    point,
                    minSeparation: separation,
                  ),
                );
              }
            },
            onMove: (points) {
              if (active != null) {
                _changeBoundary(() {
                  require(
                    normalizedQuadIssue(points) == null,
                    'حدود غير صالحة؛ أبقيت آخر موضع صالح.',
                  );
                  return _set.replace(active.copyWith(corners: points));
                });
              }
            },
            onDragStart: () => _beforeDrag = active,
            onDragCancel: () {
              if (_beforeDrag case final before?) {
                _changeBoundary(() => _set.replace(before));
              }
            },
            onRefused: () => setState(() => _error = cornerCrossingMessage),
          ),
        ),
        Positioned(
          left: 4,
          top: 4,
          child: Row(
            children: [
              for (final (key, icon, label, factor) in [
                ('in', Icons.zoom_in, 'تكبير', 1.5),
                ('out', Icons.zoom_out, 'تصغير', 1 / 1.5),
                ('reset', Icons.fit_screen, 'عرض الصورة كاملة', 0.0),
              ])
                IconButton(
                  key: Key('multi-selection-zoom-$key'),
                  tooltip: label,
                  icon: Icon(icon),
                  onPressed: () {
                    final scale = _view.value.getMaxScaleOnAxis();
                    if (factor == 0) {
                      _view.value = Matrix4.identity();
                    } else {
                      final zoom = (scale * factor).clamp(1.0, 5.0) / scale;
                      _view.value = _view.value.clone()
                        ..scaleByDouble(zoom, zoom, 1, 1);
                    }
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _activeControls(ManualDocumentSelection active) {
    final theme = Theme.of(context);
    final issue = active.issue;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_labelFor(active.id)} · '
                  '${active.corners.length}/'
                  '${ManualDocumentSelection.requiredCorners} زوايا',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              TextButton(
                key: const Key('multi-selection-undo-corner'),
                onPressed: active.corners.isEmpty || _busy ? null : _undoCorner,
                child: const Text('تراجع'),
              ),
              TextButton(
                key: const Key('multi-selection-cancel-selection'),
                onPressed: active.corners.isEmpty || _busy
                    ? null
                    : _cancelSelection,
                child: const Text('إلغاء التحديد'),
              ),
            ],
          ),
          if (issue != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                issue,
                key: const Key('multi-selection-selection-issue'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              DropdownButton<DocumentKind>(
                key: const Key('multi-selection-kind'),
                value: active.kind,
                isDense: true,
                onChanged: _busy ? null : (kind) => _setKind(kind!),
                items: [
                  const DropdownMenuItem(
                    value: DocumentKind.unknown,
                    child: Text('بلا نوع محدد'),
                  ),
                  for (final kind in DocumentKind.values)
                    if (kind != DocumentKind.unknown)
                      DropdownMenuItem(value: kind, child: Text(kind.label)),
                ],
              ),
              DropdownButton<SideKind>(
                key: const Key('multi-selection-side'),
                value: active.side,
                isDense: true,
                onChanged: _busy ? null : (side) => _setSide(side!),
                items: const [
                  DropdownMenuItem(
                    value: SideKind.unknown,
                    child: Text('وجه واحد'),
                  ),
                  DropdownMenuItem(
                    value: SideKind.front,
                    child: Text('وجه أول'),
                  ),
                  DropdownMenuItem(
                    value: SideKind.back,
                    child: Text('وجه ثانٍ'),
                  ),
                ],
              ),
            ],
          ),
          if (_candidates(active) case final candidates
              when candidates.isNotEmpty || _partners[active.id] != null)
            SidePartnerField(
              key: const Key('multi-selection-partner'),
              choices: candidates,
              value: _partners[active.id],
              onChanged: (id) => setState(() {
                if (id == null) {
                  _partners.remove(active.id);
                } else {
                  _partners[active.id] = id;
                }
              }),
            )
          else if (active.side != SideKind.unknown && !_canConfirm(active))
            const Text('يتاح ربط الوجه الآخر بعد تحديد النوع وتأكيد المقاس.'),
          if (active.kind == DocumentKind.unknown)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                // Said before the person commits, not after: an unstated
                // category is added as a free document that stays off the sheet
                // until review settles its category and size.
                'بلا نوع محدد: يُضاف كمستمسك آخر يبقى خارج ورقة A4 '
                'حتى تحدّد نوعه ومقاسه في المراجعة.',
                key: const Key('multi-selection-kind-default'),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _selectionList() {
    if (_set.isEmpty) {
      return Center(
        key: const Key('multi-selection-empty'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'اضغط «مستمسك جديد» ثم انقر زوايا كل مستند: أربع زوايا لكل واحد. '
            'يمكنك تحديد عدة مستندات في الصورة نفسها.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return ListView.builder(
      key: const Key('multi-selection-list'),
      itemCount: _set.length,
      itemBuilder: (context, index) {
        final selection = _set.selections[index];
        return ListTile(
          key: Key('multi-selection-row-${selection.id}'),
          dense: true,
          selected: selection.id == _activeId,
          onTap: () => _select(selection.id),
          leading: CircleAvatar(radius: 14, child: Text('${index + 1}')),
          title: Text(_labelFor(selection.id)),
          subtitle: Text(
            '${selection.isValid ? 'جاهز' : (selection.issue ?? 'غير مكتمل')} · '
            '${selection.kind.label}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            key: Key('multi-selection-delete-${selection.id}'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'حذف التحديد',
            onPressed: _busy ? null : () => _delete(selection.id),
          ),
        );
      },
    );
  }

  Widget _footer() {
    final ready = _set.valid.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _set.isEmpty
                  ? 'لا توجد مستندات محددة'
                  : '$ready جاهز من ${_set.length}',
              key: const Key('multi-selection-progress'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          FilledButton.icon(
            key: const Key('multi-selection-apply'),
            onPressed: _busy || !_set.canApply ? null : _apply,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            label: Text(_busy ? 'جارٍ الإضافة…' : 'إضافة المستمسكات'),
          ),
        ],
      ),
    );
  }
}
