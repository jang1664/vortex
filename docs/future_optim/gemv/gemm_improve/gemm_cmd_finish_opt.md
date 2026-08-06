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
2. 같은 ACC address를 읽는 다음 command도 `writeback_done`까지 기다릴 필요가 없다.
   현재 고정 latency에서 `d=1`은 immediate forwarding, `d=2`는 writeback-history
   forwarding, `d>=3`은 최신 ACC MEM read로 처리된다. 따라서 가능한 모든 양의
   admission 거리에서 동일 주소 RAW가 해결된다.
3. command completion과 다음 input command를 받을 수 있는 상태는 같은 개념이
   아니다. 마지막 input admission 직후에도 local DMA는 현재 파형에서 4~5 cycle 더
   active하다. 또한 단일 `input_cmd_ctx_r`는 현재 `last_write`까지 유지되므로 이를
   그대로 조기 해제하면 back-to-back command와 이전 command의 `last_write`를 구분할
   수 없다. final command의 writeback은 raw `last_write`가 아니라 input packet과 함께
   고정-latency GEMM control pipeline을 통과한 `notify_on_writeback` marker로 식별한다.
4. `d=2` history forwarding과 `d=1/2/3` directed unittest가 구현되어 VCS unittest를
   통과했다. M=2의 `row0,row1,row0,row1` seamless micro-K도 검증했으므로 micro-K
   scheduling의 correctness를 LDMA route gap에 의존시킬 필요가 없다.

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
| 2 | exact-address history forwarding; early/nominal read 억제 | 안전 |
| 3 이상 | nominal read가 A write 뒤에 발생 | 안전 |

`d=2`에서는 nominal read와 A write가 충돌하므로 기존 one-cycle-early read를 그대로
사용하면 stale PSUM을 읽는다. 현재 RTL은 exact-address `d=2` dependency를 admission에서
검출하고, producer writeback의 `{valid, addr, data}`를 한 cycle 보관해 consumer가
accumulator input에서 선택한다. 해당 consumer의 early/nominal read는 모두 억제한다.
same-bank이지만 address가 다른 `d=2` packet은 기존 one-cycle-early scheduler를 유지한다.

`d=1`은 `ctrl_pipe[0]` writer의 현재 writeback을 선택하며 history forwarding보다 우선한다.
다음 static assertion들은 현재 forwarding contract를 고정한다.

```systemverilog
WRITE_CTRL_IDX == SCALER_CTRL_IDX + 1
L_R == 1 && L_A == 1 && L_P == 0
```

따라서 이 문서의 계획은 `L_R/L_A/L_P=1/1/0`에 한정한다. accumulator latency 일반화는
범위 밖이며, 다른 latency가 설정되면 elaboration에서 실패하도록 했다.

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
| 2 | `d=2` | writeback-history forwarding으로 안전 |
| 3 이상 | `d>=3` | 최신 ACC MEM read로 안전 |

따라서 `eff_mt`와 command gap의 조합에 관계없이 같은 row의 다음 K contribution은
안전하다. M=1에서 command가 완전히 붙으면 `d=1`, 한 cycle bubble이면 `d=2`, 더 멀면
`d>=3`이며 세 경우가 모두 각각의 source로 처리된다. M=2 seamless 패턴은 다음과 같이
별도로 검증했다.

```text
row0(k0), row1(k0,last), row0(k1), row1(k1,last)
```

두 row 모두 `d=2` history forwarding을 사용하고 최종 FP32 65.0을 생성했다. 중간 cycle의
다른 row writeback이 history register를 갱신하더라도 consumer는 edge 직전의 올바른
producer 값을 소비한다.

현재 M=4 FSDB에서는 last admission 후 input LDMA `done`이 +4 cycle, `idle`이 +5 cycle에
발생했다. 다음 normal command의 `route_ready`가 계속 `input_dma_ctrl_if.idle`을 요구한다면
M=1조차 다음 first admission은 관측상 `d>=5`이고, M=4의 동일 row는 그보다 더 멀다.
이 +5 cycle은 이제 correctness 조건이 아니라 다음 command의 resource availability와
실제 성능을 결정하는 route latency다. micro-K transition은 `writeback_done`을 기다리지
않고 `ingress_done`과 `route_ready`만으로 진행할 수 있다.

