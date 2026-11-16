import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'safe_files.dart';

/// Stable root-level lock shared by project publication, recovery/restore and
/// destructive storage maintenance. Do not let GC remove or rename this file:
/// callers coordinate through an operating-system file lock on it.
const String storageCoordinationLockName = '.storage-coordination.lock';

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
// flock on a raw descriptor instead. The blocking flock call runs in a helper
// isolate; the descriptor remains process-wide and is closed by the owner. On
// Windows, Dart's LockFileEx-backed RandomAccessFile lock is used directly.
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32, Uint32);
typedef _OpenDart = int Function(Pointer<Uint8>, int, int);
typedef _FlockNative = Int32 Function(Int32, Int32);
typedef _FlockDart = int Function(int, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();

class _PosixFileLock {
  static bool get supported =>
      Platform.isAndroid ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  static DynamicLibrary get _libc => Platform.isAndroid
      ? DynamicLibrary.open('libc.so')
      : Platform.isLinux
      ? DynamicLibrary.open('libc.so.6')
      : DynamicLibrary.open('libSystem.B.dylib');

  static int _openAndLock(String path) {
    final libc = _libc;
    final malloc = libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = libc.lookupFunction<_FreeNative, _FreeDart>('free');
    final open = libc.lookupFunction<_OpenNative, _OpenDart>('open');
    final flock = libc.lookupFunction<_FlockNative, _FlockDart>('flock');
    final close = libc.lookupFunction<_CloseNative, _CloseDart>('close');
    final errnoLocation = libc.lookupFunction<_ErrnoNative, _ErrnoDart>(
      Platform.isAndroid
          ? '__errno'
          : Platform.isMacOS || Platform.isIOS
          ? '__error'
          : '__errno_location',
    );

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
      // O_RDWR | O_CREAT; Darwin uses a different O_CREAT value from Linux and
      // Android. Mode 0600 keeps the coordination file private on POSIX roots.
      final createFlag = Platform.isMacOS || Platform.isIOS ? 0x200 : 0x40;
      final descriptor = open(nativePath, 0x2 | createFlag, 0x180);
      if (descriptor < 0) {
        final error = errnoLocation().value;
        throw FileSystemException(
          'تعذر فتح قفل تنسيق التخزين.',
          path,
          OSError('errno=$error', error),
        );
      }

      // LOCK_EX is blocking. Running this small native wait in a helper isolate
      // keeps the caller's event loop responsive while another isolate/process
      // owns the lock. flock locks are associated with the open file description
      // and therefore contend even when both owners share one process.
      const lockExclusive = 2;
      while (flock(descriptor, lockExclusive) != 0) {
        final error = errnoLocation().value;
        if (error == 4) continue; // EINTR
        close(descriptor);
        throw FileSystemException(
          'تعذر الحصول على قفل تنسيق التخزين.',
          path,
          OSError('errno=$error', error),
        );
      }
      return descriptor;
    } finally {
      free(allocation);
    }
  }

  static Future<int> acquire(String path) =>
      Isolate.run(() => _openAndLock(path));

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
  const StorageCoordination(this.files);

  final SafeFiles files;

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
      if (_PosixFileLock.supported) {
        posixDescriptor = await _PosixFileLock.acquire(lockPath);
      } else {
        lockFile = await File(lockPath).open(mode: FileMode.append);
        await lockFile.lock(FileLock.exclusive);
        fileLocked = true;
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
