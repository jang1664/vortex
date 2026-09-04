# 문제점

DMA engine이 하나의 CMD만 수행 가능하다. VX_gemm_fsm이 OUTPUT_STORE를 issue해서 DMA engine이 output store를 수행하면
그 이후에 INPUT_LOAD cmd를 fsm이 생성해도 OUTPUT_STORE가 끝날 때 까지 INPUT_LOAD는 수행되지 않는다. 즉 OUTPUT_STORE에서
그 다음 INPUT_LOAD->COMPUTE 가 overlap 될 수 없다.

# 확정된 해결책

## 적용 범위와 구조

- HBM tile DMA 경로에만 multi-command scheduling을 추가한다. 다른 local DMA 경로는 변경하지 않는다.
- logical DMA command queue와 priority scheduler는 `VX_gemm_tmem_dma_ctrl`에 구현한다.
- 기존 `VX_dma_engine`과 `VX_dma_unit`은 한 번에 하나의 완결된 descriptor를 실행하는 구조를 유지한다.
- 실행 중인 chunkable `OUTPUT_STORE`를 중간 상태에서 정지시키는 대신, `VX_gemm_tmem_dma_ctrl`이 store를 독립적으로 완료 가능한 작은 descriptor chunk들로 나눈다.
- fallback 또는 channel별 descriptor form이 섞인 non-chunkable `OUTPUT_STORE`는 기존 full descriptor를 수정하지 않고 한 번에 실행한다.
- scheduler는 각 chunk가 완전히 끝난 시점에만 다음 logical command를 선택한다.

구조는 다음과 같다.

```text
VX_gemm_ctrl
  - DMA child command FIFO: depth 8
  - DMA inflight scoreboard: 8 slots
  - tagged command / tagged completion
        |
VX_gemm_tmem_dma_ctrl
  - pending command queue: parameterized, default depth 4
  - active/paused OUTPUT_STORE context: 1
  - priority scheduler
  - existing per-channel descriptor generator
  - registered OUTPUT_STORE descriptor chunk stage
        |
기존 VX_dma_engine / VX_dma_unit
```

## Queue와 inflight command

- `VX_gemm_tmem_dma_ctrl`의 pending queue depth는 parameterize하고 default를 4로 한다.
- pending depth 4는 active context를 포함하지 않는다. 따라서 `OUTPUT_STORE` 하나가 active 또는 paused인 동안 다음 tile의 `I/W/SC/ZP` 네 command를 모두 pending 상태로 수용할 수 있다.
- DMA child command FIFO는 `VX_gemm_ctrl` 안에서 FSM이 생성했지만 아직 DMA executor가 accept하지 않은 command를 보관하는 controller-side `u_child_cmd_queue`의 DMA child(index 4) instance를 뜻한다. 이 FIFO의 depth는 8로 한다.
- DMA child FIFO의 head command는 dependency가 만족되고 inflight slot을 확보한 뒤 `cmd_valid`로 제시된다.
- `cmd_valid && cmd_ready` handshake가 DMA child FIFO와 accepted/inflight command의 경계다. handshake cycle에 child FIFO를 pop하고, 같은 command를 `VX_gemm_tmem_dma_ctrl` pending queue에 push하며, 해당 tag slot을 inflight로 확정한다.
- controller에서 executor가 accept한 DMA command를 추적하는 inflight slot은 8개로 확장한다.
- 각 DMA command에는 tag를 부여한다. 8개의 inflight slot을 직접 식별할 경우 tag는 최소 3 bit가 필요하다.
- command tag는 `gemm_unified_cmd_t`에 추가하지 않고 DMA 전용 `cmd_tag` sideband로 전달한다.
- controller는 free slot 중 하나를 issue tag로 선택하여 `cmd_valid`와 함께 제시한다. backpressure가 걸리면 선택한 tag를 예약하고 handshake까지 변경하지 않는다.
- tag slot은 logical command가 `VX_gemm_tmem_dma_ctrl`에 accept되는 handshake cycle에 inflight로 확정하며, completion 전에는 재사용하지 않는다.
- controller는 inflight slot마다 원래 command의 notify/RID 관련 metadata를 저장한다.
- DMA completion은 DMA 전용 `done_tag` sideband로 tag를 반환하며 controller는 FIFO head가 아니라 해당 tag의 inflight metadata에 completion을 적용한다.
- completion된 slot은 해당 cycle 끝에서 release한다. 같은 cycle에 release되는 slot을 새 command에 allocation하지 않으며 다음 cycle부터 free slot로 사용할 수 있다.
- inflight slot이 모두 사용 중이면, 같은 cycle에 completion이 발생하더라도 새 command handshake는 하지 않고 다음 cycle에 재시도한다.
- command issue 순서와 completion 순서는 다를 수 있다. 한 개의 underlying DMA를 사용하므로 completion channel은 한 cycle에 최대 한 개의 tagged completion을 반환한다.

