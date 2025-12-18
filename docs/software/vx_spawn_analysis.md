# Vortex Runtime: Warp Spawn 및 실행 흐름 분석

이 문서는 Vortex 런타임(`vx_spawn.c`)이 어떻게 커널을 실행하고, 하드웨어와 상호작용하여 Warp를 생성(Spawn)하고 관리하는지 분석합니다.

## 1. 개요

Vortex는 하드웨어적으로는 고정된 수의 Warp(`NUM_WARPS`)를 가지고 있지만, 소프트웨어적으로는 훨씬 많은 수의 Thread와 Block을 처리해야 합니다. `vx_spawn.c`는 이 **가상화(Virtualization)**를 담당하는 핵심 런타임 코드입니다.

- **역할**: 사용자 요청(Grid/Block)을 물리적 하드웨어(Core/Warp)에 매핑
- **핵심 메커니즘**:
  1. **Work Distribution**: 전체 작업을 코어별로 분배. 전체 block을 core에게 분배하는데 contigous하게 분배함. 예를 들어 core가 2개고 block이 4개인 경우 core0이 block 0,1을 처리하고 core1이 block 2,3을 처리함.
  2. **Warp Batching**: 물리적 Warp 수보다 많은 작업은 시간 분할(Batching)로 처리
  3. **Hardware Intrinsics**: `vx_wspawn`, `vx_tmc` 등을 통해 하드웨어 제어
  4. **Execution Flow**: 각 코어의 메인 스레드(Warp 0, Thread 0)가 진입하여 스케줄링을 수행합니다. 이후 `vx_wspawn`을 통해 필요한 수만큼의 Warp를 활성화(Spawn)하고, 각 Warp는 `vx_tmc`를 호출하여 내부 스레드들을 깨운 뒤 커널 함수를 병렬로 실행합니다.

## 2. 주요 데이터 구조

Warp들이 작업을 공유하기 위해 CSR(Control Status Register) `VX_CSR_MSCRATCH`를 통해 인자를 전달합니다.

```c
// Thread Block (Group) 단위 실행을 위한 인자 구조체
typedef struct {
    vx_kernel_func_cb callback;  // 실행할 커널 함수 포인터
    const void* arg;             // 커널 인자
    uint32_t group_offset;       // 현재 코어가 처리할 시작 Block ID
    uint32_t warp_batches;       // Warp가 반복해야 할 횟수 (Time-multiplexing)
    uint32_t remaining_warps;    // 마지막 배치에서 사용할 Warp 수
    uint32_t warps_per_group;    // 하나의 Block을 처리하는데 필요한 Warp 수
    uint32_t groups_per_core;    // 코어당 할당된 Block 수
    uint32_t remaining_mask;     // 마지막 Warp의 유효 Thread 마스크
} wspawn_groups_args_t;
```

## 3. `vx_spawn_threads` 분석

이 함수는 커널 실행의 진입점입니다. 크게 두 가지 경로로 나뉩니다.

### 3.1 초기화 및 리소스 계산
```c
// 1. Grid와 Block 차원 계산
uint32_t num_groups = ...; // 전체 Block 수 (Grid Size)
uint32_t group_size = ...; // Block당 Thread 수 (Block Size)

// 2. 하드웨어 스펙 조회
uint32_t num_cores = vx_num_cores();
uint32_t warps_per_core = vx_num_warps();
uint32_t threads_per_warp = vx_num_threads();
```

### 3.2 경로 1: Thread Block 사용 (`group_size > 1`)
CUDA 스타일의 일반적인 커널 실행 경로입니다.

1.  **Warp 요구량 계산**:
    ```c
    // Block 하나를 처리하는데 몇 개의 Warp가 필요한가?
    uint32_t warps_per_group = group_size / threads_per_warp;
    ```

2.  **작업 분배 (Work Distribution)**:
    ```c
    // 전체 Block을 코어 수로 나누어 현재 코어의 할당량 계산
    uint32_t total_groups_per_core = num_groups / active_cores;
    ```

3.  **Warp Batching 계산 (핵심)**:
    물리적 Warp 수보다 필요한 Warp가 많으면 반복(Batch) 횟수를 계산합니다.
    ```c
    // 필요한 총 Warp 수
    uint32_t total_warps_per_core = total_groups_per_core * warps_per_group;
    
    // 하드웨어 한계(warps_per_core)를 초과하는가?
    if (active_warps > warps_per_core) {
        active_warps = groups_per_core * warps_per_group; // 한 번에 실행할 Warp 수
        warp_batches = total_warps_per_core / active_warps; // 반복 횟수
    }
    ```

4.  **실행 (Spawn)**:
    ```c
    // 1. 인자를 CSR에 저장 (다른 Warp들이 읽을 수 있게)
    csr_write(VX_CSR_MSCRATCH, &wspawn_args);

    // 2. 다른 Warp들 깨우기 (Warp 1 ~ active_warps-1)
    vx_wspawn(active_warps, process_thread_groups_stub);

    // 3. Warp 0도 작업 시작
    process_thread_groups_stub();
    ```

