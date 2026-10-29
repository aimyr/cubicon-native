#!/usr/bin/env python3
"""Native slicing smoke test, including printable-coordinate bounds validation."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
VERTEX = re.compile(r'(\s*vertex\s+)([-+\d.eE]+)\s+([-+\d.eE]+)\s+([-+\d.eE]+)')
WORD = re.compile(r'([A-Z])\s*([-+]?(?:\d*\.)?\d+(?:[eE][-+]?\d+)?)')


def centered_cube() -> Path:
    source = (ROOT / 'samples/test-cube-20mm.stl').read_text()
    vertices = [tuple(float(m.group(i)) for i in (2, 3, 4)) for m in VERTEX.finditer(source)]
    center = [(min(v[i] for v in vertices) + max(v[i] for v in vertices)) / 2 for i in (0, 1)]
    bottom = min(v[2] for v in vertices)
    def replace(m):
        x, y, z = (float(m.group(i)) for i in (2, 3, 4))
        return f'{m.group(1)}{x-center[0]:.6f} {y-center[1]:.6f} {z-bottom:.6f}'
    target = ROOT / 'build/native-smoke/cube-centered.stl'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(VERTEX.sub(replace, source))
    return target


def extrusion_bounds(text: str, profile: dict) -> dict:
    """Parse modal G-code; ignore stationary E-only priming/retraction moves."""
    position = {'X': None, 'Y': None, 'Z': None, 'E': 0.0}
    xyz_absolute = True
    e_absolute = True
    points = []
    count = 0
    for original in text.splitlines():
        code = original.split(';', 1)[0].strip().upper()
        if not code: continue
        tokens = dict((k, float(v)) for k, v in WORD.findall(code))
        command = code.split()[0]
        if command == 'G90': xyz_absolute = True; continue
        if command == 'G91': xyz_absolute = False; continue
        if command == 'M82': e_absolute = True; continue
        if command == 'M83': e_absolute = False; continue
        if command == 'G92':
            for axis in position:
                if axis in tokens: position[axis] = tokens[axis]
            continue
        if command not in ('G0', 'G00', 'G1', 'G01'): continue
        previous = position.copy()
        for axis in ('X', 'Y', 'Z'):
            if axis in tokens:
                position[axis] = tokens[axis] if xyz_absolute else (position[axis] or 0) + tokens[axis]
        if 'E' in tokens:
            position['E'] = tokens['E'] if e_absolute else position['E'] + tokens['E']
        xy_motion = any(axis in tokens and (previous[axis] is None or abs(position[axis]-previous[axis]) > 1e-7) for axis in ('X', 'Y'))
        if 'E' in tokens and position['E'] > previous['E'] + 1e-7 and xy_motion:
            count += 1
            for point in (previous, position):
                if all(point[a] is not None for a in ('X', 'Y', 'Z')):
                    points.append(tuple(point[a] for a in ('X', 'Y', 'Z')))
    if not points:
        return {'within_bed': False, 'command_within_bed': False, 'extrusion_moves': 0}
    settings = profile['settings']
    offset_x = float(settings.get('machine_nozzle_offset_x', 0)) if settings.get('machine_use_extruder_offset_to_offset_coords') == 'true' else 0
    offset_y = float(settings.get('machine_nozzle_offset_y', 0)) if settings.get('machine_use_extruder_offset_to_offset_coords') == 'true' else 0
    logical = [(x + offset_x, y + offset_y, z) for x, y, z in points]
    def bounds(pts):
        return {axis: [round(min(p[i] for p in pts), 4), round(max(p[i] for p in pts), 4)] for i, axis in enumerate(('x', 'y', 'z'))}
    command_bounds, logical_bounds = bounds(points), bounds(logical)
    centered = settings.get('machine_center_is_zero') == 'true'
    limits = {'x': [-profile['bedWidth']/2, profile['bedWidth']/2] if centered else [0, profile['bedWidth']], 'y': [-profile['bedDepth']/2, profile['bedDepth']/2] if centered else [0, profile['bedDepth']], 'z': [0, profile['bedHeight']]}
    def valid(b):
        return all(b[a][0] >= limits[a][0] - 0.02 and b[a][1] <= limits[a][1] + 0.02 for a in limits)
    return {'command_bounds_mm': command_bounds, 'logical_bounds_mm': logical_bounds, 'bed_limits_mm': limits, 'nozzle_offset_mm': [offset_x, offset_y], 'within_bed': valid(logical_bounds), 'command_within_bed': valid(command_bounds), 'extrusion_moves': count}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Cubicon Native.app", help="App bundle to verify (default: build/Cubicon Native.app)")
    args = parser.parse_args()
    resources = args.app.expanduser().resolve() / "Contents/Resources"
    engine = resources / "Engine/CubiEngine"
    if not engine.is_file():
        raise SystemExit(f"Build the native app first; engine missing: {engine}")
    (ROOT / "reports").mkdir(parents=True, exist_ok=True)
    profiles = json.loads((resources / "Profiles.json").read_text())["profiles"]
    base = resources / "Base.def.json"
    model = centered_cube()
    reports = []
    for profile in profiles:
        ident = profile['id']
        out = ROOT / f'reports/native-{ident}-cube.gcode'
        log = ROOT / f'reports/native-{ident}-engine.log'
        settings = profile['settings'].copy()
        # MeshGroup::finalize adds half-bed itself for front-left-origin printers.
        # The input mesh is relative to the bed center; never add half-bed twice.
        settings.update({'machine_extruder_count': '1', 'extruders_enabled_count': '1', 'layer_height': '0.2', 'layer_height_0': '0.2', 'mesh_position_x': '0', 'mesh_position_y': '0', 'mesh_position_z': '0', 'center_object': 'false'})
        cmd = [str(engine), 'slice', '-v', '-j', str(base)]
        for k, v in sorted(settings.items()): cmd += ['-s', f'{k}={v}']
        cmd += ['-e0', '-s', 'extruder_nr=0', '-l', str(model), '-o', str(out)]
        started = time.monotonic()
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
            exitcode = result.returncode
            log.write_text(result.stdout + result.stderr)
        except subprocess.TimeoutExpired as e:
            log.write_bytes((e.stdout or b'') + (e.stderr or b'')); exitcode = None
        text = out.read_text(errors='replace') if out.exists() else ''
        rows = text.splitlines()
        layers = {int(m.group(1)) for row in rows if (m := re.match(r'^;LAYER:(\d+)', row))}
        spatial = extrusion_bounds(text, profile)
        passed = exitcode == 0 and len(text) > 10000 and len(layers) == 100 and 'M904' in rows and spatial['within_bed'] and spatial['command_within_bed'] and spatial['extrusion_moves'] > 0
        report = {'profile': ident, 'engine_architecture': 'arm64', 'engine_version': '5.13.0', 'engine_exit_code': exitcode, 'elapsed_seconds': round(time.monotonic()-started, 2), 'model': str(model), 'coordinate_convention': 'STL relative to bed center; center_object=false; mesh_position_xyz=0; engine adds half-bed once.', 'output': str(out), 'output_bytes': out.stat().st_size if out.exists() else 0, 'output_sha256': hashlib.sha256(out.read_bytes()).hexdigest() if out.exists() else None, 'object_layer_count': len(layers), 'g0_g1_move_count': sum(bool(re.match(r'^G[01]\s', x)) for x in rows), 'start_m911': next((x for x in rows if x.startswith('M911 ')), None), 'end_m904': 'M904' in rows, 'end_heater_off': 'M104 S0' in rows and 'M140 S0' in rows, 'spatial_validation': spatial, 'status': 'passed' if passed else 'failed', 'scope': 'Geometry/G-code smoke test only; no printer connection or physical print.'}
        reports.append(report)
        print(json.dumps(report, ensure_ascii=False), flush=True)
    # A negative control ensures a path leaving the bed can never be called PASS.
    bad = 'M82\nG92 E0\nG0 X0 Y0 Z0.2\nG1 X999 Y999 E1\n'
    assert all(not extrusion_bounds(bad, p)['within_bed'] for p in profiles), 'Out-of-bed validator negative control failed'
    (ROOT / 'reports/native-engine-smoke.json').write_text(json.dumps(reports, ensure_ascii=False, indent=2)+'\n')
    return 0 if all(r['status'] == 'passed' for r in reports) else 1


if __name__ == '__main__':
    raise SystemExit(main())
