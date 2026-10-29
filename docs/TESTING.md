# Verification

Run the checks on an Apple Silicon Mac after building the app:

```sh
make build
make test
```

## Settings

`native/Tests/check-settings-resolver.py` compares Swift evaluation with the source Cura expressions. The cases cover unchanged snapshots, layer-height dependencies, infill spacing/pattern, related speeds, material-temperature edits, ABS settings and support-related changes. The current fixture set contains 14 cases and 10,318 setting comparisons.

## Native packaging and import

`native/scripts/verify-native.py --app "build/Cubicon Native.app"` verifies the app signature, inspects Mach-O architectures, rejects Windows/compatibility-runtime files, imports the same 20 mm cube as ASCII STL, binary STL and OBJ, and checks rejection of a truncated STL.

## Import → slice → export

`native/scripts/verify-workflow.py --app "build/Cubicon Native.app"` runs the application's native CLI through four real slicing cases:

| Printer | Material | Input | Layer height |
| --- | --- | --- | --- |
| Single Plus | PLA | ASCII STL | 0.2 mm |
| Style Plus A15 | PLA | Binary STL | 0.2 mm |
| Single Plus | ABS | OBJ | 0.15 mm |
| Style Plus A15 | PETG | OBJ | 0.2 mm |

Checks include generated model layers, extrusion bounds, `M911`/`M904` commands, heater shutdown, normalized header bounds/time, and rejection of a 400 mm model. Generated logs and reports are written to the ignored `reports/` directory.

These checks validate application behavior and generated files. They do not establish physical print quality or device connectivity. The interface has been manually opened; automated GUI interaction is not part of this suite.
