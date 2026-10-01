#!/usr/bin/env python3
"""Prepare/run the smaller native-mapping study using the archived Fig.5 flow."""
import argparse, concurrent.futures, hashlib, importlib.util, json, os, re, shlex, subprocess, sys, time
from pathlib import Path
TASK=Path(__file__).resolve().parent
OLD=TASK.parent/'fig5-fpga'
ARRAY=TASK.parent/'array-fpga-study'
spec=importlib.util.spec_from_file_location('fig5_run',OLD/'run.py')
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
sys.path.insert(0,str(ARRAY))
from prepare_woq import derive_woq

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def save(path,x):path.write_text(json.dumps(x,indent=2)+'\n')
def ip_setup(out,names):
    text=(f.ROOT/'hw/scripts/xilinx_ip_gen.tcl').read_text()
    starts=list(re.finditer(r'^ensure_floating_point_ip \$\{ip_dir\} (\w+)\s*$',text,re.M))
    blocks={m[1]:text[m.start():starts[i+1].start() if i+1<len(starts) else text.index('generate_target all')] for i,m in enumerate(starts)}
    p=out/'ip_setup.tcl'
    p.write_text('''set ip_dir [file normalize [file join [pwd] ip]]
file mkdir $ip_dir
set_property target_language Verilog [current_project]
proc ensure_floating_point_ip {ip_dir module_name} {
    create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name $module_name -dir $ip_dir
}
'''+''.join(blocks[n] for n in names)+'''\nset_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
''')
    return p

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--kind',choices=['compute','memory'],required=True)
    p.add_argument('--points',nargs='+');p.add_argument('--prepare-only',action='store_true')
    p.add_argument('--parallel',type=int,default=2)
    a=p.parse_args();build=Path.cwd().resolve()
    assert (build/'config.mk').exists(), 'Use configured build directory'
    edits=json.loads((build/'rtl_edits.json').read_text())
    assert f.ROOT==build.parent, 'FIG5_RTL_ROOT must select the experiment checkout'
    for x in edits['changes']:assert sha(f.ROOT/x['file'])==x['after_sha256']
    defs=shlex.split(os.environ['CONFIGS']);assert '-DVIVADO' in defs
    outroot=build/'mxu16_fpga';outroot.mkdir(exist_ok=True)
    if a.kind=='compute':
        assert all(x in defs for x in ['-DNUM_THREADS=16','-DMXU_COL_TILE=16','-DGEMM_ACC_MEM_DEPTH=1024'])
        points={'fp_tcu_64':('VX_tcu_top',{},64,['xil_fmul','xil_fadd']),
                'wkv_16x16':('VX_gemm_unit_top',{},256,['xil_f16mul_latency1','xil_f32mul_latency1','xil_f32add_latency1']),
                'woq_16x16':('VX_gemm_unit_woq_top',{},256,['xil_f16mul_latency1','xil_f32mul_latency1','xil_f32add_latency1'])}
    else:
        assert '-DNUM_THREADS=8' in defs and '-DLMEM_USE_URAM=0' in defs, 'Source fig5_fpga_memory.sh'
        points={}
        for n in (8,32):points[f'lmem_{n}']=('VX_local_mem_top',dict(NUM_REQS=n,NUM_BANKS=n,SIZE=524288,WORD_SIZE=8,TAG_WIDTH=16),0,[])
        for n in (1,4):points[f'cache_{n}']=('VX_cache_top',dict(NUM_REQS=n,NUM_BANKS=n,MEM_PORTS=n,CACHE_SIZE=4194304,LINE_SIZE=64,WORD_SIZE=16,NUM_WAYS=4,MSHR_SIZE=16,TAG_WIDTH=32,WRITEBACK=1,DIRTY_BYTES=0),0,[])
        for n in (1,4):points[f'axi_{n}']=('VX_axi_adapter',dict(NUM_PORTS_IN=n,NUM_BANKS_OUT=32,DATA_WIDTH=512,ADDR_WIDTH_IN=26,ADDR_WIDTH_OUT=32,TAG_WIDTH_IN=16,TAG_WIDTH_OUT=16),0,[])
    selected=a.points or list(points);assert set(selected)<=points.keys()
    prepared={}
    for name in selected:
        top,generics,macs,ips=points[name]
        out=outroot/name;out.mkdir(exist_ok=True)
        assert not (out/'post_opt.dcp').exists(), 'Use a fresh build; refusing to overwrite measured result'
        src=outroot/'sources'/name
        if name=='woq_16x16':
            base=outroot/'sources/wkv_16x16/sources.txt';assert base.exists(), 'Prepare WKV first'
            flist=derive_woq(base,src)
        else:
            flist=f.prepare(top,src,defs)
            if name=='fp_tcu_64':
                q=src/'VX_tcu_top.sv';s=q.read_text();assert s.count(') VX_execute_if();')==1
                q.write_text(s.replace(') VX_execute_if();',') execute_if();'))
                snapshot=json.loads((src/'snapshot.json').read_text())
                for row in snapshot['sources']:
                    if Path(row['snapshot'])==q:
                        row['before_wrapper_fix_sha256']=row['sha256'];row['sha256']=sha(q)
                        row['fix']='TCU execute_if instance rename, same as original study'
                save(src/'snapshot.json',snapshot)
        setup=ip_setup(out,ips) if ips else None
        manifest=dict(top=top,point=name,part=f.PART,reference_MHz=100,MAC_per_cycle=macs,
            dimensions=dict(TCU_M=4,TCU_N=4,TCU_K_packed=2,TCU_FP16_per_word=2,MXU_ROW=16,MXU_COL=16),
            internal_ACC_KiB=256 if '16x16' in name else 0,
            defines=defs,generics=generics,rtl_edits=edits,rtl_root=str(f.ROOT),
            sources={str(x):sha(x) for x in map(Path,flist.read_text().splitlines())},
            ip_source_sha256=sha(f.ROOT/'hw/scripts/xilinx_ip_gen.tcl'),
            scope='OOC synthesis + production async-RAM patch + opt_design; reference peak, not Fmax')
        save(out/'manifest.json',manifest)
        prepared[name]=(top,generics,out,flist,setup)
    if a.prepare_only:return
    if 'woq_16x16' in selected:
        v=json.loads((build/'array_fpga_test/verification.json').read_text());assert v['status']=='pass'
        vendor=json.loads((build/'vendor_ip_check/result.json').read_text())
        assert vendor['status']=='pass' and vendor['measured_handshake_latency']==1
        test=json.loads((build/'array_fpga_test/test_manifest.json').read_text())
        hashes={Path(k).name:h for k,h in test['source_hashes'].items()}
        for path in prepared['woq_16x16'][3].read_text().splitlines():assert hashes[Path(path).name]==sha(path)
        save(prepared['woq_16x16'][2]/'verification_gate.json',dict(status='pass',verification=v,vendor_ip=vendor,source_match=True))
    def launch(name):
        top,generics,out,flist,setup=prepared[name]
        cmd=[f.VIVADO,'-mode','batch','-source',str(OLD/'synth.tcl'),'-tclargs',top,f.PART,str(flist),str(out),' '.join(f'{k}={v}' for k,v in generics.items())]
        env=dict(os.environ,FIG5_RTL_ROOT=str(f.ROOT))
        if setup:env['FIG5_IP_TCL']=str(setup)
        save(out/'command.json',cmd);save(out/'status.json',dict(state='running',success=False))
        print('START '+name,flush=True);start=time.time()
        with (out/'console.log').open('w') as log:rc=subprocess.run(cmd,cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT).returncode
        status=dict(point=name,success=rc==0 and (out/'post_opt.dcp').exists() and (out/'summary.json').exists(),exit_code=rc,elapsed_s=round(time.time()-start,1))
        save(out/'status.json',status);print(json.dumps(status),flush=True);return status
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.parallel) as pool:results=list(pool.map(launch,selected))
    if not all(x['success'] for x in results):raise SystemExit(1)
if __name__=='__main__':main()
