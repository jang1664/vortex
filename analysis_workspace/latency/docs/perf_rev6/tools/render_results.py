#!/usr/bin/env python3
"""Render measured tables and publication/export friendly static figures."""
import json,re
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
OUT=Path(__file__).resolve().parents[1]
DOC=OUT.parent/'c3_c4_rev6_fine_grained_analysis.md'
rows=json.loads((OUT/'measurements.json').read_text())
by={r['key']:r for r in rows}
order=['small','llama3_kv_decode','llama3_attention_decode','llama2_ffn_decode']
rows=sorted(rows,key=lambda r:(order.index(r['case']['id']),r['candidate']))
def fmt(v):return f'{v:,.3f}' if isinstance(v,float) else f'{v:,}'
def table(headers,body):
    return '| '+' | '.join(headers)+' |\n| '+' | '.join(['---']*len(headers))+' |\n'+''.join('| '+' | '.join(str(x) for x in line)+' |\n' for line in body)+'\n'
def ratio(a,b):return a/b if b else 0.0
s='## 측정 결과\n\n'
s+=table(['case','backend','GEMM cycles','GEMM µs','core µs','input %','pipeline %','유효 GFLOP/s'],[[r['case']['id'],r['candidate'].upper(),fmt(r['gemm_cycles']),fmt(r['gemm_us']),fmt(r['core_us']),fmt(r['input_util_pct']),fmt(r['pipeline_util_pct']),fmt(r['useful_gflops'])] for r in rows])
s+='모든 수치는 reference 검증에 통과한 실행만 포함한다. input %와 nominal 유효 peak %는 N/K가 16의 배수이면 같다. ragged attention에서는 padding 때문에 유효 peak %가 조금 더 낮다.\n\n'
s+='### Weight 공급을 고려한 MXU 해석\n\n'
body=[]
for r in rows:
    mx=r['raw']['gemm_unit'][0]
    bound=max(mx['input_fire'],mx['weight_fire'])
    body.append([r['key'],fmt(mx['input_fire']),fmt(mx['weight_fire']),fmt(100*ratio(mx['weight_fire'],r['gemm_cycles'])),fmt(bound),fmt(ratio(r['useful_flops']*r['logic_hz'],bound)/1e9),fmt(100*ratio(bound,r['gemm_cycles']))])
s+=table(['case/backend','input fire','weight beat','weight beat / cycles %','낙관적 cycle 하한','그 하한의 유효 GFLOP/s','실측 / 하한 throughput %'],body)
s+='weight bus는 `GEMM_WEIGHT_DATA_SIZE=(COL×WLOAD_NUM×4)/8=32 B`이고, 한 16×16 int4 weight tile=128 B를 4 beats로 적재한다. 한 interface에서 cycle당 한 beat만 수락할 수 있으므로 관측한 input/weight beat 수의 최댓값은 해당 작업량의 낙관적 cycle 하한이다. 이 하한은 DMA·quantization·accumulator·파이프라인 의존성이 모두 이상적으로 겹친다고 가정하며 실제 도달 가능한 성능을 보장하지 않는다. M=1 projection에서는 weight beat가 input fire의 4배라 nominal compute peak 51.2 GFLOP/s보다 낮은 12.8 GFLOP/s의 weight 공급 상한이 먼저 생긴다. C4 K/V의 input 14.04%를 이것과 구별하면 weight 공급 하한 대비 throughput은 56.15%다. M이 커져 같은 weight를 여러 row에 재사용할 수 있으면 이 제약은 완화된다.\n\n'
s+='### HBM AXI bandwidth\n\n'
s+=table(['case/backend','core avg GB/s','GEMM avg GB/s','GEMM window min','max','mean','median','window 수'],[[r['key'],fmt(r['hbm_core_gbps']),fmt(r['hbm_gemm_gbps']),*[fmt(r['gemm_windows'].get(k,0.0)) if r['gemm_windows'] else 'N/A' for k in ['min','max','avg','median']],r['gemm_windows'].get('count',0)] for r in rows])
s+='small은 GEMM 길이가 1,024 cycles 미만이라 GEMM window min/max를 제공할 수 없다. core 구간의 window 통계, tail 및 port별 read/write/backpressure는 measurements.json에 있다. 동일 길이 window mean과 tail 포함 전체 평균은 다를 수 있다.\n\n'
s+=table(['case/backend','core AXI read B','core AXI write B','GEMM AXI read B','GEMM AXI write B','useful FLOPs / core AXI B'],[[r['key'],fmt(r['hbm_core_rd_bytes']),fmt(r['hbm_core_wr_bytes']),fmt(r['hbm_gemm_rd_bytes']),fmt(r['hbm_gemm_wr_bytes']),fmt(ratio(r['useful_flops'],r['hbm_core_rd_bytes']+r['hbm_core_wr_bytes']))] for r in rows])
s+='### 전체 core 구간 window 및 port 분포\n\n'
s+=table(['case/backend','core window min GB/s','max','mean','zero %','port avg min GB/s','max','mean'],[[r['key'],*[fmt(r['core_windows'][k]) for k in ['min','max','avg','zero_pct']],*[fmt(fn([(p['rd_bytes']+p['wr_bytes'])*r['logic_hz']/r['core_cycles']/1e9 for p in r['raw']['AXI_PORT']])) for fn in [min,max,lambda v:sum(v)/len(v)]]] for r in rows])
s+='port avg는 각 port의 전체 core 구간 평균이며, 시간 window 통계와 구별된다. small에서 port 3의 traffic이 상대적으로 큰 것은 instruction/descriptor/profiling traffic이 함께 들어가는 관찰 경계와 부합한다. 실제 projection에서는 read traffic이 4 ports에 훨씬 균등하게 분산된다.\n\n'
s+='### Local memory 활동과 bank conflict\n\n'
local=[]
for r in rows:
    mem=r['lmem_physical'] if r['candidate']=='c3' else r['tmem']
    time=r['core_cycles']/r['logic_hz']
    conflict=r['lmem_perf']['bank_stalls'] if r['candidate']=='c3' else mem['collision_denied']
    local.append([r['key'],'LMEM' if r['candidate']=='c3' else 'TMEM',fmt(mem['rd_bytes']),fmt(mem['wr_bytes']),fmt((mem['rd_bytes']+mem['wr_bytes'])/time/1e9),fmt(conflict),fmt(r['lmem_perf']['crsp_stalls']) if r['candidate']=='c3' else fmt(mem['blocked'])])
