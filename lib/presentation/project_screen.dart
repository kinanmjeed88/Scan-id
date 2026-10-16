import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../application/contracts.dart';
import '../application/backup_transfer.dart';
import '../application/project_service.dart';
import '../application/image_reader.dart';
import '../domain/image_deletion.dart';
import '../domain/project.dart';
import 'shared.dart';
import 'crop_screen.dart';
import 'export_screen.dart';
import 'intake.dart';
import 'layout_screen.dart';
import 'settings_screen.dart';

class ProjectScreen extends StatefulWidget {
  const ProjectScreen({
    required this.project,
    required this.service,
    required this.pickImages,
    this.startWithImagePicker = false,
    this.recoverStorage,
    super.key,
  });
  final Project project;
  final ProjectService service;
  final PickImages pickImages;
  final bool startWithImagePicker;
  final Future<void> Function()? recoverStorage;
  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  late Project _project = widget.project;
  bool _busy = false;
  // Whether this project's recovery copy is behind its saved data. Read from
  // the copies, so it stays visible after a restart until it is repaired.
  bool _recoveryStale = false;
  bool _refreshingRecovery = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkRecoveryPoint());
    if (widget.startWithImagePicker) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_import());
      });
    }
  }

  Future<void> _checkRecoveryPoint() async {
    if (widget.service.recovery == null) {
      return;
    }
    try {
      final stale = await widget.service.staleRecoveryPoints();
      if (mounted) {
        setState(() => _recoveryStale = stale.contains(_project.id));
      }
    } catch (error) {
      // Shown, not swallowed: the user must know the copies could not be read.
      if (mounted) {
        showMessage(context, userError(error));
      }
    }
  }

  /// Rewrites this project's recovery copy from the saved data. The data is
  /// not touched; a failure is shown as an error, never as success.
  Future<void> _refreshRecovery() async {
    setState(() => _refreshingRecovery = true);
    try {
      await widget.service.refreshRecoveryPoint(_project.id);
      if (mounted) {
        showMessage(context, 'حُدّثت نقطة الاستعادة لهذا المشروع.');
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _refreshingRecovery = false);
      }
      await _checkRecoveryPoint();
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
      if (result.failures.isNotEmpty || result.notices.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('تم حفظ ${result.imported} صورة'),
            content: SingleChildScrollView(
              child: Text(importReportDetails(result)),
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
          confirmLabel: 'إعادة إنشاء النسخ',
        ) &&
        mounted) {
      await _save(() => widget.service.recovery!.rebuildDerived(_project));
    }
  }

  Future<void> _camera() async {
    setState(() => _busy = true);
    final before = _project;
    try {
      final saved = await widget.service.camera!.capture(_project.id);
      if (mounted && saved != null) {
        setState(() => _project = saved);
        showMessage(
          context,
          _captureSuccessMessage(
            saved,
            before,
            fallback: 'حُفظ الالتقاط والأصل محلياً. يمكنك الآن القص والتصحيح.',
          ),
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

  String _captureSuccessMessage(
    Project saved,
    Project before, {
    required String fallback,
  }) {
    final previousIds = before.assets.map((asset) => asset.id).toSet();
    final scaled = saved.assets
        .where(
          (asset) =>
              !previousIds.contains(asset.id) && asset.hasScaledLargeSource,
        )
        .firstOrNull;
    if (scaled == null) return fallback;
    return '${scaled.name}: حُفظ الأصل كما هو، وصُغّرت نسخة العمل إلى '
        '${scaled.width}×${scaled.height} بحد أقصى 4 ملايين بكسل.';
  }

  Future<void> _recoverCapture() async {
    setState(() => _busy = true);
    final before = _project;
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
      Uint8List? preview;
      String? previewError;
      try {
        final source = await readBoundedImage(photo.file.openRead());
        preview = await widget.service.assets.previewImage(source);
      } catch (error) {
        previewError = userError(error);
      }
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('التقاط غير مؤكد الحفظ'),
          content: SizedBox(
            width: 360,
            height: 260,
            child: preview == null
                ? Text(
                    'تعذر إنشاء معاينة آمنة؛ قد يكون الملف ناقصاً أو غير مدعوم.'
                    '${previewError == null ? '' : '\n$previewError'}',
                  )
                : Image.memory(
                    preview,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Text('تعذر عرض المعاينة.'),
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
            _captureSuccessMessage(
              saved,
              before,
              fallback: 'تم حفظ الالتقاط دون تكرار صورة سبق حفظها في المشروع.',
            ),
          );
        }
      } else if (action == 'discard' &&
          await confirm(
            context,
            'حذف الالتقاط المعلق؟',
            'سيُحذف ملف الكاميرا المؤقت نهائياً. لا تُحذف صور أي مشروع محفوظ.',
            confirmLabel: 'حذف الالتقاط',
            destructive: true,
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
          'تشمل الأصول والنسخ المعالجة السابقة وبيانات المشروع. النسخة غير مشفرة وتحتوي بيانات حساسة؛ اختر مكاناً محلياً آمناً. احفظها قبل إزالة التطبيق أو تغيير الجهاز.',
          confirmLabel: 'متابعة إلى الحفظ',
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
      await _checkRecoveryPoint();
    }
  }

  /// Takes the image's elements off the sheet and keeps the image. Locked
  /// elements are included on purpose: the confirmation names them, so the
  /// user does not have to unlock them in the editor first.
  Future<void> _removeFromSheet(ImageAsset asset) async {
    final items = _project.items.where((item) => item.assetId == asset.id);
    final count = items.length;
    final locked = items.where((item) => item.locked).length;
    final yes = await confirm(
      context,
      'إزالة الصورة من الورقة؟',
      'ستُزال $count من عناصر «${asset.name}» من ورقة A4'
          '${locked == 0 ? '' : '، منها $locked مثبّتة'}. '
          'تبقى الصورة في المشروع وملفاتها كما هي، ويمكن وضعها على الورقة مجدداً من المحرر.',
      confirmLabel: 'إزالة من الورقة',
    );
    if (!yes || !mounted) return;
    await _save(() => widget.service.removeImageFromSheet(_project, asset.id));
  }

  /// Deletes the image from the project and its files. The confirmation text
  /// is computed from the same plan the service applies, so what the user reads
  /// is what happens.
  Future<void> _deleteImage(ImageAsset asset) async {
    final ImageDeletionPlan plan;
    try {
      plan = planImageDeletion(_project, asset.id);
    } on Object catch (error) {
      if (mounted) showMessage(context, userError(error));
      return;
    }
    final yes = await confirm(
      context,
      'حذف الصورة نهائياً؟',
      _deleteImageMessage(asset, plan),
      confirmLabel: 'حذف الصورة',
      destructive: true,
    );
    if (!yes || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.service.deleteImage(_project, asset.id);
      if (mounted) {
        setState(() => _project = result.project);
        showMessage(
          context,
          result.warning ?? 'حُذفت «${asset.name}» من المشروع وملفاتها.',
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, userError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _checkRecoveryPoint();
    }
  }

  String _deleteImageMessage(ImageAsset asset, ImageDeletionPlan plan) {
    final lines = <String>[
      'ستُحذف «${asset.name}» من المشروع، وتُحذف ملفاتها داخل مساحة التطبيق.',
    ];
    if (plan.itemIds.isNotEmpty) {
      lines.add(
        'ستُزال ${plan.itemIds.length} من عناصر ورقة A4: عناصر هذه الصورة '
        'وما يرتبط بها من تعرّف؛ بقية الصفحات والعناصر لا تتغير.',
      );
    }
    if (plan.lockedItemIds.isNotEmpty) {
      lines.add(
        'منها ${plan.lockedItemIds.length} مثبّتة، وستُزال دون فك تثبيتها أولاً.',
      );
    }
    if (plan.dismissedDocumentIds.isNotEmpty) {
      lines.add(
        'تُزال أيضاً المناطق المستبعدة سابقاً (${plan.dismissedDocumentIds.length}). '
        'قرارات الاستبعاد هذه تُحذف مع الصورة؛ إن استوردت الملف نفسه لاحقاً '
        'فقد تظهر هذه المناطق للمراجعة من جديد.',
      );
    }
    if (plan.keptDerivedAssetIds.isNotEmpty) {
      lines.add(
        'الصور المشتقة منها (${plan.keptDerivedAssetIds.length}) تبقى في المشروع '
        'كصور مستقلة، دون ربطها بهذه الصورة.',
      );
    }
    lines.add(
      'لا تُحذف النسخ الاحتياطية السابقة ولا نقاط الاستعادة. '
      'لا يمكن التراجع عن الحذف من داخل التطبيق.',
    );
    return lines.join('\n');
  }

  Future<void> _openExport() async {
    if (_busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ExportScreen(project: _project, service: widget.service),
      ),
    );
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
    final placed = _project.items.where((item) => item.assetId == asset.id);
    final onSheet = placed.isNotEmpty;
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
              '${index + 1}/${_project.assets.length} · ${asset.width} × ${asset.height} px\n'
              '${onSheet ? 'على الورقة: ${placed.length} عناصر' : 'غير موضوعة على الورقة'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<_AssetAction>(
              tooltip: 'خيارات الصورة',
              enabled: !_busy,
              onSelected: (action) => switch (action) {
                _AssetAction.replace => unawaited(_replace(asset)),
                _AssetAction.moveUp => unawaited(_move(asset, index - 1)),
                _AssetAction.moveDown => unawaited(_move(asset, index + 1)),
                _AssetAction.removeFromSheet => unawaited(
                  _removeFromSheet(asset),
                ),
                _AssetAction.delete => unawaited(_deleteImage(asset)),
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
                if (onSheet)
                  const PopupMenuItem(
                    value: _AssetAction.removeFromSheet,
                    child: Text('إزالة من الورقة (تبقى الصورة)'),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: _AssetAction.delete,
                  child: Text(
                    'حذف الصورة نهائياً',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
        final replacementMessage = report.aspectChanged
            ? 'استُبدلت الصورة. نسبة الأبعاد تغيّرت؛ راجع مقاس المستطيل في محرر A4 قبل التصدير.'
            : 'استُبدلت الصورة، وبقيت مواضعها في ورقة A4 كما هي.';
        showMessage(
          context,
          [
            if (report.scalingMessage != null) report.scalingMessage!,
            replacementMessage,
          ].join('\n'),
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
            tooltip: 'الإعدادات',
            onPressed: _busy ? null : _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
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
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'الورقة والتصدير',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _project.items.isEmpty
                                    ? 'لا يمكن استنتاج المقاس الحقيقي من الصورة وحدها؛ عيّنه في محرر الورقة.'
                                    : '${_project.items.length} عناصر بمقاسات mm محفوظة في محرر الورقة.',
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  FilledButton.icon(
                                    onPressed: _busy ? null : _layout,
                                    icon: const Icon(
                                      Icons.description_outlined,
                                    ),
                                    label: const Text('محرر ورقة A4'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _busy ? null : _openExport,
                                    icon: const Icon(Icons.print_outlined),
                                    label: const Text('تصدير وطباعة'),
                                  ),
                                  if (widget.service.camera != null)
                                    OutlinedButton.icon(
                                      onPressed: _busy ? null : _camera,
                                      icon: const Icon(
                                        Icons.camera_alt_outlined,
                                      ),
                                      label: const Text('التقاط بالكاميرا'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_recoveryStale) ...[
                        const SizedBox(height: 12),
                        InfoBanner(
                          tone: BannerTone.caution,
                          title: 'نقطة الاستعادة متأخرة',
                          message:
                              'البيانات محفوظة في المشروع، لكن نسخة الاستعادة المحلية لهذا المشروع لم تُحدَّث بعد. '
                              'لا تعتمد عليها إن فقدت قاعدة البيانات قبل تحديثها.',
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: OutlinedButton.icon(
                            onPressed: _refreshingRecovery
                                ? null
                                : () => unawaited(_refreshRecovery()),
                            icon: const Icon(Icons.refresh),
                            label: const Text('تحديث نقطة الاستعادة'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Card(
                        child: ExpansionTile(
                          title: const Text('البيانات والصيانة'),
                          subtitle: const Text(
                            'أدوات تخص هذا المشروع وحده؛ اضغط ⓘ لتعرف ماذا تفعل '
                            'قبل أن تضغطها.',
                          ),
                          childrenPadding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            16,
                          ),
                          children: [
                            const InfoBanner(
                              tone: BannerTone.caution,
                              title: 'النسخ الاحتياطية غير مشفرة',
                              message:
                                  'احفظ نسخة احتياطية قبل إزالة التطبيق أو تغيير الجهاز. النسخة تحتوي بيانات حساسة؛ اختر مكاناً محلياً آمناً.',
                            ),
                            const SizedBox(height: 12),
                            if (widget.service.backups != null)
                              ExplainedAction(
                                icon: Icons.backup_outlined,
                                title: 'نسخة احتياطية كاملة',
                                summary:
                                    'يحفظ هذا المشروع بجميع صوره ومخططاته في ملف '
                                    'تختار مكانه.',
                                details:
                                    'ما الذي يُنسخ: الصور الأصلية ونسخ العمل ومخطط '
                                    'الورقة وتعديلات الصور وكل بيانات هذا المشروع، '
                                    'في ملف واحد.\n\n'
                                    'ما لن يحدث: لا يُحذف شيء ولا تُعدَّل صورة؛ '
                                    'المشاريع الأخرى لا تُمسّ.\n\n'
                                    'متى تحتاجها: قبل إزالة التطبيق أو تغيير الجهاز '
                                    'أو إعادة تثبيت النظام.',
                                onTap: _busy ? null : _backup,
                              ),
                            if (widget.service.recovery != null)
                              ExplainedAction(
                                icon: Icons.healing,
                                title: 'إصلاح النسخ من الأصول',
                                summary:
                                    'يعيد إنشاء نسخ العمل القصيرة من الصور الأصلية، '
                                    'ولا يغيّر الأصول.',
                                details:
                                    'لماذا توجد: من كل صورة يحتفظ التطبيق بالأصل '
                                    'كما هو، وبنسخة عمل مصغّرة تُقصّ وتُعدَّل. إذا '
                                    'فُقدت نسخة عمل أو فسدت بعد خطأ تخزين أو صيانة '
                                    'ناقصاً؛ تظهر الصورة في المشروع ولا تُفتح.\n\n'
                                    'ما الذي يفعله: يقرأ الأصل ويعيد إنشاء نسخ العمل '
                                    'بالوصفة المحفوظة نفسها (نفس نقاط القص ونفس '
                                    'التعديلات).\n\n'
                                    'ما الذي لا يتغير: الصور الأصلية، ومخطط الورقة، '
                                    'وأماكن الصور ومقاساتها. إن كان الأصل نفسه مفقوداً '
                                    'فلا شيء يُصلَح هنا؛ استعد نسخة احتياطية.\n\n'
                                    'بعدها راجع الصور الناتجة: قد يختلف لون النسخة '
                                    'قليداً لأن إعادة الترميز تقريبية.',
                                onTap: _busy ? null : _repairImages,
                              ),
                            if (widget.service.camera != null)
                              ExplainedAction(
                                icon: Icons.history,
                                title: 'استرداد التقاط معلق',
                                summary:
                                    'يُظهر صورة التقطتها بالكاميرا ولم يُؤكَّد حفظها، '
                                    'ليحفظها أو يحذفها.',
                                details:
                                    'من أين تأتي: الضغط على الكاميرا يكتب الصورة في '
                                    'ملف مؤقت أولاً، ولا تدخل المشروع إلا بعد أن '
                                    'تؤكّدها. إن أُغلق التطبيق أو الكاميرا في تلك '
                                    'اللحظة تبقى الصورة معلقة.\n\n'
                                    'ما الذي تراه هنا: معاينة للملف المعلق وثلاثة '
                                    'مسارات: حفظها في هذا المشروع، أو حذف الملف '
                                    'المؤقت، أو الإغلاق وتركها لهذه الأداة.\n\n'
                                    'لا تكرار: صورة حُفظت في المشروع من قبل لا تُحفظ '
                                    'مرة ثانية؛ الحذف يخص الملف المؤقت وحده ولا يمس '
                                    'أي صورة محفوظة.',
                                onTap: _busy ? null : _recoverCapture,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'الصور: ${_project.assets.length} · JPEG / PNG · 16 مليون بكسل مباشرة؛ JPEG حتى 32 مليوناً بنسخة عمل مصغّرة',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _busy
                            ? 'جارٍ العمل والحفظ محلياً… يرجى عدم إغلاق التطبيق.'
                            : 'تم حفظ الحالة المعروضة محلياً.',
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
                          ? 270
                          : 310,
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

  Future<void> _openSettings() async {
    if (_busy || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          service: widget.service,
          recoverStorage: widget.recoverStorage,
        ),
      ),
    );
    if (mounted) {
      final project = await widget.service.projects.get(_project.id);
      setState(() {
        _project = project;
      });
    }
  }
}

enum _AssetAction { replace, moveUp, moveDown, removeFromSheet, delete }

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
            segments: [
              const ButtonSegment(value: false, label: Text('نسخة العمل')),
              ButtonSegment(
                value: true,
                label: Text(
                  widget.asset.hasScaledLargeSource
                      ? 'معاينة المصدر الآمنة'
                      : 'الأصل المحفوظ',
                ),
              ),
            ],
            selected: {_original},
            onSelectionChanged: (value) =>
                setState(() => _original = value.single),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            widget.asset.hasScaledLargeSource
                ? 'الأصل محفوظ كما وصل. لمنع فك صورة كبيرة كاملة، تعرض معاينة المصدر نسخة عمل مصغّرة وموجّهة؛ التكبير لا يضيف تفاصيل.'
                : 'معاينة فقط؛ نسخة العمل تصحح اتجاه EXIF دون تعديل الأصل. التكبير لا يضيف تفاصيل للصورة.',
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
                    ? widget.asset.processingInputPath
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
