# TVM Vortex 2D/3D Thread Binding, Shared/Local Memory, Barrier Extension Plan

## 목표

현재 동작하는 TVM Vortex backend를 다음 기능까지 확장한다.

- `blockIdx.{x,y,z}`와 `threadIdx.{x,y,z}`를 사용하는 2D/3D launch geometry
- TVM `scope="local"` thread-private buffer
- TVM `scope="shared"` block-shared buffer
- `tvm_storage_sync("shared")`에 해당하는 block barrier
- 위 기능을 사용하는 DLight GPU schedule과 Relax VM model execution
- Vortex hardware configuration에 따른 thread/LMEM 제한 검증과 default barrier configuration 전제

최종 실행 흐름은 기존 구조를 유지한다.

```text
PyTorch model
  -> torch.export
  -> Relax
  -> Vortex-aware DLight schedule
  -> 2D/3D TIRx with local/shared buffers and barriers
  -> CodeGenVortex
  -> native Vortex C++
  -> Vortex device compiler / vxbin
  -> Relax VM
  -> VortexModule / VortexDeviceAPI
  -> vx_start
  -> existing vx_spawn_threads with compile-time resource validation
  -> physical U55C
```

성공 기준은 simulator에서 source를 생성하는 것이 아니라, 실제 U55C에서 shared-memory tiled kernel과 Relax model이 CPU/PyTorch reference와 일치하는 것이다.

## 현재 상태와 확인된 기반

### 이미 구현된 TVM 기능

- Vortex target, compiler callback, serializable `VortexModule`, `VortexDeviceAPI`
- `blockIdx.x`, `threadIdx.x` 기반 1D launch
- 최대 `4 warps * 32 threads = 128 threads/block` 검증
- static/global buffer argument와 scalar argument
- serial loop, multi-kernel dispatch, Relax VM bytecode/compiled mode
- `torch.export`로 가져온 dynamic-batch MLP의 U55C 실행
- launch packet의 `grid[3]`, `block[3]` 저장과 host-side block product 검증

### 이미 존재하는 Vortex native 기능

CodeGraph로 확인한 Vortex native API에는 필요한 저수준 기능 대부분이 이미 존재한다.

- `vx_spawn_threads(dimension, grid_dim, block_dim, ...)`는 최대 3차원을 지원한다.
- `vx_spawn.c`는 `threadIdx.{x,y,z}`와 `blockIdx.{x,y,z}`를 계산한다.
- `vx_spawn.h`는 block별 LMEM base를 계산하는 `__local_mem(size)`를 제공한다.
- `vx_spawn.h`는 `vx_barrier(__local_group_id, __warps_per_group)` 기반 `__syncthreads()`를 제공한다.
- `vx_dev_caps(..., VX_CAPS_LOCAL_MEM_SIZE, ...)`로 실제 local-memory 용량을 조회할 수 있다.
- pinned U55C configuration은 `NUM_THREADS=32`, `NUM_WARPS=4`, `LMEM_LOG_SIZE=20`이므로 thread capacity는 128, LMEM은 1 MiB이다.
- Physical U55C probe에서 같은 core의 resident block들은 동일한 raw LMEM base를 보았고, `__local_mem(size)`가 `__local_group_id * size` offset으로 block별 slice를 만드는 software contract임을 확인했다.

따라서 핵심 과제는 새 instruction이나 RTL을 추가하는 것이 아니라 다음 세 계약을 정확히 연결하는 것이다.

1. TVM의 3D launch metadata를 `vx_spawn_threads`에 전달한다.
2. TVM `shared` allocation을 Vortex LMEM의 block별 arena로 배치한다.
3. 기존 `vx_spawn_threads`가 block dimension으로 정하는 resident block 수를 유지하고, 그 수만큼의 block이 동시에 실행되어도 LMEM을 넘지 않는 kernel만 compile한다.

## 용어와 메모리 모델

TVM과 Vortex에서 `local`이라는 단어의 의미가 다르므로 구현에서 명확히 분리한다.

