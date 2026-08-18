# 문제점

현재 TMEM arbitration은 각 DMA의 local response 상태만 보고 Input 또는 Weight request를
urgent/normal로 분류한다. 이 방식은 해당 DMA가 비어 가는지는 알 수 있지만, 그 데이터가
어떤 GEMM micro-tile에 필요하며 다른 dependency가 함께 준비됐는지는 알지 못한다.

GEMM은 M/N/K/QBLK 등의 nested loop를 micro-tile 실행 순서로 변환한다. 각 micro-tile은
Input, Weight, Scale, Zero-point와 ACC resource가 함께 준비돼야 실행할 수 있다. 예를
들어 다음 micro-tile의 Input을 많이 읽어 둬도 필요한 Weight generation이 준비되지
않으면 Input은 GEMM unit의 Weight consumer에서 멈춘다. 반대로 현재 micro-tile 실행이
아직 오래 남았다면 Weight만 고정 우선하는 것도 Input starvation과 낮은 TMEM 이용률을
만든다.

따라서 priority는 특정 K loop나 단일 DMA occupancy가 아니라 다음 정보를 함께 사용해야
한다.

- 실제 micro-tile 실행 순서
- 각 micro-tile이 요구하는 I/W/S/Z bank와 generation
- resource data가 TMEM에서 fetch됐는지, DMA slot에 있는지, register에 설치됐는지
- 현재 micro-tile의 남은 실행 거리와 resource별 실제 consumer 위치
- 하나의 resource generation을 재사용하는 upcoming micro-tile 수
- GEMM unit에서 실제로 발생한 consumer backpressure 원인

## Ready-ahead 방식의 한계

기존 ready-ahead는 response slot occupancy가 아니라 writer head부터 연속된 `READY` beat를
사용하므로 local 지표 자체는 올바르다. 하지만 다음 한계가 있다.

- Input과 Weight가 동시에 urgent면 같은 class의 round-robin으로 경쟁한다.
- Weight가 아직 writer fence에 막혀 있으면 TMEM source prefetch도 normal priority가 된다.
- Weight command가 4 beats여도 local watermark가 2이면 절반만 준비된 시점에 normal로
  돌아간다.
- 다음 micro-tile의 S/Z가 missing이어도 Input/Weight local occupancy만으로는 이를 알 수
  없다.
- 이미 DMA slot에 fetch된 resource와 아직 TMEM response를 기다리는 resource를 같은
  `not ready`로 취급하면 불필요한 priority를 줄 수 있다.

ready-ahead는 새 scheduler에서도 유용한 local pressure 신호로 유지하되, 최종 priority를
단독으로 결정하지 않는다.

## GEMM unit backpressure와의 관계

Micro-tile scheduler와 GEMM unit backpressure는 서로 대체하는 기능이 아니다.

```text
Micro-tile scheduler
  = 앞으로 어떤 TMEM request를 먼저 처리할지 결정하는 proactive performance policy

GEMM unit ready/backpressure
  = 이미 pipeline에 들어온 transaction이 실제 consumer에서 안전하게 진행 가능한지
    검사하는 reactive correctness fence
```

Scheduler의 예측이 정확하면 W/S/Z가 consumer 도착 전에 준비되어 ready가 계속 1이다.
예측이 늦거나 bank conflict가 예상보다 길면 GEMM unit이 해당 consumer에서 ready를 0으로
내리고 Input transaction을 보존한다. 따라서 scheduler 오류나 timing 편차가 data corruption으로
이어지지 않는다.

반대로 GEMM ready를 scheduler의 예측 결과로 직접 구동해서는 안 된다. GEMM ready는 항상
실제 target generation, FIFO capacity, ACC ownership을 보고 결정해야 한다. Scheduler의
priority는 성능 hint이고 GEMM ready가 correctness의 최종 authority다.

# 해결책

## 1. Micro-tile work sequence

FSM이 실제로 실행할 각 micro-tile에 단조 증가하는 `work_seq`를 부여한다.

