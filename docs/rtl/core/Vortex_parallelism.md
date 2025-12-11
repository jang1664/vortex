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

## 5. 병렬성 분석

### 5.1 TLP (Thread Level Parallelism)

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

### 5.2 DLP (Data Level Parallelism)

#### Warp당 Thread 수
```verilog
`define NUM_THREADS 4  // 기본값
`define SIMD_WIDTH  4  // NUM_THREADS와 동일
```

- **의미**: 하나의 warp가 4개의 thread를 동시 실행
- **효과**: 벡터/배열 연산을 병렬 처리
- **메커니즘**: 4개의 ALU/FPU가 동일 명령을 다른 데이터로 수행

#### 예시: 벡터 덧셈
```c
// a[0:3] + b[0:3] = c[0:3]
Warp 0 실행: ADD c, a, b
→ Thread 0: c[0] = a[0] + b[0]
   Thread 1: c[1] = a[1] + b[1]
   Thread 2: c[2] = a[2] + b[2]
   Thread 3: c[3] = a[3] + b[3]
→ 4개 덧셈이 1 사이클에 완료
```

### 5.3 ILP (Instruction Level Parallelism)

#### Issue 병렬도
```verilog
`define ISSUE_WIDTH `UP(`NUM_WARPS / 16)
```

- **의미**: 한 사이클에 issue 가능한 명령 수
- **효과**: Issue 단계의 throughput 향상
- **메커니즘**: 다중 issue slice가 병렬로 scoreboard/operand read 수행

#### 예시: ISSUE_WIDTH=2
```
Cycle N: 
  Issue Slice 0: Warp 0 명령 issue
  Issue Slice 1: Warp 1 명령 issue
→ 2개 명령이 동시에 issue stage 통과
```

### 5.4 전체 병렬성 계산

#### 총 처리 가능 Thread 수
```
Total Threads = NUM_CLUSTERS × NUM_CORES × NUM_WARPS × NUM_THREADS
              = 1 × 1 × 4 × 4
              = 16 threads (기본 설정)
```

#### 사이클당 최대 연산 수
```
Ops/Cycle = ISSUE_WIDTH × NUM_THREADS
          = 1 × 4
          = 4 ops/cycle (기본 설정)
```

#### 확장 예시 (NUM_WARPS=16, NUM_THREADS=32)
```
Total Threads = 1 × 1 × 16 × 32 = 512 threads
ISSUE_WIDTH   = UP(16/16) = 1
Ops/Cycle     = 1 × 32 = 32 ops/cycle
```

## 6. NVIDIA GPU와 비교

### 6.1 용어 매핑

| Vortex | NVIDIA GPU | 설명 |
|--------|-----------|------|
| Core | SM (Streaming Multiprocessor) | 독립적인 실행 단위 |
| Warp | Warp | Thread 그룹 (32 threads in NVIDIA) |
| Thread | Thread | SIMT 레인 |
| NUM_WARPS | Max Resident Warps | SM당 상주 가능한 warp 수 |
| ISSUE_WIDTH | Issue Bandwidth | 사이클당 issue 가능한 명령 수 |

### 6.2 주요 차이점

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

#### 2. Thread 수
**NVIDIA:**
- Warp당 32 threads (고정)
- SM당 최대 1536 threads (48 warps × 32 threads)

**Vortex:**
- Warp당 NUM_THREADS (기본 4, 설정 가능)
- Core당 NUM_WARPS × NUM_THREADS (기본 16)

#### 3. Issue 메커니즘
**NVIDIA:**
- 4-way warp scheduler
- 매 사이클 최대 4개 warp의 명령을 동시에 issue

**Vortex:**
- ISSUE_WIDTH-way issue (기본 1)
- Issue 단계의 throughput 향상이 목적
- Execution은 여전히 순차적 (in-order)

## 7. 성능 최적화 고려사항

### 7.1 Warp 수 조정
```verilog
`define NUM_WARPS 8  // 증가
```
**효과:**
- 메모리 레이턴시 숨김 능력 향상
- Context 저장 공간 증가 (레지스터 파일, PC, masks)
- Branch divergence 처리 overhead 증가

### 7.2 Thread 수 조정
```verilog
`define NUM_THREADS 16  // 증가
```
**효과:**
- SIMT 병렬도 향상 (벡터 연산 가속)
- Execution unit (ALU/FPU) 수 증가 필요
- Thread mask 복잡도 증가

### 7.3 Issue Width 조정
```verilog
`define ISSUE_WIDTH 2  // 증가
```
**효과:**
- Issue 단계 throughput 증가
- Scoreboard/Operand read 병렬화
- 면적 증가 (issue slice 복제)
- NUM_WARPS >= ISSUE_WIDTH × 16 권장

## 8. 설정 예시

### 8.1 기본 설정 (저전력)
```verilog
`define NUM_CLUSTERS 1
`define NUM_CORES    1
`define NUM_WARPS    4
`define NUM_THREADS  4
`define ISSUE_WIDTH  1  // UP(4/16)

→ 16 threads, 4 ops/cycle
```

### 8.2 중급 설정 (균형)
```verilog
`define NUM_CLUSTERS 1
`define NUM_CORES    2
`define NUM_WARPS    16
`define NUM_THREADS  8
`define ISSUE_WIDTH  1  // UP(16/16)

→ 256 threads, 16 ops/cycle
```

### 8.3 고성능 설정
```verilog
`define NUM_CLUSTERS 2
`define NUM_CORES    4
`define NUM_WARPS    32
`define NUM_THREADS  32
`define ISSUE_WIDTH  2  // UP(32/16)

→ 8192 threads, 128 ops/cycle
```

## 9. 핵심 파일

- **VX_config.vh**: 모든 병렬성 파라미터 정의
- **VX_gpu_pkg.sv**: Warp ID 매핑 함수, 상수 정의
- **VX_schedule.sv**: Warp 스케줄링 및 상태 관리
- **VX_issue.sv**: Multi-issue 분배
- **VX_issue_slice.sv**: Issue slice 내부 로직
- **VX_execute.sv**: Execution unit 실행
