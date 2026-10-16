import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/backup_transfer.dart';
import '../application/cancellation.dart';
import '../application/image_reader.dart';
import '../application/ota_update.dart';
import '../application/project_service.dart';
import '../domain/project.dart';
import 'shared.dart';
import 'export_screen.dart';
import 'layout_screen.dart';

typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);
typedef SaveBackup = Future<bool> Function(Project project);

/// صفحة الإعدادات المستقلة التي تجمع إدارة البيانات والمعلومات والصيانة.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.project,
    required this.service,
    required this.pickImages,
    required this.recoverStorage,
    this.launchExternalUrl,
    this.restoreBackup,
    this.saveBackup,
    super.key,
  });

  final Project project;
  final ProjectService service;
  final PickImages pickImages;
  final Future<void> Function()? recoverStorage;
  final ExternalUrlLauncher? launchExternalUrl;
  final Future<Project?> Function()? restoreBackup;
  final SaveBackup? saveBackup;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Project _project = widget.project;
  bool _busy = false;
  bool _recoveryStale = false;

  @override
  void initState() {
    super.initState();
    _checkRecoveryPoint();
  }

  Future<void> _checkRecoveryPoint() async {
    if (widget.service.recovery == null) return;
    try {
      final stale = await widget.service.staleRecoveryPoints();
      if (mounted) {
        setState(() => _recoveryStale = stale.contains(_project.id));
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    }
  }

  Future<void> _refreshRecovery() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
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
        setState(() => _busy = false);
        await _checkRecoveryPoint();
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
      final saved = widget.saveBackup == null
          ? await BackupTransfer(widget.service.backups!).save(_project)
          : await widget.saveBackup!.call(_project);
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
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _repairImages() async {
    if (!await confirm(
          context,
          'إعادة إنشاء النسخ المعالجة؟',
          'ستنشأ نسخ جديدة من الأصول باستخدام وصفات القص المحفوظة. تبقى النسخ القديمة والأصول ومقاسات الورقة؛ راجع الصور الناتجة. إذا كان الأصل مفقوداً أو فاسداً فاستعد نسختك الاحتياطية.',
          confirmLabel: 'إعادة إنشاء النسخ',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.service.recovery!.rebuildDerived(_project);
      if (mounted) {
        showMessage(context, 'حُدّثت النسخ المعالجة.');
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
                    '${previewError == null ? '' : '\\n$previewError'}',
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
          showMessage(context, 'تم حفظ الالتقاط.');
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
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLayout() async {
    if (_busy || !mounted) return;
    final updated = await Navigator.of(context).push<Project>(
      MaterialPageRoute(
        builder: (_) => LayoutScreen(
          project: _project,
          service: widget.service,
          pickImages: widget.pickImages,
        ),
      ),
    );
    if (mounted && updated != null) {
      setState(() => _project = updated);
    }
  }

  Future<void> _openExport() async {
    if (_busy || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ExportScreen(project: _project, service: widget.service),
      ),
    );
  }

  Future<void> _maintenance() async {
    setState(() => _busy = true);
    try {
      final orphans = await widget.service.findOrphans();
      if (!mounted) {
        return;
      }
      final kept = orphans.retained.isEmpty
          ? ''
          : '\\nمحفوظة ولن تُحذف: ${orphans.retained.length} عنصر تشير إليه '
                'نقطة استرداد أو نسخة ترقية ما زالت قائمة. تُحذف بعد تحديث تلك النقطة.';
      if (orphans.count == 0) {
        showMessage(context, 'لا ملفات غير مرتبطة بمشاريعك.$kept');
        return;
      }
      final megabytes = (orphans.bytes / (1024 * 1024)).toStringAsFixed(2);
      final yes = await confirm(
        context,
        'حذف الملفات غير المرتبطة؟',
        'عدد العناصر: ${orphans.count} · الحجم: $megabytes MiB.\\n'
            'هي ملفات أنشأها التطبيق ولم تعد مرتبطة بأي مشروع محفوظ، مثل صور مشاريع محذوفة أو نسخ معالجة قديمة أو بقايا عمل منقطع. '
            'لا تُحذف ملفات المشاريع الحالية ولا ملفات جهازك. تُتجاهل الملفات الأحدث من عشر دقائق حمايةً لعمل جارٍ.$kept',
        confirmLabel: 'حذف الملفات',
        destructive: true,
      );
      if (!yes || !mounted) {
        return;
      }
      final removed = await widget.service.deleteOrphans();
      if (mounted) {
        showMessage(context, 'أُزيل $removed من ${orphans.count} عناصر.');
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recoverDatabase() async {
    if (await confirm(
      context,
      'استرداد قاعدة المشاريع؟',
      'ستُستعاد نقاط الحفظ إلى قاعدة جديدة مع إبقاء القديمة والصور. قد تختلف آخر تغييرات غير مكتملة. إن كانت البيانات من إصدار أحدث فحدّث التطبيق أولاً.',
      confirmLabel: 'استرداد القاعدة',
    )) {
      await widget.recoverStorage?.call();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
        leading: IconButton(
          tooltip: 'رجوع',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _projectSection()),
          SliverToBoxAdapter(child: _dataAndMaintenanceSection()),
          SliverToBoxAdapter(child: _developerSection()),
          SliverToBoxAdapter(child: _updateSection()),
          if (_busy) const SliverToBoxAdapter(child: LinearProgressIndicator()),
        ],
      ),
    ),
  );

  Widget _projectSection() => Padding(
    padding: const EdgeInsets.all(20),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('مشروع حالي', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('${_project.name} · ${_project.assets.length} صور'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _openLayout,
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('محرر ورقة A4'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openExport,
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('تصدير وطباعة'),
                ),
                if (widget.service.camera != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _captureFromSettings,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('التقاط بالكاميرا'),
                  ),
              ],
            ),
            if (_recoveryStale) ...[
              const SizedBox(height: 12),
              const InfoBanner(
                tone: BannerTone.caution,
                title: 'نقطة الاستعادة متأخرة',
                message:
                    'البيانات محفوظة في المشروع، لكن نسخة الاستعادة المحلية لهذا المشروع لم تُحدَّث بعد. '
                    'لا تعتمد عليها إن فقدت قاعدة البيانات قبل تحديثها.',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _refreshRecovery,
                icon: const Icon(Icons.refresh),
                label: const Text('تحديث نقطة الاستعادة'),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _dataAndMaintenanceSection() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'البيانات والصيانة',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'نسخة احتياطية كاملة، واستعادة النسخة الاحتياطية، واسترداد قاعدة المشاريع من نقاط الحفظ، '
              'وصيانة المساحة والملفات غير المرتبطة.',
            ),
            const SizedBox(height: 12),
            const InfoBanner(
              tone: BannerTone.caution,
              message:
                  'احفظ نسخة احتياطية قبل إزالة التطبيق أو تغيير الجهاز. النسخ غير مشفرة وتحتوي بيانات حساسة؛ اختر مكاناً محلياً آمناً.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (widget.service.backups != null || widget.saveBackup != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _backup,
                    icon: const Icon(Icons.backup_outlined),
                    label: const Text('نسخة احتياطية كاملة'),
                  ),
                if (widget.service.backups != null ||
                    widget.restoreBackup != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _restoreBackup,
                    icon: const Icon(Icons.restore),
                    label: const Text('استعادة نسخة احتياطية'),
                  ),
                if (widget.service.recovery != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _repairImages,
                    icon: const Icon(Icons.healing),
                    label: const Text('إصلاح النسخ من الأصول'),
                  ),
                if (widget.service.camera != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _recoverCapture,
                    icon: const Icon(Icons.history),
                    label: const Text('استرداد التقاط معلق'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _maintenance,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('صيانة المساحة والملفات غير المرتبطة'),
                ),
                if (widget.recoverStorage != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _recoverDatabase,
                    icon: const Icon(Icons.history),
                    label: const Text('استرداد قاعدة المشاريع من نقاط الحفظ'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _developerSection() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.person_outlined, size: 24),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'البيانات الشخصية',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'مطور التطبيق',
                        style: TextStyle(color: Color(0xFF666666)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _DeveloperInfo(
              nameArabic: 'كنان الصائغ',
              nameEnglish: 'Kinan Al-Sayegh',
              status: 'التطبيق مدفوع - نسخة مستقرة',
            ),
            const SizedBox(height: 20),
            const Text(
              'تواصل مع المطور',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            _ContactCards(launchExternalUrl: widget.launchExternalUrl),
            const SizedBox(height: 8),
            const InfoBanner(
              tone: BannerTone.info,
              message:
                  'يمكنك فتح هذه الروابط خارج التطبيق. لا يشترط الاتصال لاستخدام التطبيق.',
            ),
          ],
        ),
      ),
    ),
  );

  Widget _updateSection() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
    child: _OtaUpdateCard(
      busy: _busy,
      onBusyChanged: (value) {
        if (mounted) setState(() => _busy = value);
      },
      launchExternalUrl: widget.launchExternalUrl,
    ),
  );

  Future<void> _captureFromSettings() async {
    setState(() => _busy = true);
    try {
      final saved = await widget.service.camera!.capture(_project.id);
      if (mounted && saved != null) {
        setState(() => _project = saved);
        showMessage(context, 'حُفظ الالتقاط والأصل محلياً.');
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreBackup() async {
    if (!await confirm(
          context,
          'استعادة نسخة احتياطية؟',
          'اختر ملف Scan ID محلياً موثوقاً. تُستعاد الصور والبيانات كمشروع جديد؛ لن يُستبدل أي مشروع موجود.',
          confirmLabel: 'اختيار ملف',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final project = widget.restoreBackup == null
          ? await BackupTransfer(widget.service.backups!).restore()
          : await widget.restoreBackup!.call();
      if (mounted && project != null) {
        showMessage(context, 'استُعيد المشروع كاملاً كنسخة مستقلة.');
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // OTA helpers are handled by _OtaUpdateCard below.
}

class _OtaUpdateCard extends StatefulWidget {
  const _OtaUpdateCard({
    required this.busy,
    required this.onBusyChanged,
    this.launchExternalUrl,
    this.source,
    this.currentVersion,
  });

  final bool busy;
  final ValueChanged<bool> onBusyChanged;
  final ExternalUrlLauncher? launchExternalUrl;
  final UpdateSource? source;
  final String? currentVersion;

  @override
  State<_OtaUpdateCard> createState() => _OtaUpdateCardState();
}

class _OtaUpdateCardState extends State<_OtaUpdateCard> {
  static const String _appVersion = '0.1.0';
  static const String _owner = 'kinanmjeed88';
  static const String _repo = 'Scan-id';

  UpdateInfo? _pendingUpdate;
  String? _statusMessage;
  double _progress = 0;
  bool _checking = false;
  bool _downloading = false;
  CancellationToken? _cancelToken;

  UpdatePlatform get _platform {
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isWindows) return UpdatePlatform.windows;
    return UpdatePlatform.android;
  }

  UpdateSource get _source =>
      widget.source ??
      GitHubUpdateSource(owner: _owner, repo: _repo);

  String get _version => widget.currentVersion ?? _appVersion;

  Future<void> _check() async {
    if (_checking || _downloading || widget.busy) return;
    setState(() {
      _checking = true;
      _statusMessage = null;
      _pendingUpdate = null;
    });
    widget.onBusyChanged(true);
    try {
      final service = UpdateService(
        source: _source,
        currentVersion: _version,
        platform: _platform,
      );
      final update = await service.checkForUpdate();
      if (!mounted) return;
      if (update == null) {
        setState(() => _statusMessage = 'لا يوجد تحديث أحدث من $_version.');
        showMessage(context, 'أنت على أحدث إصدار ($_version).');
      } else {
        setState(() {
          _pendingUpdate = update;
          _statusMessage =
              'يتوفر الإصدار ${update.newVersion} (الحالي $_version).';
        });
        if (mounted) {
          await _showUpdateDialog(update);
        }
      }
    } catch (error) {
      if (mounted) {
        final message = _friendlyError(error);
        setState(() => _statusMessage = message);
        showMessage(context, message);
      }
    } finally {
      if (mounted) {
        setState(() => _checking = false);
        widget.onBusyChanged(false);
      }
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('network is unreachable')) {
      return 'تعذر الاتصال بخادم التحديثات. تحقق من الإنترنت وحاول مجدداً.';
    }
    if (text.contains('404') || text.contains('http 404')) {
      return 'لم يُعثر على إصدار منشور بعد.';
    }
    if (text.contains('format') || text.contains('invalid')) {
      return 'بيانات الإصدار غير صالحة. حاول لاحقاً.';
    }
    return userError(error);
  }

  Future<void> _showUpdateDialog(UpdateInfo update) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('تحديث متاح — ${update.newVersion}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('الإصدار الحالي: $_version'),
              Text('الإصدار الجديد: ${update.newVersion}'),
              if (update.summary != null && update.summary!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(update.summary!, style: const TextStyle(fontSize: 13)),
              ],
              const SizedBox(height: 8),
              Text(
                'المنصة: ${_platform.name} — الملف: ${Uri.tryParse(update.downloadUrl)?.pathSegments.lastOrNull ?? ''}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
              ),
              if (update.size != null)
                Text(
                  'الحجم: ${(update.size! / (1024 * 1024)).toStringAsFixed(2)} MiB',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('لاحقاً'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'open'),
            child: const Text('فتح صفحة الإصدار'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'download'),
            child: const Text('تنزيل وتحقّق'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'open') {
      await _openReleasesPage();
    } else if (action == 'download') {
      await _download(update);
    }
  }

  Future<void> _openReleasesPage() async {
    final uri = Uri.parse('https://github.com/$_owner/$_repo/releases/latest');
    try {
      final opened = await (widget.launchExternalUrl ?? _launchExternally)(uri);
      if (!opened && mounted) {
        showMessage(context, 'لم يتمكن النظام من فتح صفحة الإصدارات.');
      }
    } catch (_) {
      if (mounted) showMessage(context, 'تعذر فتح صفحة الإصدارات.');
    }
  }

  Future<void> _download(UpdateInfo update) async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _cancelToken = CancellationToken();
    });
    widget.onBusyChanged(true);
    try {
      final service = UpdateService(
        source: _source,
        currentVersion: _version,
        platform: _platform,
      );
      final result = await service.downloadUpdate(
        update,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _progress = total > 0 ? received / total : 0;
          });
        },
        onCancel: () {
          if (mounted) showMessage(context, 'أُلغي التنزيل.');
        },
        cancellation: _cancelToken,
      );
      if (!mounted) return;
      if (result.isSuccess) {
        final path = result.filePath!;
        final verified = await service.verifyUpdateSource(update, path);
        if (!verified) {
          showMessage(context, 'فشل التحقق من الملف بعد التنزيل.');
          return;
        }
        final install = await service.installUpdate(update, path);
        if (install.error != null) {
          showMessage(
            context,
            'حُفظ الملف وتحقق بنجاح في: $path\n${install.error}',
          );
        } else {
          showMessage(context, install.message ?? 'اكتمل التحديث.');
        }
      } else {
        showMessage(context, result.error ?? 'فشل التنزيل.');
      }
    } catch (error) {
      if (mounted) showMessage(context, userError(error));
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
          _progress = 0;
          _cancelToken = null;
        });
        widget.onBusyChanged(false);
      }
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel();
    showMessage(context, 'جاري إلغاء التنزيل...');
  }

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.update_outlined, size: 24),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'تحديث التطبيق',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'الإصدار الحالي: $_version — المنصة: ${_platform.name}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 8),
                InfoBanner(
                  tone: _pendingUpdate != null
                      ? BannerTone.info
                      : BannerTone.caution,
                  message: _statusMessage!,
                ),
              ],
              if (_downloading) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress > 0 ? _progress : null),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    onPressed: _cancelDownload,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('إلغاء التنزيل'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed:
                        (_checking || _downloading || widget.busy) ? null : _check,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_download_outlined),
                    label: Text(_checking ? 'جاري الفحص...' : 'التحقق من التحديث'),
                  ),
                  if (_pendingUpdate != null && !_downloading)
                    OutlinedButton.icon(
                      onPressed: () => _showUpdateDialog(_pendingUpdate!),
                      icon: const Icon(Icons.info_outline),
                      label: const Text('تفاصيل التحديث'),
                    ),
                  OutlinedButton.icon(
                    onPressed: (widget.busy || _downloading)
                        ? null
                        : _openReleasesPage,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('فتح صفحة الإصدارات'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const InfoBanner(
                tone: BannerTone.info,
                message:
                    'يتحقق التطبيق من GitHub Releases الرسمية فقط عبر HTTPS. يُحقق التنزيل ببصمة SHA-256 قبل أي تثبيت؛ التثبيت التلقائي غير مفعّل حتى توقيع الناشر.',
              ),
            ],
          ),
        ),
      );
}

