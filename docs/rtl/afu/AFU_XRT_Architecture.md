# AFU (Accelerator Functional Unit) - XRT Architecture

## 개요

**AFU (Accelerator Functional Unit)**는 Vortex GPGPU를 FPGA 플랫폼(특히 Xilinx XRT - Xilinx Runtime)에 통합하기 위한 래퍼(wrapper) 모듈입니다. AFU는 호스트 CPU와 Vortex GPU 간의 인터페이스 역할을 하며, AXI4 프로토콜을 통해 통신합니다.

**위치**: `hw/rtl/afu/xrt/`

---

## 1. AFU의 역할

### 1.1 주요 기능

1. **호스트 제어 인터페이스**
   - AXI4-Lite Slave 인터페이스로 호스트로부터 제어 명령 수신
   - GPU 시작/정지, 상태 확인, 레지스터 설정

2. **메모리 인터페이스**
   - AXI4 Master 인터페이스로 플랫폼 메모리(DDR/HBM) 접근
   - 다중 메모리 뱅크 지원 (병렬 메모리 접근)

3. **GPU 라이프사이클 관리**
   - Reset sequence 관리
   - GPU 실행 상태 추적 (IDLE → INIT → RUN → DONE)
   - Pending write 추적 (메모리 일관성 보장)

4. **인터럽트 처리**
   - GPU 작업 완료 시 호스트에 인터럽트 전송

---

## 2. 계층 구조

```
┌─────────────────────────────────────────┐
│         Host CPU (XRT Runtime)          │
└──────────────┬──────────────────────────┘
               │ AXI4-Lite (Control)
               │ AXI4 (Memory)
┌──────────────┴──────────────────────────┐
│        vortex_afu.v (Top Module)        │
│  - Verilog wrapper for XRT integration  │
└──────────────┬──────────────────────────┘
               │
┌──────────────┴──────────────────────────┐
│        VX_afu_wrap.sv                   │
│  - Main AFU logic                       │
│  - State machine (IDLE/INIT/RUN/DONE)   │
│  - Memory interface management          │
└─────┬─────────────────────┬─────────────┘
      │                     │
      │                     │
┌─────┴──────────┐  ┌───────┴─────────────┐
│ VX_afu_ctrl.sv │  │   Vortex (vortex_axi)│
│ - AXI4-Lite    │  │   - Vortex GPU Core  │
│ - Control Regs │  │   - AXI4 Master      │
│ - DCR Write    │  │                      │
│ - Scope Debug  │  │                      │
└────────────────┘  └──────────────────────┘
```

---

## 3. 모듈 상세

### 3.1 vortex_afu.v (Top-level Wrapper)

**파일**: `vortex_afu.v`

**역할**: Xilinx XRT와의 인터페이스를 위한 Verilog wrapper

**주요 인터페이스**:
```verilog
// System Signals
input  wire ap_clk         // Clock
input  wire ap_rst_n       // Active-low reset

// AXI4 Master (Memory Interface)
// - m_axi_mem_0_* ~ m_axi_mem_N_* (다중 뱅크)
output wire m_axi_mem_awvalid, awready, ...  // Write Address
output wire m_axi_mem_wvalid, wready, ...    // Write Data
input  wire m_axi_mem_bvalid, bready, ...    // Write Response
output wire m_axi_mem_arvalid, arready, ...  // Read Address
input  wire m_axi_mem_rvalid, rready, ...    // Read Data

// AXI4-Lite Slave (Control Interface)
input  wire s_axi_ctrl_awvalid, awready, ... // Write Address
input  wire s_axi_ctrl_wvalid, wready, ...   // Write Data
output wire s_axi_ctrl_bvalid, bready, ...   // Write Response
input  wire s_axi_ctrl_arvalid, arready, ... // Read Address
output wire s_axi_ctrl_rvalid, rready, ...   // Read Data

// Interrupt
output wire interrupt      // GPU 완료 인터럽트
```

