import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../application/ids.dart';
import '../application/layout_session.dart';
import '../application/project_service.dart';
import '../domain/arrangement.dart';
import '../domain/crop_draft.dart';
import '../domain/document_edits.dart';
import '../domain/document_kind.dart';
import '../domain/image_adjustments.dart';
import '../domain/page_layout.dart';
import '../domain/project.dart';
import '../domain/validation.dart';

/// How the sheet view chooses its scale.
enum ZoomMode { custom, pageWidth, wholePage }

/// Smallest and largest zoom factors, where 1.0 is the real paper size.
const minZoom = .25, maxZoom = 4.0;

/// State and commands of the A4 editor, shared by the ribbon, the sheet view
/// and the status bar. Every change goes through [LayoutSession], so it is
/// saved before the screen shows it and can be undone.
///
/// With [autoFlow] on (the default) every edit that changes a size, a
/// category, the paper or the document list re-runs the automatic
/// arrangement, so the sheet always reflects the edit — like text reflowing
/// in a word processor. Moving a document by hand turns [autoFlow] off.
class LayoutEditorController extends ChangeNotifier {
  LayoutEditorController({
    required Project project,
    required this.service,
    this.pickImages,
    this.adjustmentCommitDelay = const Duration(milliseconds: 700),
    this.nudgeCommitDelay = const Duration(milliseconds: 260),
  }) : session = LayoutSession(project, service.projects);

  final ProjectService service;
  final LayoutSession session;
  final Future<List<ImportSource>> Function()? pickImages;

  /// Pause after the last slider movement before a revision is written.
  final Duration adjustmentCommitDelay;
  final Duration nudgeCommitDelay;

  /// Shows a short confirmation or explanation to the user.
  void Function(String message)? onMessage;

  final selected = <String>{};
  bool busy = false;
  String? error;
  bool autoFlow = true;
  bool allowOverlap = false;
  bool showGuides = true;

  /// Touch-friendly multi-selection: while on, selecting a document adds it
  /// to the selection or removes it (what Ctrl/Shift-click does with a mouse)
  /// and pressing or dragging a document never moves it. Resize handles and
  /// the arrow keys keep working.
  bool multiSelect = false;
  ZoomMode zoomMode = ZoomMode.pageWidth;
  double zoom = 1;
  int visiblePage = 0;

  Project? _preview;
  bool _disposed = false;

  Project get project => _preview ?? session.current;
  bool get canUndo => !busy && session.history.canUndo;
  bool get canRedo => !busy && session.history.canRedo;

  DocumentItem? get active => selected.isEmpty
      ? null
      : project.items.where((e) => e.id == selected.last).firstOrNull;

  ImageAsset? get activeAsset {
    final item = active;
    if (item == null) return null;
    return project.assets.where((a) => a.id == item.assetId).firstOrNull;
  }

  List<DocumentItem> get selectedItems => [
    for (final item in project.items)
      if (selected.contains(item.id)) item,
  ];

  List<DocumentItem> get offSheet => [
    for (final item in project.items)
      if (item.pageIndex == null) item,
  ];

  ImageAsset assetOf(DocumentItem item) =>
      project.assets.firstWhere((a) => a.id == item.assetId);

  @override
  void dispose() {
    _disposed = true;
    _nudgeTimer?.cancel();
    _adjustTimer?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _say(String message) => onMessage?.call(message);

  // ---------------------------------------------------------------------
  // Command plumbing

  Future<bool> _guard(Future<void> Function() action) async {
    if (busy || _drag != null) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
      return true;
    } catch (e) {
      error = userError(e);
      return false;
    } finally {
      busy = false;
      selected.removeWhere(
        (id) => !session.current.items.any((e) => e.id == id),
      );
      visiblePage = math.min(visiblePage, session.current.pageCount - 1);
      _notify();
    }
  }

