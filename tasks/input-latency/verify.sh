#!/usr/bin/env bash
# Input latency — automated evaluator
# Parses key latency logs and grades against criteria.
#
# Usage:
#   1. Run DEV build with CMUX_KEY_LATENCY_PROBE=1
#   2. Use Claude Code for a few minutes (type while output is streaming)
#   3. Run: ./tasks/input-latency/verify.sh [log-file]
set -euo pipefail

LOG="${1:-/tmp/cmux-debug-key-latency.log}"
RESULT_FILE="tasks/input-latency/eval-result.md"

if [ ! -f "$LOG" ]; then
    echo "FAIL: Log file not found: $LOG"
    exit 1
fi

echo "=== Input latency evaluator ==="
echo "Log: $LOG"
echo ""

python3 -c "
import re, sys

delays = []
process_times = []

with open('$LOG') as f:
    for line in f:
        if 'typing.phase path=terminal.keyDown.phase' not in line:
            continue
        dm = re.search(r'delayMs=([0-9.]+)', line)
        tm = re.search(r'totalMs=([0-9.]+)', line)
        if dm and tm:
            delays.append(float(dm.group(1)))
            process_times.append(float(tm.group(1)))

if not delays:
    print('NO DATA — no key events found in log')
    sys.exit(1)

delays.sort()
n = len(delays)
median = delays[n // 2]
p95 = delays[int(n * 0.95)]
max_d = max(delays)
spikes_40 = sum(1 for d in delays if d > 40)
avg_process = sum(process_times) / len(process_times)

print(f'Samples:     {n}')
print(f'Delay median: {median:.1f}ms')
print(f'Delay P95:    {p95:.1f}ms')
print(f'Delay max:    {max_d:.1f}ms')
print(f'Spikes >40ms: {spikes_40}')
print(f'Process avg:  {avg_process:.2f}ms')
print()

c1 = 'PASS' if median < 15 else 'FAIL'
c2 = 'PASS' if p95 < 30 else 'FAIL'
c3 = 'PASS' if spikes_40 == 0 else 'FAIL'
c4 = 'PASS' if avg_process < 10 else 'FAIL'

print(f'Criterion 1 (median <15ms):    {c1} ({median:.1f}ms)')
print(f'Criterion 2 (P95 <30ms):       {c2} ({p95:.1f}ms)')
print(f'Criterion 3 (no spikes >40ms): {c3} ({spikes_40} spikes)')
print(f'Criterion 4 (process <10ms):   {c4} ({avg_process:.2f}ms)')

verdict = 'ALL PASS' if all(x == 'PASS' for x in [c1, c2, c3, c4]) else 'NEEDS WORK'
print(f'\nVerdict: {verdict}')

with open('$RESULT_FILE', 'w') as f:
    f.write(f'# Input latency evaluation\n')
    f.write(f'Date: $(date \"+%Y-%m-%d %H:%M:%S\")\n')
    f.write(f'Samples: {n}\n\n')
    f.write(f'## Grades\n')
    f.write(f'- Delay median <15ms: **{c1}** ({median:.1f}ms)\n')
    f.write(f'- Delay P95 <30ms: **{c2}** ({p95:.1f}ms)\n')
    f.write(f'- No spikes >40ms: **{c3}** ({spikes_40} spikes)\n')
    f.write(f'- Process avg <10ms: **{c4}** ({avg_process:.2f}ms)\n')
    f.write(f'\n## Verdict: {verdict}\n')
"