**동작**:
- 단순히 신호를 `VX_afu_wrap`으로 전달
- Verilog 모듈이므로 XRT IP Integrator와 호환

---

### 3.2 VX_afu_wrap.sv (Main AFU Logic)

**파일**: `VX_afu_wrap.sv`

**역할**: AFU의 핵심 로직 - GPU 상태 관리 및 메모리 인터페이스

#### 3.2.1 상태 머신

```systemverilog
typedef enum logic [1:0] {
    STATE_IDLE = 0,  // 대기 상태
    STATE_INIT = 1,  // 초기화 (reset)
    STATE_RUN  = 2,  // GPU 실행 중
    STATE_DONE = 3   // 실행 완료
} state_e;
```

**상태 전환**:
```
IDLE ───(ap_start)──→ INIT ───(reset완료)──→ INIT
  ↑                              │
  │                          (vx_busy)
  │                              ↓
  └──(ap_done_ack)──── DONE ←── RUN
                                (~vx_busy)
```

**각 상태 설명**:

1. **STATE_IDLE**:
   - 호스트의 `ap_start` 신호 대기
   - `ap_start == 1` → STATE_INIT로 전환

2. **STATE_INIT**:
   - GPU reset sequence 수행
   - `vx_reset_ctr` 카운터로 `RESET_DELAY` 사이클 대기
   - Reset 완료 후 GPU가 busy 상태 진입 대기
   - `vx_busy == 1` → STATE_RUN으로 전환

3. **STATE_RUN**:
   - GPU가 프로그램 실행 중
   - `vx_busy == 0` (GPU idle) → STATE_DONE으로 전환

4. **STATE_DONE**:
   - `ap_done` 신호 assert (호스트에 완료 알림)
   - 모든 pending writes 완료 대기: `vx_pending_writes == 0`
   - 호스트의 `ap_done_ack` (control register read) → STATE_IDLE

#### 3.2.2 Pending Writes 추적

**목적**: 메모리 일관성 보장 - 모든 write가 완료되어야 실행 종료

```systemverilog
reg [PENDING_WR_SIZEW-1:0] vx_pending_writes;

// Write Request 감지
for (genvar i = 0; i < C_M_AXI_MEM_NUM_BANKS; ++i) begin
    VX_axi_write_ack axi_write_ack (
        .awvalid(m_axi_mem_awvalid_a[i]),
        .awready(m_axi_mem_awready_a[i]),
        .wvalid (m_axi_mem_wvalid_a[i]),
        .wready (m_axi_mem_wready_a[i]),
        .tx_ack (m_axi_wr_req_fire[i])  // Request 완료
    );
end

// Write Response 감지
assign m_axi_wr_rsp_fire[i] = m_axi_mem_bvalid_a[i] && m_axi_mem_bready_a[i];

// 카운터 업데이트
wire signed reqs_sub = cur_wr_reqs - cur_wr_rsps;
vx_pending_writes <= vx_pending_writes + reqs_sub;
```

**동작**:
- Write request 발생 시 +1
- Write response 수신 시 -1
- `ap_done` 조건: `vx_pending_writes == 0`

#### 3.2.3 Vortex GPU 인스턴스

```systemverilog
vortex_axi #(
    .AXI_DATA_WIDTH   (C_M_AXI_MEM_DATA_WIDTH),
    .AXI_ADDR_WIDTH   (M_AXI_MEM_ADDR_WIDTH),
    .AXI_NUM_BANKS    (C_M_AXI_MEM_NUM_BANKS),
    .AXI_TID_WIDTH    (C_M_AXI_MEM_ID_WIDTH)
) vortex_axi_inst (
    .clk          (clk),
    .reset        (vx_reset),
    
    // AXI4 Master
    .m_axi_awvalid(m_axi_mem_awvalid_u),
    .m_axi_awaddr (m_axi_mem_awaddr_u),
    // ... (AXI signals)
    
    // DCR (Device Configuration Registers)
    .dcr_wr_valid (dcr_wr_valid),
    .dcr_wr_addr  (dcr_wr_addr),
    .dcr_wr_data  (dcr_wr_data),
    
    // Status
    .busy         (vx_busy)
);
```

