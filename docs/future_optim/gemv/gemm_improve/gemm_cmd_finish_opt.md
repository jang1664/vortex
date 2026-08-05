# GEMM input command completion 최적화

## 1. 결론

기존 분석의 핵심은 맞다. 현재 `OP_I_LDMA_ARM` command는 마지막 input packet이
GEMM unit에 들어간 시점이 아니라, 그 packet의 결과가 ACC MEM에 writeback되는
시점까지 child command를 점유한다. 현재 설정에서 이 차이는 15 cycle이며,
NOTIFY와 sync register update까지 포함하면 마지막 input admission 이후 19 cycle이
지나야 `RID_G0/RID_G1` WAIT가 풀린다.

다만 해결책은 다음 네 가지 점에서 보완해야 한다.

1. 현재 controller는 `input_read_flag.done`을 command 완료 조건으로 사용하지 않는다.
   child command 완료는 `input_read_flag.idle`이 busy를 거쳐 다시 1이 되는 것으로
   간접 판단한다. 따라서 done signal 두 개를 추가하는 것만으로 scheduling은 바뀌지
   않는다.
2. 같은 ACC address를 읽는 다음 command라고 해서 항상 `writeback_done`까지 기다릴
   필요는 없다. 정확한 조건은 두 packet의 admission cycle 거리 `d`이다. 현재 latency에서
   `d=1`은 forwarding, `d>=3`은 최신 ACC MEM read로 안전하고, 정확히 `d=2`만 현재
   forwarding이 커버하지 못하는 RAW hazard다.
3. command completion과 다음 input command를 받을 수 있는 상태는 같은 개념이
   아니다. 마지막 input admission 직후에도 local DMA는 현재 파형에서 4~5 cycle 더
   active하다. 또한 단일 `input_cmd_ctx_r`는 현재 `last_write`까지 유지되므로 이를
   그대로 조기 해제하면 back-to-back command와 이전 command의 `last_write`를 구분할
   수 없다.
4. 현재 M=4 파형에서는 local DMA의 route gap만으로 동일 주소 재입력이 안전 구간에
   들어간다. 그러나 이 사실은 아직 RTL contract나 unittest로 고정되어 있지 않다.
   completion 최적화보다 먼저 `d=1/2/3` 경계를 assertion과 directed test로 고정해야 한다.

따라서 completion을 다음 세 의미로 분리해야 한다.

- `ingress_done`: 마지막 input packet이 GEMM input에 admission된 시점
- `writeback_done`: 해당 command의 마지막 ACC MEM write가 완료된 시점
- `route_ready`: input LDMA/context가 다음 input command를 실제로 받을 수 있는 시점

`ingress_done`과 `writeback_done`은 dependency completion event이고,
`route_ready`는 command issue backpressure이다.

## 2. 분석 범위

### 2.1 사용한 FSDB

주 분석 파형:

```text
build/run_logs/target_gemm/
  20260804-170403_fsdb-gemm_m4_n32_k32_q32_t0_d1_pid3870929/
  target_gemm.fsdb
```

- workload: `M=4, N=32, K=32, QBLK=32, WTRANS=0, QDIR=1`
- configuration: `GEMM_IMPROVE`, `MXU_WLOAD_NUM=8`
- clock: 10 ns/cycle
- FSDB 범위: `0 .. 72.510 us`
- 상태: 정상 종료

다음 파일도 확인했다.

```text
build/sim/xrtsim_vcs/vcs_cosim.fsdb
```

이 파일에는 한 번의 input command와 last admission까지만 있고 `last_write`가 기록되지
않아 command finish latency의 정량 근거로 사용하지 않았다. 아래 수치는 정상 종료한
GEMM-only FSDB에서 계산했다.

### 2.2 사용한 명령

```bash
PYTHONPATH=tools python3 -m fsdb_cli info <fsdb>

PYTHONPATH=tools python3 -m fsdb_cli hier <fsdb> \
  /tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/\
g_sockets[0]/socket/g_cores[0]/core/gemm_node -l 3 -m flat -S

PYTHONPATH=tools python3 -m fsdb_cli events <fsdb> \
  -s <gemm_node>/dbg_input_last_admission \
  -s <gemm_node>/input_dma_ctrl_if/done \
  -s <gemm_node>/dbg_input_last_write \
  -s <gemm_node>/dbg_input_cmd_done --csv
```

