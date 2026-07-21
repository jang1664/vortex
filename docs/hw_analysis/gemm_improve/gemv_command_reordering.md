# GEMV Micro-GEMM Command Reordering Proposal

## 1. 목적

`improve_th32`의 GEMV 실행에서 micro-GEMM 사이에는 약 14 cycle의
non-compute gap이 관찰된다. 이 문서는 해당 gap을 줄이기 위한 첫 번째 RTL
실험으로, 현재 GEMM에 대한 `ARM` command를 future-buffer preload command보다
먼저 발행하는 방법을 정리한다.

이 제안은 parent queue, sync module, child queue 구조를 바로 변경하지 않고
`VX_gemm_fsm`의 command 발행 순서만 조정하는 것을 목표로 한다.

## 2. Command 실행 모델

GEMM ARM과 W/SC/ZP preload command는 서로 다른 child queue로 전달된다.
따라서 다음 사항을 구분해야 한다.

- preload command의 발행은 preload의 완료를 의미하지 않는다.
- GEMM ARM은 preload command의 실제 완료를 암묵적으로 기다리지 않는다.
- command 진행을 멈추는 조건은 명시적인 `WAIT` command가 sync queue의
  head에서 조건 충족을 기다리는 경우이다.
- head의 `WAIT`가 장시간 blocking되면 parent queue가 가득 차고, 그 결과
  `gemm_fsm_if.flag.idle`이 내려가면서 FSM의 추가 command 발행도 멈춘다.
- 현재 GEMM에 필요한 weight와 scale/zero-point의 완료는
  `S_MXU_WAIT_CUR_W`와 `S_MXU_WAIT_CUR_SZ`에서 명시적으로 보장한다.

따라서 현재 순서에서 next preload가 ARM보다 앞에 있다는 것은 ARM이 preload
완료를 기다린다는 의미가 아니다. 다만 preload와 notify command들이
parent/sync dispatch 슬롯을 먼저 소비하므로, 이미 실행 준비가 끝난 현재
GEMM의 ARM 발행이 뒤로 밀린다.

## 3. 현재 Command 순서

steady-state의 주요 command 순서는 다음과 같다.

```text
WAIT_CUR_W
→ WAIT_CUR_SZ
→ NEXT_W
→ NEXT_W_NTF
→ NEXT_SC
→ NEXT_ZP
→ NEXT_SZ_NTF
→ ARM
→ ARM_NTF
→ WAIT_GEMM_DONE
```

`WAIT_CUR_W`와 `WAIT_CUR_SZ`가 통과한 시점에는 현재 GEMM이 사용하는 W/SZ
buffer가 준비되어 있다. 그러나 ARM보다 먼저 future buffer를 위한 preload 및
notify command 다섯 개를 발행한다.

이 command들은 child queue에 들어간 뒤 병렬로 실행될 수 있지만, parent/sync
경로에서는 ARM보다 먼저 한 개씩 dispatch되어야 한다. 따라서 preload의 실행
latency와 별개로 command issue latency가 현재 GEMM 시작 지연에 포함된다.

## 4. 제안하는 Command 순서

현재 GEMM의 readiness WAIT가 통과하면 ARM을 즉시 발행하고, future-buffer
preload는 현재 GEMM이 계산되는 동안 진행하도록 순서를 변경한다.

```text
WAIT_CUR_W
→ WAIT_CUR_SZ
→ ARM
→ ARM_NTF
→ NEXT_W
→ NEXT_W_NTF
→ NEXT_SC
→ NEXT_ZP
→ NEXT_SZ_NTF
→ WAIT_GEMM_DONE
```

핵심 조건은 `WAIT_GEMM_DONE`을 next preload command들보다 뒤에 두는 것이다.
이렇게 해야 GEMM completion WAIT가 sync queue head에서 blocking되기 전에 next
preload command들이 각 child queue로 dispatch될 수 있다.

기대되는 실행 형태는 다음과 같다.

```text
current W/SZ ready
→ current GEMM ARM
→ current GEMM compute와 next W/SC/ZP preload overlap
→ current GEMM completion WAIT 통과
→ next iteration의 W/SZ readiness 확인
→ next GEMM ARM
```

