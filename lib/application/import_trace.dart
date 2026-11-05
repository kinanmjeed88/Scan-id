/// Privacy-safe diagnostic events for one import. Async work inherits the
/// context through its Dart zone; isolates and native code do not, so events
/// are emitted by their caller at dispatch and completion boundaries.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'cancellation.dart';
import 'ids.dart';
import 'import_trace_store.dart';
import 'stage_budget.dart';

class ImportTraceEvent {
  const ImportTraceEvent(
    this.taskId,
    this.event,
    this.elapsedMs,
    this.late, {
    this.phase,
    this.errorType,
    this.operationId,
    this.completed,
    this.total,
  });
  final String taskId;
  final String event;
  final int elapsedMs;
  final bool late;
  final String? phase;
  final String? errorType;
  final int? operationId;
  final int? completed;
  final int? total;
}

class ImportTrace {
  ImportTrace({this.onEvent, ImportTraceStore? store})
    : taskId = store?.taskId ?? newId(),
      _injectedStore = store;
  static final Object zoneKey = Object();
  static ImportTrace? get current => Zone.current[zoneKey] as ImportTrace?;
  static Future<T> stage<T>(
    String stage,
    Future<T> Function() operation, {
    String? phase,
  }) {
    final trace = current;
    return trace == null
        ? operation()
        : trace.measure(stage, operation, phase: phase);
  }

  static T syncStage<T>(String stage, T Function() operation) {
    final trace = current;
    if (trace == null) return operation();
    final operationId = trace.nextOperation();
    trace.emit('${stage}_started', operationId: operationId);
    try {
      final value = operation();
      trace.emit('${stage}_completed', operationId: operationId);
      return value;
    } catch (error) {
      trace.emit('${stage}_failed', operationId: operationId, error: error);
      rethrow;
    }
  }

  final String taskId;
  final void Function(ImportTraceEvent event)? onEvent;
  final Stopwatch _clock = Stopwatch()..start();
  final ImportTraceStore? _injectedStore;
  late final ImportTraceStore? _store =
      _injectedStore ?? ImportTraceStore.createIfEnabled(taskId);
  final Map<int, (String, String?, int)> _pending = {};
  String? _lastStarted;
  String? _lastCompleted;
  bool _pendingOverflow = false;
  bool _terminal = false;
  int _nextOperation = 0;
  int nextOperation() => ++_nextOperation;

  // Event and phase are fixed internal identifiers, never user-supplied text.
  void emit(
    String event, {
    String? phase,
    Object? error,
    int? operationId,
    int? completed,
    int? total,
  }) {
    final entry = ImportTraceEvent(
      taskId,
      event,
      _clock.elapsedMilliseconds,
      _terminal,
      phase: phase,
      errorType: error?.runtimeType.toString(),
      operationId: operationId,
      completed: completed != null && completed >= 0 && completed <= 100000
          ? completed
          : null,
      total: total != null && total >= 0 && total <= 100000 ? total : null,
    );
    _recordLocally(entry);
    developer.log(
      'task=${entry.taskId} event=${_safeEvent(entry.event)} elapsedMs=${entry.elapsedMs} '
      'late=${entry.late} phase=${_safePhase(entry.phase) ?? "none"} '
      'operation=${entry.operationId ?? 0} errorType=${_safeError(entry.errorType) ?? "none"}',
      name: 'scan_id.import_trace',
    );
    // Diagnostics must never change task behavior.
    try {
      onEvent?.call(entry);
    } catch (_) {}
  }

