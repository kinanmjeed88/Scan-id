import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/retirable_resource.dart';

void main() {
  test('retire defers disposal until all concurrent users finish', () async {
    var nextId = 0;
    final disposed = <int>[];
    final resource = RetirableResource<int>(
      create: () async => ++nextId,
      dispose: (id) async => disposed.add(id),
    );
    final first = Completer<void>();
    final second = Completer<void>();
    final a = resource.run((id) async {
      await first.future;
      return id;
    });
    final b = resource.run((id) async {
      await second.future;
      return id;
    });
    final retired = resource.retire();
    expect(disposed, isEmpty);
    expect(await resource.run((id) async => id), 2);
    first.complete();
    expect(await a, 1);
    expect(disposed, isEmpty);
    second.complete();
    expect(await b, 1);
    await retired;
    expect(disposed, [1]);
    await resource.retire();
    await resource.retire();
    expect(disposed, [1, 2]);
  });

  test('late creation after retirement is disposed once after use', () async {
    final created = Completer<int>();
    final useFinished = Completer<void>();
    final disposed = <int>[];
    final resource = RetirableResource<int>(
      create: () => created.future,
      dispose: (id) async => disposed.add(id),
    );
    final operation = resource.run((id) async {
      await useFinished.future;
      return id;
    });
    final retired = resource.retire();
    created.complete(7);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isEmpty);
    useFinished.complete();
    expect(await operation, 7);
    await retired;
    await resource.retire();
    expect(disposed, [7]);
  });

  test('a retired failed creation cannot clear a newer generation', () async {
    final old = Completer<int>();
    var attempts = 0;
    final disposed = <int>[];
    final resource = RetirableResource<int>(
      create: () {
        attempts++;
        return attempts == 1 ? old.future : Future<int>.value(2);
      },
      dispose: (id) async => disposed.add(id),
    );
    final operation = resource.run((id) async => id);
    final failure = expectLater(operation, throwsStateError);
    final retired = resource.retire();
    expect(await resource.run((id) async => id), 2);
    old.completeError(StateError('old'));
    await failure;
    await retired;
    expect(await resource.run((id) async => id), 2);
    expect(attempts, 2);
    await resource.retire();
    expect(disposed, [2]);
  });

  test(
    'failed creation is retried and does not dispose a nonexistent value',
    () async {
      var attempts = 0;
      final disposed = <int>[];
      final resource = RetirableResource<int>(
        create: () async {
          attempts++;
          if (attempts == 1) throw StateError('temporary');
          return 10;
        },
        dispose: (id) async => disposed.add(id),
      );
      await expectLater(resource.run((id) async => id), throwsStateError);
      expect(await resource.run((id) async => id), 10);
      await resource.retire();
      expect(disposed, [10]);
    },
  );
}
