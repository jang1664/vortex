# Vortex 병렬성 아키텍처

## 1. 개요

Vortex는 SIMT (Single Instruction Multiple Thread) 실행 모델을 사용하는 GPGPU 아키텍처입니다. 다양한 레벨의 병렬성을 조합하여 높은 처리량을 달성합니다:

- **TLP (Thread Level Parallelism)**: 다수의 warp를 동시에 상주시켜 긴 레이턴시를 숨김
- **DLP (Data Level Parallelism)**: SIMT 레인을 통해 동일 명령을 다수의 thread에서 동시 실행
- **ILP (Instruction Level Parallelism)**: 다중 issue로 여러 warp의 명령을 동시에 issue

## 2. 계층적 병렬 구조

### 2.1 아키텍처 계층

```
GPU
 └─ Cluster [NUM_CLUSTERS]
     └─ Core [NUM_CORES]
         └─ Warp [NUM_WARPS]
             └─ Thread [NUM_THREADS]
```

#### 기본 설정값 (`VX_config.vh`)
```verilog
`define NUM_CLUSTERS    1
`define NUM_CORES       1  
`define NUM_WARPS       4    // core당 상주 warp 수
`define NUM_THREADS     4    // warp당 thread 수
```

### 2.2 SIMT 실행 모델

#### SIMD_WIDTH (SIMT Lane Width)
```verilog
// VX_config.vh
`define SIMD_WIDTH      `NUM_THREADS
```

- **의미**: 동일 명령을 동시 실행하는 SIMT 레인(thread) 수
- **기본값**: 4 (NUM_THREADS와 동일)
- **동작**: 하나의 warp가 실행되면 SIMD_WIDTH개의 thread가 같은 명령을 동시 처리
- **Thread Mask**: 각 thread는 개별적으로 enable/disable 가능 (분기 처리)

#### 예시
```
Warp 0 실행: ADD x1, x2, x3
→ Thread 0, 1, 2, 3이 각자의 레지스터로 동시에 ADD 수행
→ 4개의 ALU가 병렬 동작
```

## 3. Warp 스케줄링

### 3.1 Warp 상태 관리

`VX_schedule.sv`는 core 내 모든 warp의 상태를 추적합니다:

```verilog
// Warp state arrays
logic [`NUM_WARPS-1:0]             active_warps;   // 활성화된 warp
logic [`NUM_WARPS-1:0]             stalled_warps;  // stall된 warp
logic [`NUM_WARPS-1:0][`NUM_THREADS-1:0] thread_masks; // warp별 활성 thread
logic [`NUM_WARPS-1:0][PC_BITS-1:0] warp_pcs;      // warp별 PC
```

### 3.2 스케줄링 로직

#### 실행 가능한 Warp 선택
```verilog
// 실행 가능 조건: 활성화 && !stall && !barrier
assign schedule_valid = |(active_warps & ~stalled_warps & ~barrier_stalls);
```

**실행 불가 조건 (Stall)**:
1. **Decode stall**: 이전 명령이 decode 완료 전
2. **Barrier stall**: barrier 동기화 대기 중
3. **Dependency stall**: 데이터 의존성으로 인한 대기

#### Round-Robin 선택
```verilog
VX_lzc #(
    .N       (`NUM_WARPS),
    .REVERSE (1)
) schedule_select (
    .data_in   (schedule_mask),
    .data_out  (schedule_wid),
    .valid_out (schedule_valid)
);
```

- **알고리즘**: Leading-zero-count 기반 round-robin
- **공정성**: 모든 warp가 순차적으로 기회를 얻음
- **효율성**: 실행 가능한 warp 중 가장 우선순위 높은 것 선택

### 3.3 Warp 라이프사이클

```
1. [Spawn] wspawn 명령으로 warp 생성
   └─> active_warps[wid] = 1
       thread_masks[wid] = wspawn.wmask
       warp_pcs[wid] = wspawn.pc

2. [Schedule] 실행 가능한 warp 선택
   └─> active && !stalled && !barrier_stall

3. [Fetch] 명령 인출
   └─> schedule_if_fire: PC 전달

4. [Decode] 명령 디코드
   └─> stalled_warps[wid] = 1 (decode 완료까지)

5. [Issue] 명령 issue
   └─> stalled_warps[wid] = 0 (다음 명령 fetch 가능)

6. [Execute & Commit] 실행 및 완료
   └─> writeback을 통해 결과 저장

7. [Barrier/Branch] 제어 흐름 처리
   └─> barrier: barrier_stalls 업데이트
   └─> branch: warp_pcs 업데이트
   └─> split/join: 분기 divergence 처리
```

## 4. Issue 병렬성

### 4.1 ISSUE_WIDTH

```verilog
// VX_config.vh
`define ISSUE_WIDTH     `UP(`NUM_WARPS / 16)

