# Vortex RISC-V ISA Extension 명령어 분석

Vortex는 RISC-V ISA를 확장하여 GPU 스타일의 SIMT(Single Instruction Multiple Threads) 실행을 지원합니다. 이 문서는 Vortex의 주요 ISA extension 명령어들의 역할과 사용 방법을 설명합니다.

## 목차

- [개요](#개요)
- [명령어 분류](#명령어-분류)
- [명령어 상세](#명령어-상세)
  - [TMC (Thread Mask Control)](#tmc-thread-mask-control)
  - [WSPAWN (Warp Spawn)](#wspawn-warp-spawn)
  - [SPLIT / JOIN](#split--join)
  - [PRED (Predicate)](#pred-predicate)
  - [BAR (Barrier)](#bar-barrier)
- [실제 활용 시나리오](#실제-활용-시나리오)
- [하드웨어 구현](#하드웨어-구현)

---

## 개요

Vortex의 ISA extension은 다음과 같은 계층적 병렬성을 제공합니다:

```
Processor
├── Core (multiple)
│   ├── Warp (multiple)
│   │   └── Thread (multiple)
```

- **Thread**: SIMD lane, warp 내에서 같은 명령어를 실행
- **Warp**: Thread 그룹, 독립적인 PC를 가짐
- **Core**: Warp 스케줄러를 포함, 여러 warp를 시분할 실행

## 명령어 분류

| 명령어 | 제어 대상 | 주요 용도 |
|--------|----------|-----------|
| **TMC** | Thread (warp 내) | SIMD 병렬 실행, 부분 thread 활성화 |
| **WSPAWN** | Warp (코어 내) | 병렬 커널 실행, warp 레벨 병렬성 |
| **SPLIT/JOIN** | Thread (divergence) | if-else 분기 처리, control flow divergence |
| **PRED** | Thread (predication) | 간단한 조건부 실행 |
| **BAR** | Warp (동기화) | `__syncthreads()`, shared memory 일관성 보장 |

---

## 명령어 상세

### TMC (Thread Mask Control)

**목적**: Warp 내에서 어떤 thread들을 활성화할지 제어

**함수 인터페이스**:
```c
void vx_tmc(int thread_mask);     // 특정 threads 활성화
void vx_tmc_zero();                // 모든 threads 비활성화
void vx_tmc_one();                 // thread 0만 활성화
```

**어셈블리 인코딩**:
```asm
.insn r RISCV_CUSTOM0, 0, 0, x0, thread_mask, x0
```

**사용 예시**:
```c
// 예시 1: 특정 수의 threads만 활성화
int num_threads = 4;
int tmask = (1 << num_threads) - 1;  // 0b1111
vx_tmc(tmask);
do_work();        // thread 0,1,2,3만 실행
vx_tmc_one();     // 다시 thread 0만 활성화

// 예시 2: 모든 threads 활성화 (vx_spawn.c:327)
vx_tmc(-1);       // 0xFFFFFFFF = all threads
process_threads();
vx_tmc_one();
```

**테스트 코드** ([tests/kernel/conform/tests.cpp:87](../../tests/kernel/conform/tests.cpp#L87)):
```c
int test_tmc() {
    int num_threads = std::min(vx_num_threads(), 8);
    int tmask = make_full_tmask(num_threads);
    
    vx_tmc(tmask);
    do_tmc();      // 각 thread가 다른 값 저장
    vx_tmc_one();
    
    return check_error(tmc_buffer, 0, num_threads);
}
```

**하드웨어 동작** ([hw/rtl/core/VX_schedule.sv:136](../../hw/rtl/core/VX_schedule.sv#L136)):
- `thread_masks[wid]` 레지스터를 업데이트
- `tmask`가 0이면 해당 warp를 비활성화 상태로 전환
- SIMD 스타일 병렬 실행의 핵심 메커니즘

---

### WSPAWN (Warp Spawn)

**목적**: 여러 warp를 동시에 활성화하고 특정 함수로 점프

**함수 인터페이스**:
```c
typedef void (*vx_wspawn_pfn)();
void vx_wspawn(int num_warps, vx_wspawn_pfn func_ptr);
```

**어셈블리 인코딩**:
```asm
.insn r RISCV_CUSTOM0, 1, 0, x0, num_warps, func_ptr
```

**사용 예시**:
```c
// vx_spawn.c:268 - Thread group 병렬 처리
wspawn_groups_args_t wspawn_args = {...};
csr_write(VX_CSR_MSCRATCH, &wspawn_args);

// 다른 warps를 깨워서 함수 실행
vx_wspawn(active_warps, process_thread_groups_stub);

// warp 0도 동일 함수 실행
process_thread_groups_stub();
```

**테스트 코드** ([tests/kernel/conform/tests.cpp:132](../../tests/kernel/conform/tests.cpp#L132)):
```c
void wspawn_kernel() {
    unsigned wid = vx_warp_id();
    wspawn_buffer[wid] = 65 + wid;
    vx_tmc(0 == wid);  // 작업 후 warp 0만 남기기
}

int test_wsapwn() {
    int num_warps = std::min(vx_num_warps(), 8);
    vx_wspawn(num_warps, wspawn_kernel);
    wspawn_kernel();  // warp 0도 실행
    return check_error(wspawn_buffer, 0, num_warps);
}
```

**하드웨어 동작** ([hw/rtl/core/VX_schedule.sv:126](../../hw/rtl/core/VX_schedule.sv#L126)):
- `wspawn.wmask`에 지정된 warp들을 활성화
- 각 warp의 PC를 `wspawn.pc`로 설정
- `thread_masks[i][0] = 1`로 초기화 (thread 0만 활성화)

**주요 사용 시나리오**:
- CUDA/OpenCL 커널 실행 시 여러 warp에 작업 분배
- 각 warp가 서로 다른 thread block 처리

---

### SPLIT / JOIN

**목적**: Control flow divergence 처리 (if-else 분기에서 threads가 다른 경로 선택)

**함수 인터페이스**:
```c
int vx_split(int predicate);      // predicate 기준 분기, stack pointer 반환
int vx_split_n(int predicate);    // not predicate 기준 분기
void vx_join(int stack_ptr);      // 분기 합류
```

**어셈블리 인코딩**:
```asm
.insn r RISCV_CUSTOM0, 2, 0, ret, predicate, x0   # SPLIT
.insn r RISCV_CUSTOM0, 3, 0, x0, stack_ptr, x0    # JOIN
```

**사용 예시**:

#### 간단한 분기
```c
int tid = vx_thread_id();
int cond = tid < 2;  // thread 0,1은 true, 2,3은 false

int sp = vx_split(cond);
if (cond) {
    // thread 0,1만 실행
    buffer[tid] = 65;
} else {
    // thread 2,3만 실행
    buffer[tid] = 66;
}
vx_join(sp);  // 모든 threads 재활성화
```

#### 중첩된 분기 ([tests/kernel/conform/tests.cpp:149](../../tests/kernel/conform/tests.cpp#L149))
```c
void do_divergence() {
    int tid = vx_thread_id();
    int cond1 = tid < 2;
    
    int sp1 = vx_split(cond1);
    if (cond1) {
        int cond2 = tid < 1;
        int sp2 = vx_split(cond2);
        if (cond2) {
            dvg_buffer[tid] = 65;  // thread 0
        } else {
            dvg_buffer[tid] = 66;  // thread 1
        }
        vx_join(sp2);
    } else {
        int cond2 = tid < 3;
        int sp2 = vx_split(cond2);
        if (cond2) {
            dvg_buffer[tid] = 67;  // thread 2
        } else {
            dvg_buffer[tid] = 68;  // thread 3
        }
        vx_join(sp2);
    }
    vx_join(sp1);
}
```

**하드웨어 동작**:

#### SPLIT ([hw/rtl/core/VX_wctl_unit.sv:113](../../hw/rtl/core/VX_wctl_unit.sv#L113)):
1. 각 thread의 predicate 평가하여 `then_tmask`와 `else_tmask` 계산
2. 두 mask가 모두 non-zero면 divergence 발생
3. IPDOM(Immediate Post-Dominator) stack에 현재 상태 저장:
   - `orig_tmask`: 원래 thread mask
   - `else_tmask`: 나중에 실행할 경로
   - `PC`: 합류 지점 주소
4. 먼저 실행할 경로의 threads만 활성화 (보통 더 많은 threads를 가진 경로)

#### JOIN ([hw/rtl/core/VX_schedule.sv:151](../../hw/rtl/core/VX_schedule.sv#L151)):
1. IPDOM stack에서 저장된 상태 pop
2. `else_tmask`가 있으면 해당 threads 활성화 및 PC 업데이트
3. 없으면 `orig_tmask`로 전체 threads 재활성화

**Stack Pointer 반환값**:
- Hardware divergence stack의 현재 depth 반환
- JOIN 시 해당 depth까지 pop하여 정확한 상태 복원

---

### PRED (Predicate)

**목적**: 특정 조건에 따라 thread mask 설정 (SPLIT보다 가벼운 divergence)

**함수 인터페이스**:
```c
void vx_pred(int condition, int thread_mask);
void vx_pred_n(int condition, int thread_mask);  // not predicate
```

**어셈블리 인코딩**:
```asm
.insn r RISCV_CUSTOM0, 5, 0, x0, condition, thread_mask
```

**사용 예시** ([tests/kernel/conform/tests.cpp:103](../../tests/kernel/conform/tests.cpp#L103)):
```c
void do_pred() {
    unsigned tid = vx_thread_id();
    vx_pred((tid == 0), 1);  // tid==0인 thread만 활성화
    pred_buffer[tid] = 65;   // thread 0만 실행
}

int test_pred() {
    int num_threads = std::min(vx_num_threads(), 8);
    int tmask = make_full_tmask(num_threads);
    
    // 다른 threads는 다른 값으로 초기화
    for (int i = 1; i < num_threads; i++) {
        pred_buffer[i] = 65 + i;
    }
    
    vx_tmc(tmask);
    do_pred();        // thread 0만 65 저장
    vx_tmc_one();
    
    return check_error(pred_buffer, 0, num_threads);
}
```

**하드웨어 동작 및 `restore_mask` (thread_mask 파라미터)**:

PRED 명령어의 두 번째 파라미터 `restore_mask`는 **fallback 메커니즘**을 제공합니다.

**RTL 구현** ([hw/rtl/core/VX_wctl_unit.sv:107](../../hw/rtl/core/VX_wctl_unit.sv#L107)):
```systemverilog
// 1. 각 thread의 condition 평가
for (genvar i = 0; i < NUM_LANES; ++i) begin
    assign taken[i] = (execute_if.data.rs1_data[i][0] ^ not_pred);
end
assign then_tmask = taken & execute_if.data.tmask;

// 2. 조건을 만족하는 thread가 있는가?
wire has_then = (then_tmask != 0);

// 3. Thread mask 결정 (핵심!)
wire pred_mask = has_then ? then_tmask : rs2_data[NUM_THREADS-1:0];
assign tmc.tmask = is_pred ? pred_mask : rs1_data[NUM_THREADS-1:0];
```

**동작 로직**:
1. **조건 평가**: 각 활성화된 thread의 `condition` 비트 확인
2. **Then mask 계산**: 조건을 만족하는 threads의 mask
3. **최종 mask 결정**:
   - **`has_then == true`** (조건 만족 thread 존재): `then_tmask` 사용
   - **`has_then == false`** (조건 만족 thread 없음): `restore_mask` 사용 ← **Fallback!**

**시뮬레이터 구현** ([sim/simx/execute.cpp:1385](../../sim/simx/execute.cpp#L1385)):
```cpp
ThreadMask pred(num_threads);
for (uint32_t t = 0; t < num_threads; ++t) {
  auto cond = (rs1_data.at(t).i & 0x1) ^ not_pred;
  pred[t] = warp.tmask.test(t) && cond;
}

if (pred.any()) {
  next_tmask &= pred;              // 조건 만족: predicate 적용
} else {
  next_tmask = ThreadMask(num_threads, rs2_data.at(thread_last).u);  // Fallback
}
```

**`restore_mask` 사용 예시**:

```c
// 패턴 1: 조건 만족 thread만 실행, 없으면 모든 threads 활성화
vx_pred(some_condition, -1);  // restore_mask = 0xFFFFFFFF

// 패턴 2: 조건 만족 thread만 실행, 없으면 thread 0으로 복귀
vx_pred((tid == target), 1);  // restore_mask = 0b0001

// 패턴 3: 조건 만족 thread만 실행, 없으면 아무것도 안함
vx_pred(some_condition, 0);   // restore_mask = 0b0000

// 실제 사용 예 (tests/kernel/conform/tests.cpp)
vx_tmc(0b1111);  // thread 0,1,2,3 활성화
vx_pred((tid == 0), 1);  
// -> tid==0이 활성화되어 있으면: thread 0만
// -> tid==0이 비활성화되어 있으면: restore_mask=1로 thread 0 복원
```

**왜 이런 설계인가?**

이는 **warp divergence에서 안전성을 보장**하기 위한 설계입니다:

```c
// 문제 상황: 모든 활성화된 threads가 조건을 만족하지 않으면?
vx_tmc(0b1110);  // thread 1,2,3 활성화
vx_pred((tid == 0), 1);  
// -> tid==0은 비활성화 상태 → then_tmask = 0b0000
// -> has_then = false
// -> restore_mask = 1 적용 → thread 0 활성화 (안전한 fallback)
```

Fallback 없이 모든 threads가 비활성화되면 warp가 완전히 정지(stall)될 수 있습니다.

**SPLIT vs PRED 비교**:

| 특성 | SPLIT/JOIN | PRED |
|------|-----------|------|
| **Then 경로** | 조건 만족 threads 실행 | 조건 만족 threads 실행 |
| **Else 경로** | Stack에 저장 후 나중에 실행 | **restore_mask로 즉시 fallback** |
| **조건 실패 시** | Else 경로 자동 실행 | restore_mask 적용 |
| **Stack 사용** | O | X |
| **양방향 실행** | 가능 (then/else 모두) | 불가 (한쪽만) |
| **중첩 가능** | O | 제한적 |
| **오버헤드** | 높음 | 낮음 |
| **사용 사례** | if-else 분기 | 단순 필터링, 조건부 실행 |

---

### BAR (Barrier)

**목적**: 여러 warp들이 특정 지점에서 만날 때까지 대기 (동기화)

**함수 인터페이스**:
```c
void vx_barrier(int barrier_id, int num_warps);
```

**어셈블리 인코딩**:
```asm
.insn r RISCV_CUSTOM0, 4, 0, x0, barrier_id, num_warps
```

**사용 예시**:

#### CUDA 스타일 동기화 ([kernel/include/vx_spawn.h:48](../../kernel/include/vx_spawn.h#L48)):
```c
#define __syncthreads() \
  vx_barrier(__local_group_id, __warps_per_group)

// 사용 예
__shared__ int data[256];

// Phase 1: 각 thread가 데이터 작성
data[threadIdx.x] = input[threadIdx.x];

// 모든 threads가 작성 완료까지 대기
__syncthreads();

// Phase 2: 다른 thread의 데이터 읽기 (안전함)
int neighbor = data[threadIdx.x + 1];
```

#### 명시적 barrier 사용:
```c
// 4개 warps가 동기화
vx_barrier(0, 4);  // barrier_id=0, num_warps=4

// barrier 도달 순서:
// warp 0: barrier 도달 -> 대기
// warp 1: barrier 도달 -> 대기
// warp 2: barrier 도달 -> 대기
// warp 3: barrier 도달 -> 모든 warp unlock!
```

**하드웨어 동작** ([hw/rtl/core/VX_schedule.sv:161](../../hw/rtl/core/VX_schedule.sv#L161)):
1. `barrier_masks[barrier_id][wid] = 1` 설정
2. `barrier_ctrs[barrier_id]++` 증가
3. 현재 warp를 `barrier_stalls[wid] = 1`로 stall
4. Counter가 `num_warps - 1`에 도달하면:
   - Counter와 mask 리셋
   - 해당 barrier에 대기 중인 모든 warp unlock

**Global Barrier** (선택적 기능):
```c
// 여러 core에 걸친 동기화
vx_barrier(barrier_id | 0x80000000, total_warps_across_cores);
```

---

## 실제 활용 시나리오

### CUDA 커널 실행 시뮬레이션

```c
// CUDA 코드
__global__ void kernel(int* data, int threshold) {
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    
    __shared__ int shared_data[256];
    
    // Phase 1: Load
    shared_data[tid] = data[bid * 256 + tid];
    __syncthreads();
    
    // Phase 2: Compute with divergence
    if (shared_data[tid] > threshold) {
        shared_data[tid] *= 2;
    } else {
        shared_data[tid] += 1;
    }
    __syncthreads();
    
    // Phase 3: Store
    data[bid * 256 + tid] = shared_data[tid];
}
```

**Vortex 구현** ([kernel/src/vx_spawn.c:180](../../kernel/src/vx_spawn.c#L180)):
```c
// 1. Warp 요구량 계산
uint32_t warps_per_group = block_size / threads_per_warp;

// 2. 여러 warp 활성화
vx_wspawn(active_warps, process_thread_groups_stub);

// 3. 각 warp에서 모든 threads 활성화
vx_tmc(-1);

// 4. Phase 1: Load (all threads)
shared_data[tid] = data[bid * 256 + tid];
vx_barrier(block_id, warps_per_group);

// 5. Phase 2: Compute (with divergence)
int cond = (shared_data[tid] > threshold);
int sp = vx_split(cond);
if (cond) {
    shared_data[tid] *= 2;
} else {
    shared_data[tid] += 1;
}
vx_join(sp);

vx_barrier(block_id, warps_per_group);

// 6. Phase 3: Store (all threads)
data[bid * 256 + tid] = shared_data[tid];

vx_tmc_one();  // 작업 완료, thread 0로 복귀
```

### Work Distribution 패턴

```c
// vx_spawn.c의 실제 패턴
void vx_spawn_threads(...) {
    // 1. 스케줄링 계산 (warp 0, thread 0만)
    uint32_t warps_per_group = group_size / threads_per_warp;
    uint32_t groups_per_core = warps_per_core / warps_per_group;
    
    // 2. 인자를 공유 메모리(CSR)에 저장
    csr_write(VX_CSR_MSCRATCH, &wspawn_args);
    
    // 3. 다른 warps 활성화
    vx_wspawn(active_warps, process_thread_groups_stub);
    
    // 4. warp 0도 작업 시작
    process_thread_groups_stub();
}

void process_thread_groups_stub() {
    // 5. CSR에서 인자 읽기
    wspawn_groups_args_t* args = csr_read(VX_CSR_MSCRATCH);
    
    // 6. 이 warp의 threads 활성화
    uint32_t warp_id = vx_warp_id();
    uint32_t group_warp_id = warp_id % warps_per_group;
    uint32_t threads_mask = (group_warp_id == warps_per_group-1) 
                          ? args->remaining_mask 
                          : -1;
    vx_tmc(threads_mask);
    
    // 7. 실제 작업 수행
    process_thread_groups();
    
    // 8. warp 0만 남기기
    vx_tmc(0 == vx_warp_id());
}
```

---

## 하드웨어 구현

### 주요 모듈

#### 1. VX_wctl_unit.sv
- Warp control 명령어 디코딩 및 실행
- TMC, PRED, SPLIT, JOIN, BARRIER, WSPAWN 처리
- IPDOM stack과 상호작용

#### 2. VX_schedule.sv
- Warp 스케줄링 및 상태 관리
- 레지스터:
  - `active_warps`: 활성 warp mask
  - `stalled_warps`: stall된 warp mask
  - `thread_masks[wid]`: 각 warp의 활성 thread mask
  - `warp_pcs[wid]`: 각 warp의 PC
  - `barrier_masks[barrier_id]`: barrier에 도달한 warp mask
  - `barrier_ctrs[barrier_id]`: barrier counter

#### 3. VX_split_join.sv
- IPDOM(Immediate Post-Dominator) stack 관리
- Divergence 상태 저장 및 복원
- Stack entry:
  ```systemverilog
  struct ipdom_entry_t {
      ThreadMask orig_tmask;   // 원래 thread mask
      ThreadMask else_tmask;   // else 경로 mask
      Word PC;                 // 합류 지점 PC
      bool fallthrough;        // fallthrough 여부
  }
  ```

### 명령어별 하드웨어 플로우

#### TMC
```
execute_if -> VX_wctl_unit -> warp_ctl_if.tmc
                              ↓
                         VX_schedule
                              ↓
                    active_warps[wid] = (tmask != 0)
                    thread_masks[wid] = tmask
                    stalled_warps[wid] = 0
```

#### WSPAWN
```
execute_if -> VX_wctl_unit -> warp_ctl_if.wspawn
                              ↓
                         VX_schedule
                              ↓
                    active_warps |= wmask
                    warp_pcs[i] = pc (for each i in wmask)
                    thread_masks[i][0] = 1
```

#### SPLIT
```
execute_if -> VX_wctl_unit -> Calculate then/else_tmask
                              ↓
                         VX_split_join
                              ↓
                    Push to IPDOM stack
                    Return stack_ptr
                              ↓
                         VX_schedule
                              ↓
                    thread_masks[wid] = then_tmask
```

#### JOIN
```
warp_ctl_if -> VX_split_join -> Pop from IPDOM stack
                                ↓
                           VX_schedule
                                ↓
                    if (else_tmask exists) {
                        thread_masks[wid] = else_tmask
                        warp_pcs[wid] = saved_pc
                    } else {
                        thread_masks[wid] = orig_tmask
                    }
```

#### BARRIER
```
execute_if -> VX_wctl_unit -> warp_ctl_if.barrier
                              ↓
                         VX_schedule
                              ↓
                    barrier_masks[id][wid] = 1
                    barrier_ctrs[id]++
                    
                    if (barrier_ctrs[id] == num_warps-1) {
                        barrier_ctrs[id] = 0
                        barrier_masks[id] = 0
                        stalled_warps &= ~barrier_masks[id]
                    }
```

---

## 참고 자료

### 소스 코드
- [kernel/include/vx_intrinsics.h](../../kernel/include/vx_intrinsics.h) - Intrinsic 함수 정의
- [kernel/src/vx_spawn.c](../../kernel/src/vx_spawn.c) - 실제 사용 예제
- [tests/kernel/conform/tests.cpp](../../tests/kernel/conform/tests.cpp) - 테스트 코드
- [hw/rtl/core/VX_wctl_unit.sv](../../hw/rtl/core/VX_wctl_unit.sv) - 하드웨어 구현
- [hw/rtl/core/VX_schedule.sv](../../hw/rtl/core/VX_schedule.sv) - Warp 스케줄러
- [hw/rtl/core/VX_split_join.sv](../../hw/rtl/core/VX_split_join.sv) - IPDOM stack

### 관련 문서
- [microarchitecture.md](../microarchitecture.md) - Vortex 마이크로아키텍처 개요
- [vx_spawn_analysis.md](vx_spawn_analysis.md) - vx_spawn 상세 분석
- [rtl/core_study_guide.md](../rtl/core_study_guide.md) - Core 구조 학습 가이드

---

## 요약

Vortex의 ISA extension은 GPU 스타일의 병렬 실행을 위한 완전한 기능 세트를 제공합니다:

1. **TMC**: Thread 레벨 병렬성 제어
2. **WSPAWN**: Warp 레벨 병렬성 생성
3. **SPLIT/JOIN**: Control flow divergence 처리
4. **PRED**: 경량 조건부 실행
5. **BAR**: Warp 간 동기화

이들은 CUDA/OpenCL 같은 고수준 병렬 프로그래밍 모델을 하드웨어에서 효율적으로 지원하기 위한 핵심 명령어들입니다.
