import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'application/full_resolution_jpeg_cropper.dart';
import 'application/project_service.dart';
import 'application/startup_diagnostics.dart';
import 'application/native_documents.dart';
import 'application/camera_capture.dart';
import 'application/native_camera.dart';
import 'application/ota_update.dart';
import 'application/update_setup.dart';
import 'imaging/boundary_proposal_cascade.dart';
import 'imaging/docquad_model.dart';
import 'imaging/docaligner_model.dart';
import 'persistence/local_asset_repository.dart';
import 'persistence/local_project_backups.dart';
import 'persistence/local_project_repository.dart';
import 'persistence/local_image_editor.dart';
import 'persistence/local_project_recovery.dart';
import 'persistence/local_storage_maintenance.dart';
import 'presentation/shared.dart';
import 'presentation/app.dart';

void main() {
  StartupDiagnostics.mark('dart.main.enter');
  WidgetsFlutterBinding.ensureInitialized();
  StartupDiagnostics.mark('flutter.binding.ready');
  StartupDiagnostics.installErrorHooks();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'AndroidX Core',
    ], await rootBundle.loadString('assets/legal/androidx-core-LICENSE.txt'));
    yield LicenseEntryWithLineBreaks(
      ['DocQuadNet-256 (upstream declared Apache-2.0)'],
      await rootBundle.loadString(
        'assets/legal/docquadnet-apache-2.0-LICENSE.txt',
      ),
    );
    yield LicenseEntryWithLineBreaks(
      ['flutter_onnxruntime (MASIC AI)'],
      await rootBundle.loadString(
        'assets/legal/flutter-onnxruntime-MIT-LICENSE.txt',
      ),
    );
    yield LicenseEntryWithLineBreaks([
      'ONNX Runtime',
    ], await rootBundle.loadString('assets/legal/onnxruntime-LICENSE.txt'));
  });
  StartupDiagnostics.mark('licenses.lazy_callback.registered');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    StartupDiagnostics.mark('flutter.first_frame');
  });
  StartupDiagnostics.mark('runApp.begin');
  runApp(const _Bootstrap());
  StartupDiagnostics.mark('runApp.returned');
}

Future<ProjectService> _openStorage({bool recover = false}) async {
  StartupDiagnostics.mark(
    'storage.open.begin mode=${recover ? 'recover' : 'normal'}',
  );
  StartupDiagnostics.mark('storage.support_directory.begin');
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
  StartupDiagnostics.mark('storage.support_directory.ready');
  final directory = Directory(p.join(support.path, 'scan_id'));
  StartupDiagnostics.mark('storage.database_open.begin');
  final repository = recover
      ? await LocalProjectRepository.recover(directory)
      : await LocalProjectRepository.open(directory);
  StartupDiagnostics.mark('storage.database_open.complete');
  final assets = LocalAssetRepository(repository.files);
  final maintenance = LocalStorageMaintenance(repository.files);
  // Interrupted work is the only source of staging directories; a fresh start
  // is the safe moment to clear the ones that are no longer in flight.
  StartupDiagnostics.mark('storage.staging_prune.begin');
  try {
    await maintenance.pruneStaging();
    StartupDiagnostics.mark('storage.staging_prune.complete');
  } catch (error) {
    StartupDiagnostics.failure('storage.staging_prune.nonfatal', error);
    // Best effort: cleanup must never block access to the projects themselves.
  }
  StartupDiagnostics.mark('services.construct.begin');
  const fullResolution = PlatformFullResolutionJpegCropper();
  final primaryModel = DocQuadNet256();
  final secondaryModel = DocAlignerFastViT();
  StartupDiagnostics.mark(
    'detector_adapters.constructed sessions=not_loaded',
  );
  final editor = LocalImageEditor(
    repository.files,
    readFullResolutionRegion: fullResolution.cropJpegRegion,
    boundaryProposer: BoundaryProposalCascade(
      primary: primaryModel,
      secondary: secondaryModel,
    ),
  );
  final camera = Platform.isAndroid
      ? CameraCapture(repository, assets, NativeCamera())
      : null;
  StartupDiagnostics.mark('camera_adapter.constructed capture=not_started');
  final service = ProjectService(
    repository,
    assets,
    camera: camera,
    imageEditor: editor,
    recovery: LocalProjectRecovery(repository, editor),
    backups: LocalProjectBackups(repository, repository.files),
    maintenance: maintenance,
  );
  StartupDiagnostics.mark('services.construct.complete');
  StartupDiagnostics.mark('storage.open.complete');
  return service;
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
  late Future<ProjectService> _service;
  bool _storageWaitingLogged = false;
  bool _storageFailureLogged = false;
  bool _homeFrameScheduled = false;

  /// Built once. The feed and the installer do not depend on which project is
  /// open or whether storage had to be recovered, and a service rebuilt per
  /// frame would ask the release feed again on every rebuild.
  final UpdateService _updates = buildPlatformUpdateService();

  @override
  void initState() {
    super.initState();
    StartupDiagnostics.mark('bootstrap.init_state');
    StartupDiagnostics.mark('update_service.constructed network=not_started');
    StartupDiagnostics.mark('storage.future.begin');
    _service = _openStorage();
  }

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
        if (!_storageWaitingLogged) {
          _storageWaitingLogged = true;
          StartupDiagnostics.mark('bootstrap.storage.waiting_for_service');
        }
        return const AppShell(
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
        );
      }
      if (snapshot.hasData) {
        if (!_homeFrameScheduled) {
          _homeFrameScheduled = true;
          StartupDiagnostics.mark('bootstrap.service_ready');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) StartupDiagnostics.mark('app.first_home_frame');
          });
        }
        return ScanIdApp(
          key: ValueKey(snapshot.requireData),
          service: snapshot.requireData,
          pickImages: _pickImages,
          recoverStorage: _recover,
          updateService: _updates,
        );
      }
      if (snapshot.hasError && !_storageFailureLogged) {
        _storageFailureLogged = true;
        StartupDiagnostics.failure('bootstrap.storage_future', snapshot.error!);
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
                                confirmLabel: 'استعادة نقاط الحفظ',
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
