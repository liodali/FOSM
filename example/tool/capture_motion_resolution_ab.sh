#!/bin/zsh
# Plan-10/11 motion-resolution paired A/B captures on a profile device.
#
# Usage:
#   BENCHMARK_FIXTURE_DIR=... BENCHMARK_FIXTURE_ID=... \
#     zsh tool/capture_motion_resolution_ab.sh DEVICE_ID OUTPUT_DIR
#
# Runs two arms over the same frozen fixture and four benchmark scenarios:
#   control    — no fosm.vectorMotion128 (256×256 always)
#   motion128  — fosm.vectorMotion128=true (128 previews, idle upgrades)
#
# Scenario suffixes:
#   static  — cold initial arrivals and the idle refinement burst
#   fling   — continuous directional pan
#   return  — repeated return pan
#   pinch   — fractional pinch/zoom motion
#
# Each cell performs CLEAN_REPS clean runs and SPAN_REPS spans runs. The
# baseline capture script starts one payload server per cell, so runs stay
# isolated and use the same fixture-identity controls as earlier A/Bs.
# Parse results afterwards with parse_motion_resolution_ab.py.
set -euo pipefail

device="${1:?device id}"
out="${2:?output directory}"
fixture_dir="${BENCHMARK_FIXTURE_DIR:?set BENCHMARK_FIXTURE_DIR to the frozen fixture root}"
fixture_id="${BENCHMARK_FIXTURE_ID:?set BENCHMARK_FIXTURE_ID to the frozen fixture identity}"
lan_ip="${BENCHMARK_LAN_IP:-$(ipconfig getifaddr en0)}"
clean_reps="${CLEAN_REPS:-2}"
span_reps="${SPAN_REPS:-1}"
scenarios=(${SCENARIOS:-vector_cold_static vector_cold_fling vector_cold_return vector_cold_pinch})

if [[ -z "$lan_ip" ]]; then
  echo "no LAN IP found; pass BENCHMARK_LAN_IP" >&2
  exit 1
fi
if lsof -nP -iTCP:8787 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "payload port 8787 is already in use" >&2
  exit 1
fi

mkdir -p "$out"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cat > "$out/manifest.json" <<MANIFEST
{
  "capturedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "device": "$device",
  "lanIp": "$lan_ip",
  "fixtureDir": "$fixture_dir",
  "fixtureId": "$fixture_id",
  "cleanReps": $clean_reps,
  "spanReps": $span_reps,
  "scenarios": [$(printf '"%s",' "${scenarios[@]}" | sed 's/,$//')],
  "arms": {
    "control": {"fosm.vectorMotion128": false},
    "motion128": {"fosm.vectorMotion128": true}
  }
}
MANIFEST
flutter --version > "$out/flutter-version.txt" 2>/dev/null || true
git -C "$repo_root" rev-parse HEAD > "$out/git-head.txt"

here="$(cd "$(dirname "$0")" && pwd)"

for arm in control motion128; do
  if [[ "$arm" == motion128 ]]; then
    export BENCHMARK_MOTION_128=1
  else
    unset BENCHMARK_MOTION_128
  fi
  for scenario in "${scenarios[@]}"; do
    suffix="${scenario#vector_cold_}"
    cell="$out/$arm-$suffix"
    echo "── cell: $arm/$suffix"
    BENCHMARK_SCENARIO="$scenario" \
    BENCHMARK_FIXTURE_DIR="$fixture_dir" \
    BENCHMARK_FIXTURE_ID="$fixture_id" \
      zsh "$here/capture_vector_baseline.sh" \
      "$device" "$cell" "$lan_ip" "$clean_reps" "$span_reps" 0
  done
done

echo "done: $out"