```text
same_acc_addr && d == 1 -> immediate_forward
same_acc_addr && d == 2 -> history_forward
same_acc_addr && d >= 3 -> updated_acc_mem_read
```

## 5. Dependency 분류

단순히 다음 opcode만 보고 early/late completion을 고르면 부족하다. ACC address range에
대한 RAW/WAW dependency를 기준으로 판단해야 한다.

| 다음 동작 | 기다릴 completion | 이유 |
|---|---|---|
| 독립 weight/scale/ZP preload | 없음 또는 early NOTIFY | ACC MEM 비의존 |
| 다른 `nt_mxu`의 input command | early NOTIFY | qualified I_LDMA idle에서 완료 |
| 같은 `nt_mxu`의 다음 K microtile | early NOTIFY | 모든 `d>=1` 동일 주소 dependency를 GEMM unit이 처리 |
| `OP_O_ACC2LMEM` | final NOTIFY | tagged final writeback에서 완료되어 최신 ACC 결과 보장 |
| 표준 node contract 밖의 custom metadata command | final NOTIFY | writeback visibility를 증명해야 하는 경우 |

현재 FSM은 K microtile을 inner loop로 순회한다.

```text
n_kt_mxu = kt_mxu + 1, wrap 시 0
n_nt_mxu = K loop wrap 시 nt_mxu + 1
acc_base = acc_group_base + nt_mxu * acc_nb_stride
```

따라서 같은 N microtile 안에서 K가 증가하는 transition은 address overlap과 무관하게
early completion 대상이다. node/FSM이 admission 거리를 계산하거나 `d=2`를 피하기 위한
stall을 넣을 필요가 없다. 이 결론은 fixed `1/1/0` latency와 input당 최대 한 packet이라는
현재 contract에 한정한다.

## 6. 권장 해결책: completion 조건을 선택하는 paired NOTIFY

### 6.1 확정한 completion 구조

sync register update는 항상 command stream의 `OP_NOTIFY`만 수행한다. GEMM unit의
writeback signal은 sync port로 연결하지 않고 `VX_gemm_node` 내부에서 final NOTIFY를
release하는 completion signal로만 사용한다.

각 `OP_I_LDMA_ARM`에는 paired `OP_NOTIFY`가 정확히 하나 있고, 다음 consumer에 따라
NOTIFY가 기다리는 조건만 달라진다.

| I_LDMA 종류 | paired NOTIFY fire 조건 | 다음 동작 |
|---|---|---|
| non-final K | qualified I_LDMA idle | 다음 K/N microtile |
| ACC-to-TMEM 직전 final K | tagged final writeback | `OP_O_ACC2LMEM` |

```text
non-final K:
    I_LDMA
      -> ingress_done
      -> qualified I_LDMA idle
      -> paired NOTIFY updates RID_G[b]
      -> WAIT RID_G[b]
      -> next microtile

final K:
    I_LDMA(notify_on_writeback=1)
      -> ingress_done
      -> tagged final ACC writeback
      -> paired NOTIFY updates RID_G[b]
      -> WAIT RID_G[b]
      -> ACC-to-TMEM
```

따라서 GEMM 전용 sync port, `RID_GW0/RID_GW1`, `N_NODE=6` 확장은 만들지 않는다.
기존 input NOTIFY port와 `RID_G0/RID_G1`만 사용한다.

### 6.2 FSM completion mode 생성

FSM은 `OP_I_LDMA_ARM`을 생성할 때 다음 consumer가 ACC-to-TMEM인지 알고 있다. raw K index를
node에서 다시 해석하지 않고 FSM이 명시적인 `notify_on_writeback` bit를 command metadata에
설정한다.

```text
next consumer is another GEMM input:
    notify_on_writeback = 0

next consumer is ACC-to-TMEM:
    notify_on_writeback = 1
```