| TVM scope | 의미 | Vortex lowering |
|---|---|---|
| `global` | device global memory | 기존 Vortex pointer argument |
| `local` | thread-private temporary | callback 내부의 ordinary C++ stack/private array |
| `shared` | 같은 thread block이 공유 | Vortex core LMEM의 `__local_mem(total_shared_bytes)` arena |
| `shared.dyn` | launch 시 크기가 정해지는 shared memory | 이번 계획의 초기 범위에서 제외 |

Vortex hardware의 LMEM은 core-local scratchpad이다. TVM `shared` buffer 하나를 단순한 C++ stack array로 출력하면 thread마다 별도 copy가 생기므로 잘못된 lowering이다. 반대로 TVM `local` buffer를 `__local_mem`에 배치하면 thread-private semantics가 깨진다.

## 범위

### 포함

- static 2D/3D grid와 block geometry
- dynamic grid extent는 기존 packed launch argument 범위에서 허용
- compile-time constant thread block extent
- block 전체 thread 수가 hardware capacity 이하인지 product로 검증
- compile-time constant-size `local` buffer
- compile-time constant-size `shared` buffer
- 여러 shared buffer를 하나의 aligned block arena에 배치
- shared-memory block barrier
- 여러 barrier site에서 같은 block barrier ID의 순차적 재사용
- multi-kernel binary 안에서 kernel별 static shared-memory metadata
- direct TIRx와 Relax VM hardware validation
- Vortex-aware 2D/shared-memory DLight schedule
- 기존 `vx_spawn_threads`의 warp-based resident block 수를 전제로 한 compile-time LMEM 검증
- `NUM_BARRIERS=UP(NUM_WARPS/2)` default 관계를 유지하는 hardware

### 초기 제외

- `shared.dyn`과 launch-time dynamic shared-memory byte count
- grid 전체를 동기화하는 global barrier
- cooperative launch
- 독립적인 named barrier, split-phase barrier, 직접 지정하는 `vx_barrier(id, count)`
- stream, asynchronous execution, concurrent Vortex kernel launch
- block 간 shared-memory communication
- arbitrary CUDA source compatibility
- thread/block extent가 runtime에 따라 바뀌는 dynamic block geometry
- LMEM 사용량에 따라 resident block 수를 줄이는 `vx_spawn_threads_ex` 또는 runtime occupancy 조절
- `NUM_BARRIERS`를 `UP(NUM_WARPS/2)`와 다른 값으로 override한 hardware configuration

`tvm_storage_sync("global")`, dynamic shared memory, unsupported scope는 조용히 무시하지 않고 stage-specific error로 거부한다.

## 핵심 설계 결정

### 1. 3D launch packet ABI는 유지한다

현재 `vx_tvm_launch_header_t`는 이미 `grid[3]`와 `block[3]`를 저장한다. Host runtime의 `ThreadWorkLoad`도 세 축을 추출하고 block product를 계산한다.

따라서 2D/3D index 지원만으로 launch packet ABI를 변경하지 않는다. Generated dispatcher가 `vx_spawn_threads(1, ...)`로 고정 호출하는 부분을 기존 API의 `vx_spawn_threads(3, ...)` 호출로 바꾼다. 사용하지 않는 축은 1이므로 dimension을 3으로 전달해도 기존 1D kernel semantics는 유지된다.

Dynamic shared memory를 나중에 추가할 때만 launch packet에 `dynamic_shared_bytes` 같은 필드를 추가하고 ABI version을 올린다.

### 2. 기존 spawn의 resident block 수를 compile-time 계약으로 고정한다

초기 구현에서는 `vx_spawn_threads_ex`를 추가하지 않는다. 현재 `vx_spawn_threads`가 block thread 수와 warp 수로 정하는 resident group 수를 그대로 사용한다. TVM scheduler와 codegen은 이 resident 수의 모든 block이 동시에 실행되어도 안전한 static shared-memory 크기만 허용한다.

```text
warps_per_group = ceil(block_threads / threads_per_warp)
resident_groups = num_warps / warps_per_group
effective_max_shared_bytes_per_block = local_mem_size / resident_groups

required_lmem = resident_groups * aligned_shared_bytes_per_block
```

Codegen은 checked arithmetic으로 다음 조건을 검증한다.

```text
required_lmem <= target.local_mem_size
```

