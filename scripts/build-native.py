#!/usr/bin/env python3
"""Build the independent Apple Silicon macOS app from a clean checkout."""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT / "build/Cubicon Native.app"
PACKAGE = ROOT / "downloads/curanative/Cura-5.13.0-arm64.pkg"
PACKAGE_URL = "https://github.com/Ultimaker/Cura/releases/download/5.13.0/UltiMaker-Cura-5.13.0-macos-ARM64.pkg"
PACKAGE_SHA = "85fd200674c4d414091e26a008c5dd4760fc869fc54abb68726e47bca6193239"
EXPANDED = ROOT / "native/vendor-engine/cura-pkg"
ENGINE_IN_PACKAGE = Path("UltiMaker-Cura-5.13.0-macos-ARM64-Component.pkg/Payload/UltiMaker Cura.app/Contents/Frameworks/CuraEngine")
RESOURCE_FILES = ("Profiles.json", "Expressions.json", "Base.def.json")


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare_package():
    PACKAGE.parent.mkdir(parents=True, exist_ok=True)
    if PACKAGE.exists():
        if sha256(PACKAGE) != PACKAGE_SHA:
            raise SystemExit(f"Cached Cura package has an unexpected SHA256. Remove {PACKAGE} and retry.")
    else:
        partial = PACKAGE.with_suffix(".pkg.part")
        try:
            run("curl", "-fL", "--retry", "2", "-o", partial, PACKAGE_URL)
            if sha256(partial) != PACKAGE_SHA:
                raise SystemExit("The downloaded official Cura package SHA256 does not match.")
            partial.replace(PACKAGE)
        finally:
            partial.unlink(missing_ok=True)
    # Only an expansion with its completion marker and engine can be reused.
    marker = EXPANDED / ".cubicon-package-sha256"
    if (EXPANDED / ENGINE_IN_PACKAGE).is_file() and marker.is_file() and marker.read_text().strip() == PACKAGE_SHA:
        return
    EXPANDED.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cura-expand-", dir=EXPANDED.parent) as work:
        candidate = Path(work) / "cura-pkg"
        run("pkgutil", "--expand-full", PACKAGE, candidate)
        if not (candidate / ENGINE_IN_PACKAGE).is_file():
            raise SystemExit("The official Cura package did not contain the expected ARM64 engine.")
        (candidate / marker.name).write_text(PACKAGE_SHA + "\n")
        if EXPANDED.exists():
            shutil.rmtree(EXPANDED)
        candidate.replace(EXPANDED)


def replace_app(candidate: Path, destination: Path):
    """Keep an existing app recoverable until the verified replacement is ready."""
    previous = candidate.parent / "previous.app"
    if destination.exists() or destination.is_symlink():
        destination.rename(previous)
    try:
        candidate.rename(destination)
    except BaseException:
        if previous.exists() or previous.is_symlink():
            previous.rename(destination)
        raise
    if previous.is_symlink():
        previous.unlink()
    elif previous.exists():
        shutil.rmtree(previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_APP, help="Destination .app bundle (default: build/Cubicon Native.app)")
    args = parser.parse_args()
    if sys.version_info < (3, 11):
        raise SystemExit("Building requires Python 3.11 or newer.")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac running macOS 14.6 or newer.")
    app = args.output.expanduser().absolute()
    if app.suffix != ".app" or (app.exists() and not app.is_dir() and not app.is_symlink()):
        raise SystemExit("--output must name a .app bundle directory.")
    for command in ("curl", "pkgutil", "swiftc", "otool", "lipo", "plutil", "xattr", "codesign"):
        if shutil.which(command) is None:
            raise SystemExit(f"Missing required build tool: {command}. Install Xcode Command Line Tools.")
    (ROOT / "reports").mkdir(parents=True, exist_ok=True)
    prepare_package()
    run(sys.executable, ROOT / "native/scripts/extract-engine.py")
    run(sys.executable, ROOT / "scripts/export-native-profiles.py")
    app.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".cubicon-build-", dir=app.parent) as work:
        candidate = Path(work) / "Cubicon Native.app"
        resources = candidate / "Contents/Resources"
        macos = candidate / "Contents/MacOS"
        macos.mkdir(parents=True)
        resources.mkdir()
        for filename in RESOURCE_FILES:
            shutil.copy2(ROOT / "native/Resources" / filename, resources / filename)
        shutil.copytree(ROOT / "native/vendor-engine/runtime", resources / "Engine")
        shutil.copy2(ROOT / "native/Info.plist", candidate / "Contents/Info.plist")
        sources = sorted((ROOT / "native/Sources").glob("*.swift"))
        run("swiftc", "-parse-as-library", "-O", "-target", "arm64-apple-macos14.6", "-framework", "AppKit", "-framework", "SceneKit", *sources, "-o", macos / "CubiconNative")
        icon = ROOT / "native/Assets/AppIcon.icns"
        if icon.is_file():
            shutil.copy2(icon, resources / "AppIcon.icns")
        notices = resources / "Notices"
        shutil.copytree(ROOT / "native/Notices", notices)
        manifest = json.loads((ROOT / "native/EngineSource.json").read_text())
        (notices / "EngineSource.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (notices / "About.txt").write_text(
            "Cubicon Native — independent native macOS frontend.\n"
            "Frontend source: https://github.com/aimyr/cubicon-native\n"
            "CuraEngine 5.13.0: https://github.com/Ultimaker/CuraEngine/tree/636f9608621fd1d6c1b75ad2a969de53beabfbc6\n"
            "Printer profiles: Cubicon R&D Center contributions to UltiMaker Cura.\n"
            "See the accompanying licenses and SOURCES.txt for third-party components.\n"
        )
        run("plutil", "-lint", candidate / "Contents/Info.plist")
        run("xattr", "-dr", "com.apple.FinderInfo", candidate)
        run("xattr", "-dr", "com.apple.ResourceFork", candidate)
        run("codesign", "--force", "--sign", "-", candidate)
        run("codesign", "--verify", "--deep", "--strict", candidate)
        replace_app(candidate, app)
    print(f"Built native app: {app}")


if __name__ == "__main__":
    main()