복수 signal alias를 안정적으로 처리하기 위해 주요 pulse는 signal별 `events` 결과와
`tools/fsdb_cli` Python API 결과를 함께 대조했다.

## 3. FSDB 관측 결과

### 3.1 한 input command의 timeline

| Event | Time | Last admission 기준 | 의미 |
|---|---:|---:|---|
| Input child command start | 57.395 us | -14 cycles | `OP_I_LDMA_ARM` issue |
| 첫 input admission | 57.505 us | -3 cycles | 4개 packet 연속 admission 시작 |
| 마지막 input admission | 57.535 us | 0 cycles | `packet_ctrl.last=1` packet admission |
| Input LDMA `done` | 57.575 us | +4 cycles | LDMA transfer bookkeeping 완료 |
| Input LDMA `idle` | 57.585 us | +5 cycles | 다음 LDMA start 가능 |
| 마지막 ACC write | 57.685 us | +15 cycles | `gemm_unit_v2_if.last_write` |
| Input child inflight 해제 | 57.705 us | +17 cycles | idle 기반 완료 감지 |
| Input NOTIFY fire | 57.715 us | +18 cycles | sync update interface valid |
| `sync_regs[RID_G0]` update | 57.725 us | +19 cycles | GEMM WAIT 해제 |
| `OP_O_ACC2LMEM` child start | 57.755 us | +22 cycles | output command 시작 |

현재 input command의 sync-visible completion은 마지막 admission이 아니라 ACC writeback에
고정되어 있다. 이 workload에서는 `RID_G0` WAIT가 약 57.405 us부터 57.725 us까지
32 cycle block되며, 그 중 마지막 admission 이후 구간이 19 cycle이다.

### 3.2 15-cycle latency의 RTL 근거

`VX_gemm_unit_v2.sv`에서 다음 관계가 성립한다.

```text
MXU_OUT_DLY      = 5
PREALIGN_CTRL    = 4
MXU_CTRL_IDX     = 9
MERGER_CTRL_IDX  = 10
INT2FP_CTRL_IDX  = 12
SCALER_CTRL_IDX  = 13
WRITE_CTRL_IDX   = 14
WRITE_DLY        = 15
```

따라서 input admission의 `last` metadata가 `ctrl_pipe[0]`에 들어간 뒤
`ctrl_pipe[WRITE_CTRL_IDX]`에서 `acc_write_fire`와 만나기까지 15 cycle이 걸린다.
FSDB의 `57.535 us -> 57.685 us`와 일치한다.

## 4. 현재 RTL의 실제 completion 구조

### 4.1 GEMM node

현재 `VX_gemm_node.sv`의 normal input command completion은 다음과 같다.

```systemverilog
assign gemm_ctrl_if.input_read_flag.idle = !input_cmd_ctx_r.active;
assign gemm_ctrl_if.input_read_flag.done = gemm_unit_v2_if.last_write;
```

그리고 `input_cmd_ctx_r.active`는 `gemm_unit_v2_if.last_write`에서만 clear된다.
즉 `idle`과 `done`이 모두 writeback completion을 의미한다.

### 4.2 GEMM controller

`VX_gemm_ctrl.sv`는 child의 `flag.done`을 사용하지 않고 다음 순서로 normal command의
완료를 판단한다.

1. normal child command가 fire되면 `child_cmd_inflight_r=1`
2. child `idle=0`을 한 번 관측해 `child_busy_seen_r=1`
3. 이후 child `idle=1`을 관측하면 inflight clear
4. 뒤에 대기하던 NOTIFY command를 child로 전달
5. node의 NOTIFY가 `VX_gemm_sync` register를 update
6. parent queue head의 WAIT가 해제

`gemm_cqueue_out[i].flag.done`은 현재 0에 묶여 있다. 그러므로 구현 시 controller의
completion contract도 함께 바꿔야 한다.

### 4.3 Output path의 추가 안전장치

`VX_gemm_unit_v2`의 ACC MEM output read는 다음 조건으로 보호된다.

```systemverilog
o_lmem_bus_if.req_ready = pipeline_empty && !output_read_valid;
```

따라서 `OP_O_ACC2LMEM` 자체를 일찍 issue해도 실제 ACC read handshake는 pipeline이
empty가 될 때까지 발생하지 않는다. 기능적으로는 안전장치가 이미 존재한다.

