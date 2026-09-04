# Weight TMEM Arbitration Optimization

# 문제점

현재 목표는 M=4에서 하나의 Weight를 사용하는 4-beat Input burst와 다음
4-beat burst를 가능한 한 back-to-back으로 GEMM unit에 공급하는 것이다. Input,
Weight, Scale, ZP LDMA에 multi-command overlap과 response slot을 추가했고 W/S/Z
consumer-stage backpressure도 구현했지만, QCOL FSDB에서는 아직 Input과 Weight
stream에 bubble이 남아 있다.

분석 기준 FSDB는 다음과 같다.

```text
build/run_logs/target_gemm/
  20260815-220116_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d0_pid1881593/
  target_gemm.fsdb
```

## Response slot occupancy는 ready-data 개수가 아님

Weight LDMA의 8개 response slot은 다음 lifecycle을 갖는다.

```text
FREE
  -> source request accepted
WAIT_RSP
  -> source response accepted
READY
  -> response RAM read
DRAINING
  -> final WREG write handshake
FREE
```

`slot_occupancy`는 source request가 accept될 때 증가하고 WREG write가 끝날 때
감소한다. 따라서 `WAIT_RSP`, `READY`, `DRAINING`을 모두 포함하며, occupancy가
8이라고 해서 8개 data가 모두 준비된 것은 아니다.

64개 Weight command의 command-internal bubble 71 cycle을 보면 다음과 같다.

- 71/71 cycle에서 writer fence는 이미 release되어 있었다.
- 71/71 cycle에서 WREG `req_ready`가 원인이 아니었다.
- 64/71 cycle은 expected slot이 막 `READY`가 되어 response RAM read를 시작하는
  cycle이었다.
- 7/71 cycle은 expected slot 자체가 아직 `WAIT_RSP`였다.
- 56 cycle은 전체 8 slot 중 `WAIT_RSP=6`, `READY=1`이었다.
- READY slot이 2개 이상 미리 쌓여 있던 bubble cycle은 없었다.

Response payload RAM은 synchronous registered-read 구조이므로 expected slot이
현재 Weight write보다 충분히 일찍 `READY`여야 현재 write와 동시에 다음 slot을
preload할 수 있다. Response가 write boundary에 맞춰 늦게 도착하면 slot은
occupied 상태여도 다음 cycle에 RAM read를 거쳐야 하므로 bubble이 발생한다.

## TMEM bank arbitration이 Weight wide response를 늦춤

각 TMEM bank는 다음 여섯 requester가 하나의 single-port SRAM을 공유한다.

```text
port 0: tile DMA direct
port 1: Input LDMA read
port 2: Weight LDMA wide read
port 3: Scale LDMA read
port 4: Zero-point LDMA read
port 5: Output LDMA access
```

현재 target에서는 `MXU_WLOAD_NUM=8`이고 TMEM bank width는 64 B이므로 Weight
wide beat가 128 B이다. 일반적인 Weight beat 크기는 다음 derived 값으로 정의한다.

```text
WEIGHT_BEAT_BYTES = GEMM_WEIGHT_DATA_SIZE
                  = MXU_COL * MXU_WLOAD_NUM * W_BIT_WIDTH / 8
WEIGHT_BANKS_PER_BEAT = WEIGHT_BEAT_BYTES / TMEM_BANK_BYTES
NUM_WEIGHT_BANK_GROUPS = NUM_TMEM_BANKS / WEIGHT_BANKS_PER_BEAT
```

따라서 Weight wide response 하나를 만들려면 선택된
`WEIGHT_BANKS_PER_BEAT`개 bank response가 모두 도착해야 한다. 일부 bank만
grant되면 해당 lane은 context에 보관되고 나머지 bank를 다시 기다린다.

256개 Weight source beat 구간의 bank arbitration 결과는 다음과 같다.

```text
Weight가 필요로 한 bank grant     512 = 256 beats * 2 banks
Weight bank demand                 624 bank-cycles
Weight가 다른 requester에 밀림    112 bank-cycles
  Input                            92
  tile DMA                          8
  Zero-point                        6
  Scale                             3
  Output                            3
```

그 결과 64개 Weight command 중 이상적인 4-cycle 연속 write를 달성한 command는
25개뿐이었다.

