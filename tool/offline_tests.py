#!/usr/bin/env python3
"""Run the real Flutter suite in a Linux network namespace, as the runner user.

Only loopback is enabled (Flutter's test harness needs its VM service). SDK and
packages must have been cached beforehand. No dependency install is attempted.
"""
import getpass
import os
from pathlib import Path
import shutil
import subprocess
import sys

env = os.environ.copy()
env['SCAN_ID_TEST_USER'] = getpass.getuser()
env['SCAN_ID_TEST_HOME'] = str(Path.home())
flutter = shutil.which('flutter')
if not flutter:
    raise RuntimeError('Real Flutter SDK is required')
code = subprocess.call([
    'sudo', '-E', 'unshare', '--net', 'bash', '-ec',
    'ip link set lo up; test -z "$(ip route show)"; '
    'export HOME="$SCAN_ID_TEST_HOME"; '
    'exec runuser --preserve-environment -u "$SCAN_ID_TEST_USER" -- "$@"',
    'offline-flutter', flutter, 'test', '--no-pub', '--coverage', '--reporter', 'expanded',
], env=env)
print('Linux test process and child isolates had loopback only, no external network route.', flush=True)
sys.exit(code)