같은 mode를 paired NOTIFY에도 넣어 command pair의 정합성을 검증할 수 있게 한다. final 여부는
단순 `last_k` bit가 아니라 실제 다음 dependency가 `OP_O_ACC2LMEM`인지로 결정한다.
`VX_gemm_node`는 ARM start에서 mode를 command completion state에 capture하고 selected
completion이 발생할 때까지 유지한다. 동일 mode를 각 input packet의 GEMM sideband에도
전달한다.

FSM의 command 순서는 유지한다.

```text
OP_I_LDMA_ARM -> OP_NOTIFY(RID_G) -> WAIT(RID_G)
```

### 6.3 Qualified I_LDMA idle

`input_dma_ctrl_if.idle`은 command 시작 전에도 1이므로 raw idle level만으로 non-final
completion을 만들면 안 된다. 해당 command가 실제 실행됐고 ingress가 끝났음을 qualification한
뒤의 idle만 인정한다.

권장 조건은 다음과 같다.

```systemverilog
qualified_ldma_idle = input_cmd_active
                   && !notify_on_writeback
                   && input_ingress_done_seen
                   && input_dma_ctrl_if.idle;
```

`input_ingress_done_seen` 대신 command별 `input_dma_busy_seen`의 busy-to-idle transition을
사용할 수도 있지만, last admission을 이미 명시적으로 검출하므로 ingress-done qualification을
사용하는 편이 의미가 분명하다. 현재 파형에서 I_LDMA idle은 ingress보다 약 5 cycle 늦으므로
qualification 이후에는 idle이 실질적인 early completion 시점이다.

다음 invariant를 고정한다.

```text
qualified_ldma_idle -> corresponding ingress_done already occurred
non-final command done -> qualified_ldma_idle
```

### 6.4 Tagged final writeback

raw `gemm_unit_v2_if.last_write`를 final completion으로 사용하면 안 된다. 이전 non-final
command가 이미 NOTIFY를 마친 뒤에도 pipeline에 남아 있다가, 다음 final command가 실행 중일
때 `last_write`를 발생시킬 수 있기 때문이다.

`notify_on_writeback`을 input packet control과 함께 기존 `ctrl_pipe`의 write stage까지
pipeline한다.

```systemverilog
tagged_final_writeback = acc_write_fire
                       && ctrl_pipe[WRITE_CTRL_IDX].last
                       && ctrl_pipe[WRITE_CTRL_IDX].notify_on_writeback;
```

non-final command의 delayed writeback은 marker가 0이므로 final NOTIFY를 release하지 않는다.
final command는 paired NOTIFY가 완료될 때까지 다음 normal I_LDMA를 시작하지 않으므로
동시에 outstanding인 final completion은 최대 하나다. token FIFO나 command sequence tag는
필요하지 않다.

### 6.5 Child queue와 NOTIFY handshake

input child normal command의 selected completion은 다음과 같다.

```systemverilog
input_cmd_done = notify_on_writeback
               ? tagged_final_writeback
               : qualified_ldma_idle;
```

`VX_gemm_ctrl`은 기존 idle-edge 추론 대신 explicit `input_read_flag.done`으로 input child의
`child_cmd_inflight_r`를 해제한다. completion pulse가 paired NOTIFY보다 먼저 발생해도 기존
inflight state가 완료 사실을 보존하므로 별도 completion FIFO는 필요하지 않다.

paired NOTIFY는 input child queue head에 남아 있다가 normal command inflight가 해제되고
sync port가 ready일 때 update와 queue pop을 같은 cycle에 수행한다. controller는 이미 queue
head opcode와 `child_cmd_inflight_r`를 알고 있으므로 `child_notify_ok`를 유지한다. node는 queue
head opcode를 보고 NOTIFY일 때 `input_read_flag.idle`을 sync ready로 반환한다.