하지만 command dependency를 명확하게 유지하고 output LDMA가 불필요하게 대기 상태를
점유하지 않도록, 기본 구현은 `OP_O_ACC2LMEM`이 `writeback_done`을 기다리게 한다.
`pipeline_empty` gate는 제거하지 않고 최종 방어선과 assertion 근거로 유지한다.

### 4.4 동일 ACC address forwarding의 정확한 경계

이 항목이 completion 최적화의 선행 조건이다. 같은 ACC address를 갱신하는 producer
packet `A`가 cycle `t`에 admission되고 consumer packet `B`가 cycle `t+d`에
admission된다고 하자.

```text
A write cycle          = t     + L_PRE + L_A + L_P
B nominal read cycle   = t + d + L_PRE - L_R
K_LOOKBACK             = L_A + L_P + L_R
```

ACC SRAM은 bank별 single-port이고 같은 cycle의 read/write를 허용하지 않는다. 따라서
`B`가 SRAM에서 최신 값을 읽으려면 read가 `A`의 write보다 **뒤**여야 한다.

```text
d + L_PRE - L_R > L_PRE + L_A + L_P
d > L_A + L_P + L_R
d >= K_LOOKBACK + 1
```

현재 값은 `L_R=1`, `L_A=1`, `L_P=0`, `K_LOOKBACK=2`이므로 다음과 같다.

| 동일 주소 admission 거리 `d` | 현재 동작 | 판정 |
|---:|---|---|
| 1 | `admission_forward`가 이전 packet의 aligned writeback을 선택 | 안전 |
| 2 | same-bank conflict로 one-cycle-early read를 선택 | **안전하지 않음: A write 전의 stale PSUM** |
| 3 이상 | nominal read가 A write 뒤에 발생 | 안전 |

`d=2`에서는 nominal read와 A write가 충돌한다. 현재 early-read scheduler는 address가
아니라 bank만 비교하므로 read를 한 cycle 앞당긴다. 서로 다른 address라면 이 동작이
맞지만, 같은 address라면 A가 쓰기 전 값을 읽기 때문에 collision assertion은 통과하면서
계산 결과가 틀릴 수 있다.

현재 forwarding은 오직 `ctrl_pipe[0]`, 즉 정확히 직전 cycle의 writer만 비교한다.
또한 다음 static assertion으로 producer writeback과 consumer accumulator input의 정렬을
강제한다.

```systemverilog
WRITE_CTRL_IDX == SCALER_CTRL_IDX + 1
```

따라서 immediate forwarding은 `L_A + L_P = 1`인 현재 구조에 종속된다. 보장 조건은
accumulator latency 하나만이 아니라 `L_R + L_A + L_P` 전체다. 예를 들어 `L_A=2`가
되면 `K_LOOKBACK=3`, SRAM-safe 경계는 `d>=4`가 되고 `d=2,3`을 추가 forwarding이나
admission 제한으로 처리해야 한다. 현재 RTL은 이 latency 변경을 그대로 지원하지 않고
위 static assertion에서 막힌다.

### 4.5 micro-K transition에 적용

FSM은 `kt_mxu`를 inner loop로 순회하고 같은 `nt_mxu`에서는 `acc_base`를 재사용한다.
그러나 같은 row의 재입력 거리는 command 경계 자체가 아니라 실제 packet admission으로
계산해야 한다.

```text
d_same_row = (eff_mt - 1) + G_start

G_start = 이전 command의 last admission부터 다음 command의 first admission까지 거리
```

command가 bubble 없이 붙으면 `G_start=1`이므로 `d_same_row=eff_mt`이다.

| `eff_mt` | command가 완전히 연속일 때 | 현재 판정 |
|---:|---:|---|
| 1 | `d=1` | immediate forwarding으로 안전 |
| 2 | `d=2` | 현재 유일한 hazard hole |
| 3 이상 | `d>=3` | 최신 ACC MEM read로 안전 |

M=1도 항상 안전한 것은 아니다. 완전히 연속이면 forwarding으로 안전하지만, admission
사이에 정확히 한 cycle의 bubble이 생겨 `d=2`가 되면 오히려 위험하다. 두 cycle 이상
bubble이 있어 `d>=3`이면 다시 SRAM으로 안전하다.

