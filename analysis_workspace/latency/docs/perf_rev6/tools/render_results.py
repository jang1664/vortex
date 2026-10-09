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
order=['small','llama3_kv_decode','llama3_kv_decode_m4','llama3_attention_decode','llama2_ffn_decode','llama2_ffn_decode_m4']
rows=sorted(rows,key=lambda r:(order.index(r['case']['id']),r['candidate']))
def fmt(v):return f'{v:,.3f}' if isinstance(v,float) else f'{v:,}'
def table(headers,body):
    return '| '+' | '.join(headers)+' |\n| '+' | '.join(['---']*len(headers))+' |\n'+''.join('| '+' | '.join(str(x) for x in line)+' |\n' for line in body)+'\n'
def ratio(a,b):return a/b if b else 0.0
s='## 측정 결과\n\n'
s+=table(['case','backend','GEMM cycles','GEMM µs','core µs','MXU 유효 util. %','input fire %','pipeline %','유효 GFLOP/s'],[[r['case']['id'],r['candidate'].upper(),fmt(r['gemm_cycles']),fmt(r['gemm_us']),fmt(r['core_us']),fmt(r['effective_peak_pct']),fmt(r['input_util_pct']),fmt(r['pipeline_util_pct']),fmt(r['useful_gflops'])] for r in rows])
s+='MXU 유효 utilization은 `100 × 2MNK / (GEMM cycles × 512)`이며 논리 M/N/K만 사용하고 padding 연산을 제외한다. pipeline %는 nonempty 비율이며 이 utilization과 다르다. 모든 수치는 reference 검증에 통과한 실행만 포함한다. input %와 nominal 유효 peak %는 N/K가 16의 배수이면 같다. ragged attention에서는 padding 때문에 유효 peak %가 조금 더 낮다.\n\n'
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
# Compare logical M=1 and M=4 without treating pipeline occupancy as MAC use.
projection_pairs=['llama3_kv_decode','llama2_ffn_decode']
complete_projection_comparison=all(c+'_'+w+suffix in by for w in projection_pairs for c in ['c3','c4'] for suffix in ['', '_m4'])
if complete_projection_comparison:
    s+='### Projection M=1 → M=4: 같은 workload 비교\n\n'
    s+='두 shape 모두 QBLK=32, WTRANS=0, QDIR=0이고 실제 logical/target M은 4다. C4의 `padded to 8`은 DRAM 버퍼 예약이며 kernel/DMA target을 8로 바꾸지 않는다. host의 M=4 출력과 input handshake 수 `4 × (N/16) × (K/16)`를 검증해 M=8/16 실행을 배제했다. 비교 가능성의 소스·config·monitor·HBM model hash 검사는 [provenance](perf_rev6/provenance.json)에 기록한다. 기존 M=1 데이터는 같은 조건임을 확인한 경우에만 사용한다. 기본 test_vectors의 W/S/Z 생성은 M에 의존하지 않으므로 같은 generation=0에서 동일 weight·scale·zero-point를 사용하며, A의 첫 row도 같다. M=4는 입력 row를 추가한다.\n\n'
    comparison=[]; changes=[];traffic=[]
    for w in projection_pairs:
        for m,suffix in [(1,''),(4,'_m4')]:
            speed=by['c3_'+w+suffix]['gemm_cycles']/by['c4_'+w+suffix]['gemm_cycles']
            for c in ['c3','c4']:
                r=by[c+'_'+w+suffix]
                comparison.append([w,m,c.upper(),fmt(r['gemm_cycles']),fmt(r['effective_peak_pct']),fmt(r['hbm_gemm_gbps']),fmt(r['dma_pipeline_overlap_pct']),fmt(speed)])
                traffic.append([w,m,c.upper(),fmt(r['input_fire']),fmt(r['weight_fire']),fmt(r['hbm_gemm_rd_bytes']),fmt(r['hbm_gemm_wr_bytes']),fmt(r['lmem_physical']['rd_bytes'] if c=='c3' else r['tmem']['rd_bytes']),fmt(r['lmem_physical']['wr_bytes'] if c=='c3' else r['tmem']['wr_bytes']),fmt(r['useful_flops']/(r['hbm_gemm_rd_bytes']+r['hbm_gemm_wr_bytes']))])
        for c in ['c3','c4']:
            a=by[c+'_'+w]; b=by[c+'_'+w+'_m4']
            bytes_a=a['hbm_gemm_rd_bytes']+a['hbm_gemm_wr_bytes'];bytes_b=b['hbm_gemm_rd_bytes']+b['hbm_gemm_wr_bytes']
            changes.append([w,c.upper(),fmt(a['gemm_cycles']/b['gemm_cycles']),fmt(b['useful_gflops']/a['useful_gflops']),fmt(b['effective_peak_pct']/a['effective_peak_pct']),fmt(bytes_b/bytes_a),fmt(b['weight_fire']/a['weight_fire']),fmt(b['dma_pipeline_overlap_pct']-a['dma_pipeline_overlap_pct'])])
    s+=table(['projection','M','backend','GEMM cycles','MXU 유효 util. %','GEMM AXI GB/s','DMA–pipeline overlap %','C4/C3 GEMM speedup'],comparison)
    s+='MXU utilization은 `2MNK/(cycles×512)`다. overlap은 `overlap_dma_mxu/dma_union_active_cycles`이며 reset 이후 DMA-active 시간 중 pipeline-nonempty와 겹친 비율이다. DMA-active는 CPU/HBM/input/weight/scale-zero/output DMA busy의 OR이므로 동시 엔진은 cycle당 한 번만 센다. pipeline-nonempty는 MAC-active가 아니므로 overlap/occupancy를 array utilization으로 표시하지 않는다.\n\n'
    s+=table(['projection','backend','M1/M4 latency speedup','M4/M1 useful throughput','M4/M1 MXU util.','M4/M1 AXI bytes','M4/M1 weight beats','overlap 변화 pp'],changes)
    s+='latency speedup이 1 미만이면 M=4 한 invocation이 더 느린 것이다. throughput은 연산량 4배를 포함하므로 latency speedup과 구별한다. HBM bandwidth의 비율은 `AXI bytes 비율 × latency speedup`이어서 speedup의 독립적인 원인 증거가 아니다.\n\n'
    s+=table(['projection','M','backend','input fire','weight beats','GEMM AXI read B','GEMM AXI write B','local physical read B','local physical write B','useful FLOPs / GEMM AXI B'],traffic)
    s+='![Projection M1/M4 비교](perf_rev6/projection_m1_m4.png)\n\n'
    for w in projection_pairs:
        for c in ['c3','c4']:
            a=by[c+'_'+w]; b=by[c+'_'+w+'_m4']
            s+=f"{w} {c.upper()}: M=1→4에서 input fire {a['input_fire']:,}→{b['input_fire']:,}, weight beats {a['weight_fire']:,}→{b['weight_fire']:,}다. 4-beat weight tile 적재당 input fire가 {4*a['input_fire']/a['weight_fire']:.2f}→{4*b['input_fire']/b['weight_fire']:.2f}로 변해 관측한 weight 재사용 패턴을 나타낸다. GEMM cycles는 {a['gemm_cycles']:,}→{b['gemm_cycles']:,}, 유효 array utilization은 {a['effective_peak_pct']:.2f}%→{b['effective_peak_pct']:.2f}%, overlap은 {a['dma_pipeline_overlap_pct']:.2f}%→{b['dma_pipeline_overlap_pct']:.2f}%다.\n\n"
    for w in projection_pairs:
        a=by['c4_'+w]; b=by['c4_'+w+'_m4']
        stage=[]
        for name in ['lmem_dma_input','lmem_dma_weight','lmem_dma_sz','lmem_dma_output']:
            x=a['raw'][name][0]['rd_bytes']; y=b['raw'][name][0]['rd_bytes']
            stage.append(f"{name}: {x:,}→{y:,} B ({y/x:.2f}배)")
        s+=w+' C4 local DMA read endpoint는 '+', '.join(stage)+'. 이는 input/output 공급량과 weight·S/Z 재사용을 분리해 보여주며, 외부 HBM의 물리 traffic으로 대체하지 않는다.\n\n'
    s+='M 변경에는 입력/출력 storage 크기와 주소 배치 변화도 따른다. 예를 들어 C3 K/V의 weight_base는 M=1에서 0x12000, M=4에서 0x18000이다. 이로 인한 cache/bank/address 영향까지 분리하는 ablation은 하지 않았으므로, latency 변화 전체를 weight 재사용 하나의 인과 효과로 해석하지 않는다. 동일 weight beat로 더 많은 input fire를 처리했다는 관찰과 성능 변화는 구분한다.\n\n'
    util_min=min(by[c+'_'+w+'_m4']['effective_peak_pct'] for w in projection_pairs for c in ['c3','c4'])
    util_max=max(by[c+'_'+w+'_m4']['effective_peak_pct'] for w in projection_pairs for c in ['c3','c4'])
    s+=f"M=4의 유효 array utilization 범위는 {util_min:.2f}–{util_max:.2f}%다. C3/C4 간 latency·공급 beat 처리율·overlap 비교는 공급 및 스케줄링 경로의 상대적 효율을 판단하는 근거이고, M=1→4는 동일 구현에서 weight를 재사용하는 workload 변화다. 후자를 공급 경로 RTL 개선으로 부르지 않는다. '높은 array utilization을 유지한다'는 주장은 이 유효 peak 비율 자체로 평가해야 하며 pipeline occupancy나 overlap 비율로 대신 입증할 수 없다. 구현을 바꾸는 ablation 없이 개별 공급 병목의 인과 기여를 확정하지 않는다. 미구현 stall counter의 0은 stall 부재의 증거가 아니다.\n\n"

    c4_m1=[by['c4_'+w]['effective_peak_pct'] for w in projection_pairs]
    c4_m4=[by['c4_'+w+'_m4']['effective_peak_pct'] for w in projection_pairs]
    speedups=[by['c3_'+w+suffix]['gemm_cycles']/by['c4_'+w+suffix]['gemm_cycles'] for w in projection_pairs for suffix in ['', '_m4']]
    verdict="C4의 상대적 공급·스케줄링 효율이 더 높다는 주장을 지지한다" if min(speedups)>1 else "C4의 상대적 공급·스케줄링 효율이 항상 더 높다는 주장을 지지하지 않는다"
    s+=f"이 표본은 {verdict}(C4/C3 GEMM speedup {min(speedups):.3f}–{max(speedups):.3f}배; weight beat 처리율은 위 표에서 별도로 비교). 그러나 모든 조건에서 '높은 array utilization을 유지한다'는 일반화는 지지하지 않는다. C4의 유효 utilization은 M=1에서 {min(c4_m1):.2f}–{max(c4_m1):.2f}%, M=4에서 {min(c4_m4):.2f}–{max(c4_m4):.2f}%이며, 거의 100%인 DMA overlap을 MAC utilization으로 대체할 수 없다. M=4에서의 증가와 두 projection 간 일관성은 이 두 측정에 한정해 보고한다.\n\n"
