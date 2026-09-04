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
- 예를 들어 실제 descriptor의 `total_beats=4`인 Weight command에서 local watermark가 2이면
  절반만 준비된 시점에 normal로 돌아간다. 다른 tile shape에서는 이 beat 수도 달라진다.
- 다음 micro-tile의 S/Z가 missing이어도 Input/Weight local occupancy만으로는 이를 알 수
  없다.
- 이미 DMA slot에 fetch된 resource와 아직 TMEM response를 기다리는 resource를 같은
  `not ready`로 취급하면 불필요한 priority를 줄 수 있다.

ready-ahead는 새 scheduler에서도 유용한 local pressure 신호로 유지하되, 최종 priority를
단독으로 결정하지 않는다.

## Fetch readiness와 execution readiness를 혼동하면 안 됨

TMEM arbitration이 알아야 하는 readiness와 GEMM이 알아야 하는 readiness는 서로 다르다.

```text
fetch_ready(resource, work)
  = 그 work에 필요한 모든 source beat가 TMEM read를 끝내고 DMA slot에 도착했는가

execute_ready(resource, work)
  = DMA slot의 data가 target register generation으로 설치되어 GEMM이 사용할 수 있는가
```

예를 들어 다음 micro-tile의 Weight가 DMA slot에는 모두 도착했지만 WREG write를 기다리는
상태라면 다음과 같이 판단해야 한다.

```text
Weight fetch readiness     = ready
Weight execution readiness = not ready
```

이 Weight에는 더 이상 TMEM grant를 줄 이유가 없다. 이후 `DMA slot -> writer -> WREG` 경로는
해당 Weight의 TMEM bank grant와 독립적으로 진행한다. Scheduler는 아직 fetch되지 않은
Scale/ZP/Input에 TMEM bandwidth를 줘야 한다. Weight의 writer fence와 install 상태는 GEMM
실행 가능 여부와 성능 원인 분석을 위해 별도로 추적하지만, Weight source priority를 다시
올리는 근거로 사용하지 않는다.

실제 consumer에서 Weight missing을 발견한 뒤 P3를 주는 것도 이 상태에서는 효과가 없다.
이미 source request가 끝났기 때문이다. 따라서 consumer feedback은 다음과 같이 분기한다.

- `fetch_ready=0`: 남은 source request/lane을 P3로 올린다.
- `fetch_ready=1 && execute_ready=0`: TMEM priority를 올리지 않고 registered install 지연
  상태만 기록한다.
- `execute_ready=1`: resource blocker가 아니므로 다른 dependency를 선택한다.

Register write completion은 scheduler로 combinational forwarding하지 않는다. Scheduler의
TMEM 선택은 DMA descriptor/slot에서 직접 얻은 `fetch_ready`만으로 충분하다. Final register
write가 발생한 cycle에도 scheduler가 보는 execution state는 바뀌지 않으며, 기존 registered
load generation이 다음 cycle 갱신된 뒤에만 `execute_ready`로 본다.

따라서 두 종류의 forwarding을 모두 추가하지 않는다.

- WREG/SREG/ZREG write data를 GEMM consumer로 bypass하지 않는다.
- final register write completion을 scheduler effective-ready로 조합 전달하지 않는다.

이 선택은 현재 consumer의 한 cycle visibility stall을 숨기지는 않는다. 대신 잘못된 resource에
TMEM priority를 계속 주는 문제는 `fetch_ready`에서 이미 제거되므로, write-completion
forwarding 없이도 아직 DMA slot에 없는 다른 W/S/Z/Input을 선택할 수 있다.

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
  input_command_id
  resource_cmd[I/W/S/Z] = {
    command_id,
    total_beats,       // 실제 LDMA descriptor가 생성한 command별 값
    response_beats,
    writer_beats       // registered progress/debug; TMEM priority에는 사용하지 않음
  }
  w_bank, w_target_generation
  s_bank, s_target_generation
  z_bank, z_target_generation
  acc_group
  resource_consumer_offsets
```

Priority logic은 loop nesting 자체가 아니라 `work_seq`와 dependency를 사용한다. Loop 순서나
tile shape가 바뀌어도 FSM이 올바른 descriptor를 생성하면 같은 scheduler를 사용할 수 있다.

`total_beats`를 `4`, `WLOAD`, `QBLK` 또는 특정 tile 크기로 scheduler 안에 hardcode하면 안
된다. Input/Weight/Scale/ZP 각각의 실제 beat 수는 LDMA command의 bounds, segment size,
transfer size와 wide-lane 구성을 사용해 이미 계산된다. Scheduler는 이 결과를 command
enqueue 시 전달받아야 하며, 동일 계산을 별도로 복제하지 않는다.

```text
scheduler total_beats
  = LDMA descriptor의 authoritative command_total_beats

