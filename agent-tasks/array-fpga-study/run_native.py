#!/usr/bin/env python3
"""Prepare matched snapshots, verify reuse, and synthesize the derived WoQ engine."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
TASK = Path(__file__).resolve().parent
sys.path.insert(0, str(TASK.parent/'fig5-fpga'))
from run import ROOT, PART, VIVADO, prepare
from prepare_woq import derive_woq, TOP
from resources import sha

def write(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-build',type=Path,required=True)
    ap.add_argument('--prepare-only',action='store_true')
    ap.add_argument('--verification',type=Path)
    a=ap.parse_args()
    build=Path.cwd().resolve()
    assert (build/'config.mk').is_file(), 'Run in configured build directory'
    defs=shlex.split(os.environ['CONFIGS'])
    base=a.baseline_build.resolve()/'fig5_fpga_compute'
    outroot=build/'array_fpga_native'
    outroot.mkdir(exist_ok=True)
    compatible=[]
    for name,top in [('tcu_fp16','VX_tcu_top'),('fpint_32x32','VX_gemm_unit_top')]:
        manifest=json.loads((base/name/'manifest.json').read_text())
        assert defs==manifest['defines'], 'Config mismatch'
        assert manifest['part']==PART
        assert manifest['ip_config_sha256']==sha(ROOT/'hw/scripts/xilinx_ip_gen.tcl')
        assert json.loads((base/name/'status.json').read_text())['success']
        src=outroot/'sources'/name
        flist=prepare(top,src,defs)
        if name=='tcu_fp16':
            p=src/'VX_tcu_top.sv'
            text=p.read_text()
            assert text.count(') VX_execute_if();')==1
            p.write_text(text.replace(') VX_execute_if();',') execute_if();'))
        old=json.loads((base/'sources'/name/'snapshot.json').read_text())
        oldhash={Path(x['snapshot']).name:x['sha256'] for x in old['sources']}
        newhash={Path(x).name:sha(x) for x in flist.read_text().splitlines()}
        assert oldhash==newhash, f'{name}: source snapshot mismatch; resynthesize baseline'
        for item in old['sources']: assert sha(item['snapshot'])==item['sha256'], 'Stale baseline source'
        snap=json.loads((src/'snapshot.json').read_text())
        for item in snap['sources']:
            if item['sha256'] != sha(item['snapshot']):
                item['before_wrapper_fix_sha256']=item['sha256']
                item['sha256']=sha(item['snapshot'])
                item['fix']='TCU execute_if instance rename (same as Fig.5)'
        write(src/'snapshot.json',snap)
        compatible.append(dict(point=name,source_hashes=newhash,baseline=str(base/name),
            baseline_hierarchy_sha256=sha(base/name/'hierarchy.rpt'),
            baseline_checkpoint_sha256=sha(base/name/'post_opt.dcp'),
            ip_config_sha256=manifest['ip_config_sha256'],defines=defs))
    write(outroot/'baseline_compatibility.json',compatible)
    woqsrc=outroot/'sources'/'woq_derived_native'
    flist=derive_woq(outroot/'sources/fpint_32x32/sources.txt',woqsrc)
    out=outroot/'woq_derived_native'
    out.mkdir(exist_ok=True)
    ipscript=out/'ip_setup.tcl'
    ipscript.write_bytes((base/'fpint_32x32/ip_setup.tcl').read_bytes())
    write(out/'manifest.json',dict(top=TOP,macs_per_cycle=1024,target_clock_mhz=100,part=PART,
        defines=defs,rtl_root=str(ROOT),git_commit=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),
        scope='production GEMM with internal 256 KiB ACC; compile-time WoQ ablation',
        mapping='native DSP, production attributes and FP IP settings',
        ip_script_sha256=sha(ipscript),ablation_sha256=sha(woqsrc/'ablation.json')))
    if a.prepare_only:
        print('Prepared matched snapshots; both baseline hashes match. Synthesis not started.')
        return
    assert a.verification, '--verification is required before synthesis'
    verification=json.loads(a.verification.read_text())
    assert verification['status']=='pass', 'Functional gate not passed'
    test_manifest=json.loads((a.verification.parent/'test_manifest.json').read_text())
    verified_hashes={Path(k).name:v for k,v in test_manifest['source_hashes'].items()}
    for source in flist.read_text().splitlines():
        assert verified_hashes[Path(source).name]==sha(source), 'Verification/synthesis source mismatch'
    vendor_path=build/'vendor_ip_check/result.json'
    vendor=json.loads(vendor_path.read_text())
    assert vendor['status']=='pass' and vendor['measured_handshake_latency']==1
    assert vendor['testbench_sha256']==sha(TASK/'vendor_ip_tb.sv')
    write(out/'verification_gate.json',dict(report=str(a.verification.resolve()),sha256=sha(a.verification),report_data=verification,
        verified_source_hashes=verified_hashes,vendor_report=vendor,vendor_report_sha256=sha(vendor_path)))
    assert not (out/'post_opt.dcp').exists(), 'Existing result: use a fresh configured build for rerun'
    cmd=[VIVADO,'-mode','batch','-source',str(TASK.parent/'fig5-fpga/synth.tcl'),'-tclargs',TOP,PART,str(flist),str(out),'']
    write(out/'command.json',cmd)
    write(out/'status.json',dict(state='running',success=False))
    started=time.time()
    print('START WoQ native synthesis',flush=True)
    with (out/'console.log').open('w') as log:
        rc=subprocess.run(cmd,cwd=out,env=dict(os.environ,FIG5_IP_TCL=str(ipscript),FIG5_RTL_ROOT=str(ROOT)),stdout=log,stderr=subprocess.STDOUT).returncode
    status=dict(exit_code=rc,success=rc==0 and (out/'summary.json').is_file() and (out/'post_opt.dcp').is_file(),elapsed_s=round(time.time()-started,1))
    write(out/'status.json',status)
    print(json.dumps(status),flush=True)
    if not status['success']: raise SystemExit(1)

if __name__=='__main__': main()
