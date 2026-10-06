#!/usr/bin/env python3
"""Show exactly how `dart format` would rewrite the tree, from the real SDK.

Without a local SDK the only authoritative formatting answer comes from CI, so
this step runs the real formatter, publishes the diff as check annotations (the
artifact blob store is not reachable by API-only clients), and restores the
files so the following `dart format --set-exit-if-changed` gate still fails
honestly when the tree is unformatted.

When the triggering commit message contains ``[format]`` the rewritten tree is
committed and pushed back to the same branch instead, so the formatter's own
output is applied exactly, never approximated by hand.
"""
from pathlib import Path
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding='utf-8')
apply_to_branch = os.environ.get('SCAN_ID_FORMAT_COMMIT') == '1'
code = subprocess.call(['dart', 'format', '.'])
if code != 0:
    sys.exit(code)
subprocess.call(['git', 'add', '-A'])
diff = subprocess.run(
    ['git', 'diff', '--cached'], capture_output=True, text=True,
    encoding='utf-8', errors='replace',
).stdout
if not diff.strip():
    print('PASS: the tree matches dart format exactly.')
    sys.exit(0)
print(f'Formatter rewrote files ({len(diff)} diff characters).')
if apply_to_branch and os.environ.get('GITHUB_EVENT_NAME') == 'push':
    subprocess.check_call(['git', 'config', 'user.name', 'scan-id formatter'])
    subprocess.check_call([
        'git', 'config', 'user.email', 'actions@github.com',
    ])
    subprocess.check_call(['git', 'commit', '-m', 'Apply dart format output'])
    branch = os.environ.get('GITHUB_REF_NAME')
    if not branch:
        print('REFUSED: no branch name in the environment.', file=sys.stderr)
        sys.exit(1)
    subprocess.check_call([
        'git', 'push', 'origin', f'HEAD:refs/heads/{branch}',
    ])
    print('Applied and pushed the formatter output to this branch.')
    sys.exit(0)
# Publish the diff, then restore so the gate reports the same failure again.
chunks, chunk, size = [], '', 0
for character in diff:
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
    print(f'::error title=format-diff part={index}::{escaped}')
subprocess.check_call(['git', 'reset'])
subprocess.check_call(['git', 'checkout', '--', '.'])
print('Restored the tree; the format gate below reports the real status.')
