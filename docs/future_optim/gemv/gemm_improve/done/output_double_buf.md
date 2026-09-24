# GEMM Output Double Buffering Plan

## 목표

ACC MEM을 두 group으로 나눈 원래 목적을 실제 실행 overlap으로 연결한다.

```text
ACC group 0을 ACC2LMEM으로 drain하는 동안
ACC group 1에서 다음 MXU compute를 수행한다.
```

동시에 다음 correctness 조건을 명시적인 dependency로 보장한다.

- 같은 ACC group은 이전 owner의 `ACC2LMEM`이 모두 끝난 뒤에만 재사용한다.
- output LMEM 영역은 이전 `DMA_ST`가 끝난 뒤에만 덮어쓴다.
- 최종 job completion은 모든 `DMA_ST` 완료 이후에만 발생한다.
- Child command queue depth나 executor latency에 correctness가 의존하지 않는다.

이번 변경에서 completion tag는 추가하지 않는다. 현재 각 child executor는 active command를
하나만 허용하며 child별 completion은 issue 순서를 따른다. 이 계획에서 필요한 것은 completion
identity가 아니라 서로 다른 child 사이의 ACC group ownership dependency다.

## 현재 구조

### ACC group 선택

`VX_gemm_fsm`은 output tile의 `(mt, nt)` linear parity로 ACC group을 선택한다.

```systemverilog
acc_group_base = ((tile_cur_nt_q + nt_dim_q * tile_cur_mt_q) & 1)
               ? ACC_DBUF_STRIDE : 0;
```

같은 `(mt, nt)` tile의 모든 K tile은 같은 group에 누적되고, 다음 output tile은 반대 group을
사용한다.

```text
output tile 0 -> ACC group 0
output tile 1 -> ACC group 1
output tile 2 -> ACC group 0
output tile 3 -> ACC group 1
```

`VX_gemm_unit_v2`도 ACC address의 group bit를 이용해 물리적으로 분리된 RAM을 선택한다. 따라서
주소 생성과 RAM 배치는 이미 두 group을 구분한다.

### 현재 `RID_O`의 역할

현재 `RID_O` 하나가 모든 output slice를 다음과 같이 직렬화한다.

```text
ACC2LMEM(0) -> DMA_ST(0) -> ACC2LMEM(1) -> DMA_ST(1) -> ...
```

`RID_O`는 ACC group selector가 아니라 ACC2LMEM과 DMA_ST의 전역 순서 카운터다. 이 방식에는
두 가지 문제가 있다.

1. ACC group이 free가 되는 시점과 output LMEM이 free가 되는 시점을 하나의 counter로 표현한다.
2. 다음 compute는 `RID_O`를 기다리지 않으므로 같은 ACC group의 안전한 재사용을 명시적으로
   보장하지 않는다.

`S_WAIT_CUR_TILE_READY`에는 기존 `RID_O` reuse wait가 제거되어 있다. ARM command도 W, SZ,
이전 GEMM completion만 기다리고 ACC group release는 기다리지 않는다. Child command queue는
executor의 active slot과 별개로 여러 command를 저장할 수 있으므로, child당 active command가
하나라는 사실만으로 ACC group 재사용 안전성이 보장되지는 않는다.

### 실제 overlap을 막는 조건

현재 output ACC read ready는 전체 MXU pipeline이 비어 있어야 한다.

```systemverilog
o_lmem_bus_if.req_ready = gemm_unit_v2_if.pipeline_empty
                       && !output_read_valid;
```

따라서 compute가 group 1을 사용하고 output이 group 0을 읽는 경우에도 ACC2LMEM request가
막힌다. 현재 두 group은 주소 공간으로는 사용되지만, ACC2LMEM과 MXU compute의 동시 실행에는
사용되지 않는다.

## 제안하는 dependency 모델

### Sync register 배치

현재 사용 중인 RID 0-8은 유지하고 비어 있는 RID 9와 10을 ACC group release에 사용한다.