  /// Runs one saved command, after any pending keyboard nudge and picture
  /// edit are written, so commands never interleave.
  Future<bool> run(Future<void> Function() action) async {
    if (_nudgeId != null) await _flushNudge();
    if (_adjustTimer != null) await commitAdjustments();
    return _guard(action);
  }

  /// Applies [change] and then re-lays the sheet: a full re-arrangement with
  /// [autoFlow], otherwise ready off-sheet documents are put into free space
  /// and the hand-made layout is validated. [manual] marks a hand
  /// positioning, which turns [autoFlow] off.
  Future<bool> edit(
    Project Function(Project) change, {
    bool layout = true,
    bool manual = false,
  }) {
    if (manual && autoFlow) {
      autoFlow = false;
      _say(
        'أُوقف «الترتيب المستمر» لأنك رتّبت يدوياً؛ أعد تشغيله من تبويب «الرئيسية» متى شئت.',
      );
    }
    return run(() => session.apply((p) => _relayout(change(p), layout)));
  }

  Project _relayout(Project changed, bool layout) {
    if (!layout) return PageLayout.checked(changed, allowOverlap: allowOverlap);
    if (autoFlow) return arrangeDocuments(changed).result;
    return PageLayout.checked(
      arrangeDocuments(changed, keepPlaced: true).result,
      allowOverlap: allowOverlap,
    );
  }

  Future<void> undo() async {
    await run(session.undo);
  }

  Future<void> redo() async {
    await run(session.redo);
  }

  // ---------------------------------------------------------------------
  // Selection

  /// Selects one document ([toggle], or [multiSelect], adds/removes it
  /// instead). [reveal] scrolls the sheet to its page.
  void select(String id, {bool toggle = false, bool reveal = false}) {
    if (toggle || multiSelect) {
      if (!selected.remove(id)) selected.add(id);
    } else {
      selected
        ..clear()
        ..add(id);
    }
    final item = project.items.where((e) => e.id == id).firstOrNull;
    final page = item?.pageIndex;
    if (page != null) {
      visiblePage = page;
      if (reveal) pendingScrollPage = page;
    }
    _notify();
    final asset = activeAsset;
    if (asset != null) unawaited(ensureLiveBase(asset));
  }

  void selectAll() {
    selected
      ..clear()
      ..addAll(project.items.map((e) => e.id));
    _notify();
  }

  void clearSelection() {
    selected.clear();
    _notify();
  }

  void setMultiSelect(bool value) {
    multiSelect = value;
    _notify();
  }

  // ---------------------------------------------------------------------
  // Arrangement

  Future<void> arrangeNow() async {
    ArrangementResult? outcome;
    final ok = await run(
      () => session.apply((p) {
        outcome = arrangeDocuments(p);
        return outcome!.result;
      }),
    );
    if (!ok || outcome == null) return;
    final result = outcome!;
    final parts = [
      'رُتّبت المستمسكات على ${result.pageCount} صفحة',
      if (result.awaitingSize.isNotEmpty)
        '${result.awaitingSize.length} بانتظار تحديد النوع',
      if (result.unplaced.isNotEmpty)
        '${result.unplaced.length} أكبر من مساحة الطباعة',
    ];
    _say(parts.join(' · '));
  }

  Future<void> setAutoFlow(bool value) async {
    autoFlow = value;
    _notify();
    if (value) await arrangeNow();
  }

  Future<void> setStrategy(ArrangementStrategy strategy) =>
      edit((p) => p.copyWith(layout: p.layout.copyWith(strategy: strategy)));

  Future<void> setAllowRotation(bool value) =>
      edit((p) => p.copyWith(layout: p.layout.copyWith(allowRotation: value)));

  Future<void> setOrder(LayoutOrder order) =>
      edit((p) => p.copyWith(layout: p.layout.copyWith(order: order)));

  void setAllowOverlap(bool value) {
    allowOverlap = value;
    _notify();
  }

  void setShowGuides(bool value) {
    showGuides = value;
    _notify();
  }

  // ---------------------------------------------------------------------
  // Page setup

