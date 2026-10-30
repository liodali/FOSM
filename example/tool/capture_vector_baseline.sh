#!/bin/zsh
# Plan-01 vector-render baseline captures (attribution + user-visible arms).
# Usage: zsh tool/capture_vector_baseline.sh DEVICE_ID OUTPUT_DIR \
#          [LAN_IP] [CLEAN_REPS] [SPAN_REPS] [TRACE_REPS]
#
# Starts the deterministic payload server on the LAN IP, then runs the
# vector benchmark app on the device in profile mode:
#   clean   × CLEAN_REPS (default 3)  — user-visible numbers, no defines
#   spans   × SPAN_REPS (default 2)   — fosm.vectorSpans attribution
#   trace   × TRACE_REPS (default 1)  — spans + fosm.traceVector; the VM
#                                       timeline (MVT worker isolate
#                                       included) is saved as
#                                       <label>-timeline.json and
#                                       validated per scenario: the app
#                                       emits timeline boundary markers
#                                       per scenario, cold-like and
#                                       style-switch scenarios must show
#                                       worker parse events in their
#                                       window, and warm scenarios may
#                                       legitimately skip parsing. A
#                                       failing gate exits 3 — the
#                                       parse-vs-drawing conclusion
#                                       requires this saved artifact.
#
# Logs land in OUTPUT_DIR as <label>.log; parse them with
#   dart run tool/parse_benchmark_log.dart OUT/*.log > OUT/report.json
#   dart run tool/extract_vector_stages.dart OUT OUT/stages
set -euo pipefail

device="${1:?device id}"
out="${2:?output dir}"
lan_ip="${3:-$(ipconfig getifaddr en0)}"
clean_reps="${4:-3}"
span_reps="${5:-2}"
trace_reps="${6:-1}"
port=8787
base="http://${lan_ip}:${port}"

mkdir -p "$out"
cd "$(dirname "$0")/.."

echo "── payload server on ${lan_ip}:${port} (payload identity in server log)"
dart run tool/vector_payload_server.dart --host 0.0.0.0 --port "$port" \
  > "$out/payload-server.log" 2>&1 &
server_pid=$!
trap 'kill $server_pid 2>/dev/null || true' EXIT

for i in {1..30}; do
  if curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then break; fi
  if ! kill -0 $server_pid 2>/dev/null; then
    echo "payload server failed to start"; cat "$out/payload-server.log"; exit 1
  fi
  sleep 1
done

run_benchmark() {
  local label="$1"; shift
  local log="/tmp/fosm-vector-$label.log"
  echo "── run: $label $*"
  flutter run --profile --start-paused -d "$device" \
    -t lib/benchmark/map_vector_benchmark.dart \
    --dart-define=BENCHMARK_LABEL="$label" \
    --dart-define=BENCHMARK_VECTOR_BASE="$base" "$@" > "$log" 2>&1 &
  local flutter_pid=$!
  # Wait for the VM service URL, then subscribe and resume. The trace arm
  # also saves the VM timeline (all isolates — the MVT worker included)
  # and disables chunk-level spans: their volume floods the timeline ring
  # and evicts coarse stages; fine-grained CPU comes from profiler
  # samples instead.
  while ! grep -q 'Dart VM Service' "$log" 2>/dev/null; do
    if ! kill -0 $flutter_pid 2>/dev/null; then
      echo "flutter run exited early for $label"; cat "$log"; exit 1
    fi
    sleep 1
  done
  local wants_timeline=0
  for arg in "$@"; do
    if [[ "$arg" == *fosm.traceVector* ]]; then wants_timeline=1; fi
  done
  local timeline_args=()
  if [[ $wants_timeline -eq 1 ]]; then
    timeline_args=(--timeline "$out/$label-timeline.json")
  fi
  dart run tool/capture_benchmark.dart "$log" "${timeline_args[@]}" \
    > "$out/$label.log" 2>&1
  kill $flutter_pid 2>/dev/null || true
  wait $flutter_pid 2>/dev/null || true
  grep -c FOSM_BENCHMARK_RESULT "$out/$label.log" | \
    xargs -I{} echo "   {} result lines"
  grep -c FOSM_BENCHMARK_VECTOR_STAGES "$out/$label.log" | \
    xargs -I{} echo "   {} stage lines" || true
}

for rep in $(seq 1 "$clean_reps"); do
  run_benchmark "vector-clean-r$rep"
done
for rep in $(seq 1 "$span_reps"); do
  run_benchmark "vector-spans-r$rep" --dart-define=fosm.vectorSpans=true
done
for rep in $(seq 1 "$trace_reps"); do
  run_benchmark "vector-trace-r$rep" \
    --dart-define=fosm.vectorSpans=true --dart-define=fosm.traceVector=true \
    --dart-define=fosm.vectorTraceChunks=false
done

echo "done: $out (parse with parse_benchmark_log + extract_vector_stages)"