for case in ['llama3_kv_decode','llama3_attention_decode','llama2_ffn_decode']:
    a=by.get('c3_'+case);b=by.get('c4_'+case)
    if not a or not b:continue
    ac=a['raw']['core'][0];bc=b['raw']['core'][0]
    s+=f"### {case}\n\nC4는 C3 대비 GEMM 구간 {a['gemm_cycles']/b['gemm_cycles']:.3f}배, 전체 core 구간 {a['core_cycles']/b['core_cycles']:.3f}배 빠르다. 유효 throughput은 {a['useful_gflops']:.3f} → {b['useful_gflops']:.3f} GFLOP/s, MXU input utilization은 {a['input_util_pct']:.3f}% → {b['input_util_pct']:.3f}%다. 두 backend의 input fire는 각각 {a['input_fire']:,}/{b['input_fire']:,}로 유효 연산량 차이에 의한 속도 차이가 아니다.\n\n"
    s+=f"전체 core AXI traffic은 C3 {(a['hbm_core_rd_bytes']+a['hbm_core_wr_bytes'])/1e6:.3f} MB, C4 {(b['hbm_core_rd_bytes']+b['hbm_core_wr_bytes'])/1e6:.3f} MB다. C4의 이점은 주로 비슷한 데이터량을 더 짧은 시간에 처리하는 데 있다. GEMM window bandwidth 범위는 C3 {a['gemm_windows']['min']:.3f}–{a['gemm_windows']['max']:.3f}, C4 {b['gemm_windows']['min']:.3f}–{b['gemm_windows']['max']:.3f} GB/s다.\n\n"
    s+=f"pipeline active 비율은 C3 {a['pipeline_util_pct']:.3f}%, C4 {b['pipeline_util_pct']:.3f}%이지만 input fire 비율은 훨씬 낮다. 특히 C4의 pipeline이 대부분의 시간 비어 있지 않아도 MAC peak utilization이 높다는 뜻은 아니다. DMA와 pipeline의 중첩 비율은 {100*ratio(ac['overlap_dma_mxu'],ac['dma_union_active_cycles']):.3f}% → {100*ratio(bc['overlap_dma_mxu'],bc['dma_union_active_cycles']):.3f}%로 변한다. 이 수치는 DMA 중첩과 공급 경로를 구분하는 단서지만, 개별 stall의 원인을 독립적으로 분리하는 ablation을 하지 않았으므로 특정 bank conflict가 전체 속도 차이를 설명한다고 단정할 수 없다.\n\n"
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
s+='### Attention 및 지원 범위\n\n'
if 'c3_llama3_attention_decode' in by:
    s+='실제 Llama3 attention shape `4×1025×128, QBLK=128, WTRANS=1, QDIR=0`은 C3와 C4 모두 reference 검증을 통과했다. C3의 최초 실패는 QBLK register를 log2=5(32)로 고정한 simulation assertion이었다. 2026-10-09에 허용 범위를 log2=4–7(16·32·64·128)로 넓힌 후 동일 shape를 `xrt-vcs-sim --perf 3`으로 다시 측정해 위 모든 표와 그림에 반영했다. 차원/alignment 검사는 유지했고 하드웨어 데이터 경로는 변경하지 않았다. 최초 실패 기록은 `perf_rev6/raw/attempts/c3_attention_qblk32_assertion_20261008/`에 보존하고 집계에서 제외했다. 작은 QBLK별 검증은 [별도 재실행 문서](perf_rev6/qblk_support_rerun_20261009/README.md)에 있다.\n\n'
