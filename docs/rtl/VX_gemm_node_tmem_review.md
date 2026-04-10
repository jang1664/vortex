# `VX_gemm_node` TMEM/DMA RTL Review Notes

Date: 2026-04-10

Scope:
- [`hw/rtl/core/gemm/VX_gemm_node.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv)
- [`hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv)
- [`hw/rtl/mem/VX_tmem_subsystem.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv)
- [`hw/rtl/mem/VX_tmem_switch.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_switch.sv)
- [`hw/rtl/mem/VX_tensor_mem_bank.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tensor_mem_bank.sv)
- [`hw/rtl/core/gemm/VX_lmem_dma_misal.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_lmem_dma_misal.sv)

## 1. Executive Summary

현재 `VX_gemm_node`는 예전의 단일 `lmem_bus_if` 기반 구조가 아니라, `VX_tmem_subsystem`을 중심으로 재구성된 상태다.

현재 load/store 데이터 경로는 다음과 같다.

- load:
  `HBM -> VX_dma_engine -> TMEM banks -> VX_lmem_dma_misal -> GEMM unit`
- store:
  `GEMM unit -> VX_lmem_dma_misal -> TMEM banks -> VX_dma_engine -> HBM`

핵심 포인트는 3개다.

1. `VX_gemm_node` 안에서 input/weight/sz/output local DMA 명령을 `VX_tmem_subsystem`으로 넘긴다 ([`VX_gemm_node.sv:173`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L173), [`VX_gemm_node.sv:393`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L393)).
2. external DMA 명령은 `VX_gemm_tmem_dma_ctrl`가 받아서 8-channel DMA engine config register write로 분해한다 ([`VX_gemm_node.sv:340`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L340), [`VX_gemm_tmem_dma_ctrl.sv:140`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L140)).
3. 최신 RTL은 `4c2c5907`의 "DMA channel 0 + switch" 구조가 아니라, `31720f0a` 이후의 "8-channel direct-to-bank" 구조다. 즉 git history를 볼 때 `4c2c5907`의 설명만 보면 현재 구현을 잘못 이해하게 된다.

## 2. Git History Based Change Summary

`VX_gemm_node.sv` 자체의 큰 전환점은 아래 커밋들이다.

- `0b9741e8` `Implement TMEM + DMA data feeding for GEMM accelerator (Phases 1-10)`
  - 기존 `LMEM arbiter + width adapter + per-path LDMA + external gemm_dma_ctrl` 조합을 제거하고, `VX_tmem_subsystem` 기반 구조로 교체했다.
  - `VX_gemm_node`는 더 이상 single `lmem_bus_if`를 직접 다루지 않고, `dma_axi_m[NUM_TMEM_BANKS]`를 TMEM subsystem에 넘긴다.
- `4c2c5907` `Fix TMEM DMA addressing and capacity for fpint_gemm blackbox`
  - TMEM bank size를 `4KB -> 32KB`로 늘렸다.
  - 커밋 메시지 기준으로는 DMA addressing mismatch를 switch 기반으로 한 번 수정했다.
- `31720f0a` `gemm: wire 8-channel TMEM DMA directly`
  - 이 커밋은 `VX_tmem_subsystem`과 `VX_gemm_tmem_dma_ctrl`를 다시 바꿔서, channel 0 serialized/switch 방식이 아니라 8-channel direct bank wiring으로 재구성했다.
  - 현재 working tree의 `VX_tmem_subsystem.sv`/`VX_gemm_tmem_dma_ctrl.sv`는 이 구조를 반영하고 있다.

정리하면:

- 과거: single LMEM path
- 4/8: TMEM subsystem 도입
- 4/9: TMEM 용량 확대 + DMA/TMEM address mismatch 수정
- 4/10 현재: 8-channel direct DMA layout으로 다시 재정렬

## 3. What `VX_gemm_node` Does Now

### 3.1 Control plane

`VX_gemm_ctrl`가 발행한 명령은 5개 child node 관점으로 분리되어 처리된다.

- child 0: input read / notify
- child 1: weight read / notify
- child 2: quant param read / notify
- child 3: output write / notify
- child 4: external DMA / notify

