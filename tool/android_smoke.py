#!/usr/bin/env python3
"""Real APK installation and offline startup on an Android emulator.

This is deliberately a startup check, not a claim about human workflows,
physical camera hardware or printing.
"""
import json
from pathlib import Path
import subprocess
import time

def adb(*args):
    return subprocess.check_output(['adb', *args], text=True, stderr=subprocess.STDOUT).strip()

package = 'iq.scanid.scan_id'
root = Path('diagnostics/android-device')
root.mkdir(parents=True, exist_ok=True)
adb('root')
adb('wait-for-device')
adb('install', '-r', 'android-package/app-release.apk')
adb('shell', 'svc', 'wifi', 'disable')
adb('shell', 'svc', 'data', 'disable')
adb('shell', 'settings', 'put', 'global', 'airplane_mode_on', '1')
adb('logcat', '-c')
adb('shell', 'am', 'start', '-W', '-n', f'{package}/.MainActivity')
time.sleep(12)
pid = adb('shell', 'pidof', package)
if not pid:
    raise RuntimeError('APK process did not remain alive')
window = adb('shell', 'dumpsys', 'window', 'windows')
if package not in window:
    raise RuntimeError('App window was not created')
log = adb('logcat', '-d', '--pid=' + pid)
(root / 'app-log.txt').write_text(log, encoding='utf-8')
if 'FATAL EXCEPTION' in log or 'Unhandled Exception:' in log:
    raise RuntimeError('Application startup failed; inspect log')
database = adb('shell', 'ls', '-l', f'/data/user/0/{package}/files/scan_id/projects.db')
if 'projects.db' not in database:
    raise RuntimeError('Private project database was not created')
with (root / 'screen.png').open('wb') as output:
    subprocess.run(['adb', 'exec-out', 'screencap', '-p'], stdout=output, check=True)
(root / 'proof.json').write_text(json.dumps({'package': package, 'pid': pid,
    'android': adb('shell', 'getprop', 'ro.build.version.release'),
    'airplane_mode': adb('shell', 'settings', 'get', 'global', 'airplane_mode_on'),
    'database': database, 'scope': 'emulator offline startup only'}, indent=2), encoding='utf-8')
print('Real release APK installed and stayed alive with a native window and private database on Android emulator; Wi-Fi/mobile data disabled.')
print('This is NOT a physical camera, interactive end-use or printing test.')
