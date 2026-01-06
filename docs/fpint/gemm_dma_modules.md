# GEMM & DMA Modules Documentation

이 문서는 Vortex core의 DMA 및 GEMM 관련 모듈들의 역할을 설명합니다.

## Core Modules

### VX_dma_node (`hw/rtl/core/VX_dma_node.sv`)

DMA Engine between data cache and local memory.

- `cfg_reg`를 받아서 동작함. `cfg_reg`에는 stride, bound, segment size, padding 등 정보가 들어있음.
  - start, idle, done signal을 이용해서 시작 시점을 제어함.
  - 내부에 wid, tid 등 정보도 필요하면 추가해서 현재 요청이 어떤 워크 아이템, 스레드인지 추적할 수 있도록 함.
- 3D nested loop를 돌면서 LMEM <-> DCACHE 간 데이터 전송을 수행함.
  - 각 차원별로 stride, bound, segment size, padding 정보를 이용해서 주소 계산을 수행함.
  - 단일 포트 LMEM과 DCACHE 인터페이스를 가정함.

**Future improvements:**
- Support multiple port for better performance

---

## GEMM Modules

### VX_gemm_node (`hw/rtl/core/gemm/VX_gemm_node.sv`)

GEMM 연산을 담당하는 노드.

- LMEM과 GEMM unit 사이의 data width converter 사용.
- 간단하게 하기 위해 single port로 구현.
- top control과 cmd control을 구현해서 control 수행.
  - cmd control은 cmd를 완료할 때, top controller에게 sync 신호를 보냄.

---

### VX_gemm_ctrl (`hw/rtl/core/gemm/VX_gemm_ctrl.sv`)

Gemm 연산할 때 필요한 제어 신호들을 생성하는 모듈. 주로 DMA와 관련된 제어 신호를 생성한다.

- `cfg_reg`를 받아서 동작함. `cfg_reg`에는 matrix 크기, stride, padding 등 정보가 들어있음.
  - start, idle, done signal을 이용해서 시작 시점을 제어함.
  - 내부에 wid, tid 등 정보도 필요하면 추가해서 현재 요청이 어떤 워크 아이템, 스레드인지 추적할 수 있도록 함.
- gemm 연산을 위한 input, weight, output 데이터의 LMEM 접근 제어 신호를 생성함.
  - 각 데이터 타입별로 별도의 read/write 제어 신호를 생성함.
  - gemm_node 안에 있는 local DMA 엔진과 연동됨.
  - LMEM <-> GEMM 유닛 간 데이터 전송을 control 하는 것이 목적.
- tiling을 위해서 global memory (dcache) <-> LMEM 사이의 DMA를 제어함.
  - dma cmd controller에게 제어 신호를 보냄.

---

### VX_lmem_dma (`hw/rtl/core/gemm/VX_lmem_dma.sv`)

DMA Engine for LMEM <-> GEMM Unit data transfer.

- Parameterized by direction (read/write), LMEM data width, GEMM data width

**Usage:**
- `DIR = 0`: LMEM -> GEMM (read from LMEM)
- `DIR = 1`: GEMM -> LMEM (write to LMEM)

---

### VX_gemm_sync (`hw/rtl/core/gemm/VX_gemm_sync.sv`)

Gemm cmd간의 sync를 담당한다.

- parent cmd queue에서 cmd를 받아서 sync를 맞춰주고 child cmd queue로 demuxing 해준다.
- wait와 notify cmd를 처리한다. (나머지 cmd는 demuxing 해줌.)
  - notify는 그전에 들어간 cmd 따라서 감. DMA와 gemm node는 notify cmd를 만나면, sync module로 signal을 보내준다.
  - sync module은 wait cmd를 만나면 조건이 만족될 때까지 stall하고 child queue로 req를 보내는 것을 pending한다.
- sync module 안에는 N개의 sync register가 존재한다. 이걸 사용해서 wait and notify를 구현한다.
  - **notify**: register 하나 골라서 특정 value로 set함.
  - **wait**: 특정 register를 골라서 그게 target하는 condition을 만족하는지 확인함.
    - 예: reg0이 3보다 작다 ← 이런게 이전 compute phase가 끝났는지 알 수 있음. 현재 iteration이 i이면 reg0이 i보다 큰지, 이런식으로 확인

**예시:**
- double buffering할 때 이전 compute stage가 끝났는지 확인 → wait
- compute stage은 자기할거 끝내고 notify
