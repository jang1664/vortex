# Weight install deadline 기반 Input/Weight scheduler 개선 계획

## 문서 목적

이 문서는 `microtile_readiness_scheduler_opt.md` 구현 및 FSDB 검증 뒤에 확인된
새 병목을 정리하고, 다음 최적화의 구현·검증 순서를 정의한다.

현재 RTL은 numerical result, metadata 순서, DMA request/write count, scheduler retire,
backpressure 안정성 검증을 모두 통과한다. 전체 성능도 호환 baseline보다 개선됐다.
그러나 Input command 내부 gap과 Weight consumer stall은 여전히 남아 있다.

이번 단계의 핵심 목표는 다음과 같다.

> Weight의 TMEM fetch 완료 시점이 아니라, Weight가 register에 install되어 consumer에
> 보이는 시점을 deadline으로 사용한다. Input이 안전한 capacity 안에 있더라도 Weight의
> install slack을 소모할 정도로 앞서가면 Input priority를 낮추고 Weight를 먼저 완료한다.

관련 문서:

- `microtile_readiness_scheduler_opt.md`: descriptor progress, readiness scoreboard,
  fetch/install 분리, P0~P3 priority의 기본 계약
- `weight_tmem_arb_opt.md`: TMEM bank arbitration과 Weight wide request의 기본 구조
- `wreg_db_opt.md`: Weight register versioning, writer fence, double buffering의 lifetime 계약

# 용어 정의

이 문서에서는 아래 용어를 다음 의미로 사용한다.

## Micro-tile

큰 GEMM을 하드웨어가 처리 가능한 크기로 나눈 작업 단위다. 각 micro-tile에는 순서가
증가하는 `work_seq`를 부여한다. Scheduler는 물리 register 번호만 보지 않고
`work_seq`를 기준으로 현재 작업과 lookahead 작업을 구분한다.

## Resource

Micro-tile 실행에 필요한 데이터 종류다.

- Input 또는 I: GEMM 입력 행렬 조각
- Weight 또는 W: GEMM 곱셈에 사용하는 가중치 조각
- Scale 또는 S: quantization/dequantization 배율
- Zero Point 또는 Z/ZP: quantization 기준점

## Beat

DMA descriptor가 요구하는 논리적 전송 단위다. Beat 수는 tile shape, WLOAD, QBLK,
resource 종류에 따라 달라질 수 있다. Scheduler와 completion 판정에서 literal `4` 같은
고정값을 사용하지 않고 descriptor의 `total_beats`를 사용해야 한다.

## Fetch

TMEM request를 보내고 response가 DMA response slot에 도착할 때까지의 구간이다.

```text
TMEM request -> bank arbitration -> response -> DMA response slot
```

`response_beats == total_beats`가 되면 해당 command의 fetch가 완료된 것이다.

## Install

Fetch된 W/S/Z를 DMA slot에서 꺼내 실제 register에 기록하고, 새 generation이 GEMM
consumer에 보이게 만드는 구간이다.

```text
DMA response slot
  -> ordered drain
  -> writer ownership/fence 확인
  -> register write
  -> registered generation visibility
```

Fetch 완료와 install 완료는 같은 사건이 아니다.

## Consumer

Resource를 실제로 읽어 사용하는 pipeline 단계다. Weight consumer는 GEMM tree launch
직전에 필요한 Weight generation을 검사한다. Generation이 준비되지 않았으면 pipeline에
backpressure를 걸어 transaction을 멈춘다.

## Generation

같은 물리 register bank에 저장된 데이터의 논리적 버전 번호다. Bank가 일치해도 현재
generation이 command가 요구하는 target과 다르면 consumer는 그 데이터를 사용할 수 없다.

## Weight double buffering

현재 micro-tile이 한 Weight bank를 사용하는 동안 다른 bank에 다음 Weight를 준비하는
방식이다.

```text
bank A: current micro-tile이 사용
bank B: next micro-tile을 fetch/install
```

전환 시점에 bank B의 target generation이 보이지 않으면 consumer가 stall한다.

## Priority tier

TMEM bank에서 동시에 요청한 requester 중 누구를 먼저 처리할지 정하는 등급이다.

