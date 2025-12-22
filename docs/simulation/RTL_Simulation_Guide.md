# Vortex RTL Simulation (rtlsim) Guide

## 목차
1. [개요](#1-개요)
2. [Verilator 기반 시뮬레이션 구조](#2-verilator-기반-시뮬레이션-구조)
3. [RTL Testbench (rtlsim_shim.sv)](#3-rtl-testbench-rtlsim_shimsv)
4. [C++ Processor 래퍼](#4-c-processor-래퍼)
5. [Runtime 통합](#5-runtime-통합)
6. [메모리 시뮬레이션](#6-메모리-시뮬레이션)
7. [빌드 및 실행 흐름](#7-빌드-및-실행-흐름)
8. [vortex_axi vs rtlsim](#8-vortex_axi-vs-rtlsim)
9. [디버깅 및 트레이싱](#9-디버깅-및-트레이싱)

---

## 1. 개요

**RTL 시뮬레이션(rtlsim)**은 Vortex GPGPU의 **실제 RTL 코드**를 **Verilator**로 컴파일하여 C++ 시뮬레이터로 실행하는 방식입니다. FPGA 합성 없이 RTL 동작을 검증할 수 있어 개발 및 디버깅에 핵심적입니다.

### 주요 특징

- **Cycle-accurate 시뮬레이션**: RTL과 동일한 클럭 사이클 단위 동작
- **Fast simulation**: Verilator는 컴파일 기반으로 ISS보다 빠름
- **VCD 파일 생성**: 파형 덤프로 상세 디버깅 가능
- **소프트웨어 통합**: 표준 Vortex runtime API 사용

### 계층 구조

```
┌─────────────────────────────────────────────────────────┐
│                  Application (C/OpenCL)                 │
└────────────────────┬────────────────────────────────────┘
                     │ vx_* API calls
┌────────────────────┴────────────────────────────────────┐
│         libvortex-rtlsim.so (Runtime)                   │
│  - vortex.cpp: vx_device 구현                           │
│  - RAM, MemoryAllocator 관리                            │
└────────────────────┬────────────────────────────────────┘
                     │ Processor class
┌────────────────────┴────────────────────────────────────┐
│         librtlsim.so (Simulator Library)                │
│  - processor.cpp: Processor::Impl                       │
│  - Vrtlsim_shim wrapper                                 │
│  - DRAM 시뮬레이션 (ramulator)                          │
└────────────────────┬────────────────────────────────────┘
                     │ Verilated C++ model
┌────────────────────┴────────────────────────────────────┐
│         Vrtlsim_shim (Verilator Generated)              │
│  - rtlsim_shim.sv 컴파일 결과                           │
│  - Cycle-by-cycle RTL simulation                        │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────┴────────────────────────────────────┐
│              Vortex RTL Core                            │
│  - VX_cluster, VX_socket, VX_core                       │
│  - Cache hierarchy, Execute units                       │
│  - **vortex_axi/vortex_afu 미사용**                     │
└─────────────────────────────────────────────────────────┘
```

---

## 2. Verilator 기반 시뮬레이션 구조

### 2.1 Verilator란?

**Verilator**는 Verilog/SystemVerilog RTL을 **C++ 또는 SystemC 모델**로 변환하는 오픈소스 도구입니다.

#### 동작 원리

```
RTL Source (.sv, .v)
    ↓ Verilator
C++ Model (Vmodule.cpp, Vmodule.h)
    ↓ g++
Executable/Shared Library
    ↓
Cycle-accurate Simulation
```

#### Verilator vs Verilog Simulator 비교

| 특징 | Verilator | VCS/ModelSim |
|------|-----------|--------------|
| **방식** | Compile-based | Event-driven |
| **속도** | 매우 빠름 (10-100x) | 느림 |
| **정확도** | Cycle-accurate | Event-accurate |
| **지원 기능** | Synthesizable RTL | Full Verilog (delay, $random 등) |
| **주 용도** | Performance simulation | Full verification |

### 2.2 Verilator 컴파일 과정

#### Makefile (sim/rtlsim/Makefile)

```makefile
# Top module
TOP = rtlsim_shim

# Verilator flags
VL_FLAGS = --exe
VL_FLAGS += --language 1800-2009 --assert -Wall -Wpedantic
VL_FLAGS += -Wno-DECLFILENAME -Wno-REDEFMAC지RO
VL_FLAGS += --x-initial unique --x-assign unique
VL_FLAGS += verilator.vlt  # Lint config
VL_FLAGS += -DSIMULATION -DSV_DPI
VL_FLAGS += -DXLEN_$(XLEN)
VL_FLAGS += $(CONFIGS)
VL_FLAGS += $(RTL_INCLUDE)  # -I 경로들
VL_FLAGS += $(RTL_PKGS)     # 패키지 파일들
VL_FLAGS += --cc $(TOP) --top-module $(TOP)

# C++ sources to link
SRCS = processor.cpp util_dpi.cpp float_dpi.cpp mem.cpp dram_sim.cpp ...

# Build executable
$(DESTDIR)/rtlsim: $(SRCS) main.cpp $(RTL_SRCS)
	verilator --build $(VL_FLAGS) $(SRCS) main.cpp \
	    -CFLAGS '$(CXXFLAGS)' -LDFLAGS '$(LDFLAGS)' \
	    --MMD --Mdir $@.obj_dir -o $@

# Build shared library (runtime용)
$(DESTDIR)/librtlsim.so: $(SRCS) $(RTL_SRCS)
	verilator --build $(VL_FLAGS) $(SRCS) \
	    -CFLAGS '$(CXXFLAGS)' -LDFLAGS '-shared $(LDFLAGS)' \
	    --MMD --Mdir $@.obj_dir -o $@
```

**핵심 옵션**:
- `--exe`: Executable 생성 (standalone simulator)
- `--cc`: C++ 모델 생성
- `--top-module rtlsim_shim`: 시뮬레이션 최상위 모듈
- `-DSIMULATION -DSV_DPI`: RTL 컴파일 define
- `--build`: Verilator + g++ 통합 빌드

#### RTL Include Paths

```makefile
RTL_INCLUDE = -I$(SRC_DIR) -I$(RTL_DIR) -I$(DPI_DIR) \
              -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces \
              -I$(RTL_DIR)/core -I$(RTL_DIR)/mem \
              -I$(RTL_DIR)/cache $(FPU_INCLUDE)

# FPU 확장
FPU_INCLUDE = -I$(RTL_DIR)/fpu
ifneq (,$(findstring -DFPU_FPNEW, $(CONFIGS)))
    RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_pkg.sv ...
    FPU_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/...
endif

# Vector 확장
ifneq (,$(findstring -DEXT_V_ENABLE, $(CONFIGS)))
    RTL_PKGS += $(RTL_DIR)/vpu/VX_vpu_pkg.sv
    RTL_INCLUDE += -I$(RTL_DIR)/vpu
endif
```

#### 생성되는 파일

```
build/rtlsim.obj_dir/
├── Vrtlsim_shim.cpp         # Main module implementation
├── Vrtlsim_shim.h           # Module header
├── Vrtlsim_shim__Syms.cpp   # Symbol table
├── Vrtlsim_shim__Trace.cpp  # VCD tracing (DEBUG 시)
├── verilated.cpp            # Verilator runtime
├── verilated_dpi.cpp        # DPI support
└── verilated_vcd_c.cpp      # VCD output (DEBUG 시)
```

### 2.3 Verilator Lint Configuration (verilator.vlt)

```verilog
// verilator.vlt.in
lint_off -rule UNUSED
lint_off -rule UNDRIVEN
lint_off -rule DECLFILENAME
...
```

**목적**: RTL 코드의 불필요한 경고 억제 (예: unused signal은 디버그용)

---

## 3. RTL Testbench (rtlsim_shim.sv)

### 3.1 역할

**rtlsim_shim.sv**는 **Vortex 코어**와 **C++ 시뮬레이터** 사이의 **인터페이스 래퍼**입니다.

```
┌──────────────────────────────────────────────┐
│            rtlsim_shim.sv                    │
│  ┌────────────────────────────────────────┐  │
│  │        Vortex (GPU Core)               │  │
│  │  - L1/L2/L3 Cache                      │  │
│  │  - Cores, Clusters                     │  │
│  │  - Execute units                       │  │
│  └──────────┬─────────────────────────────┘  │
│             │ VX_MEM_PORTS (4~8개)           │
│             ↓                                │
│  ┌──────────────────────────────────────┐   │
│  │   VX_mem_data_adapter                │   │
│  │   (Width conversion)                 │   │
│  └──────────┬───────────────────────────┘   │
│             │                                │
│             ↓                                │
│  ┌──────────────────────────────────────┐   │
│  │   VX_mem_bank_adapter                │   │
│  │   (Crossbar to memory banks)         │   │
│  └──────────┬───────────────────────────┘   │
│             │ MEM_NUM_BANKS (1~32개)        │
│             ↓                                │
│  mem_req/rsp [MEM_NUM_BANKS]                │
└──────────────┬───────────────────────────────┘
               │ C++ Processor::Impl에서 처리
               ↓
        DRAM Simulator (ramulator)
```

### 3.2 모듈 정의

```systemverilog
module rtlsim_shim import VX_gpu_pkg::*; #(
    parameter MEM_DATA_WIDTH = (`PLATFORM_MEMORY_DATA_SIZE * 8),  // 512-bit
    parameter MEM_ADDR_WIDTH = `PLATFORM_MEMORY_ADDR_WIDTH - $clog2(`PLATFORM_MEMORY_NUM_BANKS),
    parameter MEM_NUM_BANKS  = `PLATFORM_MEMORY_NUM_BANKS,  // 1~32
    parameter MEM_TAG_WIDTH  = 64  // Tag for request tracking
) (
    // Clock & Reset
    input  wire clk,
    input  wire reset,

    // Memory Request (to C++)
    output wire                             mem_req_valid [MEM_NUM_BANKS],
    output wire                             mem_req_rw [MEM_NUM_BANKS],
    output wire [(MEM_DATA_WIDTH/8)-1:0]    mem_req_byteen [MEM_NUM_BANKS],
    output wire [MEM_ADDR_WIDTH-1:0]        mem_req_addr [MEM_NUM_BANKS],
    output wire [MEM_DATA_WIDTH-1:0]        mem_req_data [MEM_NUM_BANKS],
    output wire [MEM_TAG_WIDTH-1:0]         mem_req_tag [MEM_NUM_BANKS],
    input  wire                             mem_req_ready [MEM_NUM_BANKS],

    // Memory Response (from C++)
    input wire                              mem_rsp_valid [MEM_NUM_BANKS],
    input wire [MEM_DATA_WIDTH-1:0]         mem_rsp_data [MEM_NUM_BANKS],
    input wire [MEM_TAG_WIDTH-1:0]          mem_rsp_tag [MEM_NUM_BANKS],
    output wire                             mem_rsp_ready [MEM_NUM_BANKS],

    // DCR (Device Configuration Registers)
    input  wire                             dcr_wr_valid,
    input  wire [VX_DCR_ADDR_WIDTH-1:0]     dcr_wr_addr,
    input  wire [VX_DCR_DATA_WIDTH-1:0]     dcr_wr_data,

    // Status
    output wire                             busy
);
```

### 3.3 내부 구조

#### Stage 1: Vortex Core 인스턴스

```systemverilog
Vortex vortex (
    .clk            (clk),
    .reset          (reset),
    
    // Vortex 내부 메모리 인터페이스 (VX_MEM_PORTS개)
    .mem_req_valid  (vx_mem_req_valid),   // [VX_MEM_PORTS-1:0]
    .mem_req_rw     (vx_mem_req_rw),
    .mem_req_byteen (vx_mem_req_byteen),
    .mem_req_addr   (vx_mem_req_addr),
    .mem_req_data   (vx_mem_req_data),
    .mem_req_tag    (vx_mem_req_tag),
    .mem_req_ready  (vx_mem_req_ready),
    
    .mem_rsp_valid  (vx_mem_rsp_valid),
    .mem_rsp_data   (vx_mem_rsp_data),
    .mem_rsp_tag    (vx_mem_rsp_tag),
    .mem_rsp_ready  (vx_mem_rsp_ready),
    
    .dcr_wr_valid   (dcr_wr_valid),
    .dcr_wr_addr    (dcr_wr_addr),
    .dcr_wr_data    (dcr_wr_data),
    
    .busy           (busy)
);
```

**VX_MEM_PORTS**:
- L3 활성화 시: `L3_MEM_PORTS` (일반적으로 L3 banks 수)
- L3 비활성화 시: `L2_MEM_PORTS` (L2 banks 수)
- 일반적인 값: **4 또는 8**

#### Stage 2: Data Width Adapter

```systemverilog
// Vortex 내부 데이터 폭 → 외부 메모리 폭 변환
for (genvar i = 0; i < VX_MEM_PORTS; i++) begin
    VX_mem_data_adapter #(
        .SRC_DATA_WIDTH (VX_MEM_DATA_WIDTH),     // 32 or 64-bit
        .DST_DATA_WIDTH (MEM_DATA_WIDTH),        // 512-bit (일반적)
        .SRC_ADDR_WIDTH (VX_MEM_ADDR_WIDTH),
        .DST_ADDR_WIDTH (VX_MEM_ADDR_A_WIDTH),
        .SRC_TAG_WIDTH  (VX_MEM_TAG_WIDTH),
        .DST_TAG_WIDTH  (VX_MEM_TAG_A_WIDTH),
        ...
    ) mem_data_adapter (
        .mem_req_valid_in   (vx_mem_req_valid[i]),
        .mem_req_data_in    (vx_mem_req_data[i]),   // VX_MEM_DATA_WIDTH
        .mem_req_data_out   (mem_req_data_a[i]),    // MEM_DATA_WIDTH
        ...
    );
end
```

**역할**:
- 32/64-bit Vortex 요청 → 512-bit 메모리 인터페이스
- Address 재계산 (word → byte addressable)
- Tag 확장

#### Stage 3: Bank Adapter (Crossbar)

```systemverilog
VX_mem_bank_adapter #(
    .NUM_PORTS_IN   (VX_MEM_PORTS),      // 4~8
    .NUM_BANKS_OUT  (MEM_NUM_BANKS),     // 1~32
    .INTERLEAVE     (`PLATFORM_MEMORY_INTERLEAVE),
    ...
) mem_bank_adapter (
    .mem_req_valid_in   (mem_req_valid_a),   // [VX_MEM_PORTS-1:0]
    .mem_req_valid_out  (mem_req_valid),     // [MEM_NUM_BANKS-1:0]
    ...
);
```

**역할**: **Vortex_axi.sv의 VX_axi_adapter와 동일**
- N개 입력 포트 → M개 메모리 뱅크
- Address interleaving 또는 block allocation
- Crossbar로 request 라우팅

### 3.4 Memory Interface

**C++에서 접근하는 방식**:

```cpp
// Processor::Impl::tick() - processor.cpp
device_->clk = 0;
device_->eval();  // Combinational logic 평가

device_->clk = 1;
device_->eval();  // Rising edge

// Memory request 확인
for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
    if (device_->mem_req_valid[b] && device_->mem_req_ready[b]) {
        // Request 처리
        uint64_t addr = device_->mem_req_addr[b];
        bool is_write = device_->mem_req_rw[b];
        
        if (is_write) {
            auto data = device_->mem_req_data[b];
            auto byteen = device_->mem_req_byteen[b];
            // RAM 쓰기
            for (int i = 0; i < PLATFORM_MEMORY_DATA_SIZE; i++) {
                if ((byteen >> i) & 0x1) {
                    (*ram_)[addr + i] = data[i];
                }
            }
        } else {
            // RAM 읽기
            ram_->read(mem_req->data, addr, PLATFORM_MEMORY_DATA_SIZE);
        }
        
        // DRAM queue에 추가 (latency 시뮬레이션)
        dram_queue_[b].push(mem_req);
    }
}

// Memory response 생성 (DRAM latency 후)
if (!pending_mem_reqs_[b].empty() && mem_req->ready) {
    device_->mem_rsp_valid[b] = 1;
    device_->mem_rsp_data[b] = mem_req->data;
    device_->mem_rsp_tag[b] = mem_req->tag;
}
```

---

## 4. C++ Processor 래퍼

### 4.1 Processor Class (processor.h/cpp)

```cpp
class Processor {
public:
    Processor();
    ~Processor();
    
    void attach_ram(RAM* ram);
    void run();
    void dcr_write(uint32_t addr, uint32_t value);
    
private:
    class Impl;
    Impl* impl_;
};
```

**PIMPL 패턴**: 구현 세부사항 숨김 (Verilator 헤더 노출 방지)

### 4.2 Processor::Impl

```cpp
class Processor::Impl {
public:
    Impl() : dram_sim_(PLATFORM_MEMORY_NUM_BANKS, 
                       PLATFORM_MEMORY_DATA_SIZE, 
                       MEM_CLOCK_RATIO) {
        // Verilator 초기화
        Verilated::randReset(VERILATOR_RESET_VALUE);
        Verilated::randSeed(50);
        Verilated::assertOn(false);  // Reset 전엔 끄기
        
        // RTL 모듈 생성
        device_ = new Vrtlsim_shim();
        
    #ifdef VCD_OUTPUT
        Verilated::traceEverOn(true);
        tfp_ = new VerilatedVcdC();
        device_->trace(tfp_, 99);  // Trace depth
        tfp_->open("trace.vcd");
    #endif
        
        ram_ = nullptr;
        this->reset();
        Verilated::assertOn(true);  // Reset 후 assertion 활성화
    }
    
    ~Impl() {
        #ifdef VCD_OUTPUT
        tfp_->close();
        delete tfp_;
        #endif
        delete device_;
    }
    
    void run() {
        // Reset
        this->reset();
        
        // Start
        device_->reset = 0;
        for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
            device_->mem_req_ready[b] = 1;
        }
        
        // Wait for GPU to go busy
        while (!device_->busy) {
            this->tick();
        }
        
        // Wait for GPU to go idle
        while (device_->busy) {
            this->tick();
        }
        
        // Stop
        device_->reset = 1;
    }
    
    void dcr_write(uint32_t addr, uint32_t value) {
        device_->dcr_wr_valid = 1;
        device_->dcr_wr_addr  = addr;
        device_->dcr_wr_data  = value;
        this->tick();
        device_->dcr_wr_valid = 0;
        this->tick();
    }
    
private:
    void tick() {
        // Negative edge
        device_->clk = 0;
        device_->eval();
        
        // Memory request handling
        this->mem_bus_eval();
        
        // DRAM simulation
        dram_sim_.tick();
        
        // Positive edge
        device_->clk = 1;
        device_->eval();
        
        #ifdef VCD_OUTPUT
        if (sim_trace_enabled()) {
            tfp_->dump(timestamp);
        }
        #endif
        
        ++timestamp;
    }
    
    void mem_bus_eval() {
        // Process memory requests
        for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
            if (device_->mem_req_valid[b] && device_->mem_req_ready[b]) {
                uint64_t byte_addr = device_->mem_req_addr[b] * PLATFORM_MEMORY_DATA_SIZE;
                
                if (device_->mem_req_rw[b]) {
                    // Write
                    auto byteen = device_->mem_req_byteen[b];
                    auto data = device_->mem_req_data[b];
                    
                    // Check console output address
                    if (byte_addr >= IO_COUT_ADDR && 
                        byte_addr < IO_COUT_ADDR + IO_COUT_SIZE) {
                        // Process console output
                        for (int i = 0; i < PLATFORM_MEMORY_DATA_SIZE; i++) {
                            if ((byteen >> i) & 0x1) {
                                auto& ss_buf = print_bufs_[i];
                                char c = data[i];
                                ss_buf << c;
                                if (c == '\n') {
                                    std::cout << "#" << i << ": " << ss_buf.str();
                                    ss_buf.str("");
                                }
                            }
                        }
                    } else {
                        // Normal memory write
                        for (int i = 0; i < PLATFORM_MEMORY_DATA_SIZE; i++) {
                            if ((byteen >> i) & 0x1) {
                                (*ram_)[byte_addr + i] = data[i];
                            }
                        }
                    }
                } else {
                    // Read
                    ram_->read(mem_req->data, byte_addr, PLATFORM_MEMORY_DATA_SIZE);
                }
                
                // Enqueue to DRAM simulator
                dram_queue_[b].push(mem_req);
                pending_mem_reqs_[b].emplace_back(mem_req);
            }
        }
        
        // Process DRAM responses
        for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
            while (!dram_queue_[b].empty()) {
                auto mem_req = dram_queue_[b].front();
                if (dram_sim_.send_request(b, mem_req->addr, mem_req->write, 
                                           [mem_req](bool ready) {
                                               mem_req->ready = ready;
                                           })) {
                    dram_queue_[b].pop();
                } else {
                    break;  // DRAM queue full
                }
            }
        }
        
        // Generate memory responses
        for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
            if (!pending_mem_reqs_[b].empty()) {
                auto mem_req = pending_mem_reqs_[b].front();
                if (mem_req->ready && mem_rd_rsp_ready_[b]) {
                    device_->mem_rsp_valid[b] = 1;
                    device_->mem_rsp_data[b] = mem_req->data;
                    device_->mem_rsp_tag[b] = mem_req->tag;
                    
                    if (device_->mem_rsp_ready[b]) {
                        pending_mem_reqs_[b].pop_front();
                        delete mem_req;
                        mem_rd_rsp_ready_[b] = false;
                    }
                }
            } else {
                device_->mem_rsp_valid[b] = 0;
                mem_rd_rsp_ready_[b] = true;
            }
        }
    }
    
    Vrtlsim_shim* device_;  // Verilated model
    RAM* ram_;
    DramSim dram_sim_;
    
    std::queue<mem_req_t*> dram_queue_[PLATFORM_MEMORY_NUM_BANKS];
    std::list<mem_req_t*> pending_mem_reqs_[PLATFORM_MEMORY_NUM_BANKS];
    
    #ifdef VCD_OUTPUT
    VerilatedVcdC* tfp_;
    #endif
};
```

### 4.3 Console Output 처리

**특별한 메모리 주소 범위**:
```cpp
// VX_config.vh
#define IO_COUT_ADDR   0x7FFFF000
#define IO_COUT_SIZE   4096

