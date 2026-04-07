# FPINT GEMM Development Notes

## Programming

- openCL 사용
- MMIO register에 접근하는 방식으로 gemm node와 dma node를 async하게 사용함.

## Simulation

- vortex의 SIMX 사용

## Hardware Implementation

### GEMM Node

(별도 문서 참조: `architecture.md`)

### DMA Node

(별도 문서 참조: `architecture.md`)

### FPGA Implementation

U55C에 hardware를 올릴 예정. 구체적인 정보는 아래 페이지 참고

- [implementation on FPGA](https://www.notion.so/implementation-on-FPGA-2733080e2668804681b3c87946a74875?pvs=21)
- [Hardware candidates](https://www.notion.so/Hardware-candidates-3213080e26688084a1f2e1cdaaac4291?pvs=21)
- [PnR 결과](https://www.notion.so/PnR-3213080e26688014bc57d451904166db?pvs=21)

## Software Implementation

### Memory Regions

- dram region — 일반적인 dram address space
- local mem region — core 내부의 local memory region
- MMIO register region — gemm node와 dma node 내부의 register region
- gemm node 내부의 acc memory는 software 쪽으로 노출되지 않음.

### Kernel Implementation

#### GEMM 계열

- tensor layout
- gemm
- gemm_qk
- gemm_pv

(상세 내용은 `sw-stack.md` 참조)

## Quantization

- [FP-INT GEMM math expr](https://www.notion.so/FP-INT-GEMM-math-expr-2f13080e266880f5a46fee4964073d2f?pvs=21)
- [spinQuant](https://www.notion.so/spinQuant-2f13080e26688084a444d832ed8b31c7?pvs=21)

---

## Config Register Notes (2026-02-06)

- config register는 32bit 짜리를 쓴다. base address는 64bit를 사용한다. base address를 레지스터에 담을 때는 2개에 나눠 쓴다.
- config register는 warp 단위로 이루어져 있다. entry가 같으면 warp가 같고 하나의 warp에 있는 여러 스레드가 힘을 합쳐 하나의 dma_load (or store) configuration을 셋한다.
- gemm node에서 dma의 config register로 stride, bnd, base address 등을 쓸 때는 비어 있는 entry 중 아무 곳에 쓰고 occupy 신호가 존재해서 entry가 occupy 되어있는지 아닌지를 기록한다. occupy 신호를 보면 어떤 warp id에 의해 어떤 entry가 점유되었는지를 알 수 있다.
    - 전체 레지스터 개수 = NUM_ENTRY x NUM_REGS
    - software 입장에선 entry 하나만 보인다. 나머지 entry는 안 보인다.
- config register에는 각 entry가 working 중인지 아닌지를 나타내는 flag가 존재한다.
    - VX_gemm_dma_ctrl 은 이 플래그를 계속 읽으면서 dma가 완료되었는지 아닌지를 확인한다. (polling 방식)
    - 읽을 때는 occupy 신호를 참고해서 어떤 entry의 flag를 읽어야 하는지를 알 수 있다.

## Microarchitecture Reference

- [microarchitecture](https://www.notion.so/microarchitecture-2ff3080e26688061b24be523891768ed?pvs=21)

## Previous Versions

- [version1](https://www.notion.so/version1-2f13080e26688014a1a1f65052623489?pvs=21)
- [version2](https://www.notion.so/version2-3343080e266880e4b88dcc828856477c?pvs=21)