```text
P3: 현재 consumer stall을 직접 해소하는 fetch request
P2: 가장 가까운 deadline을 맞추기 위한 request
P1: bounded lookahead prefetch
P0: background prefetch
```

같은 tier에서는 round-robin과 기존 fairness escape를 사용한다.

## Occupancy

Input DMA response slot 중 현재 사용 중인 slot 수다. Occupancy가 capacity 이내라는 것은
storage safety를 의미하지만, Input이 Weight보다 성능상 적절한 양만큼 앞서 있다는 뜻은
아니다.

## Deadline과 slack

Deadline은 Weight generation이 consumer에 보여야 하는 시점이다. Slack은 deadline까지
남은 시간에서 Weight가 실제 사용 가능해지는 데 필요한 시간을 뺀 값이다.

```text
weight_ready_eta
  = remaining_tmem_service
  + remaining_wide_missing_lane_service
  + response_to_final_write_latency
  + generation_visibility_latency

weight_slack
  = cycles_to_consumer - weight_ready_eta
```

- slack이 충분히 크면 background/lookahead 처리 가능
- slack이 작으면 Weight를 Input보다 먼저 처리해야 함
- slack이 0 이하이면 consumer deadline miss가 예상됨

# 현재 측정 결과

기준 workload는 다음과 같다.

```text
NUM_TMEM_BANKS = 8
NUM_DMA_CHANNELS = 8
NUM_HBM_PORTS = 8
M = 4
N = K = 256
QBLK = 32
WTRANS = 0
WLOAD = 8
QDIR = QCOL
```

최종 FSDB:

```text
build/run_logs/microtile_readiness_scheduler_opt/revised2_fsdb_888/
  20260820-152207_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d0_pid1850190/
  target_gemm.fsdb
```

## Correctness와 전체 성능

- numerical, metadata, scheduler retire: PASS
- I/W/S/Z logical request 수: 256/256/64/64
- I/W/S/Z destination write 수: 256/256/64/64
- readiness scoreboard 최대 occupancy: 4, 종료 occupancy: 0
- M4 QCOL non-FSDB: 628 cycles
- M4 QROW non-FSDB: 625 cycles
- M256 QCOL/QROW non-FSDB: 19427/19427 cycles
- compatible pre-scheduler M4 QCOL baseline: 633 cycles

현재 구현은 correctness 관점에서 안전하고 total cycle도 baseline보다 빠르다. 아래 문제는
strict zero-gap과 consumer deadline 관점의 추가 성능 문제다.

## Input gap

M4 workload에는 64개 Input command와 command당 4개 beat가 있다. 따라서 command 내부
interval은 `64 * 3 = 192`개다.

- 192개 internal interval 중 49개가 non-consecutive
- internal bubble 총 94 cycles
- maximum internal gap 5 cycles
- command-boundary bubble 총 87 cycles

Internal bubble 94 cycles의 직접 상태는 다음과 같다.

```text
Input source가 비어 있음                    : 25 cycles
Input valid=1, GEMM ready=0                  : 69 cycles
```

Input이 이미 valid인데 ready가 낮았던 69 cycles는 모두 다음 조건이었다.

```text
Weight ready = 0
Scale ready = 1
ZP ready = 1
tree credit available
raw Weight consumer block = 1
```

따라서 69-cycle Input backpressure의 직접 원인은 Weight DB generation miss다.

## Weight bank conflict

Weight bank request의 arbitration 결과는 다음과 같다.

```text
Weight offer = 625
Weight grant = 512
Weight loss  = 113
```

Weight loss 113건 중 83건은 같은 bank에서 Input이 grant를 받아 발생했다.

```text
Input P2 vs Weight P1 : 64 losses
Input P2 vs Weight P2 : 13 losses
Input P2 vs Weight P0 :  6 losses
```

이 83건은 대부분 Input response-slot occupancy가 2~3인 상태에서 발생했다. 즉 Input이
완전히 비어 있는 starvation 복구만을 위해 Weight보다 먼저 처리된 것이 아니다.

현재 Input은 물리 capacity와 configured budget을 넘지 않았으므로 storage safety 관점에서
overfetch가 아니다. 그러나 Weight install deadline과 비교하면 performance 관점에서 너무
공격적으로 앞서갔다.