**중요 신호**:
- `vx_reset`: AFU가 제어하는 GPU reset
- `vx_busy`: GPU 실행 상태 (1=실행 중, 0=idle)
- `dcr_wr_*`: Device Configuration Register 쓰기 (AFU ctrl에서 제공)

---

### 3.3 VX_afu_ctrl.sv (Control Register Interface)

**파일**: `VX_afu_ctrl.sv`

**역할**: AXI4-Lite Slave 인터페이스 - 호스트 제어 레지스터

#### 3.3.1 제어 레지스터 맵

**Address Map**:
```
0x00: Control Signals
  bit 0  - ap_start      (R/W/COH) - GPU 시작
  bit 1  - ap_done       (R/COR)   - GPU 완료 (Read 시 Clear)
  bit 2  - ap_idle       (R)       - GPU idle 상태
  bit 3  - ap_ready      (R)       - GPU ready 상태
  bit 4  - ap_reset      (W)       - GPU reset
  bit 7  - auto_restart  (R/W)     - 자동 재시작 (미사용)

0x04: Global Interrupt Enable Register
  bit 0  - Global Interrupt Enable

0x08: IP Interrupt Enable Register
  bit 0  - ap_done interrupt enable
  bit 1  - ap_ready interrupt enable

0x0C: IP Interrupt Status Register
  bit 0  - ap_done interrupt status (R/TOW)
  bit 1  - ap_ready interrupt status (R/TOW)

0x10-0x14: DEV_CAPS (Device Capabilities)
  - 64-bit read-only register
  - Vortex GPU 하드웨어 정보

0x1C-0x20: ISA_CAPS (ISA Capabilities)
  - 64-bit read-only register
  - RISC-V ISA extension 정보

0x28-0x30: DCR (Device Configuration Registers)
  - 64-bit write-only register
  - GPU configuration 설정
  - Write 시 dcr_wr_valid/addr/data 생성

0x34-0x3C: SCP (Scope Debug)
  - 64-bit R/W register
  - SCOPE 디버깅용 (조건부 컴파일)
  - Scope bus 직렬 통신

0x40-0x48: MEM (Memory Base Address - 미사용)
```

**Control Register 동작 (0x00)**:

```systemverilog
// Write
if (s_axi_w_fire && waddr == ADDR_CTRL) begin
    ap_start_r     <= (s_axi_wdata[0] & wmask[0]) | (ap_start_r & ~wmask[0]);
    ap_reset_r     <= (s_axi_wdata[4] & wmask[4]) | (ap_reset_r & ~wmask[4]);
    auto_restart_r <= (s_axi_wdata[7] & wmask[7]) | (auto_restart_r & ~wmask[7]);
end

// Read
if (s_axi_ar_fire && s_axi_araddr == ADDR_CTRL) begin
    ap_ctrl_read <= 1;  // ap_done을 clear하기 위한 신호
end
```

**ap_start Handshake**:
```
Host Write ap_start=1
    ↓
VX_afu_wrap detects ap_start
    ↓
STATE_IDLE → STATE_INIT
    ↓
ap_start_r cleared (COH: Clear on Handshake)
```

#### 3.3.2 DCR (Device Configuration Register) Write

**목적**: GPU 내부 설정 변경 (base_dcrs)

```systemverilog
// DCR Write
if (s_axi_w_fire && waddr == ADDR_DCR_1) begin
    cmd_dcr_writing <= 1;
end

always @(posedge clk) begin
    if (cmd_dcr_writing) begin
        dcr_wr_valid_r <= 1;
        cmd_dcr_writing <= 0;
    end else begin
        dcr_wr_valid_r <= 0;
    end
end

assign dcr_wr_valid = dcr_wr_valid_r;
assign dcr_wr_addr  = dcr_wdata[VX_DCR_ADDR_WIDTH-1:0];
assign dcr_wr_data  = dcr_wdata[VX_DCR_ADDR_WIDTH +: VX_DCR_DATA_WIDTH];
```