// processor.cpp
if (byte_addr >= IO_COUT_ADDR && byte_addr < IO_COUT_ADDR + IO_COUT_SIZE) {
    // GPU의 printf 출력을 호스트 stdout으로 리다이렉트
    for (int i = 0; i < PLATFORM_MEMORY_DATA_SIZE; i++) {
        if ((byteen >> i) & 0x1) {
            char c = data[i];
            std::cout << c;
        }
    }
}
```

---

## 5. Runtime 통합

### 5.1 빌드 구조

```makefile
# runtime/rtlsim/Makefile

# 1. librtlsim.so 먼저 빌드 (simulator library)
$(DESTDIR)/librtlsim.so: force
	DESTDIR=$(DESTDIR) $(MAKE) -C $(ROOT_DIR)/sim/rtlsim librtlsim.so

# 2. libvortex-rtlsim.so 빌드 (runtime library)
$(DESTDIR)/libvortex-rtlsim.so: vortex.cpp librtlsim.so
	$(CXX) $(CXXFLAGS) vortex.cpp \
	    -L$(DESTDIR) -lrtlsim \
	    -shared -pthread -o $@
```

**의존성**:
```
libvortex-rtlsim.so (Runtime)
    ↓ 링크
librtlsim.so (Verilated simulator)
    ↓ 링크