// VX_gpu_pkg.sv
localparam PER_ISSUE_WARPS = `NUM_WARPS / `ISSUE_WIDTH;
localparam ISSUE_ISW_BITS = `CLOG2(`ISSUE_WIDTH);
localparam ISSUE_WIS_BITS = `CLOG2(PER_ISSUE_WARPS);
```

#### 의미
- **Issue 병렬도**: 한 사이클에 동시에 issue 가능한 명령 수
- **파이프라인 처리량**: Issue 단계의 처리 대역폭
- **기본값**: UP(NUM_WARPS / 16) = UP(4/16) = 1

### 4.2 Warp ID 매핑

Warp ID는 두 부분으로 분할됩니다:

```verilog
wid = {wis, isw}
  - isw: Issue Slice Width (하위 ISSUE_ISW_BITS 비트)
  - wis: Warp-In-Slice (상위 ISSUE_WIS_BITS 비트)

// 예: ISSUE_WIDTH=2, NUM_WARPS=8
// wid=0 → isw=0, wis=0
// wid=1 → isw=1, wis=0
// wid=2 → isw=0, wis=1
// wid=3 → isw=1, wis=1
// wid=4 → isw=0, wis=2
// ...
```

#### 매핑 함수
```verilog
// wid → isw 변환 (어느 issue slice에 속하는가)
function automatic logic [ISSUE_ISW_W-1:0] wid_to_isw(
    input logic [NW_WIDTH-1:0] wid
);
    if (ISSUE_ISW_BITS != 0) begin
        wid_to_isw = wid[ISSUE_ISW_W-1:0];
    end else begin
        wid_to_isw = 0;
    end
endfunction

// wid → wis 변환 (slice 내 몇 번째 warp인가)
function automatic logic [ISSUE_WIS_W-1:0] wid_to_wis(
    input logic [NW_WIDTH-1:0] wid
);
    if (ISSUE_WIS_BITS != 0) begin
        wid_to_wis = ISSUE_WIS_W'(wid >> ISSUE_ISW_BITS);
    end else begin
        wid_to_wis = 0;
    end
endfunction

// {wis, isw} → wid 복원
function automatic logic [NW_WIDTH-1:0] wis_to_wid(
    input logic [ISSUE_WIS_W-1:0] wis,
    input logic [ISSUE_ISW_W-1:0] isw
);
    if (ISSUE_WIS_BITS == 0) begin
        wis_to_wid = NW_WIDTH'(isw);
    end else if (ISSUE_ISW_BITS == 0) begin
        wis_to_wid = NW_WIDTH'(wis);
    end else begin
        wis_to_wid = NW_WIDTH'({wis, isw});
    end
endfunction
```

### 4.3 Issue 동작

`VX_issue.sv`는 decode된 명령을 ISSUE_WIDTH개의 slice로 분배합니다:

```verilog
wire [ISSUE_ISW_W-1:0] decode_isw = wid_to_isw(decode_if.data.wid);

// decode_if를 해당하는 issue slice로 라우팅
VX_issue_slice #(
    .INSTANCE_ID ($sformatf("%s-issue%0d", INSTANCE_ID, i)),
    .ISSUE_ID    (i)
) issue_slice (
    .decode_if     (per_issue_decode_if[i]),
    .writeback_if  (writeback_if[i]),
    .dispatch_if   (dispatch_if[i * NUM_EX_UNITS +: NUM_EX_UNITS]),
    .issue_sched_if(issue_sched_if[i])
);
```

#### 처리 흐름
```
1. Decode에서 명령 도착 (wid 포함)
2. isw = wid_to_isw(wid) 계산
3. 해당 issue slice[isw]로 명령 전달
4. Issue slice는 scoreboard 체크 및 operand read 수행
5. Dispatch stage로 전달
```

### 4.4 Multi-Issue 효과

#### ISSUE_WIDTH=1 (기본 설정)
```
Cycle 0: Warp 0 issue
Cycle 1: Warp 1 issue
Cycle 2: Warp 2 issue
Cycle 3: Warp 3 issue
```