```text
4 cycles: 25 commands
5 cycles: 21 commands
6 cycles:  7 commands
7 cycles:  9 commands
8 cycles:  1 command
9 cycles:  1 command
```

즉 command FIFO depth 4와 response slot 8은 source overlap을 만들고 있지만,
TMEM bank service가 next in-order Weight beat를 write boundary보다 앞서 준비할 만큼
안정적이지 않다. Slot이나 command context를 더 늘리는 것만으로는 single-port bank
service와 in-order head-of-line 지연을 제거할 수 없다.

## Input 공급 지연은 대부분 Weight 지연의 결과임

64개의 4-beat Input burst 내부에서 관찰된 103개 빈 cycle은 다음과 같이 분류된다.

```text
99 cycles: Input payload는 LDMA에 있지만 GEMM consumer ready가 0
 4 cycles: GEMM consumer는 ready지만 Input LDMA drain data가 없음
```

99 cycle은 모두 true consumer stage에서 요구하는 Weight generation이 늦어서
발생했다. Input LDMA 자체도 256개 read를 위해 284 valid cycle을 사용했고, 28
cycle은 선택된 TMEM bank arbitration에서 밀렸다. 그러나 Input overlap buffer가
그중 대부분을 숨겨 실제 Input stream에 source-data bubble로 드러난 것은 4 cycle이다.

현재 병목의 causal chain은 다음과 같다.

```text
TMEM bank conflict
  -> current WLOAD8 Weight의 2-bank wide response skew
  -> next in-order Weight response가 늦음
  -> 4-beat WREG load가 5~9 cycles로 늘어남
  -> 2-bank WREG reuse deadline을 놓침
  -> GEMM true consumer가 Weight generation을 기다림
  -> 이미 buffered된 Input도 GEMM에 공급되지 못함
```

## 현재 tensor allocation은 bank phase가 모두 같음

현재 주요 TMEM allocation base는 모두 64 B bank-interleave 관점에서 phase 0이다.

```text
Input  buffer 0: 0x100000
Weight buffer 0: 0x200000
Output buffer 0: 0x300000
Scale  buffer 0: 0x400000
ZP     buffer 0: 0x480000
```

TMEM switch는 64 B word address의 하위 3 bit로 8개 bank를 선택한다. 따라서 서로
다른 tensor stream이 유사한 cadence로 시작하면 같은 bank phase에서 반복적으로
충돌한다.

기존 QCOL trace의 request timing을 고정하고 Input base phase만 가상 회전한 정적
분석에서는 Input/Weight 동시 same-bank demand가 다음과 같이 변했다.

```text
Input skew   concurrent Input/Weight same-bank demand
0 B          95
+64 B        32
+128 B       41
+384 B       20
+448 B      172
```

이는 실제 timing을 다시 계산한 성능 결과는 아니지만, 현재 충돌이 allocation phase에
민감하고 작은 skew가 유효한 저비용 실험임을 보여준다. 동시에 잘못 고른 skew는
충돌을 더 악화시킬 수 있으므로 하나의 고정값을 추측해서 적용하면 안 된다.

# 해결책

## 1. Ready-ahead 기반 TMEM arbitration

핵심 해결책은 TMEM bank arbiter가 requester별 source urgency를 받아, 실제 consumer
starvation에 가까운 request를 speculative prefetch보다 먼저 처리하게 하는 것이다.

Arbiter는 `slot_occupancy`만 보고 우선순위를 결정하면 안 된다. Priority 생성기는
최소한 다음 상태를 사용한다.

- `drain_valid`: 지금 바로 destination으로 보낼 beat가 staged되어 있는가
- `ready_ahead`: `wr_expect_slot`부터 연속으로 `READY`인 slot 수
- `head_waiting`: next in-order slot이 `WAIT_RSP`인가
- `writer_can_advance`: writer fence가 release되고 destination이 진행 가능한가
- `downstream_blocked`: 해당 LDMA destination이 다른 operand 때문에 막혀 있는가
- held source request: `valid && !ready` 동안 priority가 변경되지 않았는가

첫 구현은 1-bit priority로 제한한다.

```text
URGENT:
  consumer가 진행할 수 있는데 staged/ready-ahead data가 low watermark 미만

NORMAL:
  ready-ahead가 충분하거나 downstream 자체가 block됨
```

TMEM bank는 다음 순서로 grant한다.