Vrtlsim_shim (Verilator generated)
```

### 5.2 vx_device 클래스 (vortex.cpp)

```cpp
class vx_device {
public:
    vx_device()
        : ram_(0, RAM_PAGE_SIZE)
        , global_mem_(ALLOC_BASE_ADDR, 
                      GLOBAL_MEM_SIZE - ALLOC_BASE_ADDR,
                      RAM_PAGE_SIZE, CACHE_BLOCK_SIZE)
    {
        processor_.attach_ram(&ram_);
    }
    
    int mem_alloc(uint64_t size, int flags, uint64_t* dev_addr) {
        uint64_t addr;
        global_mem_.allocate(size, &addr);
        *dev_addr = addr;
        return 0;
    }
    
    int upload(const void* src, uint64_t dest_addr, uint64_t size) {
        ram_.enable_acl(false);  // Disable access control
        ram_.write((const uint8_t*)src, dest_addr, size);
        ram_.enable_acl(true);
        return 0;
    }
    
    int download(void* dest, uint64_t src_addr, uint64_t size) {
        ram_.enable_acl(false);
        ram_.read((uint8_t*)dest, src_addr, size);
        ram_.enable_acl(true);
        return 0;
    }
    
    int start(uint64_t krnl_addr, uint64_t args_addr) {
        // Ensure prior run completed
        if (future_.valid()) {
            future_.wait();
        }
        
        // Set kernel info via DCR
        dcr_write(VX_DCR_BASE_STARTUP_ADDR0, krnl_addr & 0xffffffff);
        dcr_write(VX_DCR_BASE_STARTUP_ADDR1, krnl_addr >> 32);
        dcr_write(VX_DCR_BASE_STARTUP_ARG0, args_addr & 0xffffffff);
        dcr_write(VX_DCR_BASE_STARTUP_ARG1, args_addr >> 32);
        
        // Start new run in async thread
        future_ = std::async(std::launch::async, [&]{
            processor_.run();
        });
        
        return 0;
    }
    
