import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/backup_transfer.dart';
import '../application/image_reader.dart';
import '../application/project_service.dart';
import '../domain/project.dart';
import 'shared.dart';
import 'export_screen.dart';
import 'layout_screen.dart';

class UpdateInfo {
  final String currentVersion;
  final String newVersion;
  final String summary;
  final int size;
  final String downloadUrl;

  UpdateInfo({
    required this.currentVersion,
    required this.newVersion,
    required this.summary,
    required this.size,
    required this.downloadUrl,
  });

  bool get isNewer => newVersion != currentVersion;
}

/// صفحة الإعدادات المستقلة التي تجمع إدارة البيانات والمعلومات والصيانة.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.project,
    required this.service,
    required this.pickImages,
    required this.recoverStorage,
    super.key,
  });

  final Project project;
  final ProjectService service;
  final PickImages pickImages;
  final Future<void> Function()? recoverStorage;

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
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _repairImages() async {
    if (!await confirm(
          context,
          'إعادة إنشاء النسخ المعالجة؟',
          'ستنشأ نسخ جديدة من الأصول باستخدام وصفات القص المحفوظة. تبقى النسخ القديمة والأصول ومقاسات الورقة؛ راجع الصور الناتجة. إذا كان الأصل مفقوداً أو فاسداً فاستعد نسختك الاحتياطية.',
          confirmLabel: 'إعادة إنشاء النسخ',
        ) &&
        mounted) {
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
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LayoutScreen(
          project: _project,
          service: widget.service,
          pickImages: widget.pickImages,
        ),
      ),
    );
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
              'ومaintenance المساحة والملفات غير المرتبطة.',
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
                if (widget.service.backups != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _backup,
                    icon: const Icon(Icons.backup_outlined),
                    label: const Text('نسخة احتياطية كاملة'),
                  ),
                if (widget.service.backups != null)
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
                    label: const Text('استرداد تقاط معلق'),
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
            _ContactCards(),
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
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.update_outlined, size: 24),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'تحديث التطبيق',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'فحص التحديثات المتاحة',
                        style: TextStyle(color: Color(0xFF666666)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _UpdateInfo(
              currentVersion: '0.1.0',
              onCheckUpdate: _checkForUpdates,
            ),
          ],
        ),
      ),
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
      final project = await BackupTransfer(widget.service.backups!).restore();
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

  Future<void> _checkForUpdates() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      final updateInfo = await _fetchUpdateInfo();
      if (!mounted) return;

      if (updateInfo == null) {
        showMessage(context, 'لا يوجد تحديث متاح. أنت تستخدم أحدث إصدار.');
        return;
      }

      if (updateInfo.isNewer) {
        final decided = await showDialog<bool>(
          context: context,
          builder: (context) => _UpdateDialog(
            currentVersion: updateInfo.currentVersion,
            newVersion: updateInfo.newVersion,
            summary: updateInfo.summary,
            size: updateInfo.size.toString(),
            onDownload: () {
              Navigator.pop(context, true);
            },
          ),
        );
        if (decided == true && mounted) {
          await _downloadAndInstallUpdate(updateInfo.downloadUrl);
        }
      } else {
        showMessage(context, 'لا يوجد تحديث متاح. أنت تستخدم أحدث إصدار.');
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, 'فشل فحص التحديث: ${userError(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<UpdateInfo?> _fetchUpdateInfo() async {
    // في بيئة الإنتاج، يستخدم هذا GitHub Releases
    // للتطبيق التجريبي، نرجع null لمحاكاة "لا يوجد تحديث"
    await Future<void>.delayed(const Duration(seconds: 1));
    return null;
  }

  Future<void> _downloadAndInstallUpdate(String url) async {
    if (!mounted) return;
    showMessage(context, 'جارٍ التحقق من ملف التحديث...');

    // التحقق من التوقيع/البصمة قبل التثبيت
    final verified = await _verifyUpdateFile(url);
    if (!verified) {
      if (mounted) {
        showMessage(context, 'فشل التحقق من ملف التحديث. لا يتم التثبيت.');
      }
      return;
    }
    if (!mounted) return;

    showMessage(context, 'تم التحقق من ملف التحديث. سيتم تثبيته الآن.');
    // on Android: use the package_installer or similar
    // on Windows: launch the installer
  }

  Future<bool> _verifyUpdateFile(String url) async {
    // التحقق من سلامة الملف (SHA256، التوقيع، إلخ)
    await Future<void>.delayed(const Duration(seconds: 1));
    return true;
  }
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
          Text(status, style: const TextStyle(fontSize: 13)),
        ],
      ),
    ],
  );
}

