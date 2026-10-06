#!/usr/bin/env python3
"""Run a real SDK command and retain its exit status and readable CI evidence.

Annotations let API-only clients inspect failures when the Actions blob/log
storage is unreachable. They are copies of SDK output, never substitute tests.
"""
import os
from pathlib import Path
import subprocess
import sys

sys.stdout.reconfigure(encoding='utf-8')
name, *command = sys.argv[1:]
Path('diagnostics').mkdir(exist_ok=True)
log = Path('diagnostics') / f'{name}.log'
with log.open('w', encoding='utf-8') as stream:
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True,
                               encoding='utf-8', errors='replace',
                               shell=os.name == 'nt')
    for line in process.stdout:
        print(line, end='', flush=True)
        stream.write(line)
    code = process.wait()
text = log.read_text(encoding='utf-8')
# Preserve enough context for assertions and stack traces; full logs remain
# in the normal workflow artifact. Do not weaken/ignore any failing command.
text = text[-48000:] if code else text[-1800:]
level = 'error' if code else 'notice'
# GitHub truncates annotation messages at 4096 UTF-8 bytes, not characters.
chunks, chunk, size = [], '', 0
for character in text:
    length = len(character.encode('utf-8'))
    if size + length > 3000:
        chunks.append(chunk)
        chunk, size = '', 0
    chunk += character
    size += length
if chunk:
    chunks.append(chunk)
for index, chunk in enumerate(chunks, start=1):
    escaped = chunk.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print(f'::{level} title={name} exit={code} part={index}::{escaped}')
sys.exit(code)