| RID | 이름 | 의미 |
| ---: | --- | --- |
| 4 | `RID_O` | 완료된 output `DMA_ST` 수, 즉 output LMEM reuse token |
| 9 | `RID_ACC_FREE0` | ACC group 0에서 완료된 `ACC2LMEM` slice 수 |
| 10 | `RID_ACC_FREE1` | ACC group 1에서 완료된 `ACC2LMEM` slice 수 |

Helper는 기존 buffer RID helper와 같은 형태로 둔다.

```systemverilog
function automatic mm_rid_t rid_acc_free(input logic group);
  return mm_rid_t'(group ? RID_ACC_FREE1 : RID_ACC_FREE0);
endfunction
```

`NUM_SYNC_REGS=11`과 command format은 그대로 유지한다. ARM command에는 현재 W, SZ, prior-G
세 개의 wait가 있으므로 남아 있는 `waits[3]`에 ACC release dependency를 넣을 수 있다.

### Counter 의미

FSM에 다음 issue-side counter를 둔다.

```text
acc_copy_issue[0] : group 0에 대해 발행한 ACC2LMEM slice 수
acc_copy_issue[1] : group 1에 대해 발행한 ACC2LMEM slice 수
o_store_issue     : 발행한 DMA_ST 수
```

Sync register는 완료 수를 나타내고 issue-side counter는 발행 수를 나타낸다.

```text
RID_ACC_FREE[g] >= acc reuse target
    이전 owner가 사용한 group g의 모든 slice가 ACC에서 빠져나갔다.

RID_O >= output LMEM reuse target
    이전에 발행한 store가 완료되어 output LMEM을 덮어써도 된다.
```

`RID_ACC_FREE`는 이름과 달리 tile당 한 번만 증가시키는 boolean token이 아니다. Edge tile마다
`output_nt_mxu_dim`이 달라질 수 있으므로 완료된 ACC2LMEM slice의 누적 count로 사용한다. 같은
group을 재사용하는 ARM은 이전 owner의 마지막 slice target을 기다린다.

### Command별 wait/notify

각 work command는 notify metadata를 하나만 가질 수 있다. 다음 분배를 사용하면 command format을
확장하지 않고 두 lifetime을 분리할 수 있다.

| Command | Wait | Completion notify |
| --- | --- | --- |
| `I_LDMA_ARM` | W ready, SZ ready, prior G done, `RID_ACC_FREE[g] >= reuse_target[g]` | 기존 `RID_G` |
| `O_ACC2LMEM` | prior G done, `RID_O >= o_store_issue` | `RID_ACC_FREE[g] = copy_target` |
| `DMA_ST` | `RID_ACC_FREE[g] >= copy_target` | `RID_O += 1` |

여기서 `copy_target`은 해당 ACC2LMEM을 발행할 때의 다음 group-local sequence다.

```systemverilog
copy_target = acc_copy_issue_q[group] + 1;
```

ACC2LMEM command는 completion 시 `RID_ACC_FREE[group]`을 `copy_target`으로 SET하고,
`acc_copy_issue[group]`을 증가시킨다. 바로 다음에 생성되는 DMA_ST command는 같은
`copy_target`을 wait한다.

ACC2LMEM은 현재 output LMEM 영역을 덮어쓰기 전에 이전 DMA_ST가 끝났는지 확인한다.

```systemverilog
acc2lmem.waits[0] = wait(RID_O, o_store_issue_q);
```

DMA_ST가 완료되면 `RID_O += 1`한다. 따라서 다음 ACC2LMEM은 이전 output LMEM consumer가
끝난 뒤에만 실행된다.

### ACC reuse target capture

새 output tile이 compute를 시작할 때 선택된 group의 현재 issue count를 tile-local reuse target으로
capture한다.

```systemverilog
tile_acc_group_q        = output_tile_linear[0];
tile_acc_reuse_target_q = acc_copy_issue_q[tile_acc_group_q];
```

그 tile의 모든 ARM command는 다음 dependency를 갖는다.

```systemverilog
arm.waits[3] = wait(rid_acc_free(tile_acc_group_q),
                    tile_acc_reuse_target_q);
```