**사용 예시**:
```c
// Host 코드
write_reg(AFU_DCR_0, (addr << 0) | (data << VX_DCR_ADDR_WIDTH));
write_reg(AFU_DCR_1, 0);  // Trigger write
```

#### 3.3.3 인터럽트 생성

```systemverilog
// Interrupt Status 업데이트
if (ap_done) begin
    int_ap_done_r <= 1;
end else if (s_axi_ar_fire && s_axi_araddr == ADDR_CTRL) begin
    int_ap_done_r <= 0;  // Clear on Read (COR)
end

// Interrupt 출력
assign interrupt = (int_ap_done_r && int_ap_done_en_r) ||
                   (int_ap_ready_r && int_ap_ready_en_r);
```

---

## 4. 메모리 인터페이스

### 4.1 다중 메모리 뱅크

AFU는 플랫폼의 여러 메모리 뱅크를 병렬로 접근할 수 있습니다:

```systemverilog
parameter C_M_AXI_MEM_NUM_BANKS = `PLATFORM_MEMORY_NUM_BANKS;

// 각 뱅크별 AXI4 Master 인터페이스
for (genvar i = 0; i < C_M_AXI_MEM_NUM_BANKS; ++i) begin
    // m_axi_mem_0_*, m_axi_mem_1_*, ...
end
```

**병렬성**:
- 각 뱅크는 독립적인 AXI4 채널
- Vortex GPU의 L2/L3 cache 또는 memory arbiter와 연결
- 대역폭 증가: N banks × AXI bandwidth

### 4.2 Merged vs Non-Merged Interface

**Non-Merged** (기본):
```systemverilog
// 각 뱅크별 독립 인터페이스
m_axi_mem_0_awvalid, m_axi_mem_0_awready, ...
m_axi_mem_1_awvalid, m_axi_mem_1_awready, ...
...
```

**Merged** (`PLATFORM_MERGED_MEMORY_INTERFACE` 정의 시):
```systemverilog
// 단일 AXI 인터페이스로 통합
m_axi_mem_0_awvalid, m_axi_mem_0_awready, ...
```

---

## 5. 실행 흐름 예시

### 5.1 GPU 프로그램 실행 시퀀스

```
1. Host: 프로그램 메모리에 로드
   - 메모리 write (DMA 또는 AXI)

2. Host: DCR 설정 (필요 시)
   - write_reg(ADDR_DCR_0, config_data)
   - write_reg(ADDR_DCR_1, 0)

3. Host: GPU 시작
   - write_reg(ADDR_CTRL, 0x01)  // ap_start = 1

4. AFU: STATE_IDLE → STATE_INIT
   - ap_start 감지
   - vx_reset = 1
   - vx_reset_ctr = RESET_DELAY-1

5. AFU: Reset sequence
   - vx_reset_ctr 카운트다운
   - vx_reset = 0

6. AFU: STATE_INIT → STATE_RUN
   - vx_busy = 1 (GPU 실행 시작)

7. GPU: 프로그램 실행
   - Fetch, Decode, Execute, ...
   - Memory access via AXI4

8. AFU: Pending writes 추적
   - Write request → vx_pending_writes++
   - Write response → vx_pending_writes--

9. GPU: 실행 완료
   - vx_busy = 0

10. AFU: STATE_RUN → STATE_DONE
    - vx_pending_writes == 0 대기
    - ap_done = 1
    - interrupt assert

11. Host: 인터럽트 수신
    - read_reg(ADDR_CTRL)  // ap_done 확인 & clear

12. AFU: STATE_DONE → STATE_IDLE
    - ap_done_ack 감지
    - 다음 실행 준비