```systemverilog
// Node: readiness of the command currently visible at the child interface.
input_read_flag.idle = input_head_is_notify
                     ? gemm_sync_if[0].ready
                     : normal_input_ready;

// Controller: existing child queue pop/start, now opcode-qualified.
child_out_fire = !child_q_empty
              && input_read_flag.idle
              && (!input_head_is_notify || !child_cmd_inflight_r);

// Node: child_out_fire appears as input_read_ctrl.start.
input_notify_valid       = input_read_ctrl.start && input_head_is_notify;
input_notify_fire        = input_notify_valid && gemm_sync_if[0].ready;
gemm_sync_if[0].valid    = input_notify_valid;
gemm_sync_if[0].reg_idx  = input_notify_cmd.rs1_data[31:0];
gemm_sync_if[0].value    = input_notify_cmd.rs2_data[31:0];
```

기존 child queue가 NOTIFY payload를 보관하므로 `input_notify_pending_r`,
`input_notify_reg_idx_r`, `input_notify_value_r`는 제거한다. sync ready가 낮아지면 queue를
pop하지 않고 NOTIFY를 head에 유지한다. `child_out_fire`, queue pop, NOTIFY sync handshake는
동일 cycle에 성립한다.

### 6.6 Sync counter와 invocation lifecycle

각 I_LDMA command는 early 또는 final 시점 중 하나에서 paired NOTIFY를 정확히 한 번 발생시킨다.
`RID_G0/RID_G1`은 ADD 1 event counter로 사용한다.

```text
paired NOTIFY for buffer b:
    RID_G[b] += 1
```

FSM은 buffer별 `gemm_expected_count[2]`를 유지한다.

```text
OP_I_LDMA_ARM for buffer b is accepted into parent queue:
    gemm_expected_count[b] += 1

paired WAIT:
    RID_G[b] >= gemm_expected_count[b]
```

count는 command 생성 시도가 아니라 `out_start && can_emit`으로 ARM이 parent queue에 실제
accept된 cycle에만 증가한다. paired NOTIFY는 `value=32'd1`을 전달하고, WAIT는 이미 증가한
expected count를 target으로 사용한다.

32-bit wrap은 지원하지 않고 increment 전에 assertion으로 막는다.

```systemverilog
assert (gemm_expected_count[mxu_buf] != 32'hffff_ffff);
```

hardware reset과 새 GEMM invocation accept에서 `gemm_expected_count[0/1]`를 0으로
초기화한다. 이전 invocation의 `S_FINAL_CLEAR`가 발행한 `OP_CLEAR`는 sync register를 0으로
만든다. CLEAR는 input NOTIFY update와 같은 cycle에 발생하지 않아야 하며 assertion으로
확인한다.

NOTIFY update와 이미 대기 중인 WAIT가 같은 cycle에 겹치면 WAIT는 update된 sync register를
다음 cycle에 관측해 해제한다. combinational update bypass는 추가하지 않아 sync register와
WAIT 비교의 critical path를 늘리지 않는다.

정상 동작 중 GEMM invocation 중간에는 reset이 들어오지 않는 system contract를 사용한다.
reset은 idle 상태에서만 허용하고, active input command, child inflight 또는 GEMM pipeline에
outstanding packet이 있을 때 reset이 assertion되면 simulation에서 실패시킨다. reset 자체는
completion mode, ingress qualification, child inflight와 delayed marker를 모두 0으로
초기화한다.

### 6.7 적용 범위와 compile configuration

새 completion contract는 현재 improved/V2 module 경로에 조건 없이 직접 적용한다.
`GEMM_IMPROVE_V2` 같은 새 macro는 추가하지 않는다.

현재 RTL의 실제 node 선택은 `GEMM_IMPROVE`가 아니라 `GEMM_NAIVE` 여부로 결정된다.

```text
GEMM_NAIVE defined:
    VX_gemm_node_naive / VX_gemm_fsm_naive / VX_gemm_ctrl_naive / VX_gemm_unit

GEMM_NAIVE not defined:
    VX_gemm_node / VX_gemm_fsm / VX_gemm_ctrl / VX_gemm_unit_v2
```

