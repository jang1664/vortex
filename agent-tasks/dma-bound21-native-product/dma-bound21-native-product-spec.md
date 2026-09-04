# DMA Bound/Dimension RTL 최적화 명세

## 상태

**confirmed** — 사용자가 승인한
[`dma-bound21-native-product-plan.md`](dma-bound21-native-product-plan.md)를 구현 기준으로 삼는다.

## 목표

- DMA 내부 bound와 dimension counter를 unsigned 21-bit로 축소한다.
- stride/bound 및 byte-count 곱셈은 operand의 실제 폭으로 수행하고, 주소/카운터 경계에서만 zero-extension한다.
- `MAX_DIMS=1..3` compile-time parameter로 사용하지 않는 dimension의 storage, counter, rollover, multiplier를 제거한다.
- production GEMM local DMA는 1D로 특화하고 generic CPU DMA와 현재 U55C HBM/TMEM DMA는 3D를 유지한다.
- descriptor/MMIO ABI, request/response handshake, command accept/done cycle과 유효 descriptor의 기능 결과를 유지한다.

## 범위

- DMA interface와 공통 config: `VX_config.vh`, `VX_dma_if.sv`, `VX_dma_lookahead_if.sv`, `VX_lmem_dma_ctrl_if.sv`
- generic DMA: `VX_dma_unit*.sv`, `VX_dma_node.sv`, `VX_dma_engine.sv`, correction multiplier
- GEMM/local DMA: `VX_lmem_dma*.sv`, overlap DMA, weight gather와 관련 controller/producer
- production instance parameter: `VX_core.sv`, `VX_tmem_subsystem.sv`, GEMM node 계층
- focused/unit/blackbox/OOC 검증 도구와 testbench

## 확정 설계

1. 기본 `DMA_BOUND_WIDTH`는 21이며 bound는 unsigned다. 필요한 확장은 sign-extension이 아니라 zero-extension이다.
2. 외부 config word와 BND0/1/2 register ABI는 32-bit 그대로다. 내부 경계에서 `[20:0]`을 저장하고 `[31:21] == 0`을 simulation assertion으로 검사한다.
3. `MAX_DIMS=1`은 BND1/2가 1, `MAX_DIMS=2`는 BND2가 1이어야 한다. inactive stride는 무시한다.
4. `MAX_DIMS` 범위와 inactive-bound 계약은 elaboration/simulation assertion으로 검증한다.
5. correction product는 32x21=53-bit이며 1D/2D/3D에 각각 0/2/4개만 존재한다. misaligned DMA의 사용되지 않는 D2 correction pair는 3D에서도 제거한다.
6. total byte product는 1D 53-bit, 2D 74-bit, 3D 95-bit 단계로 계산하고 최종 destination 폭의 overflow를 simulation assertion으로 검증한다.
7. 1D/2D/3D datapath는 generate branch로 만들며 runtime dimension mux를 새로 추가하지 않는다.
8. multiplier가 제거되는 특화에서도 기존 prepare/precalc latency와 done cycle을 유지한다.
9. 기존 response-DPRAM 미커밋 변경은 보존하며 이 작업에서 되돌리거나 별도 의미로 재작성하지 않는다.

## 생산 인스턴스 정책

- `VX_core.u_VX_dma_node`: `MAX_DIMS=3`
- `VX_tmem_subsystem.u_dma_engine`: `MAX_DIMS=3` (현재 target의 `BND2=4` 사용)
- improve input/weight/scale/zero-point/output local DMA: `MAX_DIMS=1`
- naive input/quant-param/output local DMA: `MAX_DIMS=1`
- `VX_gemm_dma_ctrl_with_dma.dma_node`: `MAX_DIMS=1`
- legacy/standalone generic DMA: 기본 `MAX_DIMS=3`

## 검증 계약

- focused dual-DUT 1D/2D 비교에서 request address/data/byteen, handshake와 done cycle이 3D baseline과 동일해야 한다.
- 기존 3D rollover, aligned/misaligned, 양방향, backpressure와 outstanding overlap 회귀가 통과해야 한다.
- invalid upper bound와 inactive bound는 negative test에서 assertion을 발생시켜야 한다.
- FPINT GEMM xrt-vcs-sim 결과는 bit-exact이고 cycle 변화는 2% 이내여야 한다(목표는 동일 cycle).
- 동일 U55C improve TH16/WLOAD8 조건의 GEMM node OOC에서 7ns clock setup violation이 없어야 한다.
- OOC/netlist에서 dimension specialization에 따른 multiplier/metadata 감소가 확인되고 BRAM이 증가하지 않아야 한다.