#### ISSUE_WIDTH=2 (NUM_WARPS=8 가정)
```
Cycle 0: Warp 0 (isw=0) + Warp 1 (isw=1) 동시 issue
Cycle 1: Warp 2 (isw=0) + Warp 3 (isw=1) 동시 issue
Cycle 2: Warp 4 (isw=0) + Warp 5 (isw=1) 동시 issue
```

**장점**:
- Issue 단계 처리량 증가
- Scoreboard/Operand read 병렬화
- 전체 파이프라인 utilization 향상

**제약**:
- 각 issue slice는 독립적인 scoreboard 관리
- PER_ISSUE_WARPS = NUM_WARPS / ISSUE_WIDTH 만큼의 warp만 추적

## 5. Execution Unit 병렬성

### 5.1 개요

Vortex의 각 Execution Unit (ALU, FPU, LSU, SFU, VPU, TCU)은 두 가지 차원의 병렬성을 가집니다:

1. **LANES (레인 병렬성)**: SIMT 모델에 따른 데이터 병렬성 - 한 warp 내 여러 threads를 동시 처리
2. **BLOCKS (블록 병렬성)**: Issue 병렬성 - 여러 warps의 명령을 동시 처리

#### 기본 구조
```
Execution Unit (예: ALU)
 ├─ Block 0 [NUM_ALU_BLOCKS]
 │   ├─ Lane 0 [NUM_ALU_LANES]
 │   ├─ Lane 1
 │   ├─ Lane 2
 │   └─ Lane 3
 └─ Block 1
     ├─ Lane 0
     ├─ Lane 1
     ├─ Lane 2
     └─ Lane 3
```

### 5.2 NUM_*_LANES (레인 수)

**의미**: 한 블록 내에서 동시에 처리할 수 있는 SIMT 레인(thread) 수

**설정값** (`VX_config.vh`):
```verilog
// 대부분의 execution units는 SIMD_WIDTH와 동일
`ifndef NUM_ALU_LANES
`define NUM_ALU_LANES   `SIMD_WIDTH   // = NUM_THREADS (기본 4)
`endif

`ifndef NUM_FPU_LANES
`define NUM_FPU_LANES   `SIMD_WIDTH   // = NUM_THREADS (기본 4)
`endif

`ifndef NUM_LSU_LANES
`define NUM_LSU_LANES   `SIMD_WIDTH   // = NUM_THREADS (기본 4)
`endif

`ifndef NUM_SFU_LANES
`define NUM_SFU_LANES   `SIMD_WIDTH   // = NUM_THREADS (기본 4)
`endif

`ifndef NUM_VPU_LANES
`define NUM_VPU_LANES   `SIMD_WIDTH   // = NUM_THREADS (기본 4)
`endif

// TCU는 NUM_THREADS 고정
`define NUM_TCU_LANES   `NUM_THREADS  // (기본 4)
```

**동작**:
- 하나의 warp가 execution unit에 도착하면 NUM_LANES개의 processing element가 병렬 실행
- 각 lane은 warp 내의 한 thread를 담당
- Thread mask로 비활성 thread는 skip 가능

**예시** (NUM_ALU_LANES=4):
```
Warp 0: ADD x1, x2, x3
→ Lane 0: Thread 0의 x1 = x2 + x3
   Lane 1: Thread 1의 x1 = x2 + x3
   Lane 2: Thread 2의 x1 = x2 + x3
   Lane 3: Thread 3의 x1 = x2 + x3
→ 4개 연산이 1 사이클에 완료
```

### 5.3 NUM_*_BLOCKS (블록 수)

**의미**: 동시에 처리할 수 있는 독립적인 execution unit 블록 수

**설정값** (`VX_config.vh`):
```verilog
// ALU, FPU, VPU, TCU는 ISSUE_WIDTH와 동일
`ifndef NUM_ALU_BLOCKS
`define NUM_ALU_BLOCKS  `ISSUE_WIDTH  // (기본 1)
`endif

`ifndef NUM_FPU_BLOCKS
`define NUM_FPU_BLOCKS  `ISSUE_WIDTH  // (기본 1)
`endif

`ifndef NUM_VPU_BLOCKS
`define NUM_VPU_BLOCKS  `ISSUE_WIDTH  // (기본 1)
`endif

`ifndef NUM_TCU_BLOCKS
`define NUM_TCU_BLOCKS  `ISSUE_WIDTH  // (기본 1)
`endif

// LSU와 SFU는 1로 고정 (병렬화 제약)
`ifndef NUM_LSU_BLOCKS
`define NUM_LSU_BLOCKS  1
`endif

