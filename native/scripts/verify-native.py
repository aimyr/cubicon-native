#!/usr/bin/env python3
"""Verify the distributed native binaries and real STL/OBJ import paths."""
from pathlib import Path
import argparse
import json
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_APP = ROOT / "build/Cubicon Native.app"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP, help="App bundle to verify (default: build/Cubicon Native.app)")
    args = parser.parse_args()
    app = args.app.expanduser().resolve()
    executable = app / "Contents/MacOS/CubiconNative"
    if not executable.is_file():
        raise SystemExit(f"Build the native app first; executable missing: {executable}")
    (ROOT / "reports").mkdir(parents=True, exist_ok=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    mach = []
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            magic = stream.read(8)
        if magic[:2] == b"MZ":
            raise SystemExit(f"Windows PE file found in native bundle: {path}")
        if path.name.lower() in {"wine", "wine64", "wineserver", "wine-preloader"}:
            raise SystemExit(f"Compatibility runtime found in native bundle: {path}")
        if magic[:4] == bytes.fromhex("cffaedfe"):
            cpu = struct.unpack_from("<I", magic, 4)[0]
            if cpu != 0x100000C:
                raise SystemExit(f"A bundled Mach-O binary is not ARM64: {path}")
            mach.append(str(path.relative_to(app)))
    results = []
    for filename in ("test-cube-20mm.stl", "test-cube-20mm-binary.stl", "test-cube-20mm.obj"):
        result = subprocess.run([str(executable), "--inspect-mesh", str(ROOT / "samples" / filename)], check=True, capture_output=True, text=True)
        geometry = json.loads(result.stdout)
        if geometry["triangle_count"] != 12 or geometry["dimensions_mm"] != [20, 20, 20]:
            raise SystemExit(f"Unexpected cube geometry: {geometry}")
        results.append(geometry)
    with tempfile.TemporaryDirectory(prefix="cubicon-malformed-") as work:
        invalid = Path(work) / "truncated.stl"
        invalid.write_bytes(b"Invalid binary STL".ljust(80, b"\0") + struct.pack("<I", 1))
        failure = subprocess.run([str(executable), "--inspect-mesh", str(invalid)], capture_output=True, text=True)
        if failure.returncode == 0:
            raise SystemExit("A truncated STL was accepted by the native parser.")
    report = {
        "status": "passed",
        "nativeArchitecture": "arm64",
        "nativeBinaries": mach,
        "windowsFiles": 0,
        "wineRuntime": False,
        "signature": "codesign --verify --deep --strict passed",
        "meshImport": results,
        "truncatedSTLRejected": True,
        "engineHelpExitCode": subprocess.run([str(app / "Contents/Resources/Engine/CubiEngine"), "help"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode,
        "scope": "Native binary packaging and mesh parsing; physical printer testing is separate.",
    }
    if report["engineHelpExitCode"] != 0:
        raise SystemExit("Bundled native engine could not run.")
    (ROOT / "reports/native-verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