예를 들어 pinned U55C의 `NUM_THREADS=32`, `NUM_WARPS=4`, LMEM 1 MiB에서는 32-thread block은 4개가 resident하므로 block당 256 KiB, 64-thread block은 2개가 resident하므로 512 KiB, 128-thread block은 1개가 resident하므로 1 MiB까지 허용한다. 32-thread block이 400 KiB를 요구하면 두 block씩 실행할 가능성이 있어도 초기 구현에서는 compile error로 거부한다.

전체 grid block 수가 resident group 수보다 큰 경우의 batching은 기존 `vx_spawn_threads` 동작을 그대로 사용한다. 향후 더 큰 shared tile이 실제 성능에 필요하다는 측정 결과가 있을 때만 별도 후속 작업으로 resource-aware spawn을 검토한다.

### 3. default barrier 수는 기존 spawn의 모든 multi-warp resident block을 수용한다

Vortex default는 다음 관계를 갖는다.

```text
NUM_BARRIERS = UP(NUM_WARPS / 2)
```

`warps_per_group == 1`이면 hardware가 `vx_barrier(..., 1)`을 no-op으로 처리하므로 barrier slot을 소비하지 않는다. `warps_per_group >= 2`이면 동시에 resident할 수 있는 block 수는 항상 `floor(NUM_WARPS / 2)` 이하이므로 default `NUM_BARRIERS`가 모든 multi-warp resident block에 독립적인 ID를 제공한다.

```text
single-warp block:
  __syncthreads() -> hardware no-op

multi-warp block:
  resident_groups <= floor(NUM_WARPS / 2) == NUM_BARRIERS
```

Generated kernel과 기존 spawn은 다음 mapping을 사용한다.

```text
barrier ID    = __local_group_id
barrier count = __warps_per_group
```

따라서 초기 TVM backend는 barrier slot 수를 별도 target attribute나 runtime capability로 관리하지 않는다. Hardware manifest/build configuration에서 `NUM_BARRIERS`가 없거나 effective value가 정확히 default와 같을 때만 지원한다. 다른 override는 지원하지 않는다.

Barrier correctness의 남은 핵심 위험은 slot 부족이 아니라 일부 warp가 barrier에 도달하지 않는 divergent control flow이다.

### 4. shared-memory planning은 보수적으로 시작한다

초기 구현은 PrimFunc의 모든 static shared allocation을 수집하고 alignment를 적용해 하나의 arena에 순서대로 배치한다. Scope가 겹치지 않는 buffer 사이의 memory reuse는 하지 않는다.

```text
offset_0 = align_up(0, align_0)
offset_1 = align_up(offset_0 + size_0, align_1)
...
total_shared_bytes = align_up(last_end, arena_alignment)
```

정확성이 확보된 후 별도 최적화로 liveness 기반 offset reuse를 추가한다.

### 5. local buffer는 thread-private stack allocation으로 제한한다

TVM `scope="local"`은 ordinary C++ array로 출력한다. 초기 조건은 다음과 같다.

- shape product가 compile-time constant
- allocation byte 수가 overflow하지 않음
- alignment가 compiler에서 표현 가능
- zero/negative extent 거부
- configurable per-thread local allocation limit 적용

큰 local buffer는 register spill과 stack/global-memory traffic을 유발할 수 있으므로 warning 또는 compile-time limit를 둔다. Vortex LMEM capacity와 TVM local-buffer limit는 별도 속성으로 관리한다.

### 6. shared barrier는 uniform control flow만 허용한다

`tvm_storage_sync("shared")`는 다음 코드로 lowering한다.

```cpp
__syncthreads();
```

다만 barrier가 `threadIdx`에 의존하는 `if`, thread마다 iteration 횟수가 다른 loop, early return 아래에 있으면 일부 warp만 barrier에 도달해 deadlock할 수 있다.

Codegen 전 validator를 두어 block barrier가 thread-uniform control flow에 있는지 검사한다. 증명할 수 없는 경우 compile error로 거부한다. `tvm_storage_sync("warp")`는 Vortex warp lockstep semantics가 명확히 검증된 뒤 no-op 또는 별도 lowering을 선택하고, 그 전에는 명시적으로 거부한다.