```text
microtile_descriptor:
  work_seq
  coordinates = {m_tile, n_tile, k_tile, qblk, ...}  // debug/reuse 분석용
  input_command_id, input_required_beats
  w_bank, w_target_generation
  s_bank, s_target_generation
  z_bank, z_target_generation
  acc_group
  resource_consumer_offsets
```

Priority logic은 loop nesting 자체가 아니라 `work_seq`와 dependency를 사용한다. Loop 순서나
tile shape가 바뀌어도 FSM이 올바른 descriptor를 생성하면 같은 scheduler를 사용할 수 있다.

## 2. Bounded lookahead readiness scoreboard

Controller 또는 GEMM node에 upcoming micro-tile 4개 정도를 저장하는 bounded scoreboard를
둔다.

```text
entry[0] = executing/earliest work
entry[1] = next work
entry[2] = next+1 work
entry[3] = next+2 work
```

각 resource 상태는 최소한 다음 단계로 구분한다.

```text
NOT_FETCHED
INFLIGHT_WAIT_RSP
BUFFERED_IN_DMA
WAIT_WRITER_FENCE
INSTALLED_READY
CONSUMING
```

이 구분이 중요한 이유는 다음과 같다.

- `NOT_FETCHED/INFLIGHT_WAIT_RSP`: TMEM service priority가 필요하다.
- `BUFFERED_IN_DMA/WAIT_WRITER_FENCE`: 데이터는 이미 있으므로 TMEM bandwidth를 더 줄
  필요가 없다. 실제 register write는 기존 writer fence가 제어한다.
- `INSTALLED_READY`: target generation compare가 성공하므로 consumer가 진행할 수 있다.
- `CONSUMING`: overwrite는 기존 consume event까지 금지한다.

Micro-tile의 architectural readiness는 다음과 같이 계산한다.

```text
microtile_ready = input_available_for_launch
               && w_target_installed
               && s_target_installed
               && z_target_installed
               && acc_resource_available
```

다만 Input이 W/S/Z보다 먼저 pre-process에 들어가는 것은 허용한다. 이 readiness는
"Input을 pipeline에 한 beat도 넣지 말라"는 gate가 아니라 scheduler가 향후 bandwidth를
배분하기 위한 상태다.

## 3. Consumer distance와 slack

특정 K iteration 대신 micro-tile 실행 거리와 resource consumer offset을 사용한다.

```text
consumer_distance(resource, work)
  = distance_to_work_seq(work)
  + resource_consumer_stage_offset

slack(resource)
  = estimated_cycles_until_consume
  - estimated_remaining_service
```

정확한 cycle predictor가 부담되면 다음 bucket으로 단순화한다.

```text
FAR  : current/earlier work가 충분히 남아 있음
NEAR : lookahead 안에서 곧 consumer에 도착
DUE  : 실제 consumer stall 또는 다음 launch가 불가능한 상태
```

QDIR별 consumer offset을 반영한다.

- QROW Scale: input scaler
- Weight: GEMM tree launch
- QROW ZP: compute launch 부근
- QCOL ZP: reduce consumer
- QCOL Scale: post-process scaler

따라서 `W > S > Z`는 항상 적용하는 고정 순서가 아니라 같은 deadline과 completion 효과를
가진 경우의 tie-break로만 사용한다.

## 4. Priority key

복잡한 가산 점수보다 hardware-friendly한 lexicographic key를 사용한다.

```text
priority_key = {
  blocks_current_work,
  completes_earliest_work,
  deadline_bucket,
  completion_bonus,
  reuse_fanout_bucket,
  age
}
```

권장 priority tier는 다음과 같다.

```text
P3: 현재 GEMM consumer stall을 직접 해소하는 request
P2: earliest non-ready micro-tile을 runnable로 만드는 request
P1: lookahead window 안에서 slack이 작은 prefetch
P0: background prefetch 및 일반 round-robin traffic
```

