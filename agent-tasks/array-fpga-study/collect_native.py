#!/usr/bin/env python3
"""Archive evidence and compute Table VI / Fig.15a from raw FPGA reports."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import subprocess
from datetime import datetime, timezone
from resources import KEYS, add, subtract, hierarchy, select, sha

TASK=Path(__file__).resolve().parent

def save(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(data,indent=2)+'\n')

def breakdown(report):
    rows=hierarchy(report);top=rows[0];engine=select(rows,'gemm_unit')
    children=[c for c in engine['children'] if not c['self']]
    groups=[];used=set()
    rules=[('MXU (PE + weight registers)',lambda n:n=='u_mxu'),
           ('Input scaler',lambda n:n.startswith('gen_in_scaler[')),
           ('Prealignment',lambda n:n in ('u_prealigner','u_prealign_max_exp_pipe','u_pre_proc_pipe_buffer','u_in_pipe')),
           ('Postprocessing',lambda n:n.startswith(('gen_out_scaler[','gen_int2fp[','gen_fp32_to_fp16[')) or n in ('u_act_reduce','u_zp_mul_out_reg')),
           ('FP accumulation',lambda n:n.startswith('gen_accumulator['))]
    for name,predicate in rules:
        chosen=[c for c in children if predicate(c['name'])]
        assert not used.intersection(c['path'] for c in chosen)
        used.update(c['path'] for c in chosen)
        groups.append(dict(component=name,**add(c['counts'] for c in chosen),instances=[dict(path=c['path'],line=c['line']) for c in chosen]))
    groups.append(dict(component='ACC hard memory',**{k:top['counts'][k] if k in ('RAMB36','RAMB18','URAM') else 0 for k in KEYS},instances=[],
                      note='Only RAM primitives; all ACC glue remains in residual. Optimized hierarchy does not retain every bank.'))
    groups.append(dict(component='Control/buffers/ACC glue',**subtract(top['counts'],add(groups)),instances=[],note='Top minus named groups; includes zero-point multiply, bypass, ACC glue, buffers, and attribution residual'))
    assert add(groups)==top['counts']
    return groups

def resolved_ips(point):
    result={}
    for xci in sorted((point/'ip').glob('*/*.xci')):
        data=json.loads(xci.read_text())
        # Vivado 2025.1 JSON XCI: retain all configurable component parameters.
        inst=data['ip_inst']; params=inst['parameters']['component_parameters']
        result[xci.stem]=dict(xci_sha256=sha(xci),parameters={k:v[0]['value'] for k,v in params.items()})
    assert result, point
    return result

def collect(build,baseline,output):
    output.mkdir(parents=True,exist_ok=True)
    native=build/'array_fpga_native'
    compat=json.loads((native/'baseline_compatibility.json').read_text())
    archive=[]
    def copy(src,dst):
        dst=output/dst;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dst)
        archive.append(dict(file=str(dst.relative_to(output)),sha256=sha(dst),original=str(src)))
    table=[];parts={};ips={}
    points=[('fp_tcu_native',baseline/'fig5_fpga_compute/tcu_fp16',256,'FP16 x FP16',0),
            ('woq_derived_native',native/'woq_derived_native',1024,'FP16 x INT4; WoQ subset',256),
            ('wkv_native',baseline/'fig5_fpga_compute/fpint_32x32',1024,'FP16 x INT4; WKV',256)]
    for name,point,macs,precision,acc in points:
        assert json.loads((point/'status.json').read_text())['success'], name
        assert json.loads((point/'summary.json').read_text())['blackboxes']==0
        if name!='woq_derived_native':
            match=next(c for c in compat if c['baseline']==str(point))
            assert sha(point/'hierarchy.rpt')==match['baseline_hierarchy_sha256']
        for f in ('hierarchy.rpt','utilization.rpt','timing_post_opt.rpt','primitives.csv','summary.json','status.json','manifest.json','clock.xdc','ip_setup.tcl'):
            copy(point/f,Path('reports')/name/f)
        if (point/'command.json').exists(): copy(point/'command.json',Path('reports')/name/'command.json')
        counts=hierarchy(point/'hierarchy.rpt')[0]['counts']
        gops=2*macs*100/1000
        table.append(dict(engine=name,precision=precision,MAC_per_cycle=macs,reference_MHz=100,**counts,
            BRAM36eq=counts['RAMB36']+counts['RAMB18']/2,internal_ACC_KiB=acc,
            nominal_GOPS=gops,GOPS_per_kLUT=gops*1000/counts['LUT'],GOPS_per_DSP=gops/counts['DSP']))
        ips[name]=resolved_ips(point)
        if name!='fp_tcu_native':parts[name]=breakdown(point/'hierarchy.rpt')
    # Native matched pair must use identical configurable IP parameters.
    for name,v in ips['wkv_native'].items(): assert v['parameters']==ips['woq_derived_native'][name]['parameters'],name
    for name in ('xil_f16mul_latency1','xil_f32mul_latency1','xil_f32add_latency1'):
        p=ips['woq_derived_native'][name]['parameters']
        assert p['C_Rate']=='1' and p['C_Latency']=='1'
    woq,wkv=table[1:]
    woq_scaler=next(g for g in parts['woq_derived_native'] if g['component']=='Input scaler')
    assert all(woq_scaler[k]==0 for k in KEYS), 'WoQ input scaler survived ablation'
    assert (woq['RAMB36'],woq['RAMB18'],woq['URAM'])==(wkv['RAMB36'],wkv['RAMB18'],wkv['URAM']), 'ACC mapping differs'
    delta={k:wkv[k]-woq[k] for k in (*KEYS,'BRAM36eq')}
    pct={k:100*delta[k]/woq[k] if woq[k] else None for k in delta}
    scaler=next(g for g in parts['wkv_native'] if g['component']=='Input scaler')
    overhead=dict(WKV_minus_WoQ=delta,percent_over_WoQ=pct,
        input_scaler_counts={k:scaler[k] for k in KEYS},
        input_scaler_percent_of_WKV={k:100*scaler[k]/wkv[k] if wkv[k] else None for k in KEYS})
    copy(native/'woq_derived_native/console.log',Path('reports/woq_derived_native/console.log'))
    copy(native/'woq_derived_native/project/fig5_ooc.runs/synth_1/runme.log',Path('reports/woq_derived_native/synthesis.log'))
    copy(native/'woq_derived_native/verification_gate.json',Path('provenance/verification_gate.json'))
    verified=json.loads((build/'array_fpga_test/test_manifest.json').read_text())
    verified_hashes={Path(k).name:v for k,v in verified['source_hashes'].items()}
    synthesis_files=(native/'sources/woq_derived_native/sources.txt').read_text().splitlines()
    assert all(verified_hashes[Path(p).name]==sha(p) for p in synthesis_files)
    save(output/'verification/source_match.json',dict(status='pass',files=len(synthesis_files),
        source_hashes={Path(p).name:sha(p) for p in synthesis_files}))
    copy(native/'baseline_compatibility.json',Path('provenance/baseline_compatibility.json'))
    copy(native/'sources/woq_derived_native/ablation.json',Path('provenance/ablation.json'))
    for name in ('fpint_32x32','tcu_fp16'):
        copy(native/'sources'/name/'snapshot.json',Path('provenance')/(name+'_snapshot.json'))
    for src,dst in [('array_fpga_test/verification.json','verification/rtl.json'),('array_fpga_test/test_manifest.json','verification/test_manifest.json'),('array_fpga_test/logs/sim.log','verification/rtl_sim.log'),('array_fpga_test/logs/compile.log','verification/rtl_compile.log'),('vendor_ip_check/result.json','verification/vendor_ip.json'),('vendor_ip_check/console.log','verification/vendor_ip.log')]:copy(build/src,Path(dst))
    save(output/'ip_parameters.json',ips)
    save(output/'engine_resources.json',table);save(output/'engine_breakdown.json',parts);save(output/'overhead.json',overhead)
    with (output/'engine_breakdown.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=['engine','component',*KEYS],lineterminator='\n',extrasaction='ignore');writer.writeheader()
        for engine,groups in parts.items():
            for group in groups:writer.writerow(dict(engine=engine,**group))
    with (output/'overhead.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=['resource','WoQ','WKV','delta','percent_over_WoQ','input_scaler','scaler_percent_of_WKV'],lineterminator='\n');writer.writeheader()
        for key in KEYS:writer.writerow(dict(resource=key,WoQ=woq[key],WKV=wkv[key],delta=delta[key],percent_over_WoQ=pct[key],input_scaler=scaler[key],scaler_percent_of_WKV=overhead['input_scaler_percent_of_WKV'][key]))
    dsp=build/'dsp_attribution/wkv_native.csv'
    if dsp.exists():
        dsp_rows=list(csv.DictReader(dsp.open()))
        assert len(dsp_rows)==wkv['DSP']
        copy(dsp,Path('reports/wkv_native/dsp_cells.csv'))
        groups={}
        for r in dsp_rows:
            cell=r['cell']
            label=('MXU' if '/u_mxu/' in cell else 'Input scaler' if '/gen_in_scaler[' in cell else
                   'Output scaler' if '/gen_out_scaler[' in cell else 'Activation reduction' if '/u_act_reduce/' in cell else 'Direct GEMM arithmetic')
            key=(label,r['USE_MULT'],r['USE_SIMD']);groups[key]=groups.get(key,0)+1
        save(output/'dsp_attribution.json',[dict(component=k[0],USE_MULT=k[1],USE_SIMD=k[2],count=v) for k,v in sorted(groups.items())])
    repo=TASK.parents[1]
    scripts=[p for p in TASK.rglob('*') if p.suffix in ('.py','.tcl','.sv') and 'results' not in p.parts and '__pycache__' not in p.parts]
    scripts += [repo/'configs/array_fpga_native.sh',repo/'configs/fig5_fpga_compute.sh',repo/'hw/scripts/xilinx_ip_gen.tcl',repo/'hw/scripts/xilinx_async_bram_patch.tcl']
    scripts += [TASK.parent/'fig5-fpga'/n for n in ('run.py','synth.tcl','report.tcl')]
    save(output/'study_metadata.json',dict(created_utc=datetime.now(timezone.utc).isoformat(),
        git_head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),
        artifact_scope='native OOC synthesis resource comparison plus separate historical C4 post-route attribution',
        checkpoint_sha256={name:sha(point/'post_opt.dcp') for name,point,*_ in points},
        historical_command_available={name:(point/'command.json').exists() for name,point,*_ in points},
        script_sha256={str(p.relative_to(repo)):sha(p) for p in scripts},
        frequency='100 MHz reference only; no post-route Fmax or achieved throughput',
        functional_limitations=json.loads((build/'array_fpga_test/test_manifest.json').read_text())['limitations']))
    save(output/'archive.json',archive)
    with (output/'engine_resources.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=table[0],lineterminator='\n');w.writeheader();w.writerows(table)
    print(json.dumps(dict(table=table,overhead=overhead),indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--build',type=Path,required=True);p.add_argument('--baseline-build',type=Path,required=True);p.add_argument('--output',type=Path,default=TASK/'results')
    a=p.parse_args();collect(a.build.resolve(),a.baseline_build.resolve(),a.output.resolve())