1. URGENT request가 있으면 URGENT mask 안에서 round-robin
2. URGENT가 없으면 모든 NORMAL request 사이에서 기존 round-robin
3. 같은 request가 오래 기다리면 age/fairness rule로 승급
4. 연속 urgent grant 수에 제한을 두어 tile DMA와 다른 LDMA starvation 방지

Weight wide request의 모든 bank lane은 반드시 같은 stored priority를 사용한다.
Priority는 wide-switch context accept 시점에 command/beat와 함께 저장하며, 한 lane이
먼저 accept된 뒤 다른 lane을 기다리는 동안에도 변경하지 않는다.

현재 공용 `MEM_FLAGS_WIDTH`의 bit들은 flush, IO, local 의미로 이미 정의되어 있으므로
전역 memory flag를 무심코 확장하거나 재해석하지 않는다. TMEM subsystem 내부의
전용 priority sideband를 우선 사용한다.

## 2. Input/Weight 우선순위부터 제한적으로 적용

첫 성능 실험은 모든 requester를 동시에 변경하지 않는다. 현재 Weight가 놓친 bank
grant의 92/112가 Input 때문이므로 다음 조건만 먼저 적용한다.

```text
Weight ready-ahead가 low watermark 미만
AND Input은 drain-valid이며 충분한 consecutive ready-ahead를 가짐
  -> 같은 bank에서는 Weight 우선
```

Weight가 Input에 밀린 92 cycle을 관찰하면 Input은 89 cycle에서 이미 drain data를
가지고 있었고, 63 cycle에서는 READY slot이 4개 이상 있었다. 따라서 현재 Input
beat를 중단하지 않고 미래 Input prefetch grant만 Weight로 재배분할 여지가 있다.

Fixed Weight priority는 사용하지 않는다. Input ready-ahead도 부족한 경우에는 기존
round-robin/fairness가 유지되어야 한다. 이 단계가 효과가 있으면 Scale/ZP, tile DMA,
Output에도 같은 urgency contract를 일반화한다.

## 3. Resource-aware tensor allocation skew

Dynamic arbitration과 독립적인 저비용 실험으로 tensor base에 configurable bank-phase
skew를 둔다.

- Input, Scale, ZP, Output base는 `TMEM_BANK_BYTES` 단위로 phase를 회전한다.
- 두 double-buffer base에는 동일한 resource phase를 적용한다.
- Weight base는 64 B bank 단위가 아니라 `GEMM_WEIGHT_DATA_SIZE` 단위의 wide-bank
  group으로 회전한다. `MXU_COL`과 `W_BIT_WIDTH`가 현재 값으로 고정되어 있을 때
  Weight skew 단위는 `MXU_WLOAD_NUM`에 따라 자동으로 128 B, 256 B, 512 B 등으로
  바뀐다.
- Weight가 선택할 수 있는 phase 수는
  `NUM_TMEM_BANKS / WEIGHT_BANKS_PER_BEAT`이다. `WEIGHT_BANKS_PER_BEAT`가 전체
  TMEM bank 수와 같으면 Weight는 모든 bank를 동시에 사용하므로 의미 있는 Weight
  phase skew가 없다.
- 각 buffer의 reserved region 사이에 padding을 두고 overlap하지 않음을 검증한다.
- tile DMA producer와 local LDMA consumer는 반드시 동일한 skewed base를 사용한다.

Skew는 heuristic이므로 단일 값을 architecture contract로 고정하지 않는다. 먼저
일반 resource는 `0 .. NUM_TMEM_BANKS-1` bank phase를, Weight는
`0 .. NUM_WEIGHT_BANK_GROUPS-1` wide-group phase를 sweep하고 QCOL/QROW 및
M=4/M=256에서 공통적으로 좋은 조합을 찾는다. 현재 WLOAD8 target의 Weight phase는
0, 128, 256, 384 B이다. Shape나 WLOAD 구성에 따라 최적 phase가 다르면 compile-time
parameter 또는 allocator policy로 유지한다.

## 4. TMEM bank 수 증가는 이번 범위에서 보류

Bank 수 증가는 conflict 확률을 직접 낮출 수 있지만 이번 계획의 기본 해결책으로
사용하지 않는다.

