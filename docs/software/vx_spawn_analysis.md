# Vortex Runtime: Warp Spawn 및 실행 흐름 분석

이 문서는 Vortex 런타임(`vx_spawn.c`)이 어떻게 커널을 실행하고, 하드웨어와 상호작용하여 Warp를 생성(Spawn)하고 관리하는지 분석합니다.

## 1. 개요

Vortex는 하드웨어적으로는 고정된 수의 Warp(`NUM_WARPS`)를 가지고 있지만, 소프트웨어적으로는 훨씬 많은 수의 Thread와 Block을 처리해야 합니다. `vx_spawn.c`는 이 **가상화(Virtualization)**를 담당하는 핵심 런타임 코드입니다.

- **역할**: 사용자 요청(Grid/Block)을 물리적 하드웨어(Core/Warp)에 매핑
- **핵심 메커니즘**:
  1. **Work Distribution**: 전체 작업을 코어별로 분배
  2. **Warp Batching**: 물리적 Warp 수보다 많은 작업은 시간 분할(Batching)로 처리
  3. **Hardware Intrinsics**: `vx_wspawn`, `vx_tmc` 등을 통해 하드웨어 제어

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

## 4. 실행 흐름 상세 예시

**상황 가정**:
- **HW**: 1 Core, 4 Warps, 4 Threads/Warp (총 16 Threads)
- **SW**: Grid={2,1,1}, Block={8,1,1} (총 16 Threads)
  - Block 0: 8 threads
  - Block 1: 8 threads

### 단계별 동작

1.  **리소스 계산**:
    - `group_size` = 8 threads
    - `warps_per_group` = 8 / 4 = **2 warps** (Block 하나당 2개 Warp 필요)
    - `total_groups_per_core` = 2 blocks (Core 0이 2개 Block 모두 처리)
    - `total_warps_per_core` = 2 blocks * 2 warps/block = **4 warps**

2.  **Batching 계산**:
    - `active_warps` = 4 (HW 최대치인 4 이하이므로 4개 모두 사용)
    - `warp_batches` = 1 (한 번에 처리 가능)

3.  **Warp 매핑**:
    - **Warp 0, 1** -> Block 0 처리
    - **Warp 2, 3** -> Block 1 처리

4.  **`vx_wspawn` 호출**:
    - Warp 0이 `vx_wspawn(4, stub)` 호출
    - 하드웨어 스케줄러가 Warp 1, 2, 3을 활성화하고 PC를 `stub` 함수로 설정

5.  **`process_thread_groups_stub` 실행 (모든 Warp 병렬 실행)**:
    ```c
    // 각 Warp는 자신의 ID를 확인
    uint32_t warp_id = vx_warp_id(); // 0, 1, 2, 3
    
    // 자신이 속한 논리적 그룹(Block) 계산
    // warps_per_group = 2
    uint32_t local_group_id = warp_id / 2; 
    // Warp 0,1 -> Group 0 (Block 0)
    // Warp 2,3 -> Group 1 (Block 1)
    
    // Thread Mask 설정 (모두 활성화)
    vx_tmc(-1); 
    
    // 실제 작업 수행
    process_thread_groups();
    ```

6.  **`process_thread_groups` 실행**:
    - `blockIdx`, `threadIdx` 설정
    - `callback(arg)` 호출 -> 사용자 커널 함수 실행

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

## 6. 요약

1.  **가상화**: `vx_spawn.c`는 물리적 Warp 수의 한계를 극복하기 위해 **Batching(Loop)** 기법을 사용합니다.
2.  **통신**: Warp 0(메인)이 계산한 스케줄링 정보를 `MSCRATCH` CSR을 통해 다른 Warp들에게 전달합니다.
3.  **하드웨어 제어**: `wspawn` 명령어로 잠자고 있던 하드웨어 Warp들을 깨우고, `tmc` 명령어로 각 Warp 내의 Thread들을 제어합니다.
4.  **계층 구조**:
    - **Grid/Block (SW)** -> **Batch/Group (Runtime)** -> **Warp/Thread (HW)**