fetch_complete
  = response_beats == total_beats

install_complete
  = registered target_generation compare
```

마지막 partial tile, 다른 WLOAD/QBLK, 또는 resource별 서로 다른 전송 길이도 이 값만으로
동작해야 한다. Weight wide read에서는 logical command beat 수와 각 beat의 pending bank-lane
mask를 분리해서 추적한다.

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
INSTALLING
INSTALLED_READY
CONSUMING
```

이 구분이 중요한 이유는 다음과 같다.

- `NOT_FETCHED/INFLIGHT_WAIT_RSP`: TMEM service priority가 필요하다.
- `BUFFERED_IN_DMA/WAIT_WRITER_FENCE`: 데이터는 이미 있으므로 TMEM bandwidth를 더 줄
  필요가 없다. 실제 register write는 기존 writer fence가 제어한다.
- `INSTALLING`: writer가 DMA slot을 drain하고 있다. TMEM priority 대상이 아니다.
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

Scoreboard는 각 resource마다 다음 progress를 독립적으로 보존한다.

```text
request_beats  / total_beats
response_beats / total_beats
writer_beats   / total_beats
pending_wide_lane_mask[oldest logical beat]
writer_fence_released
target_generation_visible
```

`response_beats == total_beats`가 된 뒤에는 해당 resource의 source priority를 P0로 내린다.
Register가 아직 준비되지 않았다는 이유로 이미 완료된 TMEM fetch에 P3를 다시 주지 않는다.

## 3. Consumer distance와 slack

특정 K iteration 대신 micro-tile 실행 거리와 resource consumer offset을 사용한다.

```text
consumer_distance(resource, work)
  = distance_to_work_seq(work)
  + resource_consumer_stage_offset

slack(resource)
  = estimated_cycles_until_consume
  - estimated_fetch_cycles
```

TMEM arbitration의 예상 시간은 fetch에만 적용한다.

```text
estimated_fetch_cycles
  = outstanding request/response beats와 wide missing lanes의 예상 TMEM service
```

`estimated_fetch_cycles=0`인 resource는 register 설치 여부와 무관하게 TMEM arbitration
후보에서 제외한다. Install progress는 registered 상태로 관찰하고 GEMM backpressure 및
성능 counter에 사용하지만, source priority나 같은 cycle Input budget을 조합 변경하지 않는다.

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

P3도 source fetch가 남아 있는 경우에만 TMEM request에 적용한다. Consumer block event가
왔지만 해당 resource의 모든 response beat가 DMA slot에 있다면 P3 source request를 만들지
않고 `fetched_but_not_installed` event와 deadline miss counter를 남긴다.

Weight wide request는 oldest writer-head beat의 마지막 missing bank lane이 완료되면 slot
전체가 `READY`가 되므로 해당 lane에도 completion bonus를 준다.

## 5. Input prefetch budget

W/S/Z가 아직 준비되지 않았다는 이유로 Input을 완전히 막지 않는다. GEMM unit의 elastic
pre-process capacity와 Input DMA slot을 활용할 수 있기 때문이다. 대신 earliest work의
operand 상태에 따라 Input이 앞서갈 수 있는 양을 제한한다.

```text
earliest W/S/Z registered-installed       -> large Input ahead budget
earliest W/S/Z fetch-complete in DMA slot -> medium bounded Input ahead budget
earliest W/S/Z fetch incomplete/critical  -> small Input ahead budget
actual current Input starvation           -> current Input P3
```

Input budget은 다음 credit의 최솟값으로 제한한다.

- Input DMA free response slots
- GEMM pre-process elastic capacity
- tree-boundary/post-process credit
- earliest unresolved operand까지 안전하게 보관할 수 있는 transaction 수

이렇게 하면 Input을 미리 가져오는 장점은 유지하면서, W/S/Z가 없는 상태에서 Input만 TMEM
bandwidth와 pipeline capacity를 모두 점유하는 것을 방지한다.

