#!/usr/bin/env python3
"""Export the manufacturer-authored Cura profiles for native CuraEngine.

This does not translate Cubicreator's private CubiconDevice dialect to Repetier.
The native profiles come from UltiMaker Cura's Cubicon R&D Center definitions.
Expressions are evaluated locally for a single-extruder machine; source hashes,
definition inheritance, and every fallback are retained in the resulting JSON.
"""
from __future__ import annotations

import argparse
import ast
import copy
import hashlib
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
VERSION = "5.13.0"
MACHINES = ("cubicon_3dp_310f", "cubicon_style_plus_a15")
MATERIAL_MAP = {
    "print temperature": "material_print_temperature",
    "heated bed temperature": "material_bed_temperature",
    "standby temperature": "material_standby_temperature",
    "retraction amount": "retraction_amount",
    "retraction speed": "retraction_speed",
    "fan speed": "cool_fan_speed",
    "print cooling": "cool_fan_speed",
    "build volume temperature": "build_volume_temperature",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def flatten(tree):
    values = {}
    for key, spec in tree.items():
        if spec.get("type") != "category":
            values[key] = {k: copy.deepcopy(v) for k, v in spec.items() if k != "children"}
        values.update(flatten(spec.get("children", {})))
    return values


class Definitions:
    def __init__(self, resources):
        self.resources = resources
        self.paths = {}
        for folder in ("definitions", "extruders"):
            for path in (resources / folder).glob("*.def.json"):
                self.paths[path.name[:-9]] = path

    def load(self, name, stack=()):
        if name in stack:
            raise ValueError(f"Definition inheritance cycle: {stack + (name,)}")
        path = self.paths[name]
        document = json.loads(path.read_text(encoding="utf-8-sig"))
        parent = document.get("inherits") or document.get("base")
        if parent:
            specs, metadata, sources = self.load(parent, stack + (name,))
        else:
            specs, metadata, sources = {}, {}, []
        for key, spec in flatten(document.get("settings", {})).items():
            specs.setdefault(key, {}).update(spec)
        for key, spec in document.get("overrides", {}).items():
            specs.setdefault(key, {}).update(copy.deepcopy(spec))
        metadata.update(document.get("metadata", {}))
        source = {
            "path": str(path.relative_to(self.resources)),
            "url": f"https://raw.githubusercontent.com/Ultimaker/Cura/{VERSION}/resources/{path.relative_to(self.resources)}",
            "sha256": digest(path),
        }
        return specs, metadata, sources + [source]


class Evaluator:
    """Small, explicit expression language used by Cura's settings definitions."""
    def __init__(self, specs, explicit=None):
        self.specs = specs
        self.explicit = explicit or {}
        self.values = {}
        self.stack = []
        self.fallbacks = {}

    def get(self, key):
        if key in self.explicit:
            return self.explicit[key]
        if key in self.values:
            return self.values[key]
        spec = self.specs[key]
        if key in self.stack:
            if "default_value" in spec:
                self.fallbacks[key] = "cyclic expression; retained declared default_value"
                return spec["default_value"]
            raise ValueError("No default for recursive setting " + key)
        self.stack.append(key)
        try:
            expression = spec.get("value")
            if expression is not None and expression != "":
                try:
                    value = self.node(ast.parse(str(expression), mode="eval").body)
                except (ValueError, KeyError, TypeError, ZeroDivisionError, OverflowError) as error:
                    if "default_value" not in spec:
                        raise ValueError(f"Cannot resolve {key}: {expression}: {error}") from error
                    value = spec["default_value"]
                    self.fallbacks[key] = str(error)
            elif "default_value" in spec:
                value = spec["default_value"]
            else:
                self.stack.pop()
                return None
            if spec.get("type") in ("int", "extruder", "optional_extruder") and isinstance(value, (float, int)):
                value = int(value)
            if isinstance(value, float) and not math.isfinite(value):
                raise ValueError(f"Non-finite result for {key}")
            self.values[key] = value
            return value
        finally:
            if self.stack and self.stack[-1] == key:
                self.stack.pop()

    def node(self, node):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Name):
            if node.id in self.functions:
                return self.functions[node.id]
            return self.get(node.id)
        if isinstance(node, (ast.List, ast.Tuple)):
            return [self.node(value) for value in node.elts]
        if isinstance(node, ast.BinOp):
            left, right = self.node(node.left), self.node(node.right)
            operations = {ast.Add: lambda: left + right, ast.Sub: lambda: left - right,
                          ast.Mult: lambda: left * right, ast.Div: lambda: left / right,
                          ast.FloorDiv: lambda: left // right, ast.Mod: lambda: left % right,
                          ast.Pow: lambda: left ** right}
            if type(node.op) not in operations:
                raise ValueError("Unsupported binary operation")
            return operations[type(node.op)]()
        if isinstance(node, ast.UnaryOp):
            value = self.node(node.operand)
            if isinstance(node.op, ast.Not): return not value
            if isinstance(node.op, ast.USub): return -value
            if isinstance(node.op, ast.UAdd): return value
            raise ValueError("Unsupported unary operation")
        if isinstance(node, ast.BoolOp):
            result = self.node(node.values[0])
            for value in node.values[1:]:
                if isinstance(node.op, ast.And) and not result: return result
                if isinstance(node.op, ast.Or) and result: return result
                result = self.node(value)
            return result
        if isinstance(node, ast.IfExp):
            return self.node(node.body if self.node(node.test) else node.orelse)
        if isinstance(node, ast.Compare):
            left = self.node(node.left)
            for op, right_node in zip(node.ops, node.comparators):
                right = self.node(right_node)
                comparisons = {ast.Eq: lambda: left == right, ast.NotEq: lambda: left != right,
                               ast.Lt: lambda: left < right, ast.LtE: lambda: left <= right,
                               ast.Gt: lambda: left > right, ast.GtE: lambda: left >= right,
                               ast.In: lambda: left in right, ast.NotIn: lambda: left not in right}
                if type(op) not in comparisons or not comparisons[type(op)](): return False
                left = right
            return True
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "math":
            allowed = {"ceil": math.ceil, "floor": math.floor, "tan": math.tan,
                       "radians": math.radians, "sqrt": math.sqrt, "pi": math.pi}
            if node.attr in allowed: return allowed[node.attr]
        if isinstance(node, ast.Call):
            function = self.node(node.func)
            if not callable(function): raise ValueError("Expression target is not callable")
            return function(*(self.node(arg) for arg in node.args))
        raise ValueError("Unsupported expression node: " + type(node).__name__)

    @property
    def functions(self):
        return {
            "min": min, "max": max, "round": round, "int": int, "float": float,
            "abs": abs, "sum": sum, "len": len, "any": any, "all": all, "map": map,
            "resolveOrValue": lambda key: self.get(key) if isinstance(key, str) else key,
            "extruderValue": lambda position, key: self.get(key) if isinstance(key, str) else key,
            "extruderValues": lambda key: [self.get(key)] if isinstance(key, str) else [key],
            "defaultExtruderPosition": lambda: 0,
            "anyExtruderWithMaterial": lambda key: bool(self.get(key)),
        }

    def settings(self):
        for key in self.specs:
            self.get(key)
        return {key: stringify(value) for key, value in sorted(self.values.items()) if value is not None} | {
            key: stringify(value) for key, value in self.explicit.items()
        }