`define NUM_SFU_BLOCKS  1
```

**동작**:
- 각 블록은 독립적인 execution unit pipeline
- NUM_BLOCKS > 1이면 서로 다른 warps의 명령을 동시에 실행 가능
- Issue stage에서 warp를 블록에 분배

**예시** (NUM_ALU_BLOCKS=2, NUM_ALU_LANES=4):
```
Cycle N:
  Block 0: Warp 0의 ADD 실행 (4 lanes)
  Block 1: Warp 1의 SUB 실행 (4 lanes)
→ 8개 연산이 동시 진행
```

### 5.4 각 Execution Unit별 특성

#### ALU (Arithmetic Logic Unit)
```verilog
NUM_ALU_LANES  = SIMD_WIDTH (기본 4)
NUM_ALU_BLOCKS = ISSUE_WIDTH (기본 1)
```
- **용도**: 정수 연산 (ADD, SUB, AND, OR, XOR, Shift 등)
- **특성**: 
  - 가장 빈번히 사용되는 unit
  - BLOCKS를 늘리면 다중 warp의 정수 연산 병렬 처리
  - Latency: 1 사이클
- **병렬도**: BLOCKS × LANES = 1 × 4 = 4 ops/cycle

#### FPU (Floating-Point Unit)
```verilog
NUM_FPU_LANES  = SIMD_WIDTH (기본 4)
NUM_FPU_BLOCKS = ISSUE_WIDTH (기본 1)
```
- **용도**: 부동소수점 연산 (FADD, FMUL, FMA, FDIV, FSQRT 등)
- **특성**:
  - Multi-cycle latency (FMA: 4-16 cycles, FDIV: 15-28 cycles)
  - Pipelined execution
  - BLOCKS 증가로 FP-intensive workload 가속
- **병렬도**: BLOCKS × LANES = 1 × 4 = 4 ops/cycle (issue)

#### LSU (Load-Store Unit)
```verilog
NUM_LSU_LANES  = SIMD_WIDTH (기본 4)
NUM_LSU_BLOCKS = 1 (고정)
```
- **용도**: 메모리 load/store 연산
- **특성**:
  - **BLOCKS=1 고정 이유**: D-cache 접근 충돌 방지
  - LANES로만 병렬화 (coalesced memory access)
  - Multi-cycle latency (cache hit: ~10 cycles, miss: 100+ cycles)
- **병렬도**: 1 × LANES = 4 memory ops/cycle
- **LSU_LINE_SIZE**: `MIN(NUM_LSU_LANES * (XLEN/8), L1_LINE_SIZE)`

#### SFU (Special Function Unit)
```verilog
NUM_SFU_LANES  = SIMD_WIDTH (기본 4)
NUM_SFU_BLOCKS = 1 (고정)
```
- **용도**: Warp control (TMC, WSPAWN, SPLIT, JOIN, PRED, BAR), CSR 연산
- **특성**:
  - **BLOCKS=1 고정 이유**: Warp 상태는 전역적으로 관리 (VX_schedule)
  - 병렬화 불필요 (warp-level operation)
  - TMC/PRED만 thread-level 연산 → LANES 사용
- **병렬도**: 1 block만 존재

#### VPU (Vector Processing Unit)
```verilog
NUM_VPU_LANES  = SIMD_WIDTH (기본 4)
NUM_VPU_BLOCKS = ISSUE_WIDTH (기본 1)
```
- **용도**: RISC-V Vector Extension (EXT_V_ENABLE)
- **특성**:
  - Vector register 연산
  - BLOCKS 증가로 다중 warp의 vector 연산 병렬화
- **병렬도**: BLOCKS × LANES ops/cycle

#### TCU (Tensor Core Unit)
```verilog
NUM_TCU_LANES  = NUM_THREADS (기본 4)
NUM_TCU_BLOCKS = ISSUE_WIDTH (기본 1)
```
- **용도**: Tensor/Matrix 연산 (EXT_TCU_ENABLE)
- **특성**:
  - 행렬 곱셈 가속
  - LANES는 NUM_THREADS 고정 (SIMD_WIDTH와 다를 수 있음)
  - BLOCKS 증가로 병렬 tensor 연산

### 5.5 병렬성 계산