따라서 `notify_on_writeback`, qualified I_LDMA idle, explicit input child done과 paired NOTIFY
direct handshake는 improved/V2 module들에 구현하고 naive/legacy module은 변경하지 않는다.
config의 `GEMM_IMPROVE` define은 improve target 식별, CI 검증, FSDB hierarchy 선택 용도로
계속 유지하지만 새 RTL contract를 별도 `` `ifdef GEMM_IMPROVE`` block으로 감싸지 않는다.

## 7. 구현 계획

### Phase 0: forwarding 경계 고정 — 완료

1. 동일 주소 `d=1/2/3`을 command 내부와 `last` 경계 양쪽에서 검증했다.
2. `d=1` 연속 chain과 same-bank/different-address `d=2` early-read를 검증했다.
3. exact-address `d=2`용 one-cycle writeback-history forwarding을 구현했다.
4. M=2 seamless micro-K `row0,row1,row0,row1`을 검증했다.
5. fixed `L_R/L_A/L_P=1/1/0` contract를 static assertion으로 고정했다.
6. configured-build VCS `gemm_unit_v2` unittest가 두 verification iteration에서 통과했다.

### Phase 1: Completion mode와 tagged writeback 구현

1. FSM의 I_LDMA command와 paired NOTIFY에 `notify_on_writeback` metadata를 추가한다.
2. 다음 consumer가 `OP_O_ACC2LMEM`일 때만 mode를 1로 설정한다.
3. packet control에 mode를 넣고 기존 `ctrl_pipe`의 write stage까지 delay한다.
4. delayed mode, delayed `last`, `acc_write_fire`로 `tagged_final_writeback`을 만든다.
5. raw `last_write`는 final command completion에 사용하지 않는다.

필수 invariant:

```text
tagged_final_writeback -> last_write && delayed_notify_on_writeback
non-final delayed last_write -> !tagged_final_writeback
final last admission -> exactly one tagged_final_writeback after fixed WRITE_DLY
```

### Phase 2: Qualified LDMA idle과 explicit child completion

1. ARM start에서 `notify_on_writeback`을 command completion state에 capture한다.
2. command별 `input_ingress_done_seen`을 추가하고 last admission에서 set한다.
3. non-final command completion을 `ingress_done_seen && input_dma_idle`로 정의한다.
4. final command completion을 `tagged_final_writeback`으로 정의한다.
5. `gemm_ctrl_if.input_read_flag.done`에 selected completion을 연결한다.
6. `VX_gemm_ctrl` input child inflight를 idle edge가 아니라 explicit done으로 해제한다.
7. selected completion에서 mode와 ingress-done qualification state를 clear한다.
8. normal command start 전 initial idle을 completion으로 오인하지 않는 assertion을 추가한다.

### Phase 3: Paired NOTIFY direct handshake

1. FSM의 기존 ARM → NOTIFY → WAIT command sequence를 유지한다.
2. `input_notify_pending_r`와 저장된 RID/value register를 제거한다.
3. child queue head의 NOTIFY payload로 `gemm_sync_if[0]`을 직접 구동한다.
4. sync valid/ready handshake와 child queue pop을 같은 cycle에 묶는다.
5. normal command inflight가 해제되기 전에는 paired NOTIFY가 fire되지 않게 한다.
6. GEMM 전용 sync port, `RID_GW`, `N_NODE=6` 관련 변경은 구현하지 않는다.

### Phase 4: Sync counter와 FSM 적용

1. 모든 paired input NOTIFY가 `RID_G[buffer]`에 `value=32'd1`을 전달하게 한다.
2. ARM parent-queue accept에서 buffer별 `gemm_expected_count`를 증가시킨다.
3. paired WAIT가 해당 expected count를 target으로 사용하게 한다.
4. hardware reset과 새 invocation accept에서 expected count를 0으로 초기화한다.
5. count wrap, CLEAR/update 비동시, invocation 간 CLEAR ordering assertion을 추가한다.
6. final NOTIFY/WAIT 뒤에만 `OP_O_ACC2LMEM`이 진행되게 한다.
7. WAIT는 sync update를 다음 cycle에 관측하며 combinational bypass는 추가하지 않는다.
8. active GEMM invocation 중 reset 금지 assertion을 추가하고 reset 시 completion 관련 state를
   모두 clear한다.
