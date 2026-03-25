# Warp 스케줄링: NVIDIA vs Vortex 비교

## 1. NVIDIA GPU Warp 스케줄링

### 1.1 Thread Block과 Warp 구성

#### 기본 개념
```
Kernel Launch:
  Grid (gridDim) = {Gx, Gy, Gz} blocks
    └─ Thread Block (blockDim) = {Bx, By, Bz} threads
        └─ Warps (자동 분할) = ⌈Total_Threads / 32⌉ warps
```

#### 예시: Thread Block 크기에 따른 Warp 분할
```c
// 케이스 1: 작은 블록
blockDim = (64, 1, 1)  // 64 threads
→ Warps per block = ⌈64/32⌉ = 2 warps
  - Warp 0: threads [0:31]
  - Warp 1: threads [32:63]

// 케이스 2: 중간 블록
blockDim = (16, 16, 1)  // 256 threads
→ Warps per block = ⌈256/32⌉ = 8 warps

// 케이스 3: 큰 블록
blockDim = (32, 32, 1)  // 1024 threads (최대)
→ Warps per block = ⌈1024/32⌉ = 32 warps
```

### 1.2 SM (Streaming Multiprocessor) 스케줄링

#### SM의 물리적 제약
```
예: NVIDIA Ampere A100
- SM당 최대 Resident Warps: 64 warps
- SM당 최대 Resident Threads: 2048 threads (64×32)
- SM당 최대 Resident Blocks: 32 blocks
- Warp Scheduler: 4-way (동시 실행 warp 4개)
```

#### Warp 상주 (Residency)
SM은 **최대 64개 warp를 동시에 상주**시킬 수 있습니다. 하지만 모든 warp가 동시에 실행되는 것은 아닙니다.

```
SM Warp Pool (64 warps 상주 가능):
  Active Warps (준비된 warp들):
    - Eligible: 실행 가능한 상태
    - Stalled: 메모리 대기, 의존성 대기 등
  
  매 사이클:
    Warp Scheduler가 Active Warps 중에서
    최대 4개 warp를 선택하여 동시 실행
```

#### 예시: 128 Warps를 SM에 할당
```
Launch Configuration:
  gridDim = (16, 1, 1)    // 16 blocks
  blockDim = (256, 1, 1)  // 256 threads per block
  
Total Warps = 16 blocks × ⌈256/32⌉ = 16 × 8 = 128 warps

SM 할당 (SM이 8개 있다고 가정):
  - 각 SM이 처리할 blocks = 16 / 8 = 2 blocks per SM
  - 각 SM의 resident warps = 2 × 8 = 16 warps

SM0 내부 상태:
  Resident Warps: 16 warps (Block 0의 8 warps + Block 1의 8 warps)
  Warp Scheduler:
    Cycle N: Warp 0, 3, 7, 9 동시 실행 (4개 선택)
    Cycle N+1: Warp 1, 4, 8, 11 동시 실행
    Cycle N+2: Warp 2, 5, 12, 14 동시 실행
    ...
```

### 1.3 많은 Warp 처리 전략

#### 케이스: 1024 Warps 실행 (SM 8개 가정)
```
Launch:
  gridDim = (128, 1, 1)
  blockDim = (256, 1, 1)
  Total Warps = 128 × 8 = 1024 warps

할당 방식 1: Block 기준 분산
  SM당 blocks = 128 / 8 = 16 blocks
  SM당 resident warps = 16 × 8 = 128 warps
  → SM의 최대 용량(64 warps) 초과!
  
실제 동작:
  각 SM은 최대 64 warps만 resident 가능
  → 각 SM이 8 blocks (64 warps)만 먼저 처리
  → 완료 후 나머지 8 blocks (64 warps) 처리
  → 시간 분할 (Time Multiplexing)
```

#### 동작 순서
```
Time Slice 1:
  SM0: Block [0-7] (64 warps) resident
    └─ Warp Scheduler가 매 사이클 4개씩 선택/실행
  SM1: Block [8-15] (64 warps) resident
  ...
  SM7: Block [56-63] (64 warps) resident

Time Slice 2 (Slice 1 완료 후):
  SM0: Block [64-71] (64 warps) resident
  SM1: Block [72-79] (64 warps) resident
  ...
  SM7: Block [120-127] (64 warps) resident
```

#### 핵심 특징
1. **Resident Warps**: SM당 최대 64 warps가 동시 상주
2. **Concurrent Execution**: 매 사이클 4개 warp 동시 실행 (4-way scheduler)
3. **Time Multiplexing**: 초과 warp는 시간 분할로 처리
4. **Zero-Overhead Scheduling**: Context 전환 비용 없음 (모두 resident)

## 2. Vortex GPU Warp 스케줄링

