import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import '../application/contracts.dart';
import 'safe_files.dart';

/// Stable root-level lock shared by project publication, recovery/restore and
/// destructive storage maintenance. Do not let GC remove or rename this file:
/// callers coordinate through an operating-system file lock on it.
const String storageCoordinationLockName = '.storage-coordination.lock';

/// Upper bound on waiting for the storage lock. A dead holder is released by
/// the kernel when its process exits; a live holder that never finishes must
/// not freeze save/import forever.
const Duration defaultStorageLockAcquireTimeout = Duration(seconds: 20);

final Object _storageCoordinationZoneKey = Object();
final Map<String, _LocalMutex> _localMutexes = {};

class _LocalMutex {
  Future<void> tail = Future<void>.value();
  int users = 0;
}

class _Lease {
  bool active = true;
}

// RandomAccessFile.lock uses process-associated fcntl locks on POSIX. Those do
// not exclude another Dart isolate in the SAME process, so POSIX targets use
// flock on a raw descriptor instead. Non-blocking flock runs in a helper
// isolate with a timeout; the owner closes the process-wide descriptor. On
// Windows, Dart's LockFileEx-backed RandomAccessFile lock is polled.
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32);
typedef _OpenDart = int Function(Pointer<Uint8>, int);
typedef _FlockNative = Int32 Function(Int32, Int32);
typedef _FlockDart = int Function(int, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();

int _posixOpenAndLock(String path, int timeoutMs) =>
    _PosixFileLock.openAndLock(path, timeoutMs);

/// Polls the non-blocking exclusive lock until [timeout]. Dart's
/// [FileLock.exclusive] fails immediately when another handle holds the
/// file, so without a wait a brief overlap aborts save on Windows.
Future<void> _acquireWindowsLock(
  RandomAccessFile lockFile,
  String path,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      await lockFile.lock(FileLock.exclusive);
      return;
    } on FileSystemException {
      if (!DateTime.now().isBefore(deadline)) {
        throw FileSystemException(
          'تعذر قفل مساحة التخزين في الوقت المحدد.',
          path,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

class _PosixFileLock {
  static bool get supported =>
      Platform.isAndroid ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  static DynamicLibrary get _libc {
    final libraries = <DynamicLibrary>[];
    void tryOpen(DynamicLibrary Function() open) {
      try {
        libraries.add(open());
      } on Object {
        // Try the next candidate; Android linker namespaces differ by device.
      }
    }

    tryOpen(DynamicLibrary.process);
    if (Platform.isAndroid) {
      tryOpen(() => DynamicLibrary.open('libc.so'));
    } else if (Platform.isLinux) {
      tryOpen(() => DynamicLibrary.open('libc.so.6'));
    } else {
      tryOpen(() => DynamicLibrary.open('libSystem.B.dylib'));
    }
    for (final library in libraries) {
      final hasErrno =
          library.providesSymbol('__errno') ||
          library.providesSymbol('__errno_location') ||
          library.providesSymbol('__error');
      if (hasErrno &&
          library.providesSymbol('flock') &&
          library.providesSymbol('open') &&
          library.providesSymbol('close') &&
          library.providesSymbol('malloc') &&
          library.providesSymbol('free')) {
        return library;
      }
    }
    throw const FileSystemException('تعذر تحميل رموز قفل التخزين.');
  }

  static _ErrnoDart _errnoLocation(DynamicLibrary libc) {
    const names = <String>[
      '__errno',
      '__errno_location',
      '__error',
    ];
    for (final name in names) {
      if (!libc.providesSymbol(name)) continue;
      return libc.lookupFunction<_ErrnoNative, _ErrnoDart>(name);
    }
    throw const FileSystemException('تعذر قراءة حالة قفل التخزين.');
  }

  static int openAndLock(String path, int timeoutMs) {
    final libc = _libc;
    final malloc = libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = libc.lookupFunction<_FreeNative, _FreeDart>('free');
    final open = libc.lookupFunction<_OpenNative, _OpenDart>('open');
    final flock = libc.lookupFunction<_FlockNative, _FlockDart>('flock');
    final close = libc.lookupFunction<_CloseNative, _CloseDart>('close');
    final errnoLocation = _errnoLocation(libc);

    final encoded = utf8.encode(path);
    final allocation = malloc(encoded.length + 1);
    if (allocation == nullptr) {
      throw FileSystemException('تعذر تخصيص مسار قفل التخزين.', path);
    }
    final nativePath = allocation.cast<Uint8>();
    for (var i = 0; i < encoded.length; i++) {
      nativePath[i] = encoded[i];
    }
    nativePath[encoded.length] = 0;

    try {
      // Two-argument open(O_RDWR) avoids the variadic open(path, flags, mode)
      // ABI on ARM64. The caller creates the file before this isolate runs.
      final descriptor = open(nativePath, 0x2);
      if (descriptor < 0) {
        final error = errnoLocation().value;
        throw FileSystemException(
          'تعذر فتح قفل تنسيق التخزين.',
          path,
          OSError('errno=$error', error),
        );
      }

      // LOCK_EX|LOCK_NB so a timeout can close the descriptor instead of
      // leaking a helper isolate that later holds the lock forever.
      const lockExclusive = 2;
      const lockNonBlocking = 4;
      final deadline = DateTime.now().millisecondsSinceEpoch + timeoutMs;
      while (true) {
        if (flock(descriptor, lockExclusive | lockNonBlocking) == 0) {
          return descriptor;
        }
        final error = errnoLocation().value;
        if (error == 4) continue; // EINTR
        final wouldBlock = error == 11 || error == 35; // EAGAIN / EWOULDBLOCK
        if (!wouldBlock) {
          close(descriptor);
          throw FileSystemException(
            'تعذر الحصول على قفل تنسيق التخزين.',
            path,
            OSError('errno=$error', error),
          );
        }
        if (DateTime.now().millisecondsSinceEpoch >= deadline) {
          close(descriptor);
          throw FileSystemException(
            'تعذر قفل مساحة التخزين في الوقت المحدد.',
            path,
            OSError('timeout', 110),
          );
        }
        sleep(const Duration(milliseconds: 20));
      }
    } finally {
      free(allocation);
    }
  }

  static Future<int> acquire(String path, Duration timeout) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        await file.create();
      }
      return await Isolate.run(
        () => _posixOpenAndLock(path, timeout.inMilliseconds),
      );
    } on FileSystemException {
      rethrow;
    } on Object catch (error) {
      throw FileSystemException(
        'تعذر بدء قفل تنسيق التخزين.',
        path,
        OSError('$error', 0),
      );
    }
  }

  /// Closing the descriptor releases flock even if an explicit unlock were to
  /// fail. Always close it so success and exception paths release the lease.
  static void release(int descriptor) {
    final libc = _libc;
    final close = libc.lookupFunction<_CloseNative, _CloseDart>('close');
    close(descriptor);
  }
}

/// Cross-isolate and cross-process serialization for mutations that publish
/// project/recovery references or delete files those references may name.
///
/// The process-local queue prevents two handles in one isolate from relying on
/// platform-specific same-isolate lock semantics. The OS file lock is the
/// cross-isolate/process boundary and the kernel releases it when the owning
/// process exits or crashes. Nested calls in the same awaited async flow are
/// re-entrant through a Zone lease, so e.g. backup restoration can hold the
/// protocol across file extraction and then call the repository's `create`.
class StorageCoordination {
  const StorageCoordination(
    this.files, {
    this.acquireTimeout = defaultStorageLockAcquireTimeout,
  });

  final SafeFiles files;
  final Duration acquireTimeout;

  Future<T> runExclusive<T>(Future<T> Function() action) async {
    final lockPath = await files.checkedPath(storageCoordinationLockName);
    final key = Platform.isWindows ? lockPath.toLowerCase() : lockPath;
    final inherited = Zone.current[_storageCoordinationZoneKey];
    final leases = inherited is Map<String, _Lease>
        ? inherited
        : const <String, _Lease>{};
    final lease = leases[key];
    if (lease?.active ?? false) return action();

    final mutex = _localMutexes.putIfAbsent(key, _LocalMutex.new);
    final turn = Completer<void>();
    final previous = mutex.tail;
    mutex.tail = turn.future;
    mutex.users++;

    RandomAccessFile? lockFile;
    int? posixDescriptor;
    var fileLocked = false;
    _Lease? currentLease;
    try {
      await previous;
      try {
        if (_PosixFileLock.supported) {
          posixDescriptor = await _PosixFileLock.acquire(
            lockPath,
            acquireTimeout,
          );
        } else {
          lockFile = await File(lockPath).open(mode: FileMode.append);
          await _acquireWindowsLock(lockFile, lockPath, acquireTimeout);
          fileLocked = true;
        }
      } on FileSystemException catch (error) {
        throw StorageException(
          error.message.contains('الوقت المحدد')
              ? 'تعذر حفظ البيانات لأن عملية تخزين أخرى ما زالت جارية. أعد المحاولة.'
              : 'تعذر قفل مساحة المشاريع؛ أعد المحاولة.',
        );
      }
      final acquiredLease = _Lease();
      currentLease = acquiredLease;
      return await runZoned(
        action,
        zoneValues: {
          _storageCoordinationZoneKey: {...leases, key: acquiredLease},
        },
      );
    } finally {
      if (currentLease != null) currentLease.active = false;
      try {
        if (posixDescriptor != null) {
          _PosixFileLock.release(posixDescriptor);
        } else if (lockFile != null) {
          try {
            if (fileLocked) await lockFile.unlock();
          } finally {
            await lockFile.close();
          }
        }
      } finally {
        turn.complete();
        mutex.users--;
        if (mutex.users == 0 && identical(_localMutexes[key], mutex)) {
          _localMutexes.remove(key);
        }
      }
    }
  }
}