## Weight fetch와 install timing

Weight consumer block은 다음과 같다.

- 96 blocked cycles
- 41 blocked runs/work sequences
- maximum block length 6 cycles

41개 blocked work sequence에서 마지막 Weight response와 consumer block 시작의 관계는
다음과 같다.

```text
consumer가 마지막 response보다 1~3 cycles 먼저 시작 :  8 cases
consumer와 마지막 response가 같은 cycle              :  4 cases
마지막 response가 consumer보다 1 cycle 먼저 도착      : 16 cases
마지막 response가 consumer보다 2 cycles 먼저 도착      : 13 cases
```

모든 blocked work sequence에서 마지막 response부터 마지막 Weight register write까지
정확히 2 cycles가 걸렸다. 마지막 write의 새 generation은 다음 cycle에 consumer-visible이
된다.

```text
T0: final Weight response
T1: response-slot drain/staging
T2: final Weight register write
T3: new generation visible to consumer
```

따라서 final response가 consumer보다 2 cycles 먼저 도착해도 write와 consumer compare가
같은 cycle이면 1-cycle stall이 남는다. 안전한 목표는 final response를 consumer보다 최소
3 cycles 이상 먼저 완료하는 것이다. 이 값은 RTL latency audit와 directed test로 다시
상수화해야 하며, 단순 magic number로 scheduler에 복사하지 않는다.

## `fetch_missing=0`의 정확한 해석

Consumer block feedback는 register를 통과해 scheduler에 다음 cycle 전달된다. Raw block과
registered feedback 사이에 final response가 들어올 수 있다.

```text
cycle N   : raw consumer block, final response pending
cycle N+1 : final response 완료 + registered block 관찰
```

따라서 scheduler debug의 `fetch_missing=0`은 “registered feedback를 관찰한 시점에는 fetch가
끝났다”는 뜻이다. “Consumer deadline보다 충분히 일찍 fetch됐다”는 뜻이 아니다.

# 근본 원인

현재 scheduler는 descriptor-derived fetch progress와 work distance를 사용하지만,
Weight가 consumer-visible이 되는 전체 시간을 deadline 계산에 포함하지 않는다.

현재의 단순화된 판단은 다음과 같다.

```text
distance-0 Weight -> P2
distance-1/2 Weight -> P1
far Weight -> P0
```

이 정책에서는 occupancy가 2~3인 가까운 Input P2가 distance-2 Weight P1을 계속 이긴다.
그 결과 Weight final response가 consumer와 너무 가까운 시점에 도착한다. Response 이후의
고정 drain/write/visibility latency를 흡수할 slack이 없어 Weight DB 전환이 늦고, 이
backpressure가 다시 Input을 멈춘다.

```text
Input P2가 bank service를 선점
  -> Weight wide/final response 지연
  -> install latency를 위한 여유 부족
  -> Weight target generation deadline miss
  -> GEMM consumer stall
  -> Input pipeline backpressure
```

근본 문제는 TMEM 또는 writer 하나가 비정상적으로 느린 것이 아니다. Scheduler가
`fetch-ready`가 아니라 `install-visible-ready`를 deadline으로 사용하지 않은 것이 문제다.

# 목표와 비목표

## 목표

- Weight final response가 install latency를 흡수할 만큼 consumer보다 일찍 완료되도록 함
- Input이 비었을 때는 즉시 복구하되, occupancy가 이미 확보되면 critical Weight에 양보
- Fetch-complete W/S/Z에는 추가 TMEM priority를 주지 않음
- Current Input starvation과 일반 DMA starvation을 만들지 않음
- Existing register generation, writer fence, overwrite safety를 보존
- Fixed `valid && !ready` request의 payload와 priority 안정성을 보존

## 이번 1차 구현의 비목표

- Weight register bank/storage 수 증가
- Write-data 또는 final-write-completion forwarding
- Writer order 변경 또는 out-of-order install
- GEMM ready를 scheduler priority에 combinational 연결
- Fetch-complete Weight를 P3로 승격
- 특정 WLOAD/QBLK/tile shape의 beat 수를 scheduler에 고정