9. `o_lmem_bus_if.req_ready = pipeline_empty && !output_read_valid`는 최종 안전장치로 유지한다.

### Phase 5: Improved/V2 경로 통합

1. `VX_gemm_fsm`, `VX_gemm_ctrl`, `VX_gemm_node`, `VX_gemm_unit_v2`와 V2 interface/package
   metadata에 새 completion contract를 직접 적용한다.
2. `GEMM_IMPROVE_V2` macro와 V2 내부 기능 분기 `` `ifdef``를 추가하지 않는다.
3. `VX_gemm_fsm_naive`, `VX_gemm_ctrl_naive`, `VX_gemm_node_naive`, `VX_gemm_unit`은
   변경하지 않는다.
4. 기존 `GEMM_IMPROVE` config와 `ci/run_target_gemm.sh` target을 그대로 사용해 검증한다.

## 8. Verification 계획

### 8.1 완료된 GEMM unit unittest

- 동일 주소 `d=1`: immediate forwarding 및 3-packet chain
- 동일 주소 `d=2`: history forwarding, stale early/nominal read 억제
- 동일 주소 `d=3`: writeback 이후 nominal SRAM read
- 위 `d=1/2/3`을 command 내부와 `last` 경계에서 각각 검증
- same-bank/different-address `d=2`: 기존 one-cycle-early read 유지
- M=2 seamless micro-K `row0,row1,row0,row1`: 두 history forwarding과 최종값 검증
- fixed write timing, address, completion marker, read/forward/write count, pipeline drain
- configured-build VCS 결과: PASS

### 8.2 GEMM unit/node/controller/sync RTL unittest

- non-final command의 initial idle을 completion으로 오인하지 않음
- non-final NOTIFY는 last admission 이후 qualified LDMA idle에서만 fire
- non-final NOTIFY는 해당 command의 writeback을 기다리지 않음
- 이전 non-final command의 늦은 raw `last_write`가 final NOTIFY를 release하지 않음
- final NOTIFY는 tagged final writeback 이후에만 fire
- final NOTIFY/WAIT 완료 전 `OP_O_ACC2LMEM` 시작 금지
- multi-packet command에서 마지막 admission만 ingress-done qualification 생성
- completion pulse가 NOTIFY enqueue/head 도달보다 빨라도 inflight state로 유실되지 않음
- NOTIFY sync handshake와 child queue pop이 동일 cycle에 발생
- sync ready가 낮을 때 NOTIFY가 queue head에 유지됨
- `OP_I_LDMA_ARM` parent queue accept 때만 `gemm_expected_count` 증가
- command enqueue stall cycle에는 expected count 유지
- 새 GEMM invocation에서 expected count와 sync count가 0에서 시작
- expected count가 32-bit wrap을 일으키지 않음
- M=1/M=2/M=4 micro-K의 최종 ACC 값과 forwarding source 확인
- reset 시 delayed `notify_on_writeback` marker flush
- active GEMM invocation/input child/pipeline outstanding 중 reset assertion 금지
- CLEAR와 input NOTIFY update가 같은 cycle에 발생하지 않음
- NOTIFY update와 WAIT가 겹치면 WAIT가 다음 cycle에 해제됨
- naive/legacy build가 기존 completion contract로 compile됨

필수 assertion 및 coverage:

```text
qualified_ldma_idle -> prior ingress_done for same command
nonfinal_input_done -> qualified_ldma_idle
tagged_final_writeback -> last_write && delayed_notify_on_writeback
final_input_done -> tagged_final_writeback
raw_nonfinal_last_write -> !final_input_done
input_notify_fire -> corresponding input_cmd_done
input_notify_fire == child_queue_pop && input_sync_update_fire
arm_parent_queue_accept(buffer) -> expected_count[buffer] increments exactly once
!arm_parent_queue_accept -> expected_count remains stable
expected_count_increment -> previous_expected_count != 32'hffff_ffff
clear_fire -> !input_notify_update
reset -> gemm_idle && !input_cmd_active && !child_cmd_inflight && pipeline_empty
output_read_fire -> pipeline_empty && final_notify_wait_satisfied
cover(next_micro_k_start before previous_nonfinal_writeback)
```

2026-08-06 configured-build VCS 결과:

- `gemm_unit_v2`: PASS. accumulator latency를 1로 고정하고 `d=1/2/3`, command
  boundary, `d=1` chain과 seamless micro-K forwarding을 재검증했다.
- `gemm_sync`, `gemm_fsm`, `gemm_ctrl`: PASS. registered WAIT, expected-count,
  explicit done과 paired NOTIFY lifecycle을 재검증했다.
- `gemm_node_improve`: M=1 command-finish lifecycle과
  M=4/N=32/K=256, M=4/N=64/K=128, M=4/N=256/K=256/QDIR=1이 PASS했다.
- M=1/M=2 node 파형에서는 W/SZ readiness wait 때문에 final command start가 이전 raw
  writeback보다 7 cycle 늦어 자연적인 prior-raw/final-active overlap은 발생하지 않았다.
  따라서 이 overlap 자체는 node coverage로 주장하지 않으며, forwarding dependency는 위
  `gemm_unit_v2` directed test로 검증한다. 실제 workload에서의 start-to-start 개선 여부는
  8.3 XRT-VCS 단계에서 확인한다.
- M=4 target의 기존 1013/1024 mismatch는 command-finish RTL 문제가 아니었다. 최초로
  M=4를 허용한 `51a99040`의 node testbench가 production FSM/app의 `align8(M)` input/output
  DRAM slot contract를 반영하지 않은 것이 원인이었고, testbench physical footprint와
  checker stride를 수정한 뒤 1024/1024가 일치했다.

### 8.3 XRT-VCS

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
  - non-final last admission -> qualified LDMA idle -> NOTIFY update
  - final last admission -> tagged writeback -> NOTIFY update
  - raw non-final writeback과 tagged final writeback 구분
  - micro-GEMM start-to-start interval
  - next-K start가 이전 non-final writeback보다 빠른지
  - final NOTIFY가 ACC-to-TMEM 이전에 완료되는지
  - `S_MXU_WAIT_GEMM_DONE` blocked cycles
  - parent/child queue full cycles
  - `psum_underflow`, `rd_wr_conflict`
  - ACC output numerical comparison

2026-08-06 XRT-VCS 결과:

- `ci/run_target_gemm.sh run`으로 WLOAD 4/8/16/32를 모두 검증했고 전부 PASS했다.
  각 실행은 input 256개, output 32개, ACC write 256개를 완료했으며
  `psum_underflow=0`, `rd_wr_conflict=0`이었다. weight fire count는 각각
  512/256/128/64로 WLOAD 폭에 맞게 감소했다.
- command-finish 변경 전 같은 runner/config/workload의 보존된 결과와 비교하면 다음과 같다.

| WLOAD | 변경 전 total cycles | 변경 후 total cycles | 변화 | 변경 전 app cycles | 변경 후 app cycles | 변화 |
|---:|---:|---:|---:|---:|---:|---:|
| 4 | 3992 | 3963 | -29 (-0.73%) | 10330 | 10255 | -75 (-0.73%) |
| 8 | 3339 | 3131 | -208 (-6.23%) | 9655 | 9429 | -226 (-2.34%) |
| 16 | 3369 | 3132 | -237 (-7.03%) | 9656 | 9430 | -226 (-2.34%) |
| 32 | 3339 | 3131 | -208 (-6.23%) | 9655 | 9430 | -225 (-2.33%) |

- WLOAD8 trace에서 64개 input command 중 non-final 62개와 final 2개를 확인했다.
  non-final은 start부터 LDMA done까지 18 cycle, command done까지 19 cycle,
  raw last write까지 29 cycle이었다. final은 command done과 tagged last write가 모두
  start+29 cycle에 발생했다.
- non-final `RID_G` WAIT는 command마다 20 cycle block됐고 final 두 command는 30 cycle
  block됐다. 즉 non-final completion은 raw writeback보다 10 cycle 일찍 해제됐다.
- 그렇지만 이 workload에서 다음 input start가 이전 raw writeback보다 빨랐던 경우는
  0/63이었다. 보통 next start는 raw writeback 10 cycle 뒤였고, W/SZ readiness WAIT가
  남은 간격을 결정했다. 따라서 조기 completion은 전체 cycle을 줄였지만 실제 target의
  input admission이 forwarding 구간까지 당겨지지는 않았다. forwarding correctness는
  8.1의 directed `d=1/2/3` unittest가 담당한다.
- final ordering은 의도대로였다. 첫 final command는 tagged writeback 70.725 us,
  input NOTIFY sync update 70.735 us, `RID_G1` WAIT 만족 70.745 us 순으로 진행했고,
  실제 `OP_O_ACC2LMEM` child 실행은 70.765 us였다. FSM이 output command를 parent queue에
  미리 생성해도 child 실행은 final NOTIFY/WAIT 뒤로 보호된다. 두 번째 final command도
  같은 순서를 보였다.
- text trace만으로 completion, sync, 실제 child 실행 순서를 모두 판별할 수 있어 FSDB는
  추가로 생성하지 않았다.

주 비교 artifact:

```text
변경 전 WLOAD8:
build/run_logs/target_gemm/
  20260804-181532_run_wload8_m4_n256_k256_q32_t0_d1_pid1007157/

