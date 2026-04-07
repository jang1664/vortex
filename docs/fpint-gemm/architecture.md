# FPINT GEMM Architecture

## Overall Architecture

기본적으로 vortex hardware를 사용함. EX stage에서 FPxINT gemm node를 사용할 수 있도록 확장할 것임

## 핵심 Components

### Vortex Pipeline

기본적으로 vortex hardware를 사용함. EX stage에서 FPxINT gemm node를 사용할 수 있도록 확장할 것임

---

### GEMM Node

- gemm unit 1개. size는 32x32
- FP-INT GEMM 수행
- 내부에서 scale과 zero point 이용해서 dequantization 수행
- adder tree 방식
- pre processor 존재
    - prealigner
    - scale merger (fp16 multiplier)
    - act_sum
- post processor 존재
    - dequantization logic
    - accumulation logic
    - reformatter

### GEMM Unit

- 내부는 똑같음. 밖에서 TMEM에서 bandwidth 높게 data 가져오는 것만 달라짐.

### GEMM Ctrl

- CMD constructor에서 cmd를 생성하면 이걸 적절하게 issue하는 역할
- important assumptions
    - activation = fp16, weight = int4(packed), scale = fp16, zp = int16을 가정.
- 동작 방식
    - Command constructor가 CMD를 생성. CMD를 queue에 넣고 child queue를 지나 실제 sub controller로 전달.
    - sync module을 이용해서 sync함.
        - wait, notify, clear 존재

### GEMM DMA Ctrl

- gemm_ctrl 과 dma를 연결
- dma load, dma store, notify 커맨드를 받아서 dma config registers에 쓴다.
- 전체 길이가 dma tile 단위로 나누어 안 떨어지면 dma의 seg byte, padding 을 이용한다.
    - 이를 위해 gemm node의 config registers 로부터 M, K, N, qblk 값을 받아야 한다.
- dma node의 config register에 있는 플래그를 계속 읽으면서 dma가 완료되었는지 아닌지를 확인한다. (polling 방식)

### Local DMA Unit

- tensor memory ↔ gemm unit 사이의 DMA

---

### DMA

- job frontend와 dma unit을 가지고 있음.
- dcache 와 SMEM 사이 통신
- stride, bound, address 등을 받아서 DMA operation 수행
- misaligned 지원

---

### HBM2

- u55c 사용할 것이여서 HBM이 존재함.
- 2 stack이 존재함.
- one stack당 8개의 channel (총 16개의 채널, 32개의 pc). **128bit / channel**
    - 하나의 channel은 2개의 pseudo channel로 나눠짐. pseudo channel은 command bus하고 address bus를 공유해서 request 날릴 때 한번에 하나의 pseudo channel에만 날릴 수 있음. 그렇지만 내부 bank 는 분리되어 있어서 bank level parallelism 가능. 하나의 request를 처리하는데 1cycle 이상 걸리기 때문에 pseudo channel 2개에 대해서 interleaving하면서 request를 주면 overlap 가능.
- **pseudo channel당 64bit data bus를 가짐.**
- DDR임. (clock의 posedge, negedge에 data가 나올 수 있음)
- Burst length는 최대 4까지 가능함. → 32B를 한번에 읽을 때 효율 좋을 것!

### HBM Controller

- vivado IP
- axi3 slave interface가 있음. 2stack HBM을 사용할 때 32개의 axi slave를 사용할 수 있음.
- global mode → 내부에 xbar가 생겨서 모든 axi slave port에서 HBM의 모든 channel 접근 가능
- non global mode → axi slave 당 하나의 pseudo channel에만 접근 가능.
- default address map은 contigous. interleaving으로 쓰려면 외부에서 address remap이 필요함.

---

### Interconnections