현재 M=4 FSDB에서는 last admission 후 input LDMA `done`이 +4 cycle, `idle`이 +5 cycle에
발생했다. 다음 normal command의 `route_ready`가 계속 `input_dma_ctrl_if.idle`을 요구한다면
M=1조차 다음 first admission은 관측상 `d>=5`이고, M=4의 동일 row는 그보다 더 멀다.
따라서 현재 target의 micro-K transition에 blanket `writeback_done` barrier를 두는 것은
과도하게 보수적이다. 다만 +5는 한 workload의 관측값이므로 다음 조건을 RTL contract로
고정한 뒤에만 ingress completion을 사용한다.

```text
same_acc_addr -> admission_distance == 1
              || admission_distance >= K_LOOKBACK + 1
```

## 5. Dependency 분류

단순히 다음 opcode만 보고 early/late completion을 고르면 부족하다. ACC address range에
대한 RAW/WAW dependency를 기준으로 판단해야 한다.

| 다음 동작 | 기다릴 completion | 이유 |
|---|---|---|
| 독립 weight/scale/ZP preload | 없음 또는 `ingress_done` | ACC MEM 비의존 |
| 다른 `nt_mxu`의 input command | `ingress_done` | accumulator address range가 다름 |
| 같은 `nt_mxu`의 다음 K microtile | `ingress_done` + `route_ready` hazard check | `d=1` 또는 `d>=K_LOOKBACK+1`이면 안전 |
| `OP_O_ACC2LMEM` | `writeback_done` | 현재 ACC 결과를 소비 |
| buffer/address overlap을 증명하지 못한 command | `writeback_done` | conservative fallback |

현재 FSM은 K microtile을 inner loop로 순회한다.

```text
n_kt_mxu = kt_mxu + 1, wrap 시 0
n_nt_mxu = K loop wrap 시 nt_mxu + 1
acc_base = acc_group_base + nt_mxu * acc_nb_stride
```

따라서 같은 N microtile 안에서 K가 증가하면 address overlap은 존재하지만, overlap만으로
late dependency라고 판정하면 안 된다. 실제 admission 거리와 forwarding 가능 여부를
판정해야 한다. 현재 route gap이 유지되면 micro-K transition도 early completion 후보가
된다. 반대로 scheduler 변경으로 정확히 `d=2`가 가능해지면 별도 보호가 필요하다.

## 6. 권장 해결책

### 6.1 Completion domain 분리

GEMM input route에 두 개의 monotonic completion domain을 둔다.

- ingress domain: 기존 `RID_G0/RID_G1` 사용
- writeback domain: 새 `RID_GW0/RID_GW1` 사용

`VX_gemm_sync`는 현재 11개 register를 가지며 0~8이 사용 중이므로, 우선 9와 10을
`RID_GW0/RID_GW1` 후보로 사용할 수 있다. 실제 적용 전 다른 command에서 9/10을
사용하지 않는지 static assertion으로 고정한다.

### 6.2 Input command lifecycle 분리

`input_cmd_ctx_r`를 다음 두 역할로 분리한다.

1. ingress context
   - 현재 admission 중인 command의 ACC base, packet index, mode, register index 보관
   - `input_last_admission`에서 해제
   - 다음 command의 metadata capture에 재사용 가능
2. writeback completion tracker
   - command 순서대로 `last_write`를 대응시키는 token FIFO
   - 최소 payload: `{buffer_id, sequence/target, late_rid}`
   - pipeline에 동시에 존재할 수 있는 command 수를 수용할 depth 필요

고정 latency pipeline은 input과 writeback 순서를 보존하므로 FIFO head와
`gemm_unit_v2_if.last_write`를 순서대로 대응시킬 수 있다.

### 6.3 Child queue의 명시적 완료 사용

input child만큼은 idle edge 추론 대신 명시적 completion을 사용한다.

- normal `OP_I_LDMA_ARM` retirement: `ingress_done`
- NOTIFY acceptance: notification buffer에 enqueue되었을 때
- 다음 normal input issue ready:
  `ingress context free && input_dma_ctrl_if.idle && notification resource available`

NOTIFY는 DMA transfer를 시작하지 않으므로 `input_dma_ctrl_if.idle`과 분리해 받을 수
있어야 한다. 반대로 다음 normal I_LDMA command는 이전 LDMA가 idle이 되기 전에
start하면 안 된다. 이를 위해 child head opcode를 기반으로 ready를 구분하거나 input
child queue를 작은 전용 adapter로 분리한다.