## Command acceptance interface

DMA command 전달에는 다음 interface를 사용한다.

```text
cmd_valid  // controller가 유효한 cmd/cmd_tag를 제시
cmd_ready  // VX_gemm_tmem_dma_ctrl pending queue에 수용 공간이 있음
cmd        // DMA command
cmd_tag    // DMA 전용 sideband
```

- command는 `cmd_valid && cmd_ready`인 cycle에만 accept된다.
- controller는 `cmd_valid == 1 && cmd_ready == 0`인 동안 `cmd`와 `cmd_tag`를 stable하게 유지한다.
- `cmd_ready`는 pending queue의 수용 가능 여부를 나타내며 DMA가 현재 descriptor를 실행 중이어도 queue에 공간이 있으면 1일 수 있다.
- tag는 controller가 `cmd_valid`와 함께 제시하고 handshake가 발생한 cycle에 inflight slot에 할당된 것으로 확정한다.
- 기존 `idle`은 command acceptance에 사용하지 않는다. 전체 DMA 경로가 drain되어 outstanding logical command가 없다는 상태 표시로만 사용한다.
- logical command completion은 기존 `done` pulse와 DMA 전용 `done_tag` sideband로 반환한다. controller는 completion에 backpressure를 걸지 않고 매 cycle 수용한다.

## Priority와 ordering

- `INPUT_LOAD`는 high priority, `OUTPUT_STORE`는 low priority로 한다.
- DMA command에 새로운 `dma_priority` field를 추가한다. 현재 두 priority만 사용하므로 `0`은 low priority, `1`은 high priority로 encoding한다.
- `OUTPUT_STORE`를 생성할 때 `dma_priority = 0`, `INPUT_LOAD`를 생성할 때 `dma_priority = 1`로 설정한다.
- 같은 priority 안에서는 command issue 순서를 유지하는 FIFO policy를 사용한다.
- `I/W/SC/ZP`는 모두 같은 high priority FIFO를 사용하며 bundle 내부의 issue/completion 순서를 유지한다.
- 여러 `OUTPUT_STORE` command도 issue/completion 순서를 유지한다. paused store보다 뒤에 들어온 store가 먼저 실행될 수 없다.
- preemption은 store chunk가 완전히 끝난 뒤 `OUTPUT_STORE -> INPUT_LOAD` 방향으로만 허용한다.
- non-chunkable store는 full descriptor 전체가 하나의 chunk이므로 descriptor가 완전히 끝난 뒤에만 재중재한다.
- 한번 선택된 `INPUT_LOAD`는 다른 command에 의해 preempt되지 않고 logical command 전체가 끝날 때까지 실행한다.
- high-priority queue가 비면 가장 오래된 paused store를 재개한다.
- arbitration은 8개 HBM channel에 대해 하나의 global scheduler가 수행한다. channel별로 독립적인 command 전환은 허용하지 않는다.

## Descriptor pipeline과 store chunk

- 기존 `VX_gemm_tmem_dma_ctrl`의 logical command decode와 8개 channel별 descriptor 계산을 그대로 유지한다.
- 기존 계산 결과인 channel별 base, stride, `BND0/BND1/BND2`, `SEG_SIZE`를 먼저 full descriptor로 capture하는 pipeline stage를 추가한다.
- full descriptor 뒤에 registered chunk stage를 추가한다. `INPUT_LOAD`와 non-chunkable `OUTPUT_STORE`는 full descriptor를 그대로 한 번 issue하고, chunkable `OUTPUT_STORE`만 여러 개의 완결된 descriptor로 분할한다.
- `DMA_R_SEG_SIZE`는 descriptor 전체 크기가 아니라 한 beat의 크기이므로 기존처럼 `MEM_BLOCK_SIZE`, 즉 64 B로 유지한다.
- channel별 full descriptor의 전체 beat 수는 `BND0 * BND1 * BND2`이고 전체 byte 수는 `SEG_SIZE * BND0 * BND1 * BND2`다.
- chunk stage는 `SEG_SIZE`를 변경하지 않고 chunk의 `BND0/BND1/BND2`와 source/destination base를 계산한다.

## Maximum chunk encoding

