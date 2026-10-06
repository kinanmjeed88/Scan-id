#!/usr/bin/env python3
"""Verify the PDFium archive actually downloaded by CMake and packaged notices."""
import hashlib
from pathlib import Path
expected = '1fd8af952832dbb0eb16d9249f68fe09e5f5ebf7c3dd9f6066ea2720cc28487d'
archives = list(Path('build/windows').rglob('pdfium-win-x64.tgz'))
if not archives:
    raise RuntimeError('Cannot verify the PDFium download: retained archive missing')
for archive in archives:
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError('PDFium archive hash mismatch')
notices = Path('build/windows/x64/runner/Release/data/pdfium-licenses')
if not any(p.is_file() and p.stat().st_size > 0 for p in notices.rglob('*')):
    raise RuntimeError('PDFium license notices were not packaged')
print('PDFium chromium/8086 archive SHA256 verified; license notices packaged with Windows.')