- bank별 6:1 arbiter와 switch wiring 증가
- DMA channel/config/done interface 증가
- 현재 bank size를 유지하면 전체 TMEM capacity와 memory macro 수 증가
- 전체 capacity를 고정하면 bank depth, URAM packing, address mapping 재검토 필요
- routing 및 timing cost 증가

Skew와 urgency arbitration으로 현재 8-bank bandwidth를 먼저 효율적으로 사용한다.
두 방법 이후에도 실제 bank grant bandwidth 자체가 부족하다는 증거가 남을 때만
별도 plan에서 bank 수 증가를 검토한다.

## 성공 기준

기능 정확성과 함께 다음 steady-state 조건을 만족해야 한다.

- Weight command/beat/tag와 WREG bank/version의 loss, duplicate, reorder 없음
- Input/Weight/Scale/ZP/Output 및 tile DMA starvation 없음
- Weight가 Input의 충분한 buffered lead 때문에 밀리는 bank grant가 0 또는 이에
  가까운 수준으로 감소
- Weight 4-beat command의 command-internal bubble 제거
- Weight operand가 다음 consumer deadline 전에 준비되어 true-consumer stall 제거
- operand가 준비된 4-beat Input burst는 내부와 command boundary에서 zero-gap
- tile boundary refill 같은 별도 원인은 steady-state 성능 판정과 분리해서 보고

# 구현 계획

## 1. Baseline instrumentation 고정

현재 FSDB 분석에 사용한 signal을 안정적인 non-synthesis probe 또는 perf counter로
정리한다.

- 각 LDMA의 `drain_valid`, `wr_expect_slot`, slot state, consecutive ready-ahead
- source request fire/stall과 response fire
- destination fire/stall과 writer release
- TMEM bank별 request-valid mask, selected requester, requester별 grant/loss count
- Weight wide context의 pending bank mask와 completion cycle
- Input true-consumer stall reason

`slot_occupancy`와 ready-data count를 별도 counter로 노출해 이후 분석에서 둘을 혼동하지
않도록 한다.

## 2. Allocation skew를 parameter화

`kernel/src/fi_gemm.c`의 TMEM base 상수를 resource별 base와 bank-phase offset으로
분리한다.

```text
TMEM_INPUT_BANK_SKEW
TMEM_WEIGHT_GROUP_SKEW
TMEM_SCALE_BANK_SKEW
TMEM_ZP_BANK_SKEW
TMEM_OUTPUT_BANK_SKEW
```

- 일반 resource offset은 `*_BANK_SKEW * TMEM_BANK_BYTES`로 계산한다.
- Weight offset은 `TMEM_WEIGHT_GROUP_SKEW * GEMM_WEIGHT_DATA_SIZE`로 계산한다.
  고정된 64 B 배수나 even 값 규칙을 사용하지 않는다.
- 다음 derived 관계와 범위를 static assertion으로 검증한다.

  ```text
  GEMM_WEIGHT_DATA_SIZE % TMEM_BANK_BYTES == 0
  NUM_TMEM_BANKS % WEIGHT_BANKS_PER_BEAT == 0
  TMEM_WEIGHT_GROUP_SKEW < NUM_TMEM_BANKS / WEIGHT_BANKS_PER_BEAT
  weight_base % GEMM_WEIGHT_DATA_SIZE == 0
  ```

- buffer region end와 다음 region start가 겹치지 않는 static/runtime assertion을 둔다.
- 기본값은 모두 0으로 하여 기존 layout과 binary compatibility를 유지한다.
- 먼저 Input bank phase와 Weight group phase를 sweep하고 이후 qparam/output phase를
  조합한다.

## 3. LDMA ready-ahead와 urgency 생성

Input/Weight overlap executor에서 circular slot ring의 writer head부터 연속 READY slot을
계산한다. `drain_valid` beat는 별도의 staged beat로 포함한다.

- 계산값은 작은 saturating count로 제한한다.
- `valid && !ready` source request가 생기면 해당 request의 urgency를 handshake까지
  고정한다.
- Weight는 command/beat별 urgency를 wide-switch context에 저장한다.
- Priority 생성에는 현재 cycle의 `req_ready`를 사용하지 않아 combinational feedback을
  만들지 않는다.
- 초기 low watermark는 Input 4 beats, Weight 2 beats를 후보로 하되 parameter화한다.

## 4. TMEM 전용 priority sideband 추가

공용 memory interface flag 의미를 바꾸지 않고 TMEM subsystem 내부에 request priority를
전달한다.