s+=table(['case/backend','memory','physical read B','physical write B','read+write / core time GB/s','collision event','response stall / blocked'],local)
s+='C3의 collision event는 기존 LMEM bank_stalls이고 마지막 열은 response stall이다. C4의 collision event는 관찰 모듈의 denied requester이며 마지막 열은 모든 blocked requester-cycle이다. 단위와 지점이 다르므로 backend간 collision 숫자를 직접 비율 비교하지 않는다. TMEM per-bank 통계는 raw simv.log와 measurements.json에 있다. C3의 비활성 HBM-DMA/LDMA 카운터 0은 LMEM 직접 경로의 bandwidth가 0이라는 뜻이 아니다.\n\n'
s+='### DMA 단계별 bandwidth와 중첩\n\n'
body=[]
for r in rows:
    core=r['raw']['core'][0]
    body.append([r['key'],fmt(core['dma_union_active_cycles']),fmt(core['overlap_dma_mxu']),fmt(100*ratio(core['overlap_dma_mxu'],core['dma_union_active_cycles']))])
s+=table(['case/backend','DMA union cycles','DMA ∩ pipeline cycles','overlap / DMA union %'],body)
body=[]
for r in rows:
    groups=['cpu_dma'] if r['candidate']=='c3' else ['hbm_dma.aggregate','lmem_dma_input','lmem_dma_weight','lmem_dma_sz','lmem_dma_output']
    for name in groups:
        d=r['raw'][name][0]; hz=r['logic_hz']
        body.append([r['key'],name,fmt(d['rd_bytes']),fmt(d['wr_bytes']),fmt(d['active_cycles']),fmt(ratio(d['rd_bytes']*hz,d['active_cycles'])/1e9),fmt(d['src_rd_req_stall']),fmt(d['dst_wr_stall'])])