## 4. 실행 흐름 상세 예시 (복잡한 시나리오)

**상황 가정**:
- **HW**: 2 Cores, 4 Warps/Core, 4 Threads/Warp
  - Core 0: Warp 0-3, 각 Warp는 Thread 0-3
  - Core 1: Warp 0-3, 각 Warp는 Thread 0-3
- **SW**: Grid={11,1,1}, Block={14,1,1}
  - 총 **11개 blocks**
  - 각 block은 **14 threads**
  - **나누어떨어지지 않는 숫자들로 구성**

### 단계별 계산 과정

#### 1. Warp 요구량 계산

```c
group_size = 14 threads
threads_per_warp = 4

// Block 하나를 처리하는데 필요한 warp 수
warps_per_group = 14 / 4 = 3 warps (12 threads)
remaining_threads = 14 - 12 = 2 threads

// 마지막 warp는 2개 thread만 사용
remaining_mask = (1 << 2) - 1 = 0b0011
warps_per_group++ = 4 warps  // 마지막 warp 포함
```

**결론**: Block 하나당 **4개 warps 필요** (3개는 full, 1개는 2 threads만)

#### 2. Active Cores 계산

```c
num_groups = 11 blocks
warps_per_group = 4
warps_per_core = 4

needed_warps = 11 * 4 = 44 warps
needed_cores = (44 + 4-1) / 4 = 47/4 = 11 cores 필요
active_cores = MIN(11, 2) = 2 cores

// 2개 core 모두 활성화
```

#### 3. Core별 Work Distribution (Contiguous)

```c
// Core 0 계산
total_groups_per_core = 11 / 2 = 5 blocks
remaining_groups_per_core = 11 - 2*5 = 1 block

core_id = 0:
  total_groups_per_core = 5 + 1 = 6 blocks  // Block 0-5
  group_offset = 0*6 + MIN(0, 1) = 0

core_id = 1:
  total_groups_per_core = 5 blocks          // Block 6-10
  group_offset = 1*5 + MIN(1, 1) = 6
```

**Core 0**: Block 0, 1, 2, 3, 4, 5 처리 (6개)  
**Core 1**: Block 6, 7, 8, 9, 10 처리 (5개)

#### 4. Core별 Warp Batching 계산

**Core 0 (6 blocks 처리)**:
```c
total_groups_per_core = 6
groups_per_core = warps_per_core / warps_per_group = 4 / 4 = 1
// 한 번에 1개 block만 처리 가능

total_warps_per_core = 6 * 4 = 24 warps 필요
active_warps = 1 * 4 = 4 warps (동시에 사용)

warp_batches = 24 / 4 = 6
remaining_warps = 24 - 6*4 = 0
```

**Core 1 (5 blocks 처리)**:
```c
total_groups_per_core = 5
groups_per_core = 1
total_warps_per_core = 5 * 4 = 20 warps 필요
active_warps = 4 warps

warp_batches = 20 / 4 = 5
remaining_warps = 0
```

#### 5. Core 0 상세 실행 흐름

**Iteration 1** (group_id = 0):
- Warp 0-3 (local_group_id=0) → **Block 0** 처리
- Thread mask:
  - Warp 0: `0b1111` (4 threads)
  - Warp 1: `0b1111` (4 threads)
  - Warp 2: `0b1111` (4 threads)
  - Warp 3: `0b0011` (2 threads) - remaining_mask
- 총 14 threads가 `threadIdx.x = 0~13`으로 Block 0 실행

**Iteration 2** (group_id = 1):
- Warp 0-3 (local_group_id=0, 재사용) → **Block 1** 처리
- 같은 `local_group_id=0` → **같은 local memory 영역 재사용**
- 14 threads가 Block 1 실행

**Iteration 3-6**: Block 2, 3, 4, 5 순차 처리

**Loop 구조**:
```c
// Warp 0-3 모두 같은 local_group_id = 0
start_group = 0 + 0 = 0
group_stride = 1
end_group = 0 + 6*1 = 6
iterations = 6

for (group_id = 0; group_id < 6; group_id += 1) {
    // group_id: 0, 1, 2, 3, 4, 5
    blockIdx.x = group_id;
    callback(arg);  // 14 threads 병렬 실행
}
```

#### 6. Core 1 상세 실행 흐름

**Iteration 1** (group_id = 6):
- Warp 0-3 (local_group_id=0) → **Block 6** 처리

**Iteration 2-5**: Block 7, 8, 9, 10 순차 처리

```c
// Core 1의 Warp 0-3
start_group = 6 + 0 = 6
group_stride = 1
end_group = 6 + 5*1 = 11
iterations = 5

for (group_id = 6; group_id < 11; group_id += 1) {
    // group_id: 6, 7, 8, 9, 10
    blockIdx.x = group_id;
    callback(arg);
}
```