else:
    s+='C3 attention의 passing capture가 아직 없어 비교에서 제외했다. 실패 로그를 지원 범위나 성능값으로 대체하지 않는다.\n\n'
s+='## 검증과 재실행\n\n'
s+='small 원래 perf-only 실행과 최종 관찰 실행의 GEMM cycle 및 host PERF core cycle가 각각 C3 773 / 8,870, C4 303 / 7,610으로 같았다. host PERF instr cycle(MCYCLE)은 C3 8,845, C4 7,585로 busy cycle와 구별된다. reference verification과 window 합계 invariant도 통과했다. raw core final cycles는 profiling epilogue까지 포함해 C3 10,497, C4 9,237이다.\n\n'
s+='```bash\n# 프로젝트 root에서 최초 1회 준비; configure를 다시 하면 monitor 설정을 재추가해야 한다\npython3 analysis_workspace/latency/docs/perf_rev6/tools/setup_builds.py\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case small\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama3_kv_decode\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama2_ffn_decode --timeout 5400\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama3_attention_decode\npython3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama3_kv_decode_m4 --case llama2_ffn_decode_m4 --timeout 7200\npython3 analysis_workspace/latency/docs/perf_rev6/tools/analyze.py\n/home/jaeyongjang/.conda/envs/vortex/bin/python analysis_workspace/latency/docs/perf_rev6/tools/render_results.py\n```\n\n'
s+='full FFN의 초기 C4 실행은 VCS 진행 속도를 보고 timeout을 연장하기 위해 중단했다. 그 기록은 `raw/attempts/`에 있고 최종 분석에서는 제외한다. 각 정량 결과는 최종 단일 실행이며 실행 간 분산을 측정하지 않았다.\n\n'
s+='## 추가로 유용한 계측\n\n1. input/weight/scale/zero 공급 ready/valid 원인별 stall 및 accumulator hazard의 실제 카운터를 채우면 pipeline-active와 input-fire 사이의 공백을 설명할 수 있다. 현재 perf의 0만으로는 원인을 분해할 수 없다.\n2. per-bank read/write hotspot과 per-port backpressure를 함께 보면 충돌이 특정 bank/address mapping에 집중되는지 확인할 수 있다. 이미 수집한 raw 자료에 포함되어 있다.\n3. useful FLOPs/AXI byte와 A/weight/scale read amplification은 데이터 재사용 효율을 표현한다. physical SRAM traffic과 DMA endpoint traffic을 구분해야 한다.\n4. prefill의 큰 M, generation batch 변화, QDIR=1, FFN down projection 등으로 확장하면 compute/memory balance가 달라지는 범위를 검증할 수 있다. 이번 측정은 해당 범위를 커버하지 않는다.\n'
# Place figures near the measured tables.
colors={'c3':'#4477AA','c4':'#EE7733'}
actual=[c for c in order if c!='small' and any(r['case']['id']==c for r in rows)]
fig,axes=plt.subplots(1,3,figsize=(16,4.5),layout='constrained')
for ax,key,label in zip(axes,['gemm_us','effective_peak_pct','hbm_gemm_gbps'],['GEMM latency (µs)','Effective MXU utilization (%)','AXI GEMM-phase bandwidth (GB/s)']):
    for c,shift in [('c3',-.18),('c4',.18)]:
        for i,case in enumerate(actual):
            r=by.get(c+'_'+case)
            if r:ax.bar(i+shift,r[key],width=.34,color=colors[c],label=c.upper() if i==0 else None)
    ax.set_xticks(range(len(actual)),[c.replace('llama','L').replace('_decode','').replace('_',' ') for c in actual],rotation=18,ha='right')
    ax.set_ylabel(label);ax.grid(axis='y',alpha=.25);ax.set_axisbelow(True)