- DMA command에 새로운 `dma_max_chunk_log2p1` field를 추가한다. max chunk의 단위는 channel당 beat 수다.
- max chunk는 power-of-two만 허용한다.
- `dma_max_chunk_log2p1 == 0`은 scheduler 차원의 chunk 제한이 없다는 의미다.
- `dma_max_chunk_log2p1 > 0`이면 `max_chunk_beats = 1 << (dma_max_chunk_log2p1 - 1)`로 decode한다.
- encoding 예시는 `1 -> 1 beat`, `2 -> 2 beats`, `3 -> 4 beats`, `4 -> 8 beats`, `5 -> 16 beats`, `6 -> 32 beats`다.
- `OUTPUT_STORE`의 초기 compile-time parameter는 8 beat-per-channel이고 command에는 `dma_max_chunk_log2p1 = 4`를 기록한다.
- `INPUT_LOAD`는 `dma_max_chunk_log2p1 = 0`으로 설정하여 scheduler 차원의 추가 chunk 제한을 적용하지 않는다. 이것은 AXI burst length가 무제한이라는 의미가 아니다.

## Store descriptor chunk 계산

misalignment는 없다고 가정한다. HBM/TMEM base의 channel-slot alignment 조건은 기존 assertion을 만족해야 한다.

### Chunkable 판정과 fallback/mixed descriptor 처리

- full descriptor capture 이후 8개 channel 모두 active이고, 모든 channel이 기존 burst-mode descriptor를 생성하며, 모든 channel의 전체 beat 수와 `BND0/BND1/BND2`가 동일할 때만 해당 store를 chunkable로 판정한다.
- 위 조건 중 하나라도 만족하지 않는 fallback 또는 mixed-channel store는 non-chunkable이다.
- non-chunkable store는 registered chunk stage를 bypass하지 않고, stage가 capture한 channel별 full descriptor를 변경 없이 단 한 번 issue한다. 즉 각 channel의 active mask, base, stride, `BND0/BND1/BND2`, `SEG_SIZE`를 그대로 보존한다.
- non-chunkable store에는 `dma_max_chunk_log2p1` 제한과 아래 burst-form chunk equation을 적용하지 않는다. 해당 full descriptor 전체가 하나의 scheduling chunk이므로 실행 중 preemption하지 않는다.
- non-chunkable store 실행 중 도착한 high-priority load는 pending queue에 보관하고, full descriptor와 모든 response가 drain된 다음 arbitration에서 우선 선택한다.
- non-chunkable store도 tagged logical completion, `RID_O`, `store_done`, ordering, idle 계약은 chunkable store와 동일하다.
- 예를 들어 현재 fixed `M=4` workload의 256 B store는 4개 channel만 active이고 각 active channel이 `BND0/BND1/BND2=1/1/1` fallback descriptor를 생성하므로 non-chunkable full descriptor로 한 번 실행한다.

이하의 chunk 계산은 chunkable store에만 적용한다. 이 경우 output store 크기는 8개 channel에 균등하게 분배되며 기존 burst-mode descriptor를 생성한다.

원래 channel descriptor의 값을 `orig_bnd0`, `orig_bnd1`, `orig_bnd2`, `orig_src_base`, `orig_dst_base`라고 한다.

- `orig_bnd2`는 한 channel이 순회하는 bank group 수이며 chunk에서도 가능한 한 원래 값을 그대로 유지한다.
- target configuration에서는 `orig_bnd2 = 4`이고 실험할 max chunk 4/8/16/32는 모두 `orig_bnd2` 이상인 power-of-two다.
- `max_chunk_beats >= orig_bnd2`를 요구한다.
- `bank_budget = max_chunk_beats / orig_bnd2`로 각 bank group에서 한 chunk가 처리할 beat budget을 구한다. power-of-two 값만 허용하므로 shift로 계산한다.
- bank group 하나의 전체 beat 수는 `orig_bnd0 * orig_bnd1`이다. chunk context는 `bank_beat_cursor`와 `remaining_beats_per_bank`를 보존한다.
- `bank_budget >= orig_bnd0`이면 `chunk_bnd0 = orig_bnd0`, `chunk_bnd1 = min(remaining_beats_per_bank / orig_bnd0, bank_budget / orig_bnd0)`로 한다.
- `bank_budget < orig_bnd0`이면 `chunk_bnd0 = bank_budget`, `chunk_bnd1 = 1`로 하여 원래 `BND0` 자체를 여러 chunk로 나눈다.
- `chunk_bnd2 = orig_bnd2`로 유지한다.
- `chunk_beats_per_bank = chunk_bnd0 * chunk_bnd1`이고, chunk의 channel당 전체 beat 수는 `chunk_bnd0 * chunk_bnd1 * chunk_bnd2`로서 항상 max chunk 이하다.
- chunk source/destination base는 각각 `orig_base + bank_beat_cursor * orig_ST0`로 계산한다. 기존 descriptor에서 `ST1 = orig_bnd0 * ST0`이므로 flattened bank beat cursor와 원래 `BND0/BND1` 주소가 동일하다.
- chunk의 `ST0`와 `ST2`는 원래 값을 유지하고, `ST1`은 `chunk_bnd0 * ST0`로 계산한다. `chunk_bnd0 < orig_bnd0`인 경우 `chunk_bnd1 = 1`이므로 `ST1`은 실제 주소 생성에는 사용되지 않는다.
- chunk 완료 후 `bank_beat_cursor += chunk_beats_per_bank`, `remaining_beats_per_bank -= chunk_beats_per_bank`로 갱신한다.
- `remaining_beats_per_bank == 0`이 된 chunk가 logical store의 마지막 chunk다.
- chunk stage는 원래 descriptor보다 `BND0`을 증가시키지 않는다. 따라서 기존 generator가 계산한 AXI 최대 burst 및 4 KB boundary 안전 조건을 유지한다.

