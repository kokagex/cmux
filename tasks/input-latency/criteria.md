# Input latency optimization — evaluation criteria

## 1. Delay reduction (HARD GATE)
- Median key delay during Claude Code streaming < 15ms (currently ~18ms)
- P95 key delay < 30ms (currently ~28ms, spike 58ms)
- No spikes > 40ms
- Measured via CMUX_KEY_LATENCY_PROBE=1 during active Claude Code session

## 2. No regressions (HARD GATE)
- File explorer still follows CWD
- Git status still updates
- Terminal responsiveness not degraded in idle

## 3. Processing time unchanged (SOFT GATE)
- terminal.keyDown.phase totalMs stays < 10ms
- No new main thread work added
