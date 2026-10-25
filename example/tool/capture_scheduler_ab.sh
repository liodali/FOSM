#!/bin/zsh
# Plan-11 scheduler A/B captures on the connected iPhone.
# Usage: zsh tool/capture_scheduler_ab.sh DEVICE_ID OUTPUT_DIR
# Four runs: paced/unpaced × warm-standard and coldnet-load.
set -euo pipefail

device="${1:?device id}"
out="${2:?output dir}"
mkdir -p "$out"
cd "$(dirname "$0")/.."

run_benchmark() {
  local label="$1"; shift
  local log="/tmp/fosm-$label.log"
  echo "── run: $label $*"
  flutter run --profile --start-paused -d "$device" \
    -t lib/benchmark/map_benchmark.dart \
    --dart-define=BENCHMARK_LABEL="$label" "$@" > "$log" 2>&1 &
  local flutter_pid=$!
  # Wait for the VM service URL, then subscribe and resume.
  while ! grep -q 'Dart VM Service' "$log" 2>/dev/null; do
    if ! kill -0 $flutter_pid 2>/dev/null; then
      echo "flutter run exited early for $label"; cat "$log"; exit 1
    fi
    sleep 1
  done
  dart run tool/capture_benchmark.dart "$log" > "$out/$label.log" 2>&1
  kill $flutter_pid 2>/dev/null || true
  wait $flutter_pid 2>/dev/null || true
  grep -c FOSM_BENCHMARK_RESULT "$out/$label.log" | \
    xargs -I{} echo "   {} result lines"
}

run_benchmark paced
run_benchmark unpaced --dart-define=fosm.unpaced=true
run_benchmark paced-coldnet --dart-define=BENCHMARK_LOAD=true \
  --dart-define=BENCHMARK_NET_DELAY_MS=150 --dart-define=BENCHMARK_NET_KBPS=1000 \
  --dart-define=BENCHMARK_SAMPLE_SECONDS=12
run_benchmark unpaced-coldnet --dart-define=fosm.unpaced=true \
  --dart-define=BENCHMARK_LOAD=true \
  --dart-define=BENCHMARK_NET_DELAY_MS=150 --dart-define=BENCHMARK_NET_KBPS=1000 \
  --dart-define=BENCHMARK_SAMPLE_SECONDS=12

echo "done: $out"