### 실행 타임라인 비교

| Time | Core 0 (6 iterations) | Core 1 (5 iterations) |
|------|----------------------|----------------------|
| T0 | Block 0 (14 threads) | Block 6 (14 threads) |
| T1 | Block 1 (14 threads) | Block 7 (14 threads) |
| T2 | Block 2 (14 threads) | Block 8 (14 threads) |
| T3 | Block 3 (14 threads) | Block 9 (14 threads) |
| T4 | Block 4 (14 threads) | Block 10 (14 threads) |
| T5 | Block 5 (14 threads) | *(idle)* |

### 주요 관찰 사항

1. **Contiguous Distribution**: Core 0이 Block 0-5, Core 1이 Block 6-10 (연속)
2. **Load Imbalance**: Core 0은 6개, Core 1은 5개 block 처리 (11이 2로 나누어떨어지지 않음)
3. **Warp Batching**: 각 block이 4 warps 필요하므로 한 번에 1개 block만 처리 가능
4. **Local Memory 재사용**: 각 iteration마다 같은 `local_group_id=0` → 같은 주소 영역 재사용
5. **Partial Thread Mask**: 마지막 warp는 2개 thread만 활성화 (14 = 3*4 + 2)

### Local Memory 사용량 계산

```c
// 각 block이 1KB local memory 요청 시
groups_per_core = 1 (동시 1개 block만)
local_mem_per_group = 1024 bytes

// Core 0 주소 맵:
Block 0: 0x80000000 + 0*1024 = 0x80000000 (Iter 1)
Block 1: 0x80000000 + 0*1024 = 0x80000000 (Iter 2, 재사용!)
Block 2: 0x80000000 + 0*1024 = 0x80000000 (Iter 3, 재사용!)
...

// 총 필요 LMEM: 1KB (동시에 1개 block만 실행되므로)
// 실제 LMEM 크기: 16KB ✓ 충분
```

## 5. Hardware - Software 상호작용

C 코드의 동작이 실제 Vortex 하드웨어(`VX_schedule.sv` 등)와 어떻게 연결되는지 정리합니다.

| C Code (Runtime) | Assembly / Instruction | Hardware Action (RTL) |
|------------------|------------------------|-----------------------|
| `vx_wspawn(num, func)` | `.insn r ... (WSPAWN)` | **VX_schedule.sv**:<br>1. `active_warps` 비트맵 업데이트 (0~num-1 활성화)<br>2. 활성화된 Warp들의 `warp_pcs`를 `func` 주소로 설정<br>3. `stalled_warps` 해제하여 스케줄링 후보 등록 |
| `vx_tmc(mask)` | `.insn r ... (TMC)` | **VX_schedule.sv**:<br>1. 현재 Warp의 `thread_masks` 레지스터 업데이트<br>2. `mask`가 0이면 해당 Warp는 비활성화(Sleep) 상태로 전환 |
| `vx_barrier(...)` | `.insn r ... (BARRIER)` | **VX_schedule.sv**:<br>1. `barrier_masks` 업데이트<br>2. 참여해야 할 모든 Warp가 도달할 때까지 현재 Warp를 `barrier_stalls` 상태로 만듦 |
| `csr_write(MSCRATCH)` | `csrw mscratch, rs1` | **VX_csr_unit.sv**:<br>1. `MSCRATCH` 레지스터에 값 저장<br>2. 모든 Warp가 공유하는 메모리 공간 역할 (인자 전달용) |

### 전체 동작 흐름도

```mermaid
graph TD
    A[User App: vx_spawn_threads] --> B{리소스 계산}
    B --> C[CSR에 인자 저장]
    C --> D[vx_wspawn 호출]
    
    D -- Instruction --> E[Hardware: VX_schedule.sv]
    E --> F[Warp 0~N 활성화]
    
    F --> G[각 Warp: Stub 함수 실행]
    G --> H[CSR에서 인자 로드]
    H --> I[vx_tmc: Thread 활성화]
    I --> J[Kernel Body 실행]
    J --> K[vx_tmc(0): Warp 종료]
```

## 6. 함수별 실행 주체 분석

`vx_spawn.c`의 각 함수는 실행 주체(어떤 warp의 어떤 thread)가 다릅니다. 하나의 함수 내에서도 라인에 따라 실행 주체가 달라질 수 있습니다.

### 6.1 `vx_spawn_threads` (Lines 180-352)

**실행 주체**: 각 Core의 **Warp 0, Thread 0만** 실행 (메인 진입점)

