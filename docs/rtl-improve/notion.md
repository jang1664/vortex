# 1) Archiecture

### 1.0) Overall arch diagram
    

## 1.1) 핵심 components

### 1.1.x) vortex pipeline

기본적으로 vortex hardware를 사용함. EX stage에서 FPxINT gemm node를 사용할 수 있도록 확장할 것임

---

### 1.1.x) gemm node

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

### **1.1.x) gemm unit**

- 내부는 똑같음. 밖에서 TMEM에서 bandwidth 높게 data 가져오는 것만 달라짐.

### 1.1.x) gemm_ctrl

- CMD constructor에서 cmd를 생성하면 이걸 적절하게 issue하는 역할
- important assumptions
    - activation = fp16, weight = int4(packed), scale = fp16, zp = int16을 가정.
- 동작 방식
    - Command constructor가 CMD를 생성. CMD를 queue에 넣고 child queue를 지나 실제 sub controller로 전달.
    - sync module을 이용해서 sync함.
        - wait, notify, clear 존재

### 1.1.x) gemm dma ctrl

- gemm_ctrl 과 dma를 연결
- dma load, dma store, notify 커맨드를 받아서 dma config registers에 쓴다.
- 전체 길이가 dma tile 단위로 나누어 안 떨어지면 dma의 seg byte, padding 을 이용한다.
    - 이를 위해 gemm node의 config registers 로부터 M, K, N, qblk 값을 받아야 한다.
- dma node의 config register에 있는 플래그를 계속 읽으면서 dma가 완료되었는지 아닌지를 확인한다. (polling 방식)

### 1.1.x) local DMA unit

- tensor memory ↔ gemm unit 사이의 DMA

---

### 1.1.x) DMA

- job frontend와 dma unit을 가지고 있음.
- dcache 와 SMEM 사이 통신
- stride, bound, address 등을 받아서 DMA operation 수행
- misaligned 지원

---

### 1.1.x) HBM2

- u55c 사용할 것이여서 HBM이 존재함.
- 2 stack이 존재함.
- one stack당 8개의 channel (총 16개의 채널, 32개의 pc). **128bit / channel**
    - 하나의 channel은 2개의 pseudo channel로 나눠짐. pseudo channel은 command bus하고 address bus를 공유해서 request 날릴 때 한번에 하나의 pseudo channel에만 날릴 수 있음. 그렇지만 내부 bank 는 분리되어 있어서 bank level parallelism 가능. 하나의 request를 처리하는데 1cycle 이상 걸리기 때문에 pseudo channel 2개에 대해서 interleaving하면서 request를 주면 overlap 가능.
- **pseudo channel당 64bit data bus를 가짐.**
- DDR임. (clock의 posedge, negedge에 data가 나올 수 있음)
- Burst length는 최대 4까지 가능함. → 32B를 한번에 읽을 때 효율 좋을 것!

### 1.1.x) HBM controller

- vivado IP
- axi3 slave interface가 있음. 2stack HBM을 사용할 때 32개의 axi slave를 사용할 수 있음.
- global mode → 내부에 xbar가 생겨서 모든 axi slave port에서 HBM의 모든 channel 접근 가능
- non global mode → axi slave 당 하나의 pseudo channel에만 접근 가능.
- default address map은 contigous. interleaving으로 쓰려면 외부에서 address remap이 필요함.

---

### 1.1.x) interconnections

- vortex의 master axi port는 8개를 사용한다. HMSS에서는 8:32 interconnection이 있고 interleaved connection을 사용한다.
- 각 core의 LSU는 cache system을 통해서 HBM을 접근한다. core가 여러 개일 때 bandwidth를 높이기 위해 cache system은 multi bank cache를 사용한다. HBM에 접근하기 전에는 axi_adapter를 통해서 여러 개의 mem_interface port를 하나의 master axi port로 arbitration 한다. 이 때 8개의 axi master port로 demuxing을 하는데 주소 기반으로 어떤 axi port로 연결 해야 하는지 결정한다. 전체적으로 보면 LSU는 HBM의 모든 PC에 fully connected이기 때문에 load, store에서의 address 관련 constraint는 존재하지 않는다.
- DMA는 8개의 master axi port를 사용해서 HBM에 접근한다. vortex master axi port와 1:1 connection을 한다. on chip 쪽으로는 8개의 master tmem por를 사용해서 HBM 과 TMEM 사이의 transfer를 한다. HBM port와 TMEM port 사이에도 simple한 1:1 connection을 사용한다. 그렇기 때문에 DMA 입장에서는 address 관련 constraint가 생긴다. constraint는 다음과 같다. 64B짜리 8개이기 때문에 512 기준으로 constraint가 생긴다. 즉 HBM ↔ TMEM 에서는 **hbm_addr % 512 == TMEM_addr%512** 이여야 한다. TMEM은 64B 짜리 single port ram 8 bank를 사용한다. interleaving address scheme을 사용한다. 이 때 TMEM과 gemm_unit 사이에도 simple한 interconnection을 사용하기 때문에 constraint가 존재한다. gemm unit은 port로 input, weight 등 tensor의 특정 위치에 align 된 segment가 들어오는 것을 가정한다. 예를들어 input의 경우 1x32 형태의 vector를 기대하는데 element의 idx는 (x, y*32:y*32+32 | x, y 는 정수) 를 기대한다. gemm unit은 port들은 64B이고 그래서 8개의 bank 중 하나를 선택해서 communication 한다. 종합적으로 생각하면 TMEM에 tensor를 저장할 때 MXU에 data를 feed하는데 문제 없는 형태로 저장되어야 하고 constraint는 아래에 정리해뒀다.
    - HBM ↔ TMEM 에서는 **hbm_addr % 512 == TMEM_addr%512**
    - TMEM ↔ MXU 일 때 TMEM의 address constraint
        - input
            - base_addr(input[x,32y+:32]) % 64 == 0
        - weight
            - base_addr(weight[4x+:4, 32*y+:32])%64 == 0
        - output
            - base_addr(output[x,32y+:32]) % 64 == 0
        - scale, zero point
            - base_addr(scale or bias[x, 32y+:32])%64 == 0 | where qdir == 0
            - base_addr(scale or bias[32x+:32, y])%64 == 0 | where qdir == 1

## 1.x) address space map

- 여러 개의 address space 존재
    - 서로 다른 address space은 주소 겹침 고려 안함.
    - core 마다 CSR이 있음. CSR 접근은 CSR 명령의 12-bit immediate로 접근 (소프트웨어에선 csrr/csrw 또는 csr_read/csr_write 매크로 사용)
    - 각 instruction 마다 어떤 주소 공간을 접근하지는 정해져 있다.
    
    ```bash
    csrr x?, 0xB00 -> CSR 공간 접근
    lw x?, 0xB00(x0) -> 메모리 or IO 공간 접근
    ```
    
- 주소 공간 종류
    - CSR
    - memory
    - IO