axes[0].set_yscale('log');axes[0].legend();
for ax in axes:
    for i,case in enumerate(actual):
        if 'c3_'+case not in by:ax.annotate('C3 pending',(i-.18,0.04),xycoords=('data','axes fraction'),rotation=90,fontsize=8,ha='center')
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
if complete_projection_comparison:
    fig,axes=plt.subplots(2,2,figsize=(13,8),layout='constrained')
    groups=[(w,c) for w in projection_pairs for c in ['c3','c4']]
    for ax,key,label in zip(axes.flat,['gemm_us','effective_peak_pct','hbm_gemm_gbps','dma_pipeline_overlap_pct'],['GEMM latency (µs)','Effective MXU utilization (%)','GEMM-phase AXI bandwidth (GB/s)','DMA–pipeline overlap (%)']):
        for m,suffix,shift,color in [(1,'',-.18,'#4477AA'),(4,'_m4',.18,'#EE7733')]:
            ax.bar([i+shift for i in range(len(groups))],[by[c+'_'+w+suffix][key] for w,c in groups],width=.34,label=f'M={m}',color=color)
        ax.set_xticks(range(len(groups)),[('KV' if 'kv' in w else 'FFN')+' '+c.upper() for w,c in groups])
        ax.set_ylabel(label);ax.grid(axis='y',alpha=.25);ax.set_axisbelow(True);ax.legend()
        if key=='gemm_us':ax.set_yscale('log')
    fig.savefig(OUT/'projection_m1_m4.png',dpi=180);fig.savefig(OUT/'projection_m1_m4.svg');plt.close(fig)