### 2.1 Thread Block과 Warp 구성

#### Vortex의 접근
Vortex는 CUDA와 유사한 API를 제공하지만 **하드웨어 warp 수(NUM_WARPS)**와 **소프트웨어 warp 수(커널 요구량)**는 분리됩니다.

```c
// Kernel launch
vx_spawn_threads(dimension, grid_dim, block_dim, kernel_func, arg);

// 예시
grid_dim = {16, 8, 1}      // 128 blocks
block_dim = {8, 8, 1}      // 64 threads per block
Total tasks = 128 × 64 = 8192 threads
```

#### Thread를 Warp로 매핑
```
Hardware Spec (VX_config.vh):
  NUM_WARPS = 4           // Core당 4 warps만 resident
  NUM_THREADS = 4         // Warp당 4 threads
  Threads per Core = 4 × 4 = 16 threads

Software Requirement:
  Total tasks = 8192 threads
  
필요한 논리적 warps = ⌈8192 / 4⌉ = 2048 warps
하지만 하드웨어는 4 warps만 resident 가능!
```

### 2.2 Vortex 스케줄링 전략

#### 2-Level 스케줄링

Vortex는 **소프트웨어 스케줄링 (런타임)** + **하드웨어 스케줄링 (RTL)** 조합으로 동작합니다.

```
┌─────────────────────────────────────────┐
│ Software Layer (vx_spawn.c)             │
│ - 8192 tasks를 4 warps × 4 threads에   │
│   시간 분할 매핑                         │
│ - 각 warp/thread가 여러 task 순회      │
└─────────────┬───────────────────────────┘
              │ wspawn(4, kernel_func)
              ▼
┌─────────────────────────────────────────┐
│ Hardware Layer (VX_schedule.sv)         │
│ - 4개 warp를 round-robin 스케줄링      │
│ - 매 사이클 1개 warp 선택 (ISSUE=1)    │
└─────────────────────────────────────────┘
```

#### 소프트웨어 레이어 동작 (`kernel/src/vx_spawn.c`)

##### 케이스 1: Block Size = 1 (독립 tasks)
```c
// 설정
grid_dim = {2048, 1, 1}
block_dim = {1, 1, 1}
Total tasks = 2048

// 하드웨어 스펙
warps_per_core = 4
threads_per_warp = 4
threads_per_core = 4 × 4 = 16

// 계산
tasks_per_core = 2048 / num_cores
active_warps = MIN(⌈tasks_per_core / threads_per_warp⌉, warps_per_core)
             = MIN(⌈2048 / 4⌉, 4) = 4 warps

// Warp 할당
warp_batches = ⌈total_warps / active_warps⌉
             = ⌈512 / 4⌉ = 128

각 warp는 128번 순회하며 tasks 처리:
  Warp 0: Task [0, 4, 8, 12, ..., 508]     (128 iterations)
  Warp 1: Task [1, 5, 9, 13, ..., 509]
  Warp 2: Task [2, 6, 10, 14, ..., 510]
  Warp 3: Task [3, 7, 11, 15, ..., 511]
  
각 Warp의 각 iteration에서 4개 thread가 동시 처리:
  Warp 0, Iteration 0:
    Thread 0: Task 0
    Thread 1: Task 16
    Thread 2: Task 32
    Thread 3: Task 48
```

##### 케이스 2: Block Size > 1 (Thread groups)
```c
// 설정
grid_dim = {128, 1, 1}     // 128 blocks
block_dim = {8, 8, 1}      // 64 threads per block
group_size = 64
num_groups = 128

// 계산
warps_per_group = ⌈64 / 4⌉ = 16 warps per block
needed_warps = 128 × 16 = 2048 warps

// 하드웨어는 4 warps만 resident
groups_per_core = ⌊4 / 16⌋ = 0 (한 block도 완전히 상주 불가!)

실제 동작:
  - 한 번에 1개 group만 처리 불가 (16 > 4)
  - ERROR: group_size > threads_per_core
  
해결책: Block size를 줄이거나 NUM_WARPS 증가
```

##### 케이스 3: Block Size가 Core 용량 이하
```c
// 설정
grid_dim = {128, 1, 1}
block_dim = {4, 2, 1}      // 8 threads per block
group_size = 8
warps_per_group = ⌈8 / 4⌉ = 2 warps

// 계산
groups_per_core = ⌊4 / 2⌋ = 2 groups (동시에 2 blocks resident)
total_groups_per_core = 128 / num_cores

// Warp 할당 예시 (1 core 가정)
active_warps = MIN(128 × 2, 4) = 4 warps
warp_batches = ⌈128 × 2 / 4⌉ = 64

Warp 0-1: Group 0 (Block 0) 처리
Warp 2-3: Group 1 (Block 1) 처리
→ 완료 후 다음 iteration
Warp 0-1: Group 2 (Block 2) 처리
Warp 2-3: Group 3 (Block 3) 처리
...
```

