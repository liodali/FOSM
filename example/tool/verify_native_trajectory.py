#!/usr/bin/env python3
"""Compile the actual Swift model and compare its poses with the Dart model."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def verify(dart):
    example = Path(__file__).resolve().parents[1]
    contract = example / "benchmark/native_comparison.json"
    times = [0, 0.5, 1, 1.999, 2, 4, 6, 7.999, 8, 8.5, 12]
    with tempfile.TemporaryDirectory(prefix="fosm-trajectory-") as directory:
        root = Path(directory)
        swift = root / "main.swift"
        swift.write_text('''import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let workload = try ComparisonWorkload.load(data)
let times: [Double] = ''' + json.dumps(times) + '''
let poses = workload.scenarios.map { scenario in times.map { scenario.pose($0) } }
let output = try JSONSerialization.data(withJSONObject: poses)
print(String(data: output, encoding: .utf8)!)
''')
        binary = root / "trajectory"
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(root / "modules"),
                        str(example / "native_mapcore/ComparisonWorkload.swift"),
                        str(swift), "-o", str(binary)], check=True)
        native = json.loads(subprocess.check_output([str(binary), str(contract)], text=True))
        script = root / "trajectory.dart"
        script.write_text("import 'dart:convert';\nimport 'dart:io';\nimport " +
                          json.dumps((example / "lib/benchmark/native_comparison_workload.dart").as_uri()) + ";\n" +
                          "void main(List<String> args) {\n" +
                          "final w = NativeComparisonWorkload.fromJson(File(args[0]).readAsStringSync());\n" +
                          "final times = <double>" + json.dumps(times) + ";\n" +
                          "print(jsonEncode([for(final s in w.scenarios) [for(final t in times) s.pose(t)]]));\n}\n")
        flutter = json.loads(subprocess.check_output([dart, str(script), str(contract)], text=True))
        assert len(native) == len(flutter)
        for native_scenario, flutter_scenario in zip(native, flutter):
            for native_pose, flutter_pose in zip(native_scenario, flutter_scenario):
                assert all(abs(a - b) < 1e-9 for a, b in zip(native_pose, flutter_pose)), (native_pose, flutter_pose)
        print(f"Matched {len(native) * len(times)} Swift/Dart camera poses")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", default="dart")
    verify(parser.parse_args().dart)
