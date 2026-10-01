#!/usr/bin/env python3
"""Follow-up compute synthesis; invoked only after the memory sweep is reviewed."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import sys
from run import ROOT, TASK, PART, VIVADO, prepare

build = Path.cwd()
assert (build/'config.mk').exists()
defines=shlex.split(os.environ['CONFIGS'])
assert '-DNUM_THREADS=32' in defines and '-DMXU_COL_TILE=32' in defines
outputs=build/'fig5_fpga_compute'
outputs.mkdir(exist_ok=True)
IP_SOURCE=ROOT/'hw/scripts/xilinx_ip_gen.tcl'
ip_text=IP_SOURCE.read_text()
starts=list(re.finditer(r'^ensure_floating_point_ip \$\{ip_dir\} (\w+)\s*$',ip_text,re.M))
blocks={m[1]:ip_text[m.start():starts[i+1].start() if i+1<len(starts) else ip_text.index('generate_target all')]
        for i,m in enumerate(starts)}
points={'tcu_fp16':('VX_tcu_top',256,['xil_fmul','xil_fadd']),
        'fpint_32x32':('VX_gemm_unit_top',1024,['xil_f16mul_latency1','xil_f32mul_latency1','xil_f32add_latency1'])}
prepared={}
for name,(top,macs,ips) in points.items():
    src=outputs/'sources'/name
    flist=prepare(top,src,defines)
    corrections=[]
    if name=='tcu_fp16':
        p=src/'VX_tcu_top.sv'
        s=p.read_text()
        assert ') VX_execute_if();' in s and 'VX_result_if #' in s
        s=s.replace(') VX_execute_if();', ') execute_if();')
        p.write_text(s)
        provenance=json.loads((src/'snapshot.json').read_text())
        for item in provenance['sources']:
            if item['snapshot']==str(p):
                item['original_preprocessed_sha256']=item['sha256']
                item['sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
                item['experimental_wrapper_fix']='VX_execute_if instance renamed execute_if'
        (src/'snapshot.json').write_text(json.dumps(provenance,indent=2))
        corrections=['Corrected VX_tcu_top execute_if instance name in experimental snapshot only.']
    out=outputs/name; out.mkdir(exist_ok=True)
    script=out/'ip_setup.tcl'
    script.write_text('''set ip_dir [file normalize [file join [pwd] ip]]
file mkdir $ip_dir
set_property target_language Verilog [current_project]
proc ensure_floating_point_ip {ip_dir module_name} {
    create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name $module_name -dir $ip_dir
}
'''+''.join(blocks[ip] for ip in ips)+'''
set_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
''')
    (out/'manifest.json').write_text(json.dumps(dict(top=top,macs_per_cycle=macs,
        target_clock_mhz=100,part=PART,defines=defines,ips=ips,rtl_root=str(ROOT),
        git_commit=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),
        ip_config_source=str(IP_SOURCE),ip_config_sha256=hashlib.sha256(IP_SOURCE.read_bytes()).hexdigest(),
        wrapper_corrections=corrections,scope='standalone compute unit including local control; GEMM includes internal ACC storage'),indent=2))
    prepared[name]=(top,flist,out,script)

def run(name):
    top,flist,out,script=prepared[name]
    cmd=[VIVADO,'-mode','batch','-source',str(TASK/'synth.tcl'),'-tclargs',top,PART,str(flist),str(out),'']
    env=dict(os.environ,FIG5_IP_TCL=str(script),FIG5_RTL_ROOT=str(ROOT))
    (out/'command.json').write_text(json.dumps(cmd,indent=2))
    start=time.time()
    (out/"status.json").write_text(json.dumps(dict(point=name,success=False,state="running")))
    print('START compute '+name,flush=True)
    with (out/'console.log').open('w') as log:
        rc=subprocess.run(cmd,cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT).returncode
    result=dict(point=name,exit_code=rc,success=rc==0 and (out/'summary.json').exists() and (out/'post_opt.dcp').exists(),elapsed_s=round(time.time()-start,1))
    (out/'status.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result),flush=True)
    return result
if '--prepare-only' in sys.argv:
    print('Compute sources and IP setup prepared; synthesis not started.')
    raise SystemExit(0)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results=list(pool.map(run,points))
(outputs/'status.json').write_text(json.dumps(results,indent=2))
if not all(r['success'] for r in results): raise SystemExit(1)
