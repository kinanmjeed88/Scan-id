import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../application/project_service.dart';
import '../domain/project.dart';
import 'project_screen.dart';
import 'shared.dart';

typedef PickImages = Future<List<ImportSource>> Function();

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
  const ScanIdApp({required this.service, required this.pickImages, super.key});
  final ProjectService service;
  final PickImages pickImages;
  @override
  Widget build(BuildContext context) => AppShell(
    home: ProjectsScreen(service: service, pickImages: pickImages),
  );
}

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({
    required this.service,
    required this.pickImages,
    super.key,
  });
  final ProjectService service;
  final PickImages pickImages;
  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  late Future<List<Project>> _projects = widget.service.projects.list();
  bool _busy = false;
  void _refresh() => setState(() => _projects = widget.service.projects.list());

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
      await _open(project.id);
    }
    if (mounted) {
      _refresh();
    }
  }

  Future<void> _open(String id) async {
    setState(() => _busy = true);
    Project? project;
    try {
      project = await widget.service.projects.get(id);
    } catch (error) {
      if (mounted) {
        showMessage(context, userError(error));
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
        ),
      ),
    );
    if (mounted) {
      _refresh();
    }
  }

  Future<void> _delete(Project project) async {
    final yes = await confirm(
      context,
      'حذف المشروع من القائمة؟',
      'ستُزال بيانات «${project.name}» من قاعدة المشاريع. تبقى نسخ الصور المحلية مؤقتاً للاسترداد، ولا تُحذف الصور الأصلية من جهازك. لا يوجد تراجع عن حذف بيانات المشروع حالياً.',
    );
    if (!yes || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.service.projects.remove(project);
      if (mounted) {
        _refresh();
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
        title: const Row(
          children: [
            Icon(Icons.document_scanner_outlined),
            SizedBox(width: 12),
            Text('مستمسكات'),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _busy ? null : _newProject,
              icon: const Icon(Icons.add),
              label: const Text('مشروع جديد'),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.shield_outlined, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('محلي بالكامل · صورك لا تغادر الجهاز'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  'مساحة مستمسكاتك',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'أنشئ مشروعاً، واجمع صوره بأمان، ثم عد إليه من حيث توقفت.',
                ),
                const SizedBox(height: 20),
                const FoundationNotice(),
                const SizedBox(height: 16),
                if (_busy) const LinearProgressIndicator(),
                Expanded(
                  child: FutureBuilder<List<Project>>(
                    future: _projects,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(userError(snapshot.error!)),
                              TextButton(
                                onPressed: _refresh,
                                child: const Text('إعادة المحاولة'),
                              ),
                            ],
                          ),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final projects = snapshot.requireData;
                      if (projects.isEmpty) {
                        return const EmptyState(
                          icon: Icons.folder_open_outlined,
                          title: 'مشروعك الأول يبدأ هنا',
                          message:
                              'اضغط «مشروع جديد» لإضافة الصور. سنحتفظ بالأصل ونسخة عمل مستقلة.',
                        );
                      }
                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemCount: projects.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final project = projects[index];
                          return Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              leading: const CircleAvatar(
                                child: Icon(Icons.folder_outlined),
                              ),
                              title: Text(project.name),
                              subtitle: Text(
                                '${project.assets.length} صور · A4 · ${project.updatedAt.toLocal().toString().substring(0, 16)}',
                              ),
                              onTap: _busy ? null : () => _open(project.id),
                              trailing: IconButton(
                                tooltip: 'حذف المشروع',
                                onPressed: _busy
                                    ? null
                                    : () => _delete(project),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