  // Journal fields are restricted even if a caller accidentally passes a
  // non-constant phase. Do not write arbitrary error messages or filenames.
  static const _phases = <String>{
    'source',
    'arrangement',
    'preview',
    'segmentation',
    'boundary',
    'import',
    'analysis',
    'apply-and-save',
    'other',
    'revision-conflict',
    'boundary-preview',
    'docquad',
    'docaligner',
    'docquad-session',
    'docaligner-session',
    'docquad-inference',
    'docaligner-inference',
    'docquad-operation',
    'docaligner-operation',
    'ocr-detection-session',
    'ocr-recognition-session',
    'ocr-detection-operation',
    'ocr-recognition-operation',
    'ocr-inference',
    'ocr-region',
    'tensor-create',
    'tensor-read',
    'tensor-release',
    'ocr-detector-tensor',
    'ocr-locate-lines',
    'ocr-line-tensors',
    'ocr-detection',
    'ocr-recognition',
    'ocr-alphabet',
    'image-analysis',
    'image-apply',
    'boundary-cascade',
    'pipeline-ocr',
    'ocr-close',
    'docquad-close',
    'docaligner-close',
    'crop-source',
    'classical-boundary-proposal',
    'crop-preview',
    'crop-auto-adjust',
    'docquad-preprocess',
    'docaligner-preprocess',
    'read-only',
  };
  static const _stages = <String>{
    'import',
    'source',
    'source_read',
    'asset_import',
    'decode',
    'image',
    'preprocessing',
    'detection',
    'ocr',
    'ocr_runtime',
    'recognition',
    'persistence',
    'native',
    'stage',
    'isolate',
    'ui_state',
    'progress',
    'dialog_close',
    'dialog_pop',
    'dialog_route',
    'pairing',
    'layout',
    'apply',
    'cleanup',
  };
  static const _outcomes = <String>{
    'started',
    'completed',
    'failed',
    'cancelled',
    'timeout',
    'unavailable',
    'spawned',
    'decoded',
    'applied',
    'update',
    'requested',
    'returned',
  };
  static const _errorTypes = <String>{
    'StateError',
    'ArgumentError',
    'FormatException',
    'FileSystemException',
    'PlatformException',
    'MissingPluginException',
    'ValidationException',
    'StorageException',
    'RevisionConflict',
    'OperationCancelled',
    'StageTimeout',
    'TimeoutException',
    'UnsupportedError',
  };
  static String? _safePhase(String? value) =>
      _phases.contains(value) ? value : null;
  static String? _safeError(String? value) =>
      value == null ? null : (_errorTypes.contains(value) ? value : 'Other');
  static String _safeEvent(String value) {
    final index = value.lastIndexOf('_');
    if (index < 0) return 'redacted';
    return _stages.contains(value.substring(0, index)) &&
            _outcomes.contains(value.substring(index + 1))
        ? value
        : 'redacted';
  }

  void _recordLocally(ImportTraceEvent entry) {
    final store = _store;
    if (store == null) return;
    final event = _safeEvent(entry.event);
    final phase = _safePhase(entry.phase);
    final op = entry.operationId;
    int? duration;
    if (event.endsWith('_started') && op != null) {
      _lastStarted = phase ?? event;
      if (_pending.length < 256) {
        _pending[op] = (event, phase, entry.elapsedMs);
      } else {
        _pendingOverflow = true;
      }
    } else if (op != null &&
        (event.endsWith('_completed') ||
            event.endsWith('_failed') ||
            event.endsWith('_cancelled') ||
            event.endsWith('_timeout') ||
            event.endsWith('_unavailable'))) {
      final start = _pending.remove(op);
      if (start != null) duration = entry.elapsedMs - start.$3;
      if (event.endsWith('_completed')) _lastCompleted = phase ?? event;
    }
    store.add({
      'task': taskId, 'event': event, 'phase': phase,
      'observed_utc': DateTime.now().toUtc().toIso8601String(),
      'operation': op, 'elapsed_ms': entry.elapsedMs, 'duration_ms': duration,
      'completed': entry.completed, 'total': entry.total,
      'late': entry.late, 'error_type': _safeError(entry.errorType),
      'last_started': _lastStarted, 'last_completed': _lastCompleted,
      // These are outstanding observations, not proof that the caller still
      // waits: an expired or cancelled owner may have abandoned native work.
      'outstanding': [
        for (final pending in _pending.entries.take(64))
          {
            'operation': pending.key,
            'event': pending.value.$1,
            'phase': pending.value.$2,
            'elapsed_ms': entry.elapsedMs - pending.value.$3,
          },
      ],
      'outstanding_truncated': _pendingOverflow || _pending.length > 64,
    });
  }

  Future<T> measure<T>(
    String stage,
    Future<T> Function() operation, {
    String? phase,
  }) async {
    final operationId = nextOperation();
    emit('${stage}_started', phase: phase, operationId: operationId);
    try {
      final value = await operation();
      emit('${stage}_completed', phase: phase, operationId: operationId);
      return value;
    } catch (error) {
      final outcome = error is OperationCancelled
          ? 'cancelled'
          : error is StageTimeout
          ? 'timeout'
          : 'failed';
      emit(
        '${stage}_$outcome',
        phase: phase,
        error: error,
        operationId: operationId,
      );
      rethrow;
    }
  }

  void finish(String event) {
    emit(event);
    _terminal = true;
  }
}