관련 sync wiring은 [`VX_gemm_node.sv:193`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L193), [`VX_gemm_node.sv:233`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L233), [`VX_gemm_node.sv:280`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L280), [`VX_gemm_node.sv:320`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L320), [`VX_gemm_node.sv:356`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L356)에 있다.

`OP_NOTIFY`는 실제 DMA를 발생시키지 않고, pending register/value를 잡아두었다가 `gemm_sync_if[x].ready`에서 완료 처리한다 ([`VX_gemm_node.sv:118`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L118), [`VX_gemm_node.sv:127`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L127), [`VX_gemm_node.sv:136`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L136), [`VX_gemm_node.sv:144`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L144)).

### 3.2 GEMM-unit-facing command mapping

`gemm_unit_if.start`는 input read start에 직접 묶여 있다 ([`VX_gemm_node.sv:164`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L164)).

현재 mapping 특징:

- `acc_cnt <= input_read_ctrl.cmd.instr[31:4]`
- `acc_mem_base_addr <= input_read_ctrl.cmd.rs1_data`
- `quant_dir <= flags[5]`
- `wreg_use_idx/sreg_use_idx/zreg_use_idx <= flags[2:0]`
- `is_load <= ~flags[3]`

즉 GEMM unit의 직접 제어는 아직도 `input_read_ctrl.cmd`에 강하게 의존한다. 코드에도 `temporary/static mapping`이라고 명시되어 있다 ([`VX_gemm_node.sv:162`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L162)).

## 4. Local DMA Paths Inside `VX_gemm_node`

### 4.1 Input local DMA

input path는 `VX_lmem_dma_misal(DIR=0)`로 동작한다.

- source: `rs2_data`
- stride: `cmd.stride`
- bound[0]: `cmd.bound`
- seg_size: `MXU_KT * 2`
- done source: 실제로는 `gemm_unit_if.done`

관련 코드:
- [`VX_gemm_node.sv:174`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L174)
- [`VX_gemm_node.sv:189`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L189)
- [`VX_gemm_node.sv:190`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L190)

중요한 점은 local DMA 완료가 아니라 GEMM 연산 완료를 input read done으로 본다는 점이다. input load와 GEMM start를 사실상 같은 시작점으로 다루는 구조다.

### 4.2 Weight local DMA

weight path도 `DIR=0`이지만, GEMM unit으로 넘길 때 주소를 TMEM address가 아니라 `{weight_cmd_flags_r[1], weight_cmd_flags_r[0]}`로 강제 치환한다 ([`VX_gemm_node.sv:486`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L486)).

이 로직의 의미:

- weight DMA가 TMEM에서 읽어 오는 실제 주소와,
- GEMM unit이 weight register bank/double-buffer selector로 해석하는 주소는

서로 다르다.

즉 weight path의 주소는 "메모리 위치"가 아니라 "어느 weight buffer를 쓸지"로 재해석된다. 이 플래그는 DMA start 시점에 래치된다 ([`VX_gemm_node.sv:251`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L251)).

### 4.3 Scale/zero local DMA

scale/zero path는 `DIR=0`이며 TMEM subsystem에서 나온 beat address를 GEMM unit 쪽 byte address로 left shift해서 넘긴다 ([`VX_gemm_node.sv:493`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L493)).

핵심은 다음 한 줄이다.

- `sz_gemm_bus_if.req_data.addr = tmem_sz_gemm_bus_if.req_data.addr << log2(GEMM_SCALE_ZERO_DATA_SIZE)`

즉 TMEM/LDMA 쪽은 beat 단위, GEMM scale/zp register 쪽은 byte 단위로 해석하고 있다.

### 4.4 Output local DMA

output path는 `DIR=1`로 GEMM -> TMEM write 경로다 ([`VX_tmem_subsystem.sv:340`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L340)).

`seg_size = MXU_NT * 2 * bound`로 한 segment 안에 모든 row를 몰아쓴다 ([`VX_gemm_node.sv:316`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L316)).

## 5. `VX_tmem_subsystem` Current Architecture

