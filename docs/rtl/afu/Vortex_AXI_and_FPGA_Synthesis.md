# Vortex AXI Interface & FPGA Synthesis Guide

## 목차
1. [개요](#1-개요)
2. [Vortex_axi.sv 아키텍처](#2-vortex_axisv-아키텍처)
3. [VX_axi_adapter - Crossbar Switch](#3-vx_axi_adapter---crossbar-switch)
4. [병합 vs 비병합 메모리 인터페이스](#4-병합-vs-비병합-메모리-인터페이스)
5. [Vivado/Vitis 합성 스크립트](#5-vivadovitis-합성-스크립트)
6. [플랫폼별 설정](#6-플랫폼별-설정)
7. [성능 분석](#7-성능-분석)

---

## 1. 개요

**Vortex_axi.sv**는 Vortex GPGPU 코어를 AXI4 메모리 인터페이스로 래핑하는 핵심 모듈입니다. 이 모듈은 Vortex 내부의 메모리 요청을 AXI4 프로토콜로 변환하고, 다중 메모리 뱅크에 대한 병렬 접근을 관리합니다.

### 주요 역할

```
┌──────────────────────────────────────────────────┐
│                  Vortex_axi.sv                   │
├──────────────────────────────────────────────────┤
│                                                  │
│  ┌────────────┐    ┌──────────────┐             │
│  │  Vortex    │───►│ VX_mem_data  │             │
│  │   Core     │    │   _adapter   │             │
│  │            │◄───│ (Width Conv.)│             │
│  └────────────┘    └──────┬───────┘             │
│                           │                      │
│  VX_MEM_PORTS개          │                      │
│  (L3/L2 출력)            ▼                      │
│                   ┌──────────────┐              │
│                   │VX_axi_adapter│              │
│                   │  (Crossbar)  │              │
│                   └──────┬───────┘              │
│                          │                       │
│               AXI_NUM_BANKS개 출력               │
│                          │                       │
│                          ▼                       │
│            AXI4 Master [0..N-1]                  │
└──────────────────────────────────────────────────┘
           │              │              │
           ▼              ▼              ▼
        HBM[0]         HBM[1]  ...   HBM[31]
```

---

## 2. Vortex_axi.sv 아키텍처

### 2.1 모듈 파라미터

```systemverilog
module Vortex_axi #(
    parameter AXI_DATA_WIDTH = VX_MEM_DATA_WIDTH,  // 일반적으로 512-bit
    parameter AXI_ADDR_WIDTH = `MEM_ADDR_WIDTH,    // 플랫폼 의존
    parameter AXI_TID_WIDTH  = VX_MEM_TAG_WIDTH,   // Transaction ID 폭
    parameter AXI_NUM_BANKS  = 1                   // 출력 AXI 뱅크 수
)
```

**파라미터 설명**:
- `AXI_DATA_WIDTH`: AXI 데이터 버스 폭 (일반적으로 512-bit = 64 bytes)
- `AXI_NUM_BANKS`: **병합 모드(1) vs 비병합 모드(32)의 핵심 차이**

### 2.2 내부 계층 구조

#### Stage 1: Vortex Core

```systemverilog
Vortex vortex (
    .clk            (clk),
    .reset          (reset),
    
    // Memory Interface (VX_MEM_PORTS개)
    .mem_req_valid  (mem_req_valid),   // [VX_MEM_PORTS-1:0]
    .mem_req_rw     (mem_req_rw),      // Read/Write
    .mem_req_byteen (mem_req_byteen),
    .mem_req_addr   (mem_req_addr),
    .mem_req_data   (mem_req_data),
    .mem_req_tag    (mem_req_tag),
    .mem_req_ready  (mem_req_ready),
    
    // Memory Response
    .mem_rsp_valid  (mem_rsp_valid),
    .mem_rsp_data   (mem_rsp_data),
    .mem_rsp_tag    (mem_rsp_tag),
    .mem_rsp_ready  (mem_rsp_ready),
    ...
);
```

**VX_MEM_PORTS**:
- L3 cache가 있으면: `L3_MEM_PORTS` (일반적으로 L3 bank 수와 동일)
- L3가 없으면: `L2_MEM_PORTS` (L2 bank 수와 동일)
- 일반적인 설정: **4~8개** (configuration 의존)

#### Stage 2: Memory Data Adapter

```systemverilog
for (genvar i = 0; i < VX_MEM_PORTS; i++) begin
    VX_mem_data_adapter #(
        .SRC_DATA_WIDTH (VX_MEM_DATA_WIDTH),  // Vortex 내부 폭
        .DST_DATA_WIDTH (AXI_DATA_WIDTH),     // AXI 폭 (512-bit)
        ...
    ) mem_data_adapter (
        .mem_req_valid_in   (mem_req_valid[i]),
        .mem_req_valid_out  (mem_req_valid_a[i]),
        ...
    );
end
```

**역할**: Vortex 내부 데이터 폭을 AXI 인터페이스 폭에 맞춤
- 일반적으로 32-bit/64-bit → 512-bit 변환
- Address 재계산 (word-addressable → byte-addressable)

#### Stage 3: AXI Adapter (핵심!)

```systemverilog
VX_axi_adapter #(
    .DATA_WIDTH     (AXI_DATA_WIDTH),      // 512
    .NUM_PORTS_IN   (VX_MEM_PORTS),        // 4~8 (Vortex 출력)
    .NUM_BANKS_OUT  (AXI_NUM_BANKS),       // 1 or 32 (병합 여부)
    .INTERLEAVE     (`PLATFORM_MEMORY_INTERLEAVE),
    ...
) axi_adapter (
    .mem_req_valid  (mem_req_valid_a),  // [VX_MEM_PORTS-1:0] 입력
    .m_axi_awvalid  (m_axi_awvalid),    // [AXI_NUM_BANKS-1:0] 출력
    ...
);
```

---

## 3. VX_axi_adapter - Crossbar Switch

### 3.1 핵심 개념

**VX_axi_adapter**는 **crossbar switch**를 사용하여:
- **N개의 입력 포트** (Vortex 메모리 포트)를
- **M개의 출력 포트** (AXI 뱅크)로 라우팅

```
입력 (NUM_PORTS_IN)         Crossbar         출력 (NUM_BANKS_OUT)
─────────────────────────────────────────────────────────────
  Port 0  ────┐
  Port 1  ────┤                              ┌──── Bank 0
  Port 2  ────┼─── VX_stream_xbar ──────────┼──── Bank 1
  Port 3  ────┤    (Request)                 ├──── ...
    ...   ────┘                              └──── Bank 31
```

### 3.2 Bank Selection Logic

```systemverilog
// Address에서 뱅크 선택
wire [BANK_SEL_WIDTH-1:0] req_bank_sel;
wire [BANK_ADDR_WIDTH-1:0] req_bank_addr;

if (INTERLEAVE) begin
    // Interleaved 모드: 하위 비트가 뱅크 선택
    assign req_bank_sel  = mem_req_addr[BANK_SEL_BITS-1:0];
    assign req_bank_addr = mem_req_addr[BANK_SEL_BITS +: BANK_ADDR_WIDTH];
end else begin
    // Non-interleaved: 상위 비트가 뱅크 선택
    assign req_bank_sel  = mem_req_addr[BANK_ADDR_WIDTH +: BANK_SEL_BITS];
    assign req_bank_addr = mem_req_addr[BANK_ADDR_WIDTH-1:0];
end
```

### 3.3 Request Crossbar

```systemverilog
VX_stream_xbar #(
    .NUM_INPUTS (NUM_PORTS_IN),     // 예: 4
    .NUM_OUTPUTS(NUM_BANKS_OUT),    // 병합=1, 비병합=32
    .DATAW      (REQ_XBAR_DATAW),
    .ARBITER    ("R"),              // Round-robin
    .OUT_BUF    (2)
) req_xbar (
    .clk       (clk),
    .reset     (reset),
    .sel_in    (req_bank_sel),      // 각 입력의 목적지 뱅크
    .valid_in  (req_xbar_valid_in),
    .data_in   (req_xbar_data_in),  // {rw, addr, byteen, data, tag}
    .ready_in  (req_xbar_ready_in),
    
    .valid_out (req_xbar_valid_out),
    .data_out  (req_xbar_data_out),
    .ready_out (req_xbar_ready_out),
    .sel_out   (req_xbar_sel_out),  // 어느 입력에서 왔는지
    ...
);
```

### 3.4 Response Crossbar (역방향)

```systemverilog
VX_stream_xbar #(
    .NUM_INPUTS (NUM_BANKS_OUT),    // AXI 뱅크에서 오는 응답
    .NUM_OUTPUTS(NUM_PORTS_IN),     // Vortex 포트로 되돌림
    ...
) rsp_xbar (
    .sel_in    (rsp_xbar_sel_in),   // m_axi_rid에서 추출한 src port
    .valid_in  (m_axi_rvalid),
    .data_in   ({m_axi_rdata, m_axi_rid}),
    ...
);
```

**Tag 구조**:
```
m_axi_rid = {original_tag, source_port_id}
            └─────┬──────┘  └──────┬───────┘
              응답 매칭        역방향 라우팅
```

### 3.5 AXI Address Reconstruction

```systemverilog
// Write Address
if (INTERLEAVE) begin
    // Bank ID를 주소 하위 비트에 삽입
    m_axi_awaddr[i] = (xbar_addr_out << (BANK_SEL_BITS + LOG2_DATA_SIZE)) 
                    | (i << LOG2_DATA_SIZE);
end else begin
    // Bank ID를 주소 상위 비트에 삽입
    m_axi_awaddr[i] = (xbar_addr_out << LOG2_DATA_SIZE) 
                    | (i << (BANK_ADDR_WIDTH + LOG2_DATA_SIZE));
end
```

**예시** (Interleaved, 32 banks, 512-bit = 64 bytes):
```
Original Address: 0x1000 (word addr)
Bank Select: addr[4:0] = 5 → Bank 5
Bank Addr: addr[31:5]

Final AXI Address = (bank_addr << (5+6)) | (5 << 6)
                  = (0x20 << 11) | (5 << 6)
                  = 0x10000 | 0x140
```

---

## 4. 병합 vs 비병합 메모리 인터페이스

### 4.1 설정 비교

| 항목 | 병합 모드 | 비병합 모드 |
|------|-----------|-------------|
| **Define** | `PLATFORM_MERGED_MEMORY_INTERFACE` | 미정의 |
| **AXI_NUM_BANKS** | 1 | `PLATFORM_MEMORY_NUM_BANKS` (32) |
| **XRT 포트** | `m_axi_mem_0` (1개) | `m_axi_mem_0~31` (32개) |
| **VPP 연결** | `m_axi_mem_0:HBM[0:31]` | `m_axi_mem_i:HBM[i]` (1:1) |
| **Vitis 역할** | SmartConnect 자동 삽입 | 직접 연결 |

### 4.2 병합 모드 (Merged Interface)

#### RTL 설정 (platforms.mk)

```makefile
# U55C 설정
CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32        # Vortex 내부는 여전히 32
CONFIGS += -DPLATFORM_MERGED_MEMORY_INTERFACE    # 병합 모드 활성화
VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]
```

#### vortex_afu.v 포트 생성

```verilog
`ifdef PLATFORM_MERGED_MEMORY_INTERFACE
    parameter C_M_AXI_MEM_NUM_BANKS = 1
`else
    parameter C_M_AXI_MEM_NUM_BANKS = `PLATFORM_MEMORY_NUM_BANKS
`endif

// 외부 포트: 병합 모드면 1개만
`ifdef PLATFORM_MERGED_MEMORY_INTERFACE
    `REPEAT (1, GEN_AXI_MEM, REPEAT_COMMA),  // m_axi_mem_0_*
`else
    `REPEAT (32, GEN_AXI_MEM, REPEAT_COMMA), // m_axi_mem_0~31_*
`endif
```

#### Vortex_axi.sv 내부

```systemverilog
Vortex_axi #(
    .AXI_NUM_BANKS (1)  // ← 병합 모드!
) ...
```

**내부 동작**:
```
Cycle 1: Port 0 request → Crossbar → m_axi_mem_0 (Bank 12로 향함)
Cycle 2: Port 1 request → Crossbar → m_axi_mem_0 (Bank 5로 향함)
Cycle 3: Port 0 request → Crossbar → (대기, Port 1이 아직 진행 중)
         Port 2 request → Crossbar → (대기)
```

**Crossbar 출력이 1개**이므로:
- **1 cycle당 최대 1개의 request만 출력 가능**
- 여러 입력 포트의 request는 **arbitration으로 순차 처리**

#### Vitis SmartConnect 삽입

```
vortex_afu                 SmartConnect              HBM Controller
┌─────────────┐           ┌──────────────┐          ┌──────────────┐
│ m_axi_mem_0 │──────────►│ S00_AXI      │          │ HBM[0]       │
│ (1 port)    │           │              ├─────────►│ HBM[1]       │
└─────────────┘           │ M00~M31_AXI  │          │  ...         │
                          │ (32 ports)   ├─────────►│ HBM[31]      │
                          └──────────────┘          └──────────────┘
```

**SmartConnect**가:
- Address interleaving으로 32개 HBM 채널 분배
- 하지만 **입구가 1개뿐**이므로 병목

#### 성능 제약

```
최대 Throughput = 1 request/cycle × 512-bit = 512-bit/cycle
               = 64 bytes/cycle
               @ 250MHz = 16 GB/s
```

**32배 손실**:
- HBM 32 channels의 이론적 대역폭: ~512 GB/s
- 병합 모드 실제 대역폭: **~16 GB/s**

### 4.3 비병합 모드 (Non-Merged Interface)

#### RTL 설정

```makefile
# U55C - 비병합 모드로 변경하려면
CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32
# CONFIGS += -DPLATFORM_MERGED_MEMORY_INTERFACE  ← 주석 처리!
VPP_FLAGS += $(foreach i,$(shell seq 0 31), \
    --connectivity.sp vortex_afu_1.m_axi_mem_$(i):HBM[$(i)])
```

#### vortex_afu.v 포트 생성

```verilog
// 32개 독립 AXI master 포트
m_axi_mem_0_awvalid, m_axi_mem_0_awaddr, ...
m_axi_mem_1_awvalid, m_axi_mem_1_awaddr, ...
...
m_axi_mem_31_awvalid, m_axi_mem_31_awaddr, ...
```

#### Vortex_axi.sv 내부

```systemverilog
Vortex_axi #(
    .AXI_NUM_BANKS (32)  // ← 비병합 모드!
) ...
```

**내부 동작**:
```
Cycle 1: Port 0 request → Crossbar → m_axi_mem_12 (Bank 12)
         Port 1 request → Crossbar → m_axi_mem_5  (Bank 5)
         Port 2 request → Crossbar → m_axi_mem_31 (Bank 31)
         Port 3 request → Crossbar → m_axi_mem_7  (Bank 7)
         
모두 병렬 실행! (각 출력 뱅크는 독립적)
```

**Crossbar 출력이 32개**이므로:
- **각 뱅크당 1 request/cycle** 가능
- 서로 다른 뱅크로 향하는 request는 **완전 병렬**

#### 직접 HBM 연결

```
vortex_afu                               HBM Controller
┌─────────────────────────────────┐    ┌──────────────┐
│ m_axi_mem_0  ───────────────────────►│ HBM[0]       │
│ m_axi_mem_1  ───────────────────────►│ HBM[1]       │
│ m_axi_mem_2  ───────────────────────►│ HBM[2]       │
│  ...                             │    │  ...         │
│ m_axi_mem_31 ───────────────────────►│ HBM[31]      │
└─────────────────────────────────┘    └──────────────┘

1:1 직접 매핑, SmartConnect 없음
```

#### 성능 이점

```
최대 Throughput = 32 banks × 1 req/cycle × 512-bit
               = 16384-bit/cycle = 2048 bytes/cycle
               @ 250MHz = 512 GB/s
```

**병합 대비 32배 향상!**

### 4.4 Crossbar Arbitration

#### 병합 모드의 Contention

```systemverilog
// 4개 입력 → 1개 출력
VX_stream_xbar #(
    .NUM_INPUTS (4),
    .NUM_OUTPUTS(1),
    .ARBITER    ("R")  // Round-robin
)
```

**시나리오**:
```
Cycle 1:
  Port 0: request to Bank 12 → Crossbar 선택 → 출력
  Port 1: request to Bank 5  → 대기 (충돌)
  Port 2: request to Bank 31 → 대기 (충돌)
  
Cycle 2:
  Port 1: request to Bank 5  → Crossbar 선택 → 출력
  Port 2: request to Bank 31 → 대기 (충돌)
  
Cycle 3:
  Port 2: request to Bank 31 → Crossbar 선택 → 출력
```

**결과**: 3 cycles에 3 requests = **평균 1 req/cycle**

#### 비병합 모드의 병렬성

```systemverilog
// 4개 입력 → 32개 출력
VX_stream_xbar #(
    .NUM_INPUTS (4),
    .NUM_OUTPUTS(32),
    .ARBITER    ("R")
)
```

**시나리오**:
```
Cycle 1:
  Port 0: request to Bank 12 → m_axi_mem_12 출력
  Port 1: request to Bank 5  → m_axi_mem_5 출력
  Port 2: request to Bank 31 → m_axi_mem_31 출력
  Port 3: request to Bank 7  → m_axi_mem_7 출력
  
모두 병렬 실행! (출력 뱅크가 다름)
```

**결과**: 1 cycle에 4 requests = **4 req/cycle**

**충돌 조건**: 같은 뱅크를 동시에 요청할 때만
```
Port 0: request to Bank 5
Port 1: request to Bank 5  ← 충돌! Arbiter가 선택
```

---

## 5. Vivado/Vitis 합성 스크립트

### 5.1 Makefile 흐름

```makefile
# hw/syn/xilinx/xrt/Makefile

# 1. Generate sources list
gen-sources: $(BUILD_DIR)/sources.txt
	gen_sources.sh -P $(CFLAGS) -Osources.txt

# 2. Generate XO (Xilinx Object)
gen-xo: $(XO_CONTAINER)
	VIVADO -mode batch -source gen_xo.tcl -tclargs \
	    vortex_afu.xo vortex_afu sources.txt build/

# 3. Link to XCLBIN (Bitstream)
gen-bin: $(XCLBIN_CONTAINER)
	v++ $(VPP_FLAGS) -o vortex_afu.xclbin vortex_afu.xo
```

### 5.2 gen_xo.tcl (XO 생성)

```tcl
# gen_xo.tcl
set argv [list vortex_afu.xo vortex_afu sources.txt build/]
source package_kernel.tcl
package_xo -xo_path vortex_afu.xo \
           -kernel_name vortex_afu \
           -ip_directory build/xo/packaged_kernel
```

### 5.3 package_kernel.tcl

#### 파라미터 파싱

```tcl
# Define 파싱
set num_banks 1
set merged_mem_if 0

foreach def $vdefines_list {
    if { $name == "PLATFORM_MEMORY_NUM_BANKS" } {
        set num_banks [lindex $fields 1]
    }
    if { $name == "PLATFORM_MERGED_MEMORY_INTERFACE" } {
        set merged_mem_if 1
    }
}

# 병합 모드면 뱅크 수를 1로 강제
if { $merged_mem_if == 1 } {
    set num_banks 1
}
```

#### AXI 인터페이스 등록

```tcl
# Control interface
ipx::associate_bus_interfaces -busif s_axi_ctrl -clock ap_clk $core

# Memory interfaces (num_banks개)
for {set i 0} {$i < $num_banks} {incr i} {
    ipx::associate_bus_interfaces -busif m_axi_mem_$i -clock ap_clk $core
}
```

**병합 모드**: `m_axi_mem_0` 1개만 등록  
**비병합 모드**: `m_axi_mem_0` ~ `m_axi_mem_31` 32개 등록

#### Control Register Map

```tcl
set mem_map [::ipx::add_memory_map "s_axi_ctrl" $core]
set addr_block [::ipx::add_address_block "reg0" $mem_map]

# CTRL register (0x00)
set reg [::ipx::add_register "CTRL" $addr_block]
set_property address_offset 0x000 $reg

# MEM base address registers (0x30 + i*8)
for {set i 0} {$i < $num_banks} {incr i} {
    set reg [::ipx::add_register "MEM_$i" $addr_block]
    set_property address_offset [expr {0x30 + $i * 8}] $reg
    
    # AXI interface 연결
    set regparam [::ipx::add_register_parameter ASSOCIATED_BUSIF $reg]
    set_property value m_axi_mem_$i $regparam
}
```

### 5.4 v++ 링크 (VPP_FLAGS)

#### 병합 모드 (U55C)

```makefile
VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]
```

**의미**:
- Kernel `vortex_afu` 인스턴스 `vortex_afu_1`의
- AXI master 포트 `m_axi_mem_0`를
- Platform의 `HBM[0:31]` (32개 채널 모두)에 연결

**Vitis 동작**:
1. SmartConnect IP 자동 삽입
2. 1개 slave (m_axi_mem_0) → 32개 master (HBM[0:31])
3. Address decoding으로 채널 선택

#### 비병합 모드

```makefile
VPP_FLAGS += $(foreach i, $(shell seq 0 31), \
    --connectivity.sp vortex_afu_1.m_axi_mem_$(i):HBM[$(i)])
```

**확장**:
```makefile
--connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0]
--connectivity.sp vortex_afu_1.m_axi_mem_1:HBM[1]
...
--connectivity.sp vortex_afu_1.m_axi_mem_31:HBM[31]
```

**Vitis 동작**:
1. SmartConnect 없음
2. 각 포트를 해당 HBM 채널에 직접 연결
3. Wire로 직접 연결 (최소 latency)

### 5.5 Optimization Hooks

#### pre_opt_hook.tcl

```tcl
# Synthesis 전 최적화
# 예: Timing-critical path 제약 추가
set_property STRATEGY Flow_PerfOptimized_high [get_runs synth_1]
```

#### vitis.ini

```ini
[connectivity]
nk=vortex_afu:1  # Kernel 인스턴스 1개

