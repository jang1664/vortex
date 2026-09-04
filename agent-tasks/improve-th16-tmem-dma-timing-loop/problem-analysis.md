# IMPROVE TH16 TMEM DMA Timing Loop 분석

## 상태

- 문제 원인과 RTL 연결 경로는 확인했다.
- 해결 방식은 아직 확정하지 않았다.
- 다음 단계에서 선택할 해결 방식과 성능 보존 조건을 이 문서에 추가한다.
- 이 문서는 분석 기록이며 현재 RTL을 변경하지 않는다.

## 대상 빌드

```text
build/hw/syn/xilinx/xrt/
improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8_
xilinx_u55c_gen3x16_xdma_3_202210_1_hw
```

Vivado는 다음 문제를 보고했다.

- `TIMING-23`: combinational timing loop 두 곳
- `LUTLP-1`: controller와 여러 DMA channel을 지나는 36-LUT combinational loop
- 대표 합성 cell:
  - `u_tmem_dma_ctrl/...`
  - `u_tmem_subsystem/u_dma_engine/g_channel[*].u_dma_unit/...`
  - `u_tmem_subsystem/u_ldma_output/...`

## ready/valid 용어

- `valid`: source가 유효한 요청과 payload를 제공하고 있음을 뜻한다.
- `ready`: sink가 요청을 받을 수 있음을 뜻한다.
- `fire`: `valid && ready`이며, 실제 요청이 accept된 cycle이다.
- 정상적인 source는 `valid`와 payload를 `ready`와 무관하게 생성하고, `fire`를 상태 갱신에만 사용해야 한다.
- sink의 `ready`가 request arbitration을 위해 `valid`를 보는 것은 가능하지만, source의 `valid`가 다시 그 `ready`를 보면 combinational loop가 된다.

## 관련 hierarchy

```text
VX_gemm_ctrl
├── Global TMEM DMA child
│   └── VX_gemm_tmem_dma_ctrl
│       └── VX_dma_engine
│           └── g_channel[ch].VX_dma_unit
│               └── VX_dma_unit_align
│                   └── TMEM bank port 0
│
└── Output local DMA child
    └── VX_gemm_node
        └── VX_tmem_subsystem
            └── u_ldma_output: VX_lmem_dma_misal
                └── VX_dma_unit_align
                    └── output bank switch
                        └── TMEM bank port 5

VX_tensor_mem_bank
└── port 0..5의 req_valid/priority를 조합하여 각 req_ready 생성
```

Global DMA와 Output local DMA는 같은 TMEM bank arbiter에 서로 다른 requester port로 연결된다. 따라서 한 requester의 same-cycle completion이 다른 requester의 `valid`를 바꾸면, 원래 requester의 `ready`도 같은 cycle에 바뀔 수 있다.

## 문제 1: Global TMEM DMA command chaining loop

### RTL 위치

- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv:327-334`
  - active channel의 `cfg_reg_if.ready`를 `candidate_cfg_all_ready`로 모은다.
- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv:365-366`
  - `chain_candidate_fire = chain_candidate_select && candidate_cfg_all_ready`이다.
- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv:731-735`
  - chaining path의 `cfg_reg_if.valid`가 `chain_candidate_fire`에 의존한다.
- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv:759-764`
  - `lookahead_if.activate`도 `chain_candidate_fire`에 의존한다.
- `hw/rtl/core/VX_dma_unit_align.sv:246-250`
  - DMA channel의 `cfg_reg_if.ready`가 `lookahead_if.activate`에 의존한다.

### 정확한 loop

```text
cfg_reg_if[ch].ready
  -> candidate_cfg_all_ready
  -> chain_candidate_fire
  -> cfg_reg_if[ch].valid
  -> lookahead_if[ch].activate
  -> chain_accept_window
  -> cfg_reg_if[ch].ready
```

축약하면 다음과 같다.

```text
ready -> fire -> valid/activate -> ready
```

즉, chaining source의 `valid`가 sink의 `ready`에 직접 의존한다. 이 경로가 여러 active DMA channel에 복제되고 all-channel reduction으로 다시 합쳐지면서 Vivado의 36-LUT SCC(strongly connected component)를 만든다.

### 정상인 prepare 경로와의 구분

`lookahead_if.prepare_valid`는 registered candidate/prepare state에서 생성되고, `prepare_ready`도 channel 내부의 registered ownership state에서 생성된다. 현재 확인된 loop는 일반 PREPARE handshake가 아니라, 이전 DMA 완료 cycle에 다음 prepared descriptor를 즉시 시작하는 `ACTIVATE/config chaining` 경로다.

