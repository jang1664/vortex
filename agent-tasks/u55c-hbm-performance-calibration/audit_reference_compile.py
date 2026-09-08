#!/usr/bin/env python3
"""Audit actual vlogan parsing paths, resolving staged library symlinks."""
import argparse
import json
from pathlib import Path
import re

from audit_archive import digest


def inspect(root, stage, repo, repo_ram=False, guarded_fma=False, guarded_f32mul=False, guarded_f32add=False):
    root, stage, repo = [p.resolve(strict=True) for p in (root, stage, repo)]
    archive_roots = [root / p for p in ('src', 'xo/packaged_kernel/src',
                                       'xo/project/patched_src')]
    harness = {repo / 'sim/xrtsim_vcs' / name for name in (
        'tb_vcs_xrtsim.sv', 'VX_hbm_axi_guard.sv', 'xilinx_fpu_ip_config.sv')}
    harness.update(repo / 'hw/dpi' / name for name in ('float_dpi.vh', 'util_dpi.vh'))
    harness.add(stage / 'u55c_model_config.svh')
    fma_guards = {repo / 'agent-tasks/u55c-hbm-performance-calibration' / name
                  for name in ('reference_fma_guard.sv', 'reference_fma_guard_bind.sv')}
    if guarded_fma:
        harness.update(fma_guards)
    mul_guards = {repo / 'agent-tasks/u55c-hbm-performance-calibration' / name
                  for name in ('reference_binary_fp_guard.sv', 'reference_f32mul_guard_bind.sv')}
    if guarded_f32mul:
        harness.update(mul_guards)
    add_guards = {repo / 'agent-tasks/u55c-hbm-performance-calibration' / name
                  for name in ('reference_binary_fp_guard.sv', 'reference_f32add_guard_bind.sv')}
    if guarded_f32add:
        harness.update(add_guards)
    ram_sources = {repo / 'hw/rtl/libs' / name for name in ('VX_dp_ram.sv', 'VX_sp_ram.sv')}
    pattern = re.compile(r"Parsing (?:design|included|library directory) file '([^']+)'")
    seen = {}
    log = stage / 'vlogan.log'
    with log.open() as stream:
        for line_number, line in enumerate(stream, 1):
            match = pattern.search(line)
            if match:
                seen.setdefault(match.group(1), line_number)
    if not seen:
        raise ValueError('No compiler parsing records found')
    records = []
    for path, line_number in sorted(seen.items()):
        source = Path(path)
        if not source.is_absolute():
            source = stage / source  # vlogan's recorded working directory.
        source = source.resolve(strict=True)
        kind = ('archive' if any(p in source.parents for p in archive_roots)
                else 'approved_repo_ram' if repo_ram and source in ram_sources
                else 'harness' if source in harness else 'unexpected')
        records.append({'compiler_path': path, 'resolved_path': str(source),
                        'kind': kind, 'sha256': digest(source), 'log_line': line_number})
    if repo_ram:
        overrides = [r for r in records if r['kind'] == 'approved_repo_ram']
        if {Path(r['resolved_path']) for r in overrides} != ram_sources:
            raise ValueError('Expected compiled dual/single-port repo RAM overrides')
        if any(r['kind'] == 'archive' and Path(r['resolved_path']).name in ('VX_dp_ram.sv', 'VX_sp_ram.sv')
               for r in records):
            raise ValueError('Both archived and repo VX_dp_ram were compiled')
    if guarded_fma and not fma_guards.issubset({Path(r['resolved_path']) for r in records}):
        raise ValueError('Missing required FMA boundary guard compile records')
    if guarded_f32mul and not mul_guards.issubset({Path(r['resolved_path']) for r in records}):
        raise ValueError('Missing required multiplier boundary guard compile records')
    if guarded_f32add and not add_guards.issubset({Path(r['resolved_path']) for r in records}):
        raise ValueError('Missing required adder boundary guard compile records')
    return {
        'artifact_root': str(root), 'stage': str(stage),
        'compiler_log_sha256': digest(log), 'records': records,
        'counts': {kind: sum(r['kind'] == kind for r in records)
                   for kind in ('archive', 'harness', 'approved_repo_ram', 'unexpected')},
        'limitations': ['C++ and separately compiled VHDL IP are outside this vlogan audit.',
                        'Inactive preprocessor paths are not compiler inputs.',
                        'Current hashes do not detect an unrecorded past file mutation.'],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', required=True, type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    parser.add_argument('--repo', required=True, type=Path)
    parser.add_argument('--repo-ram', action='store_true')
    parser.add_argument('--guarded-fma', action='store_true')
    parser.add_argument('--guarded-f32mul', action='store_true')
    parser.add_argument('--guarded-f32add', action='store_true')
    args = parser.parse_args()
    result = inspect(args.artifact, args.stage, args.repo, args.repo_ram,
                     args.guarded_fma, args.guarded_f32mul, args.guarded_f32add)
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(bool(result['counts']['unexpected']))