1차 구현으로 deadline을 만족하지 못하면 원인을 다시 분류한 뒤 storage/ownership 변경을
별도 단계로 진행한다.

# 해결책

## 1. End-to-end Weight ready ETA 추가

Readiness scoreboard의 각 Weight dependency에 다음 정보를 유지한다.

```text
weight_total_beats
weight_request_beats
weight_response_beats
weight_writer_beats
weight_wide_missing_lanes 또는 completion state
weight_installed_generation
work_distance
```

ETA는 최소한 다음 항목을 구분한다.

```text
remaining_fetch_service
  = 아직 request하지 않은 logical beats
  + outstanding response beats
  + oldest wide beat의 missing bank lanes

remaining_install_service
  = fetch-complete 전이면 conservative response-to-visible latency
  + fetch-complete 뒤면 writer progress 및 registered visibility latency
```

Writer path의 관측된 2-cycle response-to-write와 1-cycle visibility는 명시적인 parameter 또는
module-local contract로 정의한다.

예시 이름:

```text
WEIGHT_RSP_TO_WRITE_LATENCY
WEIGHT_WRITE_TO_VISIBLE_LATENCY
```

이 값은 source scheduler가 tile shape에 따라 추측하지 않는다. 실제 pipeline stage 수에서
정의하고 assertion으로 검증한다.

## 2. Exact cycle 대신 registered deadline bucket부터 구현

첫 구현부터 부정확한 cycle predictor를 만들지 않는다. Registered state만 사용하는
세 단계 bucket으로 시작한다.

```text
SAFE:
  현재 Input lead와 earlier work가 충분하고 Weight ready ETA에 여유가 있음

NEAR:
  Weight fetch가 남았으며 Input occupancy/admission progress상 곧 consumer에 도달 가능

CRITICAL:
  Weight fetch가 남았고, 남은 fetch+install-visible latency가 consumer slack 이상
```

Bucket은 `work_distance` 하나만으로 정하지 않는다. 최소한 Input occupancy와 해당
`work_seq`의 Input fetch/admission progress를 함께 사용한다.

권장 초기 조건은 다음과 같다.

```text
CRITICAL if
  Weight fetch pending
  && work_distance <= configured near window
  && (
       matching Input has started admission
       || matching/earlier Input occupancy reaches critical threshold
       || conservative ETA says install-visible deadline miss
     )
```

`matching Input has started admission` 정보가 현재 scoreboard에 없다면 GEMM admission event를
registered `work_seq`와 함께 controller로 전달한다. 이 event는 priority에 다음 cycle부터만
반영한다.

## 3. Input minimum service와 ahead service 분리

Input을 하나의 P2 stream으로 취급하지 않는다.

```text
Input starvation recovery:
  occupancy == 0인 current/near Input
  -> P3

Input minimum service:
  occupancy == 1인 current/near Input
  -> P2

Input ahead service:
  occupancy >= INPUT_MIN_READY
  -> Weight deadline에 따라 P1 또는 P0
```

초기 sweep 후보:

```text
INPUT_MIN_READY = 1 또는 2
```

Input occupancy가 2 이상이고 CRITICAL Weight fetch가 존재하면 다음 정책을 우선 검증한다.

```text
critical Weight: P2
additional Input: P1
```

실제 consumer가 block됐고 fetch가 남은 경우에만 기존 계약대로 Weight P3를 허용한다.

## 4. Weight completion request 보호

Weight wide request는 한 logical beat가 여러 bank lane을 모두 받아야 완료된다. Oldest beat의
마지막 missing lane이나 command의 final logical request는 다음 Weight-ready 시점을 직접
결정한다.

Fetch가 남은 CRITICAL Weight에 한해 다음을 P2 completion bonus로 처리한다.

- final logical request
- oldest wide beat의 마지막 missing lane
- 해당 request가 완료되면 `response_beats == total_beats`가 되는 경우

Completion bonus는 P3가 아니다. Actual registered consumer block이며 fetch가 남은 경우에만
P3를 사용한다.

## 5. Fetch-complete와 install-pending 정책 유지

다음 상태의 Weight에는 TMEM priority를 주지 않는다.

```text
response_beats == total_beats
```

