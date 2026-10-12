import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../application/project_service.dart';
import '../application/backup_transfer.dart';
import '../domain/project.dart';
import 'project_screen.dart';
import 'settings_screen.dart';
import 'shared.dart';

class AppShell extends StatelessWidget {
  const AppShell({required this.home, super.key});
  final Widget home;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'مستمسكات — Scan ID',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff12685e)),
      scaffoldBackgroundColor: const Color(0xfff5f7f6),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      cardTheme: const CardThemeData(elevation: 0),
    ),
    home: home,
  );
}

class ScanIdApp extends StatelessWidget {
  const ScanIdApp({
    required this.service,
    required this.pickImages,
    this.recoverStorage,
    super.key,
  });
  final ProjectService service;
  final PickImages pickImages;
  final Future<void> Function()? recoverStorage;
  @override
  Widget build(BuildContext context) => AppShell(
    home: ProjectsScreen(
      service: service,
      pickImages: pickImages,
      recoverStorage: recoverStorage,
    ),
  );
}

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({
    required this.service,
    required this.pickImages,
    this.recoverStorage,
    super.key,
  });
  final ProjectService service;
  final PickImages pickImages;
  final Future<void> Function()? recoverStorage;
  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  late Future<List<Project>> _projects = widget.service.projects.list();
  late Future<Set<String>> _stale = _loadStale();
  bool _busy = false;
  void _refresh() {
    final next = widget.service.projects.list();
    final stale = _loadStale();
    setState(() {
      _projects = next;
      _stale = stale;
    });
  }

  Future<Set<String>> _loadStale() async {
    if (widget.service.recovery == null) {
      return <String>{};
    }
    return widget.service.staleRecoveryPoints();
  }

  /// Rewrites every outdated recovery copy. Stops at the first failure, says
  /// how many succeeded, and reloads the list so the screen shows what remains.
  Future<void> _repairRecoveryPoints(Set<String> ids) async {
    setState(() => _busy = true);
    var done = 0;
    try {
      for (final id in ids) {
        await widget.service.refreshRecoveryPoint(id);
        done++;
      }
      if (mounted) {
        showMessage(context, 'حُدّثت $done نقطة استرداد.');
      }
    } catch (error) {
      if (mounted) {
        showMessage(
          context,
          '${userError(error)} حُدّث $done من ${ids.length}.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refresh();
      }
    }
  }

  Widget _staleNotice(Set<String> ids) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      InfoBanner(
        tone: BannerTone.caution,
        title: 'نقاط استرداد متأخرة (${ids.length})',
        message:
            'بيانات هذه المشاريع محفوظة، لكن نسخها المحلية للاسترداد لا تطابقها. '
            'حدّثها حتى تعكس الاستعادة أحدث حالة إن فُقدت قاعدة البيانات.',
      ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          onPressed: _busy ? null : () => _repairRecoveryPoints(ids),
          icon: const Icon(Icons.refresh),
          label: const Text('تحديث نقاط الاستعادة'),
        ),
      ),
    ],
  );

  Future<void> _restore() async {
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
        _refresh();
        showMessage(context, 'استُعيد المشروع كاملاً كنسخة مستقلة.');
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

  Future<void> _newProject() async {
    final name = await askName(context, title: 'مشروع جديد', initial: '');
    if (name == null || !mounted) {
      return;
    }
    setState(() => _busy = true);
    Project? project;
    try {
      project = await widget.service.create(name);
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (project != null && mounted) {
      await _open(project.id, startWithImagePicker: true);
    }
    if (mounted) {
      _refresh();
    }
  }

  Future<void> _open(String id, {bool startWithImagePicker = false}) async {
    setState(() => _busy = true);
    Project? project;
    try {
      project = await widget.service.projects.get(id);
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
        final recovery = widget.service.recovery;
        if (recovery != null &&
            await confirm(
              context,
              'تعذر فتح ملفات المشروع',
              'يمكن إعادة إنشاء الصور المعالجة والمصغرات من الأصول بوصفة القص المحفوظة، دون حذف شيء. إن كان الأصل مفقوداً فاستعد نسخة احتياطية كاملة.',
              confirmLabel: 'إعادة إنشاء النسخ',
            )) {
          try {
            project = await recovery.rebuildDerived(
              await recovery.metadata(id),
            );
          } catch (repairError) {
            if (mounted) {
              showMessage(context, userError(repairError));
            }
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    final opened = project;
    if (opened == null || !mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProjectScreen(
          project: opened,
          service: widget.service,
          pickImages: widget.pickImages,
          startWithImagePicker: startWithImagePicker,
          recoverStorage: widget.recoverStorage,
        ),
      ),
    );
    if (mounted) {
      _refresh();
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

  Future<void> _openSettings() async {
    if (_busy || !mounted) return;
    final projects = await _projects;
    if (!mounted) return;
    if (projects.isEmpty) {
      showMessage(context, 'أنشئ مشروعاً أولاً للوصول إلى الإعدادات.');
      return;
    }
    final project = projects.first;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          project: project,
          service: widget.service,
          pickImages: widget.pickImages,
          recoverStorage: widget.recoverStorage,
        ),
      ),
    );
  }

  Future<void> _delete(Project project) async {
    final yes = await confirm(
      context,
      'حذف المشروع وملفاته؟',
      'ستُزال بيانات «${project.name}» من قاعدة المشاريع، ثم تُحذف نسخ الصور والمصغرات التي أنشأها التطبيق داخل مساحته الخاصة. لا تُحذف ملفات جهازك الأصلية ولا مشاريع أخرى. لا يوجد تراجع عن حذف المشروع؛ النسخ الاحتياطية التي أنشأتها سابقاً تبقى كما هي.',
      confirmLabel: 'حذف المشروع',
      destructive: true,
    );
    if (!yes || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final report = await widget.service.deleteProject(project);
      if (mounted) {
        _refresh();
        showMessage(
          context,
          report.warning ?? 'حُذف المشروع وملفاته من مساحة التطبيق.',
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

  Future<void> _maintenance() async {
    setState(() => _busy = true);
    try {
      final orphans = await widget.service.findOrphans();
      if (!mounted) {
        return;
      }
      final kept = orphans.retained.isEmpty
          ? ''
          : '\nمحفوظة ولن تُحذف: ${orphans.retained.length} عنصر تشير إليه '
                'نقطة استرداد أو نسخة ترقية ما زالت قائمة. تُحذف بعد تحديث تلك النقطة.';
      if (orphans.count == 0) {
        showMessage(context, 'لا ملفات غير مرتبطة بمشاريعك.$kept');
        return;
      }
      final megabytes = (orphans.bytes / (1024 * 1024)).toStringAsFixed(2);
      final yes = await confirm(
        context,
        'حذف الملفات غير المرتبطة؟',
        'عدد العناصر: ${orphans.count} · الحجم: $megabytes MiB.\n'
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
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _about() {
    showAboutDialog(
      context: context,
      applicationName: 'مستمسكات — Scan ID',
      applicationVersion: '0.1.0',
      children: [
        const Text(
          'معالجة محلية دون رفع. تبقى صورك على هذا الجهاز، ولا يرسلها التطبيق عبر الشبكة.',
        ),
        const SizedBox(height: 12),
        const InfoBanner(
          tone: BannerTone.caution,
          title: 'النسخ الاحتياطية',
          message:
              'احفظ نسخة احتياطية قبل إزالة التطبيق أو تغيير الجهاز. النسخ غير مشفرة وتحتوي بيانات حساسة؛ اختر مكاناً محلياً آمناً.',
        ),
        const SizedBox(height: 12),
        const InfoBanner(
          tone: BannerTone.caution,
          title: 'الطباعة',
          message:
              'للطباعة استخدم A4 والحجم الفعلي 100% دون Fit to page، وتحقق بالمسطرة.',
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('تفاصيل تقنية'),
          children: [Text('مخطط البيانات: الإصدار ${Project.schemaVersion}')],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.document_scanner_outlined),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'مستمسكات',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'الإعدادات',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
          IconButton(
            tooltip: 'عن التطبيق والتراخيص',
            icon: const Icon(Icons.info_outline),
            onPressed: _about,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'مساحة مستمسكاتك',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'أنشئ مشروعاً، واجمع صوره، ثم عد إليه من حيث توقفت. '
                        'كل شيء محفوظ على هذا الجهاز.',
                      ),
                      const SizedBox(height: 16),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FilledButton.icon(
                                onPressed: _busy ? null : _newProject,
                                icon: const Icon(Icons.add),
                                label: const Text('مشروع جديد'),
                              ),
                              const SizedBox(height: 12),
                              const Row(
                                children: [
                                  Icon(Icons.shield_outlined, size: 18),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'محلي · لا يرسل التطبيق صورك عبر الشبكة',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_busy) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        'مشاريعك',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
                FutureBuilder<Set<String>>(
                  future: _stale,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: InfoBanner(
                            tone: BannerTone.caution,
                            message: userError(snapshot.error!),
                          ),
                        ),
                      );
                    }
                    final ids = snapshot.data;
                    if (ids == null || ids.isEmpty) {
                      return const SliverToBoxAdapter(child: SizedBox.shrink());
                    }
                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _staleNotice(ids),
                      ),
                    );
                  },
                ),
                FutureBuilder<List<Project>>(
                  future: _projects,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return SliverToBoxAdapter(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(userError(snapshot.error!)),
                              if (widget.recoverStorage != null)
                                TextButton(
                                  onPressed: _recoverDatabase,
                                  child: const Text(
                                    'استرداد نقاط الحفظ دون حذف الأصل',
                                  ),
                                ),
                              TextButton(
                                onPressed: _refresh,
                                child: const Text('إعادة المحاولة'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const SliverToBoxAdapter(
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final projects = snapshot.requireData;
                    if (projects.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: EmptyState(
                          icon: Icons.folder_open_outlined,
                          title: 'مشروعك الأول يبدأ هنا',
                          message:
                              'اضغط «مشروع جديد» لإضافة الصور. سنحتفظ بالأصل ونسخة عمل مستقلة.',
                        ),
                      );
                    }
                    return SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final project = projects[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            leading: const CircleAvatar(
                              child: Icon(Icons.folder_outlined),
                            ),
                            title: Text(
                              project.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${project.assets.length} صور · '
                              'آخر تعديل ${formatLocalDateTime(project.updatedAt)}',
                            ),
                            onTap: _busy ? null : () => _open(project.id),
                            trailing: TextButton.icon(
                              onPressed: _busy ? null : () => _delete(project),
                              style: TextButton.styleFrom(
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.error,
                              ),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('حذف'),
                            ),
                          ),
                        );
                      }, childCount: projects.length),
                    );
                  },
                ),
                SliverToBoxAdapter(child: _maintenanceSection()),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// Secondary tools: they change storage, so they sit below the projects and
  /// carry their own cautions. Nothing here is removed; each action keeps its
  /// confirmation.
  Widget _maintenanceSection() => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 24),
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
            const Text('أدوات تعمل على التخزين. لا تُنفَّذ أي منها دون تأكيد.'),
            const SizedBox(height: 12),
            const InfoBanner(
              tone: BannerTone.caution,
              message: 'احفظ نسخة احتياطية قبل إزالة التطبيق؛ النسخ غير مشفرة.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (widget.service.backups != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _restore,
                    icon: const Icon(Icons.restore),
                    label: const Text('استعادة نسخة احتياطية'),
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
}

/// Local date and time as "YYYY-MM-DD HH:mm": fixed width, so it never clips
/// in an Arabic layout and never depends on the platform's default format.
String formatLocalDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