- Input/Scale/ZP/Output switch는 selected-bank request와 priority를 함께 전달
- Weight wide switch는 context별 priority를 저장하고 모든 bank lane에 동일하게 전달
- tile DMA direct request는 초기에는 NORMAL, 이후 필요하면 별도 urgency 입력 추가
- request가 stall되는 동안 address/tag/data/priority가 모두 stable하도록 assertion 추가

## 5. Two-level fair arbiter 구현

`VX_tensor_mem_bank`의 기존 6:1 round-robin 앞에 priority mask 선택을 추가한다.

```text
eligible = urgent_valid != 0 ? request_valid & urgent : request_valid
winner   = round_robin(eligible)
```

- 기존 response tag routing은 변경하지 않는다.
- 동일 priority 안에서는 기존 round-robin 순서를 유지한다.
- starvation counter 또는 bounded consecutive-urgent rule을 추가한다.
- Weight pair lane이 서로 다른 priority class로 분리되지 않음을 assertion한다.
- priority logic이 SRAM request timing path를 악화시키는지 synthesis에서 확인한다.

## 6. Input/Weight scoped policy 연결

첫 integration에서는 Input과 Weight만 dynamic priority에 참여시킨다.

- Weight ready-ahead 부족 + writer 진행 가능 시 Weight URGENT
- Input ready-ahead 충분 또는 Input destination blocked 시 Input NORMAL
- 둘 다 부족하면 같은 class에서 round-robin
- qparam/tile DMA/output은 기존 fairness class 유지

이 단계의 FSDB에서 Weight-lost-to-Input가 감소하고 Input source bubble이 증가하지 않는지
확인한다. 성공 후에만 다른 requester로 policy를 일반화한다.

## 7. Parameter와 assertion 정리

- ready-ahead low watermark
- urgency enable
- skew offset
- maximum consecutive urgent grants 또는 starvation age

를 compile-time parameter로 제공한다. 기본 기능 configuration은 urgency와 skew를
disable해 기존 동작을 재현할 수 있어야 한다.

다음 assertion을 추가한다.

- held request의 priority/address/tag 안정성
- Weight context의 모든 bank lane priority 일치
- urgent/normal mask가 valid request 밖을 선택하지 않음
- bounded starvation 위반 없음
- slot lifecycle/count와 ready-ahead 계산 일치
- skewed address alignment와 buffer non-overlap
- command/response/destination ordering 불변

# 검증 계획

## 1. Static 및 compile 검증

- `git diff --check`
- target config를 source한 뒤 Verilator lint
- Input/Weight/Scale/ZP/Output/tile DMA interface width 및 tie-off audit
- priority path의 combinational loop/UNOPTFLAT audit
- Weight wide context에 priority bit가 정확히 저장되는지 width/tag audit
- Weight `GEMM_WEIGHT_DATA_SIZE`, 나머지 resource `TMEM_BANK_BYTES` alignment audit

## 2. TMEM bank arbiter directed unittest

독립 `VX_tensor_mem_bank` 또는 priority arbiter unittest에서 다음을 검증한다.

- urgent 1개와 normal 다수일 때 urgent 우선
- urgent 다수일 때 round-robin
- urgent가 없는 경우 기존 round-robin과 동일
- 지속적인 urgent traffic에서도 normal request가 bounded cycle 안에 progress
- response tag가 원 requester로 정확히 복귀
- request/response backpressure 중 winner와 payload 안정성
- reset 후 priority/age state와 stale response 정리

## 3. Weight wide-switch 및 LDMA unittest

- Weight `GEMM_WEIGHT_DATA_SIZE` request의 모든 bank lane에 동일 priority 전달
- 한 lane만 먼저 grant된 partial issue에서 context priority 유지
- out-of-order bank response에서도 wide response/tag/order 보존
- 8 outstanding context wraparound
- Input/Weight ready-ahead 0, 1, threshold-1, threshold, full case
- occupancy가 높지만 모두 WAIT_RSP인 경우 URGENT 판정
- occupancy가 낮아도 consecutive READY가 충분한 경우 NORMAL 판정
- held source request 중 slot state가 바뀌어도 priority가 변하지 않음
- writer fence와 WREG backpressure 기능 회귀 없음

기존 unittest도 재실행한다.