**XLEN64 주소공간**

| **영역** | **기본 주소/범위** | **크기** | **Scope** | **접근 방법** |
| --- | --- | --- | --- | --- |
| Kernel image + global/static 변수 (.text/.data/.bss) | STARTUP_ADDR = 0x0000_0000_8000_0000부터 배치 | 링크 결과 크기(시뮬레이터 VM 예약 예: 0x40000) | 프로그램 이미지(디바이스 공통) | IFetch + load/store |
| User/global alloc 시작점 | USER_BASE_ADDR = 0x0000_0000_0001_0000 | GLOBAL_MEM_SIZE = 0x2_0000_0000 (8GB) 내 | 디바이스 global memory | vx_mem_alloc, load/store |
| IO window | [0x0000_0000_0000_0040, 0x0000_0000_0001_0000) | 0xFFC0 | MMIO 메모리 공간 | LSU load/store (MEM_REQ_FLAG_IO) |
| Console MMIO | [0x0000_0000_0000_0040, 0x0000_0000_0000_0080) | 64B | 디바이스 콘솔 | store byte |
| MPM MMIO dump | IO_MPM_ADDR = 0x0000_0000_0000_0080, core별 + 0x100 * core_id | 256B/core (exitcode = +0x8) | core별 성능카운터 dump 영역 | 커널 dump + 호스트 조회 |
| Stack | STACK_BASE_ADDR = 0x0000_0001_FFFF_0000, sp = base - (mhartid << 13) | 8KB/hart | hart별 | 일반 메모리 접근 |
| LMEM (local memory) | 기본 LMEM_BASE_ADDR = STACK_BASE_ADDR = 0x0000_0001_FFFF_0000 | 2^LMEM_LOG_SIZE = 16KB ([0x...F0000, 0x...F4000)) | core-local | LSU local flag 경로 |
| Page-table reserved (VM_ENABLE) | PAGE_TABLE_BASE_ADDR = 0x0000_0000_F000_0000 | runtime가 상위 구간 예약 | VM 시스템 영역 | 런타임/페이지테이블 |

| name | start | size | note |
| --- | --- | --- | --- |
| IO_WINDOW | 64'h000000040 | 65472B | IO 전체 space |
| IO_COUT | 64'h000000040 | 64B | console |
| IO_MPM | 64'h000000080 | 256B/core | Machine Performance-monitoring, core마다 있음 |
| **IO_GEMM0** | 64’h000001080 | 1KB | GEMM |
| **IO_GEMM1** | 64’h000001480 | 1KB | DMA |
| USER | 64'h000010000 |  | malloc 같은거 여기로 들어감 |
| STARTUP_ADDR | 64'h080000000 |  | text, …, data, .. 등 여러 section 들어감 |
| Page-table reserved | 0x0000_0000_F000_0000 |  | Virtual memory? |
| STACK | 64'h1_FFFF_0000(밑으로 내려감) | 8KB | (thread 마다 독립적) |
| LOCAL | 64'h1FFFF0000 | 16KB | thread block 마다 독립적 |

**공통(Control-space, XLEN 무관)**

| **공간** | **주소** | **Scope** | **접근 방법** |
| --- | --- | --- | --- |
| CSR | 12-bit (0x000~0xFFF, 예: MPM 0xB00/0xB80) | core-local(코어마다 CSR 인스턴스) | csrr/csrw 명령 |
| DCR(base) | 0x001~0x005 | host가 설정, 각 core에 fanout/copy | Host MMIO를 통한 DCR write |
| Host AFU MMIO | offset 0x00, 0x10, 0x18, 0x20, 0x28, 0x30 | host-device 제어 평면 | PCIe/XRT register R/W |
| Scope 채널 | MMIO_SCP_ADDR(0x28) + scope cmd | 로직 분석기 제어 | host callback (vx_scope_*) |

## 1.2) design paramters

hardware design parameter는 다음과 같음.

- mxu size
- gemm node와 local memory 사이의 interconnection width

### 1.2.1) design parameter constraints

- qblk 은 2의 제곱

## 1.3) Instructions

### 1.3.1) overview

- 기본적으로 RV32
- MMIO register를 사용해서 dma node와 gemm node를 activate하는 방식을 사용함.

### 1.3.1) register map

## 1.4) future challenges and optimization