    int ready_wait(uint64_t timeout) {
        if (!future_.valid())
            return 0;
        
        auto status = future_.wait_for(std::chrono::seconds(timeout/1000));
        if (status == std::future_status::ready)
            return 0;
        return -1;  // Timeout
    }
    
private:
    RAM                 ram_;
    Processor           processor_;
    MemoryAllocator     global_mem_;
    std::future<void>   future_;  // Async execution
};
```

### 5.3 Runtime API 구현 (callbacks.inc)

```cpp
// callbacks.inc (auto-included)
extern "C" {

int vx_dev_open(vx_device_h* hdevice) {
    *hdevice = new vx_device();
    return (*hdevice)->init();
}

int vx_dev_close(vx_device_h hdevice) {
    delete hdevice;
    return 0;
}

int vx_mem_alloc(vx_device_h hdevice, uint64_t size, int flags, vx_buffer_h* hbuffer) {
    uint64_t dev_addr;
    int err = hdevice->mem_alloc(size, flags, &dev_addr);
    *hbuffer = new vx_buffer(dev_addr, size, flags);
    return err;
}

int vx_copy_to_dev(vx_buffer_h hbuffer, const void* host_ptr, uint64_t dst_offset, uint64_t size) {
    return hbuffer->device->upload(host_ptr, hbuffer->addr + dst_offset, size);
}

int vx_copy_from_dev(void* host_ptr, vx_buffer_h hbuffer, uint64_t src_offset, uint64_t size) {
    return hbuffer->device->download(host_ptr, hbuffer->addr + src_offset, size);
}

int vx_start(vx_device_h hdevice, vx_buffer_h hkernel, vx_buffer_h harguments) {
    return hdevice->start(hkernel->addr, harguments->addr);
}

int vx_ready_wait(vx_device_h hdevice, uint64_t timeout) {
    return hdevice->ready_wait(timeout);
}

} // extern "C"
```

### 5.4 Application 실행 예시

```c
// test.c
#include <vortex.h>

