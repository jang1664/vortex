"""Run matched TH16 softmax RAW correctness and performance probes in VCS."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('phase')
parser.add_argument('--build', default='build_axi_raw_port')
parser.add_argument('--cases', nargs='+', choices=['normal', 'inorder', 'reordered'], default=['reordered', 'normal'])
parser.add_argument('--write-depth', type=int, default=None)
args = parser.parse_args()
if args.write_depth is not None and args.write_depth <= 0:
    parser.error('--write-depth must be positive')
repo = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent / args.phase
out.mkdir(exist_ok=True)
build = repo / args.build
config = repo / 'configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh'
stress = ('+ntb_random_seed=19 +DRAM_REQ_STALL_P_ENTER_PCT=50 '
          '+DRAM_REQ_STALL_P_EXIT_PCT=10 +DRAM_RSP_STALL_P_ENTER_PCT=75 '
          '+DRAM_RSP_STALL_P_EXIT_PCT=5')
flags = {'normal': '+ntb_random_seed=19', 'inorder': stress,
         'reordered': stress + ' +DRAM_RSP_REORDER'}
records = []
for case in args.cases:
    env = dict(os.environ, CC='/usr/bin/gcc', CXX='/usr/bin/g++',
               SOFTMAX_LAYOUT_FUSED_VARIANT='rev2_shuffle_cursor',
               VCS_SIMV_FLAGS=flags[case])
    cmd = ['bash', '-c', 'source "$1"; if [ -n "$2" ]; then CONFIGS+=" -DAXI_WRITE_PENDING_SIZE=$2"; export CONFIGS; fi; shift 2; exec "$@"', 'raw-probe',
           str(config), str(args.write_depth) if args.write_depth is not None else '', 'timeout', '600', 'bash', 'ci/run_black.sh',
           'xrt-vcs-sim', '--app', 'softmax_layout_fused', '--perf', '0',
           '--args', '-batch 1 -heads 1 -seqq 32 -seqk 32 -seqk-stride 32 '
           '-mask 1 -scale 0.125 -seed 2986547050']
    start = time.monotonic()
    print('START', args.phase, case, flush=True)
    with (out / (case + '.log')).open('w') as log:
        code = subprocess.call(cmd, cwd=build, env=env, stdout=log,
                               stderr=subprocess.STDOUT)
    text = (out / (case + '.log')).read_text()
    cycles = re.search(r'PERF: instrs=\d+, cycles=(\d+)', text)
    errors = re.search(r'max_diff=([0-9.]+) errors=(\d+)', text)
    simlog = build / 'sim/xrtsim_vcs/simv.log'
    if simlog.exists(): shutil.copyfile(simlog, out / (case + '.sim.log'))
    kernel = build / 'tests/regression/softmax_layout_fused/kernel.vxbin'
    stats = []
    if simlog.exists():
        for line in simlog.open():
            if 'RAW_DEPTH_STATS ' in line:
                stats.append({k: int(v) for k, v in re.findall(r'(\w+)=([0-9]+)', line)})
    record = dict(case=case, write_depth=args.write_depth, depth_stats=stats, exit_code=code, elapsed_s=time.monotonic()-start,
                  flags=flags[case], passed=code == 0 and 'PASSED!' in text,
                  cycles=int(cycles[1]) if cycles else None,
                  errors=int(errors[2]) if errors else None,
                  max_diff=float(errors[1]) if errors else None,
                  kernel_sha256=hashlib.sha256(kernel.read_bytes()).hexdigest()
                  if kernel.exists() else None)
    if case in ('normal', 'inorder') and cycles:
        baseline = {'normal': 164179, 'inorder': 286220}[case]
        record['baseline_cycles'] = baseline
        record['degradation_pct'] = (int(cycles[1])/baseline-1)*100
    records.append(record)
    (out / 'results.json').write_text(json.dumps(records, indent=2)+'\n')
    print('DONE', json.dumps(record), flush=True)
    if not record['passed']: break