### 7. kernel resource metadata의 source of truth는 하나만 둔다

Shared-memory planner가 계산한 결과를 동시에 다음 두 곳에 사용한다.

- codegen의 dimension-dependent compile-time resource validation
- host `VortexModule`의 kernel별 validation/serialization metadata

Host와 device가 각각 shared byte 수를 다시 계산하지 않는다. Metadata에는 최소한 다음 값이 필요하다.

```text
launch_rank
static_shared_bytes
compile_time_resident_groups
private_local_bytes_per_thread (diagnostic/limit용)
```

VortexModule serialization format은 version을 올리고, old module load compatibility 또는 명시적인 old-version rejection을 test로 고정한다.

## 접근 파일들

### TVM 변경 대상

- `src/backend/vortex/codegen/codegen_vortex.h`
  - axis tracking, resource metadata, shared arena planner interface
- `src/backend/vortex/codegen/codegen_vortex.cc`
  - x/y/z binding, block product 검증, local/shared allocation, storage sync 출력
- `src/backend/vortex/codegen/build_vortex.cc`
  - kernel resource metadata를 runtime module factory에 전달
- `src/backend/vortex/codegen/target_kind.cc`
  - shared-memory target attribute와 multidimensional limit canonicalization
- `src/backend/vortex/runtime/vortex_module.cc`
  - kernel별 resource metadata 저장/serialization/launch validation
- `src/backend/vortex/runtime/vortex_device_api.h`
- `src/backend/vortex/runtime/vortex_device_api.cc`
  - actual LMEM/thread capability query와 target/runtime 교차 검증
- `python/tvm/relax/backend/vortex/pipeline.py`
  - 1D fallback에서 검증된 2D/shared-memory schedule로 단계적 전환

### TVM 참고 파일

- `src/backend/cuda/codegen/codegen_cuda.cc`
  - `PrintStorageScope`, `PrintStorageSync`, `AllocBufferNode` lowering
- `src/backend/opencl/codegen/codegen_opencl.cc`
  - shared/local address space와 barrier 처리
- `src/runtime/thread_storage_scope.h`
  - launch tag에서 3D grid/block을 추출하는 `ThreadWorkLoad`
- GPU verifier와 DLight schedule rule
  - total threads, per-axis extent, shared-memory 사용량 검사 방식

### TVM 테스트

- `tests/python/codegen/test_target_codegen_vortex.py`
- `tests/python/target/test_target_vortex.py`
- `tests/python/runtime/test_runtime_vortex.py`
- `tests/python/integration/test_tirx_vortex.py`
- `tests/python/relax/test_relax_vm_vortex.py`
- `tests/python/relax/test_torch_export_vortex.py`
- 필요 시 신규 `tests/python/integration/test_tirx_vortex_shared.py`

### Vortex 변경 대상

초기 구현에는 Vortex product code 변경이 필요하지 않다. 기존 `vx_spawn_threads`, `__syncthreads()`, default `NUM_BARRIERS` 계약을 그대로 사용한다. Native regression 추가 중 기존 계약의 실제 결함이 확인될 때만 별도 Vortex 수정 범위를 연다.

### Vortex 참고 및 테스트

- `kernel/include/vx_intrinsics.h`
- `tests/regression/cta/`
- `tests/kernel/conform/`
- 신규 또는 확장된 native spawn/shared/barrier regression

## 구현 계획

### Phase 0: native hardware contract 고정

1. pinned U55C manifest와 `vx_dev_caps`에서 thread/warp/LMEM 값을 기록한다.
2. manifest/build `CONFIGS`에 non-default `NUM_BARRIERS` override가 없고 effective 값이 `UP(NUM_WARPS/2)`인지 기록한다.
3. 기존 `tests/regression/cta` 또는 작은 native kernel로 다음을 U55C에서 검증한다.
   - 2D/3D index flattening
   - 64/128-thread multi-warp group
   - block별 `__local_mem` isolation
   - 한 barrier와 연속 두 barrier
   - resident group보다 많은 block의 batched slot reuse
4. 실패 시 TVM 변경을 시작하지 않고 Vortex native contract를 먼저 수정한다.