int main() {
    vx_device_h device;
    vx_buffer_h staging_buf, kernel_buf, args_buf;
    
    // 1. Device 열기
    vx_dev_open(&device);
    
    // 2. Kernel & arguments 로드
    vx_mem_alloc(device, kernel_size, 0, &kernel_buf);
    vx_copy_to_dev(kernel_buf, kernel_data, 0, kernel_size);
    
    vx_mem_alloc(device, args_size, 0, &args_buf);
    vx_copy_to_dev(args_buf, &args, 0, args_size);
    
    // 3. Kernel 시작 (비동기)
    vx_start(device, kernel_buf, args_buf);
    
    // 4. 완료 대기
    vx_ready_wait(device, -1);  // Infinite timeout
    
    // 5. 결과 복사
    vx_copy_from_dev(result, result_buf, 0, result_size);
    
    // 6. 정리
    vx_buf_free(kernel_buf);
    vx_dev_close(device);
}
```

**내부 흐름**:
```
vx_start()
    ↓
vx_device::start()
    ↓
std::async([&]{ processor_.run(); })
    ↓
Processor::Impl::run()
    ↓
while (device_->busy) { tick(); }
    ↓
Verilator eval() + mem_bus_eval()
    ↓
RTL cycle simulation
```

---

## 6. 메모리 시뮬레이션

### 6.1 RAM 클래스 (mem.cpp)

```cpp
class RAM {
public:
    RAM(uint64_t base_addr, uint32_t page_size)
        : base_addr_(base_addr)
        , page_size_(page_size)
        , acl_enabled_(true)
    {}
    
