#!/usr/bin/env python3
"""Inspect the built release APK, not just the source manifest."""
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ['ANDROID_HOME'])
analyzer = sdk / 'cmdline-tools/latest/bin/apkanalyzer'
apk = Path('build/app/outputs/flutter-apk/app-release.apk')
xml = subprocess.check_output([str(analyzer), 'manifest', 'print', str(apk)], text=True)
Path('diagnostics').mkdir(exist_ok=True)
Path('diagnostics/release-manifest.xml').write_text(xml, encoding='utf-8')
root = ET.fromstring(xml)
android = '{http://schemas.android.com/apk/res/android}'
permissions = {node.get(android + 'name') for node in root.findall('uses-permission')}
for forbidden in ['android.permission.INTERNET', 'android.permission.CAMERA', 'android.permission.MANAGE_EXTERNAL_STORAGE',
                  'android.permission.READ_EXTERNAL_STORAGE', 'android.permission.WRITE_EXTERNAL_STORAGE']:
    if forbidden in permissions:
        raise RuntimeError(f'Unexpected release permission: {forbidden}')
application = root.find('application')
if application is None or application.get(android + 'allowBackup') != 'false':
    raise RuntimeError('Automatic backup must be disabled in the actual release APK')
if not application.get(android + 'dataExtractionRules'):
    raise RuntimeError('Android extraction policy missing after manifest merge')
providers = [node for node in application.findall('provider') if node.get(android + 'name', '').endswith('.CaptureFileProvider')]
if len(providers) != 1 or providers[0].get(android + 'exported') != 'false' or providers[0].get(android + 'grantUriPermissions') != 'true':
    raise RuntimeError('Scoped, non-exported camera provider missing from release APK')
paths = ET.parse('android/app/src/main/res/xml/capture_paths.xml').getroot()
if len(paths) != 1 or paths[0].tag != 'files-path' or paths[0].get('path') != 'captures/':
    raise RuntimeError('Camera provider must expose only the private captures directory')
print('Camera provider is non-exported with scoped URI grants; no CAMERA permission requested.')
print('Release APK verified: no Internet or broad storage permissions; automatic backup disabled.')
print('Declared permissions:', sorted(permissions))
print('Minimum Android SDK:', subprocess.check_output(
    [str(analyzer), 'manifest', 'min-sdk', str(apk)], text=True).strip())