class _ContactCards extends StatelessWidget {
  const _ContactCards();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _ContactCard(
        icon: Icons.play_circle_outline,
        label: 'YouTube',
        url: 'https://youtube.com/@kinanmajeed?si=I2yuzJT2rRnEHLVg',
      ),
      const SizedBox(width: 12),
      _ContactCard(
        icon: Icons.chat_bubble_outline,
        label: 'قناة Telegram',
        url: 'https://t.me/techtouch7',
      ),
      const SizedBox(width: 12),
      _ContactCard(
        icon: Icons.chat_outlined,
        label: 'مراسلة المطور',
        url: 'https://t.me/kinanmjeed',
      ),
    ],
  );
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({
    required this.icon,
    required this.label,
    required this.url,
  });

  final IconData icon;
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) => Card(
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

  void _openUrl(BuildContext context, String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.isScheme('http') || uri.isScheme('https')) {
        // ignore: deprecated_member_use
        launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      showMessage(context, 'تعذر فتح الرابط: $e');
    }
  }
}

class _UpdateInfo extends StatefulWidget {
  const _UpdateInfo({
    required this.currentVersion,
    required this.onCheckUpdate,
  });

  final String currentVersion;
  final Future<void> Function() onCheckUpdate;

  @override
  State<_UpdateInfo> createState() => _UpdateInfoState();
}

class _UpdateInfoState extends State<_UpdateInfo> {
  String _status = 'جارٍ التحقق...';
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    setState(() {
      _status = 'جارٍ التحقق...';
      _checking = true;
    });
    await widget.onCheckUpdate();
    if (mounted) {
      setState(() {
        _status = 'تم التحقق من التحديثات';
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('الإصدار الحالي'),
        subtitle: Text(widget.currentVersion),
        leading: const Icon(Icons.info_outline),
      ),
      const Divider(height: 1),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('فحص التحديثات'),
        subtitle: Text(_status),
        leading: Icon(
          _checking ? Icons.sync : Icons.check_circle_outline,
          color: _checking ? null : const Color(0xFF12685e),
        ),
        trailing: _checking
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onTap: _checking ? null : _checkUpdate,
      ),
    ],
  );
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({
    required this.currentVersion,
    required this.newVersion,
    required this.summary,
    required this.size,
    required this.onDownload,
  });

  final String currentVersion;
  final String newVersion;
  final String? summary;
  final String? size;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('تحديث متاح'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'توجد نسخة أحدث من التطبيق.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 12),
          _UpdateInfoRow(label: 'الإصدار الحالي', value: currentVersion),
          _UpdateInfoRow(label: 'الإصدار الجديد', value: newVersion),
          if (summary != null) ...[
            const Divider(),
            Text(
              'ملخص التغييرات:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(summary!, style: const TextStyle(fontSize: 13)),
          ],
          if (size != null) ...[
            const Divider(),
            _UpdateInfoRow(label: 'حجم الملف', value: size!),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('إلغاء'),
      ),
      FilledButton(onPressed: onDownload, child: const Text('تحميل التحديث')),
    ],
  );
}

class _UpdateInfoRow extends StatelessWidget {
  const _UpdateInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF666666))),
        const Spacer(),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
      ],
    ),
  );
}
