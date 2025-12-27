# Blackbox RTL 시뮬레이션 테스트 가이드

## 목차
1. [개요](#1-개요)
2. [blackbox.sh 스크립트 분석](#2-blackboxsh-스크립트-분석)
3. [RTL 시뮬레이션 전체 흐름](#3-rtl-시뮬레이션-전체-흐름)
4. [Verilator 사용 방식](#4-verilator-사용-방식)
5. [빌드 과정 상세](#5-빌드-과정-상세)
6. [테스트 실행 흐름](#6-테스트-실행-흐름)
7. [디버깅 옵션](#7-디버깅-옵션)
8. [실전 사용 예시](#8-실전-사용-예시)

---

## 1. 개요

### 1.1 blackbox.sh란?

`blackbox.sh`는 Vortex GPGPU의 자동화된 테스트 드라이버로, 다양한 하드웨어 설정과 드라이버를 조합하여 테스트를 실행합니다. RTL 시뮬레이션 테스트 시 **Verilator**를 통해 실제 RTL 코드를 C++ 모델로 컴파일하여 cycle-accurate 시뮬레이션을 수행합니다.

### 1.2 위치

```
build/ci/blackbox.sh
```

### 1.3 지원 드라이버

| 드라이버 | 설명 | 시뮬레이션 타입 |
|---------|------|----------------|
| `simx` | Instruction Set Simulator | Functional (기본값) |
| `rtlsim` | Verilator RTL Simulation | Cycle-accurate |
| `opae` | Intel OPAE FPGA | Hardware |
| `xrt` | Xilinx XRT FPGA | Hardware |
| `gpu` | Host GPU | Native |

---

## 2. blackbox.sh 스크립트 분석

### 2.1 사용법

```bash
./blackbox.sh [[--clusters=#n] [--cores=#n] [--warps=#n] [--threads=#n] \
               [--l2cache] [--l3cache] [--driver=#name] [--app=#app] \
               [--args=#args] [--debug=#level] [--scope] [--perf=#class] \
               [--log=logfile] [--nohup]]
```

### 2.2 주요 옵션

| 옵션 | 설명 | 예시 |
|------|------|------|
| `--driver` | 시뮬레이션 드라이버 선택 | `--driver=rtlsim` |
| `--app` | 테스트 애플리케이션 | `--app=sgemm` |
| `--cores` | 코어 수 설정 | `--cores=4` |
| `--warps` | 워프 수 설정 | `--warps=8` |
| `--threads` | 스레드 수 설정 | `--threads=4` |
| `--l2cache` | L2 캐시 활성화 | `--l2cache` |
| `--l3cache` | L3 캐시 활성화 | `--l3cache` |
| `--debug` | 디버그 레벨 (0-3) | `--debug=3` |
| `--debug-flags` | SimX 디버그 플래그 | `--debug-flags=pipeline,mem` |
| `--scope` | Scope 트레이싱 활성화 | `--scope` |
| `--perf` | 성능 모니터링 클래스 | `--perf=2` |
| `--args` | 애플리케이션 인자 | `--args="-n64"` |
| `--tcu_enable` | TCU 확장 활성화 | `--tcu_enable` |

### 2.3 스크립트 핵심 흐름

```bash
main() {
    parse_args "$@"      # 1. 인자 파싱
    set_driver_path      # 2. 드라이버 경로 설정
    set_app_path         # 3. 애플리케이션 경로 설정

    # GPU 드라이버는 별도 처리
    if [ "$DRIVER" = "gpu" ]; then
        run_app
        exit $?
    fi

    # 하드웨어 설정 생성
    make -C "$ROOT_DIR/hw" config > /dev/null
    make -C "$ROOT_DIR/runtime/stub" > /dev/null

    build_driver         # 4. 드라이버 빌드 (Verilator 컴파일)
    run_app              # 5. 테스트 실행

    # VCD 파일 이동
    if [ $DEBUG -eq 1 ] && [ -f "$APP_PATH/trace.vcd" ]; then
        mv -f $APP_PATH/trace.vcd .
    fi
}
```

---

## 3. RTL 시뮬레이션 전체 흐름

### 3.1 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                      blackbox.sh                                │
│  --driver=rtlsim --app=sgemm --cores=4 --debug=3               │
└─────────────────────────┬───────────────────────────────────────┘
                          │
          ┌───────────────┴───────────────┐
          │                               │
          ▼                               ▼
┌─────────────────────┐       ┌─────────────────────────────────┐
│    build_driver()   │       │        run_app()                │
│                     │       │                                 │
│ make -C runtime/    │       │ make -C tests/regression/sgemm  │
│   rtlsim            │       │   run-rtlsim                    │
│   CONFIGS="..."     │       │                                 │
└─────────┬───────────┘       └─────────────┬───────────────────┘
          │                                 │
          ▼                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                     sim/rtlsim/Makefile                         │
│  - Verilator가 RTL을 C++ 모델로 컴파일                          │
│  - librtlsim.so 생성                                            │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                   runtime/rtlsim/Makefile                       │
│  - libvortex-rtlsim.so 생성 (runtime library)                   │
│  - librtlsim.so 링크                                            │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Application Execution                           │
│  LD_LIBRARY_PATH=... VORTEX_DRIVER=rtlsim ./sgemm               │
│                                                                 │
│  1. dlopen("libvortex-rtlsim.so")                               │
│  2. vx_dev_open() → Verilator 모델 초기화                       │
│  3. vx_start() → RTL 시뮬레이션 실행                            │
│  4. vx_ready_wait() → 완료 대기                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 파일 관계도

```
blackbox.sh
    │
    ├── runtime/rtlsim/
    │   ├── Makefile
    │   ├── vortex.cpp          ← vx_device 구현
    │   └── libvortex-rtlsim.so ← 출력물
    │
    ├── sim/rtlsim/
    │   ├── Makefile
    │   ├── processor.h/cpp     ← Verilator 래퍼
    │   ├── rtlsim_shim.sv      ← RTL Testbench
    │   ├── main.cpp            ← Standalone 실행기
    │   ├── verilator.vlt.in    ← Lint 설정
    │   └── librtlsim.so        ← 출력물
    │
    ├── hw/rtl/
    │   ├── Vortex.sv           ← Top-level GPU
    │   ├── VX_cluster.sv
    │   ├── VX_socket.sv
    │   ├── VX_core.sv
    │   └── ...
    │
    └── tests/regression/sgemm/
        ├── Makefile
        ├── main.cpp            ← Host 코드
        ├── kernel.cpp          ← GPU 커널
        └── common.mk           ← 공통 빌드 규칙
```

---

## 4. Verilator 사용 방식

### 4.1 Verilator란?

**Verilator**는 Verilog/SystemVerilog RTL을 고성능 C++ 시뮬레이션 모델로 변환하는 오픈소스 도구입니다.

```
RTL Source (.sv, .v)
    │
    │  verilator --cc --build
    ▼
C++ Model (Vrtlsim_shim.cpp/h)
    │
    │  g++ link
    ▼
librtlsim.so (Shared Library)
```

### 4.2 Verilator 컴파일 옵션 (sim/rtlsim/Makefile)

```makefile
# Top module
TOP = rtlsim_shim

# Verilator flags
VL_FLAGS = --exe
VL_FLAGS += --language 1800-2009 --assert -Wall -Wpedantic
VL_FLAGS += -Wno-DECLFILENAME -Wno-REDEFMACRO
VL_FLAGS += --x-initial unique --x-assign unique
VL_FLAGS += verilator.vlt                        # Lint 설정
VL_FLAGS += -DSIMULATION -DSV_DPI                # RTL 컴파일 define
VL_FLAGS += -DXLEN_$(XLEN)                       # 32 또는 64비트
VL_FLAGS += $(CONFIGS)                           # 하드웨어 설정
VL_FLAGS += $(RTL_INCLUDE)                       # Include 경로
VL_FLAGS += $(RTL_PKGS)                          # 패키지 파일들
VL_FLAGS += --cc $(TOP) --top-module $(TOP)

# Parallel compilation
THREADS ?= $(shell python3 -c 'import multiprocessing as mp; print(mp.cpu_count())')
VL_FLAGS += -j $(THREADS)

# Debug build
ifdef DEBUG
    VL_FLAGS += --trace --trace-structs $(DBG_FLAGS)
endif
```

### 4.3 핵심 옵션 설명

| 옵션 | 설명 |
|------|------|
| `--exe` | 실행 파일 생성 모드 |
| `--cc` | C++ 모델 생성 |
| `--build` | Verilator + g++ 통합 빌드 |
| `--top-module rtlsim_shim` | 시뮬레이션 최상위 모듈 |
| `--trace` | VCD 파형 덤프 활성화 |
| `--trace-structs` | 구조체 신호 트레이싱 |
| `-j N` | 병렬 컴파일 (N코어) |
| `-DSIMULATION` | 시뮬레이션 모드 define |

### 4.4 생성되는 파일

```
build/rtlsim.obj_dir/
├── Vrtlsim_shim.cpp         # Main module C++ 코드
├── Vrtlsim_shim.h           # Module 헤더
├── Vrtlsim_shim__Syms.cpp   # Symbol table
├── Vrtlsim_shim__Trace.cpp  # VCD 트레이싱 (DEBUG 시)
├── verilated.cpp            # Verilator 런타임
├── verilated_dpi.cpp        # DPI 지원
└── verilated_vcd_c.cpp      # VCD 출력
```

### 4.5 RTL Testbench (rtlsim_shim.sv)

```
┌──────────────────────────────────────────────────────────────┐
│                    rtlsim_shim.sv                            │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                    Vortex (GPU Core)                   │  │
│  │  - VX_cluster → VX_socket → VX_core                    │  │
│  │  - Cache hierarchy (L1/L2/L3)                          │  │
│  │  - Execute units (ALU, FPU, LSU, etc.)                 │  │
│  └──────────────────┬─────────────────────────────────────┘  │
│                     │ VX_MEM_PORTS (4~8개)                   │
│                     ▼                                        │
│  ┌────────────────────────────────────────────────────────┐  │
│  │   VX_mem_data_adapter (Width Conversion)               │  │
│  │   32/64-bit → 512-bit (Platform memory width)          │  │
│  └──────────────────┬─────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌────────────────────────────────────────────────────────┐  │
│  │   VX_mem_bank_adapter (Crossbar)                       │  │
│  │   N input ports → M memory banks                       │  │
│  └──────────────────┬─────────────────────────────────────┘  │
│                     │ MEM_NUM_BANKS (1~32개)                 │
│                     ▼                                        │
│  mem_req/rsp [MEM_NUM_BANKS]                                 │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       │  C++ Processor::Impl에서 처리
                       ▼
            ┌──────────────────────┐
            │   DRAM Simulator     │
            │   (Ramulator)        │
            └──────────────────────┘
```

**rtlsim_shim.sv 인터페이스:**

```systemverilog
module rtlsim_shim #(
    parameter MEM_DATA_WIDTH = 512,      // 플랫폼 메모리 버스 폭
    parameter MEM_ADDR_WIDTH = 20,       // 주소 폭
    parameter MEM_NUM_BANKS  = 8         // 메모리 뱅크 수
) (
    // Clock & Reset
    input wire clk, reset,

    // Memory Request (to C++)
    output wire mem_req_valid[MEM_NUM_BANKS],
    output wire mem_req_rw[MEM_NUM_BANKS],
    output wire mem_req_byteen[...],
    output wire mem_req_addr[...],
    output wire mem_req_data[...],
    output wire mem_req_tag[...],
    input wire mem_req_ready[MEM_NUM_BANKS],

    // Memory Response (from C++)
    input wire mem_rsp_valid[MEM_NUM_BANKS],
    input wire mem_rsp_data[...],
    input wire mem_rsp_tag[...],
    output wire mem_rsp_ready[MEM_NUM_BANKS],

    // DCR (Device Configuration Registers)
    input wire dcr_wr_valid,
    input wire dcr_wr_addr,
    input wire dcr_wr_data,

    // Status
    output wire busy
);
```

---

## 5. 빌드 과정 상세

### 5.1 Step 1: 하드웨어 설정 생성

```bash
make -C "$ROOT_DIR/hw" config > /dev/null
```

**입력 (CONFIGS):**
```makefile
CONFIGS="-DNUM_CORES=4 -DNUM_WARPS=8 -DL2_ENABLE"
```

**출력 (hw/VX_config.h):**
```c
#define NUM_CLUSTERS 1
#define NUM_CORES 4
#define NUM_WARPS 8
#define NUM_THREADS 4
#define L2_ENABLE
...
```

### 5.2 Step 2: Stub Runtime 빌드

```bash
make -C "$ROOT_DIR/runtime/stub" > /dev/null
```

**역할:** 드라이버 선택 로직 (dlopen을 통한 동적 로딩)

```cpp
// runtime/stub/vortex.cpp
int vx_dev_open(vx_device_h* hdevice) {
    const char* driverName = getenv("VORTEX_DRIVER");  // "rtlsim"
    std::string libName = "libvortex-" + driverName + ".so";

    auto handle = dlopen(libName.c_str(), RTLD_LAZY);
    auto vx_dev_init = (vx_dev_init_t)dlsym(handle, "vx_dev_init");
    vx_dev_init(&g_callbacks);

    return g_callbacks.vx_dev_open(hdevice);
}
```

### 5.3 Step 3: RTL Simulator 빌드 (build_driver)

```bash
# blackbox.sh의 build_driver()
build_driver() {
    local cmd_opts=""
    [ $DEBUG -eq 1 ] && [ -n "$DEBUG_LEVEL" ] && \
        cmd_opts=$(add_option "$cmd_opts" "DEBUG=$DEBUG_LEVEL")
    [ -n "$CONFIGS" ] && \
        cmd_opts=$(add_option "$cmd_opts" "CONFIGS=\"$CONFIGS\"")

    cmd_opts=$(add_option "$cmd_opts" "make -C $DRIVER_PATH > /dev/null")
    eval "$cmd_opts"
}
```

**실제 실행되는 명령어:**
```bash
CONFIGS="-DNUM_CORES=4 -DL2_ENABLE" DEBUG=3 make -C runtime/rtlsim
```

**빌드 순서:**

```
1. sim/rtlsim/Makefile
   └── verilator --build ... → librtlsim.so
       ├── RTL 컴파일 (Vortex.sv, rtlsim_shim.sv 등)
       ├── C++ 모델 생성 (Vrtlsim_shim.cpp/h)
       └── processor.cpp 링크

2. runtime/rtlsim/Makefile
   └── g++ vortex.cpp -lrtlsim → libvortex-rtlsim.so
```

### 5.4 Step 4: 테스트 애플리케이션 빌드 및 실행 (run_app)

```bash
# blackbox.sh의 run_app()
run_app() {
    local cmd_opts=""
    [ $DEBUG -eq 1 ] && cmd_opts=$(add_option "$cmd_opts" "DEBUG=1")
    [ $HAS_ARGS -eq 1 ] && cmd_opts=$(add_option "$cmd_opts" "OPTS=\"$ARGS\"")

    cmd_opts=$(add_option "$cmd_opts" "make -C \"$APP_PATH\" run-$DRIVER")
    eval "$cmd_opts"
}
```

**실제 실행 (tests/regression/common.mk):**
```makefile
run-rtlsim: $(PROJECT) kernel.vxbin
	LD_LIBRARY_PATH=$(VORTEX_RT_PATH):$(LD_LIBRARY_PATH) \
	VORTEX_DRIVER=rtlsim \
	./$(PROJECT) $(OPTS)
```

---

## 6. 테스트 실행 흐름

### 6.1 Runtime 실행 시퀀스

```
Application (sgemm)
    │
    │  vx_dev_open()
    ▼
┌─────────────────────────────────────────┐
│  libvortex.so (stub)                    │
│  └── dlopen("libvortex-rtlsim.so")      │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  libvortex-rtlsim.so                    │
│  ├── new vx_device()                    │
│  │   ├── RAM ram_                       │
│  │   ├── Processor processor_           │
│  │   └── MemoryAllocator global_mem_    │
│  └── processor_.attach_ram(&ram_)       │
└─────────────────────────────────────────┘
    │
    │  vx_mem_alloc(), vx_copy_to_dev()
    ▼
┌─────────────────────────────────────────┐
│  Upload kernel.vxbin to simulation RAM  │
└─────────────────────────────────────────┘
    │
    │  vx_start()
    ▼
┌─────────────────────────────────────────┐
│  vx_device::start()                     │
│  ├── dcr_write(STARTUP_ADDR, krnl_addr) │
│  ├── dcr_write(STARTUP_ARG, args_addr)  │
│  └── std::async([&]{                    │
│          processor_.run();              │
│      })                                 │
└─────────────────────────────────────────┘
    │
    │  processor_.run()
    ▼
┌─────────────────────────────────────────┐
│  Processor::Impl::run()                 │
│  ├── reset()                            │
│  ├── while (!device_->busy) tick()      │  ← GPU 시작 대기
│  ├── while (device_->busy) tick()       │  ← 실행 완료 대기
│  │   └── tick()                         │
│  │       ├── device_->clk = 0           │
│  │       ├── device_->eval()            │  ← RTL 평가
│  │       ├── mem_bus_eval()             │  ← 메모리 처리
│  │       ├── dram_sim_.tick()           │
│  │       ├── device_->clk = 1           │
│  │       ├── device_->eval()            │
│  │       └── tfp_->dump(timestamp)      │  ← VCD 기록
│  └── reset()                            │
└─────────────────────────────────────────┘
    │
    │  vx_ready_wait()
    ▼
┌─────────────────────────────────────────┐
│  future_.wait()                         │
└─────────────────────────────────────────┘
    │
    │  vx_copy_from_dev()
    ▼
┌─────────────────────────────────────────┐
│  Download results from simulation RAM   │
└─────────────────────────────────────────┘
```

### 6.2 Verilator 시뮬레이션 루프

```cpp
// processor.cpp
void Processor::Impl::tick() {
    // Negative edge
    device_->clk = 0;
    device_->eval();           // Combinational logic

    // Memory request handling
    mem_bus_eval();

    // DRAM simulation
    dram_sim_.tick();

    // Positive edge
    device_->clk = 1;
    device_->eval();           // Sequential logic

#ifdef VCD_OUTPUT
    if (sim_trace_enabled()) {
        tfp_->dump(timestamp);  // VCD 기록
    }
#endif

    ++timestamp;
}

void Processor::Impl::mem_bus_eval() {
    // Process memory requests from RTL
    for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
        if (device_->mem_req_valid[b] && device_->mem_req_ready[b]) {
            if (device_->mem_req_rw[b]) {
                // Write: RTL → RAM
                ram_->write(device_->mem_req_data[b],
                           device_->mem_req_addr[b], ...);
            } else {
                // Read: RAM → RTL
                ram_->read(mem_req->data,
                          device_->mem_req_addr[b], ...);
            }
            dram_queue_[b].push(mem_req);
        }
    }

    // Generate responses after DRAM latency
    for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
        if (!pending_mem_reqs_[b].empty() && mem_req->ready) {
            device_->mem_rsp_valid[b] = 1;
            device_->mem_rsp_data[b] = mem_req->data;
            device_->mem_rsp_tag[b] = mem_req->tag;
        }
    }
}
```

---

## 7. 디버깅 옵션

### 7.1 VCD Waveform 생성

```bash
# DEBUG 빌드로 실행
./blackbox.sh --driver=rtlsim --app=sgemm --debug=3
```

**생성 파일:** `trace.vcd`

**GTKWave로 확인:**
```bash
gtkwave trace.vcd &
```

**유용한 신호 경로:**
```
rtlsim_shim.vortex.clk
rtlsim_shim.vortex.reset
rtlsim_shim.vortex.busy
rtlsim_shim.mem_req_valid[*]
rtlsim_shim.mem_req_addr[*]
rtlsim_shim.mem_rsp_valid[*]
rtlsim_shim.vortex.VX_cluster[0].VX_socket[0].VX_core[0].*
```

### 7.2 디버그 트레이스 플래그

```makefile
# sim/rtlsim/Makefile
DBG_TRACE_FLAGS += -DDBG_TRACE_PIPELINE   # 파이프라인 트레이스
DBG_TRACE_FLAGS += -DDBG_TRACE_MEM        # 메모리 트레이스
DBG_TRACE_FLAGS += -DDBG_TRACE_CACHE      # 캐시 트레이스
DBG_TRACE_FLAGS += -DDBG_TRACE_AFU        # AFU 트레이스
DBG_TRACE_FLAGS += -DDBG_TRACE_SCOPE      # Scope 트레이스
DBG_TRACE_FLAGS += -DDBG_TRACE_GBAR       # Global barrier 트레이스
DBG_TRACE_FLAGS += -DDBG_TRACE_TCU        # TCU 트레이스
```

### 7.3 디버그 레벨

| 레벨 | 설명 |
|------|------|
| 0 | 디버그 비활성화 |
| 1 | 기본 트레이스 |
| 2 | 상세 트레이스 |
| 3 | 전체 트레이스 + VCD |

### 7.4 SimX 디버그 플래그 모드 (--debug-flags)

```bash
./blackbox.sh --driver=simx --app=sgemm --debug-flags=pipeline,mem,cache
```

**지원 플래그:**
- `pipeline` - 파이프라인 스테이지 출력
- `mem` - 메모리 접근 출력
- `cache` - 캐시 히트/미스 출력

### 7.5 Console Output

GPU 커널에서의 `printf` 출력은 특별한 메모리 주소를 통해 호스트로 리다이렉트됩니다:

```cpp
// processor.cpp
#define IO_COUT_ADDR 0x7FFFF000

if (byte_addr >= IO_COUT_ADDR && byte_addr < IO_COUT_ADDR + IO_COUT_SIZE) {
    // GPU printf → stdout
    for (int i = 0; i < PLATFORM_MEMORY_DATA_SIZE; i++) {
        if ((byteen >> i) & 0x1) {
            char c = data[i];
            std::cout << c;
        }
    }
}
```

---

## 8. 실전 사용 예시

### 8.1 기본 RTL 시뮬레이션

```bash
./blackbox.sh --driver=rtlsim --app=vecadd
```

### 8.2 멀티코어 설정

```bash
./blackbox.sh --driver=rtlsim --app=sgemm --cores=4 --warps=8 --threads=4
```

### 8.3 캐시 계층 활성화

```bash
./blackbox.sh --driver=rtlsim --app=sgemm --cores=4 --l2cache --l3cache
```

### 8.4 디버깅 (VCD 생성)

```bash
./blackbox.sh --driver=rtlsim --app=sgemm --debug=3

# VCD 파일 확인
gtkwave trace.vcd
```

### 8.5 성능 모니터링

```bash
./blackbox.sh --driver=rtlsim --app=sgemm --perf=2

# 결과에서 cycle count, instruction count 등 확인
```

### 8.6 TCU 확장 테스트

```bash
./blackbox.sh --driver=rtlsim --app=sgemm_tcu --tcu_enable --debug=1
```

### 8.7 커스텀 인자 전달

```bash
./blackbox.sh --driver=rtlsim --app=sgemm --args="-n64 -m64 -k64"
```

### 8.8 임시 디렉토리에서 실행 (nohup)

```bash
./blackbox.sh --driver=rtlsim --app=sgemm --nohup &
```

### 8.9 클러스터 설정

```bash
./blackbox.sh --driver=rtlsim --app=sgemm --clusters=2 --cores=4 --l2cache --l3cache
```

---

## 요약

### RTL 시뮬레이션 특징

| 항목 | 설명 |
|------|------|
| **시뮬레이터** | Verilator (compile-based) |
| **정확도** | Cycle-accurate |
| **Top Module** | `rtlsim_shim` |
| **Runtime Library** | `libvortex-rtlsim.so` |
| **Simulator Library** | `librtlsim.so` |
| **메모리 모델** | Page-based RAM + Ramulator DRAM |
| **실행 방식** | `std::async` 비동기 실행 |
| **디버그 출력** | VCD waveform, Console trace |

### 주요 파일

| 파일 | 역할 |
|------|------|
| `build/ci/blackbox.sh` | 테스트 드라이버 |
| `sim/rtlsim/Makefile` | Verilator 빌드 |
| `sim/rtlsim/rtlsim_shim.sv` | RTL Testbench |
| `sim/rtlsim/processor.cpp` | Verilator C++ 래퍼 |
| `runtime/rtlsim/vortex.cpp` | Runtime API 구현 |
| `tests/regression/common.mk` | 테스트 빌드 규칙 |

### 빌드 및 실행 요약

```bash
# 1. blackbox.sh 실행
./blackbox.sh --driver=rtlsim --app=sgemm --cores=4 --debug=3

# 내부 동작:
# 1) make -C hw config CONFIGS="..."           → VX_config.h 생성
# 2) make -C runtime/stub                      → libvortex.so
# 3) make -C runtime/rtlsim CONFIGS="..." DEBUG=3
#    └── make -C sim/rtlsim                    → librtlsim.so (Verilator)
#    └── g++ vortex.cpp -lrtlsim              → libvortex-rtlsim.so
# 4) make -C tests/regression/sgemm run-rtlsim
#    └── VORTEX_DRIVER=rtlsim ./sgemm          → 시뮬레이션 실행
# 5) mv trace.vcd .                            → VCD 파일 이동
```

---

**관련 문서:**
- [RTL_Simulation_Guide.md](RTL_Simulation_Guide.md) - RTL 시뮬레이션 상세 아키텍처
- [VCS_RTL_Simulation_Integration.md](VCS_RTL_Simulation_Integration.md) - VCS 시뮬레이션
- [simulation.md](../simulation.md) - 시뮬레이션 개요

**관련 소스:**
- [rtlsim_shim.sv](../../sim/rtlsim/rtlsim_shim.sv)
- [processor.cpp](../../sim/rtlsim/processor.cpp)
- [vortex.cpp](../../runtime/rtlsim/vortex.cpp)
- [sim/rtlsim/Makefile](../../sim/rtlsim/Makefile)
- [common.mk](../../tests/regression/common.mk)