[Data feeding](https://www.notion.so/Data-feeding-32c3080e2668800e9b47e4473e352eb1?pvs=21)

[programmability](https://www.notion.so/programmability-3303080e266880ef9cd6c011e0a00183?pvs=21)

- gemm을 hardware DMA, FSM freq 높이기
    - fsm에서 주소 계산이 생각보다 critical path에 포함됨. 주소가 high bit이고 곱셈이 있어서..

---

- gemm_unit에서 weight load할 때 여러 row씩 한번에 하기
    - row-major에서는 한번에 여러 row를 가져오려면 DMA가 segment를 쪼개야함.
    - DMA의 bitwidth 등 어떻게 설계할지 생각해야함.
    - data width converting 관점도 최적화해야함.
- gemm unit에서의 pre process, post proess의 overhead
    - mxu size가 작아지면 작아질수록 overhead가 커질 것임.

# 2) programming

- openCL 사용
- MMIO register에 접근하는 방식으로 gemm node와 dma node를 async하게 사용함.

# 3) simulation

- vortex의 SIMX 사용

# 4) hardware implementation

## 4.1) gemm node

## 4.2) dma node

## 4.3) implement on FPGA

U55C에 hardware를 올릴 예정. 구체적인 정보는 아래 페이지 참고

[implementation on FPGA](https://www.notion.so/implementation-on-FPGA-2733080e2668804681b3c87946a74875?pvs=21) 

[Hardware candidates](https://www.notion.so/Hardware-candidates-3213080e26688084a1f2e1cdaaac4291?pvs=21)

[PnR 결과](https://www.notion.so/PnR-3213080e26688014bc57d451904166db?pvs=21)

# 5) software implementation

## 5.1) memory region

- dram region
    - 일반적인 dram address space
- local mem region
    - core 내부의 local memory region
- MMIO register region
    - gemm node와 dma node 내부의 register region
- gemm node 내부의 acc memory는 software 쪽으로 노출되지 않음.

## 5.1) kernel implementation

### 5.1.1) gemm 계열

**5.1.1.1) tensor layout**

**5.1.1.2) gemm**

**5.1.1.3) gemm_qk**

**5.1.1.4) gemm_pv**

# 6) quantization

[FP-INT GEMM math expr](https://www.notion.so/FP-INT-GEMM-math-expr-2f13080e266880f5a46fee4964073d2f?pvs=21)

[spinQuant](https://www.notion.so/spinQuant-2f13080e26688084a444d832ed8b31c7?pvs=21)

# 7) Analysis

## FPGA equivalent gate area

- 논문에서 사용됐던 방법
    
    ## 접근법 A: ENS (Equivalent Number of Slices) — 논리적 등가 변환
    
    COMET 논문 (arXiv 2510.03516)에서 정의한 ENS metric이 정확히 이 방식이야. DSP와 BRAM을 "이걸 LUT/Slice로 구현하면 몇 개 필요한가"를 실측해서 slice-equivalent로 변환:
    
    ```
    ENS = LUTs/4 + DSP_used × 102.4 + BRAM18K_used × 116.2
    ```
    
    구체적으로, DSP48E (25×18 multiplier)를 순수 slice로 구현하면 약 128 slice인데, 실제 사용에서 partial utilization을 반영해서 0.8을 곱해 102.4 slice/DSP. 18Kb BRAM은 dual-port RAM 기준으로 166 slice equivalent에 0.8을 곱해 116.2 slice/BRAM.
    
    이 weight의 근거: **실제로 해당 기능을 DSP/BRAM 없이 합성해보고 필요한 slice 수를 측정한 것.** 즉 Vivado에서 `set_property USE_DSP 0`으로 놓고 같은 multiplier를 합성하면 나오는 slice 수가 기준.
    
    ## 접근법 B: Device 리소스 비율 기반 — Mix and Match (IEEE)
    
    Mix and Match 논문에서는 FPGA 디바이스마다 LUT, FF, BRAM, DSP의 비율이 다르다는 점에 주목해서, 모든 리소스를 DSP 수 기준으로 normalize해서 비교. 예를 들어:
    
    ```
    XC7Z020: LUT:DSP ≈ 240:1, BRAM:DSP ≈ 2:1
    XC7Z045: LUT:DSP ≈ 250:1, BRAM:DSP ≈ 2.5:1
    ```
    
    이건 "이 디바이스에서 DSP 1개를 쓰면 LUT 240개분의 die area를 쓰는 것과 같다"는 관점. Weight를 die area 비율로 잡는 방식의 근거는 **FPGA vendor가 die에 각 리소스를 배치할 때, 전체적으로 balanced utilization이 되도록 설계한다**는 가정이야.
    
    ## 두 접근법의 핵심 차이
    
    |  | ENS (논리 등가) | Device 비율 (die area) |
    | --- | --- | --- |
    | **weight 근거** | "DSP를 LUT로 대체하면 몇 개?" | "die에서 DSP가 차지하는 면적 비율" |
    | **측정 방법** | cross-synthesis 실측 | die photo / 리소스 수 비율 역산 |
    | **의미** | 기능적 복잡도 | 물리적 silicon 비용 |
    | **장점** | 직관적, 재현 가능 | ASIC area 비교에 더 적합 |
    | **한계** | routing overhead 미반영 | device마다 비율이 달라서 portability 낮음 |
    
    ## 실무적으로 어느 게 맞아?
    
    **너의 용도 (Ozaki NPU FPGA vs ASIC 비교)에는 ENS 방식이 더 적합해.** 이유:
    
    1. 기능적 등가 변환이라 "이 accelerator의 complexity가 얼마인가"를 single number로 표현 가능
    2. Reviewer에게 설명하기 쉬움: "DSP 1개 = LUT 128개 equivalent (실측 기반)"
    3. ASIC gate count와 연결하려면 ENS에 Synopsys의 6 gates/LUT를 곱하면 rough gate equivalent가 나옴
    
    ```
    ASIC_gate_equiv ≈ ENS × 4 (LUTs/slice) × 6 (gates/LUT) = ENS × 24
    ```
    
    물론 Kuon & Rose의 35× gap을 감안하면 실제 ASIC die area는 이것의 1/35이 되겠지만, 비교의 방향성은 잡을 수 있어.
    

### Algorithmic Operation Intensity (AOI)

- llama2-spinquant-A16W4A4KV4
    
    기준은 다음이다.
    
    - 모델: Llama-2 7B
    - 기호:
        - B = batch size
        - S = prefill sequence length
        - L = decode 시점의 context length
        - H = hidden size
        - I = intermediate size
    - 정밀도:
        - activation = A16 = 2 bytes/elt
        - weight = W4 = 0.5 bytes/elt
        - KV cache = KV4 = 0.5 bytes/elt
    - OI 정의:
        - OI = FLOPs / minimal tensor bytes
    - attention은 **fused** 기준으로 둔다.
        - 즉, QK^T / softmax / AV 사이의 중간 score, prob를 HBM/DRAM에 별도 materialize하지 않는 이상적인 algorithmic OI다.
    - Llama-2 7B config는 hidden_size 4096, intermediate_size 11008, attention heads 32, key-value heads 32다. SpinQuant는 mergeable rotation R1/R2와 online Hadamard R3/R4를 두며, 논문 설명상 R3는 low-bit KV-cache, R4는 low-bit activation 쪽에 해당한다. 따라서 **A16W4KV4에서는 런타임 추가 커널을 보수적으로 R3만 포함하는 해석이 자연스럽다.** ([Hugging Face](https://huggingface.co/NousResearch/Llama-2-7b-hf/blob/main/config.json?utm_source=chatgpt.com))
    
    ---
    
    ## 1) Prefill table
    
    여기서는 총 처리 토큰 수를
    
    N_prefill = B*S
    
    로 둔다.
    
    | Kernel | FLOPs | Minimal bytes | Algorithmic OI |
    | --- | --- | --- | --- |
    | Q/K/V/O proj | 2*(B*S)*H^2 | 4*(B*S)*H + 0.5*H^2 | (2*B*S*H^2) / (4*B*S*H + 0.5*H^2) |
    | Gate proj | 2*(B*S)*H*I | 2*(B*S)*(H+I) + 0.5*H*I | (2*B*S*H*I) / (2*B*S*(H+I) + 0.5*H*I) |
    | Up proj | 2*(B*S)*H*I | 2*(B*S)*(H+I) + 0.5*H*I | (2*B*S*H*I) / (2*B*S*(H+I) + 0.5*H*I) |
    | Down proj | 2*(B*S)*I*H | 2*(B*S)*(H+I) + 0.5*H*I | (2*B*S*I*H) / (2*B*S*(H+I) + 0.5*H*I) |
    | Fused self-attention | 4*B*S^2*H | 8*B*S*H | S/2 |
    | RoPE | O(B*S*H) | O(B*S*H) | O(1) |
    | RMSNorm | O(B*S*H) | O(B*S*H) | O(1) |
    | SiLU + gate multiply | O(B*S*I) | O(B*S*I) | O(1) |
    | KV4 cache write | small compute, store-dominated | store-dominated | very low |
    | SpinQuant R3 online Hadamard | N_had*log2(g) | 4*N_had | log2(g)/4 |
    
    메모:
    
    - 여기서 g는 Hadamard block size다.
    - A16W4KV4에서는 activation이 16-bit이므로, SpinQuant의 online 추가 커널은 보통 R3만 따로 보면 된다. R3/R4의 역할 구분은 SpinQuant 본문 설명을 따른다.
    
    ---
    
    ## 2) Decode table
    
    여기서는 한 decode step에서 sequence마다 1 token씩 처리하므로, dense projection 쪽의 유효 토큰 수는
    
    N_decode = B
    
    로 둔다.
    
    | Kernel | FLOPs | Minimal bytes | Algorithmic OI |
    | --- | --- | --- | --- |
    | Q/K/V/O proj | 2*B*H^2 | 4*B*H + 0.5*H^2 | (2*B*H^2) / (4*B*H + 0.5*H^2) |
    | Gate proj | 2*B*H*I | 2*B*(H+I) + 0.5*H*I | (2*B*H*I) / (2*B*(H+I) + 0.5*H*I) |
    | Up proj | 2*B*H*I | 2*B*(H+I) + 0.5*H*I | (2*B*H*I) / (2*B*(H+I) + 0.5*H*I) |
    | Down proj | 2*B*I*H | 2*B*(H+I) + 0.5*H*I | (2*B*I*H) / (2*B*(H+I) + 0.5*H*I) |
    | Fused decode attention | 4*B*H*L | B*H*(L+4) | 4*L / (L+4) |
    | RoPE | O(B*H) | O(B*H) | O(1) |
    | RMSNorm | O(B*H) | O(B*H) | O(1) |
    | SiLU + gate multiply | O(B*I) | O(B*I) | O(1) |
    | KV4 cache write | small compute, store-dominated | store-dominated | very low |
    | SpinQuant R3 online Hadamard | N_had*log2(g) | 4*N_had | log2(g)/4 |
    
    decode attention의 bytes 항은 다음처럼 본 것이다.
    
    - Q read: 2*B*H
    - K-cache read: 0.5*B*H*L
    - V-cache read: 0.5*B*H*L
    - output write: 2*B*H
    
    합치면
    
    B*H*(L + 4)
    
    이 된다.
    
    ---
    
    ## 3) 핵심 해석
    
    ### Prefill
    
    - dense proj OI는 B*S에 비례해서 빠르게 증가한다.
    - fused attention OI는 S/2라서 sequence가 길수록 커진다.
    - 그래서 prefill은 batch와 prompt가 커질수록 **compute-friendly** 해진다.
    
    ### Decode
    
    - dense proj OI는 B에만 비례해서 증가한다.
    - fused decode attention OI는 4*L/(L+4) 이므로, L이 커져도 결국 4 근처에서 포화된다.
    - 그래서 decode는 특히 attention/KV path가 **구조적으로 memory-sensitive** 하다.
    
    즉, 같은 모델이어도 대체로
    
    - prefill: MXU, on-chip feed bandwidth 쪽을 보기 쉬움
    - decode: HBM/KV-cache path, pseudo-channel 수, outstanding request 수를 보기 쉬움
    
    이라는 방향이 나온다. 이 해석은 위 식들에서 직접 따라온다.
    
    ---
    
    ## 4) Llama-2 7B 상수 대입 후, 감만 보는 식
    
    여기부터는 표 바깥에서만 상수를 넣겠다.
    
    Llama-2 7B에서는
    
    - H = 4096
    - I = 11008
    
    이므로 아래처럼 정리된다. ([Hugging Face](https://huggingface.co/NousResearch/Llama-2-7b-hf/blob/main/config.json?utm_source=chatgpt.com))
    
    ### Prefill
    
    Q/K/V/O proj:
    
    OI = (2*B*S*4096^2) / (4*B*S*4096 + 0.5*4096^2)= 2048*B*S / (B*S + 512)
    
    Gate/Up/Down proj:
    
    OI = (2*B*S*4096*11008) / (2*B*S*(4096+11008) + 0.5*4096*11008)
    
    ≈ 2985.2*B*S / (B*S + 746.3)
    
    Fused self-attention:
    
    OI = S/2
    
    ### Decode
    
    Q/K/V/O proj:
    
    OI = (2*B*4096^2) / (4*B*4096 + 0.5*4096^2)= 2048*B / (B + 512)
    
    Gate/Up/Down proj:
    
    OI = (2*B*4096*11008) / (2*B*(4096+11008) + 0.5*4096*11008)
    
    ≈ 2985.2*B / (B + 746.3)
    
    Fused decode attention:
    
    OI = 4*L / (L + 4)
    
    ---
    
    ## 5) 숫자 감 몇 개
    
    ### Prefill 예시 1
    
    B = 1, S = 128
    
    - Q/K/V/O proj:
        
        OI = 2048*128 / (128 + 512) = 409.6
        
    - MLP proj:
        
        OI ≈ 2985.2*128 / (128 + 746.3) ≈ 436.7
        
    - Attention:
        
        OI = 128/2 = 64
        
    
    ### Prefill 예시 2
    
    B = 8, S = 512
    
    - Q/K/V/O proj:
        
        OI = 2048*4096 / (4096 + 512) ≈ 1820.4
        
    - MLP proj:
        
        OI ≈ 2985.2*4096 / (4096 + 746.3) ≈ 2525.1
        
    - Attention:
        
        OI = 512/2 = 256
        
    
    ### Decode 예시 1
    
    B = 1, L = 2048
    
    - Q/K/V/O proj:
        
        OI = 2048 / (1 + 512) ≈ 3.99
        
    - MLP proj:
        
        OI ≈ 2985.2 / (1 + 746.3) ≈ 4.00
        
    - Attention:
        
        OI = 4*2048 / (2048 + 4) ≈ 3.99
        
    
    ### Decode 예시 2
    
    B = 8, L = 2048
    
    - Q/K/V/O proj:
        
        OI = 2048*8 / (8 + 512) ≈ 31.5
        
    - MLP proj:
        
        OI ≈ 2985.2*8 / (8 + 746.3) ≈ 31.7
        
    - Attention:
        
        OI ≈ 3.99
        
    
    ### Decode 예시 3
    
    B = 64, L = 2048
    
    - Q/K/V/O proj:
        
        OI = 2048*64 / (64 + 512) ≈ 227.6
        
    - MLP proj:
        
        OI ≈ 2985.2*64 / (64 + 746.3) ≈ 235.7
        
    - Attention:
        
        OI ≈ 3.99
        
    
    ---
    
    ## 6) 한 줄 결론
    
    이 표에서 가장 중요한 포인트는 이거다.
    
    - prefill은 OI가 B*S 또는 S에 의해 빠르게 커진다.
    - decode는 dense proj만 B에 따라 커지고, attention은 거의 항상 OI <= 4 근처다.
    
    그래서 **decode target accelerator라면 HBM/KV path가 먼저 병목이 될 가능성이 높고**,
    
    **prefill target accelerator라면 MXU와 on-chip data delivery가 먼저 병목이 될 가능성이 높다.**
    
    원하면 다음 답변에서 이걸 그대로 이어서 **“HBM ridge point와 비교하는 roofline 입력표”** 형태로 정리해줄게.
    

### Theoritical bandwidth/throughput

- Naive FPINT hardware (916cc66824ae)
    
    **memory의 bandwidth**
    
    - **HBM**
        - PC의 갯수에 따라서 bandwidth가 달라진다. port는 byte width는 64B로 고정. freq는 100M 일때 PC당 6.25GB/s (FPGA 이론 bandwidth는 대략 14GB/s 정도로 생각하면 됨)
        - total bandwidth : 6.25*N_PC [GB/s]
            - N_PC==32 → `200.0` [GB/s]
    - cache system (L2 only)
        - 내부에 cache system이 있음. multi port임. port는 cache line 기준으로 움직여서 64B cache line을 사용함.
        - socket/core 에서 port는 1개로 나옴 (dcache disenable)
        - socket 갯수 == NUM_CORES/4 이기 때문에 1임
        - L2 cache port num 은 그래서 1개 → 64B / cycle
        - bandwidth : 6.25 [GB/s]
    - LMEM
        - NUM_TH banks → 8 사용 중
        - port width : XLEN (64bit)
        - bandwidth : 64B / cycle == 6.25 [GB/s]
    - TMEM
        - 64B bank N개. freq는 100M. single port
        - bandwidth
            - N==32 → 200 [GB/s]
    - REGS
        - 4 bank 로 구현됨. 3 read port, 1 write port. bank 당 1 port sp ram
        - port width == NUM_TH x XLEN == 8 x 8B == 64B
        - bandwidth : 64B x 4 == 256B / cycle
            - 100MHz → 25 [GB/s]
    
    **compute units의 이론적 throughput**
    
    - **MXU**
        - Throughput : 2*MXU_ROW*MXU_COL*F
            - 32x32, 100M → 200 [Gops/s]
        - input req_bandwidth
            - 32 x 2B / cycle →  6.25 [GB/s]
        - output req bandwidth
            - 32 x 2B / cycle → 6.25 [GB/s]
            - dataflow에 따라서 accumulation 때문에 요구 사항이 줄어들 수 있음.
        - weight req bandwidth
            - 512B / cycle → 50 [GB/s]. 이 정도면 1 cycle에 weight 전부 갈기 가능.
            - reuse factor가 높아지면 점점 요구량이 작아짐.
    - **SIMD ALU**
        
        ## 4. SIMD Execution Unit Throughput Analysis
        
        This section analyzes ALU, FPU, and TCU throughput using parametric variables first, then substitutes the concrete configuration values.
        
        ### 4.1 Parametric Model
        
        ### Execution Unit Sizing
        
        Each unit has **lanes** (parallel ALUs/FPUs per block) and **blocks** (independent issue slots).
        
        | Unit | Lanes | Blocks | Source |
        | --- | --- | --- | --- |
        | ALU (INT) | `NUM_ALU_LANES` = `SIMD_WIDTH` | `NUM_ALU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:362-365` |
        | FPU (FP) | `NUM_FPU_LANES` = `SIMD_WIDTH` | `NUM_FPU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:370-373` |
        | TCU | `NUM_TCU_LANES` = `NUM_THREADS` | `NUM_TCU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:399-401` |
        | LSU | `NUM_LSU_LANES` = `SIMD_WIDTH` | `NUM_LSU_BLOCKS` = 1 | `VX_config.vh:378-381` |
        
        Derived:
        
        ```
        SIMD_WIDTH  = NUM_THREADS
        ISSUE_WIDTH = UP(NUM_WARPS / 16)
        ```
        
        ### ALU Throughput per Operation Type
        
        The ALU has two sub-units: `VX_alu_int` (basic arithmetic) and `VX_alu_muldiv` (multiply/divide).
        
        | Operation | Implementation | Pipeline? | Latency | Throughput (instr/cycle/block) |
        | --- | --- | --- | --- | --- |
        | ADD/SUB, AND/OR/XOR, SLL/SRL/SRA | Combinatorial (`VX_alu_int.sv`) | Single-cycle | 1 cycle | **1** |
        | Branch (BEQ, BLT, ...) | Combinatorial + buffer | 1 cycle | **1** |  |
        | MUL/MULH | Pipelined shift register (`VX_alu_muldiv.sv:81`) | Yes | `LATENCY_IMUL` cycles | **1** |
        | DIV/REM | Serial divider (`VX_serial_div`) | No (blocking) | ~`XLEN` cycles | **1/XLEN** |
        - **MUL is fully pipelined**: `VX_shift_register` with `DEPTH=LATENCY_IMUL`. Accepts new instruction every cycle despite multi-cycle latency.
        - **DIV is serial**: blocks the unit for ~`XLEN` cycles per instruction.
        
        **ALU operations per cycle per block (all lanes fire in parallel):**
        
        ```
        Throughput_ALU_arith = NUM_ALU_LANES × 1 op/cycle                      (ADD, SUB, logic, shift)
        Throughput_ALU_mul   = NUM_ALU_LANES × 1 op/cycle  (pipelined)         (MUL, MULH)
        Throughput_ALU_div   = NUM_ALU_LANES × (1/XLEN) op/cycle  (serial)    (DIV, REM)
        ```
        
        Reference: `VX_platform.vh:186-198`, `VX_alu_muldiv.sv:81-93`
        
        ### FPU Throughput per Operation Type
        
        The FPU uses `VX_pe_serializer` to share physical PEs across SIMD lanes. `PE_RATIO` controls how many lanes share one PE.
        
        ```
        NUM_PEs = UP(NUM_FPU_LANES / PE_RATIO)
        BATCH_SIZE = NUM_FPU_LANES / NUM_PEs
        ```
        
        - When `PE_RATIO = 1`: `NUM_PEs = NUM_FPU_LANES` → passthrough (no serialization)
        - When `PE_RATIO > 1`: `NUM_PEs < NUM_FPU_LANES` → serialized in `BATCH_SIZE` batches
        
        | Operation | Latency | PE_RATIO | NUM_PEs | BATCH_SIZE | Instr Throughput |
        | --- | --- | --- | --- | --- | --- |
        | FMA (FADD/FMUL/FMADD) | `LATENCY_FMA` | `FMA_PE_RATIO` = 1 | `NUM_FPU_LANES` | 1 | **1 instr/cycle** |
        | FDIV | `LATENCY_FDIV` | `FDIV_PE_RATIO` = 8 | `UP(NUM_FPU_LANES/8)` | `NUM_FPU_LANES / NUM_PEs` | **1 / BATCH_SIZE instr/cycle** |
        | FSQRT | `LATENCY_FSQRT` | `FSQRT_PE_RATIO` = 8 | `UP(NUM_FPU_LANES/8)` | same | **1 / BATCH_SIZE instr/cycle** |
        | FCVT | `LATENCY_FCVT` | `FCVT_PE_RATIO` = 8 | `UP(NUM_FPU_LANES/8)` | same | **1 / BATCH_SIZE instr/cycle** |
        | FNCP (misc) | `LATENCY_FNCP` | `FNCP_PE_RATIO` = 2 | `UP(NUM_FPU_LANES/2)` | 2 | **1/2 instr/cycle** |
        
        **FMA is the critical path for GEMM.** With `PE_RATIO=1`, every lane has its own FMA PE → fully pipelined, 1 instruction/cycle.
        
        **FP operations per cycle per block:**
        
        ```
        Throughput_FMA   = NUM_FPU_LANES × 2 FLOPs/lane × 1 instr/cycle   (FMA = 1 MUL + 1 ADD)
        Throughput_FDIV  = NUM_PEs_div × 1 FLOP/lane × (1/LATENCY_FDIV) instr/cycle
        ```
        
        Reference: `VX_config.vh:504-527`, `VX_fpu_fma.sv:20`, `VX_pe_serializer.sv:82-139`
        
        ### TCU Throughput
        
        Each micro-op computes a `TCU_TC_M × TCU_TC_N` output block with `TCU_TC_K`-deep dot products.
        
        ```
        MACs_per_uop = TCU_TC_M × TCU_TC_N × TCU_TC_K
        MACs_per_WMMA = TCU_TILE_M × TCU_TILE_N × TCU_TILE_K
                        = TCU_UOPS × MACs_per_uop
        Cycles_per_WMMA = TCU_UOPS  (1 uop/cycle)
        ```
        
        ### Issue Dispatch Model
        
        ALU, FPU, LSU, TCU have **independent dispatch slots** (`VX_issue_top.sv`). They can issue simultaneously in the same cycle.
        
        ```
        Max concurrent issues = NUM_EX_UNITS × ISSUE_WIDTH
                              = 5 × ISSUE_WIDTH  (ALU, LSU, SFU, FPU, TCU)
        ```
        
        However, all share the **same operand collector** (`VX_opc_unit.sv`), which has:
        
        - 3 read ports, 1 write port
        - `NUM_GPR_BANKS` = 4 register file banks
        - Only 1 operand set fetched per cycle per OPC
        
        So the **operand collector is the true issue bottleneck**: 1 instruction dispatched per cycle per OPC, even though execution units could accept more.
        
        ### 4.2 Concrete Values (NUM_THREADS=8, XLEN=64)
        
        Substituting the configuration:
        
        ```
        SIMD_WIDTH     = NUM_THREADS    = 8
        ISSUE_WIDTH    = UP(4 / 16)     = 1
        NUM_ALU_LANES  = 8
        NUM_FPU_LANES  = 8
        NUM_TCU_LANES  = 8
        NUM_GPR_BANKS  = 4
        LATENCY_IMUL   = 3  (Quartus/Vivado)
        LATENCY_FMA    = 4  (DPI/FPNEW)  or 16 (Vivado DSP)
        LATENCY_FDIV   = 15 (DPI) / 16 (FPNEW) / 28 (Vivado)
        LATENCY_FSQRT  = 10 (DPI) / 16 (FPNEW) / 28 (Vivado)
        LATENCY_FCVT   = 5
        LATENCY_FNCP   = 2
        ```
        
        ### ALU Throughput (concrete)
        
        | Operation | Lanes | Latency | Pipeline | Ops/cycle (all lanes) |
        | --- | --- | --- | --- | --- |
        | ADD/SUB/logic/shift | 8 | 1 cycle | Yes | **8 ops** |
        | MUL/MULH | 8 | 3 cycles | Yes (pipelined) | **8 ops** |
        | DIV/REM | 8 | ~64 cycles | No (serial) | **8 / 64 ≈ 0.125 ops** |
        
        ### FPU Throughput (concrete)
        
        | Operation | NUM_PEs | BATCH_SIZE | Latency | Throughput (ops/cycle, all lanes) |
        | --- | --- | --- | --- | --- |
        | **FMA/FADD/FMUL** | 8 | 1 (passthru) | 4 cycles | **8 ops (= 16 FLOPs)** |
        | FDIV | UP(8/8) = 1 | 8 | 15 cycles | **8 / 8 = 1 op** per 1 instr |
        | FSQRT | UP(8/8) = 1 | 8 | 10 cycles | **1 op** per instruction |
        | FCVT | UP(8/8) = 1 | 8 | 5 cycles | **1 op** per instruction |
        | FNCP | UP(8/2) = 4 | 2 | 2 cycles | **4 ops** per instruction |
        
        > **Note:** For FDIV/FSQRT/FCVT, a single instruction covers all 8 lanes but is serialized internally over `BATCH_SIZE=8` cycles through 1 PE. Throughput shown is per-PE per cycle.
        > 
        
        ### TCU Throughput (concrete, NUM_THREADS=8)
        
        | Parameter | Value |
        | --- | --- |
        | TCU_TC_M × TCU_TC_N × TCU_TC_K | 4 × 2 × 2 |
        | MACs per micro-op | 4 × 2 × 2 = **16 MACs** |
        | TCU_UOPS per WMMA | 32 |
        | MACs per WMMA | 8 × 8 × 8 = **512 MACs** |
        | Cycles per WMMA | 32 cycles |
        | **MACs / cycle** | 512 / 32 = **16 MACs/cycle** |
        
        ### Summary: Peak Throughput per Cycle
        
        | Unit | Operation | Ops/cycle | FLOPs/cycle | Bits read | Bits written |
        | --- | --- | --- | --- | --- | --- |
        | **ALU** | ADD/logic | 8 | 8 | 2 × 512 = 1024 | 512 |
        | **ALU** | MUL (pipelined) | 8 | 8 | 2 × 512 = 1024 | 512 |
        | **FPU** | FMA | 8 | **16** | 3 × 512 = 1536 | 512 |
        | **TCU** | WMMA uop | 1 | **32** (16 MAC) | 3 × 512 = 1536 | 512 |
        
        ### 4.3 100% Utilization을 위한 Input/Output Bandwidth 요구량
        
        ALU/FPU/TCU를 100% 활용하려면, operand collector가 매 cycle 새 instruction을 공급해야 합니다.
        
        ### Operand Collector 공급 능력
        
        ```
        Register read ports      = 3 (rs1, rs2, rs3)
        Bits per port per cycle  = SIMD_WIDTH × XLEN = 8 × 64 = 512 bits
        Read bandwidth           = 3 × 512 = 1,536 bits/cycle (192 bytes/cycle)
        
        Register write ports     = 1
        Write bandwidth          = 1 × 512 = 512 bits/cycle (64 bytes/cycle)
        
        Total register bandwidth = 2,048 bits/cycle (256 bytes/cycle)
        ```
        
        ### 연산별 요구량 vs 공급량
        
        | Unit | Source Operands | Read 요구 (bits/cycle) | Write 요구 (bits/cycle) | Reg File 공급 충분? |
        | --- | --- | --- | --- | --- |
        | **ALU (ADD)** | rs1, rs2 | 2 × 512 = 1,024 | 512 | Yes (1,536 available) |
        | **ALU (MUL)** | rs1, rs2 | 2 × 512 = 1,024 | 512 | Yes |
        | **FPU (FMA)** | rs1, rs2, rs3 | 3 × 512 = 1,536 | 512 | Yes (exact match) |
        | **TCU (uop)** | rs1, rs2, rs3 | 3 × 512 = 1,536 | 512 | Yes (exact match) |
        
        **Register file은 모든 연산에 대해 100% utilization을 지원합니다.** FMA와 TCU는 3-operand이므로 read bandwidth를 100% 소비합니다.
        
        ### 병목: Operand Collector Issue Rate
        
        실제 병목은 register bandwidth가 아니라 **operand collector의 issue rate**입니다.
        
        ```
        NUM_OPCS = UP(NUM_WARPS / (4 × ISSUE_WIDTH)) = UP(4 / 4) = 1
        Issue rate = 1 instruction / cycle / OPC
        ```
        
        한 OPC가 cycle당 1개의 instruction만 fetch → dispatch하므로, 동시에 여러 execution unit에 보낼 수 없습니다.
        
        **단, 다른 warp의 instruction은 interleave됩니다.** Warp-level parallelism으로 pipeline latency를 숨길 수 있습니다:
        
        ```
        FMA pipeline latency = 4 cycles
        Available warps = NUM_WARPS = 4
        → 4 warps가 4-cycle FMA pipeline을 완벽히 채움 (1 warp/cycle 교대 issue)
        → 100% FPU utilization 달성 가능
        
        MUL pipeline latency = 3 cycles
        → 3 warps로 충분, 4 warps면 여유 있음
        ```
        
        ### Data 공급 경로: Register ← Memory
        
        ALU/FPU 100% 활용 시, operand이 이미 register에 있어야 합니다. Register에 data를 채우는 경로의 bandwidth:
        
        ```
        LSU → Register: 1 load instruction/cycle × 8 lanes × 8 bytes = 512 bits/cycle
        
        ALU/FPU 소비:  최대 1,536 bits/cycle (read) + 512 bits/cycle (write)
        ```
        
        **Compute-to-load ratio가 중요합니다:**
        
        | Workload | Compute instr/load instr | Register data 충분 조건 |
        | --- | --- | --- |
        | GEMM (tiled) | O(N) compute per O(1) load | 높은 reuse → 쉽게 충족 |
        | Element-wise (e.g., VADD) | 1:1 | Load 1 cycle + Compute 1 cycle → **50% utilization** |
        | Reduction | N:1 | 높은 reuse → 쉽게 충족 |
        
        Element-wise 연산의 경우 LSU와 ALU/FPU가 동일 OPC를 공유하므로 교대 issue됩니다. 이 경우:
        
        ```
        Element-wise ALU utilization = 1 / (1 + 1) = 50%  (load + compute 교대)
        ```
        
        하지만 LMEM에서의 load는 1-cycle latency이고, warp interleaving으로 숨길 수 있습니다:
        
        ```
        Warp 0: LOAD → ALU → LOAD → ALU ...
        Warp 1:         LOAD → ALU → LOAD → ALU ...
        Warp 2:                 LOAD → ALU → LOAD → ALU ...
        Warp 3:                         LOAD → ALU → LOAD → ALU ...
        → 4 warps 교대 시, 매 cycle ALU 또는 LOAD 가 issue됨
        → ALU: ~50%, LSU: ~50% (이론적 상한)
        ```
        
        ### 4.4 Throughput Summary Diagram
        
        ```
                            Operand Collector (1 instr/cycle)
                            ┌─────────────────────────────────┐
           Reg File ────────┤  3 read × 512b + 1 write × 512b │
           (4 banks)        └────────┬────────────────────────┘
                                     │ dispatch (1 instr/cycle to one of:)
                      ┌──────────────┼──────────────┬──────────────┐
                      ▼              ▼              ▼              ▼
                ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
                │ ALU ×8   │  │ FPU ×8   │  │ TCU ×8   │  │ LSU ×8   │
                │ 8 ops/c  │  │ 16FLOP/c │  │ 16MAC/c  │  │ 512b/c   │
                │ (1 cyc)  │  │ (4 cyc)  │  │ (32 cyc) │  │ (1 cyc)  │
                └──────────┘  └──────────┘  └──────────┘  └──────────┘
                 INT arith     FMA peak      WMMA peak     Memory
        
           Warp interleaving: 4 warps hide pipeline latency
           → FMA 4-cycle latency / 4 warps = 100% utilization possible
        ```
        
    - TCU
        
        **TCU Register File Bandwidth**
        
        **TCU Tile Dimensions (NUM_THREADS=8)**
        
        The TCU computes WMMA (Warp Matrix Multiply-Accumulate) operations by decomposing a tile into micro-ops.
        
        **Tile dimensions** (full WMMA operation):
        
        | Parameter | Computation | Value |
        | --- | --- | --- |
        | `TCU_NT` | `NUM_THREADS` | 8 |
        | `TCU_NR` | constant | 8 |
        | `TCU_TILE_CAP` | 8 × 8 | 64 elements |
        | `TCU_TILE_M` | `1 << 3` | **8** |
        | `TCU_TILE_N` | `1 << 3` | **8** |
        | `TCU_TILE_K` | `64 / max(8, 8)` | **8** |
        
        One WMMA instruction computes: **C[8×8] = A[8×8] · B[8×8] + C[8×8]**
        
        Reference: `VX_tcu_pkg.sv:39-46`
        
        **Block dimensions** (hardware micro-op granularity):
        
        | Parameter | Computation | Value |
        | --- | --- | --- |
        | `TCU_BLOCK_CAP` | `TCU_NT` | 8 |
        | `TCU_TC_M` | `1 << 2` | **4** |
        | `TCU_TC_N` | `1 << 1` | **2** |
        | `TCU_TC_K` | `8 / max(4, 2)` | **2** |
        
        Reference: `VX_tcu_pkg.sv:49-56`
        
        **Micro-op decomposition:**
        
        | Parameter | Computation | Value |
        | --- | --- | --- |
        | `TCU_M_STEPS` | `8 / 4` | 2 |
        | `TCU_N_STEPS` | `8 / 2` | 4 |
        | `TCU_K_STEPS` | `8 / 2` | 4 |
        | **`TCU_UOPS`** | `2 × 4 × 4` | **32 micro-ops / WMMA** |
        
        Reference: `VX_tcu_pkg.sv:59-81`
        
        **Register File Architecture (NUM_THREADS=8)**
        
        | Parameter | Value | Source |
        | --- | --- | --- |
        | `XLEN` | 64 bits | RV64 |
        | `SIMD_WIDTH` | 8 | `= NUM_THREADS` |
        | `NUM_TCU_LANES` | 8 | `= NUM_THREADS` |
        | `NUM_GPR_BANKS` | 4 | Default |
        | Read ports (`NUM_SRC_OPDS`) | 3 (rs1, rs2, rs3) | `VX_opc_unit.sv:59` |
        | Write ports | 1 | `VX_opc_unit.sv:35` |
        | Read latency | 2 cycles | Pipeline stages in `VX_opc_unit.sv` |
        
        **Per-port data width:**
        
        ```
        BANK_DATA_WIDTH = XLEN × SIMD_WIDTH = 64 × 8 = 512 bits (64 bytes)
        ```
        
        Reference: `VX_opc_unit.sv:44`, `VX_config.vh:353-354`
        
        **Register Bandwidth per Cycle**
        
        | Direction | Ports | Width / Port | **Bandwidth / Cycle** |
        | --- | --- | --- | --- |
        | **Read** | 3 | 512 bits | **1,536 bits (192 bytes)** |
        | **Write** | 1 | 512 bits | **512 bits (64 bytes)** |
        | **Total** | 4 | — | **2,048 bits (256 bytes)** |
        
        > **Bank conflict note:** The 4-bank register file serves 3 read requests per cycle via a crossbar arbiter. When multiple requests target the same bank, stalls occur. Best case: all 3 requests hit different banks → 1 cycle. Worst case: all hit the same bank → 3 cycles.
        > 
        
        **TCU per Micro-op Register Access**
        
        Each micro-op reads 3 operands and writes 1 result through the operand collector:
        
        | Operand | Role | Size |
        | --- | --- | --- |
        | `rs1_data` | A matrix row | 8 lanes × 64 bits = **512 bits** |
        | `rs2_data` | B matrix column | 8 lanes × 64 bits = **512 bits** |
        | `rs3_data` | C accumulator | 8 lanes × 64 bits = **512 bits** |
        | `rd` (write) | D result | 8 lanes × 64 bits = **512 bits** |
        
        **Per micro-op: 1,536 bits read + 512 bits write = 2,048 bits**
        
        Reference: `VX_tcu_fp.sv:127-129`
        
        **WMMA Total Register Traffic**
        
        |  | Computation | Value |
        | --- | --- | --- |
        | Read total | 32 uops × 1,536 bits | **49,152 bits (6,144 bytes)** |
        | Write total | 32 uops × 512 bits | **16,384 bits (2,048 bytes)** |
        | **WMMA total** |  | **65,536 bits (8,192 bytes = 8 KB)** |
        | **Minimum latency** | 32 uops (no bank conflicts) | **32 cycles** |
        
        **End-to-End Data Path Summary**
        
        ```
                                1536 b/cyc read
          Register File (4 banks) ─────────────▶  TCU (8 lanes, 4×2 TC block)
                                  ◀─────────────
                                 512 b/cyc write
        
                                 512 b/cyc
          Register File ◀────────────────────▶  LSU (8 lanes)
                                                  │
                                 512 b/cyc        ▼
          LMEM (8 banks, 4 MB)  ◀────────────▶  LSU
                                                  │
                                 512 b/cyc        ▼
          L2 Cache (1 bank, 1 MB) ◀──────────▶  L1 bypass (1 port)
                                                  │
                                 512 b/cyc        ▼
          External Memory (2 banks) ◀─────────▶  L2 (1 port)
        ```
        
          **Bandwidth Comparison**
        
        | Path | Bandwidth / Cycle | Relative |
        | --- | --- | --- |
        | Register → TCU (read) | 1,536 bits | 3× |
        | TCU → Register (write) | 512 bits | 1× |
        | Register ↔ LMEM (via LSU) | 512 bits | 1× |
        | LMEM ↔ L2 | 512 bits | 1× |
        | L2 ↔ External Memory | 512 bits | 1× |
        
        **Key Observations**
        
        1. **Register read bandwidth (1,536 bits/cycle)** is the widest path in the system, enabled by the 3-port operand collector design.
        2. **L1 → L2 single port** is the primary memory-side bottleneck. `DCACHE_DISABLE` forces `DCACHE_NUM_BANKS=1`, limiting `L1_MEM_PORTS` to 1.
        3. **LMEM (8 banks)** provides bank-conflict-free parallel access for all 8 threads, making it the preferred high-bandwidth data store for TCU operands.
        4. **TCU computation** requires 32 cycles per WMMA (8×8×8 tile), moving 8 KB through the register file. The register bandwidth is sufficient to sustain one micro-op per cycle when bank conflicts are avoided.
        5. **Data staging strategy:** To maximize TCU throughput, operand data should be staged in LMEM (8-bank parallel access) and loaded into registers before TCU execution, avoiding the L2 single-port bottleneck during computation.
    
    **interconnect 의 bandwidth**
    
    - HBM ↔ cache system
        - merged interface를 쓰기 때문에 6.25 [GB/s] 가 최대 bandwidth가 됨.
    - LMEM ↔ MXU ports
        - LMEM에서 port 1개 사용함. 8B / cycle → 0.78 [GB/s]
    - DMA ↔ cache
        - port 한 개 사용. 64B / cycle → 6.25 [GB/s]

# Note

[microarchitecture](https://www.notion.so/microarchitecture-2ff3080e26688061b24be523891768ed?pvs=21)

- 26-02-06
    - config register는 32bit 짜리를 쓴다. base address는 64bit를 사용한다. base address를 레지스터에 담을 때는 2개에 나눠 쓴다.
    - config register는 warp 단위로 이루어져 있다. entry가 같으면 warp가 같고 하나의 warp에 있는 여러 스레드가 힘을 합쳐 하나의 dma_load (or store) configuration을 셋한다.
    - gemm node에서 dma의 config register로 stride, bnd, base address 등을 쓸 때는 비어 있는 entry 중 아무 곳에 쓰고 occupy 신호가 존재해서 entry가 occupy 되어있는지 아닌지를 기록한다. occupy 신호를 보면 어떤 warp id에 의해 어떤 entry가 점유되었는지를 알 수 있다.
        - 전체 레지스터 개수 = NUM_ENTRY x NUM_REGS
        - software 입장에선 entry 하나만 보인다. 나머지 entry는 안 보인다.
    - config register에는 각 entry가 working 중인지 아닌지를 나타내는 flag가 존재한다.
        - VX_gemm_dma_ctrl 은 이 플래그를 계속 읽으면서 dma가 완료되었는지 아닌지를 확인한다. (polling 방식)
        - 읽을 때는 occupy 신호를 참고해서 어떤 entry의 flag를 읽어야 하는지를 알 수 있다.

# Previous versions

[version1](https://www.notion.so/version1-2f13080e26688014a1a1f65052623489?pvs=21)

[version2](https://www.notion.so/version2-3343080e266880e4b88dcc828856477c?pvs=21)