```c
int vx_spawn_threads(...) {
  // [Warp 0, Thread 0] Grid/Block 계산
  uint32_t num_groups = 1;
  uint32_t group_size = 1;
  for (uint32_t i = 0; i < 3; ++i) {
    // [Warp 0, Thread 0] 차원별 계산
    ...
  }

  // [Warp 0, Thread 0] 하드웨어 스펙 조회
  uint32_t num_cores = vx_num_cores();
  uint32_t warps_per_core = vx_num_warps();
  ...

  if (group_size > 1) {
    // [Warp 0, Thread 0] 스케줄링 계산
    ...
    
    // [Warp 0, Thread 0] CSR에 인자 저장 (다른 Warp들이 읽을 공유 메모리)
    csr_write(VX_CSR_MSCRATCH, &wspawn_args);

    // [Warp 0, Thread 0] 다른 Warp들 활성화
    vx_wspawn(active_warps, process_thread_groups_stub);

    // [Warp 0, Thread 0] 본인도 작업 시작
    process_thread_groups_stub();
  } else {
    // [Warp 0, Thread 0] group_size == 1 경로
    ...
    
    if (active_warps >= 1) {
      // [Warp 0, Thread 0] 다른 Warp들 활성화
      vx_wspawn(active_warps, process_threads_stub);

      // [Warp 0, Thread 0] 본인 warp의 모든 threads 활성화
      vx_tmc(-1);

      // ★ 여기서부터는 [Warp 0, All Threads] 실행
      process_threads();

      // [Warp 0, All Threads -> Thread 0만] 다시 단일 스레드로
      vx_tmc_one();
    }

    if (remaining_tasks != 0) {
      // [Warp 0, Thread 0] 특정 threads만 활성화
      vx_tmc(tmask);

      // ★ 여기서부터는 [Warp 0, tmask에 해당하는 Threads] 실행
      process_remaining_threads();

      // [Warp 0, 활성 Threads -> Thread 0만] 다시 단일 스레드로
      vx_tmc_one();
    }
  }

  // [Warp 0, Thread 0] 모든 Warp 완료 대기
  vx_wspawn(1, 0);

  return 0;
}
```

**핵심 포인트**:
- 함수 진입: Warp 0의 Thread 0만
- `vx_tmc(-1)` 이후: Warp 0의 모든 Threads
- `vx_tmc(tmask)` 이후: Warp 0의 해당 mask Threads
- `vx_tmc_one()` 이후: 다시 Warp 0의 Thread 0만

### 6.2 `process_thread_groups_stub` (Lines 155-168)

**실행 주체**: `vx_wspawn`으로 활성화된 **각 Warp의 Thread 0만** (초기 진입 시)

```c
static void process_thread_groups_stub() {
  // [각 Warp, Thread 0] CSR에서 인자 로드
  wspawn_groups_args_t* targs = (wspawn_groups_args_t*)csr_read(VX_CSR_MSCRATCH);
  
  // [각 Warp, Thread 0] 파라미터 계산
  uint32_t warps_per_group = targs->warps_per_group;
  uint32_t remaining_mask = targs->remaining_mask;
  uint32_t warp_id = vx_warp_id();
  uint32_t group_warp_id = warp_id % warps_per_group;
  uint32_t threads_mask = (group_warp_id == warps_per_group-1) ? remaining_mask : -1;

  // [각 Warp, Thread 0] 해당 warp의 threads 활성화
  vx_tmc(threads_mask);

  // ★ 여기서부터는 [각 Warp, threads_mask에 해당하는 Threads] 실행
  process_thread_groups();

  // [각 Warp, 활성 Threads] Warp 0만 Thread 0 유지, 나머지는 비활성화
  vx_tmc(0 == vx_warp_id());
}
```

**핵심 포인트**:
- 함수 진입: 각 Warp의 Thread 0만 (Warp 0, 1, 2, ... 각각의 Thread 0)
- `vx_tmc(threads_mask)` 이후: 각 Warp의 mask에 해당하는 Threads
- 마지막 `vx_tmc`: Warp 0은 Thread 0만 유지, 나머지 Warp는 모든 Thread 비활성화

### 6.3 `process_thread_groups` (Lines 112-153)

**실행 주체**: **각 Warp의 활성화된 모든 Threads**