- vortex의 master axi port는 8개를 사용한다. HMSS에서는 8:32 interconnection이 있고 interleaved connection을 사용한다.
- 각 core의 LSU는 cache system을 통해서 HBM을 접근한다. core가 여러 개일 때 bandwidth를 높이기 위해 cache system은 multi bank cache를 사용한다. HBM에 접근하기 전에는 axi_adapter를 통해서 여러 개의 mem_interface port를 하나의 master axi port로 arbitration 한다. 이 때 8개의 axi master port로 demuxing을 하는데 주소 기반으로 어떤 axi port로 연결 해야 하는지 결정한다. 전체적으로 보면 LSU는 HBM의 모든 PC에 fully connected이기 때문에 load, store에서의 address 관련 constraint는 존재하지 않는다.
- DMA는 8개의 master axi port를 사용해서 HBM에 접근한다. vortex master axi port와 1:1 connection을 한다. on chip 쪽으로는 8개의 master tmem port를 사용해서 HBM 과 TMEM 사이의 transfer를 한다. HBM port와 TMEM port 사이에도 simple한 1:1 connection을 사용한다. 그렇기 때문에 DMA 입장에서는 address 관련 constraint가 생긴다. constraint는 다음과 같다. 64B짜리 8개이기 때문에 512 기준으로 constraint가 생긴다. 즉 HBM ↔ TMEM 에서는 **hbm_addr % 512 == TMEM_addr%512** 이여야 한다. TMEM은 64B 짜리 single port ram 8 bank를 사용한다. interleaving address scheme을 사용한다. 이 때 TMEM과 gemm_unit 사이에도 simple한 interconnection을 사용하기 때문에 constraint가 존재한다. gemm unit은 port로 input, weight 등 tensor의 특정 위치에 align 된 segment가 들어오는 것을 가정한다. 예를들어 input의 경우 1x32 형태의 vector를 기대하는데 element의 idx는 (x, y*32:y*32+32 | x, y 는 정수) 를 기대한다. gemm unit은 port들은 64B이고 그래서 8개의 bank 중 하나를 선택해서 communication 한다.

#### Address Constraints

- HBM ↔ TMEM: **hbm_addr % 512 == TMEM_addr % 512**
- TMEM ↔ MXU:
    - input: `base_addr(input[x, 32y+:32]) % 64 == 0`
    - weight: `base_addr(weight[4x+:4, 32*y+:32]) % 64 == 0`
    - output: `base_addr(output[x, 32y+:32]) % 64 == 0`
    - scale, zero point:
        - `base_addr(scale or bias[x, 32y+:32]) % 64 == 0` (qdir == 0)
        - `base_addr(scale or bias[32x+:32, y]) % 64 == 0` (qdir == 1)

---

## Design Parameters

hardware design parameter는 다음과 같음.

- mxu size
- gemm node와 local memory 사이의 interconnection width

### Design Parameter Constraints

- qblk 은 2의 제곱

## Instructions

### Overview

- 기본적으로 RV32
- MMIO register를 사용해서 dma node와 gemm node를 activate하는 방식을 사용함.

### Register Map

(별도 문서 참조: `sw-stack.md` MMIO Register Map 섹션)

## Future Challenges and Optimization

- gemm을 hardware DMA, FSM freq 높이기
    - fsm에서 주소 계산이 생각보다 critical path에 포함됨. 주소가 high bit이고 곱셈이 있어서..

---

- gemm_unit에서 weight load할 때 여러 row씩 한번에 하기
    - row-major에서는 한번에 여러 row를 가져오려면 DMA가 segment를 쪼개야함.
    - DMA의 bitwidth 등 어떻게 설계할지 생각해야함.
    - data width converting 관점도 최적화해야함.
- gemm unit에서의 pre process, post process의 overhead
    - mxu size가 작아지면 작아질수록 overhead가 커질 것임.

External links:
- [Data feeding](https://www.notion.so/Data-feeding-32c3080e2668800e9b47e4473e352eb1?pvs=21)
- [programmability](https://www.notion.so/programmability-3303080e266880ef9cd6c011e0a00183?pvs=21)
