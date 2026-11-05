import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/import_trace.dart';
import 'package:scan_id/application/stage_budget.dart';

void main() {
  test('a pending preprocessing stage is identifiable without claiming completion', () async {
    final events = <ImportTraceEvent>[];
    final trace = ImportTrace(onEvent: events.add);
    final gate = Completer<int>();
    final pending = runZoned(
      () => ImportTrace.stage('preprocessing', () => gate.future, phase: 'fake'),
      zoneValues: {ImportTrace.zoneKey: trace},
    );
    expect(events.single.event, 'preprocessing_started');
    expect(events.single.operationId, isNotNull);
    gate.complete(4);
    expect(await pending, 4);
    expect(events.last.event, 'preprocessing_completed');
    expect(events.last.operationId, events.first.operationId);
  });

  test('native failure and delayed completion remain correlated', () async {
    final events = <ImportTraceEvent>[];
    final trace = ImportTrace(onEvent: events.add);
    final gate = Completer<int>();
    final pending = runZoned(
      () => ImportTrace.stage('native', () => gate.future, phase: 'fake-inference'),
      zoneValues: {ImportTrace.zoneKey: trace},
    );
    trace.finish('import_cancelled');
    gate.complete(1);
    await pending;
    expect(events.last.event, 'native_completed');
    expect(events.last.late, isTrue);
    expect(events.last.taskId, trace.taskId);
    expect(events.last.operationId, events.first.operationId);
    await expectLater(runZoned(
      () => ImportTrace.stage<int>('native', () async => throw StateError('fake')),
      zoneValues: {ImportTrace.zoneKey: trace},
    ), throwsA(isA<StateError>()));
    expect(events.last.event, 'native_failed');
    expect(events.last.errorType, 'StateError');
  });

  test('bounded cancellation reports cancellation rather than completion', () async {
    final events = <ImportTraceEvent>[];
    final trace = ImportTrace(onEvent: events.add);
    final token = CancellationToken();
    final gate = Completer<int>();
    final pending = runZoned(
      () => ImportTrace.stage('recognition', () => requireStageWithin(
        () => gate.future,
        budget: const Duration(seconds: 10),
        name: 'image-analysis',
        cancellation: token,
      )),
      zoneValues: {ImportTrace.zoneKey: trace},
    );
    final expectation = expectLater(pending, throwsA(isA<OperationCancelled>()));
    token.cancel();
    await expectation;
    gate.complete(1);
    expect(events.any((e) => e.event == 'stage_cancelled'), isTrue);
    expect(events.last.event, 'recognition_cancelled');
  });
}