이때 Weight가 아직 consumer-visible이 아니면 `INSTALL_PENDING` 또는
`FETCHED_NOT_INSTALLED`로 기록한다. Source priority는 P0으로 유지한다.

Install-pending만을 이유로 Input TMEM request를 막지 않는다. Input을 막아도 독립 writer가
빨라지지 않기 때문이다. 이 상태가 반복적으로 deadline을 놓치면 source policy가 아니라
writer/install storage 문제로 분류한다.

## 6. Stalled request priority 안정성

TMEM request가 `valid=1 && ready=0`이면 priority와 payload를 바꾸지 않는다.

```text
새 request를 제시하기 전:
  최신 deadline bucket을 sampling

request가 stall된 뒤:
  address/data/tag/work_seq/priority를 handshake까지 hold
```

이미 bank에 제시된 request를 live reprioritize하지 않는다. Reprioritization이 필요하면
별도의 descriptor queue 구조를 사용하며 이번 1차 범위에서는 제외한다.

## 7. Fairness 보존

Priority가 높은 requester가 계속 존재해도 일반 DMA와 낮은 tier requester가 bounded time
안에 progress해야 한다.

- 같은 tier: 기존 round-robin 유지
- 서로 다른 tier: 기존 consecutive-priority cap/fairness escape 유지
- Input starvation recovery P3도 무한 연속 허용하지 않음
- Weight CRITICAL P2가 Scale/ZP completion을 영구적으로 막지 않음

# 구현 계획

## 1단계: Baseline probe와 contract 고정

수정 전 현재 FSDB에서 다음 값을 자동 추출하는 분석 스크립트 또는 재현 가능한 명령을
정리한다.

- Input internal/boundary gaps
- Input valid/ready와 Weight raw block overlap
- Resource별 bank offer/grant/loss와 winner
- Weight final response, final write, generation-visible, first consumer 시점
- Work sequence별 `fetch_to_consumer`, `fetch_to_write`, `write_to_visible`
- Priority pair별 conflict count

Assertion으로 다음 latency contract를 고정한다.

- final response부터 final write까지 예상 latency
- final write가 같은 cycle generation compare를 바꾸지 않음
- generation은 정의된 registered boundary 뒤에 visible

## 2단계: Scheduler deadline metadata 추가

주요 수정 후보:

- `hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/rtl/core/gemm/VX_gemm_node.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`
- 필요 시 `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv`

추가할 registered 정보:

- Input admission event와 `work_seq`
- Weight consumer까지의 deadline bucket 입력
- Weight response-to-visible latency contract
- Debug용 `weight_slack_bucket`, `input_service_class`

기존 descriptor-derived total/request/response/writer progress는 재사용한다.

## 3단계: Input service class 분리

Scheduler에서 Input priority를 occupancy와 Weight bucket에 따라 분리한다.

초기 policy:

```text
occupancy == 0:
  Input P3

occupancy == 1 and no current Input stall:
  Input P2

occupancy >= INPUT_MIN_READY and CRITICAL Weight fetch pending:
  Weight P2
  Input P1

otherwise:
  기존 current/near Input P2와 bounded budget 유지
```

`INPUT_MIN_READY`는 1과 2를 directed/node test에서 sweep한다. 3 이상은 현재 occupancy 2~3
구간의 Weight conflict를 재현할 가능성이 크므로 초기 기본값으로 사용하지 않는다.

## 4단계: Weight ETA/completion bonus 연결

- Descriptor의 authoritative progress만 사용
- Weight wide missing-lane completion을 ETA에 반영
- CRITICAL fetch-pending Weight의 final request/lane을 P2
- Actual block + fetch pending만 P3
- Fetch-complete/install-pending은 P0

## 5단계: Debug 및 assertion 추가

필수 debug counter:

```text
input_won_over_critical_weight
critical_weight_bank_loss
weight_fetch_after_consumer
weight_fetch_lead_0_1_2_3plus
weight_install_deadline_miss
input_starvation_recovery_cycles
input_ahead_throttled_cycles
fetch_missing_block
fetched_not_installed_block
```

필수 assertion:

