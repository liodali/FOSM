#!/usr/bin/env python3
"""Summarize FOSM_BENCHMARK_DASH_DIAGNOSTICS payloads from capture logs.

Handles the chunk protocol emitted by lib/benchmark (payloads exceed the
device console's line limit and ride out as FOSM_BENCHMARK_CHUNK lines,
terminated by FOSM_BENCHMARK_CHUNK_END). Prints per-payload metadata (run
label and dashCull flag from the adjacent FOSM_BENCHMARK_META) and
per-layer counter sums, plus the derived share of extractions that were
skipped and how many of those skips failed the optional bounds proof.

Usage: python3 tool/parse_dash_diagnostics.py LOG [LOG ...]
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

META_LINE = re.compile(r'FOSM_BENCHMARK_META (\{.*\})$')
DASH_LINE = re.compile(r'FOSM_BENCHMARK_DASH_DIAGNOSTICS (.+)$')
CHUNK_LINE = re.compile(r'^FOSM_BENCHMARK_CHUNK (.+)$')
CHUNK_END = 'FOSM_BENCHMARK_CHUNK_END'

COUNTERS = [
    'contours', 'patternSteps', 'extractions', 'culledExtractions',
    'culledUnproven', 'offscreenExtractions', 'unknownBounds',
    'extractionUs', 'drawDispatchUs', 'solidFallbacks',
]


def parse(path: Path):
    """Return a list of (meta, payload) dash payloads from one log."""
    meta = None
    payloads = []
    assembling = False
    meta_assembling: list[str] | None = None
    chunks: list[str] = []
    for line in path.read_text(errors='replace').splitlines():
        if meta_assembling is not None:
            meta_assembling.append(line[len('FOSM_BENCHMARK_CHUNK '):]
                                   if line.startswith('FOSM_BENCHMARK_CHUNK ')
                                   else line)
            if line.strip() == CHUNK_END:
                assembled = ''.join(meta_assembling)
                try:
                    meta = json.loads(assembled[len('FOSM_BENCHMARK_META '):])
                except json.JSONDecodeError:
                    print(f'{path.name}: unusable meta payload',
                          file=sys.stderr)
                meta_assembling = None
            continue
        if assembling:
            if line.startswith('FOSM_BENCHMARK_CHUNK '):
                chunks.append(line[len('FOSM_BENCHMARK_CHUNK '):])
            elif line.strip() == CHUNK_END:
                assembled = ''.join(chunks)
                payload = _parse_payload(assembled, path.name)
                if payload is not None:
                    payloads.append((meta, payload))
                assembling = False
                chunks = []
            else:
                # A non-chunk line inside a chunk stream: keep it; some
                # relays interleave untagged lines between continuations.
                chunks.append(line)
            continue
        meta_match = META_LINE.search(line)
        if meta_match is None and 'FOSM_BENCHMARK_META ' in line:
            # Meta payloads are chunked when longer than the device line
            # limit; the head line then lacks the closing '}'.
            meta_assembling = [line[line.find('FOSM_BENCHMARK_META '):]]
            continue
        if meta_match is not None:
            try:
                meta = json.loads(meta_match.group(1))
            except json.JSONDecodeError:
                meta = None
            continue
        dash_match = DASH_LINE.search(line)
        if dash_match is not None:
            payload_text = dash_match.group(1)
            if payload_text.rstrip().endswith('}'):
                payload = _parse_payload(payload_text, path.name)
                if payload is not None:
                    payloads.append((meta, payload))
            else:
                assembling = True
                chunks = [payload_text]
            continue
    return payloads


def _parse_payload(text: str, name: str):
    try:
        return json.loads(text.rstrip())
    except json.JSONDecodeError:
        print(f'{name}: unusable dash payload (truncated?)', file=sys.stderr)
        return None


def summarize(meta, payload):
    rows = payload.get('rows', [])
    by_layer: dict[str, dict] = {}
    for row in rows:
        bucket = by_layer.setdefault(row['layer'], dict.fromkeys(COUNTERS, 0))
        for key in COUNTERS:
            bucket[key] += row.get(key) or 0
    total = dict.fromkeys(COUNTERS, 0)
    for bucket in by_layer.values():
        for key in COUNTERS:
            total[key] += bucket[key]
    extracted = total['extractions']
    culled = total['culledExtractions']
    return {
        'label': (meta or {}).get('label'),
        'dashCull': (meta or {}).get('dashCull'),
        'scenario': payload.get('scenario'),
        'droppedUpdates': payload.get('droppedUpdates'),
        'rows': len(rows),
        'byLayer': by_layer,
        'total': total,
        'culledShare': round(culled / (extracted + culled), 4)
        if (extracted + culled) else None,
        'unprovenShare': round(total['culledUnproven'] / max(culled, 1), 6)
        if culled else 0,
    }


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    for name in argv[1:]:
        payloads = parse(Path(name))
        if not payloads:
            print(f'{Path(name).name}: no dash diagnostics payloads')
            continue
        for meta, payload in payloads:
            print(json.dumps({'log': Path(name).name,
                              **summarize(meta, payload)}, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