## 문제 2: Output final-write completion feedback loop

### RTL 위치

- `hw/rtl/core/VX_dma_unit_align.sv:952-984`
  - Output DMA의 실제 request `valid`와 payload를 구동한다.
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:147-151`
  - `dst_write_fire`가 `req_valid && req_ready`로 생성된다.
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:261-263`
  - 마지막 destination write의 `fire`를 같은 cycle의 `write_done`으로 내보낸다.
- `hw/rtl/core/gemm/VX_gemm_node.sv:1024-1026`
  - `output_dma_ctrl_if.write_done`을 controller의 output child completion으로 직접 연결한다.
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv:368-384`
  - child completion을 같은 cycle의 `effective_sync`에 반영한다.
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv:590-608`
  - completion/dependency 결과가 새로운 child `ctrl.start`, 즉 requester `valid`를 열 수 있다.
- `hw/rtl/mem/VX_tensor_mem_bank.sv:96-139`
  - 모든 requester의 `valid`와 priority를 보고 각 requester의 `ready`를 생성한다.

### 정확한 feedback 구조

```text
Output TMEM req_ready
  -> dst_write_fire
  -> output write_done
  -> child_completion_pop
  -> effective_sync / dependency eligibility
  -> 다음 DMA 또는 operand requester valid
  -> TMEM bank arbitration
  -> Output TMEM req_ready
```

여기서는 Output request의 `valid` 자체가 자신의 `ready`에 의존하는 것은 아니다. Output request `valid`는 registered DMA state와 payload availability에서 생성된다. 문제는 `ready`가 포함된 마지막 `fire` 결과가 같은 cycle에 다른 requester의 `valid`를 변경한다는 점이다. 따라서 시스템 전체에서는 간접적인 `ready -> valid -> ready` loop가 된다.

### 합성 cell 이름 주의

Vivado `TIMING-23 #2`는 loop break cell을 다음처럼 표시했다.

```text
u_ldma_output/dma_core/g_aligned.u_impl/
g_size_gt1.g_single_step.g_size_eq2.full_r_reg0_i_1
```

이 이름만 보면 `VX_pending_size` 문제처럼 보이지만, post-synthesis netlist에서 해당 LUT는 다음과 같이 연결된다.

```text
I4 = ldma_to_switch[4].req_ready
O  = output_dma_ctrl_if.write_done
```

따라서 원인은 `VX_pending_size` counter가 아니라, Output final-write `ready/fire`와 same-cycle controller completion 사이의 feedback이다.

## 두 loop의 관계

두 문제는 완전히 독립적인 작은 loop라기보다 같은 TMEM arbitration network를 통해 하나의 큰 feedback network를 형성할 수 있다.

```text
Global DMA chaining valid/ready loop
       ↕
TMEM bank arbitration
       ↕
Output final-write completion loop
```

Global DMA chaining이 여러 channel의 `valid/ready`를 연결하고, Output completion이 controller dependency와 다음 request issue를 같은 cycle에 연결한다. 이 때문에 loop가 controller, DMA engine channel, Output DMA, TMEM bank arbitration까지 넓어져 timing 분석 정확도와 placement/routing congestion을 모두 악화시킨다.

## 수정 시 반드시 보존할 조건

1. `valid`와 payload는 stall 중 안정적으로 유지되어야 한다.
2. `fire` 전에는 descriptor나 command ownership을 retire하면 안 된다.
3. active DMA channel 전체의 descriptor 전환은 원자성을 유지해야 한다.
4. 마지막 Output write는 실제 TMEM accept 전에 완료 처리하면 안 된다.
5. stale/duplicate completion, descriptor drop, channel별 부분 activation이 없어야 한다.
6. loop 제거를 위해 TMEM arbitration을 test-only constraint로 무시하면 안 된다.
7. 변경 전후 `fpint_gemm` 기능과 cycle 수를 비교하여 성능 손실을 별도로 판단해야 한다.

## 해결 방식

Global DMA chaining은 fence 없이 source-owned `valid/activate`와
state-owned `ready`를 분리하는 방식으로 확정한다. Output completion
feedback은 controller-visible completion을 1 cycle 지연하는 방식으로
확정한다.

### Global DMA chaining

#### 핵심 원칙

DMA channel의 `ready`는 `activate`를 보지 않고, channel이 현재 descriptor를
accept할 수 있는 registered state인지만 나타낸다. Controller의
`valid/activate`는 channel `ready`와 무관하게 selected candidate에서 생성한다.
`fire`만 모든 channel의 실제 accept와 controller 상태 갱신에 사용한다.