class _DeveloperInfo extends StatelessWidget {
  const _DeveloperInfo({
    required this.nameArabic,
    required this.nameEnglish,
    required this.status,
  });

  final String nameArabic;
  final String nameEnglish;
  final String status;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              nameArabic,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
          ),
          const Icon(Icons.arrow_forward, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              nameEnglish,
              style: const TextStyle(fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      const Divider(height: 24),
      Row(
        children: [
          const Icon(
            Icons.cloud_done_outlined,
            size: 18,
            color: Color(0xFF12685e),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(status, style: const TextStyle(fontSize: 13))),
        ],
      ),
    ],
  );
}

Future<bool> _launchExternally(Uri uri) {
  // ignore: deprecated_member_use
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _ContactCards extends StatelessWidget {
  const _ContactCards({this.launchExternalUrl});

  final ExternalUrlLauncher? launchExternalUrl;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _ContactCard(
        icon: Icons.play_circle_outline,
        label: 'YouTube',
        url: 'https://youtube.com/@kinanmajeed?si=I2yuzJT2rRnEHLVg',
        launchExternalUrl: launchExternalUrl,
      ),
      _ContactCard(
        icon: Icons.chat_bubble_outline,
        label: 'قناة Telegram',
        url: 'https://t.me/techtouch7',
        launchExternalUrl: launchExternalUrl,
      ),
      _ContactCard(
        icon: Icons.chat_outlined,
        label: 'مراسلة المطور',
        url: 'https://t.me/kinanmjeed',
        launchExternalUrl: launchExternalUrl,
      ),
    ],
  );
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({
    required this.icon,
    required this.label,
    required this.url,
    this.launchExternalUrl,
  });

  final IconData icon;
  final String label;
  final String url;
  final ExternalUrlLauncher? launchExternalUrl;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _openUrl(context, url),
      child: SizedBox(
        width: 100,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 28,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      showMessage(context, 'الرابط غير صالح.');
      return;
    }
    try {
      final opened = await (launchExternalUrl ?? _launchExternally)(uri);
      if (!opened && context.mounted) {
        showMessage(context, 'لم يتمكن النظام من فتح الرابط.');
      }
    } catch (_) {
      if (context.mounted) showMessage(context, 'تعذر فتح الرابط.');
    }
  }
}