[profile]
data=vortex_afu_1:all:all  # 프로파일링 활성화
```

---

## 6. 플랫폼별 설정

### 6.1 platforms.mk 분석

```makefile
# 공통 설정
CONFIGS += -DPLATFORM_MEMORY_DATA_WIDTH=512  # 모든 플랫폼 512-bit

# Alveo U55C (HBM)
ifneq ($(findstring xilinx_u55c,$(XSA)),)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32      # 32 banks
  CONFIGS += -DPLATFORM_MEMORY_ADDR_WIDTH=34     # 16GB = 2^34 bytes
  CONFIGS += -DPLATFORM_MERGED_MEMORY_INTERFACE  # 병합 모드
  VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]
endif

# Alveo U50 (HBM)
else ifneq ($(findstring xilinx_u50,$(XSA)),)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32
  CONFIGS += -DPLATFORM_MEMORY_ADDR_WIDTH=33     # 8GB = 2^33 bytes
  VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]
endif

# Alveo U280 (HBM)
else ifneq ($(findstring xilinx_u280,$(XSA)),)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32
  CONFIGS += -DPLATFORM_MEMORY_ADDR_WIDTH=33
  VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]
endif

# Alveo U250 (DDR4)
else ifneq ($(findstring xilinx_u250,$(XSA)),)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=4       # 4 DDR channels
  CONFIGS += -DPLATFORM_MEMORY_ADDR_WIDTH=36     # 64GB = 2^36 bytes
  # 병합 모드 없음 - 4개 포트 직접 연결
