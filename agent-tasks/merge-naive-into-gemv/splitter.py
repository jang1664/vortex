#!/usr/bin/env python3
"""Run the splitter VCS regression in a configured, config-sourced build."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent / 'execution/splitter'
TASK.mkdir(exist_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', type=Path, default=ROOT / 'hw/rtl/mem/VX_mem_bus_split.sv')
    parser.add_argument('--output-name', default='split_verified')
    args = parser.parse_args()
    build = ROOT / 'build_merge_splitter'
    build.mkdir(exist_ok=True)
    with (TASK / 'unit_configure.log').open('w') as log:
        subprocess.run(['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                        f'--prefix={Path.home()}/tools/vortex'], cwd=build,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    raw = subprocess.check_output(['bash', '-c', 'source "$1"; env -0', 'bash',
                                   str(ROOT / 'agent-tasks/naive-dma256-depth/configs/d8_r32.sh')], cwd=ROOT)
    env = dict(x.split('=', 1) for x in raw.decode().split('\0') if '=' in x)
    env.update(CC='/usr/bin/gcc', CXX='/usr/bin/g++')
    # Geometry, depth, mask, seed, reorder, injected reordering, ID bits,
    # naive preprocessing, debug UUID/trace preprocessing.
    matrix = [(l,b,d,1,1,o,o,12,1,0) for o in [0,1]
              for l,b in [(4,64),(32,8)] for d in [8,16,32,64,128]]
    matrix += [(l,b,d,0,2,1,1,12,1,0) for l,b in [(4,64),(32,8)] for d in [8,128]]
    matrix += [(l,b,128,1,2,1,1,5,1,0) for l,b in [(4,64),(32,8)]]
    matrix += [(l,b,8,0,3,0,0,12,0,0) for l,b in [(4,64),(32,8)]]
    matrix += [(4,64,16,1,3,1,1,12,1,1)]
    rtl = ROOT / 'hw/rtl'
    tb = ROOT / 'hw/unittest/mem_bus_split_depth/tb_mem_bus_split_depth.sv'
    results = []
    for lanes, size, depth, masked, seed, reorder, inject, tagbits, naive, debug in matrix:
        name = f'l{lanes}_d{depth}_m{masked}_s{seed}_o{reorder}_t{tagbits}_n{naive}_dbg{debug}'
        out = build / args.output_name / name
        out.mkdir(parents=True, exist_ok=True)
        cmd = ['vcs', '-full64', '-sverilog', '-timescale=1ns/1ps',
               '+define+SIMULATION', '+define+XLEN_64',
               *(['+define+GEMM_NAIVE'] if naive else []),
               '+define+DBG_TRACE_MEM' if debug else '+define+NDEBUG',
               f'+incdir+{rtl}', '+libext+.sv', '-y', str(rtl / 'libs'),
               '-y', str(rtl / 'mem'), str(rtl / 'VX_gpu_pkg.sv'),
               str(rtl / 'mem/VX_mem_bus_if.sv'), str(args.rtl.resolve()),
               str(tb), '-top', 'tb_mem_bus_split_depth']
        parameters = dict(LANES=lanes, BYTES=size, DEPTH=depth, MASKED=masked,
                          SEED=seed, REORDER=reorder, INJECT_REORDER=inject, TAG_BITS=tagbits)
        cmd += [f'-pvalue+tb_mem_bus_split_depth.{k}={v}' for k, v in parameters.items()]
        with (out / 'compile.log').open('w') as log:
            subprocess.run(cmd, cwd=out, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        with (out / 'sim.log').open('w') as log:
            p = subprocess.run(['./simv'], cwd=out, env=env, stdout=log,
                               stderr=subprocess.STDOUT, timeout=120)
        text = (out / 'sim.log').read_text()
        passed = p.returncode == 0 and 'TEST PASSED:' in text and 'Fatal' not in text
        results.append(dict(**parameters, naive=naive, debug=debug, passed=passed,
                            rtl=str(args.rtl.resolve()), log=str(out / 'sim.log')))
        (TASK / (args.output_name + '_results.json')).write_text(json.dumps(results, indent=2) + '\n')
        print(name, passed, flush=True)
        if not passed:
            return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