#### 하드웨어 레이어 동작 (`hw/rtl/core/VX_schedule.sv`)

소프트웨어가 `vx_wspawn(active_warps, kernel_func)`를 호출하면:

```verilog
// Warp 활성화
wspawn.valid = 1
wspawn.wmask = 4'b1111      // 4개 warp 모두 활성화
wspawn.pc = kernel_func

// 각 warp 상태 업데이트
for (wid in wmask):
  active_warps[wid] = 1
  thread_masks[wid] = vx_tmc() 값
  warp_pcs[wid] = wspawn.pc
```

#### Round-Robin 스케줄링
```verilog
// 매 사이클 실행 가능한 warp 선택
schedule_mask = active_warps & ~stalled_warps & ~barrier_stalls

// Leading-zero-count로 우선순위 선택
schedule_wid = lzc(schedule_mask)
schedule_valid = |schedule_mask

// 타임라인
Cycle 0: Warp 0 선택 → Fetch
Cycle 1: Warp 1 선택 → Fetch, Warp 0 → Decode
Cycle 2: Warp 2 선택 → Fetch, Warp 1 → Decode, Warp 0 → Issue
Cycle 3: Warp 3 선택 → Fetch, Warp 2 → Decode, Warp 1 → Issue
Cycle 4: Warp 0 선택 → Fetch (다음 명령)
...
```

### 2.3 NUM_WARPS=4, 128 Tasks 처리 예시

#### 시나리오
```
Hardware: NUM_WARPS=4, NUM_THREADS=4, NUM_CORES=1
Software: 128 tasks (grid_dim={128,1,1}, block_dim={1,1,1})
```

#### 소프트웨어 스케줄링 계산
```c
// vx_spawn.c 내부 계산
threads_per_core = 4 × 4 = 16
tasks_per_core = 128 (1 core 가정)

total_warps_per_core = 128 / 4 = 32 warps 필요
active_warps = MIN(32, 4) = 4 warps

warp_batches = 32 / 4 = 8 iterations
remaining_warps = 32 - 8×4 = 0
```

#### 실행 순서
```
Iteration 0:
  Warp 0, Thread 0-3: Task [0, 1, 2, 3]
  Warp 1, Thread 0-3: Task [4, 5, 6, 7]
  Warp 2, Thread 0-3: Task [8, 9, 10, 11]
  Warp 3, Thread 0-3: Task [12, 13, 14, 15]

Iteration 1:
  Warp 0, Thread 0-3: Task [16, 17, 18, 19]
  Warp 1, Thread 0-3: Task [20, 21, 22, 23]
  ...

Iteration 7:
  Warp 0, Thread 0-3: Task [112, 113, 114, 115]
  Warp 1, Thread 0-3: Task [116, 117, 118, 119]
  Warp 2, Thread 0-3: Task [120, 121, 122, 123]
  Warp 3, Thread 0-3: Task [124, 125, 126, 127]
```

#### 하드웨어 스케줄링 (각 iteration 내)
```
각 iteration은 4 warps가 순차 실행:
  Cycle 0-N: Warp 0 처리 (Task 0-3)
  Cycle N+1-M: Warp 1 처리 (Task 4-7)
  Cycle M+1-K: Warp 2 처리 (Task 8-11)
  Cycle K+1-L: Warp 3 처리 (Task 12-15)

Stall 발생 시:
  - Warp 0이 메모리 대기 중이면 stalled_warps[0] = 1
  - 즉시 Warp 1, 2, 3 중 준비된 것 실행
  - Warp 0은 메모리 응답 올 때까지 skip
```

## 3. 핵심 차이점 비교

| 항목 | NVIDIA GPU | Vortex GPU |
|------|-----------|-----------|
| **Resident Warps** | SM당 최대 64 warps | Core당 NUM_WARPS (기본 4) |
| **Concurrent Execution** | 매 사이클 4 warps 동시 실행 | 매 사이클 1 warp 실행 (ISSUE_WIDTH=1) |
| **초과 Warp 처리** | SM의 용량 초과 시 시간 분할 (HW가 자동 관리) | 소프트웨어가 명시적 iteration 관리 |
| **Context Switch** | Zero-overhead (모두 resident) | Zero-overhead (4 warps만 resident) |
| **Warp 선택** | 4-way scheduler (complex) | Round-robin LZC (simple) |
| **Thread per Warp** | 32 (고정) | NUM_THREADS (설정 가능, 기본 4) |
| **Block 제약** | SM 용량 내에서 자유 | group_size ≤ threads_per_core |

