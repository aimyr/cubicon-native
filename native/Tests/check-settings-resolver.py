#!/usr/bin/env python3
"""Compare the native evaluator to the source Cura expressions after UI edits."""
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("native_profile_export", ROOT / "scripts/export-native-profiles.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)
catalog = json.loads((ROOT / "native/Resources/Profiles.json").read_text())
materials = {material["id"]: material for material in catalog["materials"]}
definitions = exporter.Definitions(ROOT / "native/ProfileSources")
fixtures = []
for profile in catalog["profiles"]:
    settings, metadata, _ = definitions.load(profile["id"])
    extruder, _, _ = definitions.load(metadata["machine_extruder_trains"]["0"])
    for key, declaration in extruder.items():
        settings.setdefault(key, {}).update(declaration)
    edits = [
        ("unchanged", "pla", {}),
        ("fine-layers", "pla", {"layer_height": "0.15"}),
        ("density-and-pattern", "pla", {"infill_sparse_density": "30"}),
        ("speed", "pla", {"speed_print": "80"}),
        ("temperature", "pla", {"material_print_temperature": "215", "default_material_print_temperature": "215"}),
        ("abs-combined", "abs", {"layer_height": "0.1", "speed_print": "90", "infill_sparse_density": "50", "support_enable": "true"}),
    ]
    for name, material_id, overrides in edits:
        material = materials[material_id]
        snapshot = profile["materialSettings"][material_id]
        explicit = {"machine_extruder_count": 1, "extruders_enabled_count": 1, "extruder_nr": 0}
        for source in (material["settings"], overrides):
            for key, value in source.items():
                try: explicit[key] = json.loads(value)
                except json.JSONDecodeError: explicit[key] = value
        expected = exporter.Evaluator(settings, explicit).settings()
        fixtures.append({"name": profile["id"] + "/" + name, "snapshot": snapshot, "expressions": profile["expressions"], "literalKeys": list(material["settings"]), "overrides": overrides, "expected": expected})
    # A wide dependency closure exercises rarely exposed support/prime tower
    # branches as well as the few settings editable in the interface.
    material = materials["pla"]
    snapshot = profile["materialSettings"]["pla"]
    overrides = {key: value for key, value in snapshot.items() if key not in profile["expressions"]}
    overrides.update(material["settings"])
    explicit = {}
    for key, value in overrides.items():
        try: explicit[key] = json.loads(value)
        except json.JSONDecodeError: explicit[key] = value
    expected = exporter.Evaluator(settings, explicit).settings()
    fixtures.append({"name": profile["id"] + "/all-expression-dependencies", "snapshot": snapshot, "expressions": profile["expressions"], "literalKeys": list(material["settings"]), "overrides": overrides, "expected": expected})

work = ROOT / "native/build/settings-check"
work.mkdir(parents=True, exist_ok=True)
fixture_path = work / "fixtures.json"
fixture_path.write_text(json.dumps(fixtures))
executable = work / "SettingsResolverCheck"
subprocess.run(["swiftc", "-parse-as-library", "-O", str(ROOT / "native/Sources/SettingsResolver.swift"), str(ROOT / "native/Tests/SettingsResolverCheck.swift"), "-o", str(executable)], check=True)
subprocess.run([str(executable), str(ROOT / "native/Resources/Expressions.json"), str(fixture_path)], check=True)
