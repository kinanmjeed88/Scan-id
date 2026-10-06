import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/project.dart';
import 'project_backups.dart';
import 'native_documents.dart';

/// Native dialogs and temporary file lifecycle are not widget responsibilities.
class BackupTransfer {
  const BackupTransfer(this.backups);
  final ProjectBackups backups;
  Future<bool> save(Project project) async {
    final file = await backups.create(project, await getTemporaryDirectory());
    try {
      return await saveDocument(file, 'application/octet-stream');
    } finally {
      await file.parent.delete(recursive: true);
    }
  }

  Future<Project?> restore() async {
    if (Platform.isAndroid) {
      final source = await pickAndroidBackup();
      if (source == null) {
        return null;
      }
      try {
        return await backups.restore(source);
      } finally {
        await removePickedFile(source);
      }
    }
    const group = XTypeGroup(
      label: 'Scan ID backup',
      extensions: ['scanid'],
      mimeTypes: ['application/octet-stream'],
    );
    final picked = await openFile(acceptedTypeGroups: [group]);
    if (picked == null) {
      return null;
    }
    final folder = await (await getTemporaryDirectory()).createTemp(
      'scan-restore-',
    );
    try {
      final file = File('${folder.path}/input.scanid');
      // File providers need not expose a native path; stream in bounded chunks.
      final writer = await file.open(mode: FileMode.write);
      try {
        var total = 0;
        await for (final chunk in picked.openRead()) {
          total += chunk.length;
          if (total > 64 * 1024 * 1024 * 1024 + 16 * 1024 * 1024 + 64) {
            throw const FileSystemException('Backup exceeds size budget');
          }
          await writer.writeFrom(chunk);
        }
      } finally {
        await writer.close();
      }
      return await backups.restore(file);
    } finally {
      await folder.delete(recursive: true);
    }
  }
}