```text
hw/unittest/lmem_dma_input_overlap
hw/unittest/lmem_dma_weight_overlap
hw/unittest/lmem_dma_qparam_overlap
hw/unittest/tmem_wide_read_switch
hw/unittest/lmem_dma_misal
```

## 4. Allocation skew sweep

우선 priority를 disable한 상태에서 skew 효과만 분리해 측정한다.

```text
Input skew:  0 .. NUM_TMEM_BANKS-1 bank phases
Weight skew: 0 .. NUM_WEIGHT_BANK_GROUPS-1 wide-group phases
Scale/ZP/Output: baseline 후 필요한 bank-phase 조합만 추가

Current WLOAD8 example:
  Input offset:  0, 64, 128, ..., 448 B
  Weight offset: 0, 128, 256, 384 B
```

각 조합에서 다음을 수집한다.

- requester pair별 concurrent same-bank demand
- requester별 bank grant/loss
- Weight wide request partial-issue cycle
- Weight response inter-arrival gap
- Weight 4-beat write duration
- Input burst internal/boundary gap
- numerical correctness

고정 trace의 정적 overlap 추정이 아니라 실제 VCS timing에서 결과를 판정한다.

## 5. Node integration unittest

다음 matrix를 `gemm_node_improve`에서 실행한다.

```text
M = 4, 256
N = K = 256
QBLK = 32
QDIR = QCOL, QROW
WTRANS = 0
WLOAD = 8
```

- numerical output 일치
- command/packet/last admission/last write/done/scheduler retire count 일치
- W/S/Z exact generation mismatch 없음
- Input held-valid 안정성과 no loss/reorder
- starvation timeout 없음

## 6. XRT-VCS blackbox regression

Configured build에서 `ci/run_target_gemm.sh`의 xrt-vcs-sim flow를 사용한다.

- M=4/M=256 x QCOL/QROW 4개 조합
- baseline, skew-only, priority-only, skew+priority 비교
- exit status 0, numerical `PASSED`, functional Error/Fatal/timeout 없음
- Input/Weight/Output/ACC perf counter 회귀 없음

## 7. FSDB 성능 검증

M=4 QCOL을 먼저 분석하고 성공한 경우 QROW를 진행한다.

기준 FSDB와 동일한 방법으로 다음을 비교한다.

- Weight bank loss: baseline 112, 그중 Input 92
- Weight command duration: baseline 4-cycle command 25/64
- Weight command-internal bubble: baseline 71 cycles
- Input burst internal bubble: baseline 103 cycles
  - Weight readiness 99
  - Input source data 4
- slot occupancy와 `WAIT_RSP/READY/DRAINING` 분포
- ready-ahead low watermark 적중률
- requester별 starvation 최대 길이
- Weight consume/write와 exact-version readiness

Pass 기준은 steady-state에서 다음과 같다.

- Weight의 over-buffered Input에 대한 arbitration loss 제거 또는 거의 0
- 64개 Weight command 모두 4-beat continuous write, 별도 tile boundary는 분리 보고
- operand-ready Input burst의 모든 internal gap 0
- priority 때문에 새로 생긴 Input source bubble 또는 tile DMA starvation 0
- data loss, duplicate, reorder, stale version, unsafe overwrite 0

# Hard Rule

구현 중 현재 계획의 핵심 구조가 성립하지 않는 문제가 발견되면 즉시 중단하고 문제와
근거를 보고한다. 다음은 설계 blocker의 예이다.

- urgency 생성과 bank `req_ready` 사이에 끊을 수 없는 combinational cycle이 생김
- Weight wide context가 모든 bank lane의 stable priority를 보존할 수 없음
- bounded fairness를 적용해도 특정 requester starvation을 피할 수 없음
- derived resource skew가 Weight wide-beat alignment, bank-group mapping, 또는 TMEM
  buffer non-overlap을 깨뜨림
- priority가 Weight gap을 줄이는 대신 Input/tile DMA를 같은 수준 이상으로 악화시켜
  전체 zero-gap 목표를 달성할 수 없음
- 현재 8-bank physical service bandwidth가 policy 변경으로는 목표를 충족할 수 없음

Makefile, testbench race, interface tie-off, simulator compatibility, stale scoreboard처럼 설계
concept을 바꾸지 않는 명백한 구현/검증 오류는 Hard Rule blocker가 아니며 필요한 범위에서
수정할 수 있다.

