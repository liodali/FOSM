#!/bin/zsh
# Plan-01 vector-render BASELINE browser captures (separate addendum:
# native worker-isolate parsing conclusions do not transfer to web).
# Usage: zsh tool/capture_vector_baseline_web.sh OUTPUT_DIR \
#          [LAN_OR_HOST_BASE] [CLEAN_REPS] [SPAN_REPS] [PORT]
#
# flutter_tools' `flutter run -d chrome` cannot host a debug connection
# (it launches Chrome with --disable-extensions), so this script bypasses
# it entirely: build the profile web app once per arm, serve it as static
# files, drive Chrome directly, and let the app POST its payload lines to
# the payload server's /log marker sink (one file per label under the
# output dir, parsed like any native run log).
#
#   dart run tool/vector_payload_server.dart --host 0.0.0.0 --port 8787 \
#     --marker-log-dir OUT/browser
#   flutter build web --profile -t lib/benchmark/map_vector_benchmark.dart \
#     --dart-define=fosm.vectorSpans=true -o build/web-spans
#   python3 -m http.server 6101 --directory build/web-clean …
#
# The label passes per rep through `?label=web-clean-r1`; the marker sink
# its server route passes through `?sink=`. Metadata identity of the
# web build lands in the parsed report like any other run.
#
# The same env vars as tool/capture_vector_baseline.sh steer the build:
#   BENCHMARK_DASH_CULL=1      add fosm.vectorDashCull to both arms
#   BENCHMARK_SCENARIO=name    scenario filter define
#   BENCHMARK_FIXTURE_DIR/ID   fixture payload defines (the *server* must
#                              still be started with --fixture-dir itself)
#   BENCHMARK_LATITUDE/LONGITUDE  benchmark center define
#   BENCHMARK_SAMPLE_SECONDS   override the sampling window length
# Arms that differ by defines get distinct build directories so baseline
# and candidate builds can coexist.
set -euo pipefail

out="${1:?output dir}"
base="${2:-http://$(ipconfig getifaddr en0):8787}"
clean_reps="${3:-2}"
span_reps="${4:-2}"
port="${5:-8787}"

chrome_app="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$chrome_app" ]] || chrome_app="$(which google-chrome || which chrome)"
[[ -n "${chrome_app:-}" ]] || { echo "no chrome found"; exit 1; }
lan_ip="${base#http://}"
lan_ip="${lan_ip%%:*}"

mkdir -p "$out"
cd "$(dirname "$0")/.."

# Record tool versions next to the captures so results stay interpretable
# after the fact (Chrome patch versions change between sessions).
"$chrome_app" --version > "$out/browser-version.txt" 2>/dev/null || true
flutter --version > "$out/flutter-version.txt" 2>/dev/null || true

# Build define list + a deterministic build-dir suffix from the env.
target='lib/benchmark/map_vector_benchmark.dart'
build_defines=()
suffix_parts=()
if [[ "${BENCHMARK_DASH_CULL:-0}" == 1 ]]; then
  build_defines+=(--dart-define=fosm.vectorDashCull=true)
  suffix_parts+=('cull')
fi
if [[ -n "${BENCHMARK_SCENARIO:-}" ]]; then
  build_defines+=(--dart-define=BENCHMARK_SCENARIO="$BENCHMARK_SCENARIO")
  suffix_parts+=("$BENCHMARK_SCENARIO")
fi
if [[ -n "${BENCHMARK_FIXTURE_DIR:-}" ]]; then
  : "${BENCHMARK_FIXTURE_ID:?fixture runs require BENCHMARK_FIXTURE_ID}"
  build_defines+=(--dart-define=BENCHMARK_PAYLOAD_IDENTITY="$BENCHMARK_FIXTURE_ID"
    --dart-define=BENCHMARK_VECTOR_PROFILE=fixture)
  suffix_parts+=("$BENCHMARK_FIXTURE_ID")
fi
if [[ -n "${BENCHMARK_LATITUDE:-}" && -n "${BENCHMARK_LONGITUDE:-}" ]]; then
  build_defines+=(--dart-define=BENCHMARK_LATITUDE="$BENCHMARK_LATITUDE"
    --dart-define=BENCHMARK_LONGITUDE="$BENCHMARK_LONGITUDE")
elif [[ -n "${BENCHMARK_LATITUDE:-}" || -n "${BENCHMARK_LONGITUDE:-}" ]]; then
  echo "BENCHMARK_LATITUDE and BENCHMARK_LONGITUDE must both be set" >&2
  exit 2
