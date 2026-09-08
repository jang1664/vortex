#!/usr/bin/env python3
"""Audit archived VHDL inputs and simulation/synthesis wrapper generic maps."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def generic_map(path):
    text = re.sub(r'--[^\n]*', '', path.read_text())
    maps = re.findall(r'generic\s+map\s*\((.*?)\)\s*port\s+map', text, re.I | re.S)
    if len(maps) != 1:
        raise ValueError(f'Expected one vendor generic map: {path}')
    return re.sub(r'\s+', '', maps[0]).lower()


def inspect(artifact, stage):
    records, sources = [], []
    for log in sorted(stage.glob('vhdlan_*.log')):
        text = log.read_text()
        if re.search(r'Error-\[|Error:', text):
            raise ValueError(f'Compiler error in {log}')
        for name in re.findall(r"Parsing design file '([^']+)'", text):
            path = Path(name).resolve(strict=True)
            if artifact / 'ip' not in path.parents:
                raise ValueError(f'Non-archived VHDL input: {path}')
            sources.append(path)
            records.append({'source': str(path), 'sha256': sha(path),
                            'log': str(log), 'log_sha256': sha(log)})
    wrappers = sorted(p for p in (artifact / 'ip').glob('*/sim/*.vhd') if p.stem == p.parent.parent.name)
    if not wrappers or not set(wrappers).issubset(sources):
        raise ValueError('Missing compiled archived wrapper records')
    matches = []
    for wrapper in wrappers:
        synth = wrapper.parent.parent / 'synth' / wrapper.name
        if generic_map(wrapper) != generic_map(synth):
            raise ValueError(f'Simulation/synthesis generic mismatch: {wrapper}')
        matches.append({'module': wrapper.stem, 'sim_sha256': sha(wrapper),
                        'synth_sha256': sha(synth), 'generic_map_equal': True})
    shared = []
    for source in sources:
        if source.parent.name != 'hdl':
            continue
        copies = list((artifact / 'ip').glob(f'*/hdl/{source.name}'))
        if any(sha(copy) != sha(source) for copy in copies):
            raise ValueError(f'Inconsistent archived vendor-library copies: {source.name}')
        shared.append({'name': source.name, 'identical_copies': len(copies), 'sha256': sha(source)})
    return {'stage': str(stage), 'compiled_vhdl': records, 'wrapper_matches': matches,
            'shared_library_matches': shared,
            'limitations': ['Compares generic maps and archived VHDL inputs, not formal gate-level equivalence.',
                            'Does not prove every compiled wrapper was elaborated or used by a workload.',
                            'Installed primitive simulation libraries and Xprop instrumentation require separate evidence.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.artifact.resolve(), args.stage.resolve())
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(f"Audited {len(result['compiled_vhdl'])} VHDL inputs and {len(result['wrapper_matches'])} wrapper maps")