  Future<void> setOrientation(PaperOrientation orientation) => edit(
    (p) => p.copyWith(paper: p.paper.copyWith(orientation: orientation)),
  );

  Future<void> setMargins(Margins margins) =>
      edit((p) => p.copyWith(paper: p.paper.copyWith(margins: margins)));

  Future<void> setGaps({double? horizontal, double? vertical}) => edit(
    (p) => p.copyWith(
      layout: p.layout.copyWith(
        horizontalGap: horizontal,
        verticalGap: vertical,
      ),
    ),
  );

  Future<void> addPage() async {
    final ok = await edit(
      (p) => p.copyWith(pageCount: p.pageCount + 1),
      layout: false,
    );
    if (ok) {
      visiblePage = session.current.pageCount - 1;
      _notify();
    }
  }

  /// Removes every page without documents and closes the gaps.
  Future<void> removeEmptyPages() => edit((p) {
    final used = {
      for (final item in p.items)
        if (item.pageIndex != null) item.pageIndex!,
    }.toList()..sort();
    final remap = {for (var i = 0; i < used.length; i++) used[i]: i};
    return p.copyWith(
      pageCount: math.max(1, used.length),
      items: [
        for (final item in p.items)
          item.pageIndex == null
              ? item
              : item.copyWith(pageIndex: remap[item.pageIndex]),
      ],
    );
  }, layout: false);

  Future<void> setCatalog(DocumentSizeCatalog catalog) =>
      edit((p) => DocumentEdits.applyCatalog(p, catalog));

  // ---------------------------------------------------------------------
  // Document commands

  Iterable<String> get _editableIds =>
      selectedItems.where((item) => !item.locked).map((item) => item.id);

  Future<void> setKind(DocumentKind kind) {
    final ids = _editableIds.toList();
    if (ids.isEmpty) return _refuseLocked();
    return edit((p) {
      var next = p;
      for (final id in ids) {
        next = DocumentEdits.setKind(next, id, kind);
      }
      return next;
    });
  }

  Future<void> _refuseLocked() async {
    if (selected.isNotEmpty) {
      _say('العناصر المحددة مثبتة؛ ألغِ التثبيت أولاً.');
    }
  }

  Future<void> resizeActive({double? width, double? height}) async {
    final item = active;
    if (item == null) return;
    if (item.locked) return _refuseLocked();
    await edit(
      (p) => DocumentEdits.resize(p, item.id, width: width, height: height),
    );
  }

  Future<void> resetSize() {
    final ids = _editableIds
        .where(
          (id) =>
              project.catalog.natural(
                PageLayout.item(project, id).documentKind,
              ) !=
              null,
        )
        .toList();
    if (ids.isEmpty) {
      _say('لا يوجد مقاس محفوظ لنوع العنصر المحدد.');
      return Future.value();
    }
    return edit((p) {
      var next = p;
      for (final id in ids) {
        next = DocumentEdits.resetSize(next, id);
      }
      return next;
    });
  }

  Future<void> toggleAspectLock() async {
    final item = active;
    if (item == null || item.locked) return _refuseLocked();
    await edit(
      (p) => p.copyWith(
        items: [
          for (final e in p.items)
            e.id == item.id
                ? e.copyWith(keepAspectRatio: !e.keepAspectRatio)
                : e,
        ],
      ),
      layout: false,
    );
  }

  Future<void> rotateOnSheet() {
    final ids = _editableIds.toList();
    if (ids.isEmpty) return _refuseLocked();
    return edit((p) {
      var next = p;
      for (final id in ids) {
        next = DocumentEdits.rotate(next, id);
      }
      return next;
    });
  }

  Future<void> toggleLock() async {
    final items = selectedItems;
    if (items.isEmpty) return;
    final lock = !items.every((e) => e.locked);
    await edit((p) {
      var next = p;
      for (final item in items) {
        next = PageLayout.lock(next, item.id, lock);
      }
      return next;
    }, layout: false);
  }