```systemverilog
// VX_dma_unit_align: accept capability는 registered state에서만 생성
assign cfg_reg_if.ready = (state == S_IDLE)
                       || ((state == S_DONE) && done_if.ready);

// VX_gemm_tmem_dma_ctrl: source request는 ready와 독립
assign chain_candidate_offer = chain_candidate_select;
assign cfg_reg_if[ch].valid = chain_candidate_offer
                           && chain_channel_active;
assign lookahead_if[ch].activate = chain_candidate_offer
                                && chain_channel_active;

// fire는 accept/retire 상태 갱신에만 사용
assign chain_candidate_fire = chain_candidate_offer
                           && candidate_cfg_all_ready[chain_candidate_id];
```

수정 후 조합 경로는 다음처럼 단방향이 된다.

```text
registered channel state -> ready
registered controller/candidate state -> valid/activate
ready + valid -> fire -> next registered state
```

`ready -> valid/activate -> ready` feedback은 사라진다.

#### same-cycle chaining 보존

Channel별 이전 command 종료 시점은 다를 수 있다. 하지만 먼저 완료한 channel은
`S_DONE`에서 `done_if.valid=1`을 유지하고, controller가 `done_if.ready`를 줄 때까지
대기한다. Controller의 `chain_candidate_select`는 모든 active channel의
`done_all_valid`가 확인된 후에만 올라간다.

따라서 마지막 channel이 `S_DONE`에 도달한 cycle에는 모든 active channel이
동시에 다음 조건을 만족한다.

```text
state == S_DONE
done_if.valid == 1
done_if.ready == 1
cfg_reg_if.ready == 1
```

그 cycle에 controller가 `valid/activate`를 제시하면 같은 edge에서 기존 command의
done handshake와 다음 prepared descriptor accept가 함께 일어난다. 별도의
`S_IDLE` bubble이나 추가 chaining cycle은 넣지 않는다.

#### Fence를 사용하지 않는 이유

Per-channel `accepted_mask` fence는 추가하지 않는다. 현재 `cfg_fire`는 단순한
descriptor 예약이 아니라 해당 channel의 새 DMA 실행을 즉시 시작하기 때문이다.
Fence로 channel별 handshake를 따로 허용하면 먼저 accept한 channel만 실행되는
partial activation을 만들 수 있다. 이를 안전하게 쓰려면 별도 descriptor staging과
global commit 단계가 필요하며, 현재 구조에서는 불필요한 상태와 cycle을 추가한다.

현재는 early-complete channel이 `S_DONE`에서 유지되는 구조로 all-ready 동시성을
보장하고, 그 전제를 assertion으로 고정한다.

#### 추가할 assertion

1. `chain_candidate_offer`가 1이면 모든 active channel의 `done_if.valid`가
   1이어야 한다.
2. `chain_candidate_offer`가 1이면 모든 active channel의 `cfg_reg_if.ready`가
   같은 cycle에 1이어야 한다.
3. `S_DONE`에서 `cfg_reg_if.valid`가 1이면 `lookahead_if.activate`도 반드시
   1이어야 한다.
4. `cfg_reg_if.valid`와 `lookahead_if.activate`는 active mask와 정확히
   일치해야 한다.
5. `chain_candidate_fire` cycle에는 모든 active channel에서 `cfg_fire`가
   발생하고, inactive channel에서는 발생하지 않아야 한다.
6. 일부 active channel만 `cfg_fire`하는 partial activation은 Fatal이어야 한다.
7. offer/accept cycle의 descriptor payload, candidate ID, active mask는
   안정적이어야 한다.
8. same-cycle old `done`과 new `cfg_fire`가 일어났을 때 channel이 `S_IDLE`을
   거치지 않고 새 command state로 전환되어야 한다.

### Output completion feedback

#### 핵심 원칙

마지막 Output TMEM write는 기존처럼 `req_valid && req_ready`인 cycle에
정상적으로 accept한다. 하지만 그 `write_done`으로 dependency를 해제하고
후속 requester의 `start/valid`를 올리는 것은 반드시 다음 cycle부터
허용한다.

```text
cycle N:
  Output req_valid && req_ready
  -> raw_output_write_done = 1
  -> 실제 TMEM write 및 DMA 내부 byte/count 상태 갱신

posedge N -> N+1:
  raw_output_write_done을 register에 저장

cycle N+1:
  controller_output_done = 1
  -> child_completion_pop
  -> effective_sync 갱신
  -> dependency 해제
  -> 후속 requester start/valid 허용
```