예를 들어 `SEG_SIZE=64 B`, `BND0=2`, `BND1=9`, `BND2=4`, max chunk가 8 beat-per-channel이면 다음과 같다.

```text
bank_budget = 8 / 4 = 2
chunk_BND0  = 2
chunk_BND1  = 1
chunk_BND2  = 4
chunk beats = 2 * 1 * 4 = 8 beats/channel
```

총 9개의 chunk를 issue하며 chunk `k`의 base는 `orig_base + k * orig_ST1`이다. max chunk가 16이면 `chunk_BND0=2`, `chunk_BND1=2`, `chunk_BND2=4`로 네 개의 16-beat chunk와 마지막 8-beat chunk를 생성한다. max chunk가 4이면 `chunk_BND0=1`, `chunk_BND1=1`, `chunk_BND2=4`로 원래 `BND0`을 두 번에 나눈다.

- 각 chunk는 모든 `BND2` bank group을 포함하므로 원래 단일 descriptor와 비교해 `BND1/BND2`의 실행 순서는 일부 재배치될 수 있다.
- chunking은 `OUTPUT_STORE`에만 적용되고, source TMEM은 logical store가 끝날 때까지 유지되며, source/destination alias가 없고, 모든 주소를 정확히 한 번씩 처리하므로 이 재배치는 기능 결과에 영향을 주지 않는다.
- store chunk는 8개 channel의 해당 chunk 작업과 모든 write response가 drain된 뒤에만 완료된 것으로 판단한다. 그 이후에만 scheduler가 재중재한다.
- paused store context에는 logical command tag, 원래 notify 정보, full descriptor, `bank_beat_cursor`, `remaining_beats_per_bank`를 보존한다.

## Completion과 idle semantics

- chunk completion은 logical DMA command completion이 아니다.
- `OUTPUT_STORE`의 `done`, `store_done`, `RID_O` notify는 모든 chunk가 끝난 logical store 완료 시점에 정확히 한 번만 발생한다.
- `INPUT_LOAD`도 logical command 전체가 끝난 뒤에만 tagged completion을 반환한다.
- tag 기반 completion을 사용하므로 먼저 issue된 paused store보다 뒤의 input load가 먼저 완료되어도 올바른 RID/notify가 갱신되어야 한다.
- `VX_gemm_tmem_dma_ctrl`의 idle은 pending queue가 비어 있고, active load가 없고, active/paused store가 없고, DMA engine이 idle이며, outstanding read/write response가 모두 drain된 상태를 의미한다.

## Forward progress

- aging은 구현하지 않는다.
- high-priority load는 tile당 `I/W/SC/ZP`의 유한한 bundle로 생성된다.
- high-priority queue가 소진되면 paused store를 반드시 재개한다.
- final drain에서는 신규 load가 생성되지 않으므로 모든 paused/pending store가 최종적으로 완료되어야 한다.

## Store chunk length 성능 tuning

- store chunk 길이는 compile-time parameter로 만들고 초기 default는 8 beat-per-channel로 한다.
- xrt-vcs blackbox build에서는 repository 표준 `CONFIGS` 경로의
  `-DGEMM_DMA_STORE_MAX_CHUNK_BEATS={4,8,16,32}`로 설정을 선택한다.
  `VX_config.vh`의 default는 8이며 `VX_core -> VX_gemm_node -> VX_gemm_ctrl
  -> VX_gemm_fsm` parameter 경로를 통해 store command encoding에 반영한다.