완료 조건: TVM 없이 Vortex native API만으로 LMEM/barrier semantics가 physical U55C에서 증명된다.

### Phase 1: static residency resource contract 고정

1. 기존 `vx_spawn_threads`의 `warps_per_group` 및 `groups_per_core` 계산을 native regression으로 고정한다.
2. target resource profile에서 `threads_per_warp`, `num_warps`, `local_mem_size`를 명시한다. 별도 `num_barriers` target attribute는 추가하지 않는다.
3. block dimension으로 `compile_time_resident_groups`를 checked arithmetic으로 계산하는 공용 TVM helper를 만든다.
4. 다음 dimension-dependent 한도를 계산한다.
   - `effective_max_shared_bytes_per_block = local_mem_size / compile_time_resident_groups`
5. 32/64/128-thread block에 대해 pinned U55C 한도가 각각 256 KiB/512 KiB/1 MiB인지 unit test로 고정한다.
6. resident block 수를 줄여야만 실행 가능한 kernel은 `_ex`로 우회하지 않고 명확한 compile-time diagnostic으로 거부한다.

완료 조건: scheduler와 codegen이 기존 spawn의 동시 resident block 수를 정확히 재현하고, 모든 resident slot의 LMEM 합계가 target cap 안에 있음을 compile time에 증명한다.

### Phase 2: target와 runtime capability 확장

1. Vortex target의 `max_shared_memory_per_block=0` 강제를 제거한다.
2. pinned profile의 physical LMEM은 1 MiB로 설정하되, 실제 block당 한도는 block dimension으로 계산한다. `max_shared_memory_per_block=1 MiB`만 보고 32-thread block에 1 MiB를 허용하지 않는다.
3. thread dimension은 축별 최대 `[128, 128, 128]`, total product 최대 128이라는 계약으로 바꾼다.
4. `VortexDeviceAPI`가 실제 `VX_CAPS_LOCAL_MEM_SIZE`를 반환한다.
5. target resource가 actual device보다 큰 경우 launch 전에 거부하고, 조용히 clamp하지 않는다.

완료 조건: target JSON round-trip, invalid attribute, runtime device attribute test가 모두 통과한다.

### Phase 3: 2D/3D thread binding codegen

1. `BindThreadIndex`가 x/y/z의 block/thread tag를 허용한다.
2. 각 axis의 중복 binding과 알 수 없는 tag를 거부한다.
3. `threadIdx.{x,y,z}` extent는 positive compile-time constant로 제한한다.
4. per-axis limit와 `x*y*z <= max_threads_per_block`을 overflow-safe하게 검사한다.
5. `blockIdx` extent는 positive uint32 ABI 범위에서 dynamic value도 허용한다.
6. dispatcher가 기존 `vx_spawn_threads(3, grid, block, ...)`를 호출한다.
7. 기존 1D generated source와 hardware behavior의 regression을 유지한다.

완료 조건: 2D/3D index-only kernel이 direct `tvm.tirx.build`로 U55C에서 통과한다.

### Phase 4: thread-private local memory

1. `AllocBufferNode(scope="local")`의 constant shape와 alignment를 계산한다.
2. ordinary C++ array 또는 pointer-compatible stack allocation을 출력한다.
3. buffer dtype, volatile annotation, load/store index lowering을 기존 CodeGenC 방식과 맞춘다.
4. per-thread local byte limit와 overflow error를 추가한다.
5. 서로 다른 thread가 같은 local array를 alias하지 않는 hardware test를 작성한다.

완료 조건: local scratch를 사용하는 2D kernel이 source inspection과 hardware correctness를 모두 통과한다.

### Phase 5: static block-shared memory

1. PrimFunc 사전 pass로 모든 `scope="shared"` allocation을 수집한다.
2. constant byte size와 alignment를 계산하고 kernel별 arena offset을 배정한다.
3. generated C++에서 각 shared buffer를 `__local_mem(total_shared_bytes) + offset` pointer로 출력한다.
4. `compile_time_resident_groups * static_shared_bytes <= target.local_mem_size`를 compile time에 검증한다.
5. Host module metadata에 static shared byte 수와 compile-time resident group 수를 저장하고, actual LMEM과 launch time에 다시 비교한다. Runtime은 resident 수를 조절하지 않고 mismatch를 거부한다.
6. multi-kernel module에서 kernel마다 다른 resource metadata를 직렬화한다.