s+=table(['case/backend','DMA','rd B','wr B','active cycle sum','rd / active GB/s','src request stall','dst write stall'],body)
s+='rd/active는 엔진·채널 activity의 합으로 나눈 endpoint 평균이며 HBM 전체 wall-clock bandwidth가 아니다. `lmem_dma_sz`는 scale DMA와 zero-point DMA 두 엔진의 **합**이다. 두 엔진이 동시에 활동하므로 active_cycles가 GEMM/core cycles보다 커질 수 있다. HBM-DMA 역시 4-channel active sum이고 runtime의 “8-channel” 문자열은 고정된 표시다. 실제 channel/port 수는 manifest의 4를 따른다.\n\n'
s+='## 분석\n\n'
for case in ['llama3_kv_decode','llama2_ffn_decode']:
    a=by.get('c3_'+case);b=by.get('c4_'+case)
    if not a or not b:continue
    ac=a['raw']['core'][0];bc=b['raw']['core'][0]
    s+=f"### {case}\n\nC4는 C3 대비 GEMM 구간 {a['gemm_cycles']/b['gemm_cycles']:.3f}배, 전체 core 구간 {a['core_cycles']/b['core_cycles']:.3f}배 빠르다. 유효 throughput은 {a['useful_gflops']:.3f} → {b['useful_gflops']:.3f} GFLOP/s, MXU input utilization은 {a['input_util_pct']:.3f}% → {b['input_util_pct']:.3f}%다. 두 backend의 input fire는 각각 {a['input_fire']:,}/{b['input_fire']:,}로 유효 연산량 차이에 의한 속도 차이가 아니다.\n\n"
    s+=f"전체 core AXI traffic은 C3 {(a['hbm_core_rd_bytes']+a['hbm_core_wr_bytes'])/1e6:.3f} MB, C4 {(b['hbm_core_rd_bytes']+b['hbm_core_wr_bytes'])/1e6:.3f} MB다. C4의 이점은 주로 비슷한 데이터량을 더 짧은 시간에 처리하는 데 있다. GEMM window bandwidth 범위는 C3 {a['gemm_windows']['min']:.3f}–{a['gemm_windows']['max']:.3f}, C4 {b['gemm_windows']['min']:.3f}–{b['gemm_windows']['max']:.3f} GB/s다.\n\n"
    s+=f"pipeline active 비율은 C3 {a['pipeline_util_pct']:.3f}%, C4 {b['pipeline_util_pct']:.3f}%이지만 input fire 비율은 훨씬 낮다. 특히 C4의 pipeline이 대부분의 시간 비어 있지 않아도 MAC peak utilization이 높다는 뜻은 아니다. DMA와 pipeline의 중첩 비율은 {100*ratio(ac['overlap_dma_mxu'],ac['dma_union_active_cycles']):.3f}% → {100*ratio(bc['overlap_dma_mxu'],bc['dma_union_active_cycles']):.3f}%로 증가한다. 수치들은 C4의 DMA 중첩과 공급 경로 개선에 부합하지만, 개별 stall의 원인을 독립적으로 분리하는 ablation을 하지 않았으므로 특정 bank conflict가 전체 속도 차이를 설명한다고 단정할 수 없다.\n\n"
    ad=a['raw']['cpu_dma'][0];bd=b['raw']['hbm_dma.aggregate'][0]
    s+=f"C3 CPU-DMA source request stall은 {ad['src_rd_req_stall']:,} events이며 wait_dcache 카운터와 같다. C4 HBM-DMA는 source request stall {bd['src_rd_req_stall']:,}, destination write stall {bd['dst_wr_stall']:,} events다. 관찰 지점이 달라 단순 event-count 비율을 speedup의 원인으로 해석할 수는 없지만, C3의 D-cache 경유 공급과 C4의 TMEM 수용 경로를 구분하는 진단 지표가 된다. C3 CPU-DMA rd counter {ad['rd_bytes']:,} B와 실제 외부 AXI read {a['hbm_core_rd_bytes']:,} B도 같지 않아 DMA byte counter를 곧바로 HBM 물리 traffic으로 사용할 수 없다.\n\n"
    lm=a['lmem_physical'];tm=b['tmem']
    s+=f"local memory physical traffic은 C3 read {lm['rd_bytes']:,} B / write {lm['wr_bytes']:,} B, C4 read {tm['rd_bytes']:,} B / write {tm['wr_bytes']:,} B다. local memory traffic의 양과 실제 처리 속도를 분리해 보는 것이 필요하다.\n\n"
    d=b['raw']['lmem_dma_input'][0]
    logical_a=2*b['case']['m']*b['case']['k']
    s+=f"C4 input local DMA는 논리 A {logical_a:,} B에 대해 {d['rd_bytes']:,} B를 읽어 {d['rd_bytes']/logical_a:.1f}배의 local read amplification을 보인다. N 방향 tile마다 A를 재사용하는 방식의 비용이며 HBM에서 같은 비율로 다시 읽는다는 의미는 아니다. weight, scale/zero의 전송량도 DMA table에서 별도로 확인할 수 있다.\n\n"
