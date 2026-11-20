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
import 'image_viewport.dart';
import 'shared.dart';

/// The fallback sharpness the single-document manual path also starts from, so a
/// document cropped here and one cropped there come out alike.
const double multiSelectionSharpness = .5;

/// The minimum gap, in screen pixels, between two corners. It removes accidental
/// double taps only; it is not a detection rule, and it is measured through
/// [ImageViewport.screenDistance] so it scales with the zoom the person sees.
const double multiSelectionMinSeparationPx = 20.0;

/// The radius, in screen pixels, for grabbing an existing corner.
const double multiSelectionGrabRadiusPx = 28.0;

/// How far a single pointer may travel and still count as a tap. Beyond this it
/// is a pan or a corner drag: 10 px is comfortably larger than a steady finger
/// wobble and far smaller than any deliberate move.
const double _tapSlopPx = 10;

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

  /// Zoom. The pan is stored as the image point pinned to the centre of the
  /// workspace instead of as a pixel offset, so a rotation, a resize or the
  /// options panel changing height cannot move the person's place.
  double _scale = ImageViewport.minScale;
  Point2? _centre;

  /// Gesture bookkeeping: which corner a drag grabbed, and whether the pointer
  /// has moved far enough to be a pan rather than a tap.
  int? _dragCorner;
  Offset? _pressAt;
  bool _gestureMoved = false;

  /// Where every finger currently is, by pointer id. Two fingers are a pinch;
  /// one finger is a pan, a corner drag, or a tap.
  final Map<int, Offset> _pointers = {};

  /// The previous two-finger distance, so a pinch zooms by the RATIO between
  /// moves rather than from a recogniser's internal baseline.
  double? _pinchSpan;

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

  /// The viewport for this box, derived purely from the zoom and the pinned
  /// centre. Nothing here depends on the previous box size.
  ImageViewport _viewport(Size box) {
    final source = _source!;
    final base = ImageViewport(
      viewport: box,
      imageWidth: source.width.toDouble(),
      imageHeight: source.height.toDouble(),
      scale: _scale,
    );
    final centre = _centre;
    if (centre == null) return base;
    final target = Offset(box.width / 2, box.height / 2);
    final current = base.toScreen(centre);
    return base.translatedBy(target - current);
  }

  void _applyView(ImageViewport next) {
    _scale = next.scale;
    _centre = next.toImage(
      Offset(next.viewport.width / 2, next.viewport.height / 2),
    );
  }

  void _addSelection() {
    final id = 'sel-${_nextId++}';
    setState(() {
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
    });
  }

  void _select(String id) => setState(() {
    _activeId = id;
    _error = null;
  });

  void _delete(String id) {
    setState(() {
      _set = _set.remove(id);
      if (_activeId == id) {
        _activeId = _set.isEmpty ? null : _set.selections.last.id;
      }
      _error = null;
    });
  }

  ManualDocumentSelection? get _active =>
      _activeId == null ? null : _set.byId(_activeId!);

  /// Places a new corner, or moves the grabbed one. Every rejection becomes a
  /// message rather than a silent no-op: a corner that «just did not appear» is
  /// the worst possible outcome for someone outlining a document by hand.
  void _placePoint(ImageViewport viewport, Offset local) {
    final active = _active;
    if (active == null) {
      setState(() => _error = 'اختر مستمسكاً من القائمة أو أضف واحداً أولاً.');
      return;
    }
    if (!viewport.containsScreen(
      local,
      tolerance: multiSelectionGrabRadiusPx,
    )) {
      setState(() => _error = 'النقطة خارج الصورة؛ اضغط داخل حدود الصورة.');
      return;
    }
    final point = viewport.toImage(local);
    final grabbed = _dragCorner;
    try {
      if (grabbed != null) {
        setState(() {
          _set = _set.moveCorner(active.id, grabbed, point);
          _error = null;
        });
        return;
      }
      if (active.isComplete) {
        setState(() {
          _error =
              'المستمسك «${_labelFor(active.id)}» مكتمل. '
              'اسحب إحدى زواياه لتعديلها، أو أضف مستمسكاً جديداً.';
        });
        return;
      }
      setState(() {
        _set = _set.addCorner(
          active.id,
          point,
          minSeparation:
              multiSelectionMinSeparationPx / viewport.displayedRect.width,
        );
        _error = null;
        _notice = null;
      });
    } on ValidationException catch (error) {
      setState(() => _error = error.message);
    }
  }

  /// Distance between the two fingers, or null when there are not exactly two.
  double? get _twoFingerSpan {
    if (_pointers.length != 2) return null;
    final positions = _pointers.values.toList();
    return (positions[0] - positions[1]).distance;
  }

  /// The midpoint between the two fingers, which is the point a pinch zooms
  /// about.
  Offset get _twoFingerFocus {
    final positions = _pointers.values.toList();
    return Offset(
      (positions[0].dx + positions[1].dx) / 2,
      (positions[0].dy + positions[1].dy) / 2,
    );
  }

  /// The nearest corner of the active selection to [local], within the grab
  /// radius. Returns its index so a drag moves exactly one point.
  int? _cornerAt(ImageViewport viewport, Offset local) {
    final active = _active;
    if (active == null) return null;
    int? best;
    var bestDistance = double.infinity;
    for (var i = 0; i < active.corners.length; i++) {
      final distance = (viewport.toScreen(active.corners[i]) - local).distance;
      if (distance <= multiSelectionGrabRadiusPx && distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
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
    if (active == null) return;
    setState(() {
      // A category change must not keep a manual size measured for the old one.
      _set = _set.replace(active.copyWith(kind: kind, clearCustomSize: true));
      _error = null;
    });
  }

  void _setSide(SideKind side) {
    final active = _active;
    if (active == null) return;
    setState(() => _set = _set.replace(active.copyWith(side: side)));
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
    for (final selection in _set.selections) {
      final key = '${widget.asset.id}-${selection.id}';
      final log = widget.stageLog?.forAsset(key, name: selection.id);
      try {
        final ring = selection.validatedCorners;
        require(ring != null, 'التحديد «${_labelFor(selection.id)}» غير صالح.');
        final recipe = CropDraft(
          corners: ring!,
          adjustments: ImageAdjustments(sharpness: multiSelectionSharpness),
        ).toRecipe(source.width, source.height);
        project = await widget.service.extractManualDerivedDocument(
          project,
          widget.asset,
          recipe,
          documentKind: selection.kindForExtraction,
          side: selection.side,
          stages: log,
          keepPlaced: true,
          customSizeMm: selection.customSizeMm,
          sourceWidth: source.width,
          sourceHeight: source.height,
        );
        _saved = project;
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy && _set.isEmpty && _saved == null,
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
    return LayoutBuilder(
      builder: (context, box) {
        final viewport = _viewport(Size(box.maxWidth, box.maxHeight));
        // Raw pointer tracking, not competing gesture recognisers.
        //
        // A tap must place a corner and a drag must pan or move one, with no
        // arena deciding between them after the fact — that ambiguity is exactly
        // how a tap silently became a two-pixel pan. Here the intent is decided
        // once: a second finger is always a pinch, and a move of more than
        // [_tapSlopPx] is always a pan or a corner drag.
        return Listener(
          key: const Key('multi-selection-canvas'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            _pointers[event.pointer] = event.localPosition;
            _pressAt = event.localPosition;
            _gestureMoved = false;
            _pinchSpan = _twoFingerSpan;
            // A second finger means the person is zooming, so no corner is held.
            _dragCorner = _pointers.length == 1
                ? _cornerAt(viewport, event.localPosition)
                : null;
          },
          onPointerMove: (event) {
            final known = _pointers.containsKey(event.pointer);
            _pointers[event.pointer] = event.localPosition;
            final origin = _pressAt;
            if (origin != null &&
                (event.localPosition - origin).distance > _tapSlopPx) {
              _gestureMoved = true;
            }
            if (_pointers.length >= 2) {
              final previous = _pinchSpan;
              final span = _pinchSpan = _twoFingerSpan;
              if (known && previous != null && span != null && previous > 0) {
                setState(
                  () => _applyView(
                    viewport.scaledBy(span / previous, focus: _twoFingerFocus),
                  ),
                );
              }
              return;
            }
            setState(() {
              final grabbed = _dragCorner;
              if (grabbed != null) {
                final active = _active;
                if (active == null) return;
                try {
                  _set = _set.moveCorner(
                    active.id,
                    grabbed,
                    viewport.toImage(event.localPosition),
                  );
                  _error = null;
                } on ValidationException catch (error) {
                  // Refused at the last good position, with the reason stated.
                  _error = error.message;
                }
              } else {
                _applyView(viewport.translatedBy(event.localDelta));
              }
            });
          },
          onPointerUp: (event) {
            final wasTap = !_gestureMoved && _pointers.length == 1;
            final grabbed = _dragCorner;
            _pointers.remove(event.pointer);
            _pressAt = null;
            _pinchSpan = null;
            _dragCorner = null;
            _gestureMoved = false;
            if (wasTap && grabbed == null) {
              _placePoint(viewport, event.localPosition);
            }
          },
          onPointerCancel: (event) {
            _pointers.remove(event.pointer);
            _pressAt = null;
            _pinchSpan = null;
            _dragCorner = null;
            _gestureMoved = false;
          },
          child: ClipRect(
            child: Stack(
              children: [
                // The photograph is drawn exactly where the viewport says it is,
                // NOT stretched to the box: a stretched image would put the
                // pixels somewhere other than the coordinates taps are converted
                // into, and every corner would land slightly wrong.
                Positioned.fromRect(
                  rect: viewport.displayedRect,
                  child: Image.memory(
                    _source!.preview,
                    key: const Key('multi-selection-source'),
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SelectionPainter(
                        selections: _set.selections,
                        activeId: _activeId,
                        viewport: viewport,
                      ),
                    ),
                  ),
                ),
                Positioned(left: 8, top: 8, child: _zoomControls(viewport)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _zoomControls(ImageViewport viewport) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const Key('multi-selection-zoom-in'),
            color: Colors.white,
            icon: const Icon(Icons.zoom_in),
            tooltip: 'تكبير',
            onPressed: () => setState(() => _applyView(viewport.scaledBy(1.5))),
          ),
          IconButton(
            key: const Key('multi-selection-zoom-out'),
            color: Colors.white,
            icon: const Icon(Icons.zoom_out),
            tooltip: 'تصغير',
            onPressed: () =>
                setState(() => _applyView(viewport.scaledBy(1 / 1.5))),
          ),
          IconButton(
            key: const Key('multi-selection-zoom-reset'),
            color: Colors.white,
            icon: const Icon(Icons.fit_screen),
            tooltip: 'عرض الصورة كاملة',
            onPressed: () => setState(() {
              _scale = ImageViewport.minScale;
              _centre = null;
            }),
          ),
        ],
      ),
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

/// Draws every selection, numbering them the way the list does, so a person can
/// tell at a glance which outline is which row.
class _SelectionPainter extends CustomPainter {
  _SelectionPainter({
    required this.selections,
    required this.activeId,
    required this.viewport,
  });

  final List<ManualDocumentSelection> selections;
  final String? activeId;
  final ImageViewport viewport;

  @override
  void paint(Canvas canvas, Size size) {
    for (var index = 0; index < selections.length; index++) {
      final selection = selections[index];
      final active = selection.id == activeId;
      final ordered = selection.validatedCorners;
      final points = ordered != null
          ? [for (final corner in ordered) viewport.toScreen(corner)]
          : [for (final corner in selection.corners) viewport.toScreen(corner)];
      if (points.isEmpty) continue;
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2.5 : 1.5
        ..color = active ? Colors.lightGreenAccent : Colors.white70;
      if (points.length >= 3) {
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        path.close();
        canvas.drawPath(path, stroke);
      } else if (points.length == 2) {
        canvas.drawLine(points[0], points[1], stroke);
      }
      final handle = Paint()
        ..style = PaintingStyle.fill
        ..color = active ? Colors.lightGreenAccent : Colors.white70;
      for (final point in points) {
        canvas.drawCircle(point, active ? 6 : 4, handle);
      }
      // The number sits above the first corner, matching the list row.
      final anchor = points.first;
      final label = TextPainter(
        text: TextSpan(
          text: '${index + 1}',
          style: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badge = Rect.fromLTWH(anchor.dx - 10, anchor.dy - 24, 20, 16);
      canvas.drawRRect(
        RRect.fromRectAndRadius(badge, const Radius.circular(3)),
        Paint()..color = active ? Colors.lightGreenAccent : Colors.black54,
      );
      label.paint(canvas, Offset(badge.left + 7, badge.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter old) =>
      old.activeId != activeId ||
      old.viewport != viewport ||
      !_sameSelections(old.selections, selections);

  static bool _sameSelections(
    List<ManualDocumentSelection> a,
    List<ManualDocumentSelection> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].corners.length != b[i].corners.length) {
        return false;
      }
      for (var c = 0; c < a[i].corners.length; c++) {
        if (a[i].corners[c].x != b[i].corners[c].x ||
            a[i].corners[c].y != b[i].corners[c].y) {
          return false;
        }
      }
    }
    return true;
  }
}
