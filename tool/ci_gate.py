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
level = 'error' if code else 'notice'
# GitHub keeps only 10 annotations per step and truncates each message at
# 4096 UTF-8 bytes (not characters).
LIMIT, BYTES = 10, 3000


def chunked(value):
    chunks, chunk, size = [], '', 0
    for character in value:
        length = len(character.encode('utf-8'))
        if size + length > BYTES:
            chunks.append(chunk)
            chunk, size = '', 0
        chunk += character
        size += length
    if chunk:
        chunks.append(chunk)
    return chunks


parts = []
if code:
    # Every failed test WITH its reason and the final tally first, so a long log
    # can never push them out of the annotations; the end of the log follows.
    # The reporter indents the failure detail (Expected / Actual / Which, then a
    # blank line and the stack) under the test name. Collecting only the name
    # lines says WHICH test failed but never WHY, and the log blob store is
    # unreachable for API-only clients -- so the indented block is collected
    # too, up to the blank line that ends it.
    lines = text.splitlines()
    marks = []
    seen = set()
    for index, line in enumerate(lines):
        stripped = line.rstrip()
        if stripped.endswith('[E]'):
            # The reporter names each failure twice (inline and in the closing
            # summary); keep the first, which is the one carrying the detail.
            if stripped in seen:
                continue
            seen.add(stripped)
            marks.append(line)
            for detail in lines[index + 1:index + 41]:
                if detail[:1] not in (' ', '\t') or not detail.strip():
                    break
                marks.append(detail)
        elif ('tests failed' in line or 'All tests passed' in line
              or line.lstrip().startswith('error')):
            # The closing tally is printed once but matched again in the
            # summary; keep one copy of each such line.
            if stripped in seen:
                continue
            seen.add(stripped)
            marks.append(line)
    summary = chunked('\n'.join(marks))
    # The reasons for a failure outrank the tail of the log: keep as much of the
    # summary as the annotation budget allows and spend only the remainder on
    # the tail, always leaving room for at least one tail chunk.
    keep = min(len(summary), LIMIT - 1)
    parts += [('summary', chunk) for chunk in summary[:keep]]
    tail = chunked(text)[-(LIMIT - keep):]
else:
    tail = chunked(text[-1800:])
parts += [(str(index), chunk) for index, chunk in enumerate(tail, start=1)]
# Full logs remain in the workflow artifact. Never weaken a failing command.
for part, chunk in parts:
    escaped = chunk.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print(f'::{level} title={name} exit={code} part={part}::{escaped}')
sys.exit(code)