```c
static void process_thread_groups() {
  // [각 Warp, 각 활성 Thread] CSR 읽기 (같은 값 읽음)
  wspawn_groups_args_t* targs = (wspawn_groups_args_t*)csr_read(VX_CSR_MSCRATCH);

  // [각 Warp, 각 활성 Thread] 자신의 ID 조회
  uint32_t threads_per_warp = vx_num_threads();
  uint32_t warp_id = vx_warp_id();      // Warp마다 다름
  uint32_t thread_id = vx_thread_id();  // Thread마다 다름
  
  // [각 Warp, 각 활성 Thread] 파라미터 로드 (모든 thread가 같은 값)
  uint32_t warps_per_group = targs->warps_per_group;
  uint32_t groups_per_core = targs->groups_per_core;
  ...

  // [각 Warp, 각 활성 Thread] 반복 횟수 계산 (Warp마다 다를 수 있음)
  uint32_t iterations = warp_batches + (warp_id < remaining_warps);

  // [각 Warp, 각 활성 Thread] 자신이 속한 그룹 계산 (Warp마다 다름)
  uint32_t local_group_id = warp_id / warps_per_group;
  uint32_t group_warp_id = warp_id - local_group_id * warps_per_group;
  
  // [각 Warp, 각 활성 Thread] Thread별 task ID 계산 (Thread마다 다름)
  uint32_t local_task_id = group_warp_id * threads_per_warp + thread_id;

  // [각 Warp, 각 활성 Thread] Thread-local 변수 설정
  __local_group_id = local_group_id;
  threadIdx.x = local_task_id % blockDim_x;
  threadIdx.y = (local_task_id / blockDim_x) % blockDim_y;
  threadIdx.z = local_task_id / blockDim_xy;

  // [각 Warp, 각 활성 Thread] 시작 그룹 계산
  uint32_t start_group = targs->group_offset + local_group_id;
  uint32_t group_stride = groups_per_core;
  uint32_t end_group = start_group + iterations * group_stride;

  // [각 Warp, 각 활성 Thread] 콜백 포인터 로드
  vx_kernel_func_cb callback = targs->callback;
  const void* arg = targs->arg;

  // [각 Warp, 각 활성 Thread] 루프: 모든 thread가 같은 횟수 반복
  for (uint32_t group_id = start_group; group_id < end_group; group_id += group_stride) {
    // [각 Warp, 각 활성 Thread] blockIdx 설정 (같은 Warp 내에서는 같은 값)
    blockIdx.x = group_id % gridDim_x;
    blockIdx.y = (group_id / gridDim_x) % gridDim_y;
    blockIdx.z = group_id / (gridDim_x * gridDim_y);
    
    // [각 Warp, 각 활성 Thread] 커널 함수 호출
    // 각 thread는 서로 다른 threadIdx를 가지고 같은 blockIdx에서 실행
    callback((void*)arg);
  }
}
```

**핵심 포인트**:
- 모든 코드 라인이 **각 Warp의 각 활성 Thread**에서 실행됨
- `warp_id`, `thread_id`는 각 thread마다 다른 값
- CSR 읽기, 파라미터 로드는 모든 thread가 같은 값을 읽음 (공유 메모리)
- `threadIdx`, `__local_group_id`는 `__thread` 변수로 각 thread별 독립 저장

### 6.4 `process_threads_stub` (Lines 101-110)

**실행 주체**: `vx_wspawn`으로 활성화된 **각 Warp의 Thread 0만** (초기 진입 시)

```c
static void process_threads_stub() {
  // [각 Warp, Thread 0] 해당 warp의 모든 threads 활성화
  vx_tmc(-1);

  // ★ 여기서부터는 [각 Warp, All Threads] 실행
  process_threads();

  // [각 Warp, All Threads] 해당 warp의 모든 threads 비활성화
  vx_tmc_zero();
}
```

**핵심 포인트**:
- 함수 진입: 각 Warp의 Thread 0만
- `vx_tmc(-1)` 이후: 각 Warp의 모든 Threads
- `vx_tmc_zero()` 이후: 모든 Threads 비활성화

### 6.5 `process_threads` (Lines 56-79)

**실행 주체**: **각 Warp의 모든 활성화된 Threads**

```c
static void process_threads() {
  // [각 Warp, 각 Thread] CSR 읽기
  wspawn_threads_args_t* targs = (wspawn_threads_args_t*)csr_read(VX_CSR_MSCRATCH);

  // [각 Warp, 각 Thread] 자신의 ID 조회
  uint32_t threads_per_warp = vx_num_threads();
  uint32_t warp_id = vx_warp_id();      // Warp마다 다름
  uint32_t thread_id = vx_thread_id();  // Thread마다 다름

  // [각 Warp, 각 Thread] 파라미터 로드
  uint32_t remaining_warps = targs->remaining_warps;
  uint32_t warp_batches = targs->warp_batches;

  // [각 Warp, 각 Thread] Warp별 시작 위치 계산
  uint32_t start_warp_add = (warp_id < remaining_warps) ? warp_id : remaining_warps;
  uint32_t start_warp = warp_id * warp_batches + start_warp_add;
  uint32_t iterations = warp_batches + (warp_id < remaining_warps);

  // [각 Warp, 각 Thread] Thread별 task ID 범위 계산
  uint32_t start_task_id = targs->all_tasks_offset + start_warp * threads_per_warp + thread_id;
  uint32_t end_task_id = start_task_id + iterations * threads_per_warp;

  // [각 Warp, 각 Thread] grid 정보 로드
  uint32_t gridDim_x = gridDim.x;
  uint32_t gridDim_y = gridDim.y;

  // [각 Warp, 각 Thread] 콜백 포인터 로드
  vx_kernel_func_cb callback = targs->callback;
  const void* arg = targs->arg;

  // [각 Warp, 각 Thread] 루프: thread마다 다른 task_id 범위
  for (uint32_t task_id = start_task_id; task_id < end_task_id; task_id += threads_per_warp) {
    // [각 Warp, 각 Thread] blockIdx 계산 (thread마다 다름)
    blockIdx.x = task_id % gridDim_x;
    blockIdx.y = (task_id / gridDim_x) % gridDim_y;
    blockIdx.z = task_id / (gridDim_x * gridDim_y);
    
    // [각 Warp, 각 Thread] 커널 함수 호출
    callback((void*)arg);
  }
}
```