if 'c4_llama2_ffn_decode' in by:
    r=by['c4_llama2_ffn_decode'];h=r['raw']['hbm_dma.aggregate'][0];ch=r['raw']['hbm_channels'][0]
    active_bw=(h['rd_bytes']+h['wr_bytes'])*r['logic_hz']/ch['active_max']/1e9
    s+=f"C4 FFN의 bandwidth 최솟값 {r['gemm_windows']['min']:.3f} GB/s는 마지막 완전 window에서 측정됐으며 중앙값 {r['gemm_windows']['median']:.3f} GB/s와 크게 다르다. min/max는 시작·종료 및 window alignment에 민감하므로 평균·중앙값·time series를 함께 본다. 또한 HBM-DMA bytes/active_max로 계산하면 {active_bw:.3f} GB/s가 되지만 실제 GEMM 구간 평균은 {r['hbm_gemm_gbps']:.3f} GB/s다. active_max {ch['active_max']:,} cycles는 GEMM {r['gemm_cycles']:,} cycles 전체의 elapsed time이 아니므로 전자를 전체 bandwidth로 보고하면 과대평가한다.\n\n"
s+='kernel-facing AXI의 config상 read capacity는 4 ports×64 B×100 MHz=25.6 GB/s이며 write도 별도 channel에서 같은 beat capacity를 가진다. 이것은 DRAM 실측 peak가 아니라 관찰 interface의 이론적 상한이다. 측정 bandwidth가 이 상한보다 낮다는 사실만으로 HBM 장치 자체가 포화되었다고 결론 낼 수 없다. DMA 의존성, D-cache 경유, TMEM 수용, quantization 및 accumulator 경로를 함께 확인해야 한다.\n\n'
s+='### Attention 및 지원 범위\n\nC4의 실제 Llama3 attention shape `4×1025×128, QBLK=128, WTRANS=1`은 검증을 통과했다. C3는 GEMM 시작 시 `VX_gemm_fsm_naive_meta.sv:384`의 `unsupported dimensions/qblock/alignment` assertion으로 종료했다. 이 FSM은 QBLK register의 log2 값이 5(=32)인지 검사한다. 실제 suite의 QBLK=128은 현재 naive RTL의 지원 범위를 벗어난다. 실패 실행의 GEMM cycles=0을 성능값으로 사용하지 않았다. [실패 simv log](raw/c3_llama3_attention_decode.simv.log)에서 assertion을 확인할 수 있다. 이 shape를 두 backend에서 비교하려면 naive 지원 확장이 먼저 필요하며, QBLK를 임의로 바꾸면 원래 workload와 달라진다.\n\n'
s+='## 검증과 재실행\n\n'
s+='small 원래 perf-only 실행과 최종 관찰 실행의 GEMM cycle 및 host PERF core cycle가 각각 C3 773 / 8,870, C4 303 / 7,610으로 같았다. host PERF instr cycle(MCYCLE)은 C3 8,845, C4 7,585로 busy cycle와 구별된다. reference verification과 window 합계 invariant도 통과했다. raw core final cycles는 profiling epilogue까지 포함해 C3 10,497, C4 9,237이다.\n\n'
s+='```bash\n# 프로젝트 root에서 최초 1회 준비; configure를 다시 하면 monitor 설정을 재추가해야 한다\npython3 analysis_workspace/latency/docs/perf_rev6/tools/setup_builds.py\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case small\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama3_kv_decode\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama2_ffn_decode --timeout 5400\n# C3 QBLK=128 제약 때문에 attention은 C4만 정상 실행 가능\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama3_attention_decode --candidate c4\npython3 analysis_workspace/latency/docs/perf_rev6/tools/analyze.py\n/home/jaeyongjang/.conda/envs/vortex/bin/python analysis_workspace/latency/docs/perf_rev6/tools/render_results.py\n```\n\n'
s+='full FFN의 초기 C4 실행은 VCS 진행 속도를 보고 timeout을 연장하기 위해 중단했다. 그 기록은 `raw/attempts/`에 있고 최종 분석에서는 제외한다. 각 정량 결과는 최종 단일 실행이며 실행 간 분산을 측정하지 않았다.\n\n'
s+='## 추가로 유용한 계측\n\n1. input/weight/scale/zero 공급 ready/valid 원인별 stall 및 accumulator hazard의 실제 카운터를 채우면 pipeline-active와 input-fire 사이의 공백을 설명할 수 있다. 현재 perf의 0만으로는 원인을 분해할 수 없다.\n2. per-bank read/write hotspot과 per-port backpressure를 함께 보면 충돌이 특정 bank/address mapping에 집중되는지 확인할 수 있다. 이미 수집한 raw 자료에 포함되어 있다.\n3. useful FLOPs/AXI byte와 A/weight/scale read amplification은 데이터 재사용 효율을 표현한다. physical SRAM traffic과 DMA endpoint traffic을 구분해야 한다.\n4. prefill의 큰 M, generation batch 변화, QDIR=1, FFN down projection 등으로 확장하면 compute/memory balance가 달라지는 범위를 검증할 수 있다. 이번 측정은 해당 범위를 커버하지 않는다.\n'
# Place figures near the measured tables.
colors={'c3':'#4477AA','c4':'#EE7733'}
actual=[c for c in order if c!='small' and any(r['case']['id']==c for r in rows)]
fig,axes=plt.subplots(1,3,figsize=(13,4),layout='constrained')
for ax,key,label in zip(axes,['gemm_us','input_util_pct','hbm_gemm_gbps'],['GEMM latency (µs)','MXU input fire / GEMM cycles (%)','AXI GEMM-phase bandwidth (GB/s)']):
    for c,shift in [('c3',-.18),('c4',.18)]:
        for i,case in enumerate(actual):
            r=by.get(c+'_'+case)
            if r:ax.bar(i+shift,r[key],width=.34,color=colors[c],label=c.upper() if i==0 else None)
    ax.set_xticks(range(len(actual)),[c.replace('llama','L').replace('_decode','').replace('_',' ') for c in actual],rotation=18,ha='right')
    ax.set_ylabel(label);ax.grid(axis='y',alpha=.25);ax.set_axisbelow(True)