- Fetch-complete resource가 P1/P2/P3가 되지 않음
- CRITICAL Weight가 있을 때 occupancy threshold 이상의 Input이 더 높은 tier가 되지 않음
- Stalled request priority/payload/work sequence 안정
- Counter와 descriptor `total_beats` 일치
- Final write와 같은 cycle scheduler priority/Input budget이 바뀌지 않음
- Scheduler output이 GEMM `req_ready`를 조합 구동하지 않음

# 검증 계획

## 1. Scheduler directed unittest

`hw/unittest/microtile_readiness_scheduler`에 다음 case를 추가한다.

- occupancy 0 Input P3
- occupancy 1 Input P2
- occupancy 2 이상 + SAFE Weight: 기존 Input ahead 허용
- occupancy 2 이상 + CRITICAL fetch-pending Weight: Weight P2, Input P1
- final Weight request/lane completion bonus P2
- actual consumer block + fetch pending Weight P3
- consumer block + fetch complete Weight P0
- install-pending Weight P0
- Scale/ZP completion과 일반 DMA fairness
- valid/ready stall 중 priority와 payload hold
- descriptor total 1/2/4/8/9 및 slot-depth보다 큰 command

## 2. LDMA와 wide-switch unittest

- Weight logical response는 모든 wide lane 완료 뒤 한 번만 증가
- Last missing lane 정보와 command final response 일치
- Request가 stall되면 sampled deadline priority 유지
- Input service class가 새 request에만 반영
- Reset, slot recycle, same-cycle pop/push 안정

## 3. GEMM unit/controller unittest

- Input admission event의 `work_seq` 정확성
- Raw Weight block은 registered feedback보다 정확히 한 cycle 빠름
- Final response/write/visible latency contract
- Weight miss 중 Input transaction/metadata 안정
- Scale/ZP/tree가 준비된 Weight-only block case
- Final write same-cycle에는 old generation compare, 정의된 다음 cycle에는 new generation compare

## 4. Node VCS matrix

Configured build directory에서 다음 조건을 실행한다.

```text
M = 4, 256
N = K = 256
QBLK = 32
QDIR = QCOL, QROW
WTRANS = 0
WLOAD = 8
T/D/H = 8/8/8
```

기본 명령 형태:

```bash
source configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh
export CONFIGS="$CONFIGS -DNUM_TMEM_BANKS=8 -DNUM_DMA_CHANNELS=8 -DNUM_HBM_PORTS=8"
export CC=/usr/bin/gcc
export CXX=/usr/bin/g++

/usr/bin/python3 tools/verify_rtl.py unittest \
  --path build/hw/unittest/gemm_node_improve \
  --sim vcs \
  --params "M=<M> N=256 K=256 QBLK=32 WTRANS=0 WLOAD=8 QDIR=<0|1>" \
  --extra-sim-args "+REQUIRE_INPUT_METADATA +NO_WAVE"
```

반드시 확인할 항목:

- numerical output
- command/packet/retire count
- Input metadata order
- W/S/Z generation target
- Input stall 중 payload 안정
- ACC/post-process backpressure 회귀

## 5. XRT-VCS blackbox

Blackbox는 configured build의 wrapper를 통해 `xrt-vcs-sim`으로 실행한다.

```bash
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "..."
```

Repository의 `ci/run_target_gemm.sh`를 사용할 경우 첫 case는 강제 rebuild하고, 이후 case는
matching compile configuration과 fresh `simv`만 재사용한다. Verilator `rtlsim`이나 `simx`를
blackbox 대체 수단으로 사용하지 않는다.

## 6. FSDB strict 분석

첫 FSDB는 M4 QCOL에서 생성한다. 다음 기준을 통과한 뒤 QROW로 확장한다.

### Weight 기준

- Steady-state Weight consumer block 0 목표
- Cold-start 예외가 있으면 별도 분류하고 bounded recovery 증명
- Final response가 consumer보다 최소 required install-visible latency만큼 먼저 도착
- `input_won_over_critical_weight` 0
- Critical Weight의 Input 원인 bank loss 0 또는 fairness escape로 설명 가능한 bounded 값
- Fetch-complete Weight priority P0

### Input 기준

- Weight 원인의 `valid && !ready` internal gap 0 목표
- Pipeline이 실제로 ready인 source-empty gap이 현재보다 증가하지 않음
- Occupancy 0 starvation recovery가 bounded
- Input command 내부 consecutive beat와 boundary gap을 service class별로 분류
- Input budget과 physical response-slot capacity 준수