완료 조건: 두 개 이상의 shared buffer와 alignment가 있는 kernel이 source/serialization/U55C test를 통과한다.

### Phase 6: block barrier lowering

1. `CodeGenVortex::PrintStorageSync`를 구현한다.
2. `shared` sync를 `__syncthreads()`로 출력한다.
3. thread-dependent control flow 아래 barrier를 거부하는 uniformity validator를 추가한다.
4. `global`, `shared.dyn`, 미지원 sync scope를 명확히 거부한다.
5. single-warp block에서는 hardware no-op이지만 동일한 uniformity rule을 적용한다.
6. 같은 kernel 안의 연속 barrier와 loop 안의 uniform barrier를 검증한다. Source의 여러 barrier site는 block의 같은 `__local_group_id`를 순차 재사용한다.

완료 조건: 64/128-thread cross-warp producer/barrier/consumer kernel이 hang 없이 U55C에서 정확하다.

### Phase 7: direct TIRx acceptance kernels

다음 kernel을 handwritten TIRx로 만들되 external source나 `T.call_kernel`은 사용하지 않는다.

1. 2D grid/block index mapping kernel
2. 3D grid/block index mapping kernel
3. thread-private local scratch kernel
4. 8x8 또는 16x8 shared tile transpose
5. shared tile을 사용하는 naive/tiled matmul
6. 두 barrier로 shared buffer를 두 번 재사용하는 kernel
7. 기존 resident group 수보다 많은 block을 실행하는 batching, LMEM slot 재사용, multi-warp block barrier ID isolation test

각 kernel은 `tvm.tirx.build -> target.build.vortex -> native C++ -> vxbin -> VortexModule`의 정상 경로를 거치고 NumPy reference와 비교한다.

### Phase 8: Relax/DLight schedule 활성화

1. 현재 Vortex pipeline의 `dl.gpu.Fallback()`를 바로 제거하지 않는다.
2. Direct TIRx acceptance가 통과한 뒤 Matmul 등 검증된 operator에만 2D/shared-memory rule을 적용한다.
3. Schedule이 생성한 TIR에 대해 다음을 검사한다.
   - total threads <= 128
   - per-axis extent <= target limit
   - `resident_groups(block_dim) * static_shared_bytes <= target/actual LMEM`
   - unsupported intrinsic 없음
   - barrier uniformity 만족
4. Rule이 resource limit에 맞지 않으면 safe 1D fallback으로 돌아가거나 compile-time schedule error를 낸다.
5. 기존 `torch.export` MLP와 shared-memory matmul을 포함하는 더 큰 model을 Relax VM bytecode/compiled mode에서 실행한다.

완료 조건: handwritten TIR 없이 Relax의 정상 scheduling pipeline이 2D/shared/barrier TIR을 만들고 U55C에서 eager PyTorch와 일치한다.

### Phase 9: serialization, failure, performance hardening

1. Resource metadata가 export/load 후 보존되는지 검증한다.
2. corrupted resource metadata와 version mismatch를 거부한다.
3. target와 actual U55C LMEM mismatch를 launch 전에 거부한다.
4. oversized block product, oversized shared arena, divergent barrier를 driver open 전에 거부한다.
5. 1D fallback과 2D/shared schedule의 build time, artifact size, host latency, hardware cycles를 비교한다.
6. Shared-memory schedule이 정확하지만 느린 경우 correctness support와 default scheduling 선택을 분리한다.

## 검증 계획

### Host-only unit test matrix

| 영역 | Positive | Negative |
|---|---|---|
| thread binding | x/y/z source emission | unknown axis, duplicate axis |
| block extent | 8x8, 4x4x4 | zero, dynamic thread extent, product 129+ |
| local buffer | constant array, alignment | dynamic/zero/overflow allocation |
| shared buffer | multiple aligned buffers; 32/64/128 threads에서 256 KiB/512 KiB/1 MiB 경계 | dimension-dependent target limit 초과, unsupported dtype/scope |
| barrier | 32-thread no-op path, 64/128-thread uniform shared sync, 연속 barrier ID 재사용 | divergent/global/dynamic-shared sync |
| metadata | multi-kernel round-trip | truncated/version/resource corruption |
| runtime | actual LMEM query | target/actual mismatch |

