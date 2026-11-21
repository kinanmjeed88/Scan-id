/// Append-only, crash-tolerant storage for the comprehensive processing log.
///
/// One file per processing operation, one JSON event per line, flushed as each
/// event is produced. That shape is the durability mechanism: an app killed in
/// the middle of a batch loses at most the event that was being written, and
/// every stage that DID finish is already on disk. Reading the file back
/// replays those events into a [ProcessingReport] — including the fact that the
/// run never finished.
///
/// Constraints, in order:
///
/// - **Bounded.** A fixed number of recent operations and a fixed byte ceiling
///   per file, so years of use cannot fill storage with diagnostics.
/// - **Tolerant.** A damaged line is skipped, a damaged file reads as empty,
///   and reading never throws into the UI.
/// - **Private.** Events are written by [ProcessingLedger] and hold stage codes,
///   measured numbers and bounded sentences only — never recognized text,
///   image bytes or a filesystem path. This store adds nothing of its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../application/processing_ledger.dart';
import '../domain/processing_record.dart';

class LocalProcessingJournal implements ProcessingJournal {
  LocalProcessingJournal({
    Future<Directory> Function()? supportDirectory,
    this.maxOperations = 20,
    this.maxEventsPerOperation = 1200,
    this.maxBytesPerOperation = 1024 * 1024,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  /// Newest operations kept on disk. Older files are removed when a new
  /// operation is first written.
  final int maxOperations;

  /// Events accepted per operation. Past this, ordinary events are dropped but
  /// a final report is still written: losing the summary would defeat the log.
  final int maxEventsPerOperation;

  /// Hard ceiling for one operation's file. A single final report may exceed
  /// it, because refusing to write the summary would lose the answer.
  final int maxBytesPerOperation;

  static const String folderName = 'processing_journal';

  final Future<Directory> Function() _supportDirectory;

  // Different instances in the same isolate can share the folder. Serializing
  // writes prevents a lost line and a temporary-file race between them. It is
  // not an inter-process lock.
  static Future<void> _tail = Future<void>.value();
  static final Map<String, int> _admitted = {};

  Directory? _folder;
  final List<(String batch, String line)> _queue = [];
  bool _draining = false;
  bool _failed = false;
  Completer<void>? _idle;

  /// Diagnostics never make the pipeline wait. Events are queued and written in
  /// the background; a write failure stops further writes without touching the
  /// batch's own result.
  @override
  void add(Map<String, Object?> event) {
    if (_failed) return;
    final batch = event['batch'];
    if (batch is! String || !_validBatchId(batch)) return;
    final accepted = _admitted[batch] ?? 0;
    final isReport = event['event'] == 'report';
    if (!isReport && accepted >= maxEventsPerOperation) return;
    final String line;
    try {
      line = jsonEncode(event);
    } catch (_) {
      // A value that cannot be encoded is not worth failing a task over.
      return;
    }
    _admitted[batch] = accepted + 1;
    _queue.add((batch, line));
    if (!_draining) {
      _idle = Completer<void>();
      unawaited(_drain());
    }
  }

  /// Completes when every queued event has been written (or dropped).
  Future<void> get idle => _idle?.future ?? Future<void>.value();

  @override
  Future<List<ProcessingReport>> reports() async {
    await idle;
    final folder = await _resolveFolder(create: false);
    if (folder == null) return const [];
    final files = <File>[];
    try {
      await for (final entity in folder.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.jsonl')) continue;
        files.add(entity);
      }
    } on FileSystemException {
      return const [];
    }
    final reports = <ProcessingReport>[];
    for (final file in files) {
      final report = await _readFile(file);
      if (report != null) reports.add(report);
    }
    reports.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return List.unmodifiable(reports);
  }

  /// Newest report, or null when nothing was recorded.
  @override
  Future<ProcessingReport?> latest() async {
    final all = await reports();
    return all.isEmpty ? null : all.first;
  }

  /// The report of one operation, recovered from its own file.
  @override
  Future<ProcessingReport?> reportFor(String operationId) async {
    await idle;
    if (!_validBatchId(operationId)) return null;
    final folder = await _resolveFolder(create: false);
    if (folder == null) return null;
    final file = File(
      '${folder.path}${Platform.pathSeparator}'
      'operation_$operationId.jsonl',
    );
    try {
      if (!await file.exists()) return null;
    } on FileSystemException {
      return null;
    }
    return _readFile(file);
  }

  /// Deletes the whole journal. Projects and images are untouched.
  @override
  Future<void> clear() async {
    await idle;
    final folder = await _resolveFolder(create: false);
    if (folder == null) return;
    try {
      await for (final entity in folder.list()) {
        if (entity is File && entity.path.endsWith('.jsonl')) {
          await entity.delete();
        }
      }
      _admitted.clear();
    } on FileSystemException {
      // A failed clear leaves the files intact, which the next read reports.
    }
  }

  Future<Directory?> _resolveFolder({required bool create}) async {
    if (_folder != null) return _folder;
    try {
      final support = await _supportDirectory();
      final folder = Directory(
        '${support.path}${Platform.pathSeparator}$folderName',
      );
      if (create && !await folder.exists()) {
        await folder.create(recursive: true);
      }
      if (!await folder.exists()) return null;
      _folder = folder;
      return folder;
    } on Object {
      return null;
    }
  }

  Future<void> _drain() async {
    if (_draining || _failed) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final (batch, line) = _queue.removeAt(0);
        Map<String, Object?> event;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map) continue;
          event = Map<String, Object?>.from(decoded);
        } catch (_) {
          continue;
        }
        if (event['batch'] != batch) continue;
        final folder = await _resolveFolder(create: true);
        if (folder == null) {
          _failed = true;
          break;
        }
        final file = File(
          '${folder.path}${Platform.pathSeparator}operation_$batch.jsonl',
        );
        final isReport = event['event'] == 'report';
        final lineBytes = utf8.encode('$line\n').length;
        var wrote = false;
        await _exclusive(() async {
          var bytes = 0;
          try {
            if (await file.exists()) bytes = await file.length();
          } on FileSystemException {
            bytes = 0;
          }
          if (!isReport && bytes + lineBytes > maxBytesPerOperation) return;
          await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
          wrote = true;
        });
        if (wrote && (isReport || event['event'] == 'batch')) {
          await _prune(folder, keep: batch);
        }
      }
    } on Object {
      _failed = true;
    } finally {
      if (_failed) _queue.clear();
      _draining = false;
      _idle?.complete();
    }
  }

  /// Keeps the newest [maxOperations] files, by modification time.
  Future<void> _prune(Directory folder, {required String keep}) async {
    final files = <(File, DateTime)>[];
    try {
      await for (final entity in folder.list()) {
        if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
        final stat = await entity.stat();
        files.add((entity, stat.modified));
      }
    } on FileSystemException {
      return;
    }
    files.sort((a, b) => b.$2.compareTo(a.$2));
    final limit = maxOperations < 1 ? 1 : maxOperations;
    final keepName = 'operation_$keep.jsonl';
    final keepIndex = files.indexWhere(
      (entry) => entry.$1.uri.pathSegments.last == keepName,
    );
    final retained = files.take(limit).toList();
    if (keepIndex >= limit) {
      retained.removeLast();
      retained.add(files[keepIndex]);
    }
    final retainedPaths = {for (final entry in retained) entry.$1.path};
    for (final entry in files) {
      if (retainedPaths.contains(entry.$1.path)) continue;
      final name = entry.$1.uri.pathSegments.last;
      try {
        await entry.$1.delete();
        final id = name.startsWith('operation_')
            ? name.substring('operation_'.length, name.length - 6)
            : '';
        _admitted.remove(id);
      } on FileSystemException {
        // A file that cannot be deleted stays; the next prune retries.
      }
    }
  }

  Future<ProcessingReport?> _readFile(File file) async {
    try {
      final length = await file.length();
      // A file that ballooned past any sane bound is not read into memory.
      if (length > 8 * 1024 * 1024) return null;
      final content = await file.readAsString();
      final events = <Map<String, Object?>>[];
      String? batch;
      for (final line in const LineSplitter().convert(content)) {
        if (line.isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map) continue;
          final event = Map<String, Object?>.from(decoded);
          batch ??= event['batch'] is String ? event['batch'] as String : null;
          events.add(event);
        } catch (_) {
          // One damaged line must not hide the stages around it.
        }
      }
      batch ??= _batchFromFileName(file);
      if (batch == null || events.isEmpty) return null;
      return ProcessingLedger.tryRecover(batch, events);
    } on Object {
      return null;
    }
  }

  static String? _batchFromFileName(File file) {
    final name = file.uri.pathSegments.last;
    if (!name.startsWith('operation_') || !name.endsWith('.jsonl')) return null;
    final id = name.substring('operation_'.length, name.length - 6);
    return _validBatchId(id) ? id : null;
  }

  static bool _validBatchId(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(value);

  static Future<void> _exclusive(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.catchError((_) {});
    return next;
  }
}