**핵심 포인트**:
- 모든 라인이 **각 Warp의 각 Thread**에서 실행
- `start_task_id`, `end_task_id`는 각 thread마다 다름 (thread_id에 의해)
- 각 thread는 서로 다른 `blockIdx`에서 커널을 실행

### 6.6 `process_remaining_threads` (Lines 81-89)

**실행 주체**: **Warp 0의 특정 mask에 해당하는 Threads만**

```c
static void process_remaining_threads() {
  // [Warp 0, 특정 Threads] CSR 읽기
  wspawn_threads_args_t* targs = (wspawn_threads_args_t*)csr_read(VX_CSR_MSCRATCH);

  // [Warp 0, 특정 Threads] 자신의 ID 조회
  uint32_t thread_id = vx_thread_id();
  
  // [Warp 0, 특정 Threads] task ID 계산 (thread마다 다름)
  uint32_t task_id = targs->remain_tasks_offset + thread_id;
  
  // [Warp 0, 특정 Threads] blockIdx 계산
  blockIdx.x = task_id % gridDim.x;
  blockIdx.y = (task_id / gridDim.x) % gridDim.y;
  blockIdx.z = task_id / (gridDim.x * gridDim.y);
  
  // [Warp 0, 특정 Threads] 커널 함수 호출
  (targs->callback)((void*)targs->arg);
}
```

**핵심 포인트**:
- Warp 0의 `vx_tmc(tmask)`로 활성화된 threads만 실행
- 각 thread는 서로 다른 `task_id`와 `blockIdx`를 가짐

### 6.7 실행 주체 요약표

| 함수 | 초기 진입 주체 | 중간 변화 | 최종 실행 주체 |
|------|---------------|----------|---------------|
| `vx_spawn_threads` | Core별 Warp 0, Thread 0 | `vx_tmc(-1)` 또는 `vx_tmc(tmask)` 호출 | Warp 0의 활성화된 threads |
| `process_thread_groups_stub` | 각 Warp의 Thread 0 | `vx_tmc(threads_mask)` 호출 | 각 Warp의 mask threads |
| `process_thread_groups` | 각 Warp의 활성 threads | 변화 없음 | 각 Warp의 활성 threads |
| `process_threads_stub` | 각 Warp의 Thread 0 | `vx_tmc(-1)` 호출 | 각 Warp의 모든 threads |
| `process_threads` | 각 Warp의 모든 threads | 변화 없음 | 각 Warp의 모든 threads |
| `process_remaining_threads` | Warp 0의 특정 threads | 변화 없음 | Warp 0의 특정 threads |

### 6.8 주요 인사이트

1. **`vx_tmc`의 역할**: Thread Mask Control로 warp 내 어떤 threads를 활성화할지 제어
2. **`vx_wspawn`의 역할**: 여러 warp를 깨우되, 각 warp의 Thread 0만 지정 함수로 진입
3. **CSR 공유**: `VX_CSR_MSCRATCH`는 Core 단위 공유이므로 모든 warp/thread가 같은 값 읽음
4. **Thread-local 변수**: `__thread` 키워드가 붙은 변수(`blockIdx`, `threadIdx` 등)는 각 thread별 독립 저장
5. **SIMD 실행**: 같은 warp 내 threads는 같은 코드를 실행하지만 다른 데이터(thread_id 기반)로 처리
6. **Physical vs Virtual Warp**:
   - **`vx_warp_id()`는 물리적(physical) warp ID를 반환** (0 ~ warps_per_core-1, 예: 0~3)
   - Virtual warp 개념은 존재하지 않음
   - 대신 **warp batching**을 통해 하나의 물리적 warp가 시간을 나눠 여러 논리적 그룹을 처리
   - 예: warp_id=0인 물리적 warp가 루프를 돌며 group 0, 4, 8, ... 을 순차 처리

### 6.9 Local Memory 주소 파티셔닝 메커니즘

**Vortex의 똑똑한 설계: 소프트웨어 주소 분리**

Vortex는 Core당 1개의 물리적 Local Memory를 가지지만, **소프트웨어적으로 주소 공간을 분할**하여 동시에 여러 Thread Group이 안전하게 실행될 수 있습니다.