```

### 5.2 타임라인 다이어그램

```
Time   State      ap_start  vx_reset  vx_busy  ap_done  Action
----------------------------------------------------------------
0      IDLE       0         1         0        0        Waiting
100    IDLE       1         1         0        0        Host writes ap_start
101    INIT       0         1         0        0        Begin reset
102    INIT       0         1         0        0        Reset countdown
...
108    INIT       0         0         0        0        Reset complete
109    INIT       0         0         1        0        GPU starts
110    RUN        0         0         1        0        GPU executing
...
5000   RUN        0         0         0        0        GPU completes
5001   DONE       0         0         0        1        Wait for ack
5002   DONE       0         0         0        1        Host reads CTRL
5003   IDLE       0         0         0        0        Back to idle
```

---

## 6. Xilinx XRT 통합

### 6.1 XRT Kernel 특징

AFU는 **XRT RTL Kernel** 표준을 따릅니다:

1. **AXI4-Lite Slave**: Control interface
   - 64-byte address space
   - ap_start, ap_done, ap_idle, ap_ready 신호

2. **AXI4 Master**: Memory interface
   - 64-bit addressing
   - Burst transactions

3. **Interrupt**: 작업 완료 알림

4. **Clock/Reset**:
   - `ap_clk`: 모든 로직의 clock
   - `ap_rst_n`: Active-low reset

### 6.2 XRT Runtime 호출 예시

```c
// Host 코드 (C/C++)
#include <xrt/xrt_kernel.h>
#include <xrt/xrt_bo.h>

// Kernel handle 생성
xrt::kernel krnl(device, uuid, "vortex_afu");

// Buffer object 할당
xrt::bo input_bo(device, input_size, krnl.group_id(0));
xrt::bo output_bo(device, output_size, krnl.group_id(1));

// 메모리 복사
input_bo.write(input_data);
input_bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);

// Kernel 실행
auto run = krnl(input_bo, output_bo, size);
run.wait();  // ap_done 대기 (인터럽트)

