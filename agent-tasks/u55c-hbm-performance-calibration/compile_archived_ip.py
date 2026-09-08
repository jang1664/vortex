#!/usr/bin/env python3
"""Compile existing archived IP simulation sources without generating new IP."""
import argparse
from pathlib import Path
import shutil
import subprocess


def compile_ip(artifact, stage, simlib):
    compiler = shutil.which('vhdlan')
    if not compiler:
        raise RuntimeError('vhdlan is unavailable')
    if not simlib.is_file():
        raise RuntimeError('Existing VCS simulation library mapping is unavailable')
    entries = [
        ('xbip_utils_v3_0_14', 'xbip_utils_v3_0_vh_rfs.vhd'),
        ('axi_utils_v2_0_10', 'axi_utils_v2_0_vh_rfs.vhd'),
        ('xbip_pipe_v3_0_10', 'xbip_pipe_v3_0_vh_rfs.vhd'),
        ('xbip_dsp48_wrapper_v3_0_7', 'xbip_dsp48_wrapper_v3_0_vh_rfs.vhd'),
        ('mult_gen_v12_0_23', 'mult_gen_v12_0_vh_rfs.vhd'),
        ('floating_point_v7_1_20', 'floating_point_v7_1_vh_rfs.vhd'),
    ]
    mapping = ['LIBRARY_SCAN=TRUE', 'WORK > DEFAULT',
               f'DEFAULT:{stage / "vcs_lib/work"}']
    for name in ['work', 'xil_defaultlib'] + [name for name, _ in entries]:
        directory = stage / 'vcs_lib' / name
        directory.mkdir(parents=True, exist_ok=True)
        mapping.append(f'{name}:{directory}')
    mapping.append(f'OTHERS={simlib}')
    (stage / 'synopsys_sim.setup').write_text('\n'.join(mapping) + '\n')
    for name, filename in entries:
        source = artifact / 'ip/xil_fma/hdl' / filename
        if not source.is_file():
            raise RuntimeError(f'Missing archived IP source: {source}')
        subprocess.run([compiler, '-full64', '-work', name, str(source),
                        '-l', str(stage / f'vhdlan_{name}.log')], cwd=stage, check=True)
    wrappers = sorted(p for p in (artifact / 'ip').glob('*/sim/*.vhd')
                      if p.stem == p.parent.parent.name)
    if not wrappers:
        raise RuntimeError('No archived IP wrappers found')
    subprocess.run([compiler, '-full64', '-work', 'xil_defaultlib',
                    *map(str, wrappers), '-l', str(stage / 'vhdlan_wrappers.log')],
                   cwd=stage, check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('artifact', 'stage', 'simlib'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    compile_ip(args.artifact.resolve(), args.stage.resolve(), args.simlib.resolve())