  Future<void> bringForward() => _restack(forward: true);

  Future<void> sendBackward() => _restack(forward: false);

  Future<void> _restack({required bool forward}) async {
    final item = active;
    if (item == null || item.locked) return _refuseLocked();
    await edit((p) {
      final levels = p.items.map((e) => e.zIndex);
      final z = forward
          ? levels.reduce(math.max) + 1
          : levels.reduce(math.min) - 1;
      return p.copyWith(
        items: [
          for (final e in p.items) e.id == item.id ? e.copyWith(zIndex: z) : e,
        ],
      );
    }, layout: false);
  }

  Future<void> duplicate() => addCopies(1);

  Future<void> addCopies(int count) async {
    final item = active;
    if (item == null) return;
    require(count >= 1 && count <= 200, 'عدد النسخ يجب أن يكون بين 1 و200.');
    final ok = await edit(
      (p) => p.copyWith(
        items: [...p.items, ...PageLayout.copies(item, count, newId)],
      ),
    );
    if (ok) {
      final left = offSheet.where((e) => e.assetId == item.assetId).length;
      _say(
        left == 0
            ? 'أُضيفت $count نسخة ووُضعت على الورق.'
            : 'أُضيفت $count نسخة؛ $left منها خارج الورق لعدم وجود مساحة.',
      );
    }
  }

  Future<void> deleteSelected() async {
    if (selected.isEmpty) return;
    final ids = {...selected};
    if (project.items.any((e) => ids.contains(e.id) && e.locked)) {
      _say('ألغِ تثبيت العناصر المحددة قبل حذفها.');
      return;
    }
    final ok = await edit((p) => PageLayout.remove(p, ids));
    if (ok) _say('حُذف ${ids.length} عنصر. للتراجع: Ctrl + Z.');
  }

  Future<void> align(PageAlignment alignment) => edit(
    (p) => PageLayout.align(p, selected, alignment, allowOverlap: allowOverlap),
    layout: false,
    manual: true,
  );

  Future<void> distribute({required bool horizontal}) => edit(
    (p) => PageLayout.distribute(
      p,
      selected,
      horizontal: horizontal,
      allowOverlap: allowOverlap,
    ),
    layout: false,
    manual: true,
  );

  // ---------------------------------------------------------------------
  // Importing and cropping

  Future<void> importImages() async {
    final picker = pickImages;
    if (picker == null || busy) return;
    final List<ImportSource> sources;
    try {
      sources = await picker();
    } catch (e) {
      error = userError(e);
      _notify();
      return;
    }
    if (sources.isEmpty) return;
    AutomaticLayoutReport? report;
    var failures = 0;
    await run(() async {
      final existing = session.current.assets.map((a) => a.id).toSet();
      final imported = await service.importImages(session.current, sources);
      failures = imported.failures.length;
      final ids = [
        for (final asset in imported.project.assets)
          if (!existing.contains(asset.id)) asset.id,
      ];
      var latest = imported.project;
      if (ids.isNotEmpty) {
        try {
          report = await service.arrangeImportedImages(
            latest,
            ids,
            keepPlaced: !autoFlow,
          );
          latest = report!.project;
        } catch (_) {
          latest = await service.projects.get(latest.id);
          rethrow;
        } finally {
          if (latest.revision > session.current.revision) {
            await session.adoptSaved(latest);
          }
        }
      } else if (latest.revision > session.current.revision) {
        await session.adoptSaved(latest);
      }
    });
    final r = report;
    if (r != null) {
      _say(
        'قُصّ ${r.cropped} · تُعرّف على ${r.recognized} · بلا حدود ${r.notDetected}'
        '${failures > 0 ? ' · تعذر استيراد $failures' : ''}',
      );
    }
  }

