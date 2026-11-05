/// Opt-in debug-only local journal. No images, OCR text or exception messages.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Enabled only by a debug build explicitly built with this dart-define.
const bool importJournalRequested = bool.fromEnvironment(
  'SCAN_ID_IMPORT_DIAGNOSTICS',
  defaultValue: false,
);

class ImportTraceStore {
  ImportTraceStore(
    this.taskId, {
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const maxQueuedEvents = 256;
  static const maxEventsPerTask = 2048;
  final String taskId;
  final Future<Directory> Function() _supportDirectory;
  final List<String> _queue = [];
  File? _file;
  bool _writing = false;
  bool _failed = false;
  Completer<void>? _idle;
  Future<void> get idle => _idle?.future ?? Future<void>.value();
  int _accepted = 0;
  int _dropped = 0;

  static ImportTraceStore? createIfEnabled(String taskId) =>
      kDebugMode && importJournalRequested ? ImportTraceStore(taskId) : null;

  /// Queues a bounded, already-sanitized record. Never waits for disk here.
  void add(Map<String, Object?> record) {
    if (_failed) return;
    if (_accepted >= maxEventsPerTask || _queue.length >= maxQueuedEvents) {
      _dropped++;
      if (_dropped == 1) {
        developer.log('journal_events_dropped', name: 'scan_id.import_trace');
        _queue.add(
          jsonEncode({'task': taskId, 'event': 'journal_events_dropped'}),
        );
        if (!_writing) {
          _idle = Completer<void>();
          unawaited(_drain());
        }
      }
      return;
    }
    _accepted++;
    _queue.add(jsonEncode({...record, 'dropped_events': _dropped}));
    if (!_writing) {
      _idle = Completer<void>();
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    if (_writing || _failed) return;
    _writing = true;
    try {
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(taskId)) {
        throw StateError('Invalid trace identifier');
      }
      if (_file == null) {
        final support = await _supportDirectory();
        final folder = Directory(
          '${support.path}${Platform.pathSeparator}import_diagnostics',
        );
        await folder.create(recursive: true);
        _file = File(
          '${folder.path}${Platform.pathSeparator}import_$taskId.jsonl',
        );
      }
      while (_queue.isNotEmpty) {
        final line = _queue.removeAt(0);
        await _file!.writeAsString(
          '$line\n',
          mode: FileMode.append,
          flush: true,
        );
      }
    } catch (error) {
      _failed = true;
      _queue.clear();
      developer.log(
        'journal_write_failed errorType=${error.runtimeType}',
        name: 'scan_id.import_trace',
      );
    } finally {
      _writing = false;
      _idle?.complete();
    }
  }
}