## 5. 기대 효과

이 reorder는 다음 효과를 목표로 한다.

1. `WAIT_CUR_SZ` 통과 후 ARM 앞에 있던 next preload/notify command issue 시간을
   GEMM compute 구간으로 이동한다.
2. 현재 GEMM compute와 서로 다른 child queue의 next preload 실행을 겹친다.
3. next preload command가 `RID_G0` 또는 `RID_G1` completion WAIT 뒤에서
   head-of-line blocking되는 상황을 줄인다.
4. parent/sync queue의 구조 변경 없이 command scheduling 효과를 먼저 측정한다.

이 변경만으로 14 cycle gap 전체가 제거된다고 가정해서는 안 된다. child queue
dispatch latency, input ARM 경로, 명시적 W/SZ WAIT, tile boundary 및 output 처리
등의 비용은 남을 수 있다.

## 6. Correctness 조건

reorder 구현 시 다음 조건을 확인해야 한다.

- 현재 GEMM이 참조하는 W/SC/ZP buffer의 readiness는 ARM 전에 기존과 동일하게
  보장되어야 한다.
- next preload는 현재 GEMM이 사용하는 ping-pong buffer가 아니라 반대편
  buffer만 갱신해야 한다.
- `ARM_NTF`는 ARM과 동일한 child 경로에서 기존 completion semantics를
  유지해야 한다.
- K tile 간 accumulator dependency와 `is_accum` 순서는 변하지 않아야 한다.
- `has_next_mxu == 0`인 마지막 micro-GEMM에서는 불필요한 next preload를
  발행하지 않아야 한다.
- 마지막 K tile의 output/store 전환은 GEMM completion 이후에만 진행되어야
  한다.

## 7. 검증 항목

변경 전후 동일한 `M=1, K=256, N=256` workload에서 다음 값을 비교한다.

### 7.1 주요 latency

- `S_MXU_WAIT_CUR_SZ`가 통과한 cycle부터 `OP_I_LDMA_ARM`이 parent/sync 경로에서
  dispatch되는 cycle까지의 거리
- ARM child queue가 command를 받아 실제 GEMM compute가 시작될 때까지의 거리
- 연속 micro-GEMM의 start-to-start interval
- micro-GEMM 종료 후 다음 compute 시작까지의 non-compute gap

### 7.2 Overlap과 blocking

- GEMM compute와 W/SC/ZP local DMA activity의 overlap
- `WAIT_GEMM_DONE`이 parent queue head에 도달하기 전에 next preload command가
  모두 child queue로 dispatch됐는지 여부
- parent queue full cycle 수
- `RID_G0`/`RID_G1`에 의해 blocked된 cycle 수
- `S_MXU_PRE_NEXT_SC`에서 `can_emit == 0`인 cycle 수

### 7.3 기능 검증

- GEMV 결과값이 변경 전과 bit-accurate하게 동일한지 확인
- 64개 micro-GEMM job이 모두 완료되는지 확인
- input, weight, psum 및 output backpressure/underflow counter에 regression이
  없는지 확인
- 첫 tile, 마지막 tile, K accumulation boundary에서 buffer reuse 오류가 없는지
  확인

## 8. 후속 단계

reorder 후에도 micro-GEMM 사이에 큰 gap이 남는다면 다음 순서로 확장한다.

1. 남은 gap을 explicit W/SZ WAIT, child dispatch, GEMM unit idle 대기 및 output
   boundary로 다시 분류한다.
2. `RID_G0`/`RID_G1` completion WAIT를 global ordered queue에서 분리하는 방안을
   검토한다.
3. command별 dependency 또는 별도 completion scoreboard를 도입하여 unrelated
   command가 completion WAIT를 우회할 수 있게 한다.
4. 필요하면 W, SC/ZP, GEMM ARM 및 output 경로의 독립 command queue 구조를
   검토한다.

parent queue depth를 단순히 늘리는 것은 우선순위가 낮다. queue full 발생을
늦출 수는 있지만, head의 explicit WAIT가 이후 command를 막는 ordered-queue
semantics 자체는 제거하지 못하기 때문이다.