endif
```

### 6.2 플랫폼 비교표

| 플랫폼 | 메모리 타입 | 채널 수 | 용량/채널 | 총 용량 | 병합 모드 | 이론 BW |
|--------|-------------|---------|-----------|---------|-----------|---------|
| **U55C** | HBM2 | 32 | 512 MB | 16 GB | ✅ | 460 GB/s |
| **U50** | HBM2 | 32 | 256 MB | 8 GB | ✅ | 460 GB/s |
| **U280** | HBM2 | 32 | 256 MB | 8 GB | ✅ | 460 GB/s |
| **U250** | DDR4 | 4 | 16 GB | 64 GB | ❌ | 77 GB/s |
| **U200** | DDR4 | 4 | 16 GB | 64 GB | ❌ | 77 GB/s |

**의문점**: HBM 플랫폼은 모두 병합 모드 사용 → **왜?**

---

## 7. 성능 분석

### 7.1 병합 모드의 병목

#### Throughput 비교

| 설정 | Crossbar 출력 | Max Req/Cycle | 대역폭 @ 250MHz |
|------|---------------|---------------|-----------------|
| **병합 (1 port)** | 1 | 1 | 16 GB/s |
| **비병합 (32 ports)** | 32 | 32 | 512 GB/s |

#### Latency 분석

**병합 모드**:
```
Request → Crossbar Arbiter (1~N cycles 대기)
        → SmartConnect (2~3 cycles)
        → HBM Controller (50~100 cycles)
        
