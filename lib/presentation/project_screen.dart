import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../application/contracts.dart';
import '../application/backup_transfer.dart';
import '../application/project_service.dart';
import '../domain/project.dart';
import 'app.dart';
import 'shared.dart';
import 'crop_screen.dart';
import 'intake.dart';
import 'layout_screen.dart';

class ProjectScreen extends StatefulWidget {
  const ProjectScreen({
    required this.project,
    required this.service,
    required this.pickImages,
    this.startWithImagePicker = false,
    super.key,
  });
  final Project project;
  final ProjectService service;
  final PickImages pickImages;
  final bool startWithImagePicker;
  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  late Project _project = widget.project;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.startWithImagePicker) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_import());
      });
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final sources = await widget.pickImages();
      if (sources.isEmpty || !mounted) return;
      // The shared runner gives the project screen the same real progress,
      // cooperative cancellation and committed final state as the editor.
      final run = await runIntakeWithProgress(
        context,
        service: widget.service,
        project: _project,
        sources: sources,
      );
      if (!mounted || run == null) return;
      final result = run.import;
      final latest = run.project;
      final automatic = run.layout;
      setState(() => _project = latest);
      final failure = run.error;
      if (failure != null && mounted) {
        showMessage(context, userError(failure));
      }
      if (result.failures.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('تم حفظ ${result.imported} صورة'),
            content: SingleChildScrollView(
              child: Text(
                result.failures
                    .map((f) => '${f.name}: ${f.message}')
                    .join('\n\n'),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('حسناً'),
              ),
            ],
          ),
        );
      }
      if (result.imported > 0 && mounted) {
        final summary = automatic == null
            ? 'استورد التطبيق الصور، لكن تعذر الترتيب التلقائي.'
            : intakeSummaryText(automatic);
        await _layout(
          intakeSummary: summary,
          intakeWarnings: automatic?.warnings ?? const [],
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, userError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _repairImages() async {
    if (await confirm(
          context,
          'إعادة إنشاء النسخ المعالجة؟',
          'ستنشأ نسخ جديدة من الأصول باستخدام وصفات القص المحفوظة. تبقى النسخ القديمة والأصول ومقاسات الورقة؛ راجع الصور الناتجة. إذا كان الأصل مفقوداً أو فاسداً فاستعد نسختك الاحتياطية.',
        ) &&
        mounted) {
      await _save(() => widget.service.recovery!.rebuildDerived(_project));
    }
  }

  Future<void> _camera() async {
    setState(() => _busy = true);
    try {
      final saved = await widget.service.camera!.capture(_project.id);
      if (mounted && saved != null) {
        setState(() => _project = saved);
        showMessage(
          context,
          'حُفظ الالتقاط والأصل محلياً. يمكنك الآن القص والتصحيح.',
        );
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _recoverCapture() async {
    setState(() => _busy = true);
    try {
      final camera = widget.service.camera!;
      final photo = await camera.port.pending();
      if (!mounted) {
        return;
      }
      if (photo == null) {
        showMessage(context, 'لا يوجد التقاط معلق.');
        return;
      }
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('التقاط غير مؤكد الحفظ'),
          content: SizedBox(
            width: 360,
            height: 260,
            child: Image.file(
              photo.file,
              cacheWidth: 1200,
              errorBuilder: (_, _, _) =>
                  const Text('تعذر عرض الالتقاط؛ قد يكون ناقصاً أو مفقوداً.'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('حذف الالتقاط المؤقت'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'accept'),
              child: const Text('استيراد إلى هذا المشروع'),
            ),
          ],
        ),
      );
      if (!mounted) {
        return;
      }
      if (action == 'accept') {
        final saved = await camera.accept(photo, _project.id);
        if (mounted) {
          setState(() => _project = saved);
          showMessage(
            context,
            'تم حفظ الالتقاط دون تكرار صورة سبق حفظها في المشروع.',
          );
        }
      } else if (action == 'discard' &&
          await confirm(
            context,
            'حذف الالتقاط المعلق؟',
            'سيُحذف ملف الكاميرا المؤقت نهائياً. لا تُحذف صور أي مشروع محفوظ.',
          )) {
        await camera.port.discard(photo.id);
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _backup() async {
    if (!await confirm(
          context,
          'نسخة احتياطية كاملة؟',
          'تشمل الأصول والنسخ المعالجة السابقة وبيانات المشروع. النسخة غير مشفرة وتحتوي بيانات حساسة؛ اختر مكاناً محلياً آمناً.',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final saved = await BackupTransfer(
        widget.service.backups!,
      ).save(_project);
      if (mounted) {
        showMessage(
          context,
          saved ? 'حُفظت النسخة الاحتياطية الكاملة.' : 'أُلغي حفظ النسخة.',
        );
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _rename() async {
    final name = await askName(
      context,
      title: 'إعادة تسمية المشروع',
      initial: _project.name,
    );
    if (name == null || !mounted) {
      return;
    }
    await _save(() => widget.service.rename(_project, name));
  }

  Future<void> _save(Future<Project> Function() operation) async {
    setState(() => _busy = true);
    try {
      final saved = await operation();
      if (mounted) {
        setState(() => _project = saved);
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _remove(ImageAsset asset) async {
    final yes = await confirm(
      context,
      'إزالة الصورة من المشروع؟',
      'ستُزال «${asset.name}» من قائمة الصور فقط. لن يُحذف الأصل من جهازك أو نسخته المحلية.',
    );
    if (yes && mounted) {
      await _save(() => widget.service.removeAsset(_project, asset.id));
    }
  }

  Future<void> _crop(ImageAsset asset) async {
    final saved = await Navigator.of(context).push<Project>(
      MaterialPageRoute(
        builder: (_) => CropScreen(
          project: _project,
          asset: asset,
          service: widget.service,
        ),
      ),
    );
    if (saved != null && mounted) {
      setState(() => _project = saved);
    }
  }

  Future<void> _layout({
    String? intakeSummary,
    List<String> intakeWarnings = const [],
  }) async {
    final saved = await Navigator.of(context).push<Project>(
      MaterialPageRoute(
        builder: (_) => LayoutScreen(
          project: _project,
          service: widget.service,
          pickImages: widget.pickImages,
          intakeSummary: intakeSummary,
          intakeWarnings: intakeWarnings,
        ),
      ),
    );
    if (saved != null && mounted) setState(() => _project = saved);
  }

  Future<void> _view(ImageAsset asset) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            AssetViewer(asset: asset, repository: widget.service.assets),
      ),
    );
  }

  /// Drag reorder for pointing devices, long-press reorder for touch, plus an
  /// explicit menu so reordering is reachable without a drag gesture.
  Widget _assetCard(int index) {
    final asset = _project.assets[index];
    final card = Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: InkWell(
              onTap: _busy ? null : () => _view(asset),
              child: SizedBox.expand(
                child: LocalImage(
                  repository: widget.service.assets,
                  path: asset.thumbnailPath,
                  cacheWidth: 320,
                ),
              ),
            ),
          ),
          if (widget.service.imageEditor != null)
            TextButton.icon(
              onPressed: _busy ? null : () => _crop(asset),
              icon: const Icon(Icons.crop),
              label: const Text('قص وتصحيح'),
            ),
          ListTile(
            dense: true,
            title: Text(
              asset.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${index + 1}/${_project.assets.length} · ${asset.width} × ${asset.height} px',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.ltr,
            ),
            trailing: PopupMenuButton<_AssetAction>(
              tooltip: 'خيارات الصورة',
              enabled: !_busy,
              onSelected: (action) => switch (action) {
                _AssetAction.replace => unawaited(_replace(asset)),
                _AssetAction.moveUp => unawaited(_move(asset, index - 1)),
                _AssetAction.moveDown => unawaited(_move(asset, index + 1)),
                _AssetAction.remove => unawaited(_remove(asset)),
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _AssetAction.replace,
                  child: Text('استبدال الصورة بأخرى'),
                ),
                PopupMenuItem(
                  value: _AssetAction.moveUp,
                  enabled: index > 0,
                  child: const Text('نقل إلى ترتيب أسبق'),
                ),
                PopupMenuItem(
                  value: _AssetAction.moveDown,
                  enabled: index + 1 < _project.assets.length,
                  child: const Text('نقل إلى ترتيب لاحق'),
                ),
                const PopupMenuItem(
                  value: _AssetAction.remove,
                  child: Text('إزالة من قائمة الصور'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final draggable = _isDesktop
        ? Draggable<String>(
            data: asset.id,
            feedback: _dragFeedback(asset),
            child: card,
          )
        : LongPressDraggable<String>(
            data: asset.id,
            feedback: _dragFeedback(asset),
            child: card,
          );
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => !_busy && details.data != asset.id,
      onAcceptWithDetails: (details) =>
          unawaited(_moveToIndex(details.data, index)),
      builder: (context, candidates, rejected) => Stack(
        children: [
          if (candidates.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                  ),
                ),
              ),
            ),
          draggable,
        ],
      ),
    );
  }

  Widget _dragFeedback(ImageAsset asset) => Material(
    elevation: 4,
    child: SizedBox(
      width: 180,
      height: 180,
      child: LocalImage(
        repository: widget.service.assets,
        path: asset.thumbnailPath,
        cacheWidth: 320,
      ),
    ),
  );

  Future<void> _moveToIndex(String assetId, int target) async {
    if (_busy) {
      return;
    }
    await _save(() => widget.service.moveAsset(_project, assetId, target));
  }

  Future<void> _move(ImageAsset asset, int target) async {
    if (target < 0 || target >= _project.assets.length) {
      return;
    }
    await _moveToIndex(asset.id, target);
  }

  Future<void> _replace(ImageAsset asset) async {
    setState(() => _busy = true);
    try {
      final sources = await widget.pickImages();
      if (sources.isEmpty || !mounted) {
        return;
      }
      final report = await widget.service.replaceImage(
        _project,
        asset,
        sources.first,
      );
      await widget.service.discardSources(sources.skip(1));
      if (mounted) {
        setState(() => _project = report.project);
        showMessage(
          context,
          report.aspectChanged
              ? 'استُبدلت الصورة. نسبة الأبعاد تغيّرت؛ راجع مقاس المستطيل في محرر A4 قبل التصدير.'
              : 'استُبدلت الصورة، وبقيت مواضعها في ورقة A4 كما هي.',
        );
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(_project.name),
        actions: [
          IconButton(
            tooltip: 'إعادة تسمية المشروع',
            onPressed: _busy ? null : _rename,
            icon: const Icon(Icons.edit_outlined),
          ),
          AdaptableAction(
            label: 'إضافة صور',
            icon: Icons.add_photo_alternate_outlined,
            onPressed: _busy ? null : _import,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const FoundationNotice(),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _layout,
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('تحرير ورقة A4'),
                      ),
                      if (widget.service.recovery != null)
                        TextButton.icon(
                          onPressed: _busy ? null : _repairImages,
                          icon: const Icon(Icons.healing),
                          label: const Text('إصلاح النسخ من الأصول'),
                        ),
                      if (widget.service.recovery?.warning != null)
                        Text(widget.service.recovery!.warning!),
                      if (widget.service.camera != null)
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _camera,
                              icon: const Icon(Icons.camera_alt_outlined),
                              label: const Text('التقاط بالكاميرا'),
                            ),
                            TextButton(
                              onPressed: _busy ? null : _recoverCapture,
                              child: const Text('استرداد التقاط معلق'),
                            ),
                          ],
                        ),
                      if (widget.service.backups != null)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _backup,
                          icon: const Icon(Icons.backup_outlined),
                          label: const Text('نسخة احتياطية كاملة'),
                        ),
                      const SizedBox(height: 16),
                      Text(
                        '${_project.assets.length} صور · JPEG / PNG · حتى 16 مليون بكسل للصورة',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _busy
                            ? 'جارٍ العمل والحفظ محلياً… يرجى عدم إغلاق التطبيق.'
                            : 'تم حفظ الحالة المعروضة محلياً.',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _project.items.isEmpty
                            ? 'لا يمكن استنتاج المقاس الحقيقي من الصورة وحدها؛ عيّنه في محرر الورقة.'
                            : '${_project.items.length} عناصر بمقاسات mm محفوظة في محرر الورقة.',
                      ),
                    ],
                  ),
                ),
              ),
              if (_busy)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
              if (_project.assets.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.add_photo_alternate_outlined,
                    title: 'أضف صور المستمسكات',
                    message:
                        'اختر صورة أو عدة صور من الجهاز. تُحفظ الأصول ونسخ العمل مستقلة.',
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 280,
                      mainAxisExtent: widget.service.imageEditor == null
                          ? 250
                          : 290,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _assetCard(index),
                      childCount: _project.assets.length,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum _AssetAction { replace, moveUp, moveDown, remove }

/// Pointing devices drag immediately; touch keeps long-press so the grid still
/// scrolls normally.
bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class LocalImage extends StatefulWidget {
  const LocalImage({
    required this.repository,
    required this.path,
    required this.cacheWidth,
    super.key,
  });
  final AssetRepository repository;
  final String path;
  final int cacheWidth;
  @override
  State<LocalImage> createState() => _LocalImageState();
}

class _LocalImageState extends State<LocalImage> {
  late Future<File> _file = widget.repository.resolve(widget.path);
  @override
  void didUpdateWidget(LocalImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.repository != widget.repository) {
      _file = widget.repository.resolve(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: _file,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Center(child: Text('الصورة مفقودة أو غير قابلة للقراءة'));
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      return Image.file(
        snapshot.requireData,
        fit: BoxFit.contain,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (_, _, _) => const Center(child: Text('تعذر عرض الصورة')),
      );
    },
  );
}

class AssetViewer extends StatefulWidget {
  const AssetViewer({required this.asset, required this.repository, super.key});
  final ImageAsset asset;
  final AssetRepository repository;
  @override
  State<AssetViewer> createState() => _AssetViewerState();
}

class _AssetViewerState extends State<AssetViewer> {
  bool _original = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.asset.name)),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('نسخة العمل')),
              ButtonSegment(value: true, label: Text('الأصل المحفوظ')),
            ],
            selected: {_original},
            onSelectionChanged: (value) =>
                setState(() => _original = value.single),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'معاينة فقط؛ نسخة العمل تصحح اتجاه EXIF دون تعديل الأصل. التكبير لا يضيف تفاصيل للصورة.',
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(
              child: LocalImage(
                repository: widget.repository,
                path: _original
                    ? widget.asset.originalPath
                    : widget.asset.workingPath,
                cacheWidth: 1800,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
