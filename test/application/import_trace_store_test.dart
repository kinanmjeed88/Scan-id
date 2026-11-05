import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/import_trace.dart';
import 'package:scan_id/application/import_trace_store.dart';

void main() {
  test(
    'local journal keeps pending operations and redacts arbitrary values',
    () async {
      final root = await Directory.systemTemp.createTemp('import-journal-');
      addTearDown(() async {
        await root.delete(recursive: true);
      });
      final store = ImportTraceStore(
        '0123456789abcdef0123456789abcdef',
        supportDirectory: () async => root,
      );
      final trace = ImportTrace(store: store);
      final gate = Completer<int>();
      final pending = runZoned(
        () => ImportTrace.stage(
          'native',
          () => gate.future,
          phase: 'docquad-inference',
        ),
        zoneValues: {ImportTrace.zoneKey: trace},
      );
      trace.emit(
        'source_failed',
        phase: 'document-name',
        error: StateError('PRIVATE-TEXT'),
      );
      await store.idle;
      final file = File(
        '${root.path}${Platform.pathSeparator}import_diagnostics'
        '${Platform.pathSeparator}import_${trace.taskId}.jsonl',
      );
      var text = await file.readAsString();
      expect(text, isNot(contains('document-name')));
      expect(text, isNot(contains('PRIVATE-TEXT')));
      final records = const LineSplitter()
          .convert(text)
          .map(jsonDecode)
          .toList();
      final outstanding = records.last['outstanding'] as List<dynamic>;
      expect(outstanding.single['phase'], 'docquad-inference');
      gate.complete(5);
      expect(await pending, 5);
      trace.finish('import_completed');
      await store.idle;
      text = await file.readAsString();
      final completed = const LineSplitter()
          .convert(text)
          .map(jsonDecode)
          .firstWhere((entry) => entry['event'] == 'native_completed');
      expect(completed['duration_ms'], isA<int>());
      expect(completed['outstanding'], isEmpty);
    },
  );
}
