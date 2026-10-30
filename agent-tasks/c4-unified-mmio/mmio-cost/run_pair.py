#!/usr/bin/env python3
"""Freeze and optionally synthesize only the paired retained GEMM MMIO path."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile
from datetime import datetime

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CONFIG = 'configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh'
BASELINE = '12382c883'
PART = 'xcu55c-fsvh2892-2L-e'
TOP = 'VX_mmio_cost_top'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True,
                        help='Existing configured build directory; never configures or cleans it')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare-only', action='store_true')
    mode.add_argument('--run', action='store_true')
    parser.add_argument('--name', default=datetime.now().strftime('%Y%m%d_%H%M%S'))
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    if not (build / 'config.mk').is_file():
        parser.error('--build-dir must contain configure-generated config.mk')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', args.name):
        parser.error('--name must be a simple directory name')
    out = HERE / 'runs' / args.name
    out.mkdir(parents=True, exist_ok=False)
    flags = shlex.split(subprocess.check_output(
        ['bash', '-c', f'source {CONFIG}; printf "%s" "$CONFIGS"'], cwd=ROOT, text=True))
    flags += ['-DXLEN_64', '-DNDEBUG', '-DSYNTHESIS']
    assert '-DGEMM_SRAM_FUSION' in flags
    archive = subprocess.check_output(['git','archive',BASELINE,'hw/rtl'], cwd=ROOT)
    baseline = out / 'baseline_sources'
    baseline.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(baseline, filter='data')
    candidate = out / 'candidate_sources'
    shutil.copytree(ROOT / 'hw/rtl', candidate / 'hw/rtl')
    shutil.copy2(HERE / f'{TOP}.sv', out / f'{TOP}.sv')
    shutil.copy2(HERE / 'mmio-cost.xdc', out / 'mmio-cost.xdc')
    # Existing unit manifest supplies this hierarchy's ordinary shared helpers.
    unit = (ROOT / 'hw/unittest/mmio_serializer/Makefile').read_text().split('INCDIRS :=')[0]
    sources = list(dict.fromkeys(re.findall(r'\$\(RTL_DIR\)/([A-Za-z0-9_/]+\.sv)', unit)))
    for helper in ['libs/VX_fifo_queue.sv','libs/VX_pending_size.sv','libs/VX_dp_ram.sv']:
        if helper not in sources:
            sources.append(helper)
    assert sources[0] == 'VX_gpu_pkg.sv'
    assert all('gemm_node' not in s and 'sram_io' not in s and 'fusion_ctrl' not in s for s in sources)
    script = ROOT / 'hw/syn/xilinx/dut/ooc_synth.tcl'
    tool_dir = ROOT / 'hw/scripts'
    vivado = shutil.which('vivado')
    if not vivado:
        raise RuntimeError('Vivado is not on PATH')
    metadata = {'baseline_commit':BASELINE, 'config':CONFIG, 'part':PART,
                'clock_ns':5.0, 'input_output_delay_ns':0.0,
                'scope':'retained GEMM MMIO path; excludes SRAM sequencer and removed fusion controller/link',
                'configured_build':str(build), 'flags':flags, 'variants':{}}
    commands = []
    for variant, snapshot in [('baseline',baseline), ('candidate',candidate)]:
        variant_flags = flags + (['-DMMIO_COST_CANDIDATE'] if variant == 'candidate' else [])
        selected = [snapshot/'hw/rtl'/s for s in sources
                    if variant == 'candidate' or s != 'core/VX_mmio_serializer.sv']
        selected.append(out/f'{TOP}.sv')
        includes = [snapshot/'hw/rtl'/s for s in ['', 'core','mem','libs']]
        manifest = out / f'{variant}.f'
        manifest.write_text('\n'.join(['+define+'+f[2:] for f in variant_flags]
            + ['+incdir+'+str(p) for p in includes] + [str(p) for p in selected])+'\n')
        hashes = {str(p.relative_to(snapshot)) if p.is_relative_to(snapshot) else p.name:
                  hashlib.sha256(p.read_bytes()).hexdigest() for p in selected}
        command = [vivado,'-mode','batch','-source',str(script),'-tclargs',TOP,PART,
                   str(manifest),str(out/'mmio-cost.xdc'),str(out/variant),str(args.jobs),'0','']
        metadata['variants'][variant] = {'source_sha256':hashes,'command':command}
        commands.append((variant,command))
        # Preprocessing only: catches missing includes/macros without elaboration,
        # simulation or synthesis. Preserve selected wrapper for width review.
        pp = subprocess.run(['verilator','-E','-P','-Wno-fatal']+variant_flags
            + ['-I'+str(p) for p in includes]+[str(out/f'{TOP}.sv')],
            cwd=build,text=True,capture_output=True,check=True)
        (out/f'{variant}_wrapper.pp.sv').write_text(pp.stdout)
    (out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(f'Prepared paired MMIO sources and commands: {out}', flush=True)
    if args.run:
        env = os.environ.copy()
        env['TOOL_DIR'] = str(tool_dir)
        for variant,command in commands:
            # Keep Vivado journals and logs inside this measurement artifact.
            run_cwd = out / f'{variant}_launch'
            run_cwd.mkdir()
            with (out/f'{variant}_launch.log').open('w') as log:
                subprocess.run(command,cwd=run_cwd,env=env,stdout=log,
                               stderr=subprocess.STDOUT,check=True)
            report = out/variant/'post_synth_util.rpt'
            if not report.is_file():
                raise RuntimeError(f'Missing utilization report: {report}')
            print(f'{variant} synthesis completed: {report}', flush=True)

if __name__ == '__main__':
    main()
