#!/usr/bin/env python3
"""Stage CuraEngine's native ARM64 dependency closure from the pinned installer."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "native/vendor-engine/cura-pkg/UltiMaker-Cura-5.13.0-macos-ARM64-Component.pkg/Payload/UltiMaker Cura.app"
FRAMEWORKS = APP / "Contents/Frameworks"
ENGINE = FRAMEWORKS / "CuraEngine"
RUNTIME = ROOT / "native/vendor-engine/runtime"


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def inspect(path: Path) -> tuple[list[str], list[str]]:
    lines = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
    dependencies = [line.strip().split(" (", 1)[0] for line in lines]
    load_commands = subprocess.check_output(["otool", "-l", str(path)], text=True).splitlines()
    rpaths = []
    for index, line in enumerate(load_commands):
        if "cmd LC_RPATH" in line:
            rpaths.append(load_commands[index + 2].strip().split("path ", 1)[1].split(" (offset", 1)[0])
    return dependencies, rpaths


def dependency_path(dependency: str, parent: Path) -> Path:
    if dependency.startswith("@rpath/"):
        return FRAMEWORKS / dependency.removeprefix("@rpath/")
    if dependency.startswith("@loader_path/"):
        return parent / dependency.removeprefix("@loader_path/")
    if dependency.startswith("@executable_path/"):
        return FRAMEWORKS / dependency.removeprefix("@executable_path/")
    return Path(dependency)


def main():
    if sys.version_info < (3, 11):
        raise SystemExit("Engine extraction requires Python 3.11 or newer.")
    if not ENGINE.is_file():
        raise SystemExit("The pinned Cura package has not been expanded. Run python3 scripts/build-native.py first.")
    reports = ROOT / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    RUNTIME.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    # Build the complete closure in isolation; stale dylibs never enter a bundle.
    with tempfile.TemporaryDirectory(prefix="runtime-stage-", dir=RUNTIME.parent) as work:
        candidate = Path(work) / "runtime"
        candidate.mkdir()
        queue = [ENGINE]
        seen = {}
        while queue:
            path = queue.pop(0)
            if path.name in seen:
                if seen[path.name].resolve() != path.resolve():
                    raise SystemExit(f"Dependency basename collision: {path.name}")
                continue
            seen[path.name] = path
            dependencies, rpaths = inspect(path)
            for dependency in dependencies:
                if dependency.startswith(("/usr/lib/", "/System/Library/")):
                    continue
                resolved = dependency_path(dependency, path.parent)
                if not resolved.is_file():
                    raise SystemExit(f"Unresolved dependency {dependency} of {path.name}")
                queue.append(resolved)
            name = "CubiEngine" if path == ENGINE else path.name
            destination = candidate / name
            shutil.copy2(path, destination)
            architectures = subprocess.check_output(["lipo", "-archs", str(destination)], text=True).strip().split()
            if architectures != ["arm64"]:
                raise SystemExit(f"Expected an ARM64-only runtime, got {architectures}: {name}")
            with destination.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            rows.append({"path": relative(path), "bundleName": name, "stagedPath": relative(RUNTIME / name), "sha256": digest, "architectures": architectures, "dependencies": dependencies, "rpaths": rpaths})
        help_result = subprocess.run([str(candidate / "CubiEngine"), "help"], capture_output=True, text=True)
        (reports / "native-engine-help.log").write_text(help_result.stdout + help_result.stderr)
        if help_result.returncode != 0:
            raise SystemExit(f"Staged native engine help failed: {help_result.returncode}")
        # Source runtime is a generated cache, never the installed app runtime.
        if RUNTIME.exists():
            shutil.rmtree(RUNTIME)
        candidate.replace(RUNTIME)
    manifest = {
        "version": "5.13.0",
        "sourceType": "Official UltiMaker macOS ARM64 installer; extracted without installation",
        "pathConvention": "All local paths are relative to the repository root.",
        "packageUrl": "https://github.com/Ultimaker/Cura/releases/download/5.13.0/UltiMaker-Cura-5.13.0-macos-ARM64.pkg",
        "packagePath": "downloads/curanative/Cura-5.13.0-arm64.pkg",
        "packageSha256": "85fd200674c4d414091e26a008c5dd4760fc869fc54abb68726e47bca6193239",
        "extractedAppPath": relative(APP),
        "enginePath": relative(ENGINE),
        "stagedEnginePath": relative(RUNTIME / "CubiEngine"),
        "stagedRuntimePath": relative(RUNTIME),
        "resourcesPath": relative(APP / "Contents/Resources/share/cura/resources"),
        "libraryPaths": [row["path"] for row in rows if row["bundleName"] != "CubiEngine"],
        "binaries": rows,
        "noticePaths": [relative(path) for path in sorted((ROOT / "native/Notices").glob("*")) if path.is_file()],
        "nativeHelpExitCode": help_result.returncode,
        "packagingNote": "Keep CubiEngine and its native dylibs in the same directory. No Windows, Wine, Python or Rosetta runtime is required.",
        "curaSource": {"repository": "https://github.com/Ultimaker/Cura", "tag": "5.13.0", "commit": "1fb8a7610460e03ec62da950d1c173a249b23b59"},
        "engineSource": {"repository": "https://github.com/Ultimaker/CuraEngine", "tag": "5.13.0", "commit": "636f9608621fd1d6c1b75ad2a969de53beabfbc6", "license": "AGPL-3.0-or-later"},
        "scope": "Cubicon R&D Center Cura profiles use Repetier flavor. This engine is separate from Cubicreator's proprietary slicer.",
    }
    (ROOT / "native/EngineSource.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Native ARM64 runtime staged:", RUNTIME)
    print("Binaries:", ", ".join(row["bundleName"] for row in rows))
    print("Bytes:", sum((RUNTIME / row["bundleName"]).stat().st_size for row in rows))


if __name__ == "__main__":
    main()