Codegen golden test는 다음 문자열과 구조를 확인한다.

- `threadIdx.y`, `threadIdx.z`, `blockIdx.y`, `blockIdx.z`
- `vx_spawn_threads(3, ...)`
- `__local_mem(total_shared_bytes)`
- aligned shared buffer offsets
- `__syncthreads()`
- kernel별 `static_shared_bytes`, `compile_time_resident_groups`

### Vortex native regression

- 기존 `vx_spawn_threads` compatibility
- block dimension별 기존 warp-based resident group 계산
- 32/64/128-thread block의 static LMEM 경계와 초과 거부
- LMEM slot isolation
- default configuration의 concurrent multi-warp block barrier ID isolation
- single-warp `__syncthreads()` no-op
- partial final warp
- 32, 64, 96, 128 threads/block
- block count가 resident slot 수보다 큰 batching
- 연속 barrier 재사용

### Physical U55C acceptance

다음은 실제 hardware에서 모두 실행한다.

1. 2D mapping: grid `(3, 2)`, block `(8, 4)`
2. 3D mapping: grid `(2, 3, 2)`, block `(4, 2, 2)`
3. shared transpose: block `(8, 8)` 또는 `(16, 8)`
4. cross-warp barrier: 64 threads와 128 threads
5. shared tiled matmul: irregular M/N/K shape 포함
6. multi-kernel binary: shared 사용 kernel과 사용하지 않는 kernel 혼합
7. Relax VM export/reload 후 동일 실행
8. `torch.export` model의 eager PyTorch 비교

모든 결과는 exact xclbin path, XRT index/BDF, manifest `CONFIGS`, test command, timeout, PERF counter를 기록한다.

## 환경 setting

### TVM host build

기존 deterministic host LLVM 설정을 유지한다.

```sh
export TVM_LLVM_CONFIG=/opt/conda-pkgs/llvmdev-18.1.8-default_h99862b1_12/bin/llvm-config
export PATH=/opt/conda-pkgs/llvmdev-18.1.8-default_h99862b1_12/bin:/usr/bin:/bin
```

Vortex device compiler는 host `PATH`에 전역으로 추가하지 않고 compiler helper가 absolute path를 사용한다.

### Physical FPGA image

Acceptance test는 다음 xclbin만 사용한다.

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin
```

이 image의 manifest `CONFIGS`에는 최소 다음 resource가 일치해야 한다.

```text
NUM_THREADS=32
NUM_WARPS=4
LMEM_LOG_SIZE=20
NUM_BARRIERS=UP(NUM_WARPS/2)=2
```

이 profile에서는 32-thread block 네 개가 동시에 resident할 수 있다. 각 block은 single-warp이므로 `__syncthreads()`가 hardware no-op이고 barrier slot을 소비하지 않는다. Multi-warp block의 최대 resident 수는 항상 `floor(NUM_WARPS/2)` 이하이므로 default barrier 두 개로 충분하다.

Acceptance 전에 manifest/build `CONFIGS`를 확인한다. `NUM_BARRIERS` override가 없으면 위 default를 적용하고, 명시되어 있다면 effective 값이 `UP(NUM_WARPS/2)`와 같아야 한다. 다른 값의 xclbin은 초기 지원 범위 밖으로 명확히 거부한다.

### Hardware 실행

Vortex hardware 사용 예시는 기존과 동일하게 `ci/run_black.sh`를 기준으로 한다.

```sh
./ci/run_black.sh hw \
  --fpga-bin /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin \
  --app <native-resource-regression> \
  --args="<test-specific arguments>"