**메커니즘:**

1. **`__local_group_id` 할당** (vx_spawn.c:132-133):
   ```c
   uint32_t local_group_id = warp_id / warps_per_group;
   __local_group_id = local_group_id;  // 각 그룹마다 고유 ID (0, 1, 2, ...)
   ```

2. **주소 계산 매크로** (vx_spawn.h:45-46):
   ```c
   #define __local_mem(size) \
     (void*)((int8_t*)csr_read(VX_CSR_LOCAL_MEM_BASE) + __local_group_id * size)
   ```

3. **실제 주소 분리 예시:**
   ```
   LMEM_BASE = 0x80000000
   각 그룹이 1KB 요청 시:
   
   Group 0 (local_group_id=0) → 0x80000000 + 0*1024 = 0x80000000
   Group 1 (local_group_id=1) → 0x80000000 + 1*1024 = 0x80000400
   Group 2 (local_group_id=2) → 0x80000000 + 2*1024 = 0x80000800
   Group 3 (local_group_id=3) → 0x80000000 + 3*1024 = 0x80000C00
   ```

**동시 실행 시나리오:**

| 시나리오 | 값 | 설명 |
|---------|-----|------|
| `warps_per_core` | 4 | Core당 물리적 warp 수 |
| `warps_per_group` | 2 | 그룹당 필요한 warp 수 |
| `groups_per_core` | 2 | 동시 실행 가능 그룹 수 |
| Local mem per group | 512 bytes | 각 그룹 요청 크기 |
| **Total LMEM 필요** | **1024 bytes** | 2 * 512 |
| **실제 LMEM 크기** | **16KB** | `1 << 14` ✓ 충분! |

**Strided Loop의 의미:**
```c
// Warp 0-1 (local_group_id=0): Group 0, 2, 4, 6, ...
// Warp 2-3 (local_group_id=1): Group 1, 3, 5, 7, ...
for (uint32_t group_id = start_group; group_id < end_group; group_id += group_stride) {
    // 각 iteration에서 local_group_id는 동일 → 같은 local memory 영역 재사용
}
```

**제약 조건:**
- `groups_per_core * local_memory_per_group <= LMEM_SIZE (16KB)`
- 예: 동시 4개 그룹 실행 시 각 그룹은 최대 4KB까지 사용 가능

### 6.10 그룹 일관성 보장: 같은 Block의 Warps는 항상 같은 Iteration에서 실행

**핵심 설계 원칙**: 하나의 Thread Group(Block)을 구성하는 모든 Warps는 **반드시 같은 iteration에서 동시에 실행**되어야 합니다.

#### 보장 메커니즘

**1. Active Warps 계산 (vx_spawn.c:237):**
```c
active_warps = groups_per_core * warps_per_group;
```

이 계산은 `active_warps`가 항상 **완전한 그룹들의 집합**임을 보장합니다.

**예시:**
- `warps_per_core = 6`
- `warps_per_group = 2` (한 그룹당 2개 warp 필요)
- `groups_per_core = 6 / 2 = 3` (동시에 3개 그룹 처리 가능)
- `active_warps = 3 * 2 = 6` (6개 warp는 정확히 3개 완전한 그룹)

**Warp 배치:**
```
Warp 0-1 → Group 0 (local_group_id=0)
Warp 2-3 → Group 1 (local_group_id=1)
Warp 4-5 → Group 2 (local_group_id=2)
```

**2. Iteration 횟수 계산 (vx_spawn.c:127):**
```c
uint32_t iterations = warp_batches + (warp_id < remaining_warps);
```

**같은 그룹의 warps는 항상 같은 `iterations` 값:**

```c
// 예: total_warps_per_core = 20, active_warps = 6
warp_batches = 20 / 6 = 3
remaining_warps = 20 - 18 = 2

// Group 0 (Warp 0-1):
Warp 0: iterations = 3 + (0 < 2) = 4  ✓
Warp 1: iterations = 3 + (1 < 2) = 4  ✓ 같음!

// Group 1 (Warp 2-3):
Warp 2: iterations = 3 + (2 < 2) = 3  ✓
Warp 3: iterations = 3 + (3 < 2) = 3  ✓ 같음!

// Group 2 (Warp 4-5):
Warp 4: iterations = 3 + (4 < 2) = 3  ✓
Warp 5: iterations = 3 + (5 < 2) = 3  ✓ 같음!
```

`remaining_warps = 2`는 정확히 Group 0 전체(2개 warps)를 1회 더 실행시킵니다.

**3. Loop 동기화 (vx_spawn.c:130-149):**
```c
uint32_t local_group_id = warp_id / warps_per_group;
uint32_t start_group = targs->group_offset + local_group_id;
uint32_t group_stride = groups_per_core;

for (uint32_t group_id = start_group; group_id < end_group; group_id += group_stride) {
    // Warp 0과 Warp 1은 항상 같은 group_id 처리
    blockIdx.x = group_id % gridDim_x;
    blockIdx.y = (group_id / gridDim_x) % gridDim_y;
    blockIdx.z = group_id / (gridDim_x * gridDim_y);
    callback((void*)arg);
}
```