Total: 53~104+ cycles
```

**비병합 모드**:
```
Request → Crossbar Direct Route (0~1 cycle 대기, 다른 뱅크면 0)
        → HBM Controller (50~100 cycles)
        
Total: 50~101 cycles
```

**Latency 개선**: 약 3 cycles (미미)  
**Throughput 개선**: **32배** (엄청난 차이!)

### 7.2 실제 워크로드 영향

#### Memory-Intensive Kernel

```c
// GPU Kernel: 큰 배열 처리
for (int i = tid; i < N; i += nthreads) {
    C[i] = A[i] + B[i];  // 3 memory accesses
}
```

**병합 모드**:
- L1/L2 cache miss 발생 시
- 모든 request가 1개 포트로 직렬화
- **대역폭 포화**: 16 GB/s에서 막힘

**비병합 모드**:
- 32개 HBM 채널 병렬 접근
- **대역폭 활용**: ~512 GB/s 가능
- **32배 빠른 메모리 접근**

#### Cache-Friendly Kernel

```c
// 작은 working set, 높은 cache hit rate
for (int i = tid; i < N; i += nthreads) {
    sum += shared_data[i % 128];  // Cache에 상주
}
```

**병합 vs 비병합 차이**: 거의 없음
- Cache hit rate가 높으면 메모리 접근 빈도 낮음
- Crossbar 병목이 드러나지 않음

### 7.3 왜 병합 모드를 사용하는가?

**추정 이유**:

1. **Vitis 툴 제약**:
   - 32개 AXI master 포트 관리 복잡도
   - Routing 리소스 부족
   - Timing closure 어려움

2. **Shell 리소스 제약**:
   - Xilinx XRT shell이 32개 포트 미지원
   - SmartConnect가 이미 shell에 포함

3. **실험적/개발 편의성**:
   - 초기 개발 단계에서는 1개 포트가 간단
   - 성능 최적화는 추후 단계

**권장**:
- **메모리 대역폭이 중요한 애플리케이션**이면 **비병합 모드로 전환 필수**!
- platforms.mk에서 `PLATFORM_MERGED_MEMORY_INTERFACE` 주석 처리
- VPP_FLAGS를 32개 개별 연결로 수정

### 7.4 비병합 모드로 전환 방법

#### Step 1: platforms.mk 수정

```makefile
ifneq ($(findstring xilinx_u55c,$(XSA)),)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32
  CONFIGS += -DPLATFORM_MEMORY_ADDR_WIDTH=34
  # CONFIGS += -DPLATFORM_MERGED_MEMORY_INTERFACE  ← 주석 처리!
  # VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]  ← 주석 처리!
  VPP_FLAGS += $(foreach i,$(shell seq 0 31), \
      --connectivity.sp vortex_afu_1.m_axi_mem_$(i):HBM[$(i)])