s=s.replace('## 분석\n\n','![GEMM 성능 비교](perf_rev6/overview.png)\n\n![HBM 1024-cycle window bandwidth](perf_rev6/hbm_windows.png)\n\n## 분석\n\n')
s=s.replace('(raw/c3_llama3_attention_decode.simv.log)','(perf_rev6/raw/c3_llama3_attention_decode.simv.log)')
prefix=DOC.read_text().split('<!-- RESULTS -->')[0]
prefix=re.sub(r'<!-- SUMMARY -->.*?<!-- /SUMMARY -->\n*','',prefix,flags=re.S)
if all(key in by for key in ['c3_llama3_kv_decode','c4_llama3_kv_decode','c3_llama2_ffn_decode','c4_llama2_ffn_decode']):
    summary=f"<!-- SUMMARY -->\nM=1 projection에서 C4는 C3보다 GEMM 구간 기준 **Llama3 K/V 1.882배, Llama2 FFN 1.916배** 빠르다. GEMM 구간 HBM AXI 평균은 C3 **1.18–1.20 GB/s**, C4 **2.30–2.31 GB/s**, MXU input utilization은 C3 **7.34–7.46%**, C4 **14.04–14.06%**다. K/V·FFN projection의 LMEM/TMEM 물리 read/write byte 수는 같은 shape에서 동일해, 데이터량 감소보다 공급·중첩 경로의 처리 속도 차이가 두드러진다. 작은 검증 case를 포함한 {len(rows)}개 실행은 reference 검증을 통과했다. HBM 모델은 uncalibrated이며 GB/s를 실측 hardware bandwidth로 해석하지 않는다.\n<!-- /SUMMARY -->\n\n"
    if 'c3_llama3_attention_decode' in by and 'c4_llama3_attention_decode' in by:
        a=by['c3_llama3_attention_decode']; b=by['c4_llama3_attention_decode']
        summary=summary.replace('HBM 모델은',f"M4 attention도 C3를 보완 측정해 C4가 GEMM 구간 **{a['gemm_cycles']/b['gemm_cycles']:.3f}배** 빠름을 확인했다. HBM 모델은")
    if complete_projection_comparison:
        c3=[by['c3_'+w+'_m4']['effective_peak_pct'] for w in projection_pairs]
        c4=[by['c4_'+w+'_m4']['effective_peak_pct'] for w in projection_pairs]
        summary=summary.replace('HBM 모델은',f"M=4 projection의 유효 MXU utilization은 C3 **{min(c3):.2f}–{max(c3):.2f}%**, C4 **{min(c4):.2f}–{max(c4):.2f}%**이며 M1/M4 비교·traffic·overlap은 본문에 함께 제시한다. HBM 모델은")
    prefix=prefix.replace('## 측정 조건과 재현 자료',summary+'## 측정 조건과 재현 자료')
DOC.write_text(prefix+'<!-- RESULTS -->\n'+s)
print('Rendered',len(rows),'passing cases into',DOC)
