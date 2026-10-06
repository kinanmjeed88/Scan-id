#!/usr/bin/env python3
"""Archive SDK-generated runner sources and lockfile, not build products.

The small base64 copy in check annotations is a fallback for clients that can
reach GitHub's API but cannot download Actions artifacts from Azure storage.
"""
import base64
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
import sys

part = int(sys.argv[1]) if len(sys.argv) > 1 else 0
if part == 0:
    paths = subprocess.check_output([
        'git', 'ls-files', '--others', '--exclude-standard', '--',
        'android', 'windows', '.metadata', 'pubspec.lock',
    ], text=True).splitlines()
    # Include the resolved lock even after it has been checked into the repository.
    if Path('pubspec.lock').is_file() and 'pubspec.lock' not in paths:
        paths.append('pubspec.lock')
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for name in paths:
            path = Path(name)
            if path.is_file() and not path.is_symlink():
                archive.add(path, arcname=name, recursive=False)
    data = buffer.getvalue()
    Path('diagnostics').mkdir(exist_ok=True)
    Path('diagnostics/generated-source.tar.gz').write_bytes(data)
    if len(data) > 240000:
        raise RuntimeError('Generated source archive is unexpectedly large; inspect normal artifact')
else:
    data = Path('diagnostics/generated-source.tar.gz').read_bytes()
encoded = base64.b64encode(data).decode('ascii')
if part == 0:
    print(f'::notice title=generated-source sha256::{hashlib.sha256(data).hexdigest()}')
# GitHub retains at most 10 notices per step, so publish at most 8 chunks.
for index in range(part * 24000, min(len(encoded), (part + 1) * 24000), 3000):
    print(f'::notice title=generated-source chunk={index // 3000 + 1:03d}::{encoded[index:index + 3000]}')
