#!/usr/bin/env python3
"""Exercise the actual native app's import, placement, settings, slice and export."""
from pathlib import Path
import argparse
import json
import math
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_APP = ROOT / "build/Cubicon Native.app"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP, help="App bundle to verify (default: build/Cubicon Native.app)")
    args = parser.parse_args()
    executable = args.app.expanduser().resolve() / "Contents/MacOS/CubiconNative"
    if not executable.is_file():
        raise SystemExit(f"Build the native app first; executable missing: {executable}")
    (ROOT / "reports").mkdir(parents=True, exist_ok=True)
    cases = [
        ("cubicon_3dp_310f", "pla", "test-cube-20mm.stl", {}, [240, 190, 200]),
        ("cubicon_style_plus_a15", "pla", "test-cube-20mm-binary.stl", {}, [150, 150, 150]),
        ("cubicon_3dp_310f", "abs", "test-cube-20mm.obj", {"layer_height": "0.15", "infill_sparse_density": "30", "material_print_temperature": "215", "speed_print": "80"}, [240, 190, 200]),
        ("cubicon_style_plus_a15", "petg", "test-cube-20mm.obj", {}, [150, 150, 150]),
    ]
    results = []
    for profile, material, model, overrides, size in cases:
        label = f"{profile}-{material}"
        output = ROOT / f"reports/native-workflow-{label}.gcode"
        command = [str(executable), "--slice-model", profile, material, str(ROOT / "samples" / model), str(output), json.dumps(overrides)]
        run = subprocess.run(command, capture_output=True, text=True, timeout=190)
        (ROOT / f"reports/native-workflow-{label}.log").write_text(run.stderr)
        if run.returncode != 0:
            raise SystemExit(f"Native workflow failed for {label}: {run.stderr[-1500:]}")
        report = json.loads(run.stdout)
        code = output.read_text()
        if report["status"] != "passed" or report["layer_count"] < 100:
            raise SystemExit(f"Incomplete geometry: {report}")
        for group in ("commanded_extrusion_bounds_mm", "logical_extrusion_bounds_mm"):
            bounds = report[group]
            for axis, limit in zip(("x", "y", "z"), size):
                index = ("x", "y", "z").index(axis)
                # The app reports min/max XYZ arrays. Keep this check independent
                # of generated MIN/MAX comments, which upstream CLI leaves unset.
                low, high = bounds["min"][index], bounds["max"][index]
                if low < -0.06 or high > limit + 0.06:
                    raise SystemExit(f"Out-of-volume native output: {label} {group} {axis} {low}..{high}")
        expected = "M911 3DP-310F" if profile == "cubicon_3dp_310f" else "M911 Style Plus-A15"
        if expected not in code or not all(line in code.splitlines() for line in ("M904", "M104 S0", "M140 S0")):
            raise SystemExit(f"Missing Cubicon start/end commands: {label}")
        for name in ("MINX", "MINY", "MINZ", "MAXX", "MAXY", "MAXZ"):
            match = re.search(rf"(?m)^;{name}:([-+0-9.eE]+)", code)
            if not match or abs(float(match.group(1))) > 1000:
                raise SystemExit(f"Invalid exported bounds header: {label} {name}")
        times = re.findall(r"(?m)^;TIME_ELAPSED:([0-9.]+)", code)
        estimate = re.search(r"(?m)^;TIME:([0-9]+)", code)
        if not times or not estimate or int(estimate.group(1)) != math.ceil(float(times[-1])):
            raise SystemExit(f"The exported time estimate is still a placeholder: {label}")
        if overrides and not (130 <= report["layer_count"] <= 135):
            raise SystemExit("Changing layer height did not change the actual slice.")
        report["input_format"] = Path(model).suffix
        results.append(report)
        print(label, "PASS", report["layer_count"], "layers", flush=True)
    with tempfile.TemporaryDirectory(prefix="cubicon-large-model-") as work:
        oversized = Path(work) / "oversized.stl"
        data = bytearray((ROOT / "samples/test-cube-20mm-binary.stl").read_bytes())
        for face in range(12):
            for vertex in range(3):
                offset = 84 + face * 50 + 12 + vertex * 12
                for coordinate in range(3):
                    value = struct.unpack_from("<f", data, offset + coordinate * 4)[0]
                    struct.pack_into("<f", data, offset + coordinate * 4, value * 20)
        oversized.write_bytes(data)
        destination = Path(work) / "must-not-exist.gcode"
        rejected = subprocess.run([str(executable), "--slice-model", "cubicon_3dp_310f", "pla", str(oversized), str(destination)], capture_output=True, text=True, timeout=30)
        if rejected.returncode == 0 or destination.exists():
            raise SystemExit("An oversized model was exported instead of being rejected.")
    report = {"status": "passed", "runtime": "native ARM64 app and engine", "cases": results, "oversized_model_rejected": True, "scope": "File generation and geometry only; no device connection or physical print."}
    (ROOT / "reports/native-workflow-verification.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