### 전체 기준

- M4 QCOL/QROW total cycle이 현재 628/625보다 악화되지 않음
- M256 QCOL/QROW이 현재 19427/19427 대비 0.5% 이상 악화되지 않음
- Requester별 maximum consecutive bank loss가 fairness bound 이내
- 일반 DMA/Output/Scale/ZP starvation 없음
- Data loss, duplicate, reorder, stale generation, unsafe overwrite 0

Cycle 차이가 1~2 정도면 단일 run으로 결론내지 않는다. 동일 binary와 configuration으로
여러 번 실행하거나 deterministic counter를 비교해 policy 효과와 실행 noise를 분리한다.

# 단계별 판정과 fallback

## Gate A: Priority 변경이 실제 bank schedule을 바꾸는가

다음을 확인한다.

- CRITICAL Weight가 실제 bank request에서 P2로 제시됨
- Occupancy threshold 이상의 Input이 P1로 낮아짐
- Weight가 Input 때문에 잃은 83건이 감소함

Priority 분포만 바뀌고 offer/grant/loss가 그대로면 fixed-at-request sampling 시점 또는
deadline bucket 전달 경로를 먼저 수정한다. Storage 구조 변경으로 바로 넘어가지 않는다.

## Gate B: Final response lead가 확보되는가

Weight final response가 consumer보다 필요한 latency만큼 일찍 도착하는지 확인한다.

- Lead가 확보되고 block이 사라지면 1차 정책 성공
- Lead가 확보됐는데도 block이 남으면 install/visibility contract 분석으로 이동
- Lead를 확보하지 못하면 command가 scheduler window에 들어오는 시점과 FSM issue timing 분석

Command 자체가 늦게 생성된다면 TMEM arbiter priority만으로 해결할 수 없다. 이 경우 FSM 또는
controller가 Weight descriptor를 더 일찍 enqueue하도록 별도 계획을 세운다.

## Gate C: Install path가 실제 병목인가

Final response가 충분히 일찍 끝났는데도 final write가 늦는 경우에만 다음 구조 변경을 검토한다.

- Additional Weight generation/install slot
- Lifetime-aware writer reordering
- Registered reservation/ownership ledger

Write-data 또는 final-completion forwarding은 마지막 대안이다. Forwarding 없이 해결 가능한지
먼저 확인한다.

# Hard Rule

다음 조건이 발생하면 해당 구현을 중단하고 설계를 다시 논의한다.

- Input을 낮춘 결과 occupancy 0 starvation이나 일반 DMA starvation이 unbounded해짐
- Weight priority가 먼 lookahead W/S/Z overfetch를 다시 만들어 current Input을 늦춤
- Fetch-complete/install-pending Weight가 TMEM P1/P2/P3로 승격됨
- Scheduler priority와 GEMM ready 사이에 combinational loop가 생김
- `valid && !ready` request의 payload, tag, work sequence, priority가 바뀜
- Descriptor `total_beats` 대신 tile/WLOAD/QBLK 고정 beat 수를 사용함
- Final register write가 같은 cycle priority/Input budget/GEMM ready를 바꿈
- Register generation lifetime을 증명하지 못한 상태에서 writer order 또는 storage ownership을 변경함
- M4만 개선되고 M256/QROW/general DMA에서 starvation 또는 유의한 성능 회귀가 발생함

# 완료 조건

다음 조건을 모두 만족하면 이 계획을 완료한 것으로 판정한다.

- Deadline policy가 final response뿐 아니라 install-visible latency를 포함
- Input minimum service와 ahead service가 분리됨
- Critical Weight가 Input 때문에 bank service를 놓치지 않음
- Weight 원인의 steady-state Input held-valid gap 제거 또는 명확한 bounded 예외만 남음
- Current Input과 일반 DMA starvation 없음
- Numerical, metadata, generation, overwrite safety 전부 PASS
- Fixed 8/8/8 VCS node matrix 및 XRT-VCS matrix PASS
- FSDB에서 priority 변화가 실제 bank schedule과 final-response lead 개선으로 이어짐