  /// Adopts a crop saved by the crop editor and re-applies the catalog size
  /// in the new orientation.
  Future<void> adoptCrop(Project saved, String assetId) async {
    await run(() => session.adoptSaved(saved));
    final ids = [
      for (final item in session.current.items)
        if (item.assetId == assetId &&
            !item.locked &&
            session.current.catalog.natural(item.documentKind) != null)
          item.id,
    ];
    if (ids.isEmpty) return;
    await edit((p) {
      var next = p;
      for (final id in ids) {
        next = DocumentEdits.setKind(
          next,
          id,
          PageLayout.item(next, id).documentKind,
        );
      }
      return next;
    });
  }

  // ---------------------------------------------------------------------
  // Live picture corrections

  String? _liveAssetId;
  ImageAdjustments? _liveDraft;
  Timer? _adjustTimer;
  String? _baseKey;
  Uint8List? _baseBytes;
  String? _loadingKey;

  /// Adjustments to show for [asset]: the slider draft while editing.
  ImageAdjustments adjustmentsFor(ImageAsset asset) =>
      asset.id == _liveAssetId && _liveDraft != null
      ? _liveDraft!
      : asset.adjustments;

  String _keyFor(ImageAsset asset, ImageAdjustments adjustments) =>
      '${asset.id}|${asset.originalPath}|${asset.crop?.toJson()}|'
      '${adjustments.sharpness}|${adjustments.quarterTurns}';

  /// Colour-neutral preview of [asset] for live display, when ready. The
  /// base for a previous sharpness is kept while the new one renders.
  Uint8List? liveBaseFor(ImageAsset asset) {
    final key = _baseKey;
    if (key == null || _baseBytes == null) return null;
    final prefix = '${asset.id}|${asset.originalPath}|${asset.crop?.toJson()}|';
    if (!key.startsWith(prefix)) return null;
    final turns = adjustmentsFor(asset).quarterTurns;
    return key.endsWith('|$turns') ? _baseBytes : null;
  }

  Future<void> ensureLiveBase(ImageAsset asset) async {
    if (service.imageEditor == null) return;
    final adjustments = adjustmentsFor(asset);
    final key = _keyFor(asset, adjustments);
    if (key == _baseKey || key == _loadingKey) return;
    _loadingKey = key;
    try {
      final bytes = await service.livePreviewBase(asset, adjustments);
      if (_loadingKey == key) {
        _baseKey = key;
        _baseBytes = bytes;
        _notify();
      }
    } catch (_) {
      // The saved image stays visible; the live preview is an enhancement.
    } finally {
      if (_loadingKey == key) _loadingKey = null;
    }
  }

  /// Shows [value] on the selected picture immediately and writes the
  /// revision once the user pauses.
  void liveAdjust(ImageAdjustments value) {
    final asset = activeAsset;
    if (asset == null || busy) return;
    _liveAssetId = asset.id;
    _liveDraft = value;
    _notify();
    unawaited(ensureLiveBase(asset));
    _adjustTimer?.cancel();
    _adjustTimer = Timer(
      adjustmentCommitDelay,
      () => unawaited(commitAdjustments()),
    );
  }

  /// Writes the pending slider values as a new image revision now.
  Future<void> commitAdjustments() async {
    _adjustTimer?.cancel();
    _adjustTimer = null;
    final assetId = _liveAssetId;
    final draft = _liveDraft;
    if (assetId == null || draft == null) return;
    if (busy || _drag != null) {
      // Another command is being saved; try again right after it.
      _adjustTimer = Timer(
        adjustmentCommitDelay,
        () => unawaited(commitAdjustments()),
      );
      return;
    }
    final ok = await _guard(() async {
      final asset = session.current.assets.firstWhere((a) => a.id == assetId);
      final geometry =
          asset.crop ??
          CropDraft.fullImage().toRecipe(asset.width, asset.height).geometry;
      final revised = await service.createImageRevision(
        session.current,
        asset,
        ImageEditRecipe(geometry, draft),
      );
      await session.apply(
        (p) => p.copyWith(
          assets: [for (final a in p.assets) a.id == revised.id ? revised : a],
        ),
      );
    });
    if (_liveDraft == draft) {
      _liveDraft = null;
      _liveAssetId = null;
    }
    if (!ok) _notify();
  }