DMA slot에 operand가 모두 있는데 register write만 남은 경우에는 Input과 writer가 서로 다른
경로에서 병렬로 진행할 수 있으므로 medium budget을 허용한다. Large budget은 registered
target generation compare가 이미 성공한 경우에만 허용한다. Final write completion wire로 같은
cycle medium에서 large로 전환하지 않는다. Response가 아직 부족하면 small budget으로 missing
operand fetch를 우선한다.

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
7. fetch가 남아 있으면 다음 cycle부터 missing Weight request/lane을 P3로 승격
8. 이미 DMA slot에 모두 있으면 source P3 대신 `fetched_but_not_installed`로 분류
9. TMEM response -> DMA slot -> writer fence -> WREG write 완료
10. registered load generation이 target에 도달한 다음 cycle ready=1
11. 보존된 Input이 정확히 한 번 consumer handshake
```

Scale/ZP도 각자의 실제 consumer 위치에서 동일하게 동작한다.

### W/S/Z가 DMA slot에는 있지만 register write가 막힌 경우

이 상태는 `WAIT_WRITER_FENCE`다. Micro-tile은 아직 architectural ready가 아니므로 GEMM
consumer는 필요하면 stall한다. 하지만 TMEM fetch는 완료됐으므로 같은 resource에 추가
TMEM priority를 주지 않는다. Scheduler는 다른 missing resource나 Input을 처리하면서
registered `writer_beats/total_beats`, fence 상태, target generation을 관찰용 상태로만 갱신한다.
Final register write completion을 조합 입력으로 받아 priority나 Input budget을 같은 cycle에
바꾸지 않는다.

Writer 경로에 별도 arbitration이 존재한다면 earliest deadline의 buffered resource를 먼저
install할 수 있지만, TMEM bank priority와 writer priority는 서로 다른 제어로 유지한다.
현재처럼 W/S/Z writer가 독립 포트이고 ordered drain이라면 source scheduler는 writer 순서를
억지로 바꾸지 않고 더 일찍 fetch를 완료하도록 deadline을 잡는다.

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
combinational하게 볼 수 있지만, 여기서 exact state란 register에 저장된 generation state다.
같은 cycle의 final register write fire를 scheduler나 GEMM ready에 bypass하지 않는다.

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
- W/S/Z bank와 exact target generation, 각 I/W/S/Z LDMA command 연결
- 각 command의 `total_beats`는 LDMA descriptor가 계산한 authoritative 값을 enqueue metadata로 전달
- Scheduler 내부에서 `4`, WLOAD, QBLK 또는 tile dimension으로 beat 수를 재계산하거나 hardcode하지 않음
- logical beat와 Weight wide bank-lane mask를 구분
- QDIR별 consumer-stage offset 정의
- micro-tile retire와 descriptor pop이 정확히 일치하도록 assertion 추가

## 2. Readiness scoreboard 추가

- 4-entry bounded lookahead로 시작
- resource별 fetch/install/consume 상태와 request/response/writer progress counter 분리
- existing LDMA command, response slot, register write, consume event로 상태 갱신
- `response_beats == total_beats`에서만 `BUFFERED_IN_DMA`로 전이
- registered target generation compare가 성공할 때만 `INSTALLED_READY`로 전이
- writer progress는 install 상태 검증용이며 source priority 계산에서는 제외
- partial tile과 command별 서로 다른 total-beat 값을 entry마다 보존
- 동일 generation을 여러 upcoming work가 재사용하는 경우 reference/fanout 계산

## 3. Fetch policy와 install tracking 분리

- TMEM priority는 `NOT_FETCHED/INFLIGHT_WAIT_RSP` resource에만 생성
- `BUFFERED_IN_DMA/WAIT_WRITER_FENCE/INSTALLING` resource는 source priority 후보에서 제거
- remaining response beats와 Weight missing-lane mask로 fetch ETA 계산
- writer progress/fence/registered target generation은 stall 원인과 residence-time 측정에만 사용
- buffered operand의 consumer block은 P3 source request가 아니라
  `fetched_but_not_installed` event로 기록
- final register write completion forwarding 및 scheduler effective-ready logic을 추가하지 않음
- source priority와 register writer progress 사이에 combinational path를 만들지 않음

## 4. GEMM backpressure feedback 추가

- 실제 W/S/Z consumer의 `valid && !ready && generation_missing` event 생성
- event에 `work_seq/resource/bank/target` 포함
- event가 발생한 resource의 fetch/install 상태를 함께 snapshot
- scheduler 입력에서 반드시 1-cycle register
- fetch가 남아 있을 때만 P3 source priority, fetch가 끝났으면
  `fetched_but_not_installed` accounting
- stall 중 transaction과 metadata 안정성 assertion 유지

## 5. Input ahead budget 구현

- Input DMA ready-ahead와 response slot credit 연결
- GEMM pre-process 및 tree-boundary credit 반영
- earliest micro-tile의 fetch 상태와 registered install 상태에 따라 small/medium/large budget 선택
- fetch-complete지만 registered install 전이면 medium, registered install 뒤에만 large budget 허용
- final write fire가 같은 cycle budget을 변경하지 않는지 assertion 추가
- current Input starvation은 operand prefetch와 별도로 P3 처리

## 6. 2~3-bit priority sideband

- 기존 1-bit urgency를 priority tier로 확장
- Input/Weight/Scale/ZP request 모두 micro-tile priority 생성
- tile/output/general DMA는 기존 age/fairness class 유지
- 동일 priority에서 기존 RR 보존

## 7. Descriptor 길이 기반 completion 및 Weight lane bonus

- request 완료가 earliest micro-tile의 last missing dependency인지 판정
- `response_beats + 1 == total_beats`인 실제 마지막 response에 completion bonus 적용
- Weight oldest logical beat의 remaining lane mask 추적
- 마지막 missing lane에 completion bonus 적용
- wide request의 다른 lane이 완료된 상태에서 unrelated Input이 반복적으로 이기지 않도록 검증

## 8. Optional per-bank descriptor queue

- 첫 fixed-priority 실험 결과 후 필요성을 판단
- queue entry가 bank valid로 선택되기 전까지 priority 재평가 허용
- 선택 후 stall 중에는 payload/priority 안정성 보장
- queue full/backpressure 및 reset/flush contract 정의

## 9. Debug 및 perf probe

- micro-tile work_seq와 missing mask
- command별 total/request/response/writer beat 수와 resource state transition
- fetch ETA와 registered install-state residence time
- priority tier와 선택 이유
- registered consumer blocker feedback
- consumer feedback의 `fetch_missing`/`fetched_but_not_installed` 분류
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
- I/W/S/Z command별 `total_beats`가 서로 다른 경우에도 last-response/completion 판정 정확
- 1 beat, 2 beats, slot depth보다 작은/같은/큰 command와 partial final command를 포함
- scheduler decision에 literal `4` 또는 고정 WLOAD/QBLK beat 수가 사용되지 않음을 lint/assertion으로 확인

## 2. Backpressure 상호작용 unittest

- Input이 먼저 도착하고 W가 늦으면 Weight consumer에서만 stall
- Scale/ZP가 늦으면 QDIR별 실제 consumer에서만 stall
- stall 중 Input data/control/work_seq/target generation 안정
- consumer block event가 정확히 다음 cycle 반영되며, fetch가 남은 경우에만 P3가 됨
- load generation 설치 다음 cycle ready가 올라가고 transaction이 정확히 한 번 진행
- TMEM priority와 GEMM ready 사이 combinational loop/UNOPTFLAT 없음
- final register write fire가 같은 cycle scheduler priority/Input budget/GEMM ready를 바꾸지 않음

## 3. Fetch/install 상태 검증

- `WAIT_RSP`와 `BUFFERED_IN_DMA`를 구분
- request/response/writer counter가 descriptor의 `total_beats`와 정확히 일치
- 일부 beat만 DMA slot에 있을 때 fetch가 완료됐다고 판정하지 않음
- data가 DMA slot에 있으면 register가 아직 fenced여도 추가 TMEM fetch priority를 주지 않음
- buffered consumer miss가 source P3가 아니라 `fetched_but_not_installed`로 분류됨
- final register write와 registered target-generation visibility가 한 cycle 경계로 분리됨
- write-data bypass와 write-completion-to-scheduler forwarding이 모두 없는지 hierarchy/lint로 확인
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

기본 성능 비교는 위 설정을 사용하되 descriptor-length correctness는 이 한 조합만으로
판정하지 않는다. 최소한 다음 변형을 directed/node test에 포함한다.

- M/N/K 마지막 partial tile이 생기는 크기
- 서로 다른 QBLK
- 지원되는 여러 WLOAD
- resource command가 1 beat, multi-beat, response-slot depth 경계를 넘는 경우

각 case의 expected beat 수는 testbench 상수로 복사하지 않고 DUT가 enqueue한 descriptor의
`total_beats` 또는 독립 reference descriptor 계산과 비교한다.

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
- Input command별 descriptor-derived beat interval과 command boundary gap
- Weight command별 descriptor-derived register write interval과 command boundary gap
- total/request/response/writer beats, fetch ETA 오차, registered install residence time
- requester별 bank loss와 starvation 최대 길이
- scheduler prediction miss 후 backpressure stall 길이

성공 기준은 다음과 같다.

- operand-ready micro-tile의 Input command에서 descriptor가 요구한 모든 consecutive beat의 internal gap 0
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
- scheduler가 특정 tile/WLOAD/QBLK의 고정 beat 수를 가정해 descriptor와 progress가 달라짐
- final register write completion이 scheduler priority/Input budget/GEMM ready로 조합 연결됨
- priority가 earliest micro-tile latency를 줄이지만 current work 또는 일반 DMA starvation을 만듦

Makefile, testbench race, simulator syntax, stale scoreboard처럼 concept을 바꾸지 않는 명백한
구현/검증 오류는 Hard Rule blocker가 아니며 필요한 범위에서 수정할 수 있다.