# 구현 상태 (2026-08-16)

첫 RTL iteration은 위 contract에 따라 구현되었다.

- Input/Weight overlap executor가 staged drain beat와 `wr_expect_slot`부터의 연속
  `READY` prefix를 `ready_ahead`로 계산한다. `WAIT_RSP` occupancy는 제외된다.
- urgency는 `req_ready`를 참조하지 않으며 stalled source request 동안 latch된다.
- Weight wide-read context가 urgency를 저장하고 partial issue의 모든 bank lane에
  동일한 값을 전달한다.
- TMEM bank는 urgent/normal 두 class의 독립 RR cursor와 bounded
  consecutive-urgent budget을 사용한다.
  초기 dynamic participant는 Input/Weight이고 나머지 requester는 normal이다.
- `fi_gemm.c`의 resource base skew는 일반 resource에 64 B bank unit, Weight에
  derived `GEMM_WEIGHT_DATA_SIZE` group unit을 사용한다. 모든 기본 skew와 urgency
  enable은 0이라 기존 layout/arbitration을 보존한다.

Directed TB에는 ready-ahead threshold, WAIT_RSP exclusion, held urgency, Weight lane
priority consistency, urgent-over-normal, bounded normal progress coverage가 추가되었다.
VCS/blackbox/성능 판정은 verification phase에서 수행한다.

# 검증 결과 및 Hard Rule 판정 (2026-08-16)

## 기능 검증

- directed VCS unittest와 `gemm_node_improve`의 M=4/256 x QDIR=QCOL/QROW가 모두
  통과했다.
- XRT-VCS의 baseline, priority-only, 선택 skew-only, priority+skew 조합도 각
  M=4/256 x QDIR=QCOL/QROW에서 모두 numerical PASS했다.
- priority-only total cycle은 baseline 대비 다음과 같이 감소했다.

```text
             baseline  priority-only
M4 QCOL          635        609
M4 QROW          618        608
M256 QCOL      19425      17769
M256 QROW      19421      17769
```

모든 blackbox case에서 Input/Weight/Output stall counter, ACC underflow 및 conflict는
0이었다.

## Skew sweep 결과

Urgency를 끄고 Input 8 phase x Weight 4 group의 32개 조합을 실제 M4 QCOL
XRT-VCS로 실행했다. 전 조합은 수치적으로 통과했지만 최선은 635 cycle에서 633
cycle로 2 cycle(0.315%) 줄어든 것뿐이며 17개 조합이 동률이었다. 대표 후보
Input=0/Weight=1은 M4 QROW을 618에서 621 cycle로 악화시켰고 M256에는 이득이
없었다. 따라서 resource-aware skew 기능은 유지하되 기본값은 0으로 둔다.

## QCOL FSDB 결과

최선인 priority-only 설정을 기존 baseline과 같은 방식으로 비교했다.

```text
metric                              baseline  priority-only  target
Weight arbitration loss                 112       79         near 0
  caused by Input                         92       59         near 0
continuous 4-beat Weight command       25/64    34/64        64/64
Weight command internal bubbles          71       57          0
Input burst internal gaps                103      68          0 when operands ready
Input source-valid-low internal gaps       4       0          0
max Weight requester starvation            -       3 cycles   bounded
```

64개 Weight command와 256개 beat의 순서 및 각 command의 beat `0,1,2,3`은 모두
정확했다. 그러나 첫 command부터 write가 57,185,000 / 57,205,000 / 57,225,000 /
57,245,000 ps에 발생해 4 beat가 7 cycle에 걸렸고, 전체 64개 중 30개 command가
continuous하지 않았다.

즉 READY-ahead priority는 contention을 유의미하게 줄였지만 over-buffered Input이
Weight를 이기는 경우를 제거하지 못했다. `Input-caused loss=59`, `Weight bubble=57`이
남아 strict zero-gap 목표를 충족하지 못했으므로 Hard Rule에 따라 QCOL에서 중단했다.
QROW FSDB는 실행하지 않았으며 이 문서 범위에서 새로운 RTL concept은 추가하지 않는다.

FSDB artifact:

```text
build/run_logs/weight_tmem_arb_opt/fsdb_priority/
  20260816-051645_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d0_pid2144481/
  target_gemm.fsdb
```