  Future<void> resetAdjustments() async {
    final asset = activeAsset;
    if (asset == null) return;
    liveAdjust(ImageAdjustments(quarterTurns: asset.adjustments.quarterTurns));
    await commitAdjustments();
  }

  Future<void> autoAdjust() async {
    final asset = activeAsset;
    if (asset == null) return;
    final ok = await run(() async {
      final current = session.current.assets.firstWhere(
        (a) => a.id == asset.id,
      );
      final suggestion = await service.suggestAutoAdjustments(
        session.current,
        current,
      );
      final geometry =
          current.crop ??
          CropDraft.fullImage()
              .toRecipe(current.width, current.height)
              .geometry;
      final revised = await service.createImageRevision(
        session.current,
        current,
        ImageEditRecipe(geometry, suggestion),
      );
      await session.apply(
        (p) => p.copyWith(
          assets: [for (final a in p.assets) a.id == revised.id ? revised : a],
        ),
      );
    });
    if (ok) _say('طُبّق التحسين التلقائي؛ عدّل المنزلقات أو تراجع عنه.');
  }

  /// Turns the picture itself by 90° and swaps the printed width and height.
  Future<void> rotateImage() async {
    final asset = activeAsset;
    if (asset == null) return;
    if (project.items.any((e) => e.assetId == asset.id && e.locked)) {
      return _refuseLocked();
    }
    await run(() async {
      final current = session.current.assets.firstWhere(
        (a) => a.id == asset.id,
      );
      final geometry =
          current.crop ??
          CropDraft.fullImage()
              .toRecipe(current.width, current.height)
              .geometry;
      final revised = await service.createImageRevision(
        session.current,
        current,
        ImageEditRecipe(
          geometry,
          current.adjustments.copyWith(
            quarterTurns: (current.adjustments.quarterTurns + 1) % 4,
          ),
        ),
      );
      await session.apply(
        (p) => _relayout(
          DocumentEdits.swapForTurnedImage(
            p.copyWith(
              assets: [
                for (final a in p.assets) a.id == revised.id ? revised : a,
              ],
            ),
            revised.id,
          ),
          true,
        ),
      );
    });
  }

  // ---------------------------------------------------------------------
  // Direct manipulation

  _Drag? _drag;
  bool get dragging => _drag != null;

  void startDrag(String id, {required bool resize}) {
    if (busy) return;
    final item = project.items.where((e) => e.id == id).firstOrNull;
    if (item == null || item.locked) return;
    selected
      ..clear()
      ..add(id);
    _drag = _Drag(item, resize);
    _notify();
  }

  /// [deltaMm] is the pointer travel since [startDrag], in millimetres.
  void updateDrag(Offset deltaMm) {
    final drag = _drag;
    if (drag == null) return;
    final old = drag.item;
    final DocumentItem next;
    if (drag.resize) {
      final angle = old.rotation * math.pi / 180;
      final localX =
          deltaMm.dx * math.cos(angle) + deltaMm.dy * math.sin(angle);
      final localY =
          -deltaMm.dx * math.sin(angle) + deltaMm.dy * math.cos(angle);
      final width = math.max(minDocumentEdgeMm, old.width + localX).toDouble();
      final height = math
          .max(minDocumentEdgeMm, old.height + localY)
          .toDouble();
      next = PageLayout.resize(old, width, height);
      if (next.width < minDocumentEdgeMm || next.height < minDocumentEdgeMm) {
        return;
      }
    } else {
      next = old.copyWith(x: old.x + deltaMm.dx, y: old.y + deltaMm.dy);
    }
    drag.moved = true;
    _preview = session.current.copyWith(
      items: [for (final e in session.current.items) e.id == old.id ? next : e],
    );
    _notify();
  }

