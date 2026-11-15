"""OS lock-candidate diagnostics, not a test of Scan-id's storage protocol.

The app does not yet use these primitives. This probes independent handles and
real child processes, including abrupt owner death; it does not prove Android,
Dart FFI, Sembast, filesystem lifecycle, or protection against uncooperative IO.
"""

import os
import queue
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path


class Busy(Exception):
    pass


if sys.platform.startswith('linux'):
    import fcntl

    def acquire(path):
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError as error:
            os.close(fd)
            raise Busy() from error
        except BaseException:
            os.close(fd)
            raise

    def release(handle):
        os.close(handle)

elif sys.platform == 'win32':
    import ctypes
    from ctypes import wintypes

    _kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    _create = _kernel.CreateFileW
    _create.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
        wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    _create.restype = wintypes.HANDLE
    _close = _kernel.CloseHandle
    _close.argtypes = [wintypes.HANDLE]
    _close.restype = wintypes.BOOL
    _invalid_handle = ctypes.c_void_p(-1).value

    def acquire(path):
        # OPEN_ALWAYS with no sharing: the persistent filename is not the lock.
        handle = _create(str(path), 0x80000000 | 0x40000000, 0, None, 4, 0x80, None)
        if handle == _invalid_handle:
            error = ctypes.get_last_error()
            if error == 32:  # ERROR_SHARING_VIOLATION
                raise Busy()
            raise ctypes.WinError(error)
        return handle

    def release(handle):
        if not _close(handle):
            raise ctypes.WinError(ctypes.get_last_error())


def _child(path):
    try:
        handle = acquire(path)
    except Busy:
        print('busy', flush=True)
        return
    try:
        print('acquired', flush=True)
        sys.stdin.read(1)
    finally:
        release(handle)


def _line(process):
    """Wait for a pipe event, not a timing-based scheduling assumption."""
    result = queue.Queue()
    thread = threading.Thread(target=lambda: result.put(process.stdout.readline()), daemon=True)
    thread.start()
    try:
        return result.get(timeout=20).strip()
    except queue.Empty as error:
        raise AssertionError('child did not report its lock result') from error


@unittest.skipUnless(sys.platform.startswith('linux') or sys.platform == 'win32', 'unsupported host')
class StorageLockCandidateTest(unittest.TestCase):
    def test_real_process_exclusion_normal_close_and_owner_death(self):
        with tempfile.TemporaryDirectory(prefix='scan-lock-primitive-') as root:
            path = str(Path(root) / 'owner.lock')
            handle = acquire(path)
            child = None
            try:
                # A second open-file description in this process must conflict.
                with self.assertRaises(Busy):
                    acquire(path)
                child = subprocess.Popen(
                    [sys.executable, '-u', __file__, '--child', path],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True,
                )
                self.assertEqual(_line(child), 'busy')
                child.communicate(timeout=20)
                self.assertEqual(child.returncode, 0)
                child = None
                release(handle)
                handle = None

                # The pathname remains; a normal close alone releases ownership.
                self.assertTrue(Path(path).exists())
                child = subprocess.Popen(
                    [sys.executable, '-u', __file__, '--child', path],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True,
                )
                self.assertEqual(_line(child), 'acquired')
                with self.assertRaises(Busy):
                    acquire(path)
                child.kill()
                child.communicate(timeout=20)
                child = None
                self.assertTrue(Path(path).exists())
                handle = acquire(path)
            finally:
                if child is not None:
                    child.kill()
                    child.communicate(timeout=20)
                if handle is not None:
                    release(handle)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--child':
        _child(sys.argv[2])
    else:
        unittest.main()