    void write(const uint8_t* data, uint64_t addr, uint64_t size) {
        if (acl_enabled_ && !is_accessible(addr, size)) {
            throw std::runtime_error("Access violation");
        }
        
        for (uint64_t i = 0; i < size; ++i) {
            uint64_t page = (addr + i) / page_size_;
            uint64_t offset = (addr + i) % page_size_;
            
            if (pages_.find(page) == pages_.end()) {
                pages_[page] = new uint8_t[page_size_];
                memset(pages_[page], 0, page_size_);
            }
            
            pages_[page][offset] = data[i];
        }
    }
    
    void read(uint8_t* data, uint64_t addr, uint64_t size) {
        for (uint64_t i = 0; i < size; ++i) {
            uint64_t page = (addr + i) / page_size_;
            uint64_t offset = (addr + i) % page_size_;
            
            if (pages_.find(page) != pages_.end()) {
                data[i] = pages_[page][offset];
            } else {
                data[i] = 0;  // Uninitialized memory
            }
        }
    }
    
    uint8_t& operator[](uint64_t addr) {
        // Direct access for simulation
        uint64_t page = addr / page_size_;
        uint64_t offset = addr % page_size_;
        
        if (pages_.find(page) == pages_.end()) {
            pages_[page] = new uint8_t[page_size_];
            memset(pages_[page], 0, page_size_);
        }
        
        return pages_[page][offset];
    }
    
private:
    std::unordered_map<uint64_t, uint8_t*> pages_;
    uint64_t base_addr_;
    uint32_t page_size_;
    bool acl_enabled_;
};
```

**Page-based 메모리**: 효율적인 sparse 메모리 시뮬레이션

### 6.2 DRAM Simulator (ramulator)

```cpp
class DramSim {
public:
    DramSim(uint32_t num_banks, uint32_t bus_width, uint32_t clock_ratio)
        : num_banks_(num_banks)
        , bus_width_(bus_width)
        , clock_ratio_(clock_ratio)
    {
        // Ramulator 초기화
        // ...
    }
    
    void tick() {
        if (++clock_ctr_ < clock_ratio_)
            return;
        clock_ctr_ = 0;
        
        // Ramulator tick
        ramulator_->tick();
    }
    
    bool send_request(uint32_t bank_id, uint64_t addr, bool write,
                      std::function<void(bool)> callback) {
        Request req(addr, write ? Request::Type::WRITE : Request::Type::READ,
                    [callback](Request& req) {
                        callback(true);  // Ready
                    });
        
        return ramulator_->send(req);
    }
    
private:
    Ramulator::Ramulator* ramulator_;
    uint32_t num_banks_;
    uint32_t clock_ratio_;  // GPU clk / DRAM clk
    uint32_t clock_ctr_;
};
```

**역할**: Realistic DRAM latency/bandwidth 시뮬레이션

---

## 7. 빌드 및 실행 흐름

### 7.1 전체 빌드 과정

```bash
# 1. RTL simulator 빌드
cd sim/rtlsim
make CONFIGS="-DNUM_CORES=4 -DL2_ENABLE"

# 생성물:
# - build/rtlsim (standalone executable)
# - build/librtlsim.so (shared library)

# 2. Runtime library 빌드
cd runtime/rtlsim
make

# 생성물:
# - build/libvortex-rtlsim.so

# 3. Application 빌드
cd tests/regression/vecadd
make