def stringify(value):
    if isinstance(value, bool): return "true" if value else "false"
    if isinstance(value, (list, dict)): return json.dumps(value, separators=(",", ":"))
    return str(value)


def expression_ast(node):
    if isinstance(node, ast.Constant): return {"kind": "constant", "value": node.value}
    if isinstance(node, ast.Name): return {"kind": "name", "name": node.id}
    if isinstance(node, (ast.List, ast.Tuple)): return {"kind": "list", "args": [expression_ast(value) for value in node.elts]}
    if isinstance(node, ast.BinOp): return {"kind": "binary", "op": type(node.op).__name__, "args": [expression_ast(node.left), expression_ast(node.right)]}
    if isinstance(node, ast.UnaryOp): return {"kind": "unary", "op": type(node.op).__name__, "args": [expression_ast(node.operand)]}
    if isinstance(node, ast.BoolOp): return {"kind": "bool", "op": type(node.op).__name__, "args": [expression_ast(value) for value in node.values]}
    if isinstance(node, ast.IfExp): return {"kind": "if", "args": [expression_ast(node.test), expression_ast(node.body), expression_ast(node.orelse)]}
    if isinstance(node, ast.Compare): return {"kind": "compare", "ops": [type(value).__name__ for value in node.ops], "args": [expression_ast(node.left)] + [expression_ast(value) for value in node.comparators]}
    if isinstance(node, ast.Call):
        if isinstance(node.func, ast.Name): name = node.func.id
        elif isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and node.func.value.id == "math": name = "math." + node.func.attr
        else: raise ValueError("Unsupported expression call")
        return {"kind": "call", "name": name, "args": [expression_ast(value) for value in node.args]}
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "math": return {"kind": "name", "name": "math." + node.attr}
    raise ValueError("Unsupported AST export node " + type(node).__name__)