## 4. 구체적 시나리오 비교

### 시나리오: 1024 Tasks 처리

#### NVIDIA (예: 8 SMs, 64 warps/SM)
```
Launch:
  gridDim = (128, 1, 1)
  blockDim = (256, 1, 1)
  Warps = 128 × ⌈256/32⌉ = 128 × 8 = 1024 warps

할당:
  SM당 blocks = 128 / 8 = 16 blocks
  SM당 warps = 16 × 8 = 128 warps
  
처리:
  Time Slice 1:
    각 SM이 8 blocks (64 warps) resident
    매 사이클 4 warps 동시 실행
    
  Time Slice 2:
    나머지 8 blocks (64 warps) resident
    매 사이클 4 warps 동시 실행
    
총 사이클 (대략):
  Slice당 사이클 = (명령 수 × 64 warps) / 4
  총 사이클 = 2 × Slice당 사이클
```

#### Vortex (1 Core, 4 Warps)
```
Launch:
  gridDim = {1024, 1, 1}
  blockDim = {1, 1, 1}
  Tasks = 1024

할당:
  threads_per_core = 4 × 4 = 16
  논리적 warps = ⌈1024 / 4⌉ = 256 warps
  active_warps = 4
  warp_batches = 256 / 4 = 64 iterations

처리:
  Iteration 0:
    Warp 0: Task [0-3]
    Warp 1: Task [4-7]
    Warp 2: Task [8-11]
    Warp 3: Task [12-15]
    → 4 warps가 round-robin 실행
    
  Iteration 1:
    Warp 0: Task [16-19]
    ...
    
  Iteration 63:
    Warp 0: Task [1008-1011]
    Warp 1: Task [1012-1015]
    Warp 2: Task [1016-1019]
    Warp 3: Task [1020-1023]

총 사이클:
  각 iteration: 명령 수 × 4 warps
  총 사이클 = 64 × (명령 수 × 4)
```

## 5. Vortex 최적화 전략

### 5.1 NUM_WARPS 증가
```verilog
// VX_config.vh
`define NUM_WARPS 16  // 4 → 16

효과:
  - Resident warps 증가 (4 → 16)
  - 레이턴시 숨김 능력 향상
  - Iteration 감소 (128개 tasks: 32회 → 8회)
  
비용:
  - 레지스터 파일 크기 4배 증가
  - Scoreboard 복잡도 증가
  - 면적/전력 증가
```

### 5.2 ISSUE_WIDTH 증가
```verilog
`define ISSUE_WIDTH 2  // 1 → 2

효과:
  - Issue 단계 throughput 2배
  - 2개 warp 동시 issue (NVIDIA의 4-way와 유사)
  
제약:
  - Execution은 여전히 순차 (out-of-order 아님)
  - NUM_WARPS >= ISSUE_WIDTH × 16 권장
```

### 5.3 NUM_CORES 증가
```verilog
`define NUM_CORES 4  // 1 → 4

효과:
  - 병렬 처리 능력 4배
  - 128 tasks: 각 core가 32 tasks 처리
  
비용:
  - 전체 core 복제 (면적 4배)
  - 메모리 대역폭 요구 증가
```

## 6. 설계 철학 차이

### NVIDIA: Hardware-Centric
```
- 대량의 warps를 SM에 resident (64 warps)
- 복잡한 4-way warp scheduler
- Zero-overhead context switching
- 소프트웨어는 하드웨어 용량만 신경
→ 고성능, 고비용, 복잡한 하드웨어
```

### Vortex: Software-Centric
```
- 적은 수의 warps만 resident (4 warps)
- 단순한 round-robin scheduler
- 소프트웨어가 iteration 관리
- 명시적 warp spawning
→ 저비용, 단순 하드웨어, 유연성
```

## 7. 요약

### NVIDIA 방식
- **물리적 warp 수가 많음** (SM당 64)
- **4개 warp가 매 사이클 동시 실행**
- **초과분은 하드웨어가 자동으로 시간 분할**
- **고성능, 고복잡도**

### Vortex 방식
- **물리적 warp 수가 적음** (Core당 4)
- **1개 warp가 매 사이클 실행** (ISSUE_WIDTH=1)
- **초과분은 소프트웨어가 명시적으로 iteration**
- **저비용, 단순 설계, 확장 가능**

### 공통점
- 둘 다 SIMT 모델
- 둘 다 warp 기반 스케줄링
- 둘 다 레이턴시 숨김 목적
- 둘 다 zero-overhead context switching

### 적용 시나리오
- **NVIDIA**: 대규모 데이터 병렬 처리, 고성능 컴퓨팅
- **Vortex**: 임베디드 GPGPU, 저전력, 학습/연구 목적
