#!/usr/bin/env python3
"""Aggregate motion-resolution A/B capture logs.

Usage:
  python3 tool/parse_motion_resolution_ab.py OUTPUT_DIR [--json OUT.json]

Reads the manifest written by capture_motion_resolution_ab.sh, reassembles
chunked FOSM_BENCHMARK_RESULT payloads from every clean run, and prints
per-run plus arm/scenario means for the acceptance metrics. Stage reports
remain available through:

  dart run tool/extract_vector_stages.dart CELL stages
"""
from __future__ import annotations

import argparse
import json
import pathlib
import statistics
from typing import Any

RESULT = "FOSM_BENCHMARK_RESULT "
CHUNK = "FOSM_BENCHMARK_CHUNK "
CHUNK_END = "FOSM_BENCHMARK_CHUNK_END"


def payload_lines(text: str, marker: str) -> list[dict[str, Any]]:
    """Reassemble chunked FOSM benchmark payloads."""
    out: list[dict[str, Any]] = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        at = lines[i].find(marker)
        if at < 0:
            i += 1
            continue
        buf = lines[i][at + len(marker):]
        i += 1
        while i < len(lines):
            if lines[i].startswith(CHUNK):
                buf += lines[i][len(CHUNK):]
                i += 1
                continue
            if lines[i].strip() == CHUNK_END:
                i += 1
            break
        try:
            value = json.loads(buf)
            if isinstance(value, dict):
                out.append(value)
        except json.JSONDecodeError:
            pass
    return out


def load_cell(cell: pathlib.Path) -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    for path in sorted(cell.glob("vector-clean-r*.log")):
        for payload in payload_lines(path.read_text(errors="replace"), RESULT):
            payload["_log"] = path.name
            runs.append(payload)
    return runs


def number(value: Any) -> float | None:
    return float(value) if isinstance(value, (int, float)) else None


def mean(values: list[float]) -> float | None:
    return round(statistics.mean(values), 2) if values else None


def maximum(values: list[float]) -> float | None:
    return round(max(values), 2) if values else None


def summarize(runs: list[dict[str, Any]]) -> dict[str, Any]:
    cov = [(r.get("coverage") or {}) for r in runs]
    fields = [
        "allCoveredMs",
        "covered95Ms",
        "firstSharpMs",
        "sharp95Ms",
        "allSharpMs",
        "labelsViewportReadyMs",
        "meanNewToSharpMs",
    ]
    summary: dict[str, Any] = {
        "runs": len(runs),
        "frames": [r.get("frames") for r in runs],
    }
    for field in fields:
        values = [v for row in cov if (v := number(row.get(field))) is not None]
        summary[field] = {"mean": mean(values), "values": values}
    for field in ["uiP50Ms", "uiP95Ms", "uiP99Ms", "uiMaxMs",
                  "rasterP50Ms", "rasterP95Ms", "rasterP99Ms", "rasterMaxMs"]:
        values = [v for r in runs if (v := number(r.get(field))) is not None]
        summary[field] = {"mean": mean(values), "max": maximum(values)}
    summary["framesOverDisplayBudget"] = [
        r.get("framesOverDisplayBudget") for r in runs
    ]
    summary["peakRenderedBytes"] = [
        r.get("peakRenderedBytes") for r in runs
    ]
    summary["peakEstimatedTotalBytes"] = [
        r.get("peakEstimatedTotalBytes") for r in runs
    ]
    summary["peakParsedTiles"] = [r.get("peakParsedTiles") for r in runs]
    summary["peakPreparedLabels"] = [
        r.get("peakPreparedLabels") for r in runs
    ]
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("--json", type=pathlib.Path)
    args = parser.parse_args()

    manifest_path = args.root / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit(f"missing {manifest_path}")
    manifest = json.loads(manifest_path.read_text())
    report: dict[str, Any] = {"manifest": manifest, "cells": {}}

    for arm in ["control", "motion128"]:
        for scenario in manifest["scenarios"]:
            suffix = scenario.removeprefix("vector_cold_")
            cell = args.root / f"{arm}-{suffix}"
            runs = load_cell(cell) if cell.exists() else []
            key = f"{arm}/{suffix}"
            report["cells"][key] = summarize(runs)
            if not runs:
                print(f"{key:26} MISSING RUNS")
                continue
            def cov(field: str) -> str:
                values = report["cells"][key][field]
                return f"{values['mean'] if values['mean'] is not None else '-':>8}"
            print(
                f"{key:26} n={len(runs)} frames={report['cells'][key]['frames']} "
                f"allCov={cov('allCoveredMs')} cov95={cov('covered95Ms')} "
                f"firstSharp={cov('firstSharpMs')} sharp95={cov('sharp95Ms')} "
                f"allSharp={cov('allSharpMs')} labelReady={cov('labelsViewportReadyMs')} "
                f"uiP95={report['cells'][key]['uiP95Ms']['max'] or '-'} "
                f"rasterP95={report['cells'][key]['rasterP95Ms']['max'] or '-'} "
                f"overB={report['cells'][key]['framesOverDisplayBudget']}"
            )

    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
