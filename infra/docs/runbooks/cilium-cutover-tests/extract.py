#!/usr/bin/env python3
"""Extracts every OP block from the Cilium cutover runbook into OUT/<id>.cmd (the whole Bash call ops sends) and
OUT/<id>.sh (its script, for shellcheck).

Each block must be one call: the fixed wrapper (the saved profile's check, the clock, `nix develop` on the saved
store path), `<<'OP'`, a `# <id> …` header, and the closing `OP` as its last line. Blocks must fit a phone: at most
MAX_BYTES each and MAX_COLS characters per line.

Usage: extract.py RUNBOOK OUT
"""
import os
import re
import sys

MAX_BYTES = 4800
MAX_COLS = 120
WRAPPER = '''trap 'exit 143' TERM INT HUP   # a cancelled step exits 143, whichever the signal
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \\
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
'''
INIT = "trap 'exit 143' TERM INT HUP   # a cancelled step exits 143\nbash -s <<'OP'\n"   # 0.0: no profile yet

runbook, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
errors = []
blocks = {}
# Bytes as committed: no newline translation, so a call is exactly what a copy from the file gives.
with open(runbook, encoding='utf-8', newline='') as f:
    source = f.read()
if '\r' in source:
    errors.append('carriage returns in the runbook')
for m in re.finditer(r'^```sh\n(.*?)^```$', source, re.S | re.M):
    text = m.group(1)
    if "<<'OP'" not in text:
        continue   # the VM's helpers, sourced on the VM rather than sent to ops
    wrapper = WRAPPER if text.startswith(WRAPPER) else INIT if text.startswith(INIT) else None
    if wrapper is None:
        errors.append(f'a block without the wrapper: {text.splitlines()[0][:60]}')
        continue
    script = text[len(wrapper):]
    if not script.endswith('\nOP\n') or script[:-len('OP\n')].count('\nOP\n'):
        errors.append(f'a block that is not one call ending in OP: {script.splitlines()[0][:60]}')
        continue
    head = script.splitlines()[0]
    if not head.startswith('# '):
        errors.append(f'a block without a "# <id>" header: {head[:60]}')
        continue
    bid = head[2:].split(' ')[0].rstrip(',')
    if bid in blocks:
        errors.append(f'block {bid} appears twice')
    if (wrapper is INIT) != (bid == '0.0'):
        errors.append(f'block {bid} has the wrong wrapper')
    size = len(text.encode())
    cols = max(len(line) for line in text.splitlines())
    if size > MAX_BYTES or cols > MAX_COLS:
        errors.append(f'block {bid}: {size} bytes, longest line {cols} (limits {MAX_BYTES}, {MAX_COLS})')
    blocks[bid] = (text, script[:-len('OP\n')], size, cols)

for bid, (text, script, size, cols) in sorted(blocks.items()):
    with open(f'{out}/{bid}.cmd', 'w', encoding='utf-8', newline='') as f:
        f.write(text)
    with open(f'{out}/{bid}.sh', 'w', encoding='utf-8', newline='') as f:
        f.write(script)
    print(f'{bid:10s} {size:5d} bytes, longest line {cols}')
print(len(blocks), 'blocks')
for e in errors:
    print('ERROR', e, file=sys.stderr)
sys.exit(1 if errors or not blocks else 0)
