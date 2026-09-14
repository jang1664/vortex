"""Publish cycle-only tables after all frozen matrix results pass."""
from pathlib import Path
import json
TASK=Path(__file__).resolve().parent
ROOT=TASK.parents[1]
TOPOLOGIES=['p16_b16','p32_b16','p16_b32','p32_b32']
results={}
for t in TOPOLOGIES:
    results[t]={}
    for case in ['m4','m256']:
        r=json.loads((TASK/'runs/v2'/t/case/'result.json').read_text())
        assert r['passed'] and not r['source_changes'] and r['config_unchanged']
        results[t][case]={k:r[k][0] for k in ['gemm_cycles','core_cycles']}
baseline=json.loads((TASK/'baseline.json').read_text())
improve={}
for case in ['m4','m256']:
    r=json.loads((TASK/'runs/v3/improve'/case/'result.json').read_text())
    assert r['passed'] and r['zero_cycle_delta'] and not r['source_changes']
    improve[case]={k:r[k][0] for k in ['gemm_cycles','core_cycles']}
    assert improve[case]['gemm_cycles']==baseline['improve_gemm'][case]
    assert improve[case]['core_cycles']==baseline['improve_core'][case]
summary={'matrix':results,'improve':improve}
for case in ['m4','m256']:
    a=results['p16_b16'][case]['gemm_cycles'];b=results['p32_b32'][case]['gemm_cycles']
    summary.setdefault('naive_reduction',{})[case]={'cycles':a-b,'percent':100*(a-b)/a,'speedup':a/b}
(TASK/'comparison.json').write_text(json.dumps(summary,indent=2)+'\n')
text='# FPINT GEMM cycles: improve vs naive\n\nCurrent RTL, xrt-vcs-sim, TH16 / MXU16x16, K=N=512, micro-tile N-fast. Naive uses continuous Input issue and PSUM read quota=1. Weight response slots: 8 on both backends; naive PSUM read/response slots: 16. External DMA read slots: naive 32, improve 16 per channel. Naive LMEM total capacity: 1 MiB.\n\n## Naive LMEM port/bank matrix\n\n| Ports / banks | M4 GEMM | M256 GEMM | M4 core | M256 core |\n|---|---:|---:|---:|---:|\n'
for t in TOPOLOGIES:
    r=results[t];label=t.replace('p','').replace('_b',' / ')
    text+=f"| {label} | {r['m4']['gemm_cycles']:,} | {r['m256']['gemm_cycles']:,} | {r['m4']['core_cycles']:,} | {r['m256']['core_cycles']:,} |\n"
for key,title in [('gemm_cycles','GEMM cycles'),('core_cycles','Kernel core cycles')]:
    text+=f"\n## {title}: improve vs naive 32-port/32-bank\n\n| M | Improve | Naive 32/32 | Naive - improve | Naive / improve | Improve cycle reduction |\n|---:|---:|---:|---:|---:|---:|\n"
    for case,m in [('m4',4),('m256',256)]:
        i=summary['improve'][case][key];n=results['p32_b32'][case][key]
        text+=f"| {m} | {i:,} | {n:,} | {n-i:,} | {n/i:.3f}x | {100*(n-i)/n:.2f}% |\n"
text+='\nGEMM cycles: configuration acceptance to first completion-valid. Reduction = (naive - improve) / naive.\n'
(ROOT/'docs/hw_analysis/improve_vs_naive/fpint_gemm_latency.md').write_text(text)
print(json.dumps(summary,indent=2))
