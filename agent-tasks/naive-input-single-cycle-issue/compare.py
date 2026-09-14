"""Collect fixed-workload before/after cycles and update the cycle-only document."""
from pathlib import Path
import json
import shlex

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[1]
rows = []
for m in (4,256):
    case = f'm{m}'
    oldrun = ROOT/f'agent-tasks/naive-psum-read-priority/runs/v2/r1-{case}'
    newrun = TASK/'runs/v1'/case
    impath = ROOT/f'agent-tasks/dma-read-slot-saturation/captures/improve16-{case}/result.json'
    old = json.loads((oldrun/'result.json').read_text())
    new = json.loads((newrun/'result.json').read_text())
    om = json.loads((oldrun/'manifest.json').read_text())
    nm = json.loads((newrun/'manifest.json').read_text())
    assert old['passed'] and new['passed']
    assert shlex.split(om['configs'])==shlex.split(nm['configs'])
    assert om['app_args']==nm['app_args']
    analysis = json.loads((TASK/(case+'-analysis.json')).read_text())
    assert analysis['handshake_checks']=='pass'
    improve = json.loads(impath.read_text())
    ig = improve['gemm_cycles']
    ic = {4:12205,256:278622}[m]
    bg, ng = old['gemm_cycles'][0],new['gemm_cycles'][0]
    bc, nc = old['core_cycles'][0],new['core_cycles'][0]
    rows.append(dict(m=m,before_gemm=bg,after_gemm=ng,improve_gemm=ig,
                     delta_gemm=ng-bg,change_percent=100*(ng-bg)/bg,
                     before_core=bc,after_core=nc,improve_core=ic,
                     naive_over_improve=ng/ig,gemm_gap=ng-ig,
                     phases=analysis['phases']))
(TASK/'comparison.json').write_text(json.dumps(rows,indent=2)+'\n')
doc = '# FPINT GEMM cycle 비교: improve vs naive\n\n'
doc += '현재 RTL 기준, `xrt-vcs-sim`, TH16 / MXU16×16, K=N=512, micro-tile N-fast.\n'
doc += '외부 DMA read slot: improve 채널당 16개, naive 32개. Weight response slot은 양쪽 모두 8개, naive PSUM read/response slot은 16개. Naive는 PSUM read 우선 정책(R=1)과 Input DMA 연속 요청 발행을 사용한다.\n\n'
doc += '## GEMM cycles\n\n| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |\n|---:|---:|---:|---:|---:|---:|\n'
for r in rows:
    i,n=r['improve_gemm'],r['after_gemm']
    doc += f"| {r['m']} | {i:,} | {n:,} | {n-i:,} | {n/i:.3f}× | {100*(n-i)/n:.2f}% |\n"
doc += '\nGEMM cycles는 configuration 수락부터 최초 completion-valid까지의 구간이다.\n\n## 전체 커널 core cycles\n\n| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |\n|---:|---:|---:|---:|---:|---:|\n'
for r in rows:
    i,n=r['improve_core'],r['after_core']
    doc += f"| {r['m']} | {i:,} | {n:,} | {n-i:,} | {n/i:.3f}× | {100*(n-i)/n:.2f}% |\n"
doc += '\n감소율 = `(naive − improve) / naive × 100`.\n'
(ROOT/'docs/hw_analysis/improve_vs_naive/fpint_gemm_latency.md').write_text(doc)
print(json.dumps(rows,indent=2))
