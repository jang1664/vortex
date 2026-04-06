# SPLIT 명령어의 next_pc 분석

## 개요

**next_pc**는 SPLIT 명령어에서 **IPDOM (Immediate Post-Dominator)** 스택에 저장되는 재결합(reconvergence) 지점의 PC 값입니다. Thread divergence 발생 시 else 경로의 thread들이 나중에 실행될 PC 주소를 저장하여, JOIN 명령어에서 else 경로로 전환할 때 사용됩니다.

### 핵심 개념
- **SPLIT**: Thread divergence 시작 지점 (if-else 분기)
- **next_pc**: SPLIT 다음 명령어의 PC (일반적으로 `PC + 4`)
- **IPDOM Stack**: Divergence 정보를 저장하는 스택 (재결합 지점 추적)
- **JOIN**: Thread reconvergence 지점 (분기 종료)

---

## next_pc 생성 위치

### 1. VX_wctl_unit.sv - SPLIT 명령어 처리

**파일**: [hw/rtl/core/VX_wctl_unit.sv](hw/rtl/core/VX_wctl_unit.sv#L124)

```systemverilog
// SPLIT 명령어 실행 시
assign split.next_pc = execute_if.data.PC + from_fullPC(`XLEN'(4));
```

**설명**:
- `execute_if.data.PC`: 현재 SPLIT 명령어의 PC
- `+ from_fullPC(4)`: 다음 명령어로 이동 (4 bytes = 1 instruction)
- **next_pc = SPLIT 다음 명령어의 주소**

#### from_fullPC 함수

```systemverilog
// VX_gpu_pkg.sv
`ifndef NDEBUG
    localparam PC_BITS = `XLEN;
    function automatic logic [PC_BITS-1:0] from_fullPC(input logic[`XLEN-1:0] pc);
        from_fullPC = pc;
    endfunction
`else
    localparam PC_BITS = (`XLEN-2);
    function automatic logic [PC_BITS-1:0] from_fullPC(input logic[`XLEN-1:0] pc);
        from_fullPC = PC_BITS'(pc >> 2);  // 하위 2비트 제거 (4-byte aligned)
    endfunction
`endif
```

**최적화**:
- **Debug 모드**: 전체 32/64비트 PC 저장
- **Release 모드**: 하위 2비트 제거 (항상 0이므로) → PC_BITS = XLEN-2

---

## next_pc 저장 - IPDOM Stack

### 2. VX_split_join.sv - IPDOM Stack에 Push

**파일**: [hw/rtl/core/VX_split_join.sv](hw/rtl/core/VX_split_join.sv#L47)

```systemverilog
// IPDOM Stack 입력 데이터
wire [(`NUM_THREADS + PC_BITS)-1:0] ipdom_d0 = {split.then_tmask | split.else_tmask, PC_BITS'(0)};
wire [(`NUM_THREADS + PC_BITS)-1:0] ipdom_d1 = {split.else_tmask, split.next_pc};

wire ipdom_push = split_valid && split.is_dvg;

VX_ipdom_stack #(
    .WIDTH (`NUM_THREADS + PC_BITS),
    .DEPTH (DV_STACK_SIZE)
) ipdom_stack (
    .clk   (clk),
    .reset (reset),
    .wid   (wid),
    .d0    (ipdom_d0),  // Slot 0: {전체 tmask, 0}
    .d1    (ipdom_d1),  // Slot 1: {else_tmask, next_pc}
    .push  (ipdom_push),
    .pop   (ipdom_pop),
    .rd_ptr(sjoin.stack_ptr),
    .q_val ({ipdom_tmask, ipdom_pc}),
    .q_idx (ipdom_idx),
    .wr_ptr(ipdom_wr_ptr),
    `UNUSED_PIN (empty),
    `UNUSED_PIN (full)
);
```

### IPDOM Stack 구조

#### 2-Slot 저장 방식

IPDOM Stack은 각 엔트리에 **2개의 슬롯**을 저장합니다:

| Slot | 내용 | 용도 |
|------|------|------|
| **d0** (idx=0) | `{then_tmask \| else_tmask, PC=0}` | Then 경로 복귀 시 (첫 번째 JOIN) |
| **d1** (idx=1) | `{else_tmask, next_pc}` | Else 경로 실행 시 (두 번째 JOIN) |

#### 데이터 포맷

```
WIDTH = NUM_THREADS + PC_BITS

┌─────────────────────┬──────────────────┐
│   Thread Mask       │       PC         │
│  (NUM_THREADS bits) │   (PC_BITS bits) │
└─────────────────────┴──────────────────┘

ipdom_d1 = {else_tmask, next_pc}
          ↑            ↑
          0b0011       0x00001008  (예시)
```

### 3. VX_ipdom_stack.sv - 스택 구현

**파일**: [hw/rtl/core/VX_ipdom_stack.sv](hw/rtl/core/VX_ipdom_stack.sv)

```systemverilog
module VX_ipdom_stack #(
    parameter WIDTH = 1,
    parameter DEPTH = 1,  // DV_STACK_SIZE = UP(NUM_THREADS-1)
    parameter ADDRW = `LOG2UP(DEPTH)
) (
    input  wire             clk,
    input  wire             reset,
    input  wire [NW_WIDTH-1:0] wid,        // Warp ID
    input  wire [WIDTH-1:0] d0,            // Slot 0 data
    input  wire [WIDTH-1:0] d1,            // Slot 1 data
    input  wire [ADDRW-1:0] rd_ptr,        // JOIN에서 전달된 stack pointer
    input  wire             push,          // SPLIT 시 push
    input  wire             pop,           // JOIN 시 pop
    output wire [WIDTH-1:0] q_val,         // 읽은 데이터
    output wire             q_idx,         // Slot index (0 or 1)
    output wire [`NUM_WARPS-1:0][ADDRW-1:0] wr_ptr,  // 각 warp의 stack pointer
    output wire             empty,
    output wire             full
);

