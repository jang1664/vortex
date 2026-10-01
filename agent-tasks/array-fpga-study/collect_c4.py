#!/usr/bin/env python3
"""Non-overlapping C4 routed resource accounting; never mix with OOC totals."""
import argparse
import csv
import json
from pathlib import Path
import shutil
from resources import KEYS, add, subtract, hierarchy, select, sha

DEFAULT = Path('/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin')

def collect(source, output):
    output.mkdir(parents=True,exist_ok=True)
    raw=output/'reports/c4'; raw.mkdir(parents=True,exist_ok=True)
    provenance=[]
    for name in ('hier_utilization.rpt','impl_1_full_util_routed.rpt'):
        src=source/name; dst=raw/name
        if src.resolve()!=dst.resolve(): shutil.copyfile(src,dst)
        provenance.append(dict(original=str(src),archived=str(dst.relative_to(output)),sha256=sha(dst)))
    rows=hierarchy(raw/'hier_utilization.rpt')
    afu=select(rows,'vortex_afu_1'); core=select(rows,'g_cores[0].core')
    gemm=select(rows,'u_VX_gemm_unit'); node=select(rows,'gemm_node')
    mem=select(rows,'mem_unit'); lmem=select(rows,'local_mem'); tmem=select(rows,'u_tmem_subsystem')
    groups=[]
    def group(name,counts,basis):
        assert all(counts[k]>=0 for k in KEYS)
        groups.append(dict(component=name,**counts,BRAM36eq=counts['RAMB36']+counts['RAMB18']/2,basis=basis))
    def selected(name):
        n=select(rows,name);return n['counts'],[dict(path=n['path'],line=n['line'])]
    group('SIMT pipeline',subtract(core['counts'],add([node['counts'],mem['counts']])),
        ['core minus gemm_node minus mem_unit; includes instruction register files'])
    for label,name in [('LMEM','local_mem'),('D-cache','dcache'),('I-cache','icache')]:
        c,b=selected(name);group(label,c,b)
    group('Core memory interconnect',subtract(mem['counts'],lmem['counts']),['mem_unit minus local_mem'])
    # All 60 GEMM URAMs implement ACC; optimizing hierarchy has moved one bank.
    # Split hard memory only, leaving *all* ACC glue/control in the logic group.
    acc={k:gemm['counts'][k] if k in ('RAMB36','RAMB18','URAM') else 0 for k in KEYS}
    group('ACC hard memory',acc,['GEMM RAM primitives only; glue logic remains in GEMM logic'])
    group('GEMM logic + ACC glue',subtract(gemm['counts'],acc),[dict(path=gemm['path'],line=gemm['line'])])
    banks=[c for c in tmem['children'] if c['name'].startswith('g_bank[')]
    assert len(banks)==8
    bankcounts=add(c['counts'] for c in banks)
    group('TMEM banks',bankcounts,[dict(path=c['path'],line=c['line']) for c in banks])
    dma=[c for c in tmem['children'] if c['name']=='u_dma_engine' or c['name'].startswith('u_ldma_')]
    assert len(dma)==5
    dmacounts=add(c['counts'] for c in dma)
    group('Tensor DMA engines',dmacounts,[dict(path=c['path'],line=c['line']) for c in dma])
    group('TMEM switches/control',subtract(tmem['counts'],add([bankcounts,dmacounts])),['u_tmem_subsystem minus banks and five DMA engine subtrees'])
    group('GEMM/DMA control + frontend',subtract(node['counts'],add([gemm['counts'],tmem['counts']])),
          ['gemm_node minus GEMM unit and TMEM subsystem; includes any hierarchy accounting difference'])
    group('AFU/AXI/cluster residual',subtract(afu['counts'],add(groups)),['vortex_afu_1 minus all listed non-overlapping groups'])
    assert add(groups)==afu['counts']
    shell=subtract(rows[0]['counts'],afu['counts'])
    for g in groups:
        g['percent_of_accelerator']={k:100*g[k]/afu['counts'][k] if afu['counts'][k] else None for k in KEYS}
    data=dict(scope='historical C4, Physopt postRoute, accelerator=vortex_afu_1',
        part='xcu55c-fsvh2892-2L-e',vivado='2025.1',source_binary_dir=str(source),reports=provenance,
        accelerator=afu['counts'],device_design_total=rows[0]['counts'],shell_and_other=shell,groups=groups,
        caveats=[
            'This historical C4 build uses 60 ACC URAMs; OOC matched WoQ/WKV use BRAM. Do not combine totals.',
            'Counts only: ignore report percentages with mixed PR-region denominators.',
            'ACC hard memory excludes all LUT/FF glue; GEMM logic + ACC glue retains it.',
            'Hierarchy optimization moves logic between scopes. Components are attribution, not removal costs.',
            'gemm_node immediate-child LUT counts exceed parent by 2; parent-minus-selected-children keeps accounting exact without asserting a cause.',
            'No Fmax, power, or deployed throughput is inferred from these counts.'])
    (output/'c4_resources.json').write_text(json.dumps(data,indent=2)+'\n')
    with (output/'c4_resources.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=['component',*KEYS,'BRAM36eq'],lineterminator='\n',extrasaction='ignore');w.writeheader();w.writerows(groups)
    print(json.dumps(dict(accelerator=afu['counts'],shell_and_other=shell,groups=len(groups),verified_sum=True)))
    return data

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,default=DEFAULT);p.add_argument('--output',type=Path,default=Path(__file__).parent/'results')
    a=p.parse_args();collect(a.source,a.output)