def read_material(path):
    root = ET.parse(path).getroot()
    ns = {"m": "http://www.ultimaker.com/material"}
    settings = {}
    material_type = root.findtext("m:metadata/m:name/m:material", namespaces=ns)
    brand = root.findtext("m:metadata/m:name/m:brand", namespaces=ns)
    material_name = " ".join(value for value in (brand, material_type, "1.75 mm") if value)
    for element in root.findall("m:settings/m:setting", ns):
        key = MATERIAL_MAP.get(element.get("key"))
        if key and element.text:
            settings[key] = float(element.text)
    for source, target in (("diameter", "material_diameter"), ("density", "material_density")):
        value = root.findtext("m:properties/m:" + source, namespaces=ns)
        if value: settings[target] = float(value)
    if "material_print_temperature" in settings:
        settings["default_material_print_temperature"] = settings["material_print_temperature"]
    if "material_bed_temperature" in settings:
        settings["default_material_bed_temperature"] = settings["material_bed_temperature"]
    return material_name, settings


def export(resources, output):
    definitions = Definitions(resources)
    materials = []
    for material_id, filename in (("pla", "generic_pla_175.xml.fdm_material"), ("abs", "generic_abs_175.xml.fdm_material"), ("petg", "generic_petg_175.xml.fdm_material")):
        path = resources / "materials" / filename
        if path.exists():
            label, settings = read_material(path)
            materials.append({"id": material_id, "name": label, "settings": {k: stringify(v) for k,v in settings.items()}, "sourceFiles": [str(path.relative_to(resources))], "sourceProvenance": [{"path": str(path.relative_to(resources)), "sha256": digest(path)}], "validation": "Generic 1.75 mm Cura material defaults; adjust temperatures for the actual filament and printer."})
    if not materials:
        # Retain Cura's declared material defaults rather than inventing temperatures.
        materials.append({"id": "default", "name": "Cura default material", "settings": {}, "sourceFiles": []})
    profiles = []
    base_specs, base_values = None, None
    for machine_id in MACHINES:
        specs, metadata, sources = definitions.load(machine_id)
        extruder_id = metadata["machine_extruder_trains"]["0"]
        extruder_specs, _, extruder_sources = definitions.load(extruder_id)
        for key, spec in extruder_specs.items():
            specs.setdefault(key, {}).update(spec)
        # Both machines have one nozzle. None of their -1 UI selectors should be
        # sent as an invalid extruder number to a standalone engine invocation.
        explicit = {"machine_extruder_count": 1, "extruders_enabled_count": 1, "extruder_nr": 0}
        evaluations = {}
        fallbacks = {}
        for material in materials:
            raw_material = {key: json.loads(value) if value in ("true", "false") else float(value) for key,value in material["settings"].items()}
            evaluator = Evaluator(specs, explicit | raw_material)
            settings = evaluator.settings()
            if base_specs is None:
                base_specs = copy.deepcopy(specs)
                base_values = copy.deepcopy(evaluator.values | evaluator.explicit)
            evaluations[material["id"]] = settings
            fallbacks[material["id"]] = evaluator.fallbacks
        settings = evaluations[materials[0]["id"]]
        profile = {
            "id": machine_id,
            "name": settings["machine_name"],
            "bedWidth": float(settings["machine_width"]),
            "bedDepth": float(settings["machine_depth"]),
            "bedHeight": float(settings["machine_height"]),
            "nozzleDiameter": float(settings["machine_nozzle_size"]),
            "settings": settings,
            "startGcode": settings["machine_start_gcode"],
            "endGcode": settings["machine_end_gcode"],
            "sourceFiles": [item["path"] for item in sources + extruder_sources],
            "sourceProvenance": sources + extruder_sources,
            "defaultMaterialID": materials[0]["id"],
            "materialIDs": [material["id"] for material in materials],
            "materialSettings": evaluations,
            "expressionFallbacks": fallbacks,
            "expressions": {key: str(spec["value"]) for key, spec in specs.items() if spec.get("value") not in (None, "")},
            "profileAuthor": metadata.get("author"),
            "outputFormat": "text/x-gcode",
            "supportsUSBConnection": metadata.get("supports_usb_connection", False),
            "validation": "Manufacturer-authored Cura profile; physical printing with this native frontend has not been validated.",
        }
        if settings["machine_gcode_flavor"] != "Repetier":
            raise ValueError("Native profile unexpectedly selected a non-Repetier dialect")
        if not settings["machine_start_gcode"].startswith("M911 "):
            raise ValueError("Native profile lost its Cubicon machine identifier")
        profiles.append(profile)
    result = {"schemaVersion": 1, "curaVersion": VERSION, "sourceRepository": "https://github.com/Ultimaker/Cura", "profiles": profiles, "materials": materials,
              "limitations": ["The application uses the Single Plus / 3DP-310F and Style Plus A15 manufacturer-authored Cura definitions; other printer variants are not supported.", "Only single-extruder expression semantics are exported.", "Changing layer height, infill, temperatures, or speed requires recalculating their dependent settings before slicing.", "Physical printing and printer connectivity are not validated by this export."]}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    expression_trees = {expression: expression_ast(ast.parse(expression, mode="eval").body) for profile in profiles for expression in profile["expressions"].values()}
    (output.parent / "Expressions.json").write_text(json.dumps({"schemaVersion": 1, "curaVersion": VERSION, "expressions": expression_trees}, ensure_ascii=False, indent=2) + "\n")
    base_definition = {"version": 2, "name": "Cubicon Native Standalone Base", "metadata": {"type": "machine", "author": "Generated from Cubicon R&D Center / UltiMaker Cura definitions", "cura_version": VERSION, "visible": False}, "settings": {key: {"type": base_specs.get(key, {}).get("type", "float" if isinstance(value, (int, float)) else "str"), "default_value": value} for key, value in sorted(base_values.items()) if value is not None}}
    (output.parent / "Base.def.json").write_text(json.dumps(base_definition, ensure_ascii=False, indent=2) + "\n")
    summary = [{"id": profile["id"], "settings": len(profile["settings"]), "materials": profile["materialIDs"], "fallbacks": profile["expressionFallbacks"]} for profile in profiles]
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cura-resources", type=Path, default=ROOT / "native/ProfileSources")
    parser.add_argument("--output", type=Path, default=ROOT / "native/Resources/Profiles.json")
    args = parser.parse_args()
    export(args.cura_resources.resolve(), args.output.resolve())