  Future<void> endDrag() async {
    final drag = _drag;
    final preview = _preview;
    _drag = null;
    _preview = null;
    _notify();
    if (drag == null || preview == null || !drag.moved) return;
    final moved = PageLayout.item(preview, drag.item.id);
    await edit(
      (p) => p.copyWith(
        items: [
          for (final e in p.items)
            e.id == moved.id
                ? (drag.resize ? moved.copyWith(sizeConfirmed: true) : moved)
                : e,
        ],
      ),
      layout: drag.resize,
      manual: !drag.resize,
    );
  }

  void cancelDrag() {
    _drag = null;
    _preview = null;
    _notify();
  }

  Timer? _nudgeTimer;
  String? _nudgeId;
  double _nudgeDx = 0, _nudgeDy = 0;

  /// Arrow-key nudges show at once and are saved when the key is released.
  void nudge(double dx, double dy) {
    final item = active;
    if (item == null || item.locked || busy || _drag != null) return;
    if (item.pageIndex == null) return;
    if (_nudgeId != item.id) {
      _nudgeId = item.id;
      _nudgeDx = 0;
      _nudgeDy = 0;
    }
    _nudgeDx += dx;
    _nudgeDy += dy;
    _preview = session.current.copyWith(
      items: [
        for (final e in session.current.items)
          e.id == item.id
              ? e.copyWith(x: e.x + _nudgeDx, y: e.y + _nudgeDy)
              : e,
      ],
    );
    _notify();
    _nudgeTimer?.cancel();
    _nudgeTimer = Timer(nudgeCommitDelay, () => unawaited(_flushNudge()));
  }

  Future<void> _flushNudge() async {
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    final id = _nudgeId;
    final dx = _nudgeDx, dy = _nudgeDy;
    _nudgeId = null;
    _nudgeDx = 0;
    _nudgeDy = 0;
    _preview = null;
    if (id == null || (dx == 0 && dy == 0)) {
      _notify();
      return;
    }
    if (autoFlow) {
      autoFlow = false;
      _say(
        'أُوقف «الترتيب المستمر» لأنك رتّبت يدوياً؛ أعد تشغيله من تبويب «الرئيسية» متى شئت.',
      );
    }
    await _guard(
      () => session.apply(
        (p) => PageLayout.move(p, id, dx, dy, allowOverlap: allowOverlap),
      ),
    );
  }

  /// Writes pending nudges and picture edits (before leaving the editor).
  Future<void> flush() async {
    if (_nudgeId != null) await _flushNudge();
    if (_adjustTimer != null) await commitAdjustments();
  }

  // ---------------------------------------------------------------------
  // View

  void setZoomMode(ZoomMode mode) {
    zoomMode = mode;
    _notify();
  }

  void setZoom(double value) {
    zoom = value.clamp(minZoom, maxZoom).toDouble();
    zoomMode = ZoomMode.custom;
    _notify();
  }

  /// Updates the effective zoom computed by the view for fit modes.
  void reportEffectiveZoom(double value) {
    final next = value.clamp(minZoom, maxZoom).toDouble();
    if ((next - zoom).abs() < 1e-3) return;
    zoom = next;
    // Reported during the view's layout; listeners (the zoom read-out) are
    // told after the frame.
    SchedulerBinding.instance.addPostFrameCallback((_) => _notify());
  }

  void zoomIn() => setZoom((zoom * 1.1 * 100).round() / 100);

  void zoomOut() => setZoom((zoom / 1.1 * 100).round() / 100);

  /// Page the sheet view should scroll to on its next frame.
  int? pendingScrollPage;

  void goToPage(int page) {
    if (page < 0 || page >= project.pageCount) return;
    visiblePage = page;
    pendingScrollPage = page;
    _notify();
  }

  void reportVisiblePage(int page) {
    if (page != visiblePage && page >= 0 && page < project.pageCount) {
      visiblePage = page;
      _notify();
    }
  }
}

class _Drag {
  _Drag(this.item, this.resize);
  final DocumentItem item;
  final bool resize;
  bool moved = false;
}