**Iteration별 처리:**
```
Iteration 1:
  Warp 0-1 (local_group_id=0): group_id = 0 + 0 = 0
  Warp 2-3 (local_group_id=1): group_id = 0 + 1 = 1
  Warp 4-5 (local_group_id=2): group_id = 0 + 2 = 2

Iteration 2:
  Warp 0-1: group_id = 0 + 3 = 3
  Warp 2-3: group_id = 1 + 3 = 4
  Warp 4-5: group_id = 2 + 3 = 5
```

#### 이 보장이 필요한 이유

**1. Barrier 동기화 (`__syncthreads()`):**
```c
// vx_spawn.h:48-49
#define __syncthreads() \
  vx_barrier(__local_group_id, __warps_per_group)
```

- 같은 block의 모든 threads(여러 warps 포함)가 barrier에 도달해야 진행
- Warp 0이 Iteration 4에서 barrier 호출
- Warp 1도 반드시 Iteration 4에 있어야 함
- **다른 iteration에 있으면 Deadlock!**

**2. Local Memory 일관성:**
```c
// 같은 local_group_id의 warps는 같은 주소 공유
__local_mem(size) = BASE + __local_group_id * size
```

- Warp 0-1은 `BASE + 0 * size` 공유
- 같은 iteration에서 같은 block을 처리해야 데이터 일관성 보장
- OpenCL/CUDA semantics: 한 work-group 내의 모든 work-items는 같은 shared memory 공유

**3. Block-level Semantics:**
- CUDA/OpenCL 모델: 한 Thread Block은 원자적 실행 단위
- 모든 threads가 동시에 시작하고 종료
- 중간에 일부만 실행되는 상태는 허용되지 않음

#### 보장 검증

**잘못된 구현 (가상의 버그):**
```c
// 만약 이렇게 했다면? (실제 코드 아님)
active_warps = warps_per_core;  // 6
// 그룹 경계 무시하고 모든 warp 활성화

warp_batches = 20 / 6 = 3
remaining_warps = 2

// 문제 발생:
Warp 0 (Group 0): 4회 반복
Warp 1 (Group 0): 4회 반복  ✓ 같음
Warp 2 (Group 1): 3회 반복
Warp 3 (Group 1): 3회 반복  ✓ 같음
Warp 4 (Group 2): 3회 반복
Warp 5 (Group 2): 3회 반복  ✓ 같음

// → 우연히 동작 (remaining_warps가 짝수)

// 하지만 remaining_warps=3이면?
Warp 0 (Group 0): 4회
Warp 1 (Group 0): 4회  ✓
Warp 2 (Group 1): 4회
Warp 3 (Group 1): 3회  ✗ 다름! → DEADLOCK!
```

**올바른 구현 (실제 코드):**
```c
active_warps = groups_per_core * warps_per_group;  // 3 * 2 = 6
// 항상 완전한 그룹 단위로만 활성화

// remaining_warps가 홀수여도 안전:
// remaining_warps는 "몇 개 warp"가 아니라 
// "몇 개 완전한 그룹"을 추가 실행할지 결정하는 threshold
```

#### 요약

| 측면 | 보장 내용 |
|------|----------|
| **Warp 배치** | `active_warps = groups_per_core * warps_per_group`로 완전한 그룹 단위 |
| **Iteration 횟수** | 같은 그룹의 모든 warps는 항상 같은 `iterations` 값 |
| **Loop 동기화** | 같은 `local_group_id`는 같은 `group_id` (block) 처리 |
| **Barrier 안전성** | `__syncthreads()`에서 같은 iteration이므로 deadlock 없음 |
| **Memory 일관성** | 같은 `__local_group_id`로 local memory 주소 공유 안전 |

이 설계 덕분에 Vortex는 **CUDA/OpenCL의 Thread Block 동기화 semantics를 완벽히 준수**합니다.

## 7. 요약

1.  **가상화**: `vx_spawn.c`는 물리적 Warp 수의 한계를 극복하기 위해 **Batching(Loop)** 기법을 사용합니다.
2.  **통신**: Warp 0(메인)이 계산한 스케줄링 정보를 `MSCRATCH` CSR을 통해 다른 Warp들에게 전달합니다.
3.  **하드웨어 제어**: `wspawn` 명령어로 잠자고 있던 하드웨어 Warp들을 깨우고, `tmc` 명령어로 각 Warp 내의 Thread들을 제어합니다.
4.  **계층 구조**:
    - **Grid/Block (SW)** -> **Batch/Group (Runtime)** -> **Warp/Thread (HW)**