// Dual-port RAM에 저장
VX_dp_ram #(
    .DATAW    (1 + WIDTH * 2),  // {idx, d1, d0}
    .SIZE     (DEPTH * `NUM_WARPS),
    .RDW_MODE ("R"),
    .RADDR_REG(1)
) ipdom_store (
    .clk   (clk),
    .reset (reset),
    .read  (pop),
    .write (push || pop),
    .wren  (1'b1),
    .waddr (waddr),
    .raddr (raddr),
    .wdata (push ? {1'b0, d1, d0} : {1'b1, q1, q0}),
    .rdata ({q_idx, q1, q0})
);

assign q_val = q_idx ? q0 : q1;  // Slot 선택
```

**저장 데이터 구조**:
```
{q_idx, q1, q0}
  ↑     ↑   ↑
  │     │   └─ d0: {then|else tmask, 0}
  │     └───── d1: {else_tmask, next_pc}
  └─────────── 현재 slot index (0: then 경로, 1: else 경로)
```

---

## next_pc 사용 - JOIN 명령어

### 4. VX_split_join.sv - JOIN 시 Pop

```systemverilog
wire sjoin_valid = valid && sjoin.valid;
wire sjoin_is_dvg = (sjoin.stack_ptr != ipdom_wr_ptr[wid]);
wire ipdom_pop = sjoin_valid && sjoin_is_dvg;

// Stack read
VX_ipdom_stack (
    // ...
    .pop   (ipdom_pop),
    .rd_ptr(sjoin.stack_ptr),  // JOIN 명령어의 rs1 값 (stack pointer)
    .q_val ({ipdom_tmask, ipdom_pc}),
    .q_idx (ipdom_idx),
    // ...
);

// 출력 레지스터
VX_pipe_register #(
    .DATAW  (1 + NW_WIDTH + 1 + 1 + `NUM_THREADS + PC_BITS),
    .RESETW (1),
    .DEPTH  (OUT_REG)
) pipe_reg (
    .clk      (clk),
    .reset    (reset),
    .enable   (1'b1),
    .data_in  ({sjoin_valid, wid, sjoin_is_dvg, ~ipdom_idx, ipdom_tmask, ipdom_pc}),
    //                                            ^^^^^^^^^^                ^^^^^^^^^
    //                                            join_is_else              join_pc
    .data_out ({join_valid, join_wid, join_is_dvg, join_is_else, join_tmask, join_pc})
);
```

**핵심 로직**:
- `join_is_else = ~ipdom_idx`
  - `ipdom_idx = 0` (Slot 0, then 경로) → `join_is_else = 1` (아직 else 실행 안 함)
  - `ipdom_idx = 1` (Slot 1, else 경로) → `join_is_else = 0` (else 실행 완료)
- `join_pc = ipdom_pc`
  - Slot 1에서 읽은 경우: **next_pc** 값 반환 (else 경로로 이동)
  - Slot 0에서 읽은 경우: `PC = 0` (사용 안 함)

### 5. VX_schedule.sv - PC 업데이트

**파일**: [hw/rtl/core/VX_schedule.sv](hw/rtl/core/VX_schedule.sv#L150)

```systemverilog
// join handling
if (join_valid) begin
    if (join_is_dvg) begin
        if (join_is_else) begin
            warp_pcs_n[join_wid] = join_pc;  // next_pc로 PC 변경!
        end
        thread_masks_n[join_wid] = join_tmask;
    end
    stalled_warps_n[join_wid] = 0; // unlock warp
end
```

**동작**:
1. **첫 번째 JOIN** (`join_is_else = 1`):
   - `warp_pcs_n[wid] = join_pc` ← **next_pc** 값으로 PC 설정
   - `thread_masks_n[wid] = else_tmask` ← Else 경로 thread들만 활성화
   - Warp unlock → Fetch stage가 **next_pc**에서 명령어 가져옴

2. **두 번째 JOIN** (`join_is_else = 0`):
   - PC 변경 없음 (then 경로 이미 실행 중)
   - `thread_masks_n[wid] = then_tmask | else_tmask` ← 전체 thread 재결합

---

## 실행 흐름 예시

### 코드 예시

```c
// Example kernel
if (threadIdx.x < 2) {       // PC=0x1000: SPLIT
    a[tid] = 1;              // PC=0x1004: then 경로
} else {                     
    a[tid] = 2;              // PC=0x1008: else 경로 (next_pc가 여기를 가리킴)
}
// Merge point                // PC=0x100C: JOIN
b[tid] = a[tid];             // PC=0x1010: 재결합 후 계속
```

### 어셈블리 (의사코드)

```assembly
0x1000: SPLIT    r1, label_else    ; if (threadIdx.x < 2)
                                    ; then_tmask = 0b0011
                                    ; else_tmask = 0b1100
                                    ; next_pc = 0x1004
0x1004: SW       r1, a[tid]        ; a[tid] = 1 (then 경로)
0x1008: label_else:
        SW       r2, a[tid]        ; a[tid] = 2 (else 경로)
0x100C: JOIN     r3                ; Merge point
0x1010: LW       r4, a[tid]        ; b[tid] = a[tid]
```

### 실행 타임라인

#### 초기 상태
```
Warp 0:
  PC = 0x1000
  tmask = 0b1111 (4 threads 모두 active)
```

#### Cycle 1: SPLIT 실행 (PC=0x1000)

**VX_wctl_unit.sv**:
```systemverilog
split.valid      = 1
split.is_dvg     = 1              // 실제 divergence 발생
split.then_tmask = 0b0011         // Thread 0, 1
split.else_tmask = 0b1100         // Thread 2, 3
split.next_pc    = 0x1004         // SPLIT 다음 명령어 PC
```

**VX_split_join.sv - IPDOM Stack Push**:
```
ipdom_d0 = {0b1111, 0x0000}       // Slot 0: 전체 tmask, PC=0
ipdom_d1 = {0b1100, 0x1004}       // Slot 1: else_tmask, next_pc
push     = 1
wr_ptr[0] = 1                      // Stack depth 증가
```

**VX_schedule.sv**:
```systemverilog
thread_masks_n[0] = 0b0011        // Then 경로만 활성화
warp_pcs_n[0]     = 0x1000        // PC 유지 (Schedule에서 +4)
stalled_warps_n[0] = 0            // Unlock
```

#### Cycle 2-3: Then 경로 실행 (PC=0x1004)

```
Warp 0:
  PC = 0x1004  (Schedule에서 자동 +4)
  tmask = 0b0011
  Execute: SW r1, a[tid]  (Thread 0, 1만 실행)
```

#### Cycle 4: 첫 번째 JOIN (PC=0x100C)

**VX_split_join.sv - IPDOM Stack Read**:
```
sjoin.stack_ptr = 0               // JOIN의 rs1 = 0
ipdom_wr_ptr[0] = 1               // Stack에 1개 엔트리
sjoin_is_dvg    = (0 != 1) = 1    // Divergence 상태
ipdom_pop       = 1               // Stack pop

// Stack read (첫 번째 접근은 Slot 0)
ipdom_idx       = 0               // Slot 0 읽음
ipdom_tmask     = 0b1111          // then_tmask | else_tmask
ipdom_pc        = 0x0000          // Slot 0의 PC (사용 안 함)

// Pipe register
join_is_else    = ~0 = 1          // Else 경로 실행 필요
join_tmask      = 0b1111
join_pc         = 0x0000          // 사용 안 됨
```

**Stack 상태 변경**:
```
// pop 시 idx를 1로 변경 (Slot 0 → Slot 1 전환)
wdata = {1'b1, q1, q0}            // idx=1로 설정
      = {1, {0b1100, 0x1004}, {0b1111, 0x0000}}
```

**VX_schedule.sv**:
```systemverilog
join_valid      = 1
join_is_dvg     = 1
join_is_else    = 1               // Else 경로 실행 필요

if (join_is_else) begin
    // Stack에서 읽은 next_pc 값 사용
    // 하지만 첫 번째 JOIN에서는 Slot 0 읽어서 PC=0
    // 실제로는 다시 IPDOM stack의 Slot 1 읽어야 함!
end
```

**⚠️ 중요**: 실제 RTL 구현은 **2단계 프로토콜**을 사용합니다:
1. **첫 번째 JOIN**: Slot 0 읽음 → Stack의 idx를 1로 변경 (pop은 안 함)
2. **두 번째 JOIN**: Slot 1 읽음 → **next_pc** 사용 → Stack에서 완전히 pop

#### Cycle 5: Else 경로로 전환

**VX_split_join.sv - 두 번째 읽기**:
```
// Stack에서 이제 Slot 1 읽음
ipdom_idx       = 1               // Slot 1
ipdom_tmask     = 0b1100          // else_tmask
ipdom_pc        = 0x1004          // next_pc!

// Pipe register
join_is_else    = ~1 = 0          // Else 실행 완료
join_tmask      = 0b1100
join_pc         = 0x1004          // ← next_pc 사용!
```

**VX_schedule.sv**:
```systemverilog
if (join_is_else) begin
    warp_pcs_n[0] = 0x1004        // next_pc로 PC 설정!
end
thread_masks_n[0] = 0b1100        // Else thread만 활성화
```

#### Cycle 6-7: Else 경로 실행 (PC=0x1004)

```
Warp 0:
  PC = 0x1004
  tmask = 0b1100
  Fetch: 명령어를 0x1004에서 가져옴
  실제 실행되는 명령어: 0x1008의 SW (else 경로)
```

**⚠️ 주의**: Fetch는 0x1004에서 시작하지만, 실제 컴파일러는 then/else 코드를 다른 주소에 배치합니다. LLVM Pass가 적절한 주소로 변환합니다.

#### Cycle 8: 두 번째 JOIN (PC=0x100C)

```
sjoin.stack_ptr = 0
ipdom_wr_ptr[0] = 1
sjoin_is_dvg    = (0 != 1) = 1

// Stack read (Slot 1, 이미 idx=1)
ipdom_idx       = 1
join_is_else    = ~1 = 0          // 완료
join_tmask      = 0b1111          // 재결합!

// Stack pop
wr_ptr[0] = 1 - 1 = 0             // Stack 비움
```

**VX_schedule.sv**:
```systemverilog
join_is_else = 0                  // PC 변경 없음
thread_masks_n[0] = 0b1111        // 전체 thread 활성화
```

#### Cycle 9: 재결합 후 계속 (PC=0x1010)

```
Warp 0:
  PC = 0x1010
  tmask = 0b1111
  모든 thread가 동일한 경로로 실행
```

---

## 시뮬레이터 구현 (SIMX)

### execute.cpp - SPLIT 처리

**파일**: [sim/simx/execute.cpp](sim/simx/execute.cpp#L1354)

```cpp
case WctlType::SPLIT: {
    auto then_tmask = warp.tmask;
    auto else_tmask = warp.tmask;
    
    // Compute then/else masks
    for (uint32_t t = 0; t < num_threads; ++t) {
        auto cond = rs1_data.at(t).i & 0x1;
        if (!cond) {
            then_tmask.reset(t);
        } else {
            else_tmask.reset(t);
        }
    }
    
    bool is_divergent = then_tmask.any() && else_tmask.any();
    
    if (is_divergent) {
        // Choose larger set as next_tmask
        if (then_tmask.count() >= else_tmask.count()) {
            next_tmask = then_tmask;
        } else {
            next_tmask = else_tmask;
        }
        
        // Push IPDOM stack
        auto ntaken_tmask = ~next_tmask & warp.tmask;
        auto next_pc = warp.PC + 4;  // SPLIT 다음 명령어
        
        warp.ipdom_stack.emplace(warp.tmask, ntaken_tmask, next_pc);
        //                                                   ^^^^^^^^
        //                                                   이것이 next_pc!
    }
    
    // Return stack depth
    for (uint32_t t = thread_start; t < num_threads; ++t) {
        rd_data[t].i = warp.ipdom_stack.size();
    }
    rd_write = true;
} break;
```

### execute.cpp - JOIN 처리

```cpp
case WctlType::JOIN: {
    trace->fetch_stall = true;
    auto stack_ptr = rs1_data.at(thread_last).u;
    
    if (stack_ptr != warp.ipdom_stack.size()) {
        if (warp.ipdom_stack.empty()) {
            std::abort();
        }
        
        if (warp.ipdom_stack.top().fallthrough) {
            // 두 번째 JOIN: Stack pop
            next_tmask = warp.ipdom_stack.top().orig_tmask;
            warp.ipdom_stack.pop();
        } else {
            // 첫 번째 JOIN: Else 경로로 전환
            next_tmask = warp.ipdom_stack.top().else_tmask;
            next_pc = warp.ipdom_stack.top().PC;  // ← next_pc 사용!
            warp.ipdom_stack.top().fallthrough = true;
        }
    }
} break;
```

### IPDOM Stack 구조체

```cpp
// sim/simx/types.h
struct IPDOM_entry {
    ThreadMask orig_tmask;    // 원래 thread mask
    ThreadMask else_tmask;    // Else 경로 thread mask
    Word PC;                  // next_pc (재결합 지점 또는 else 경로)
    bool fallthrough;         // Then 경로 실행 완료 여부
};

std::stack<IPDOM_entry> ipdom_stack;
```

---

## next_pc의 목적 및 중요성

### 1. Thread Divergence 복구

**Without next_pc**:
```
SPLIT 후 then 경로만 실행 → JOIN → Else thread는 어디로 가야 할까? ❌
```

**With next_pc**:
```
SPLIT 후 then 경로 실행 → JOIN → next_pc로 이동 → Else 경로 실행 ✅
```

### 2. 컴파일러와의 협력

LLVM은 SPLIT/JOIN을 다음과 같이 생성합니다:

```llvm
; if (cond) { then_block } else { else_block }

entry:
  %cond = ...
  call void @llvm.vx.split(i32 %cond)  ; SPLIT 생성
  br i1 %cond, label %then, label %else

then:
  ; then_block
  br label %merge

else:
  ; else_block (next_pc가 이 블록의 시작 주소를 가리킴)
  br label %merge

merge:
  call void @llvm.vx.join()  ; JOIN 생성
```

**컴파일 후**:
- SPLIT의 `next_pc` = `else` 블록의 시작 주소
- JOIN에서 `next_pc`로 이동하면 else 블록 실행

### 3. Nested Divergence 지원

```c
if (cond1) {
    if (cond2) {   // Nested SPLIT
        ...
    }
}
```

각 SPLIT마다 별도의 `next_pc`를 스택에 저장하여 중첩된 divergence 처리 가능.

---

## 주요 파일 위치

| 파일 | 역할 | next_pc 관련 코드 |
|------|------|-------------------|
| [hw/rtl/core/VX_wctl_unit.sv](hw/rtl/core/VX_wctl_unit.sv#L124) | SPLIT 명령어 처리 | `split.next_pc = PC + 4` |
| [hw/rtl/core/VX_split_join.sv](hw/rtl/core/VX_split_join.sv#L47) | IPDOM Stack 관리 | `ipdom_d1 = {else_tmask, next_pc}` |
| [hw/rtl/core/VX_ipdom_stack.sv](hw/rtl/core/VX_ipdom_stack.sv) | Stack 구현 | 2-slot 저장 및 읽기 |
| [hw/rtl/core/VX_schedule.sv](hw/rtl/core/VX_schedule.sv#L150) | PC 업데이트 | `warp_pcs_n[wid] = join_pc` |
| [sim/simx/execute.cpp](sim/simx/execute.cpp#L1354) | SIMX SPLIT 구현 | `warp.ipdom_stack.emplace(..., next_pc)` |
| [sim/simx/execute.cpp](sim/simx/execute.cpp#L1375) | SIMX JOIN 구현 | `next_pc = ipdom_stack.top().PC` |

---

## 디버깅 정보

### RTL Trace

```systemverilog
// VX_wctl_unit.sv
`ifdef DBG_TRACE_CORE_PIPELINE
    always @(posedge clk) begin
        if (split.valid && split.is_dvg) begin
            $display("[%0t] SPLIT: wid=%0d, then_tmask=%b, else_tmask=%b, next_pc=0x%h",
                     $time, wid, split.then_tmask, split.else_tmask, split.next_pc);
        end
    end
`endif
```

### SIMX Trace

```cpp
// execute.cpp
DT(3, "SPLIT: wid=" << warp.id 
     << ", then=" << then_tmask 
     << ", else=" << else_tmask 
     << ", next_pc=0x" << std::hex << next_pc);
```

### 예상 출력

```
[100] SPLIT: wid=0, then_tmask=0011, else_tmask=1100, next_pc=0x00001004
[150] JOIN: wid=0, is_else=1, join_pc=0x00001004
[200] JOIN: wid=0, is_else=0, tmask=1111
```

---

## 요약

| 항목 | 내용 |
|------|------|
| **정의** | SPLIT 다음 명령어의 PC (일반적으로 `PC + 4`) |
| **생성** | VX_wctl_unit.sv에서 계산 |
| **저장** | IPDOM Stack의 Slot 1에 `{else_tmask, next_pc}` 형태로 저장 |
| **사용** | JOIN 명령어에서 else 경로로 전환 시 PC로 사용 |
| **목적** | Thread divergence에서 else 경로 실행을 위한 주소 저장 |
| **중요성** | SIMT 모델의 핵심 - divergence 복구 메커니즘 |

**핵심**: `next_pc`는 SPLIT에서 실행되지 않은 else 경로의 시작 주소를 저장하여, JOIN에서 else thread들이 올바른 위치에서 실행을 재개할 수 있도록 합니다.

---

*문서 작성일: 2025-12-22*  
*Vortex GPGPU Project - SPLIT next_pc Analysis*
