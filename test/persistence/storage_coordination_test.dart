import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/persistence/safe_files.dart';
import 'package:scan_id/persistence/storage_coordination.dart';

void _holdStorageLock(List<Object?> arguments) async {
  final rootPath = arguments[0] as String;
  final ready = arguments[1] as SendPort;
  final release = ReceivePort();
  try {
    await StorageCoordination(SafeFiles(Directory(rootPath))).runExclusive(
      () async {
        ready.send(release.sendPort);
        await release.first;
      },
    );
  } finally {
    release.close();
  }
}

class _ObservedSafeFiles extends SafeFiles {
  _ObservedSafeFiles(super.root, this.lockPathChecked);

  final Completer<void> lockPathChecked;

  @override
  Future<String> checkedPath(String relative) async {
    final path = await super.checkedPath(relative);
    if (relative == storageCoordinationLockName &&
        !lockPathChecked.isCompleted) {
      lockPathChecked.complete();
    }
    return path;
  }
}

void main() {
  test('nested storage operations reuse the active lease', () async {
    final root = await Directory.systemTemp.createTemp('storage_lease_');
    try {
      final coordination = StorageCoordination(SafeFiles(root));
      var nestedActionRan = false;
      await coordination
          .runExclusive(() async {
            await coordination.runExclusive(() async {
              nestedActionRan = true;
            });
          })
          .timeout(const Duration(seconds: 3));
      expect(nestedActionRan, isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('an exception releases the lease for the next operation', () async {
    final root = await Directory.systemTemp.createTemp('storage_release_');
    try {
      final coordination = StorageCoordination(SafeFiles(root));
      await expectLater(
        coordination.runExclusive(() async {
          throw StateError('synthetic operation failure');
        }),
        throwsA(isA<StateError>()),
      );

      var nextOperationRan = false;
      await coordination
          .runExclusive(() async {
            nextOperationRan = true;
          })
          .timeout(const Duration(seconds: 3));
      expect(nextOperationRan, isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('exclusive lease blocks another isolate until release', () async {
    final root = await Directory.systemTemp.createTemp('storage_process_lock_');
    final ready = ReceivePort();
    final exited = ReceivePort();
    Isolate? holder;
    SendPort? release;
    Future<void>? contender;
    try {
      holder = await Isolate.spawn<List<Object?>>(_holdStorageLock, [
        root.path,
        ready.sendPort,
      ], onExit: exited.sendPort);
      release =
          await ready.first.timeout(const Duration(seconds: 5)) as SendPort;

      final entered = Completer<bool>();
      final lockPathChecked = Completer<void>();
      contender = StorageCoordination(_ObservedSafeFiles(root, lockPathChecked))
          .runExclusive(() async {
            if (!entered.isCompleted) entered.complete(true);
          });
      await lockPathChecked.future.timeout(const Duration(seconds: 5));

      // The holder acknowledges acquisition first; the contender confirms it
      // resolved the lock path, then must remain outside the action until release.
      final enteredWhileHeld = await entered.future.timeout(
        const Duration(milliseconds: 150),
        onTimeout: () => false,
      );
      expect(enteredWhileHeld, isFalse);

      release.send(null);
      await contender.timeout(const Duration(seconds: 5));
      expect(entered.isCompleted, isTrue);
    } finally {
      if (release != null) {
        release.send(null);
      } else {
        holder?.kill(priority: Isolate.immediate);
      }
      if (contender != null) {
        try {
          await contender.timeout(const Duration(seconds: 5));
        } on Object {
          // Preserve the original assertion/error while still releasing the
          // temporary lock holder during test cleanup.
        }
      }
      if (holder != null) {
        try {
          await exited.first.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          holder.kill(priority: Isolate.immediate);
          await exited.first.timeout(const Duration(seconds: 5));
        }
      }
      ready.close();
      exited.close();
      await root.delete(recursive: true);
    }
  });
}