# 4. 실행
VORTEX_RT_PATH=../../../build make run-rtlsim
```

### 7.2 Standalone Execution (sim/rtlsim/main.cpp)

```cpp
int main(int argc, char **argv) {
    parse_args(argc, argv);  // program = "kernel.bin"
    
    // Create memory
    vortex::RAM ram(0, RAM_PAGE_SIZE);
    
    // Create processor
    vortex::Processor processor;
    processor.attach_ram(&ram);
    
    // Setup DCRs
    processor.dcr_write(VX_DCR_BASE_STARTUP_ADDR0, STARTUP_ADDR & 0xffffffff);
    processor.dcr_write(VX_DCR_BASE_STARTUP_ADDR1, STARTUP_ADDR >> 32);
    
    // Load program
    if (program_ext == "bin") {
        ram.loadBinImage(program, STARTUP_ADDR);
    } else if (program_ext == "hex") {
        ram.loadHexImage(program);
    }
    
    // Run simulation
    processor.run();
    
    // Read exitcode from MPM memory
    int exitcode;
    ram.read(&exitcode, IO_MPM_ADDR + 8, 4);
    
    return exitcode;
}
```

**실행**:
```bash
./rtlsim kernel.bin
# VCD 파일 생성: trace.vcd (DEBUG 빌드 시)
```

### 7.3 Runtime Execution

```bash
# Application에서
./vecadd

# 내부적으로:
# 1. dlopen("libvortex-rtlsim.so")
# 2. vx_dev_open() → new vx_device()
# 3. vx_mem_alloc(), vx_copy_to_dev()
# 4. vx_start() → std::async { processor_.run(); }
# 5. vx_ready_wait() → future_.wait()
# 6. vx_copy_from_dev()
```

### 7.4 BlackBox Test (ci/blackbox.sh)

```bash
# 자동화된 테스트
./blackbox.sh --driver=rtlsim --app=sgemm --cores=4 --l2cache --debug=3

# 내부 동작:
# 1. build_driver(): make -C runtime/rtlsim CONFIGS="-DNUM_CORES=4 -DL2_ENABLE"
# 2. run_app(): make -C tests/regression/sgemm run-rtlsim DEBUG=3
# 3. 결과 검증
```

---

## 8. vortex_axi vs rtlsim

### 8.1 핵심 차이

| 항목 | **rtlsim** | **vortex_axi / vortex_afu** |
|------|------------|----------------------------|
| **Top Module** | `Vortex` (bare core) | `Vortex_axi` → `VX_afu_wrap` |
| **Memory Interface** | Custom (mem_req/rsp arrays) | AXI4 protocol |
| **Crossbar** | `VX_mem_bank_adapter` | `VX_axi_adapter` |
| **용도** | **Verilator 시뮬레이션** | **FPGA 합성 (XRT/OPAE)** |
| **Wrapper 계층** | rtlsim_shim.sv | vortex_afu.v + VX_afu_wrap.sv |
| **Control** | DCR direct write | AXI4-Lite control interface |
| **Status** | `busy` signal | ap_start/done handshake |

### 8.2 RTL 계층 비교

#### RTLsim 구조

```
rtlsim_shim.sv
    ├── Vortex (RTL Core)
    │   ├── VX_cluster
    │   ├── VX_socket
    │   └── VX_core
    ├── VX_mem_data_adapter (N개)
    └── VX_mem_bank_adapter (Crossbar)
        └── mem_req/rsp [MEM_NUM_BANKS]
            ↓
        C++ Processor::Impl
```

#### FPGA (XRT) 구조

```
vortex_afu.v
    └── VX_afu_wrap.sv
        ├── VX_afu_ctrl.sv (AXI4-Lite Slave)
        └── Vortex_axi.sv
            ├── Vortex (RTL Core)
            ├── VX_mem_data_adapter (N개)
            └── VX_axi_adapter (Crossbar)
                └── m_axi_* [AXI_NUM_BANKS]
                    ↓
                HBM/DDR Controller
```

### 8.3 rtlsim이 vortex_axi를 사용하지 않는 이유

**1. 불필요한 복잡성**:
- AXI4 프로토콜 오버헤드 불필요 (시뮬레이션에선 직접 메모리 접근)
- AFU control 계층 불필요 (C++에서 직접 DCR 쓰기)

**2. 시뮬레이션 효율**:
- Custom interface가 더 간단하고 빠름
- C++에서 직접 메모리 배열 접근 가능

**3. 디버깅 편의성**:
- AXI4 handshake 없이 직접 request/response 확인
- Console output 같은 특수 기능 쉽게 추가

**하지만 Crossbar 로직은 동일**:
- `VX_mem_bank_adapter` ≈ `VX_axi_adapter`
- 동일한 address interleaving, bank selection
- **RTL 검증 목적으로는 충분**

### 8.4 공통 RTL 코드

**둘 다 사용하는 모듈**:
```
hw/rtl/
├── Vortex.sv               # ✅ 공통 (Core)
├── VX_cluster.sv           # ✅ 공통
├── VX_socket.sv            # ✅ 공통
├── VX_core.sv              # ✅ 공통
├── cache/                  # ✅ 공통
├── mem/                    # ✅ 공통
├── libs/
│   ├── VX_mem_data_adapter.sv   # ✅ 공통
│   ├── VX_mem_bank_adapter.sv   # rtlsim 전용
│   └── VX_axi_adapter.sv        # FPGA 전용
├── afu/xrt/
│   ├── vortex_afu.v        # ❌ FPGA 전용
│   └── VX_afu_wrap.sv      # ❌ FPGA 전용
└── Vortex_axi.sv           # ❌ FPGA 전용
```

**결론**: **핵심 GPU 로직은 동일**, **인터페이스만 다름**

---

## 9. 디버깅 및 트레이싱

### 9.1 VCD Waveform

```makefile
# DEBUG 빌드
make DEBUG=3

