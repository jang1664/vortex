# VX_gemm Input Streaming Plan

## Goal

`gemm_unit` input path에서 `input_bus`가 가능한 한 매 cycle 1 beat씩 들어오도록 만드는 방향을 정리한다.

현재 관찰된 현상은 `gemm_unit`의 문제라기보다, 그 앞단의 local DMA와 TMEM path가 request/response 기반으로 동작하기 때문에 생기는 bubble이다.

관련 RTL:
- [`hw/rtl/core/gemm/VX_gemm_unit.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_unit.sv)
- [`hw/rtl/core/gemm/VX_lmem_dma_misal.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_lmem_dma_misal.sv)
- [`hw/rtl/mem/VX_tmem_subsystem.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv)
- [`hw/rtl/mem/VX_tmem_switch.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_switch.sv)
- [`hw/rtl/mem/VX_tensor_mem_bank.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tensor_mem_bank.sv)

## Current Bottleneck

### 1. Local DMA is not a streaming engine

`VX_lmem_dma_misal`은 source에서 연속적으로 받아서 sink로 계속 밀어넣는 구조가 아니다.

현재 state machine은 대략 다음 순서로 돈다.
- `S_DECIDE`
- `S_SRC_RD_REQ`
- `S_SRC_RD_WAIT`
- `S_DST_WR_REQ`
- `S_ADV_SEG`

즉 한 beat를 `gemm_unit`에 쓰기 전에:
- TMEM read request 발행
- TMEM response 대기
- 내부 window 갱신
- GEMM write request 발행

을 거친다.

관련 코드:
- [`VX_lmem_dma_misal.sv:502`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_lmem_dma_misal.sv#L502)
- [`VX_lmem_dma_misal.sv:515`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_lmem_dma_misal.sv#L515)
- [`VX_lmem_dma_misal.sv:539`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_lmem_dma_misal.sv#L539)

input path에서는 `seg_size = 64B`라서 이 패턴이 거의 매 beat마다 반복된다.
- [`VX_gemm_ctrl_with_ldma.sv:64`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_ctrl_with_ldma.sv#L64)

결과적으로 `input_bus`는 naturally bubble이 생긴다.

### 2. TMEM bank is single-ported behind arbitration

`VX_tmem_subsystem`에서 local DMA input path는 `VX_tmem_switch`를 거쳐 각 TMEM bank로 라우팅된다.
- [`VX_tmem_subsystem.sv:303`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L303)

각 bank는 5개 포트를 받지만 실제 메모리는 single-port SRAM이고, `VX_mem_arb`로 arbitration 된다.
- [`VX_tensor_mem_bank.sv:53`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tensor_mem_bank.sv#L53)
- [`VX_tensor_mem_bank.sv:91`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tensor_mem_bank.sv#L91)

즉 input DMA가 읽고 싶은 cycle에:
- weight DMA
- scale/zp DMA
- output DMA
- external DMA

와 같은 bank를 치면 `req_ready`가 밀릴 수 있다.

### 3. GEMM side is elastic, not the primary bottleneck

`gemm_unit` input은 `VX_pipe_buffer`로 받고 있고, `ready_out`은 `in_flight`에 묶여 있다.
- [`VX_gemm_unit.sv:390`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_unit.sv#L390)
- [`VX_gemm_unit.sv:708`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_unit.sv#L708)

이쪽도 backpressure를 만들 수는 있지만, 현재 waveform에서 보이는 띄엄띄엄한 패턴의 1차 원인은 보통 producer 쪽이다.

## What “One Beat Per Cycle” Actually Requires

실제로 one-beat-per-cycle을 만들려면 아래 조건이 동시에 필요하다.
- TMEM에서 다음 beat를 미리 읽어둘 것
- GEMM에 write하는 동안 다음 TMEM read가 병행될 것
- TMEM arbitration 때문에 한 번 밀리더라도 front buffer가 충분히 흡수할 것
- misaligned access가 있어도 head/body/tail 처리가 throughput을 크게 깨지 않게 설계될 것

지금 구조는 read와 write를 FSM에서 번갈아 수행하므로 이 조건을 만족하지 못한다.

## Design Options

## Option A: Add prefetch FIFO to `VX_lmem_dma_misal`

가장 현실적인 첫 단계다.

핵심 아이디어:
- TMEM read side와 GEMM write side를 느슨하게 분리한다.
- source response를 담아두는 FIFO를 두고, FIFO에 데이터가 있으면 GEMM write를 연속적으로 밀어넣는다.
- 동시에 FIFO가 꽉 차지 않았으면 다음 TMEM read를 미리 issue한다.

필요한 구조:
- source beat FIFO
- misalignment/window logic를 FIFO 앞 또는 뒤에 배치
- `outstanding read count` tracking
- low watermark / high watermark 기반 prefetch

장점:
- 현재 인터페이스를 크게 바꾸지 않고 throughput을 개선할 수 있다.
- aligned input path에서 가장 효과가 크다.

한계:
- TMEM bank가 single-port라 conflict가 심하면 완전한 1 beat/cycle은 여전히 어렵다.
- misaligned head/tail 처리 때문에 steady-state 외 구간에는 bubble이 남는다.

추천도:
- 가장 먼저 시도할 가치가 있다.

## Option B: Split local DMA into independent read and write pipelines

보다 구조적인 해법이다.

핵심 아이디어:
- `read engine`: TMEM에서 가능한 한 계속 read issue
- `packer/aligner`: response를 byte window로 정렬
- `write engine`: GEMM input bus로 연속 write issue

즉 현재의 single FSM을 producer-consumer pipeline으로 나눈다.

필요한 블록:
- request generator
- response reorder or response queue
- byte aligner / shifter
- sink writer
- completion tracker

장점:
- steady-state throughput을 설계적으로 높일 수 있다.
- 향후 output path나 weight path에도 같은 구조를 재사용할 수 있다.

단점:
- RTL 변경량이 크다.
- verification 범위가 크게 늘어난다.

추천도:
- 장기적으로는 이 방향이 맞다.
- 단기 fix로는 부담이 크다.

## Option C: Add an input staging buffer near `gemm_unit`

TMEM 쪽을 당장 크게 바꾸기 어렵다면, `gemm_unit` 바로 앞에 tile staging buffer를 두는 방법이다.

핵심 아이디어:
- compute 시작 전에 input tile 일부 또는 전체를 미리 채운다.
- compute 동안에는 staging buffer에서 GEMM으로 1 beat/cycle 공급한다.

장점:
- `gemm_unit` 입장에서 가장 깔끔한 stream을 만들 수 있다.
- TMEM arbitration latency를 compute와 decouple하기 쉽다.

단점:
- 추가 storage가 든다.
- preload latency가 필요하다.
- double buffering 제어가 필요하다.

추천도:
- 성능 우선이면 강한 후보지만, area와 control complexity를 더 먹는다.

## Option D: Increase TMEM-side parallelism or reduce conflicts

local DMA를 바꿔도 TMEM bank conflict가 심하면 throughput ceiling이 낮다.

가능한 방법:
- input/weight/sz/output schedule을 겹치지 않게 조정
- bank access pattern을 충돌이 덜 나게 바꿈
- 특정 path에 더 높은 arbitration priority 부여
- TMEM bank 구조를 read-friendly 하게 변경

장점:
- root cause 중 하나인 `req_ready` stall을 줄일 수 있다.

단점:
- 구조적 개선 없이 schedule만 조정하면 workload dependence가 크다.

## Recommended Plan

현실적인 순서는 아래가 맞다.

### Step 1. Measure the real stall breakdown

먼저 waveform이나 counter로 stall 원인을 분리해야 한다.

추가하면 좋은 counter:
- `input_dma_src_req_cycles`
- `input_dma_src_wait_cycles`
- `input_dma_dst_req_cycles`
- `input_dma_gemm_backpressure_cycles`
- `input_dma_tmem_backpressure_cycles`
- `input_dma_fifo_empty_cycles` if FIFO is added

이 단계 없이 바로 구조를 바꾸면, 실제 병목이 TMEM conflict인지 DMA FSM인지 구분이 흐려진다.

### Step 2. Implement Option A first

`VX_lmem_dma_misal`에 작은 prefetch FIFO를 붙이는 것이 가장 비용 대비 효과가 좋다.

구체적으로는:
- source read outstanding을 2~4개까지 허용
- source responses를 FIFO에 적재
- FIFO에 충분한 data가 있으면 GEMM write는 계속 진행
- read side는 FIFO high watermark까지만 선행

aligned input path만 봐도 이걸로 bubble이 크게 줄 가능성이 높다.

### Step 3. Re-evaluate TMEM conflicts

Option A 후에도 gap이 크면, 그때는 TMEM bank conflict가 성능 ceiling일 가능성이 높다.

이 경우:
- arbitration priority 조정
- traffic scheduling 변경
- input prefetch timing 조정

중 하나를 봐야 한다.

### Step 4. Move to Option B or C only if needed

아래 조건이면 더 큰 구조 변경이 정당화된다.
- input path가 전체 GEMM throughput 병목으로 확정됨
- Option A로도 목표 throughput에 못 미침
- area/control 증가를 감수할 수 있음

## Practical Notes for This Codebase

### 1. The current input tile shape is favorable

input DMA 설정은:
- `seg_size = 64B`
- `bounds[0] = MT`
- source stride = `KT * 2B`
- dest stride = `MXU_KT * 2B = 64B`

즉 aligned steady-state만 잘 만들면 path 자체는 꽤 단순하다.
- [`VX_gemm_ctrl_with_ldma.sv:53`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_ctrl_with_ldma.sv#L53)
- [`VX_gemm_ctrl_with_ldma.sv:64`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_gemm_ctrl_with_ldma.sv#L64)

따라서 first target은 general misaligned all-case support보다, aligned common case에서 sustained streaming을 높이는 것이 좋다.

### 2. Weight and scale traffic may interfere

현재 input, weight, sz, output local DMA가 모두 같은 TMEM subsystem을 공유한다.
- [`VX_tmem_subsystem.sv:303`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L303)
- [`VX_tmem_subsystem.sv:315`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L315)
- [`VX_tmem_subsystem.sv:327`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L327)
- [`VX_tmem_subsystem.sv:339`](/home/jaeyongjang/project.local/vortex/hw/rtl/mem/VX_tmem_subsystem.sv#L339)

input만 고쳐도 전체가 해결되지 않을 수 있다.

### 3. `gemm_unit` should stay simple unless proven otherwise

현재 문제는 input producer path에 더 가깝다. `gemm_unit` 내부에 복잡한 fetch control을 넣는 것보다, upstream을 stream-like 하게 만드는 것이 더 자연스럽다.

## Conclusion

`gemm_unit input_bus`를 one-beat-per-cycle로 만들려면, 핵심은 `VX_lmem_dma_misal`을 지금의 read-wait-write FSM에서 벗어나게 만드는 것이다.

우선순위는 다음이 적절하다.
1. stall breakdown 계측 추가
2. `VX_lmem_dma_misal`에 prefetch FIFO 추가
3. TMEM arbitration conflict 재측정
4. 필요하면 read/write decoupled DMA 또는 input staging buffer로 확장

단기적으로 가장 실용적인 방향은 Option A다.
