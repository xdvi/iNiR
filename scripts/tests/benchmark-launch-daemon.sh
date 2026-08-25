#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

ITERATIONS="${1:-100}"
UNIT="inir-bench-test"

cleanup() {
    systemctl --user stop "${UNIT}.service" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Ensure clean slate
cleanup

# Start active dummy service
if ! systemd-run --user --quiet --unit="$UNIT" --description="Benchmark Unit" sleep 3600; then
    echo "Failed to launch benchmark test unit" >&2
    exit 1
fi

# Wait until unit is confirmed active
for _ in $(seq 1 20); do
    if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if ! systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    echo "Benchmark unit failed to transition to active state" >&2
    exit 1
fi

python3 - "$REPO_ROOT" "$UNIT" "$ITERATIONS" <<'PY'
import sys
import re
import time
import statistics
import subprocess
from pathlib import Path

repo_root = Path(sys.argv[1])
unit = sys.argv[2]
iterations = int(sys.argv[3])

qml_file = repo_root / "modules/common/functions/ShellExec.qml"
content = qml_file.read_text(encoding="utf-8")

env_match = re.search(r"readonly property string _envRestoreScript:\s*`([^`]+)`", content)
daemon_match = re.search(r"function launchDaemon\(opts:\s*var\):\s*void\s*\{[\s\S]*?const script = root\._envRestoreScript \+\s*`([^`]+)`", content)

if not env_match or not daemon_match:
    print("Error: Could not extract launchDaemon scripts from ShellExec.qml", file=sys.stderr)
    sys.exit(1)

script = env_match.group(1) + "\n" + daemon_match.group(1)
script = re.sub(r"\\(\$|`)", r"\1", script)

print(f"Running {iterations} iterations on active unit '{unit}'...")
latencies = []
for i in range(iterations):
    t0 = time.perf_counter()
    res = subprocess.run(
        ["/usr/bin/bash", "-lc", script, "inir-daemon", "/usr/bin/systemd-run", "Benchmark Unit", unit, "", "true"],
        capture_output=True
    )
    t1 = time.perf_counter()
    if res.returncode != 0:
        print(f"Iteration {i+1} failed with code {res.returncode}: {res.stderr.decode()}", file=sys.stderr)
        sys.exit(res.returncode)
    latencies.append((t1 - t0) * 1000.0)

latencies.sort()
mean_val = statistics.mean(latencies)
stdev_val = statistics.stdev(latencies) if len(latencies) > 1 else 0.0
p95_val = latencies[int(len(latencies) * 0.95)]
p50_val = statistics.median(latencies)
min_val = min(latencies)
max_val = max(latencies)
total_val = sum(latencies)

print("\n--- Latency Benchmark Results ---")
print(f"Iterations: {len(latencies)}")
print(f"Total time: {total_val:.2f} ms")
print(f"Mean:       {mean_val:.2f} ms")
print(f"Median:     {p50_val:.2f} ms")
print(f"Min:        {min_val:.2f} ms")
print(f"Max:        {max_val:.2f} ms")
print(f"p95:        {p95_val:.2f} ms")
print(f"StdDev:     {stdev_val:.2f} ms")
print("---------------------------------")
PY