같은 tier에서는 age와 round-robin으로 starvation을 방지한다. Scale/ZP처럼 전송량은
작지만 마지막 한 beat가 전체 bundle을 완성하는 request에는 `completion_bonus`를 준다.

Weight wide request는 oldest writer-head beat의 마지막 missing bank lane이 완료되면 slot
전체가 `READY`가 되므로 해당 lane에도 completion bonus를 준다.

## 5. Input prefetch budget

W/S/Z가 아직 준비되지 않았다는 이유로 Input을 완전히 막지 않는다. GEMM unit의 elastic
pre-process capacity와 Input DMA slot을 활용할 수 있기 때문이다. 대신 earliest work의
operand 상태에 따라 Input이 앞서갈 수 있는 양을 제한한다.

```text
earliest W/S/Z installed                 -> large Input ahead budget
earliest W/S/Z buffered, write 예정      -> medium Input ahead budget
earliest W/S/Z TMEM response 부족/critical -> small Input ahead budget
actual current Input starvation          -> current Input P3
```

Input budget은 다음 credit의 최솟값으로 제한한다.

- Input DMA free response slots
- GEMM pre-process elastic capacity
- tree-boundary/post-process credit
- earliest unresolved operand까지 안전하게 보관할 수 있는 transaction 수

이렇게 하면 Input을 미리 가져오는 장점은 유지하면서, W/S/Z가 없는 상태에서 Input만 TMEM
bandwidth와 pipeline capacity를 모두 점유하는 것을 방지한다.

## 6. Backpressure interaction contract

### 정상 예측

```text
1. Scheduler가 upcoming work의 missing W/S/Z를 먼저 fetch
2. writer fence가 안전해지면 W/S/Z register에 target generation 설치
3. Input이 pre-process와 consumer를 bubble 없이 통과
4. GEMM ready는 계속 1
```

### Input이 먼저 도착하고 Weight가 늦은 경우

```text
1. Input은 available credit 범위에서 pre-process에 admission
2. transaction과 {work_seq, W/S/Z bank, target generation} metadata가 함께 이동
3. Weight consumer 직전에서 actual W generation compare 실패
4. 해당 elastic stage의 ready=0
5. Input data/control/metadata는 valid 상태로 안정적으로 유지
6. `weight_consumer_blocked(work_seq)`를 register해 scheduler에 feedback
7. 다음 cycle부터 missing Weight request/lane을 P3로 승격
8. TMEM response -> DMA slot -> writer fence -> WREG write 완료
9. registered load generation이 target에 도달한 다음 cycle ready=1
10. 보존된 Input이 정확히 한 번 consumer handshake
```

Scale/ZP도 각자의 실제 consumer 위치에서 동일하게 동작한다.

### W/S/Z가 DMA slot에는 있지만 register write가 막힌 경우

이 상태는 `WAIT_WRITER_FENCE`다. Micro-tile은 아직 architectural ready가 아니므로 GEMM
consumer는 필요하면 stall한다. 하지만 TMEM fetch는 완료됐으므로 같은 resource에 추가
TMEM priority를 주지 않는다. Scheduler는 다른 missing resource나 Input을 처리한다.

### 모든 W/S/Z가 준비된 경우

Earliest work를 시작하는 데 남은 bottleneck이 Input이므로 해당 Input command를 P2/P3로
올린다. 이 상태에서 Input DMA와 GEMM pre-process가 back-to-back admission을 유지하는 것이
목표다.

## 7. Feedback는 반드시 registered

다음 combinational loop를 만들면 안 된다.

```text
TMEM grant
 -> W/S/Z register write
 -> GEMM consumer ready
 -> Input fire/stall
 -> scheduler priority
 -> TMEM grant
```

GEMM unit은 다음 event를 FF에 잡아 controller/scheduler로 전달한다.

```text
consumer_block_event = {
  valid,
  work_seq,
  resource,
  bank,
  target_generation
}
```

Scheduler는 이 event를 다음 cycle priority에 반영한다. GEMM ready 자체는 local exact state를
combinational하게 볼 수 있지만 TMEM priority로 직접 되돌리지 않는다.

