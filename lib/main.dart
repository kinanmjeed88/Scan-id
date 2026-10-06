import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'application/project_service.dart';
import 'application/native_documents.dart';
import 'application/camera_capture.dart';
import 'application/native_camera.dart';
import 'persistence/local_asset_repository.dart';
import 'persistence/local_project_backups.dart';
import 'persistence/local_project_repository.dart';
import 'persistence/local_image_editor.dart';
import 'persistence/local_project_recovery.dart';
import 'presentation/shared.dart';
import 'presentation/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'AndroidX Core',
    ], await rootBundle.loadString('assets/legal/androidx-core-LICENSE.txt'));
  });
  runApp(const _Bootstrap());
}

Future<ProjectService> _openStorage({bool recover = false}) async {
  final Directory support;
  if (Platform.isWindows) {
    // path_provider's support directory is RoamingAppData on Windows. Identity
    // images belong in LocalAppData, not an enterprise roaming profile.
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || !p.isAbsolute(local)) {
      throw const FileSystemException('Local application data is unavailable.');
    }
    support = Directory(p.join(local, 'ScanId'));
  } else {
    support = await getApplicationSupportDirectory();
  }
  final directory = Directory(p.join(support.path, 'scan_id'));
  final repository = recover
      ? await LocalProjectRepository.recover(directory)
      : await LocalProjectRepository.open(directory);
  final assets = LocalAssetRepository(repository.files);
  return ProjectService(
    repository,
    assets,
    camera: Platform.isAndroid
        ? CameraCapture(repository, assets, NativeCamera())
        : null,
    imageEditor: LocalImageEditor(repository.files),
    recovery: LocalProjectRecovery(
      repository,
      LocalImageEditor(repository.files),
    ),
    backups: LocalProjectBackups(repository, repository.files),
  );
}

Future<List<ImportSource>> _pickImages() async {
  if (Platform.isAndroid) {
    return pickAndroidImages();
  }
  const group = XTypeGroup(
    label: 'JPEG / PNG',
    extensions: ['jpg', 'jpeg', 'png'],
    mimeTypes: ['image/jpeg', 'image/png'],
  );
  final files = await openFiles(acceptedTypeGroups: [group]);
  return files
      .map((file) => ImportSource(file.name, () => file.openRead()))
      .toList();
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Future<ProjectService> _service = _openStorage();
  Future<void> _recover() async {
    try {
      await (await _service).projects.close();
    } catch (_) {
      /* Opening may have failed before a repository existed. */
    }
    final next = _openStorage(recover: true);
    setState(() => _service = next);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ProjectService>(
    future: _service,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const AppShell(
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
        );
      }
      if (snapshot.hasData) {
        return ScanIdApp(
          key: ValueKey(snapshot.requireData),
          service: snapshot.requireData,
          pickImages: _pickImages,
          recoverStorage: _recover,
        );
      }
      return AppShell(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: snapshot.hasError
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder_off_outlined, size: 48),
                        const SizedBox(height: 16),
                        const Text('تعذر فتح مساحة المشاريع المحلية.'),
                        const SizedBox(height: 8),
                        const Text(
                          'تحقق من المساحة والصلاحيات. لم تُحذف قاعدة البيانات أو يُعد إنشاؤها.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Builder(
                          builder: (context) => OutlinedButton(
                            onPressed: () async {
                              if (await confirm(
                                context,
                                'استعادة نقاط الحفظ المحلية؟',
                                'ستنشأ قاعدة جديدة من آخر نقاط الحفظ. تبقى القاعدة القديمة والصور دون حذف. قد تفقد آخر تعديل إذا انقطع الحفظ؛ حدّث التطبيق أولاً إن كان إصدار البيانات أحدث.',
                              )) {
                                await _recover();
                              }
                            },
                            child: const Text(
                              'استرداد آمن دون حذف القاعدة القديمة',
                            ),
                          ),
                        ),
                        FilledButton(
                          onPressed: () {
                            final next = _openStorage();
                            setState(() {
                              _service = next;
                            });
                          },
                          child: const Text('إعادة المحاولة'),
                        ),
                      ],
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
        ),
      );
    },
  );
}