#### 총 Execution 병렬도
```
각 Unit별 병렬도 = NUM_*_BLOCKS × NUM_*_LANES

예: 기본 설정 (ISSUE_WIDTH=1, SIMD_WIDTH=4)
- ALU: 1 × 4 = 4 ops/cycle
- FPU: 1 × 4 = 4 ops/cycle
- LSU: 1 × 4 = 4 ops/cycle
- SFU: 1 × 4 = 4 ops/cycle (실제로는 warp-level)

총 병렬도 (이론적): 16 ops/cycle (각 unit 동시 사용 시)
```

#### 확장 예시 (ISSUE_WIDTH=2, SIMD_WIDTH=8)
```
NUM_ALU_BLOCKS = 2, NUM_ALU_LANES = 8
→ ALU 병렬도 = 2 × 8 = 16 ops/cycle

NUM_FPU_BLOCKS = 2, NUM_FPU_LANES = 8
→ FPU 병렬도 = 2 × 8 = 16 ops/cycle

NUM_LSU_BLOCKS = 1 (고정), NUM_LSU_LANES = 8
→ LSU 병렬도 = 1 × 8 = 8 ops/cycle
```

### 5.6 LANES vs BLOCKS 트레이드오프

#### LANES 증가 (NUM_THREADS 증가)
**장점**:
- 데이터 병렬성 향상 (벡터/배열 연산 가속)
- 단일 warp의 throughput 증가
- 메모리 coalescing 효율 향상

**단점**:
- 하드웨어 면적 증가 (각 lane마다 ALU/FPU 필요)
- 레지스터 파일 크기 증가 (NUM_WARPS × NUM_THREADS × 32 registers)
- Thread divergence 시 낭비 증가

**적합한 경우**: 벡터 연산, 정규 메모리 접근 패턴

#### BLOCKS 증가 (ISSUE_WIDTH 증가)
**장점**:
- 다중 warp 병렬 처리로 throughput 증가
- Latency hiding 능력 향상
- 다양한 workload 동시 실행 가능

**단점**:
- Issue stage 복잡도 증가 (scoreboard, operand collector 복제)
- Warp 수 증가 필요 (NUM_WARPS >= ISSUE_WIDTH × 16 권장)
- LSU/SFU는 제약 (BLOCKS=1 고정)

**적합한 경우**: 높은 warp count, 다양한 instruction mix

### 5.7 설계 가이드라인

#### 1. 균형 잡힌 설정
```verilog
NUM_THREADS = 4-8    // 적당한 데이터 병렬성
NUM_WARPS   = 16-32  // 충분한 latency hiding
ISSUE_WIDTH = 1-2    // Issue throughput
→ LANES = 4-8, BLOCKS = 1-2
```

#### 2. 데이터 병렬 최적화
```verilog
NUM_THREADS = 16-32  // 높은 SIMT width
NUM_WARPS   = 8-16   // 적은 warp count
ISSUE_WIDTH = 1      // 단일 issue
→ LANES = 16-32, BLOCKS = 1
```

#### 3. Latency Hiding 최적화
```verilog
NUM_THREADS = 4      // 적은 thread count
NUM_WARPS   = 32-64  // 많은 warp count
ISSUE_WIDTH = 2-4    // 다중 issue
→ LANES = 4, BLOCKS = 2-4
```

#### 4. 면적 제약 설정
```verilog
NUM_THREADS = 2-4    // 최소 SIMT
NUM_WARPS   = 4-8    // 최소 warp
ISSUE_WIDTH = 1      // 단일 issue
→ LANES = 2-4, BLOCKS = 1
```

## 6. 병렬성 분석

### 6.1 TLP (Thread Level Parallelism)

#### Core당 동시 상주 Warp 수
```verilog
`define NUM_WARPS 4  // 기본값
```

- **의미**: Core 하나에 4개의 warp가 상주
- **효과**: 긴 레이턴시 (메모리 접근, 분기 등) 숨김
- **메커니즘**: 한 warp가 stall되면 다른 warp가 즉시 실행

#### 예시: 메모리 레이턴시 숨기기
```
Cycle 0: Warp 0 Load 명령 issue → stalled_warps[0] = 1
Cycle 1: Warp 1 Add 명령 issue
Cycle 2: Warp 2 Mul 명령 issue
Cycle 3: Warp 3 Sub 명령 issue
Cycle 4: Warp 0 Load 완료 → stalled_warps[0] = 0
```

### 6.2 DLP (Data Level Parallelism)

#### Warp당 Thread 수
```verilog
`define NUM_THREADS 4  // 기본값
`define SIMD_WIDTH  4  // NUM_THREADS와 동일
```

- **의미**: 하나의 warp가 4개의 thread를 동시 실행
- **효과**: 벡터/배열 연산을 병렬 처리
- **메커니즘**: NUM_*_LANES개의 ALU/FPU가 동일 명령을 다른 데이터로 수행

#### 예시: 벡터 덧셈
```c
// a[0:3] + b[0:3] = c[0:3]
Warp 0 실행: ADD c, a, b
→ Lane 0/Thread 0: c[0] = a[0] + b[0]
   Lane 1/Thread 1: c[1] = a[1] + b[1]
   Lane 2/Thread 2: c[2] = a[2] + b[2]
   Lane 3/Thread 3: c[3] = a[3] + b[3]
