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

# Build the two arms (the span arm needs the define at build time).
if [[ ! -d build/web-clean ]]; then
  echo "── building web-clean…"
  flutter build web --profile -t lib/benchmark/map_vector_benchmark.dart \
    -o build/web-clean > /tmp/fosm-bw-clean.log 2>&1
fi
if [[ ! -d build/web-spans ]]; then
  echo "── building web-spans…"
  flutter build web --profile -t lib/benchmark/map_vector_benchmark.dart \
    --dart-define=fosm.vectorSpans=true -o build/web-spans \
    > /tmp/fosm-bw-spans.log 2>&1
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
serve_static build/web-clean 6101
serve_static build/web-spans 6102

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