axes[0].set_yscale('log');axes[0].legend();
for ax in axes:
    for i,case in enumerate(actual):
        if 'c3_'+case not in by:ax.annotate('C3 unsupported' if case=='llama3_attention_decode' else 'C3 pending',(i-.18,0.04),xycoords=('data','axes fraction'),rotation=90,fontsize=8,ha='center')
fig.savefig(OUT/'overview.png',dpi=180);fig.savefig(OUT/'overview.svg');plt.close(fig)
fig,axes=plt.subplots(len(actual),1,figsize=(10,3*len(actual)),squeeze=False,layout='constrained')
for ax,case in zip(axes[:,0],actual):
    for c in ['c3','c4']:
        r=by.get(c+'_'+case)
        if not r:continue
        windows=r['raw'].get('GEMM_WINDOW',[])
        x=[w['index']*1024/r['logic_hz']*1e6 for w in windows]
        y=[(w['rd_bytes']+w['wr_bytes'])*r['logic_hz']/w['cycles']/1e9 for w in windows]
        ax.plot(x,y,lw=1.2,color=colors[c],label=c.upper())
    ax.set_title(case);ax.set_xlabel('Elapsed selected GEMM cycles (µs)');ax.set_ylabel('AXI read + write (GB/s)');ax.grid(alpha=.25);ax.legend()
fig.savefig(OUT/'hbm_windows.png',dpi=180);fig.savefig(OUT/'hbm_windows.svg');plt.close(fig)
s=s.replace('## 분석\n\n','![GEMM 성능 비교](perf_rev6/overview.png)\n\n![HBM 1024-cycle window bandwidth](perf_rev6/hbm_windows.png)\n\n## 분석\n\n')
s=s.replace('(raw/c3_llama3_attention_decode.simv.log)','(perf_rev6/raw/c3_llama3_attention_decode.simv.log)')
prefix=DOC.read_text().split('<!-- RESULTS -->')[0]
prefix=re.sub(r'<!-- SUMMARY -->.*?<!-- /SUMMARY -->\n*','',prefix,flags=re.S)
if all(key in by for key in ['c3_llama3_kv_decode','c4_llama3_kv_decode','c3_llama2_ffn_decode','c4_llama2_ffn_decode']):
    summary="<!-- SUMMARY -->\n공통 projection에서 C4는 C3보다 GEMM 구간 기준 **Llama3 K/V 1.882배, Llama2 FFN 1.916배** 빠르다. GEMM 구간 HBM AXI 평균은 C3 **1.18–1.20 GB/s**, C4 **2.30–2.31 GB/s**, MXU input utilization은 C3 **7.34–7.46%**, C4 **14.04–14.06%**다. LMEM/TMEM의 물리 read/write byte 수는 같은 shape에서 동일해, 데이터량 감소보다 공급·중첩 경로의 처리 속도 차이가 두드러진다. 작은 검증 case를 포함한 7개 실행은 reference 검증을 통과했다. C3의 QBLK=128 attention은 현재 naive FSM 지원 범위 제한으로 실패해 성능 표에서 제외했다. HBM 모델은 uncalibrated이며 GB/s를 실측 hardware bandwidth로 해석하지 않는다.\n<!-- /SUMMARY -->\n\n"
    prefix=prefix.replace('## 측정 조건과 재현 자료',summary+'## 측정 조건과 재현 자료')
DOC.write_text(prefix+'<!-- RESULTS -->\n'+s)
print('Rendered',len(rows),'passing cases into',DOC)