이렇게 하면 다음 경로 사이에 register가 들어간다.

```text
TMEM req_ready
  -> final write fire
  -> [register]
  -> controller completion
  -> next requester valid
  -> TMEM arbiter
  -> TMEM req_ready
```

#### 구현 경계

권장 위치는 `VX_gemm_node`의 Output DMA와 `VX_gemm_ctrl` 사이 경계다.

1. `output_dma_ctrl_if.write_done`은 physical final-write pulse로 유지한다.
2. 새 `output_write_done_q`가 이 pulse를 한 cycle 저장한다.
3. `gemm_ctrl_if.output_write_flag.done`에는 raw pulse가 아니라
   `output_write_done_q`를 연결한다.
4. `output_write_active_r`의 ownership 종료도 controller-visible done과
   일치시키거나, raw physical completion과 logical controller completion을
   각각 별도 이름으로 명확하게 관리한다.
5. DMA 내부 byte counter, destination write acceptance, TMEM request protocol은
   raw final-write `fire`를 계속 사용하며 변경하지 않는다.
6. 등록된 completion은 정확히 한 cycle의 단일 pulse여야 하며
   drop/duplicate가 없어야 한다.

개념적인 연결은 다음과 같다.

```systemverilog
always_ff @(posedge clk) begin
  if (reset)
    output_write_done_q <= 1'b0;
  else
    output_write_done_q <= output_dma_ctrl_if.write_done;
end

assign gemm_ctrl_if.output_write_flag.done = output_write_done_q;
```

실제 구현에서는 같은 cycle의 새 Output start와 delayed done이 겹칠 때
`output_write_active_r` ownership이 잘못 clear되지 않도록 start/done 우선순위를
명시해야 한다.

#### 예상 성능 영향

- 동일 TMEM bank를 사용하는 후속 요청은 cycle N에 Output write가 이미 bank를
  점유하므로, 다음 cycle에 valid를 올려도 이론적으로 처리량 손실이 없다.
- 다른 bank를 사용하는 후속 요청은 기존 combinational look-through가 제공하던
  1-cycle 빠른 병렬 시작이 사라질 수 있다.
- 실제 total cycle 영향은 DMA/계산 overlap에 숨을 수 있으므로 시뮬레이션으로
  판단한다.
- 기능적으로는 실제 final write accept보다 completion을 앞당기지 않으므로
  correctness 위험 없이 보수적인 방향이다.

### 검증 계획

Global DMA chaining 변경 후 다음 항목을 먼저 검증한다.

1. 서로 다른 cycle에 완료되는 active channel들이 `S_DONE`에서 유지되고, 마지막
   channel 완료 시 모든 active channel이 동시에 ready가 되는 directed test를
   추가한다.
2. 같은 cycle에 old done과 new cfg/activate handshake가 발생하며 `S_IDLE`
   bubble이 추가되지 않는지 확인한다.
3. 앞 절의 all-ready, active-mask, full-fire, no-partial-activation assertion을
   모두 directed test로 hit한다.
4. `valid && !ready`가 가능한 일반 cfg 경로에서는 valid, descriptor payload,
   candidate ID와 active mask가 안정적인지 확인한다.
5. chaining 전후 command accept/done 수, channel별 descriptor 수와 data count가
   정확히 같아야 한다.

Output completion 변경 후 다음 항목을 검증한다.

1. final Output write의 raw `fire`와 controller-visible done 사이가 정확히
   1 cycle인지 확인한다.
2. raw final write 이전에는 completion, dependency 해제, 후속 requester issue가
   발생하지 않는지 확인한다.
3. delayed done이 정확히 한 번만 발생하고 child inflight entry가 정확히 한 번만
   retire되는지 확인한다.
4. Output request `valid/payload`가 `ready=0` 동안 안정적인지 확인한다.
5. same-cycle `TMEM ready -> completion -> requester valid` 조합 경로가 lint와
   Vivado post-init timing report에서 제거됐는지 확인한다.
6. `fpint_gemm` NAIVE/IMPROVE 기준 결과와 변경 후 결과의 numerical output,
   DMA traffic count, total cycles, DMA overlap을 비교한다.
7. 두 수정이 모두 반영된 뒤 Vivado post-init methodology/DRC를 다시 실행하여
   두 `TIMING-23`와 36-LUT `LUTLP-1`이 모두 제거됐는지 확인한다.
