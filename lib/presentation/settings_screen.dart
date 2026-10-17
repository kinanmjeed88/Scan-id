import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/app_release.dart';
import '../application/backup_transfer.dart';
import '../application/cancellation.dart';
import '../application/contracts.dart';
import '../application/ota_update.dart';
import '../application/project_service.dart';
import '../application/update_installer.dart';
import '../application/update_setup.dart';
import '../domain/project.dart';
import 'shared.dart';
import 'update_prompt.dart';

typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);
typedef SaveBackup = Future<bool> Function(Project project);

/// The app's own settings: what it stores, how it can be repaired or moved,
/// who made it, and whether it is up to date.
///
/// Nothing here belongs to one project. Opening, naming or backing up a single
/// project happens inside that project, where its images and sheets are
/// visible; this screen is reachable whenever the app runs — with no project
/// at all — because the tools it holds are exactly the ones a person needs
/// when there is no project to open.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.service,
    this.recoverStorage,
    this.launchExternalUrl,
    this.restoreBackup,
    this.saveBackup,
    this.updateSource,
    this.currentVersion,
    this.updateInstaller,
    this.updateService,
    super.key,
  });

  final ProjectService service;
  final Future<void> Function()? recoverStorage;
  final ExternalUrlLauncher? launchExternalUrl;
  final Future<Project?> Function()? restoreBackup;
  final SaveBackup? saveBackup;

  /// The update card's three collaborators, replaceable so a test can watch a
  /// check, a download and an install handoff without a network or a device.
  /// `null` means the real ones: the published release feed, this build's
  /// version, and the installer the running platform can actually use.
  final UpdateSource? updateSource;
  final String? currentVersion;
  final UpdateInstaller? updateInstaller;

  /// Replaces the whole service, so a test can hold a download open long enough
  /// to leave the screen while it runs. `null` builds the real one.
  final UpdateService? updateService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  bool get _canSave =>
      widget.service.backups != null || widget.saveBackup != null;

  bool get _canRestore =>
      widget.service.backups != null || widget.restoreBackup != null;

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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _backupSection()),
              SliverToBoxAdapter(child: _storageSection()),
              SliverToBoxAdapter(child: _developerSection()),
              SliverToBoxAdapter(child: _updateSection()),
              if (_busy)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
            ],
          ),
        ),
      ),
    ),
  );

  // Sections ---------------------------------------------------------------

  Widget _backupSection() => _SettingsCard(
    title: 'النسخ والاستعادة',
    intro:
        'ملف واحد لكل مشروع، يُحفظ حيث تختاره ويُعاد منه إلى جهاز آخر. '
        'الاستعادة تضيف مشروعاً جديداً ولا تستبدل ما هو موجود.',
    notice:
        'النسخ غير مشفرة وتحتوي بيانات حساسة؛ اختر مكاناً محلياً آمناً، واحفظ '
        'نسخة قبل إزالة التطبيق أو تغيير الجهاز.',
    children: [
      if (_canSave)
        ExplainedAction(
          icon: Icons.backup_outlined,
          title: 'نسخة احتياطية كاملة',
          summary:
              'يحفظ مشروعاً واحداً بجميع صوره ومخططاته في ملف تختار مكانه.',
          details:
              'ما الذي يُنسخ: الصور الأصلية ونسخ العمل ومخطط الورقة وتعديلات '
              'الصور وكل بيانات المشروع، في ملف واحد.\n\n'
              'ما لن يحدث: لا يُحذف شيء ولا تُعدَّل صورة؛ تُقرأ البيانات وتُكتب في '
              'الملف الذي تختار مكانه.\n\n'
              'متى تحتاجها: قبل إزالة التطبيق أو تغيير الجهاز، وقبل أي صيانة تحذف '
              'ملفات. يُنسخ مشروع واحد في كل مرة؛ كرّر الأداة لكل مشروع إن كان '
              'لديك عدة مشاريع.',
          onTap: _busy ? null : _backup,
        ),
      if (_canRestore)
        ExplainedAction(
          icon: Icons.restore,
          title: 'استعادة نسخة احتياطية',
          summary: 'يقرأ ملف نسخة احتياطية ويضيفه مشروعاً جديداً مستقلاً.',
          details:
              'كيف تعمل: تختار ملف النسخة، فتُكتب صوره وبياناته من جديد مشروعاً '
              'جديداً باسم مستقل. لا تُستبدل نسخة موجودة ولا تُمسح ملفاتك.\n\n'
              'إن كان المشروع موجوداً في جهازك أصلاً فستحصل على صورة ثانية منه؛ '
              'احذف ما لا تريده بعد ذلك.\n\n'
              'ملف غير صالح أو ناقص يُرفض قبل أن يتغير أي شيء، ويخبرك التطبيق '
              'بالسبب.',
          onTap: _busy ? null : _restoreBackup,
        ),
    ],
  );

  Widget _storageSection() => _SettingsCard(
    title: 'المساحة والاسترداد',
    intro:
        'أدوات تعمل على مساحة التطبيق نفسها. لا تُنفَّذ أي منها دون أن تؤكّدها، '
        'وكل واحدة تُبقي ما لا يخصها كما هو.',
    children: [
      ExplainedAction(
        icon: Icons.cleaning_services_outlined,
        title: 'صيانة المساحة والملفات غير المرتبطة',
        summary: 'يحذف ملفات أنشأها التطبيق ولم يعد أي مشروع يشير إليها.',
        details:
            'من أين تأتي: صورة حُذفت من مشروع، أو مشروع حُذف، أو عمل انقطع في '
            'منتصفه. يبقى في مساحة التطبيق ما كتبه ذلك العمل ولا يذكره أحد.\n\n'
            'ما الذي يُحذف: هذه الملفات وحدها. لا ملفات جهازك الأصلية، ولا صور '
            'مشاريعك الحالية، ولا ما تشير إليه نقطة استرداد لم تُحدَّث بعد؛ يُعرض '
            'ذلك عدداً وحجماً قبل الحذف لتقرّر.\n\n'
            'حماية العمل الجاري: ما كُتب خلال الدقائق العشر الأخيرة يُترك، فقد '
            'يكون صورة تُستورد الآن.',
        onTap: _busy ? null : _maintenance,
      ),
      if (widget.recoverStorage != null)
        ExplainedAction(
          icon: Icons.settings_backup_restore,
          title: 'استرداد قاعدة المشاريع من نقاط الحفظ',
          summary:
              'يبني قائمة مشاريعك من آخر نسخة داخلية، دون حذف القاعدة القديمة.',
          details:
              'متى تُحتاج: عندما لا تُفتح قائمة المشاريع، أو تظهر ناقصة بعد انقطاع '
              'أو بعد خطأ في التخزين.\n\n'
              'ما الذي يحدث: تُقرأ نسخ الاسترداد التي يحتفظ بها التطبيق بعد كل '
              'حفظ، وتُكتب منها قاعدة جديدة. القاعدة القديمة وصور المشاريع تبقى '
              'كما هي، فلا حذف في هذه الأداة.\n\n'
              'ما الذي قد يختلف: آخر تعديل لم يكتمل حفظه قبل العطل. لذلك تُحدَّث '
              'نقاط الاسترداد مع كل حفظ، وإن تأخرت ستجد التنبيه في شاشة المشروع.\n\n'
              'بيانات كُتبت من إصدار أحدث من التطبيق: حدّث التطبيق أولاً ثم استعد.',
          onTap: _busy ? null : _recoverDatabase,
        ),
    ],
  );

  Widget _developerSection() => _SettingsCard(
    title: 'البيانات الشخصية للمطور',
    intro: 'من يقف خلف التطبيق، وكيف تصل إليه.',
    children: [
      const _DeveloperIdentity(),
      _ContactRow(launchExternalUrl: widget.launchExternalUrl),
    ],
  );

  Widget _updateSection() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
    child: _OtaUpdateCard(
      busy: _busy,
      onBusyChanged: (value) {
        if (mounted) setState(() => _busy = value);
      },
      source: widget.updateSource,
      currentVersion: widget.currentVersion,
      installer: widget.updateInstaller,
      service: widget.updateService,
    ),
  );

  // The tools that change storage -------------------------------------------

  /// Backs up ONE project the person chooses.
  ///
  /// Settings holds no current project, so there is nothing to guess from: the
  /// list is asked, a single project is taken as the answer to the question
  /// «أي مشروع», and several are offered for choice. Reading the first row of a
  /// list instead would copy the wrong project in silence.
  Future<void> _backup() async {
    if (_busy) return;
    setState(() => _busy = true);
    final List<Project> projects;
    try {
      projects = await widget.service.projects.list();
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        showMessage(context, userError(error));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (projects.isEmpty) {
      showMessage(
        context,
        'لا يوجد مشروع بعد؛ أنشئ مشروعاً أولاً ثم احفظ نسخة عنه.',
      );
      return;
    }
    final Project? chosen;
    if (projects.length == 1) {
      chosen = projects.single;
    } else {
      chosen = await _chooseProject(projects);
    }
    if (!mounted) return;
    if (chosen == null) return;
    final message =
        'تشمل الأصول والنسخ المعالجة ومخطط الورقة وكل بيانات المشروع في ملف واحد '
        'تختار مكانه. النسخة غير مشفرة وتحتوي بيانات حساسة. المشاريع الأخرى لا '
        'تُمسّ؛ انسخها واحدة واحدة إن أردت نسخة من كلها.';
    if (!await confirm(
          context,
          'نسخة احتياطية كاملة لـ«${chosen.name}»؟',
          message,
          confirmLabel: 'متابعة إلى الحفظ',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final saved = widget.saveBackup == null
          ? await BackupTransfer(widget.service.backups!).save(chosen)
          : await widget.saveBackup!.call(chosen);
      if (mounted) {
        showMessage(
          context,
          saved ? 'حُفظت نسخة «${chosen.name}».' : 'أُلغي حفظ النسخة.',
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

  Future<Project?> _chooseProject(List<Project> projects) {
    return showDialog<Project>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('أي مشروع تنسخه؟'),
        content: SizedBox(
          width: 420,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final project in projects)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${project.assets.length} صور'),
                    onTap: () => Navigator.pop(context, project),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreBackup() async {
    if (!await confirm(
          context,
          'استعادة نسخة احتياطية؟',
          'اختر ملف نسخة موثوقاً من جهازك. تُستعاد الصور والبيانات مشروعاً جديداً '
              'مستقلاً؛ لن يُستبدل أي مشروع موجود ولا تُمسح ملفاتك.',
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

  Future<void> _maintenance() async {
    setState(() => _busy = true);
    final orphans = await _findOrphans();
    if (!mounted || orphans == null) {
      return;
    }
    if (orphans.count == 0) {
      setState(() => _busy = false);
      showMessage(
        context,
        'لا ملفات غير مرتبطة بمشاريعك.${_retainedNote(orphans)}',
      );
      return;
    }
    final megabytes = (orphans.bytes / (1024 * 1024)).toStringAsFixed(2);
    final warning =
        'عدد العناصر: ${orphans.count} · الحجم: $megabytes MiB.\n'
        'هي ملفات أنشأها التطبيق ولم تعد مرتبطة بأي مشروع محفوظ، مثل صور '
        'مشاريع محذوفة أو نسخ معالجة قديمة أو بقايا عمل منقطع. لا تُحذف ملفات '
        'المشاريع الحالية ولا ملفات جهازك. تُتجاهل الملفات الأحدث من عشر دقائق '
        'حمايةً لعمل جارٍ.${_retainedNote(orphans)}';
    // The confirmation is the person's turn, not the app's: the progress bar
    // goes down while they read, so it never spins to pretend work that is
    // only waiting. No file is touched before the answer comes back.
    setState(() => _busy = false);
    final yes = await confirm(
      context,
      'حذف الملفات غير المرتبطة؟',
      warning,
      confirmLabel: 'حذف الملفات',
      destructive: true,
    );
    if (!yes || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
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

  /// Reads the orphan set, reporting a failure instead of treating an
  /// unreadable storage as an empty one.
  Future<OrphanFiles?> _findOrphans() async {
    try {
      return await widget.service.findOrphans();
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        showMessage(context, userError(error));
      }
      return null;
    }
  }

  static String _retainedNote(OrphanFiles orphans) => orphans.retained.isEmpty
      ? ''
      : '\nمحفوظة ولن تُحذف: ${orphans.retained.length} عنصر تشير إليه '
            'نقطة استرداد أو نسخة ترقية ما زالت قائمة. تُحذف بعد تحديث تلك '
            'النقطة.';

  Future<void> _recoverDatabase() async {
    final note =
        'تُستعاد نقاط الحفظ في قاعدة جديدة مع إبقاء القديمة والصور دون حذف. قد '
        'تختلف آخر تغييرات لم يكتمل حفظها. إن كانت البيانات مكتوبة من إصدار أحدث '
        'من التطبيق فحدّث التطبيق أولاً.';
    if (await confirm(
      context,
      'استرداد قاعدة المشاريع؟',
      note,
      confirmLabel: 'استرداد القاعدة',
    )) {
      await widget.recoverStorage?.call();
    }
  }
}

// The sections themselves ---------------------------------------------------

/// One settings section: a title, the sentence that says what the section is
/// for, an optional caution, and [children] of [ExplainedAction] rows.
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.intro,
    required this.children,
    this.notice,
  });

  final String title;
  final String intro;
  final String? notice;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(intro),
            if (notice != null) ...[
              const SizedBox(height: 12),
              InfoBanner(tone: BannerTone.caution, message: notice!),
            ],
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    ),
  );
}

class _DeveloperIdentity extends StatelessWidget {
  const _DeveloperIdentity();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Icon(Icons.person_outline, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'كنان الصائغ',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      SizedBox(height: 2),
      Text(
        'Kinan Al-Sayegh',
        style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
      ),
      SizedBox(height: 12),
      Row(
        children: [
          Icon(Icons.verified_outlined, size: 18, color: Color(0xFF12685e)),
          SizedBox(width: 8),
          Expanded(child: Text('التطبيق مدفوع — نسخة مستقرة')),
        ],
      ),
      SizedBox(height: 12),
    ],
  );
}

/// The channels the developer answers on, in ONE row, each drawn as its own
/// brand mark.
///
/// A generic speech bubble told you nothing about which channel you were about
/// to open, and a `Wrap` of fixed-width cards folded the third one onto a
/// second line on a narrow phone. So: the real YouTube and Telegram marks, side
/// by side, in a row that divides the width between them instead of wrapping.
class _ContactRow extends StatelessWidget {
  const _ContactRow({this.launchExternalUrl});

  static const List<_Contact> _contacts = [
    _Contact(
      brand: _Brand.youtube,
      label: 'YouTube',
      hint: 'قناة المطور',
      url: 'https://youtube.com/@kinanmajeed?si=I2yuzJT2rRnEHLVg',
    ),
    _Contact(
      brand: _Brand.telegram,
      label: 'Telegram',
      hint: 'قناة تيليجرام',
      url: 'https://t.me/techtouch7',
    ),
    _Contact(
      brand: _Brand.telegram,
      label: 'مراسلة المطور',
      hint: 'محادثة مباشرة',
      url: 'https://t.me/kinanmjeed',
    ),
  ];

  final ExternalUrlLauncher? launchExternalUrl;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final contact in _contacts)
        Expanded(
          child: _ContactMark(
            contact: contact,
            launchExternalUrl: launchExternalUrl,
          ),
        ),
    ],
  );
}

class _Contact {
  const _Contact({
    required this.brand,
    required this.label,
    required this.hint,
    required this.url,
  });

  final _Brand brand;
  final String label;
  final String hint;
  final String url;
}

class _ContactMark extends StatelessWidget {
  const _ContactMark({required this.contact, this.launchExternalUrl});

  final _Contact contact;
  final ExternalUrlLauncher? launchExternalUrl;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: contact.url,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openUrl(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BrandIcon(contact.brand),
            const SizedBox(height: 6),
            Text(
              contact.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            Text(
              contact.hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _openUrl(BuildContext context) async {
    final uri = Uri.tryParse(contact.url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      showMessage(context, 'الرابط غير صالح.');
      return;
    }
    try {
      final launcher = launchExternalUrl ?? _launchExternally;
      final opened = await launcher(uri);
      if (!opened && context.mounted) {
        showMessage(context, 'لم يتمكن النظام من فتح الرابط.');
      }
    } catch (_) {
      if (context.mounted) showMessage(context, 'تعذر فتح الرابط.');
    }
  }
}

Future<bool> _launchExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// The brand a mark is drawn for, with the colour that brand publishes in.
enum _Brand {
  youtube(Color(0xFFFF0000)),
  telegram(Color(0xFF229ED0));

  const _Brand(this.color);

  final Color color;
}

class _BrandIcon extends StatelessWidget {
  const _BrandIcon(this.brand);

  final _Brand brand;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 30,
    height: 30,
    child: CustomPaint(painter: _BrandPainter(brand)),
  );
}

/// Both marks are drawn on the 24-point grid their logos are published on, so
/// they stay sharp at any size and need no bundled image file.
class _BrandPainter extends CustomPainter {
  const _BrandPainter(this.brand);

  final _Brand brand;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    if (brand == _Brand.telegram) {
      _paintTelegram(canvas, size, unit);
      return;
    }
    // YouTube: a red rounded tube with a white triangle along it.
    final fill = Paint()..color = brand.color;
    final tube = Rect.fromLTRB(
      1.9 * unit,
      4.9 * unit,
      22.1 * unit,
      19.1 * unit,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(tube, Radius.circular(4.4 * unit)),
      fill,
    );
    final play = Path()
      ..moveTo(9.8 * unit, 8.3 * unit)
      ..lineTo(9.8 * unit, 15.7 * unit)
      ..lineTo(16.4 * unit, 12.0 * unit)
      ..close();
    canvas.drawPath(play, Paint()..color = const Color(0xFFFFFFFF));
  }

  void _paintTelegram(Canvas canvas, Size size, double unit) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, size.width / 2, Paint()..color = brand.color);
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.42);
    canvas.translate(-center.dx, -center.dy);
    final plane = Path()
      ..moveTo(5.4 * unit, 11.9 * unit)
      ..lineTo(17.8 * unit, 6.1 * unit)
      ..lineTo(13.4 * unit, 17.6 * unit)
      ..lineTo(10.6 * unit, 13.9 * unit)
      ..lineTo(7.4 * unit, 12.4 * unit)
      ..close();
    canvas.drawPath(plane, Paint()..color = const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(_BrandPainter oldDelegate) => oldDelegate.brand != brand;
}

// The update card -----------------------------------------------------------

/// Checks for a newer published version and, where the platform can complete an
/// update, finishes it: download, verify by digest, hand the package to the
/// system installer.
///
/// What a person sees is a version number and one decision. The feed it reads
/// and the file it fetches are not shown: naming them would put words on the
/// screen that nobody can act on, and offer a link out of the app where the app
/// already does the job.
class _OtaUpdateCard extends StatefulWidget {
  const _OtaUpdateCard({
    required this.busy,
    required this.onBusyChanged,
    this.source,
    this.currentVersion,
    this.installer,
    this.service,
  });

  final bool busy;
  final ValueChanged<bool> onBusyChanged;
  final UpdateSource? source;
  final String? currentVersion;
  final UpdateInstaller? installer;
  final UpdateService? service;

  @override
  State<_OtaUpdateCard> createState() => _OtaUpdateCardState();
}

class _OtaUpdateCardState extends State<_OtaUpdateCard> {
  static const String _explanation =
      'ماذا يفعل الفحص: يسأل مصدر الإصدارات الرسمي — عبر اتصال آمن — هل نُشر '
      'إصدار أحدث من هذا، ثم يخبرك بالنتيجة. يتكرر هذا السؤال مرة واحدة عند '
      'بدء التطبيق، بصمت: لا يظهر منه شيء إن لم يوجد أحدث أو تعذّر الاتصال، '
      'ولا ينزّل شيئاً. ثم تسأله أنت متى شئت من هنا. لا يُرسل مع السؤال أي '
      'شيء عنك: لا رقم إصدارك ولا اسمك ولا أي صورة؛ الطلب عنوان ثابت في نطاق '
      'مصدر الإصدارات، ويرى ذلك المصدر عنوان شبكتك ووقت الطلب كما في أي اتصال.\n\n'
      'بعد «تنزيل التحديث»: تُنزَّل الحزمة إلى مساحة التطبيق الخاصة بها وتُطابق '
      'بصمتها المنشورة، وهي مطابقة تُثبت أن الملف وصل كما نُشر ولا تُثبت من '
      'نشره؛ لذلك يقارن التطبيق قبل فتح المثبت توقيعَ الحزمة بتوقيع التطبيق '
      'المثبَّت على جهازك، ويُرفض أي تحديث لا تُثبت هذه المقارنة هويته أو يتعذر '
      'فيه التحقق. ثم يفتح النظام شاشته لتأكيد التثبيت. لا يُثبَّت شيء بصمت.\n\n'
      'إن أُلغي التنزيل أو رُفض التثبيت: تبقى مشاريعك وصورك كما هي، ولا يُحذف '
      'أي ملف. ومغادرة هذه الشاشة أثناء التنزيل تُلغيه.';

  @override
  void dispose() {
    // The download belongs to this screen. Leaving it must not leave a socket
    // writing a package nobody can stop any more: the cancelled read ends, and
    // the service removes the partial file it had written.
    _cancelToken?.cancel();
    super.dispose();
  }

  UpdateInfo? _pendingUpdate;
  String? _statusMessage;
  double _progress = 0;
  bool _checking = false;
  bool _downloading = false;
  CancellationToken? _cancelToken;

  UpdateSource get _source {
    final injected = widget.source;
    if (injected != null) return injected;
    return GitHubUpdateSource(owner: releaseOwner, repo: releaseRepository);
  }

  String get _version => widget.currentVersion ?? appVersion;

  UpdateInstaller? get _installer =>
      widget.installer ?? platformUpdateInstaller();

  UpdatePlatform get _platform {
    if (Platform.isWindows) return UpdatePlatform.windows;
    return UpdatePlatform.android;
  }

  UpdateService _service() {
    final injected = widget.service;
    if (injected != null) return injected;
    // Production takes the same factory the startup check takes, so the card
    // and the check cannot disagree about the platform or the installer. A
    // test that injects a source or an installer keeps its own composition.
    if (widget.source == null && widget.installer == null) {
      return buildPlatformUpdateService(version: _version);
    }
    return UpdateService(
      source: _source,
      currentVersion: _version,
      platform: _platform,
      installer: _installer,
      temporaryDirectory: updateDownloadDirectory,
    );
  }

  Future<void> _check() async {
    if (_checking || _downloading || widget.busy) return;
    setState(() {
      _checking = true;
      _statusMessage = null;
      _pendingUpdate = null;
    });
    widget.onBusyChanged(true);
    UpdateInfo? found;
    try {
      found = await _service().checkForUpdate();
      if (!mounted) return;
      if (found == null) {
        setState(() => _statusMessage = 'أنت على أحدث إصدار ($_version).');
      } else {
        setState(() => _pendingUpdate = found);
      }
    } catch (error) {
      if (mounted) {
        final message = error is UpdateFailure
            ? describeUpdateFailure(error)
            : userError(error);
        setState(() => _statusMessage = message);
      }
      found = null;
    } finally {
      if (mounted) {
        setState(() => _checking = false);
        widget.onBusyChanged(false);
      }
    }
    // The offer is the person's turn, not the app's: the card waits for an
    // answer with no progress running, so the screen stays honest about what
    // is happening and downloading starts only on a yes.
    if (!mounted || found == null) return;
    await _present(found);
  }

  String get _downloadLabel =>
      _installer == null ? 'تنزيل وتحقّق' : 'تنزيل وتثبيت';

  Future<void> _present(UpdateInfo update) async {
    await showUpdateOffer(
      context,
      update: update,
      currentVersion: _version,
      canInstall: _installer != null,
      downloadLabel: _downloadLabel,
      onDownload: () => _download(update),
    );
  }

  Future<void> _download(UpdateInfo update) async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _cancelToken = CancellationToken();
    });
    widget.onBusyChanged(true);
    final service = _service();
    try {
      final result = await service.downloadUpdate(
        update,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() => _progress = total > 0 ? received / total : 0);
        },
        onCancel: () {
          if (mounted) showMessage(context, 'أُلغي التنزيل.');
        },
        cancellation: _cancelToken,
      );
      if (!mounted) return;
      if (!result.isSuccess) {
        setState(() => _statusMessage = result.error ?? 'فشل التنزيل.');
        return;
      }
      final install = await service.installUpdate(update, result.filePath!);
      if (!mounted) return;
      setState(() {
        _statusMessage = install.message ?? install.error ?? 'اكتمل التحديث.';
      });
      showMessage(context, _statusMessage!);
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

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_alt, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'تحديث التطبيق',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'كيف يعمل التحديث؟',
                icon: const Icon(Icons.info_outline),
                onPressed: () => showFeatureExplanation(
                  context,
                  title: 'تحديث التطبيق',
                  details: _explanation,
                ),
              ),
            ],
          ),
          Text('الإصدار الحالي: $_version'),
          if (_statusMessage != null) ...[
            const SizedBox(height: 10),
            InfoBanner(
              tone: _pendingUpdate == null
                  ? BannerTone.caution
                  : BannerTone.info,
              message: _statusMessage!,
            ),
          ],
          if (_downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => _cancelToken?.cancel(),
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
                onPressed: (_checking || _downloading || widget.busy)
                    ? null
                    : _check,
                icon: _checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(_checking ? 'جاري الفحص' : 'التحقق من التحديث'),
              ),
              if (_pendingUpdate != null && !_downloading)
                OutlinedButton.icon(
                  onPressed: () => _present(_pendingUpdate!),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(_downloadLabel),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const InfoBanner(
            message:
                'الاتصال بالشبكة يُستخدم لهذا الفحص ولتنزيل التحديث فقط. صورك '
                'ومشاريعك لا تغادر الجهاز.',
          ),
          const SizedBox(height: 4),
        ],
      ),
    ),
  );
}