- 최소한 4/8/16/32 beat-per-channel 설정을 동일 workload에서 비교한다.
- 모든 설정에서 numerical result와 logical completion semantics가 동일해야 한다.
- total cycle, store-to-load 전환 latency, load/compute overlap, context switch 횟수, queue occupancy, AXI utilization을 측정한다.
- overlap 개선과 잦은 chunk 전환에 따른 AXI 효율 저하를 함께 비교하여 최종 default를 결정한다.
- 성능 tuning workload는 chunkable store를 생성하는 geometry를 사용한다. fallback/mixed store workload는 numerical result와 logical completion correctness 대상으로 유지하지만, unchunked 정책상 store 중간 preemption이나 store/load overlap 개선을 기대하지 않는다.
- `DBG_TRACE_GEMM` simulation trace의 `TMEM_DMA_SCHED_PERF` marker에서 pending
  occupancy sample/sum/max, descriptor 및 store chunk issue/completion 수,
  logical completion 수, store-to-load context switch 수, switch latency
  count/sum/max, `input_load_active_cycles`, `compute_active_cycles`,
  `input_load_compute_overlap_cycles`를 수집한다. 마지막 세 값은 각각 실제
  load descriptor in-flight, 기존 GEMM V2 `!pipeline_empty` compute predicate,
  두 predicate의 동일-cycle 교집합이다. 개별 accept/select/chunk/logical-completion event는
  tag, chunkable/bypass mode, cursor와 remaining 값을 포함한다. total cycle과
  기존 all-DMA-union/MXU overlap은 perf class 3, AXI/HBM utilization은 perf class 4를 사용한다.

### 2026-08-07 xrt-vcs tuning 결과

- build directory: `build_multi_cmd_dma` (`../configure --xlen=64 --tooldir=/opt/vortex --prefix=/home/jaeyongjang/tools/vortex`)
- base config: `configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`
- workload: `fpint_gemm_ffn_hw -m 384 -n 32 -k 128 -q 32 -t 0 -d 0`, 1 core
- 실행: `ci/run_black.sh xrt-vcs-sim`, `-DDBG_TRACE_GEMM -DDISABLE_FSDB`, perf class 3/4
- 이 workload는 128x32 output tile당 8192 B store, 즉 channel당 16 beats를 생성하고 DMA tile이 3개이다. 따라서 4/8-beat 설정은 tile0 store 중 tile2 `INPUT_LOAD`를 선점하며, 16/32-beat 설정은 full store가 하나의 chunk에 들어가 중간 선점 지점이 없다.

| max chunk (beats/ch) | result | total cycles (class 3) | DMA+MXU overlap | direct IL∩compute / IL | store chunks | store->load switch / latency | pending avg / max (class 3) | HBM active/busy | HBM BW (B/active-max-cyc) | AXI W fire ratio |
|---:|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4  | PASS | 2569 | 76.561% | 241 / 401 (60.100%) | 12 | 1 / 4 cyc | 0.525 / 4 | 6.872% | 212.638 | 79.32% |
| 8  | PASS | 2524 | 77.517% | 241 / 400 (60.250%) | 6  | 1 / 4 cyc | 0.540 / 4 | 5.914% | 249.160 | 85.71% |
| 16 | PASS | 2501 | 77.962% | 240 / 400 (60.000%) | 3  | 0 / -     | 0.560 / 4 | 5.429% | 271.435 | 89.43% |
| 32 | PASS | 2506 | 77.801% | 240 / 400 (60.000%) | 3  | 0 / -     | 0.567 / 4 | 5.428% | 271.435 | 89.43% |

`DMA+MXU overlap`은 모든 DMA activity의 union을 사용하므로 store-to-load 선점 자체의 직접 지표가 아니다. 실제 선점은 `TMEM_DMA_STORE_TO_LOAD_SWITCH`/`TMEM_DMA_SWITCH_LATENCY`로 확인했다. direct column은 계측 추가 후 동일 class-3 workload를 재실행한 `input_load_compute_overlap_cycles / input_load_active_cycles`이며, 4/8/16/32 설정의 `input_load_active_cycles / compute_active_cycles / input_load_compute_overlap_cycles` raw 값은 각각 `401/1942/241`, `400/1940/241`, `400/1938/240`, `400/1938/240`이다. 모든 설정에서 direct overlap이 0보다 크고 두 activity count를 넘지 않았다. 모든 설정에서 accepted/logical completion은 15/15로 일치했고 descriptor issue/complete와 store chunk issue/complete도 각각 일치했다. 최초 matrix와 direct-overlap 재실행 모두 numerical result가 `PASSED`였다. 기존 `DMA+MXU overlap` 값은 historical all-DMA-union 수치로 유지하며 direct overlap으로 재해석하지 않는다.