## 8. Request queue와 priority 안정성

현재 TMEM request는 `valid && !ready` 동안 priority sideband까지 안정적이어야 한다. 이미
bank interface에 제시된 request의 priority를 deadline 변화에 따라 수정하면 protocol을
위반한다.

동적 재평가가 필요하면 TMEM bank 앞에 작은 descriptor queue를 둔다.

```text
LDMA producer handshake
  -> descriptor queue에 request 저장
  -> queue 내부 request의 priority를 readiness scoreboard로 재평가
  -> selected descriptor만 bank valid로 제시
  -> bank valid가 올라간 뒤에는 payload/priority 고정
```

Weight wide context에는 `work_seq`, resource target, remaining lane mask를 저장한다. Queue가
없는 첫 실험에서는 request 생성 시점의 2~3-bit priority를 latch하고, 효과가 확인된 뒤
동적 queue scheduling으로 확장한다.

# 구현 계획

## 1. Micro-tile descriptor 정의

- FSM이 실제 ARM/Input command 순서에 맞춰 `work_seq` 생성
- W/S/Z bank와 exact target generation, Input command/beat 수 연결
- QDIR별 consumer-stage offset 정의
- micro-tile retire와 descriptor pop이 정확히 일치하도록 assertion 추가

## 2. Readiness scoreboard 추가

- 4-entry bounded lookahead로 시작
- resource별 fetch/install/consume 상태 분리
- existing LDMA command, response slot, register write, consume event로 상태 갱신
- 동일 generation을 여러 upcoming work가 재사용하는 경우 reference/fanout 계산

## 3. GEMM backpressure feedback 추가

- 실제 W/S/Z consumer의 `valid && !ready && generation_missing` event 생성
- event에 `work_seq/resource/bank/target` 포함
- scheduler 입력에서 반드시 1-cycle register
- stall 중 transaction과 metadata 안정성 assertion 유지

## 4. Input ahead budget 구현

- Input DMA ready-ahead와 response slot credit 연결
- GEMM pre-process 및 tree-boundary credit 반영
- earliest micro-tile operand 상태에 따라 small/medium/large budget 선택
- current Input starvation은 operand prefetch와 별도로 P3 처리

## 5. 2~3-bit priority sideband

- 기존 1-bit urgency를 priority tier로 확장
- Input/Weight/Scale/ZP request 모두 micro-tile priority 생성
- tile/output/general DMA는 기존 age/fairness class 유지
- 동일 priority에서 기존 RR 보존

## 6. Bundle completion 및 Weight lane bonus

- request 완료가 earliest micro-tile의 last missing dependency인지 판정
- Weight oldest beat의 remaining lane 수 추적
- 마지막 missing lane에 completion bonus 적용
- wide request의 다른 lane이 완료된 상태에서 unrelated Input이 반복적으로 이기지 않도록 검증

## 7. Optional per-bank descriptor queue

- 첫 fixed-priority 실험 결과 후 필요성을 판단
- queue entry가 bank valid로 선택되기 전까지 priority 재평가 허용
- 선택 후 stall 중에는 payload/priority 안정성 보장
- queue full/backpressure 및 reset/flush contract 정의

## 8. Debug 및 perf probe

- micro-tile work_seq와 missing mask
- resource state transition
- priority tier와 선택 이유
- registered consumer blocker feedback
- Input ahead budget/사용량
- requester별 grant/loss와 earliest-work completion latency

# 검증 계획

## 1. Scheduler directed unittest

- earliest work에서 W만 missing이면 먼 work의 Input보다 W 우선
- earliest work에서 S/Z 한 beat가 bundle을 완성하면 completion bonus 적용
- W가 크지만 S/Z last beat가 더 urgent한 경우 deadline 기준 선택
- 모든 operand가 ready면 earliest Input 우선
- current Input starvation이면 future W/S/Z보다 current Input 우선
- 동일 generation의 reuse fanout은 deadline보다 낮은 tie-break로만 사용
- 같은 tier의 persistent requester가 bounded time 안에 progress