변경 후 WLOAD8:
build/run_logs/target_gemm/
  20260806-121946_run_wload8_m4_n256_k256_q32_t0_d1_pid573073/

변경 후 WLOAD8 trace:
build/run_logs/target_gemm/
  20260806-122550_trace_wload8_m4_n256_k256_q32_t0_d1_pid640256/
```

## 9. 기대 효과와 한계

non-final K iteration은 기존 writeback-based NOTIFY 대신 qualified I_LDMA idle에서 완료된다.
현재 파형에서는 last admission 이후 약 5 cycle로, 기존 sync-visible completion의 약 19
cycle보다 빨라진다. 다음 micro-K는 이전 command의 ACC writeback보다 먼저 시작할 수 있고,
동일 주소 dependency는 검증된 `d=1/2/3` forwarding/read contract가 처리한다.

ACC-to-TMEM 직전 final command는 tagged final writeback까지 NOTIFY를 지연하므로 별도의
`RID_GW`, GEMM sync port 또는 output-side writeback tracker 없이 ACC data visibility를
보장한다. 모든 sync register update는 기존 NOTIFY command 경로를 유지한다.

이 구조는 한 input child command와 paired NOTIFY를 순서대로 처리하며 동시에 outstanding인
final completion이 최대 하나라는 현재 FSM contract를 전제로 한다. accumulator latency는
`L_R/L_A/L_P=1/1/0`으로 고정한다.

NOTIFY update bypass는 사용하지 않고 active GEMM 중 reset을 금지하며, 새 macro 없이 현재
improved/V2 module 경로에만 새 completion contract를 적용하는 것으로 남은 설계 결정을
모두 확정했다.

# hard rule

계획 수행 도중에 계획한 설계에서 문제가 발견되면 즉시 멈추고 문제를 보고한다.
그 이후에 해결책을 논의한다.

# Result

GEMM input command completion 최적화와 forwarding 검증을 완료했다. RTL unittest와
`fpint_gemm_ffn_hw` XRT-VCS의 WLOAD 4/8/16/32가 모두 통과했으며, WLOAD8 기준 total
cycle은 3339에서 3131로 6.23% 감소했다. final writeback/NOTIFY/WAIT/ACC-to-TMEM 순서와
`psum_underflow=0`, `rd_wr_conflict=0`도 확인했다. 현재 target에서는 W/SZ readiness가
남은 병목이어서 next input이 이전 writeback보다 먼저 시작하지는 않았다.

Done