### 5.1 Subsystem composition

`VX_tmem_subsystem`은 아래 4개 블록을 묶는다.

- `VX_dma_engine`
- `VX_tmem_switch` x4
- `VX_tensor_mem_bank` x8
- `VX_lmem_dma_misal` x4

정의는 [`VX_tmem_subsystem.sv:16`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L16)부터 보인다.

### 5.2 TMEM banks

각 bank는 single-port SRAM 위에 5-port arbiter를 얹은 구조다.

- port 0: DMA
- port 1: input local DMA
- port 2: weight local DMA
- port 3: scale/zp local DMA
- port 4: output local DMA

관련 코드:
- [`VX_tmem_subsystem.sv:190`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L190)
- [`VX_tensor_mem_bank.sv:16`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tensor_mem_bank.sv#L16)
- [`VX_tensor_mem_bank.sv:53`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tensor_mem_bank.sv#L53)

bank 내부 동작:

- `VX_mem_arb`로 5개 요청을 1개로 중재
- `VX_sp_ram` 1개 사용
- read response는 1-cycle pipeline register를 거침
- write response data는 `0`

즉 동시성은 bank 간 병렬성으로 확보하고, bank 내부는 철저히 serialized access다 ([`VX_tensor_mem_bank.sv:87`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tensor_mem_bank.sv#L87), [`VX_tensor_mem_bank.sv:123`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tensor_mem_bank.sv#L123)).

### 5.3 Local DMA to bank routing

local DMA 쪽은 반드시 `VX_tmem_switch`를 지난다.

switch 규칙:

- bank select = request beat address 하위 `log2(NUM_BANKS)` 비트
- bank-local address = `req_addr >> log2(NUM_BANKS)`
- bank select bits는 response routing용으로 tag에 실린다

관련 코드:
- [`VX_tmem_switch.sv:54`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_switch.sv#L54)
- [`VX_tmem_switch.sv:58`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_switch.sv#L58)
- [`VX_tmem_switch.sv:69`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_switch.sv#L69)

즉 local DMA 관점의 TMEM 주소는 "interleaved global beat address"다.

## 6. External DMA Path

### 6.1 Frontend mapping

`gemm_ctrl_if.dma_ctrl`는 `VX_gemm_tmem_dma_ctrl`로 직접 연결된다 ([`VX_gemm_node.sv:342`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L342)).

이 블록은:

- `OP_DMA_LD`
- `OP_DMA_ST`
- `OP_NOTIFY`

세 opcode를 처리한다 ([`VX_gemm_tmem_dma_ctrl.sv:58`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L58)).

### 6.2 Per-channel decomposition

현재 external DMA는 channel 0 only가 아니다. `seg_size`를 64B bus-word 단위로 잘라서 8개 channel에 나눈다.

- `num_words = seg_size >> 6`
- `words_quot = num_words >> 3`
- `words_rem = num_words[2:0]`
- 각 channel은 `quot` 또는 `quot+1` word를 담당

관련 코드:
- [`VX_gemm_tmem_dma_ctrl.sv:121`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L121)
- [`VX_gemm_tmem_dma_ctrl.sv:142`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L142)

주소 생성 규칙은 현재 구조를 이해할 때 가장 중요하다.

- DMA load (`HBM -> TMEM`)
  - HBM source base: `src_base + ch * 64`
  - TMEM destination base: `dst_base >> 3`
- DMA store (`TMEM -> HBM`)
  - TMEM source base: `src_base >> 3`
  - HBM destination base: `dst_base + ch * 64`

코드:
- [`VX_gemm_tmem_dma_ctrl.sv:145`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L145)
- [`VX_gemm_tmem_dma_ctrl.sv:158`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L158)

해석:

- HBM 쪽은 channel별로 64B stripe를 나눠 갖고,
- TMEM 쪽은 각 channel이 자기 bank의 bank-local address 공간을 본다.

즉 `31720f0a` 이후 current design은 "DMA channel == TMEM bank"를 전제로 한다.

### 6.3 Why direct DMA wiring now works

`VX_tmem_subsystem` 현재 코드는 DMA 요청을 switch에 넣지 않고 각 channel을 각 bank에 직결한다 ([`VX_tmem_subsystem.sv:207`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L207)).

이게 성립하려면 `VX_gemm_tmem_dma_ctrl`가 TMEM 쪽 주소를 이미 bank-local form으로 만들어 줘야 한다.

현재 그 역할을 하는 것이:

- base address의 `>> 3`
- TMEM-side stride의 `>> 3`
- `SRC_ST0`/`DST_ST0`를 `64`와 `512`로 분리한 per-bank stepping

이다 ([`VX_gemm_tmem_dma_ctrl.sv:146`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L146), [`VX_gemm_tmem_dma_ctrl.sv:158`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L158), [`VX_gemm_tmem_dma_ctrl.sv:160`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L160)).

그래서 현재 구조는:

- local DMA: global interleaved address 사용, switch가 bank 분해
- external DMA: controller가 bank-local address로 미리 분해, switch 없이 direct bank 접근

이라는 "서로 다른 주소 해석 계층"을 갖는다.

## 7. Capacity Change and Why It Matters

현재 `VX_gemm_node`는 `BANK_SIZE = 32*1024`를 명시적으로 override한다 ([`VX_gemm_node.sv:434`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_node.sv#L434)).

`4c2c5907` 이전에는 `4KB`였고, commit message 기준으로 FPINT GEMM double-buffered tile layout에 비해 심각하게 작았다. 이 변경은 구조적 최적화가 아니라 correctness fix에 가깝다.

리뷰 관점에서는:

- bank aliasing이 다시 생기지 않는지
- testbench나 wrapper가 여전히 4KB 가정을 갖고 있지 않은지

를 함께 봐야 한다.

## 8. Review Checklist

### 8.1 Correctness points worth focusing on

1. external DMA command의 `rs1_data/rs2_data/stride` 단위가 current controller의 `>>3` 규칙과 일치하는지
   - current design은 TMEM-side address가 bank-local beat address라는 가정이 매우 강하다.
2. local DMA와 external DMA가 같은 TMEM layout을 공유하는지
   - local DMA는 switch-based interleaved view
   - external DMA는 controller-deinterleaved direct-bank view
3. weight path의 address override가 모든 mode에서 안전한지
   - 실제 TMEM read address는 사라지고 `{wtrans, use_idx}`만 GEMM unit으로 들어간다.
4. input done을 `gemm_unit_if.done`으로 보는 것이 scheduler/FSM 기대와 맞는지
   - load complete와 compute complete가 분리되지 않는다.
5. bank arbitration starvation 가능성
   - DMA + local DMA가 같은 bank를 동시에 두드릴 때 single-port SRAM이라 완전 병렬이 아니다.

### 8.2 History-related caution

`4c2c5907`의 커밋 메시지에는 DMA channel 0을 switch에 넣는 설명이 있지만, 현재 RTL은 그렇지 않다. 현재 문서/리뷰는 반드시 `31720f0a` 이후 구조를 기준으로 봐야 한다.

즉 "과거 fix 설명"과 "현재 코드"가 다르다. 이번 리뷰에서 가장 먼저 걸러야 할 오해 포인트다.

## 9. Bottom Line

현재 `VX_gemm_node`의 핵심 설계 의도는 명확하다.

- GEMM node는 control 분배와 path별 address reinterpretation에 집중
- 실제 memory movement는 `VX_tmem_subsystem`으로 집중
- external DMA는 8-channel direct bank fill/drain
- local DMA는 interleaved TMEM view를 유지하며 GEMM unit과 연결

즉 구조 자체는 "TMEM을 shared staging buffer로 두고, HBM-side parallelism과 GEMM-side path specialization을 분리"하는 방향이다.

리뷰 우선순위는 다음 순서가 맞다.

1. external DMA address unit 정합성
2. local DMA/interleaved TMEM view와 external DMA/direct bank view의 합치성
3. weight/sz path의 address reinterpretation이 GEMM unit 프로토콜과 정확히 맞는지
4. single-port bank arbitration이 실제 workload에서 병목 또는 starvation을 만들지