// 결과 복사
output_bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
output_bo.read(output_data);
```

**내부 동작**:
1. `krnl()`: Control register에 ap_start write
2. `run.wait()`: Interrupt 대기 (ap_done)
3. XRT는 polling 또는 interrupt로 완료 감지

---

## 7. 디버깅 및 모니터링

### 7.1 Scope Debug Interface

**조건부 컴파일**: `SCOPE` 정의 시

```systemverilog
input  wire scope_bus_in,
output wire scope_bus_out,
```

**동작**:
- 64-bit 직렬 버스로 내부 신호 읽기/쓰기
- AFU ctrl이 직렬 → 병렬 변환
- `ADDR_SCP_0/1` 레지스터로 접근

**사용 예시**:
```c
// Scope 데이터 읽기
uint64_t scope_read() {
    // SCP_0, SCP_1 read → scope_bus_in으로 64-bit 수신
    uint32_t lo = read_reg(ADDR_SCP_0);
    uint32_t hi = read_reg(ADDR_SCP_1);
    return ((uint64_t)hi << 32) | lo;
}
```

### 7.2 ChipScope/ILA Integration

**조건부 컴파일**: `CHIPSCOPE` 정의 시

```systemverilog
ila_afu ila_afu_inst (
    .clk(clk),
    .probe0({ap_reset, ap_start, ap_done, ap_idle, state, interrupt}),
    .probe1({vx_pending_writes, vx_busy, vx_reset, dcr_wr_valid, ...})
);
```

**Vivado에서 실시간 디버깅**:
- Waveform 캡처
- Trigger 설정
- State machine 추적

### 7.3 DBG_TRACE_AFU

**시뮬레이션 디버그 출력** (`DBG_TRACE_AFU` 정의 시):

```systemverilog
`ifdef DBG_TRACE_AFU
    always @(posedge clk) begin
        if (m_axi_mem_awvalid_a[i] && m_axi_mem_awready_a[i]) begin
            `TRACE(2, ("%t: AXI Wr Req [%0d]: addr=0x%0h, id=0x%0h\n",
                $time, i, m_axi_mem_awaddr_a[i], m_axi_mem_awid_a[i]))
        end
        if (m_axi_mem_rvalid_a[i] && m_axi_mem_rready_a[i]) begin
            `TRACE(2, ("%t: AXI Rd Rsp [%0d]: data=0x%h, id=0x%0h\n",
                $time, i, m_axi_mem_rdata_a[i], m_axi_mem_rid_a[i]))
        end
    end
`endif
```

---

## 8. 설계 특징

### 8.1 장점

1. **표준 호환성**
   - Xilinx XRT RTL Kernel 표준 준수
   - Vitis IDE에서 직접 사용 가능

2. **메모리 일관성**
   - Pending writes 추적으로 완료 보장
   - ap_done은 모든 write 완료 후에만 assert

3. **모듈화**
   - AFU와 Vortex core 분리
   - 다른 플랫폼 지원 용이 (OPAE, simX 등)

4. **디버깅 지원**
   - Scope interface
   - ChipScope/ILA integration
   - Trace 출력

### 8.2 제약사항

1. **Single GPU Instance**
   - 하나의 AFU = 하나의 Vortex GPU
   - 다중 GPU는 다중 AFU 필요

2. **Synchronous Execution**
   - STATE_RUN 동안 새 명령 불가
   - 완료 후에만 다음 실행 가능

3. **Fixed Memory Banks**
   - 메모리 뱅크 수는 컴파일 타임 고정
   - 런타임 변경 불가

---

## 9. 관련 파일

### RTL 파일
- **vortex_afu.v**: Top-level Verilog wrapper
- **VX_afu_wrap.sv**: Main AFU logic (state machine, memory)
- **VX_afu_ctrl.sv**: AXI4-Lite control interface
- **vortex_afu.vh**: Macro definitions (AXI interface generation)

### Vortex Core
- **vortex_axi.sv**: Vortex GPU with AXI4 master interface
- **VX_cluster.sv** → **VX_socket.sv** → **VX_core.sv**: GPU hierarchy

### 기타 플랫폼
- **hw/rtl/afu/opae/**: Intel OPAE (Open Programmable Acceleration Engine) AFU
- **hw/rtl/afu/simx/**: Simulation wrapper

---

## 10. 요약

### AFU의 핵심 역할

| 계층 | 역할 | 기술 |
|------|------|------|
| **Host Interface** | 호스트 제어 | AXI4-Lite Slave |
| **Memory Interface** | 플랫폼 메모리 접근 | AXI4 Master (다중 뱅크) |
| **State Management** | GPU 라이프사이클 | IDLE/INIT/RUN/DONE FSM |
| **Synchronization** | 완료 보장 | Pending writes tracking |
| **Interrupt** | 비동기 알림 | ap_done interrupt |

### 실행 모델

```
┌──────────┐    AXI4-Lite    ┌────────────┐
│   Host   │◄───────────────►│  AFU Ctrl  │
│   (XRT)  │                 │  (Regs)    │
└─────┬────┘                 └──────┬─────┘
      │                             │
      │ ap_start                    │ dcr_wr_*
      │ ap_done                     │
      │                             ↓
      │                     ┌───────────────┐
      │                     │  AFU Wrap FSM │
      │                     │  (State Mgmt) │
      │                     └───────┬───────┘
      │                             │
      │                         vx_reset
      │                         vx_busy
      │                             ↓
      │ AXI4 (Memory)       ┌──────────────┐
      └────────────────────►│  Vortex GPU  │
                            │  (vortex_axi)│
                            └──────────────┘
```

AFU는 Vortex GPGPU를 FPGA 플랫폼의 **표준 가속기**로 만들어주는 핵심 인터페이스입니다!