최종 default는 **8 beats/channel**로 유지한다. 4-beat 대비 total cycle이 45 cycles 줄고 AXI write fire ratio가 높아지면서도 4-cycle store-to-load 선점을 보존한다. 16/32-beat는 이 workload에서 18~23 cycles를 더 줄이지만 full store가 single chunk가 되어 중간 선점을 제공하지 않는다. 따라서 8-beat가 선점 응답성과 AXI 효율 사이의 확인된 균형점이다.

# hard rule

## 목적

구현 편의를 위해 확정된 설계 의미를 임의로 바꾸거나, correctness 문제를 우회한 상태로 다음 phase를 진행하지 않는다. 계획의 전제나 불변식이 깨지는 문제가 발견되면 관련 구현을 즉시 멈추고 사용자와 해결책을 합의한 뒤 재개한다.

## 즉시 중단해야 하는 조건

다음 중 하나라도 확인되면 hard-rule stop을 선언한다.

1. 확정된 interface 또는 architectural semantics를 지킬 수 없는 경우
   - `cmd_valid/cmd_ready`, `cmd_tag/done_tag`, logical-command completion 계약을 변경해야 하는 경우
   - tag가 가리키는 notify/RID가 아닌 다른 inflight metadata를 갱신할 가능성이 있는 경우
   - chunk completion과 logical store completion을 분리할 수 없는 경우
2. chunk address correctness를 보장할 수 없는 경우
   - full descriptor와 chunk descriptor의 source/destination address 집합에 누락, 중복 또는 예상하지 않은 alias가 생기는 경우
   - `SEG_SIZE=64 B` 유지, `BND0/BND1/BND2`, stride, base cursor 규칙으로 original descriptor를 정확히 표현할 수 없는 경우
   - 기존 4 KB boundary 또는 AXI burst legality를 깨야 하는 경우
3. 확정된 chunking 전제가 실제 command에서 성립하지 않는 경우
   - HBM/TMEM channel-slot alignment 조건이 깨지는 경우
   - chunkable로 판정한 store에서 channel별 transfer length가 달라 lockstep global chunk completion을 적용할 수 없는 경우
   - chunkable로 판정한 store에서 `orig_bnd2`가 power-of-two가 아니거나 `max_chunk_beats < orig_bnd2`인 경우
   - fallback/mixed descriptor가 chunkable 경로에 들어가거나, non-chunkable 경로가 capture한 full descriptor를 그대로 issue하지 못하는 경우
4. ordering 또는 forward-progress를 보장할 수 없는 경우
   - 같은 priority FIFO, `I/W/SC/ZP` 순서, store issue 순서 중 하나가 깨지는 경우
   - queue full, paused store, tagged completion의 조합에서 deadlock 또는 store starvation 가능성이 발견되는 경우
   - final drain 또는 `idle`이 outstanding command/response보다 먼저 완료될 수 있는 경우
5. 계획한 범위를 넘어선 RTL 변경이 필요한 경우
   - `VX_dma_unit`의 실행 state를 저장/복원하거나 multi-context로 변경해야 하는 경우
   - HBM tile DMA 외의 local DMA 동작 또는 interface를 변경해야 하는 경우
   - 확정되지 않은 새로운 queue, reorder buffer, completion protocol이 필요한 경우
6. capacity 또는 event semantics가 확정 계획과 맞지 않는 경우
   - pending depth 4 + active/paused store 1 또는 controller inflight 8 slots로 command stream을 안전하게 수용할 수 없는 경우
   - same-cycle slot release/reallocation을 하지 않으면 correctness 또는 forward progress를 만족할 수 없는 경우
   - 한 cycle에 두 개 이상의 DMA logical completion을 처리해야 하는 경우

## 중단하지 않고 수정할 수 있는 조건

다음은 확정된 설계나 외부 동작을 바꾸지 않는 한 일반 구현/debug 작업으로 처리하고 계속 진행할 수 있다.

- syntax, width, lint, reset-value, signal-polarity 같은 국소 RTL 오류
- 확정된 equation이나 state transition을 잘못 옮긴 coding bug
- testbench, assertion, trace 또는 counter 자체의 오류
- build/configuration 문제나 일시적인 simulation infrastructure 문제
- 기능 결과가 동일한 이름 변경, 조합 논리 정리, pipeline timing 수정

단, 같은 종류의 오류라도 수정하기 위해 위의 확정된 interface, ordering, completion, address 또는 scope를 변경해야 하면 hard-rule stop으로 전환한다.

## stop 이후 허용되는 작업