## 2. Backpressure 상호작용 unittest

- Input이 먼저 도착하고 W가 늦으면 Weight consumer에서만 stall
- Scale/ZP가 늦으면 QDIR별 실제 consumer에서만 stall
- stall 중 Input data/control/work_seq/target generation 안정
- consumer block event가 정확히 다음 cycle scheduler P3로 반영
- load generation 설치 다음 cycle ready가 올라가고 transaction이 정확히 한 번 진행
- TMEM priority와 GEMM ready 사이 combinational loop/UNOPTFLAT 없음

## 3. Fetch/install 상태 검증

- `WAIT_RSP`와 `BUFFERED_IN_DMA`를 구분
- data가 DMA slot에 있으면 register가 아직 fenced여도 추가 TMEM fetch priority를 주지 않음
- writer fence 이전 overwrite 없음
- final old-version consumer와 new register write의 기존 same-cycle contract 보존
- loss/duplicate/reorder/stale generation 없음

## 4. Multi-micro-tile lookahead

- 서로 다른 M/N/K/QBLK coordinate가 섞인 4-entry window
- loop nesting을 바꿔도 `work_seq` 순서 기준으로 동일한 decision
- earliest tile을 건너뛰어 먼 tile만 준비하는 starvation 없음
- descriptor wrap, full, pop/push same-cycle, reset flush

## 5. Node 및 XRT-VCS

```text
M = 4, 256
N = K = 256
QBLK = 32
QDIR = QCOL, QROW
WTRANS = 0
WLOAD = 8
```

- numerical output 일치
- command/packet/consumer/done/scheduler retire count 일치
- current and upcoming micro-tile dependency trace 일치
- Input held-valid와 consumer stall/resume 안정성
- ACC forwarding 및 post-process backpressure 회귀 없음

## 6. FSDB 성능 판정

- earliest micro-tile이 runnable하지 않은 총 cycle과 blocker별 분류
- Input over-prefetch로 W/S/Z가 늦어진 cycle
- W/S/Z는 준비됐지만 Input이 없어 생긴 cycle
- `WAIT_RSP`, `BUFFERED`, `WAIT_WRITER_FENCE`, `INSTALLED` residence time
- Weight wide oldest-beat missing-lane latency
- Input 4-beat internal/boundary gap
- Weight 4-beat register write gap
- requester별 bank loss와 starvation 최대 길이
- scheduler prediction miss 후 backpressure stall 길이

성공 기준은 다음과 같다.

- operand-ready micro-tile의 Input burst internal gap 0
- upcoming micro-tile의 W/S/Z가 consumer deadline 전에 설치
- Input을 불필요하게 선행 fetch해 earliest work를 늦추는 arbitration loss 거의 0
- actual consumer stall이 발생해도 loss 없이 bounded recovery
- current Input starvation, tile/output DMA starvation 없음
- data loss, duplicate, reorder, stale version, unsafe overwrite 0

# Hard Rule

다음 문제가 구조적으로 발생하면 즉시 중단하고 설계를 다시 논의한다.

- scheduler priority와 GEMM ready 사이에 끊을 수 없는 combinational loop가 생김
- bounded scoreboard로 실제 micro-tile dependency/lifetime을 표현할 수 없음
- Input ahead budget이 tree/post-process의 실제 capacity를 안전하게 bound하지 못함
- request priority 재평가가 `valid && !ready` 안정성 contract를 위반함
- resource generation reuse/reference를 추적하지 못해 overwrite safety가 깨짐
- priority가 earliest micro-tile latency를 줄이지만 current work 또는 일반 DMA starvation을 만듦

Makefile, testbench race, simulator syntax, stale scoreboard처럼 concept을 바꾸지 않는 명백한
구현/검증 오류는 Hard Rule blocker가 아니며 필요한 범위에서 수정할 수 있다.