→ NUM_ALU_LANES(4)개 덧셈이 1 사이클에 완료
```

### 6.3 ILP (Instruction Level Parallelism)

#### Issue 병렬도
```verilog
`define ISSUE_WIDTH `UP(`NUM_WARPS / 16)
```

- **의미**: 한 사이클에 issue 가능한 명령 수
- **효과**: Issue 단계의 throughput 향상, Execute 단계의 블록 수 결정
- **메커니즘**: 
  - 다중 issue slice가 병렬로 scoreboard/operand read 수행
  - NUM_*_BLOCKS를 결정하여 execution unit 병렬화

#### 예시: ISSUE_WIDTH=2
```
Issue Stage:
  Issue Slice 0: Warp 0 명령 issue
  Issue Slice 1: Warp 1 명령 issue

Execute Stage:
  ALU Block 0: Warp 0 ADD 실행 (4 lanes)
  ALU Block 1: Warp 1 SUB 실행 (4 lanes)
→ Issue와 Execute 모두 병렬 처리
```

### 6.4 전체 병렬성 계산

#### 총 처리 가능 Thread 수
```
Total Threads = NUM_CLUSTERS × NUM_CORES × NUM_WARPS × NUM_THREADS
              = 1 × 1 × 4 × 4
              = 16 threads (기본 설정)
```

#### 사이클당 최대 연산 수 (각 Execution Unit별)
```
ALU: NUM_ALU_BLOCKS × NUM_ALU_LANES = 1 × 4 = 4 ops/cycle
FPU: NUM_FPU_BLOCKS × NUM_FPU_LANES = 1 × 4 = 4 ops/cycle
LSU: NUM_LSU_BLOCKS × NUM_LSU_LANES = 1 × 4 = 4 ops/cycle

이론적 최대 (모든 unit 동시 사용): 12 ops/cycle
```

#### 확장 예시 (NUM_WARPS=16, NUM_THREADS=32, ISSUE_WIDTH=2)
```
Total Threads = 1 × 1 × 16 × 32 = 512 threads
ISSUE_WIDTH   = 2
SIMD_WIDTH    = 32

ALU: 2 × 32 = 64 ops/cycle
FPU: 2 × 32 = 64 ops/cycle
LSU: 1 × 32 = 32 ops/cycle (BLOCKS는 여전히 1)

이론적 최대: 160 ops/cycle
```

## 7. NVIDIA GPU와 비교

### 7.1 용어 매핑

| Vortex | NVIDIA GPU | 설명 |
|--------|-----------|------|
| Core | SM (Streaming Multiprocessor) | 독립적인 실행 단위 |
| Warp | Warp | Thread 그룹 (32 threads in NVIDIA) |
| Thread | Thread | SIMT 레인 |
| NUM_WARPS | Max Resident Warps | SM당 상주 가능한 warp 수 |
| ISSUE_WIDTH | Issue Bandwidth | 사이클당 issue 가능한 명령 수 |
| NUM_*_LANES | CUDA Cores per SM | Execution unit의 SIMT 레인 수 |
| NUM_*_BLOCKS | Concurrent Execution Units | 병렬 execution unit 수 |

### 7.2 주요 차이점

#### 1. Concurrent Warp Execution
**NVIDIA (예: Ampere):**
- 동시 실행 가능한 warp: 4개 (SM scheduler가 선택)
- Warp scheduler가 매 사이클 4개 warp 중 실행할 것 선택
- 실제 4개가 병렬 실행 (각각 다른 execution unit 사용)

**Vortex:**
- ISSUE_WIDTH는 issue 단계의 병렬도 (기본값 1)
- 모든 NUM_WARPS는 상주 (resident)하지만 time-multiplexing
- Schedule 단계에서 1개 warp 선택 → Issue → Execute
- ISSUE_WIDTH=2라도 execution은 여전히 순차적 (issue만 병렬)

#### 2. Thread 수 및 Execution Units
**NVIDIA (예: Ampere GA102):**
- Warp당 32 threads (고정)
- SM당 128 CUDA cores (INT32/FP32)
- SM당 64 FP64 cores
- SM당 4개의 독립적인 warp scheduler

**Vortex:**
- Warp당 NUM_THREADS (기본 4, 설정 가능)
- Core당 NUM_ALU_LANES (기본 4) ALUs
- Core당 NUM_FPU_LANES (기본 4) FPUs
- NUM_*_BLOCKS로 execution unit 복제 (기본 1)

**핵심 차이**:
- NVIDIA: 고정된 많은 수의 execution cores
- Vortex: 파라미터화로 유연한 설정 가능

#### 3. Issue 메커니즘 및 Execution 병렬성
**NVIDIA:**
- 4-way warp scheduler
- 매 사이클 최대 4개 warp의 명령을 동시에 issue
- 각 warp scheduler는 독립적인 execution pipeline 사용
- 128개 CUDA cores가 여러 warps의 명령을 동시 처리

**Vortex:**
- ISSUE_WIDTH-way issue (기본 1)
- Issue 단계: ISSUE_WIDTH개 명령 병렬 처리
- Execute 단계: NUM_*_BLOCKS개 unit이 병렬 실행
- NUM_*_LANES로 각 unit 내 SIMT 병렬성 구현

**핵심 차이**:
- NVIDIA: 물리적으로 많은 cores, 여러 warps가 진짜 병렬 실행
- Vortex: BLOCKS×LANES 구조로 병렬성 구현, 더 작은 규모

## 8. 성능 최적화 고려사항

### 8.1 Warp 수 조정
```verilog
`define NUM_WARPS 8  // 증가
```
**효과:**
- 메모리 레이턴시 숨김 능력 향상
- Context 저장 공간 증가 (레지스터 파일, PC, masks)
- Branch divergence 처리 overhead 증가

**권장**: NUM_WARPS >= ISSUE_WIDTH × 16

### 8.2 Thread 수 조정 (LANES 증가)
```verilog
`define NUM_THREADS 16  // 증가
→ NUM_ALU_LANES = 16
→ NUM_FPU_LANES = 16
→ NUM_LSU_LANES = 16
```
**효과:**
- SIMT 병렬도 향상 (벡터 연산 가속)
- 각 Execution unit의 processing elements 증가 필요
- Thread mask 복잡도 증가
- 레지스터 파일 크기: NUM_WARPS × NUM_THREADS × 32 × XLEN

**트레이드오프**: 
- 장점: 데이터 병렬성 최대화
- 단점: 면적/전력 증가, divergence 낭비

### 8.3 Issue Width 조정 (BLOCKS 증가)
```verilog
`define ISSUE_WIDTH 2  // 증가
→ NUM_ALU_BLOCKS = 2
→ NUM_FPU_BLOCKS = 2
→ NUM_VPU_BLOCKS = 2
→ NUM_LSU_BLOCKS = 1 (여전히 고정)
```
**효과:**
- Issue 단계 throughput 증가
- Execute 단계의 execution unit 병렬화
- Scoreboard/Operand read 병렬화
- 면적 증가 (issue slice, execution blocks 복제)

**권장**: NUM_WARPS >= ISSUE_WIDTH × 16

**주의**: LSU와 SFU는 BLOCKS=1로 고정되어 이득 제한적

### 8.4 균형 잡힌 병렬성 설계

#### Compute-Bound Workload (연산 집약적)
```verilog
`define NUM_THREADS 16-32   // 높은 SIMT
`define NUM_WARPS   8-16    // 적당한 warp
`define ISSUE_WIDTH 1-2     // 낮은 issue
→ NUM_ALU_LANES = 16-32, NUM_ALU_BLOCKS = 1-2
→ 고밀도 데이터 병렬성
```

#### Memory-Bound Workload (메모리 집약적)
```verilog
`define NUM_THREADS 4-8     // 적당한 SIMT
`define NUM_WARPS   32-64   // 높은 warp (latency hiding)
`define ISSUE_WIDTH 1-2     // 적당한 issue
→ NUM_LSU_LANES = 4-8, NUM_LSU_BLOCKS = 1 (고정)
→ 많은 warps로 메모리 latency 숨김
```

#### 혼합 Workload
```verilog
`define NUM_THREADS 8       // 균형
`define NUM_WARPS   16-32   // 균형
`define ISSUE_WIDTH 2       // 균형
→ LANES = 8, BLOCKS = 2 (LSU 제외)
→ 모든 병렬성 골고루 활용
```

## 9. 설정 예시

### 9.1 기본 설정 (저전력)
```verilog
`define NUM_CLUSTERS 1
`define NUM_CORES    1
`define NUM_WARPS    4
`define NUM_THREADS  4
`define ISSUE_WIDTH  1  // UP(4/16)

→ Execution Units:
  - NUM_ALU_LANES = 4, NUM_ALU_BLOCKS = 1 → 4 ops/cycle
  - NUM_FPU_LANES = 4, NUM_FPU_BLOCKS = 1 → 4 ops/cycle
  - NUM_LSU_LANES = 4, NUM_LSU_BLOCKS = 1 → 4 ops/cycle
→ 총 16 threads, 이론적 12 ops/cycle
```

### 9.2 중급 설정 (균형)
```verilog
`define NUM_CLUSTERS 1
`define NUM_CORES    2
`define NUM_WARPS    16
`define NUM_THREADS  8
`define ISSUE_WIDTH  1  // UP(16/16)

→ Execution Units (per core):
  - NUM_ALU_LANES = 8, NUM_ALU_BLOCKS = 1 → 8 ops/cycle
  - NUM_FPU_LANES = 8, NUM_FPU_BLOCKS = 1 → 8 ops/cycle
  - NUM_LSU_LANES = 8, NUM_LSU_BLOCKS = 1 → 8 ops/cycle
→ 총 256 threads, 이론적 48 ops/cycle (2 cores)
```

### 9.3 고성능 설정
```verilog
`define NUM_CLUSTERS 2
`define NUM_CORES    4
`define NUM_WARPS    32
`define NUM_THREADS  32
`define ISSUE_WIDTH  2  // UP(32/16)

→ Execution Units (per core):
  - NUM_ALU_LANES = 32, NUM_ALU_BLOCKS = 2 → 64 ops/cycle
  - NUM_FPU_LANES = 32, NUM_FPU_BLOCKS = 2 → 64 ops/cycle
  - NUM_LSU_LANES = 32, NUM_LSU_BLOCKS = 1 → 32 ops/cycle
→ 총 8192 threads, 이론적 1280 ops/cycle (8 cores)
```

## 10. 핵심 파일

### 설정 파일
- **VX_config.vh**: 모든 병렬성 파라미터 정의
  - NUM_CLUSTERS, NUM_CORES, NUM_WARPS, NUM_THREADS
  - ISSUE_WIDTH, SIMD_WIDTH
  - NUM_*_LANES, NUM_*_BLOCKS (각 execution unit별)

### 패키지 파일
- **VX_gpu_pkg.sv**: Warp ID 매핑 함수, 상수 정의

### 하드웨어 모듈
- **VX_schedule.sv**: Warp 스케줄링 및 상태 관리
- **VX_issue.sv**: Multi-issue 분배
- **VX_issue_slice.sv**: Issue slice 내부 로직
- **VX_execute.sv**: Execution unit 실행
- **VX_alu_unit.sv**: ALU execution blocks
- **VX_fpu_unit.sv**: FPU execution blocks
- **VX_lsu_unit.sv**: LSU execution blocks
- **VX_sfu_unit.sv**: SFU execution blocks

## 11. 요약

### 병렬성 3단계
1. **TLP (Warp Level)**: NUM_WARPS - latency hiding
2. **DLP (Thread Level)**: NUM_THREADS = SIMD_WIDTH = NUM_*_LANES - 데이터 병렬성
3. **ILP (Issue Level)**: ISSUE_WIDTH = NUM_*_BLOCKS - instruction throughput

### Execution Unit 병렬성
```
각 Unit의 총 병렬도 = NUM_*_BLOCKS × NUM_*_LANES

기본 설정: BLOCKS=1, LANES=4 → 4 ops/cycle
확장 설정: BLOCKS=2, LANES=32 → 64 ops/cycle
```

### 주요 제약사항
- **LSU**: NUM_LSU_BLOCKS = 1 (고정) - D-cache 충돌 방지
- **SFU**: NUM_SFU_BLOCKS = 1 (고정) - warp 전역 상태 관리
- **권장**: NUM_WARPS >= ISSUE_WIDTH × 16

### 설계 원칙
- **면적 제약**: LANES 증가 → 하드웨어 복제
- **성능 요구**: BLOCKS 증가 → throughput 향상
- **균형**: Workload 특성에 맞춰 LANES/BLOCKS 조정