- 문제를 재현하고 원인을 특정하기 위한 read-only 코드 조사, log 확인, assertion 추가 검토, 최소 simulation은 수행할 수 있다.
- 문제와 직접 관련된 추가 구현, workaround, architecture 변경은 하지 않는다.
- 이미 작성한 변경을 임의로 되돌리거나 다른 설계로 교체하지 않는다. worktree를 그대로 보존하고 변경 범위를 보고한다.
- 실패한 phase 이후의 구현 및 성능 실험은 진행하지 않는다.

## 필수 보고 형식

hard-rule stop 보고에는 최소한 다음 내용을 포함한다.

```text
[HARD-RULE STOP]
발견 phase:
관찰된 현상:
재현 조건 또는 command 예시:
근거: RTL file/line, assertion, log 또는 waveform signal
위반된 확정 규칙:
correctness/성능/범위에 미치는 영향:
현재까지 변경된 파일과 검증 상태:
가능한 해결안과 각각의 trade-off:
권장 해결안:
```

성능 예상보다 낮은 것만으로는 기능 구현을 중단하지 않는다. 다만 chunkable store를 사용하는 성능 tuning workload에서 핵심 목표인 `OUTPUT_STORE`와 다음 tile의 `INPUT_LOAD/COMPUTE` overlap이 구조적으로 불가능함을 보여주면 설계 전제가 깨진 것이므로 hard-rule stop으로 보고한다. non-chunkable store는 승인된 unchunked 정책상 이 조건의 대상이 아니다.

## 재개 조건

- 사용자가 해결 방향을 선택하거나 확정된 계획 변경을 승인하기 전에는 관련 구현을 재개하지 않는다.
- 합의된 변경 사항을 이 문서의 확정된 해결책, unresolved issues, 구현 계획 및 검증 계획에 먼저 반영한다.
- 문서 갱신 후 중단된 phase부터 구현과 검증을 재개한다.

# unresolved issues

현재 남은 unresolved issue는 없다. 2026-08-07 hard-rule stop에서 발견된 fallback/mixed store는 사용자 선택에 따라 full descriptor를 unchunked로 실행하기로 확정했고, xrt-vcs 4/8/16/32 tuning 결과 store chunk의 최종 default는 8 beats/channel로 확정했다.

# 구현 계획

## Phase 1: tagged multi-command interface와 controller

1. DMA command interface에 `cmd_valid`, `cmd_ready`, DMA 전용 `cmd_tag`와 `done_tag`를 추가한다.
2. DMA command에 새 `dma_priority`와 `dma_max_chunk_log2p1` field를 추가하고 FSM의 load/store command 생성부에서 값을 설정한다.
3. DMA child command FIFO depth를 8로 설정한다.
4. DMA child에만 single-active 제한을 제거하고 8-slot inflight scoreboard와 stable issue-tag reservation을 구현한다.
5. `cmd_valid && cmd_ready` handshake에서 DMA child FIFO를 pop하고 notify/RID metadata를 tag-indexed slot에 저장하여 inflight로 전환한다.
6. tagged completion이 해당 slot만 갱신하고 cycle 끝에서 해제하도록 한다. release된 slot은 다음 cycle부터 allocation할 수 있으며 같은 cycle 재할당은 구현하지 않는다.
7. 다른 GEMM child executor의 기존 in-order completion 동작은 변경하지 않는다.

## Phase 2: `VX_gemm_tmem_dma_ctrl` command scheduler

1. default depth 4의 parameterized pending queue를 추가한다.
2. load/store priority와 같은 priority 내 FIFO ordering을 구현한다.
3. active load와 active/paused store context를 관리한다.
4. queue-full backpressure와 tag 보존 경로를 구현한다.
5. global all-channel chunk completion 시점에만 재중재한다.

## Phase 3: `OUTPUT_STORE` chunk generator

1. 기존 channel별 descriptor 계산 결과를 full descriptor로 capture하는 pipeline stage를 추가한다.
2. 모든 channel의 active/burst mode, total beats, `BND0/BND1/BND2`를 비교해 chunkable 여부를 판정한다.
3. fallback/mixed non-chunkable store는 channel별 full descriptor를 변경 없이 한 번 issue하고 완료 후에만 재중재한다.
4. chunkable store에 대해서만 `dma_max_chunk_log2p1`을 decode하고 power-of-two 및 `max_chunk_beats >= orig_bnd2` 조건을 assertion으로 검사한다.
5. `orig_bnd2`를 유지하면서 `bank_budget`에 맞게 `BND1`을 먼저 줄이고, 필요하면 `BND0`을 나누는 registered chunk stage를 구현한다.
6. channel별 source/destination base를 `orig_base + bank_beat_cursor * orig_ST0`로 계산하고 `ST1`을 chunk `BND0`에 맞게 생성한다.
7. chunk마다 기존 `VX_dma_engine`이 완전히 완료되고 write response가 drain된 뒤 cursor와 remaining count를 갱신하고 다음 arbitration을 수행한다.
8. high-priority load가 있으면 이를 먼저 실행하고, load queue가 비면 저장된 full descriptor와 cursor에서 paused store를 재개한다.
9. 마지막 chunk에서만 logical store tagged completion과 `store_done`을 발생시킨다.