# 실행
./rtlsim kernel.bin

# 생성: trace.vcd
```

**GTKWave로 확인**:
```bash
gtkwave trace.vcd

# 유용한 신호들:
# - rtlsim_shim.vortex.clk
# - rtlsim_shim.vortex.VX_cluster[0].VX_socket[0].VX_core[0].VX_execute.*
# - rtlsim_shim.mem_req_valid[*]
# - rtlsim_shim.mem_req_addr[*]
```

### 9.2 RTL Trace 출력

```makefile
# Trace flags
DBG_TRACE_FLAGS += -DDBG_TRACE_PIPELINE
DBG_TRACE_FLAGS += -DDBG_TRACE_MEM
DBG_TRACE_FLAGS += -DDBG_TRACE_CACHE

# 빌드
make DEBUG=3

# 실행
./rtlsim kernel.bin 2>&1 | tee trace.log
```

**출력 예시**:
```
100: [D$0-0] core-req: valid=1, addr=0x80000000, tag=0x1
101: [D$0-0] mem-req: valid=1, addr=0x10000, bank=0
150: [D$0-0] mem-rsp: valid=1, data=0x12345678, tag=0x1
151: [D$0-0] core-rsp: valid=1, data=0x12345678
```

### 9.3 Console Output

```c
// GPU Kernel
printf("Hello from core %d, thread %d\n", vx_core_id(), vx_thread_id());
```

**시뮬레이터 출력**:
```
#0: Hello from core 0, thread 0
#1: Hello from core 0, thread 1
#2: Hello from core 0, thread 2
...
```

**구현** (processor.cpp):
```cpp
if (byte_addr >= IO_COUT_ADDR && byte_addr < IO_COUT_ADDR + IO_COUT_SIZE) {
    for (int i = 0; i < PLATFORM_MEMORY_DATA_SIZE; i++) {
        if ((byteen >> i) & 0x1) {
            char c = data[i];
            print_bufs_[i] << c;
            if (c == '\n') {
                std::cout << "#" << i << ": " << print_bufs_[i].str();
                print_bufs_[i].str("");
            }
        }
    }
}
```

### 9.4 Performance Monitoring

```cpp
// Application
uint64_t mpm_cycles;
vx_mpm_query(device, VX_CSR_MPM_CYCLES, 0, &mpm_cycles);
printf("Execution cycles: %ld\n", mpm_cycles);

// Runtime (vortex.cpp)
int mpm_query(uint32_t addr, uint32_t core_id, uint64_t* value) {
    uint32_t offset = addr - VX_CSR_MPM_BASE;
    uint64_t mpm_mem_addr = IO_MPM_ADDR + core_id * 32 * sizeof(uint64_t);
    
    // Download MPM data from simulation memory
    download(mpm_cache_[core_id].data(), mpm_mem_addr, 32 * sizeof(uint64_t));
    
    *value = mpm_cache_[core_id][offset];
    return 0;
}
```

---

## 10. 요약

### rtlsim의 핵심 구성요소

| 계층 | 파일 | 역할 |
|------|------|------|
| **Application** | test.c | Vortex runtime API 호출 |
| **Runtime** | vortex.cpp | vx_device, async execution |
| **Simulator Library** | processor.cpp | Verilator wrapper, DRAM sim |
| **Verilated Model** | Vrtlsim_shim | RTL → C++ 변환 결과 |
| **RTL Testbench** | rtlsim_shim.sv | Vortex + adapters |
| **GPU Core** | Vortex.sv | 실제 GPU 로직 |

### Verilator 워크플로우

```
RTL Source (.sv)
    ↓ verilator --build
C++ Model (Vrtlsim_shim.cpp/h)
    ↓ g++ link
librtlsim.so
    ↓ runtime link
libvortex-rtlsim.so
    ↓ dlopen
Application
```

### vortex_axi 미사용 이유

- ✅ **rtlsim**: 시뮬레이션용, 직접 메모리 인터페이스, DCR 직접 접근
- ❌ **vortex_axi**: FPGA용, AXI4 프로토콜, AFU 제어 계층
- ✅ **핵심 GPU 로직은 동일** (Vortex.sv)
- ✅ **Crossbar는 유사** (VX_mem_bank_adapter ≈ VX_axi_adapter)

### 주요 장점

1. **Fast Simulation**: Verilator의 compile-based 방식
2. **Cycle-Accurate**: RTL과 동일한 동작
3. **VCD Tracing**: 파형으로 상세 디버깅
4. **Standard API**: 다른 runtime과 동일한 인터페이스
5. **Realistic Memory**: Ramulator DRAM 시뮬레이션

### 다음 단계

- [ ] VCD 파일로 파이프라인 동작 분석
- [ ] Custom memory model 추가 (DRAM latency 변경)
- [ ] Multi-threading Verilator (`--threads N`)
- [ ] Coverage 측정 (`--coverage`)

---

**참고 파일**:
- [rtlsim_shim.sv](../../sim/rtlsim/rtlsim_shim.sv)
- [processor.cpp](../../sim/rtlsim/processor.cpp)
- [vortex.cpp](../../runtime/rtlsim/vortex.cpp)
- [sim/rtlsim/Makefile](../../sim/rtlsim/Makefile)
- [runtime/rtlsim/Makefile](../../runtime/rtlsim/Makefile)