endif
```

#### Step 2: 재컴파일

```bash
make clean
make all PLATFORM=xilinx_u55c_gen3x16_xdma_2_202110_1 TARGET=hw
```

#### Step 3: 성능 검증

```bash
# 대역폭 테스트
./bandwidth_test --kernel vortex_afu

# Before (병합): ~16 GB/s
# After (비병합): ~400~500 GB/s (실제 달성 가능)
```

---

## 8. 요약

### 핵심 포인트

1. **Vortex_axi.sv**:
   - Vortex core → AXI4 변환
   - VX_axi_adapter가 crossbar로 라우팅

2. **병합 모드**:
   - 1개 AXI master 포트
   - Vitis SmartConnect로 HBM 32채널 분배
   - **심각한 대역폭 제약**: 16 GB/s (32배 손실)

3. **비병합 모드**:
   - 32개 AXI master 포트
   - 직접 HBM 채널 매핑
   - **완전한 병렬성**: 512 GB/s 이론 대역폭

4. **Crossbar의 역할**:
   - `NUM_OUTPUTS=1`: 모든 request 직렬화 (병목)
   - `NUM_OUTPUTS=32`: 다른 뱅크면 병렬 실행

5. **성능 최적화**:
   - Memory-intensive 워크로드는 **반드시 비병합 모드**
   - platforms.mk 수정으로 간단히 전환 가능

### 다음 단계

- [ ] 비병합 모드로 전환 후 성능 측정
- [ ] Timing closure 확인 (32개 포트의 routing 복잡도)
- [ ] 실제 워크로드에서 대역폭 활용률 분석
- [ ] Cache 계층과 메모리 대역폭의 상호작용 연구

---

**참고 파일**:
- [Vortex_axi.sv](../../hw/rtl/Vortex_axi.sv)
- [VX_axi_adapter.sv](../../hw/rtl/libs/VX_axi_adapter.sv)
- [platforms.mk](../../hw/syn/xilinx/xrt/platforms.mk)
- [package_kernel.tcl](../../hw/syn/xilinx/xrt/package_kernel.tcl)
- [AFU_XRT_Architecture.md](AFU_XRT_Architecture.md)
