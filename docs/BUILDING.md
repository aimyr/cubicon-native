# Building

Use an Apple Silicon Mac with macOS 14.6+, Xcode Command Line Tools and Python 3.11 or later.

```sh
make build
make test
make open
```

The build pins the upstream installer URL and SHA-256, expands it without installing Cura, regenerates settings from checked-in source definitions, and compiles the Swift frontend. A new bundle is verified before replacing an existing output.

## Custom output

```sh
python3 scripts/build-native.py --output "$HOME/Applications/Cubicon Native.app"
python3 native/scripts/verify-native.py --app "$HOME/Applications/Cubicon Native.app"
python3 native/scripts/verify-workflow.py --app "$HOME/Applications/Cubicon Native.app"
```

## Synced folders

iCloud/FileProvider may recreate Finder metadata inside generated app bundles while they are being signed. If `codesign` reports “resource fork, Finder information, or similar detritus not allowed,” build into a local cache directory outside the synced folder:

```sh
make APP="$HOME/Library/Caches/CubiconNative/Cubicon Native.app" build test
open "$HOME/Library/Caches/CubiconNative/Cubicon Native.app"
```

This changes the generated output location; no macOS security setting needs to be disabled.