### 6.4 Early/late sync event 생성

`OP_I_LDMA_ARM` 뒤의 NOTIFY를 input child가 받으면 다음을 수행한다.

1. ingress completion target을 `RID_G*`에 update
2. 대응하는 `{RID_GW*, target}` token을 writeback FIFO에 enqueue
3. 해당 command의 `last_write`가 오면 FIFO를 pop하고 `RID_GW*` update

early notify와 이전 command의 late writeback이 같은 cycle에 발생할 수 있으므로
두 event를 잃지 않는 arbitration/FIFO가 필요하다. 단순 priority mux만 두고 한쪽 pulse를
버리면 안 된다.

### 6.5 FSM dependency 선택

`S_MXU_WAIT_GEMM_DONE`에서 항상 `RID_G*` 하나만 기다리는 대신 dependency와 다음 input의
admission 가능 시점을 분리한다.

```text
if next command is ACC output read:
    wait RID_GW[buffer]       // writeback_done
else:
    wait RID_G[buffer]        // ingress_done
    issue only when route_ready && acc_hazard_free
```

`acc_hazard_free`는 disjoint address이면 즉시 참이다. 같은 address range이면 첫 packet의
예상 admission 거리가 `1` 또는 `K_LOOKBACK+1` 이상인지 확인한다. 이를 증명할 수 없는
경우만 `RID_GW`로 fallback한다. `OP_O_ACC2LMEM`은 계속 late completion을 사용한다.

## 7. 구현 계획

### Phase 0: forwarding 경계 고정 — 최우선

1. `VX_gemm_unit_v2` directed test에 동일 주소 `d=1`, `d=2`, `d=3` case를 추가한다.
2. `last`로 stream을 끊은 뒤 같은 주소를 다시 쓰는 cross-command 형태로도 반복한다.
3. 현재 `d=2`가 stale PSUM을 사용하는 failing test임을 먼저 재현한다.
4. 첫 구현은 다음 둘 중 하나로 `d=2`를 제거한다.
   - node에서 최근 `K_LOOKBACK` cycle의 writer address를 추적해 unsafe admission 금지
   - GEMM unit에서 직전 writeback `{valid, addr, data}`를 한 cycle 더 보관해 history
     forwarding하고 해당 packet의 early/nominal SRAM read 억제
5. command completion 최적화에는 node guard를 필수로 둔다. history forwarding을 함께
   구현하면 guard는 assertion/fallback 역할로 유지한다.
6. 다음 invariant를 unit/node 양쪽 assertion으로 고정한다.

```text
same_acc_addr && acc_rd_en
  -> d == 1 || d >= K_LOOKBACK + 1 || history_forward_hit
```

### Phase 1: 관측 신호와 contract 고정

1. `VX_gemm_node`에 다음 probe/counter를 추가한다.
   - `input_ingress_done`
   - `input_writeback_done`
   - `input_route_ready`
   - ingress/writeback command sequence
   - writeback token FIFO occupancy
2. assertion을 추가한다.
   - command당 ingress/writeback completion이 정확히 한 번 발생
   - `writeback_done`은 대응하는 `ingress_done`보다 빠를 수 없음
   - completion 순서 보존
3. 기존 FSDB workload로 baseline 15/19-cycle 간격을 자동 측정한다.

### Phase 2: Node context와 completion tracker 분리

1. `input_cmd_ctx_r`를 last admission에서 해제하는 ingress context로 변경한다.
2. `last_write`에서 context 전체를 clear하는 현재 로직을 제거한다.
3. command별 writeback token FIFO를 추가한다.
4. back-to-back command 중 이전 `last_write`가 새 ingress context를 훼손하지 않는지
   unittest로 검증한다.

### Phase 3: Input child completion/ready 변경

1. `VX_gemm_ctrl` input child가 `ingress_done`으로 normal command를 retire하도록 한다.
2. NOTIFY와 normal command의 ready 조건을 분리한다.
3. NOTIFY는 LDMA busy 중에도 completion buffer가 비어 있으면 accept한다.
4. normal input command는 LDMA idle과 ingress context availability를 모두 확인한다.
5. 기존 children 1~4의 idle-edge completion 동작은 유지해 변경 범위를 제한한다.

