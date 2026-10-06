import 'dart:io';

import 'package:flutter/material.dart';

import '../application/contracts.dart';
import '../application/backup_transfer.dart';
import '../application/project_service.dart';
import '../domain/project.dart';
import 'app.dart';
import 'shared.dart';
import 'crop_screen.dart';
import 'layout_screen.dart';

class ProjectScreen extends StatefulWidget {
  const ProjectScreen({
    required this.project,
    required this.service,
    required this.pickImages,
    super.key,
  });
  final Project project;
  final ProjectService service;
  final PickImages pickImages;
  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  late Project _project = widget.project;
  bool _busy = false;

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final sources = await widget.pickImages();
      if (sources.isEmpty) {
        return;
      }
      final result = await widget.service.importImages(_project, sources);
      if (!mounted) {
        return;
      }
      setState(() => _project = result.project);
      if (result.failures.isEmpty) {
        showMessage(context, 'تم استيراد وحفظ ${result.imported} صورة.');
      } else {
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

  Future<void> _layout() async {
    final saved = await Navigator.of(context).push<Project>(
      MaterialPageRoute(
        builder: (_) =>
            LayoutScreen(project: _project, service: widget.service),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.icon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('إضافة صور'),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
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
                    const Text(
                      'لم يتم تعيين مقاسات طباعة للصور. لا يمكن استنتاج المقاس الحقيقي من الصورة وحدها.',
                    ),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              Expanded(
                child: _project.assets.isEmpty
                    ? const EmptyState(
                        icon: Icons.add_photo_alternate_outlined,
                        title: 'أضف صور المستمسكات',
                        message:
                            'اختر صورة أو عدة صور من الجهاز. تُنسخ الأصول إلى مساحة المشروع وتُنشأ صور مصغرة للعرض.',
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 280,
                          mainAxisExtent: widget.service.imageEditor == null
                              ? 250
                              : 290,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: _project.assets.length,
                        itemBuilder: (context, index) {
                          final asset = _project.assets[index];
                          return Card(
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
                                    onPressed: _busy
                                        ? null
                                        : () => _crop(asset),
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
                                    '${asset.width} × ${asset.height} px',
                                    textDirection: TextDirection.ltr,
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'إزالة الصورة',
                                    onPressed: _busy
                                        ? null
                                        : () => _remove(asset),
                                    icon: const Icon(Icons.close),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

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