## Phase 4: 검증

1. store 실행 중 load 네 개를 enqueue하고 첫 store chunk 이후 `I/W/SC/ZP`가 FIFO 순서로 실행되는지 확인한다.
2. `dma_priority`의 high/low 선택과 `dma_max_chunk_log2p1`의 `0=unlimited`, `4=8 beats` encoding이 scheduler에서 정확히 적용되는지 확인한다.
3. load completion tag가 `RID_T`를 갱신하고 paused store의 `RID_O`를 잘못 갱신하지 않는지 확인한다.
4. store가 정확한 다음 HBM/TMEM 주소에서 재개되며 data duplication, drop, address overlap이 없는지 확인한다.
5. store의 `RID_O`와 `store_done`이 chunk 수와 무관하게 logical command당 한 번만 발생하는지 확인한다.
6. 동일 priority ordering, multiple store ordering, queue full backpressure, tag wrap/reuse를 directed test로 검증한다.
7. scoreboard가 full인 cycle에 completion이 발생하면 같은 cycle에는 child FIFO를 pop하지 않고, release된 slot을 다음 cycle에 할당하는지 확인한다.
8. AXI AR/R/AW/W/B 및 TMEM backpressure를 주고 response drain 전에는 arbitration하지 않는지 확인한다.
9. pending/active/paused command가 존재하는 동안 final drain과 idle이 조기에 완료되지 않는지 확인한다.
10. queue depth 1/2/4와 store chunk length parameter 경계값을 검증한다.
11. `BND0=2, BND1=9, BND2=4`에서 max chunk 4/8/16 각각의 chunk bounds, base cursor, 마지막 partial chunk를 directed test로 확인한다.
12. full descriptor와 모든 chunk descriptor의 source/destination address 집합이 정확히 같고 중복과 누락이 없는지 scoreboard로 확인한다.
13. store chunk 4/8/16/32 설정에서 동일 xrt-vcs blackbox workload를 실행하고 기존 numerical result와 일치하는지 확인한다.
14. 각 chunk 설정의 total cycle, store-to-load 전환 latency, context switch 횟수, queue occupancy, AXI utilization을 비교하고, `TMEM_DMA_SCHED_PERF`의 `input_load_active_cycles`, `compute_active_cycles`, `input_load_compute_overlap_cycles`로 direct load/compute overlap을 계산한다. 기존 perf-class-3 all-DMA-union overlap은 별도 참고값으로만 유지한다.
15. 측정 결과로 최종 default chunk 길이를 결정하고 문서에 결과와 선택 근거를 기록한다.
16. 256 B store처럼 일부 channel만 active인 fallback descriptor와 channel별 burst/fallback이 섞인 mixed descriptor가 full descriptor 그대로 한 번 실행되는지 확인한다.
17. non-chunkable store 실행 중 들어온 high-priority load가 pending 상태를 유지하고 full descriptor drain 직후 우선 선택되며, store/load가 각각 정확히 한 번 tagged completion되는지 확인한다.

### Phase 4 완료 결과

- VCS scheduler directed test는 depth 1/2/4, chunk 4/8/16/32, high-priority load FIFO, 세 개의 queued low-priority store 순서, queue-full backpressure, exact tagged logical completion을 통과했다.
- 256 B fallback store의 마지막 channel response를 4 cycles 보류한 동안 scheduler가 재중재하지 않았고, drain 직후 pending high-priority load tag 5가 later low-priority store tag 6보다 먼저 선택됐다. store/load/store tag 4/5/6은 각각 정확히 한 번 완료됐다.
- 실제 `VX_dma_engine` VCS test는 G2L/L2G descriptor에 AXI AR/AW/W ready stall `3/4/6`, AXI R/B response throttle `12/7`, TMEM request-ready/response throttle `3/9` cycles를 적용했다. 두 descriptor의 numerical result, descriptor 사이 drain, final drain이 모두 통과했다.
- controller의 8-tag out-of-order completion과 same-cycle released-slot 재사용 금지, chunk address-set equivalence, fallback/mixed full-descriptor 보존, node M=2/M=4 numerical regression도 통과했다.
- 위 directed 결과와 4/8/16/32 xrt-vcs numerical/performance matrix를 합쳐 Phase 4의 17개 항목을 모두 닫았다.