### Phase 4: Dual sync completion 구현

1. `RID_GW0/RID_GW1`를 정의한다.
2. early notify에서 ingress RID를 update하고 late token을 enqueue한다.
3. `last_write`에서 writeback RID를 update한다.
4. early/late event 동시 발생을 처리하는 completion event FIFO를 구현한다.
5. FIFO overflow/underflow 및 RID/target pairing assertion을 추가한다.

### Phase 5: Dependency-aware FSM 적용

1. current/next ACC range 비교 helper를 추가한다.
2. 동일 N의 다음 K microtile도 `route_ready && acc_hazard_free`이면 ingress RID를 기다린다.
3. disjoint N microtile transition은 ingress RID를 기다린다.
4. 정확한 admission 거리를 증명할 수 없는 overlapping transition만 writeback RID를
   선택한다.
5. `o_lmem_bus_if.req_ready = pipeline_empty && !output_read_valid`는 유지한다.

### Phase 6: latency 일반화

1. `L_R`, `L_A`, `L_P` 변화에 대해 unsafe window `2..K_LOOKBACK`을 자동 산출한다.
2. accumulator latency가 1보다 커지면 multi-entry result forwarding 또는 admission
   scoreboard로 unsafe window 전체를 처리한다.
3. current-writeback 하나만 선택하는 immediate forwarding static assertion을 새 구조에
   맞게 일반화한다.

## 8. Verification 계획

### 8.1 RTL unittest

- 단일 packet command: ingress와 writeback 간 고정 latency 확인
- multi-packet command: 마지막 admission에서만 ingress completion 발생
- disjoint back-to-back command: 이전 writeback 전에 다음 ingress 허용
- 동일 주소 `d=1`: immediate forwarding 및 연속 chain 확인
- 동일 주소 `d=2`: stale early-read 금지와 guard/history forwarding 확인
- 동일 주소 `d=3`: writeback 이후 nominal SRAM read 확인
- same-bank/different-address `d=2`: 기존 one-cycle-early read 유지 확인
- micro-K transition: M=1, M=2, M=4와 `G_start=1,2,3` 조합
- `OP_O_ACC2LMEM`: 마지막 writeback 이전 ACC read fire 금지
- early notify와 late writeback 동시 발생
- writeback token FIFO full/backpressure
- reset 중 outstanding token flush

필수 assertion:

```text
ingress_count >= writeback_count
ingress_count - writeback_count <= tracker_depth
late_target(command_i) == ingress_target(command_i)
same_acc_addr -> d == 1 || d >= K_LOOKBACK + 1 || history_forward_hit
unsafe_same_addr -> no early_read_req && no nominal_read_req
output_read_fire -> pipeline_empty && required_writeback_done
```

### 8.2 XRT-VCS

기능 검증:

```bash
ci/run_target_gemm.sh run --wload 4
ci/run_target_gemm.sh run --wload 8
ci/run_target_gemm.sh run --wload 16
ci/run_target_gemm.sh run --wload 32
```

성능/FSDB 검증:

- target: `M=4, N=256, K=256, QBLK=32, WTRANS=0, QDIR=1`
- 비교 항목:
  - last admission -> ingress RID update
  - last admission -> writeback RID update
  - micro-GEMM start-to-start interval
  - `S_MXU_WAIT_GEMM_DONE` blocked cycles
  - parent/child queue full cycles
  - `psum_underflow`, `rd_wr_conflict`
  - ACC output numerical comparison

## 9. 기대 효과와 한계

현재 파형 기준으로 ingress completion은 sync-visible completion에서 최대 약 15 cycle의
writeback latency를 제거할 수 있다. 다음 normal input command는 input LDMA idle 때문에
last admission 후 관측상 최소 약 5 cycle 뒤에 시작할 수 있으므로, 현재 latency의
SRAM-safe 경계 `d>=3`을 이미 넘는다. M=4 target은 동일 row 재입력 거리도 추가로 확보된다.

따라서 동일 `nt_mxu`의 K accumulation transition도 우선적인 early-completion 대상이다.
성능 최적화 전에 Phase 0에서 `d=2` hole을 test/assertion으로 재현하고 제거해야 하며,
`route_ready`가 LDMA idle과 `acc_hazard_free`를 모두 포함한다는 contract를 유지해야 한다.