```

TVM pytest도 같은 U55C allocation, XRT detector, pinned xclbin, manifest `CONFIGS`, Vortex runtime `LD_LIBRARY_PATH`를 사용한다.

실제 hardware가 correctness source of truth이다. `simx`는 barrier hang, LMEM address, active warp mask를 debugging할 때만 사용하고, 최종 acceptance를 대체하지 않는다.

## 위험 요소와 대응

- **Non-default barrier configuration:** manifest/build `CONFIGS`에서 `NUM_BARRIERS=UP(NUM_WARPS/2)` 계약을 확인하고 다른 override의 xclbin은 지원하지 않는다.
- **Barrier ID 충돌:** default 관계에서는 single-warp barrier가 no-op이고 multi-warp resident group마다 `__local_group_id`가 독립 ID를 제공하는지 native/U55C regression으로 고정한다.
- **LMEM block alias:** `resident_groups * shared_bytes`를 검증하고 group slot별 stride를 사용한다.
- **Divergent barrier deadlock:** thread-uniformity validator로 compile time에 거부한다.
- **Partial warp barrier count 오류:** `__warps_per_group`에 partial warp를 포함하고 33/63/65/127-thread test를 추가한다.
- **Thread dimension overflow:** 축별 값과 product를 checked arithmetic으로 검증한다.
- **TVM local/shared 의미 혼동:** local은 private stack, shared만 Vortex LMEM에 배치한다.
- **Host/device resource metadata drift:** 한 planner 결과를 device source와 serialized host metadata가 함께 사용한다.
- **Target와 xclbin 불일치:** target limit와 `vx_dev_caps` actual limit를 모두 확인한다.
- **고정 residency가 shared tile을 과도하게 제한:** correctness를 우선하고, liveness reuse와 schedule tile tuning으로 block당 shared 사용량을 줄인다. 유효한 schedule이 반복적으로 거부되고 성능상 필요성이 측정될 때만 `_ex`를 후속 설계한다.
- **Generic CUDA schedule의 과도한 resource 사용:** Vortex-specific schedule rule에 128-thread/LMEM 제한을 넣는다.
- **기존 1D regression 손상:** spawn API를 바꾸지 않고 기존 test를 그대로 통과해야 한다.

## 완료 조건

다음을 모두 만족하면 확장이 완료된 것으로 본다.

- `CodeGenVortex`가 2D/3D block/thread binding을 생성한다.
- 축별 extent와 전체 block thread product를 target/actual hardware limit로 검증한다.
- TVM `local` buffer가 thread-private semantics로 동작한다.
- TVM `shared` buffer가 block별 Vortex LMEM arena에 배치된다.
- Shared-memory barrier가 multi-warp block에서 정확히 동작한다.
- 기존 spawn이 정하는 resident group 수를 기준으로 모든 동시 block의 LMEM resource가 compile time에 안전하다고 증명된다.
- Default `NUM_BARRIERS=UP(NUM_WARPS/2)`에서 single-warp no-op과 multi-warp block barrier가 정확히 동작한다.
- Kernel별 shared-memory metadata가 multi-kernel module과 export/load에서 보존된다.
- Oversized resource와 divergent barrier는 driver launch 전에 명확히 거부된다.
- 기존 1D vecadd, matmul, Relax VM, torch.export regression이 유지된다.
- 2D/3D mapping, shared transpose, tiled matmul이 pinned U55C에서 NumPy와 일치한다.
- Relax/DLight가 handwritten TIR 없이 shared-memory kernel을 생성한다.
- PyTorch-exported model이 Relax VM bytecode와 compiled mode에서 eager PyTorch와 일치한다.
- 최종 결과는 실제 U55C에서 통과하며 simx-only 결과로 대체되지 않는다.

## 권장 커밋 단위

1. 기존 Vortex spawn의 static residency/LMEM 및 default barrier contract native regression
2. TVM target/runtime multidimensional resource contract
3. Vortex 2D/3D codegen과 direct TIRx tests
4. Thread-private local allocation lowering
5. Static shared arena planning과 module metadata
6. Shared barrier lowering과 uniformity validation
7. U55C direct TIRx acceptance kernels
8. Relax/DLight shared-memory scheduling과 torch.export acceptance
9. Serialization/failure/performance hardening

각 커밋은 가능한 한 host-only test와 필요한 physical U55C test를 함께 포함한다. Vortex kernel-library 변경과 그 TVM consumer는 dependency 순서대로 분리하되, 최종 branch에서는 두 repository commit ID 조합을 STATUS에 기록한다.