fi
if [[ -n "${BENCHMARK_SAMPLE_SECONDS:-}" ]]; then
  build_defines+=(--dart-define=BENCHMARK_SAMPLE_SECONDS="$BENCHMARK_SAMPLE_SECONDS")
  suffix_parts+=("t${BENCHMARK_SAMPLE_SECONDS}s")
fi
suffix="${suffix_parts[*]:-default}"
suffix="${suffix// /_}"

# Build the two arms (the span arm needs the define at build time).
arm_dir() {
  printf 'build/web-%s-%s' "$1" "$suffix"
}
if [[ ! -d "$(arm_dir clean)" ]]; then
  echo "── building web-clean ($suffix)…"
  flutter build web --profile -t "$target" -o "$(arm_dir clean)" \
    "${build_defines[@]}" > /tmp/fosm-bw-clean.log 2>&1
fi
if [[ ! -d "$(arm_dir spans)" ]]; then
  echo "── building web-spans ($suffix)…"
  flutter build web --profile -t "$target" \
    --dart-define=fosm.vectorSpans=true -o "$(arm_dir spans)" \
    "${build_defines[@]}" > /tmp/fosm-bw-spans.log 2>&1
fi

pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  pgrep -f "web-baseline-chrome" 2>/dev/null | xargs kill 2>/dev/null || true
}
trap cleanup EXIT

curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 || {
  echo "payload server not reachable on $port — start it first ([--marker-log-dir path])"
  exit 1
}

serve_static() {
  local dir="$1" port="$2"
  python3 -m http.server "$port" --directory "$dir" --bind 127.0.0.1 \
    > "/tmp/fosm-web-static-$port.log" 2>&1 &
  pids+=($!)
  for i in {1..20}; do
    curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "static server on :$port failed to start"; exit 1
}
serve_static "$(arm_dir clean)" 6101
serve_static "$(arm_dir spans)" 6102

run_rep() {
  local dir_port="$1" label="$2"; shift 2
  local markers="$out/markers-$label.log"
  local profile_dir
  profile_dir=$(/usr/bin/mktemp -d /tmp/web-baseline-chrome.XXXXXX)
  rm -f "$markers"
  echo "── run: $label (static build :$dir_port)"
  "$chrome_app" \
    --user-data-dir="$profile_dir" \
    --no-first-run --no-default-browser-check \
    --remote-debugging-port=0 \
    --disable-background-timer-throttling \
    --disable-backgrounding-occluded-windows \
    --disable-renderer-backgrounding \
    --disable-features=CalculateNativeWinOcclusion \
    "http://localhost:$dir_port/?label=$label&sink=http://$lan_ip:$port/log" \
    > /dev/null 2>&1 &
  local chrome_pid=$!
  # The CDP debug port lands in the DevToolsActivePort file inside the
  # profile dir once the browser is up.
  local cdp_port=""
  local tries=0
  while [[ -z "$cdp_port" && $tries -lt 60 ]]; do
    if [[ -f "$profile_dir/DevToolsActivePort" ]]; then
      cdp_port=$(head -1 "$profile_dir/DevToolsActivePort")
    fi
    [[ -z "$cdp_port" ]] && { sleep 1; tries=$((tries + 1)); }
  done
  if [[ -z "$cdp_port" ]]; then
    echo "chrome devtools port not found for $label"; exit 1
  fi
  # Capture rides the /log marker sink (the write path the app itself
  # drives); the console bridge is a best-effort transcript only.
  dart run tool/capture_web_console.dart "$cdp_port" \
    "$out/$label.console.log" 2> "$out/$label.bridge.log" &
  local bridge_pid=$!
  local waited=0
  while ! grep -q 'FOSM_BENCHMARK_DONE' "$markers" 2>/dev/null; do
    if ! kill -0 $chrome_pid 2>/dev/null; then
      echo "chrome exited early for $label"; exit 1
    fi
    if [[ $waited -gt 540 ]]; then
      echo "marker sink waited too long for $label"; exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  kill $chrome_pid 2>/dev/null || true
  kill $bridge_pid 2>/dev/null || true
  wait $chrome_pid 2>/dev/null || true
  rm -rf "$profile_dir"
  mv "$markers" "$out/$label.log"
  echo "   $label: $(grep -c FOSM_BENCHMARK_RESULT "$out/$label.log" || true)"\
      "result lines"
}

for rep in $(seq 1 "$clean_reps"); do
  run_rep 6101 "vector-web-clean-r$rep"
done
for rep in $(seq 1 "$span_reps"); do
  run_rep 6102 "vector-web-spans-r$rep"
done

echo "done: $out/browser (parse with parse_benchmark_log + extract_vector_stages)"