첫 owner는 target이 0이므로 즉시 실행할 수 있다. Tile 2가 group 0을 재사용할 때는 tile 0의
마지막 ACC2LMEM target을 기다린다. Tile 0의 DMA_ST가 아직 진행 중이어도 ACC data는 이미
output LMEM으로 복사되었으므로 group 0을 재사용할 수 있다.

`tile_acc_reuse_target_q`는 tile 시작 시 capture하고 tile 실행 중에는 바꾸지 않는다. 그렇지 않으면
현재 tile의 output command가 `acc_copy_issue`를 증가시킨 뒤 같은 tile의 ARM dependency 의미가
달라질 수 있다.

## 실행 예시

설명을 단순화하기 위해 output tile마다 ACC2LMEM slice가 하나라고 가정한다.

초기 상태:

```text
RID_ACC_FREE0 = 0
RID_ACC_FREE1 = 0
RID_O         = 0
```

Tile 0은 group 0을 사용한다.

```text
ARM(0)
  wait ACC_FREE0 >= 0
  compute group 0

ACC2LMEM(0)
  wait GEMM(0) done
  wait RID_O >= 0
  copy group 0 -> output LMEM
  done: ACC_FREE0 = 1

DMA_ST(0)
  wait ACC_FREE0 >= 1
  store output LMEM -> DRAM
  done: RID_O += 1
```

Tile 1은 group 1을 사용하므로 Tile 0의 ACC2LMEM과 겹칠 수 있다.

```text
ARM(1):        compute group 1
ACC2LMEM(0):  drain group 0
```

Tile 2는 group 0을 재사용한다.

```text
ARM(2)
  wait ACC_FREE0 >= 1
```

이 시점에는 Tile 0의 ACC2LMEM이 끝났으므로 group 0은 안전하다. `DMA_ST(0)`은 ACC MEM이
아니라 output LMEM을 읽기 때문에 ARM(2)와 겹칠 수 있다.

정상 steady state는 다음과 같다.

```text
time -------------------------------------------------------------->

MXU:      COMPUTE-0    COMPUTE-1    COMPUTE-2    COMPUTE-3
ACC G0:   write-0      drain-0      write-2      drain-2
ACC G1:                write-1      drain-1      write-3
DMA:                   store-0      store-1      store-2
```

## Group-aware ACC read arbitration

Dependency 변경만 적용하면 same-group overwrite correctness는 보장할 수 있지만, 기존
`pipeline_empty` gate 때문에 실제 ACC2LMEM/MXU overlap은 생기지 않는다. 두 번째 단계에서
output read ready를 group-aware하게 바꾼다.

개념적인 조건은 다음과 같다.

```systemverilog
output_group_conflict = compute_group_busy[output_read_group];

o_lmem_bus_if.req_ready = !output_read_valid
                       && !output_group_conflict;
```

필요한 상태는 2-bit group busy vector 또는 동등한 정보다.

```text
compute_group_busy[0] = group 0을 접근하는 compute request/pipeline이 존재
compute_group_busy[1] = group 1을 접근하는 compute request/pipeline이 존재
```

다음 경우를 구분해야 한다.

| Compute group | Output group | 허용 여부 |
| ---: | ---: | --- |
| 0 | 0 | block |
| 0 | 1 | allow |
| 1 | 0 | allow |
| 1 | 1 | block |

ACC RAM은 group별로 물리 메모리가 분리되어 있으므로 다른 group이면 RAM port 충돌이 없다.
다만 implementation 시 다음을 함께 확인한다.

- ARM accept와 output request가 같은 cycle에 발생하는 경우 incoming compute group까지 conflict
  판정에 포함한다.
- ACC writeback pipeline에 남은 request의 group을 busy 상태에서 너무 일찍 제거하지 않는다.
- 같은 physical ACC bank에 compute read/write와 output read가 동시에 들어가지 않는다는 assertion을
  추가한다.
- FP32-to-FP16 output conversion path가 compute datapath와 공유하는 별도 state/resource가 있는지
  확인한다.

## 구현 단계

### Phase 1: ACC ownership dependency 추가

대상 파일:

- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/unittest/gemm_fsm/tb_VX_gemm_fsm.sv`
- `hw/unittest/gemm_ctrl/tb_VX_gemm_ctrl.sv`

작업:

1. RID 9/10을 `RID_ACC_FREE0/1`로 선언하고 helper를 추가한다.
2. Group별 `acc_copy_issue_q`와 tile-local `tile_acc_reuse_target_q`를 추가한다.
3. ARM의 `waits[3]`에 ACC group reuse dependency를 추가한다.
4. ACC2LMEM notify를 `RID_ACC_FREE[group] = copy_target`으로 변경한다.
5. DMA_ST가 해당 `copy_target`을 기다린 뒤 `RID_O += 1`하도록 변경한다.
6. ACC2LMEM의 `RID_O` wait target을 완료된 store count 의미로 단순화한다.
7. Final drain은 `RID_O >= o_store_issue_q`를 기다리도록 갱신한다.
8. Reset/new invocation 시 issue counter와 captured target을 0으로 초기화한다.

이 단계에서는 `pipeline_empty` gate를 유지한다. 먼저 queue latency와 backpressure에 무관한 ACC
ownership correctness를 확립한다.

### Phase 2: Group-aware concurrent access 허용

대상 파일:

- `hw/rtl/core/gemm/VX_gemm_node.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`
- 관련 GEMM unit/node unittest

작업:

1. Active/incoming compute ACC group을 추적한다.
2. 전체 `pipeline_empty` 조건을 same-group conflict 조건으로 대체한다.
3. 다른 group의 compute와 output read가 같은 cycle 또는 overlapping interval에 진행되도록 한다.
4. Same-group access는 기존처럼 block하고 output response ordering은 유지한다.

### Phase 3: Output LMEM 병목 재평가

이번 계획은 output LMEM을 하나의 global lifetime domain으로 유지하므로 `RID_O`가 모든 DMA_ST를
직렬화한다. ACC double buffering을 먼저 검증한 뒤 다음 항목을 별도 최적화로 평가한다.

- `o_nt_mxu`별 LMEM slice가 실제로 disjoint한 범위
- output LMEM을 두 slot으로 나눌 필요성
- `RID_O0/1` 또는 per-LMEM-slot store token의 성능 효과
- global DMA child가 두 store를 pipeline할 수 있게 된 이후 tag 필요성

이 단계는 ACC group correctness에 필요하지 않으므로 첫 구현 범위에는 포함하지 않는다.

## Assertion 및 unittest 계획

### FSM command metadata

- ARM의 ACC group RID가 address의 group bit와 일치해야 한다.
- 첫 owner의 reuse target은 0이어야 한다.
- 같은 group의 reuse target은 이전 owner의 마지막 ACC2LMEM target과 같아야 한다.
- Group별 ACC2LMEM target은 strictly increasing이어야 한다.
- DMA_ST의 ACC wait target은 바로 앞 대응 ACC2LMEM의 target과 같아야 한다.
- ACC2LMEM의 `RID_O` target과 DMA_ST issue count가 일관되어야 한다.
- Final drain target은 총 DMA_ST 발행 수와 같아야 한다.

### Controller dependency behavior

다음 directed scenario를 만든다.

1. Child 3 ACC2LMEM completion을 의도적으로 지연한다.
2. 반대 group의 ARM은 issue되는지 확인한다.
3. 같은 group을 재사용하는 ARM은 `RID_ACC_FREE[group]`에서 block되는지 확인한다.
4. ACC2LMEM completion과 같은 cycle에 effective-sync bypass로 ARM이 issue 가능한지 확인한다.
5. Child 4 DMA_ST를 지연해도 ACC2LMEM 완료 후 같은 ACC group의 ARM은 진행하는지 확인한다.
6. 반대로 같은 output LMEM을 쓰는 다음 ACC2LMEM은 `RID_O`에서 block되는지 확인한다.

### ACC RAM arbitration

- `compute_group == output_group`일 때 output request fire 금지.
- `compute_group != output_group`일 때 양쪽 ready/valid가 만족되면 동시 진행 허용.
- 동일 physical bank에 두 access source가 동시에 선택되지 않아야 한다.
- Output response data/tag ordering은 기존과 동일해야 한다.

## XRT-VCS 검증 계획

Repository 지침에 따라 configured build directory에서 적절한 `configs/` 설정을 source한 뒤
`ci/run_black.sh xrt-vcs-sim`을 사용한다.

검증 순서:

1. 기존 baseline과 동일한 WLOAD8 workload로 functional result를 비교한다.
2. 최소 세 개의 output tile을 만드는 shape를 포함해 group 0 재사용을 반드시 발생시킨다.
3. M/N edge tile로 `output_nt_mxu_dim`이 달라지는 case를 실행한다.
4. K tile이 여러 개인 case로 같은 output tile 안의 accumulation이 동일 group을 유지하는지 확인한다.
5. Output/HBM backpressure가 큰 case에서 same-group reuse가 안전한지 확인한다.
6. FSDB에서 다음 구간과 counter를 다시 추출한다.

```text
MXU compute active cycles
ACC2LMEM active cycles
MXU && ACC2LMEM overlap cycles
DMA_ST active cycles
MXU && DMA_ST overlap cycles
RID_ACC_FREE0/1 wait cycles
RID_O wait cycles
same-group conflict block cycles
different-group overlap opportunity/accepted cycles
```

성능 지표는 다음처럼 분리한다.

```text
ACC drain hidden by MXU = cycles(MXU && ACC2LMEM) / cycles(ACC2LMEM)
DMA hidden by MXU       = cycles(MXU && DMA_ST)    / cycles(DMA_ST)
```

부수 작업이 compute에 얼마나 가려지는지를 보는 지표이므로 분모는 각각 ACC2LMEM과 DMA active
cycle로 둔다.

## 완료 조건

- 모든 functional unittest와 XRT-VCS blackbox가 통과한다.
- 세 번째 output tile의 same-group reuse가 이전 ACC2LMEM completion에 의해 명시적으로 보호된다.
- Child queue depth와 executor latency를 바꿔도 dependency assertion이 유지된다.
- FSDB에서 서로 다른 ACC group에 대해 MXU compute와 ACC2LMEM이 동시에 active인 cycle이 관찰된다.
- 같은 group의 compute/ACC2LMEM 동시 access는 0회다.
- Final completion 시 `RID_O == total DMA_ST issued`이고 모든 child queue/inflight가 비어 있다.
- Baseline 대비 numerical output이 동일하다.

## 예상 위험과 대응

- **Variable output slice count:** Tile generation만으로 target을 계산하지 않고 group별 누적 slice
  count를 사용한다.
- **Same-cycle start conflict:** Registered busy bit만 보지 않고 incoming ARM request까지 arbitration에
  포함한다.
- **Busy release가 너무 빠름:** Last ACC writeback까지 group busy를 유지한다.
- **Counter mismatch:** Issue counter, command target, completion counter 사이의 monotonic assertion을
  추가한다.
- **한 command당 notify 하나:** ACC2LMEM은 `RID_ACC_FREE`, DMA_ST는 `RID_O`만 update하도록 역할을
  고정한다.
- **Output LMEM 직렬화:** 첫 단계에서는 correctness를 위해 유지하고, ACC overlap 확보 후 별도로
  완화한다.
- **향후 multi-inflight/out-of-order completion:** In-order completion이 유지되는 동안 tag는 필요 없다.
  Out-of-order completion을 허용할 때 command tag와 completion tag를 함께 도입한다.

## 권장 구현 순서

1. Phase 1 dependency 변경과 directed unittest로 ownership correctness를 먼저 고정한다.
2. 기존 `pipeline_empty` gate 상태에서 XRT-VCS correctness regression을 수행한다.
3. Phase 2 group-aware arbitration과 collision assertion을 추가한다.
4. XRT-VCS FSDB로 실제 ACC2LMEM/MXU overlap과 성능 변화를 측정한다.
5. `RID_O` wait가 새로운 주 병목으로 남을 때만 output LMEM double buffering을 후속 작업으로
   분리한다.

# Hard rule

계획 수행 도중에 계획한 설계에서 문제가 발견되면 즉시 멈추고 문제를 보고한다.  그 이후에 해결책을 논의한다.