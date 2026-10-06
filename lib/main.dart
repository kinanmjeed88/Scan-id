import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'application/project_service.dart';
import 'persistence/local_asset_repository.dart';
import 'persistence/local_project_repository.dart';
import 'presentation/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Bootstrap());
}

Future<ProjectService> _openStorage() async {
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
  final repository = await LocalProjectRepository.open(
    Directory(p.join(support.path, 'scan_id')),
  );
  return ProjectService(repository, LocalAssetRepository(repository.files));
}

Future<List<ImportSource>> _pickImages() async {
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
  @override
  Widget build(BuildContext context) => FutureBuilder<ProjectService>(
    future: _service,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return ScanIdApp(
          service: snapshot.requireData,
          pickImages: _pickImages,
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
