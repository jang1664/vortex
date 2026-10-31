#!/usr/bin/env python3
import datetime,json,subprocess,sys
from pathlib import Path
r=Path(__file__).resolve().parent
repo=r.parents[3]
build=repo/'build_c4_unified_mmio_hw'
alias='improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_unified_mmio_r1'
cases=[
 ('mmio_serialization','mmio_serialization',''),
 ('sram_early_return','sram_early_return',''),
 ('fp32_multitile','flash_attn','-r -f -m 4 -n 256'),
 ('fp16_multitile','flash_attn','-r -m 4 -n 256'),
 ('legacy_single','flash_attn','-m 4 -n 128'),
 ('fp32_tail','flash_attn','-r -f -m 16 -n 257'),
 ('fp32_mask','flash_attn','-r -f -m 16 -n 384 -c -p 0'),
 ('fp32_pv_overflow','flash_attn','-r -f -m 1 -n 128 -s pv-overflow'),
 ('fp32_qk_overflow','flash_attn','-r -f -m 1 -n 128 -s qk-overflow'),
]
rows=[]
for name,app,args in cases:
    cmd=['timeout','--signal=TERM','--kill-after=30s','300','./ci/run_black.sh','hw','--fpga-bin',alias,'--app',app,'--args',args]
    start=datetime.datetime.now().astimezone().isoformat()
    print(start,'START',name,flush=True)
    with (r/(name+'.log')).open('w') as f:
        result=subprocess.run(cmd,cwd=build,stdout=f,stderr=subprocess.STDOUT)
    log=(r/(name+'.log')).read_text(errors='replace')
    passed=result.returncode==0 and 'PASSED' in log.splitlines()
    row={'name':name,'app':app,'args':args,'command':cmd,'started':start,'finished':datetime.datetime.now().astimezone().isoformat(),'exit_code':result.returncode,'passed':passed,'log':str(r/(name+'.log'))}
    rows.append(row)
    (r/'results.json').write_text(json.dumps({'alias':alias,'cases':rows},indent=2)+'\n')
    print(row['finished'],name,'PASS' if passed else 'FAIL','exit',result.returncode,flush=True)
    for line in log.splitlines():
        if any(s in line for s in ['MMIO_SERIALIZATION','SRAM_EARLY_RETURN','max_abs','max_rel','attention_cycles','cycles=','PASSED','FAILED','ERROR:']): print(line[:700],flush=True)
    if not passed:
        print('LAST LOG LINES:',*log.splitlines()[-15:],sep='\n',flush=True)
        sys.exit(result.returncode or 1)
print('ALL 9 HARDWARE CASES PASSED',flush=True)
