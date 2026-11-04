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
# Set BENCHMARK_DASH_DIAGNOSTICS=1 for instrumented dash counts and timings.
# BENCHMARK_SCENARIO selects one exact scenario; BENCHMARK_DASH_CULL=1
# enables the experimental dash-culling candidate.
# BENCHMARK_FIXTURE_DIR and BENCHMARK_FIXTURE_ID select recorded MVT tiles.
# BENCHMARK_LATITUDE and BENCHMARK_LONGITUDE select the benchmark center.
set -euo pipefail

device="${1:?device id}"
out="${2:?output dir}"
lan_ip="${3:-$(ipconfig getifaddr en0)}"
clean_reps="${4:-3}"
span_reps="${5:-2}"
trace_reps="${6:-1}"
port=8787
base="http://${lan_ip}:${port}"
dash_args=()
fixture_args=()
if [[ -n "${BENCHMARK_FIXTURE_DIR:-}" ]]; then
  : "${BENCHMARK_FIXTURE_ID:?fixture runs require BENCHMARK_FIXTURE_ID}"
  fixture_args=(--fixture-dir "$BENCHMARK_FIXTURE_DIR")
  dash_args+=(--dart-define=BENCHMARK_PAYLOAD_IDENTITY="$BENCHMARK_FIXTURE_ID"
    --dart-define=BENCHMARK_VECTOR_PROFILE=fixture)
fi
if [[ "${BENCHMARK_DASH_DIAGNOSTICS:-0}" == 1 ]]; then
  dash_args+=(--dart-define=fosm.vectorDashDiagnostics=true)
fi
if [[ "${BENCHMARK_DASH_CULL:-0}" == 1 ]]; then
  dash_args+=(--dart-define=fosm.vectorDashCull=true)
fi
# Plan-05 scheduler A/B overrides (defaults reproduce shipped pacing).
if [[ -n "${BENCHMARK_WORK_BUDGET_MS:-}" ]]; then
  dash_args+=(--dart-define=fosm.workBudgetMs="$BENCHMARK_WORK_BUDGET_MS")
fi
if [[ -n "${BENCHMARK_IMAGE_STARTS:-}" ]]; then
  dash_args+=(--dart-define=fosm.imageStartsPerFrame="$BENCHMARK_IMAGE_STARTS")
fi
if [[ -n "${BENCHMARK_ACTIVE_IMAGES:-}" ]]; then
  dash_args+=(--dart-define=fosm.activeImages="$BENCHMARK_ACTIVE_IMAGES")
fi
if [[ -n "${BENCHMARK_SCENARIO:-}" ]]; then
  dash_args+=(--dart-define=BENCHMARK_SCENARIO="$BENCHMARK_SCENARIO")
fi
if [[ -n "${BENCHMARK_LATITUDE:-}" && -n "${BENCHMARK_LONGITUDE:-}" ]]; then
  dash_args+=(--dart-define=BENCHMARK_LATITUDE="$BENCHMARK_LATITUDE"
    --dart-define=BENCHMARK_LONGITUDE="$BENCHMARK_LONGITUDE")
elif [[ -n "${BENCHMARK_LATITUDE:-}" || -n "${BENCHMARK_LONGITUDE:-}" ]]; then
  echo "BENCHMARK_LATITUDE and BENCHMARK_LONGITUDE must both be set" >&2
  exit 2
fi

mkdir -p "$out"
cd "$(dirname "$0")/.."

echo "── payload server on ${lan_ip}:${port} (payload identity in server log)"
dart run tool/vector_payload_server.dart --host 0.0.0.0 --port "$port" \
  --marker-log-dir "$out" \
  "${fixture_args[@]}" \
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
  # Clear synchronously before starting flutter in the background. Otherwise
  # the poll below can see a previous run's VM URL before the child opens
  # and truncates its redirected log.
  : > "$log"
  flutter run --profile --start-paused -d "$device" \
    -t lib/benchmark/map_vector_benchmark.dart \
    --dart-define=BENCHMARK_LABEL="$label" \
    --dart-define=BENCHMARK_VECTOR_BASE="$base" \
    --dart-define=BENCHMARK_MARKER_URL="$base/log" "${dash_args[@]}" "$@" > "$log" 2>&1 &
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
  # The marker sink is the run's data safety net: when the wireless
  # console relay wedges mid-run (results frozen while the app kept
  # running), the app's direct POSTs still filled markers-$label.log.
  # Canonize it when it is more complete than the console copy.
  local markers="$out/markers-$label.log"
  if [[ -f "$markers" ]]; then
    local console_n marker_n
    console_n=$(grep -cF FOSM_BENCHMARK_RESULT "$out/$label.log" 2>/dev/null || echo 0)
    marker_n=$(grep -cF FOSM_BENCHMARK_RESULT "$markers" 2>/dev/null || echo 0)
    if (( marker_n > console_n )); then
      mv "$markers" "$out/$label.log"
      echo "   (marker sink was the more complete channel)"
    else
      rm -f "$markers"
    fi
  fi
  grep -cF FOSM_BENCHMARK_RESULT "$out/$label.log" | \
    xargs -I{} echo "   {} result lines"
  grep -c FOSM_BENCHMARK_VECTOR_STAGES "$out/$label.log" | \
    xargs -I{} echo "   {} stage lines" || true
}

rep=1
while [[ $rep -le $clean_reps ]]; do
  run_benchmark "vector-clean-r$rep"
  rep=$((rep + 1))
done
rep=1
while [[ $rep -le $span_reps ]]; do
  run_benchmark "vector-spans-r$rep" --dart-define=fosm.vectorSpans=true
  rep=$((rep + 1))
done
rep=1
while [[ $rep -le $trace_reps ]]; do
  run_benchmark "vector-trace-r$rep" \
    --dart-define=fosm.vectorSpans=true --dart-define=fosm.traceVector=true \
    --dart-define=fosm.vectorTraceChunks=false
  rep=$((rep + 1))
done

echo "done: $out (parse with parse_benchmark_log + extract_vector_stages)"
