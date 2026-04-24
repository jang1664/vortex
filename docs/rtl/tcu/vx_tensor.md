# `kernel/include/vx_tensor.h` — WMMA Software API

## 개요

Vortex GPU의 WMMA (Warp Matrix Multiply-Accumulate) 소프트웨어 API.
NVIDIA CUDA의 mma.sync와 유사한 인터페이스를 제공.

## 네임스페이스 구조

```cpp
namespace vortex {
namespace tensor {
    // 데이터 타입 정의
    struct fp32 { ... };
    struct fp16 { ... };
    ...

    // WMMA Context
    template <uint32_t NT, typename It, typename Ot>
    struct wmma_context { ... };
}
}
```

## 데이터 타입

### 부동소수점

```cpp
struct fp32 {
    using dtype = float;
    static constexpr uint32_t id = 0;    // HW에서 사용하는 ID
    static constexpr uint32_t bits = 32;
    static constexpr const char* name = "fp32";
};

struct fp16 {
    using dtype = uint16_t;
    static constexpr uint32_t id = 1;
    static constexpr uint32_t bits = 16;
};

struct bf16 {
    using dtype = uint16_t;
    static constexpr uint32_t id = 2;
    static constexpr uint32_t bits = 16;
};
```

### 정수

```cpp
struct int8 {
    using dtype = int8_t;
    static constexpr uint32_t id = 9;
    static constexpr uint32_t bits = 8;
};

struct int4 {
    using dtype = uint8_t;  // 실제 4비트, 패킹됨
    static constexpr uint32_t id = 11;
    static constexpr uint32_t bits = 4;
};
```

## wmma_context 템플릿

```cpp
template <uint32_t NT,   // Warp 내 스레드 수 (예: 32)
          typename It,   // 입력 타입 (A, B)
          typename Ot>   // 출력 타입 (C, D)
struct wmma_context {
    // 타입 별칭
    using input_t  = typename It::dtype;
    using output_t = typename Ot::dtype;

    // 타일 크기 (wmma_config_t에서 계산)
    static constexpr uint32_t tileM = cfg::tileM;  // 16
    static constexpr uint32_t tileN = cfg::tileN;  // 16
    static constexpr uint32_t tileK = cfg::tileK;  // 16 (i_ratio 적용)

    // Fragment 타입
    using fragment_a   = fragment_t<matrix_a, input_t, NRA>;
    using fragment_b   = fragment_t<matrix_b, input_t, NRB>;
    using fragment_acc = fragment_t<accumulator, output_t, NRC>;
};
```

## Fragment 구조

Fragment는 **WMMA 타일의 per-thread shard**다. Warp 전체(NT 스레드)가 협력해서 하나의 행렬 타일을 처리하는데, 타일을 공유 저장소에 두지 않고 각 스레드의 스칼라 레지스터에 분산 보관한다. 한 스레드가 들고 있는 자기 몫이 곧 fragment이다 (CUDA `nvcuda::wmma::fragment`와 같은 개념).

```cpp
template <frag_use_t U, typename T, uint32_t N>
struct fragment_t {
    using Type = T;
    static constexpr frag_use_t Use = U;
    static constexpr uint32_t NR = N;      // 이 fragment가 점유하는 32-bit 레지스터 수
    std::array<vreg_t, N> data;            // vreg_t = float (32비트 GPR)
};
```

- `data[]`는 실제 RISC-V FP 레지스터에 할당된다 (`vreg_t = float`).
- Lane(스레드)마다 독립적으로 존재 → warp 관점에서는 `NT × NR`개의 레지스터가 타일 하나를 구성한다.
- 입력이 서브워드(fp16/int8/int4)인 경우 32-bit 레지스터 하나에 여러 원소가 **packing**된다 (`i_ratio = sizeof(vreg_t) / sizeof(input_t)`). 즉 "NR개의 레지스터"는 "NR × i_ratio개의 원소"를 담을 수 있다.

### NR 계산 (`sim/common/tensor_cfg.h`)

`NR`은 "타일 전체 원소 수 / warp 내 스레드 수"로 정해진다 — 타일을 스레드들이 균등하게 나눠 갖는다는 정의 그 자체다.

```cpp
static constexpr uint32_t NRA = (xtileM * xtileK) / NT;  // A 레지스터 수
static constexpr uint32_t NRB = (xtileN * xtileK) / NT;  // B 레지스터 수
static constexpr uint32_t NRC = (xtileM * xtileN) / NT;  // C/D 레지스터 수
```

Fragment별로 NR이 다를 수 있는 이유는 A/B/C 타일의 모양(`xtileM·xtileK`, `xtileN·xtileK`, `xtileM·xtileN`)이 서로 다르기 때문이다. 보통은 같은 값(예: 8)이 되도록 `wmma_config_t`가 잡혀 있다.

### `TCU_NR` (HW) vs. `NRA/NRB/NRC` (SW)

HW(`hw/rtl/tcu/VX_tcu_pkg.sv`)에는 `TCU_NR`이라는 **단일 상수** 하나만 있고, fragment별 NR은 명시적으로 남기지 않았다. 오해하기 쉬운 부분이라 정확한 정의부터 정리한다.

```systemverilog
// hw/rtl/tcu/VX_tcu_pkg.sv
localparam TCU_NR       = 8;                 // fragment 하나당 스레드가 쓰는 최대 레지스터 수
localparam TCU_TILE_CAP = TCU_NT * TCU_NR;   // fragment 하나당 warp 전체 원소 용량
// ...
//localparam TCU_NRA = (TCU_TILE_M * TCU_TILE_K) / TCU_NT;   ← 주석 처리
localparam TCU_NRB = (TCU_TILE_N * TCU_TILE_K) / TCU_NT;
//localparam TCU_NRC = (TCU_TILE_M * TCU_TILE_N) / TCU_NT;   ← 주석 처리
```

#### 정의

**`TCU_NR` = fragment 하나가 스레드당 점유할 수 있는 *최대* 레지스터 수** (코드 주석 그대로 "registers per fragment"). 세 fragment(A/B/C)는 **각자 독립적으로** 이 상한을 가진다. NR을 셋이서 나눠 갖는 게 아니다.

```
NRA ≤ TCU_NR
NRB ≤ TCU_NR
NRC ≤ TCU_NR
스레드 전체 레지스터 점유량 = NRA + NRB + NRC  (최대 3·NR)
```

세 static_assert (`xtileM·xtileK ≤ TILE_CAP` 등)가 A/B/C에 **각각 따로** 걸려 있기 때문이다 — 공통 budget이 아니라 fragment별 독립 상한.

#### Fragment가 NR보다 적게 쓸 수 있다 (상한이라는 의미)

정사각 타일이면 세 fragment가 모두 NR을 꽉 채운다. 직사각이면 타일 모양이 작은 fragment는 NR보다 적게 사용한다.

| NT | NR | xtileM | xtileN | xtileK | NRA | NRB | NRC | 비고 |
|----|----|--------|--------|--------|-----|-----|-----|------|
| 32 | 8  | 16     | 16     | 16     | 8   | 8   | 8   | 정사각 — 셋 다 NR 꽉 채움 |
| 32 | 4  | 16     | 8      | 8      | 4   | **2** | 4   | 직사각 — B 타일이 작아서 NRB=2 (NR 미달) |

NR=4인 경우에 NRB=2가 되는 건 B에 레지스터를 "양보"해서가 아니라, **B 타일의 모양(xtileN · xtileK = 64)** 자체가 TILE_CAP(128)의 절반이라 저절로 레지스터가 남는 것이다.

#### mma_sync의 실제 레지스터 할당

커널 asm(`kernel/include/vx_tensor.h:316-344`)에서 NR=8, NRA=NRB=NRC=8인 경우 스레드는 세 fragment를 **동시에** 라이브로 물고 있다:

```
fragA : f0  ~ f7    (NRA=8)
fragB : f10 ~ f17   (NRB=8)
fragC : f24 ~ f31   (NRC=8)
합계  : 24개 FP 레지스터 (총 32개 F-regfile 중 대부분)
```

셋이 별개 레지스터 범위를 점유하므로, "NR을 나눠 쓴다"면 불가능한 양이다. NRB가 4로 줄면 fragB가 `f28~f31`로 옮겨가고 fragC가 `f10~f17`로 배치되는 방식으로 재배치된다.

### HW가 실제로 NRA/NRB/NRC를 소비하는 방식

RTL은 세 값 중 **`TCU_NRB`만** 명시적으로 계산하고 나머지는 다른 파라미터로 흡수한다:

| SW 개념 | HW 처리 위치 | 비고 |
|---------|-------------|------|
| `NRA`   | `TCU_M_STEPS × TCU_K_STEPS` + `TCU_RA = 0` | uop loop의 step 인덱스로 표현, 레지스터는 `f0`부터 고정 |
| `NRB`   | `TCU_NRB` 상수로 명시 → `TCU_RB`, `TCU_RC` base 결정 | fragB가 `f10~f17`(8개)인지 `f28~f31`(4개)인지가 fragC 배치까지 바꾸기 때문 |
| `NRC`   | `TCU_M_STEPS × TCU_N_STEPS` + `TCU_RC` base | uop step으로 표현 |

즉 `TCU_NRA` / `TCU_NRC`를 주석 처리한 건 **필요 없어서**가 아니라, uop sequencer가 step 인덱스로 이미 같은 정보를 들고 있기 때문이다(`VX_tcu_uops.sv:65-67`의 offset 식 참고). `TCU_NRB`만 남겨둔 이유는 레지스터 파일 파티셔닝(`TCU_RB`, `TCU_RC` base address 선택)에 FragB 크기가 필요하기 때문이며, 이는 커널 쪽 asm의 `if constexpr (FragB::NR == 8)` vs `== 4` 분기(`kernel/include/vx_tensor.h`)와 1:1로 대응된다.

### 요약

- **`TCU_NR` = fragment 하나당 스레드가 쓰는 *최대* 레지스터 수** (상한)
- 세 fragment(A/B/C)는 **각자 독립**으로 NR을 상한으로 가짐 — 공유 예산이 아님
- `NRA, NRB, NRC ≤ NR`, 합은 최대 `3·NR`까지 레지스터 파일에서 동시 점유
- 정사각 타일이면 셋 다 NR 꽉 채움, 직사각이면 작은 fragment는 NR 미달 가능 (예: NRB=2)
- HW는 NRA/NRC를 별도 상수로 두지 않고 `M/N/K_STEPS` + `RA/RB/RC` base address로 암묵 표현
- 유일하게 명시된 `TCU_NRB`는 레지스터 파일 파티셔닝 분기에만 사용

### 메모리 레이아웃

```
fragment_a   (Matrix A, xtileM × xtileK):  각 스레드가 NRA개의 레지스터에 자기 몫을 보관
fragment_b   (Matrix B, xtileK × xtileN):  각 스레드가 NRB개의 레지스터에 자기 몫을 보관
fragment_acc (Accumulator C/D, xtileM × xtileN): 각 스레드가 NRC개의 레지스터에 자기 몫을 보관
```

`load_matrix_sync` / `store_matrix_sync`는 `unroll_for<Frag::NR>([&](auto r) { ... })`로 레지스터 인덱스 `r = 0..NR-1`을 순회하면서, 그 `r`에 대응하는 타일 좌표를 계산해 메모리 ↔ 레지스터 매핑을 수행한다 (`kernel/include/vx_tensor.h`의 `load_matrix_sync` 참고).

## API 함수

### fill_fragment

Fragment를 특정 값으로 초기화:

```cpp
template <typename Frag, typename T>
static void fill_fragment(Frag &dst, T value);

// 사용 예
ctx::fill_fragment(fragC, 0);      // 누산기를 0으로 초기화
ctx::fill_fragment(fragC, 1.0f);   // 1.0으로 초기화
```

### load_matrix_sync

메모리에서 Fragment로 행렬 로드:

```cpp
template <mem_layout src_layout = row_major, typename Frag>
static void load_matrix_sync(Frag &dst, const void *src, size_t ldm);

// 사용 예
ctx::load_matrix_sync(fragA, pA, K);              // A: row-major (기본, 자연 layout)
ctx::load_matrix_sync<col_major>(fragB, pB, K);   // B: col-major (자연 layout)
```

#### Layout 규약 — "자연(natural) layout"과 API 계약의 차이

`load_matrix_sync`는 fragment 종류와 layout을 **독립적으로** 받는다. 템플릿 기본값은 A/B/C 모두 `row_major`이며, `Frag::Use`에 따라 자동으로 layout이 바뀌지 않는다. 즉 **API 계약 자체는 "A는 row, B는 col"을 강제하지 않는다.**

하지만 구현상 각 fragment에는 **성능에 유리한 "자연 layout"** 이 존재한다:

| Fragment | 자연 layout | 이유 |
|----------|-------------|------|
| A (matrix_a)   | **row-major** | lane이 K 방향으로 흩어져 있어, row-major일 때 K-연속 원소가 메모리 연속 → 32-bit `vreg_t` 하나를 **단일 aligned load**로 채울 수 있음 |
| B (matrix_b)   | **col-major** | 마찬가지로 lane이 K 방향 → col-major일 때 동일 최적화 성립 |
| C (accumulator)| row-major     | `tcM × tcN` lane 배치가 row-major일 때 자연스러움 |

자연 layout 경로에서는 `*reinterpret_cast<const vreg_t*>(ptr)` 한 번으로 `i_ratio`개 원소를 packing해 읽는다(`vx_tensor.h:212, 236, 245`). **반대 layout**도 지원되지만, 이때는 `input_acessor_t::pack_row(ptr, ldm)`로 원소를 하나씩 `ldm` stride로 수집해 packing해야 하므로 메모리 접근이 NR × i_ratio배로 늘어난다(`vx_tensor.h:206, 238`).

#### Sub-byte 타입은 자연 layout이 **강제**된다

`input_t`가 32-bit 미만(int4 등)일 때는 `ldm` stride로 개별 원소에 접근할 수 없기 때문에(비트 단위 주소 불가) static_assert로 반대 layout이 차단된다:

```cpp
// vx_tensor.h:200
static_assert(input_is_subbyte == false,
              "col_major layout is not supported for sub-byte matrix_a");
// vx_tensor.h:233
static_assert(input_is_subbyte == false,
              "row_major layout is not supported for sub-byte matrix_b");
```

즉 sub-byte(1바이트 미만, `bits < 8` — 현재는 int4 / uint4)에서는:
- A는 **반드시 row-major**
- B는 **반드시 col-major**

#### 실제 예시 해설 — `tests/regression/sgemm_tcu/kernel.cpp`

```cpp
// A: 항상 row-major (자연 layout, 템플릿 기본값)
ctx::load_matrix_sync(fragA, pTileA, K);

if constexpr (vt::ITYPE::bits < 8) {
  // int4 등: col-major 강제 (자연 layout, static_assert 때문에 선택지 없음)
  auto pTileB = pB + tile_col * K + i;
  ctx::load_matrix_sync<vt::col_major>(fragB, pTileB, K);
} else {
  // fp16/fp32: row-major로 로드 (비자연 layout, pack_row 경로)
  auto pTileB = pB + i * N + tile_col;
  ctx::load_matrix_sync(fragB, pTileB, N);
}
```

≥8-bit 타입에서 B를 row-major로 로드하는 건 호스트 쪽 메모리 배치 편의상 선택된 것으로, 성능 최적이 아니라 `pack_row` 경로를 탄다. 성능이 중요한 경우에는 호스트에서 B를 col-major로 준비하고 `<vt::col_major>`로 로드하는 쪽이 유리하다.

### store_matrix_sync

Fragment에서 메모리로 결과 저장:

```cpp
template <mem_layout dst_layout = row_major, typename Frag>
static void store_matrix_sync(void *dst, const Frag &src, size_t ldm);

// 사용 예
ctx::store_matrix_sync(pC, fragC, N);
```

### mma_sync

행렬 곱셈-누산 실행:

```cpp
template <typename FragD, typename FragA, typename FragB, typename FragC>
static void mma_sync(FragD &fragD, const FragA &fragA,
                     const FragB &fragB, const FragC &fragC);

// 사용 예: D = A × B + C
ctx::mma_sync(fragC, fragA, fragB, fragC);  // in-place
```

## mma_sync 내부 구현

### 레지스터 할당

```cpp
// fragA: f0-f7 (caller-saved)
register float fa0 __asm__("f0")  = fragA.data[0];
register float fa1 __asm__("f1")  = fragA.data[1];
// ...
register float fa7 __asm__("f7")  = fragA.data[7];

// fragB: f10-f17 또는 f28-f31 (NRB에 따라)
register float fb0 __asm__("f10") = fragB.data[0];
// ...

// fragC: f24-f31 또는 f10-f17
register float fc0 __asm__("f24") = fragC.data[0];
// ...
```

### 명령어 인코딩

```cpp
__asm__ volatile (".insn r %[insn], 0, 2, x%[fmd], x%[fms], x0"
    : "=f"(fd0), "=f"(fd1), ...  // 출력
    : [insn]"i"(RISCV_CUSTOM0),  // opcode
      [fmd]"i"(Ot::id),          // 출력 형식 ID
      [fms]"i"(It::id),          // 입력 형식 ID
      "f"(fa0), "f"(fa1), ...    // 입력 레지스터
);
```

## HW 실행 흐름 — 1 WMMA → N micro-op → 병렬 datapath

`mma_sync`는 ISA 레벨에서 **단일 custom-0 명령어**로 인코딩되지만, 하드웨어 내부에서는 두 단계로 확장되어 처리된다.

```
┌──────────────────────────────────────────────────────────────────────┐
│  SW (kernel)                                                          │
│    ctx::mma_sync(fragD, fragA, fragB, fragC)                          │
│      └─► .insn r CUSTOM0 (1개 RISC-V 명령어, warp 타일 전체 MMA)      │
└──────────────────────────────────────────────────────────────────────┘
                              ▼ Decode (EX_TCU + INST_TCU_WMMA)
┌──────────────────────────────────────────────────────────────────────┐
│  VX_uop_sequencer.sv / VX_tcu_uops.sv  — 시간적(temporal) 루프        │
│                                                                       │
│    TCU_UOPS = M_STEPS × N_STEPS × K_STEPS  micro-op 생성              │
│                                                                       │
│    counter[LG_N+LG_M +: LG_K] = k_index   (outer)                    │
│    counter[LG_N      +: LG_M] = m_index                               │
│    counter[0         +: LG_N] = n_index   (inner)                     │
│                                                                       │
│    각 uop마다 (rs1, rs2, rs3) 레지스터 오프셋 재계산하여 fragment    │
│    레지스터 파일(f0~f31)에서 해당 step의 sub-tile을 선택             │
└──────────────────────────────────────────────────────────────────────┘
                              ▼ 한 uop = 한 sub-tile MMA
┌──────────────────────────────────────────────────────────────────────┐
│  VX_tcu_int.sv / VX_tcu_fp.sv  — 공간적(spatial) 병렬 datapath        │
│                                                                       │
│    TC_M × TC_N 개의 dot-product 유닛 (각 유닛당 TC_K-way MAC)         │
│    → 한 cycle에 TC_M × TC_N × TC_K MAC을 병렬 수행                   │
└──────────────────────────────────────────────────────────────────────┘
```

### 파라미터 관계 (`hw/rtl/tcu/VX_tcu_pkg.sv`, `sim/common/tensor_cfg.h`)

| 파라미터 | 정의 | 의미 |
|---------|------|------|
| `xtileM`, `xtileN`, `xtileK` | Warp 타일 크기 (SW fragment가 표현하는 범위) | `NT × NR`로부터 유도 |
| `TC_M`, `TC_N`, `TC_K` | TCU datapath 1-cycle 처리 크기 | 공간적 병렬 폭 |
| `M_STEPS = xtileM / TC_M` | M 방향 uop 개수 | 시간적 루프 |
| `N_STEPS = xtileN / TC_N` | N 방향 uop 개수 | 시간적 루프 |
| `K_STEPS = xtileK / TC_K` | K 방향 uop 개수 | 시간적 루프 |
| `TCU_UOPS = M_STEPS × N_STEPS × K_STEPS` | 1 WMMA당 총 uop 수 | 전체 타일 / 데이터패스 폭 |

즉 **"1개 WMMA 명령어 = TCU datapath를 TCU_UOPS번 돌리는 일"** 이 성립한다. Kernel이 warp 타일 전체(`xtileM × xtileN × xtileK`)를 한 줄로 요청하면, uop sequencer가 이를 datapath 폭(`TC_M × TC_N × TC_K`)으로 쪼개서 순차 발급한다.

### Micro-op당 레지스터 매핑 (`VX_tcu_uops.sv:65-72`)

```
rs1_offset = (m_index >> LG_A_SB) << LG_K  |  k_index   // fragA 선택
rs2_offset = (k_index << LG_N | n_index) >> LG_B_SB     // fragB 선택
rs3_offset = m_index << LG_N | n_index                  // fragC/D 선택
```

`LG_A_SB` / `LG_B_SB`는 한 레지스터가 여러 sub-tile을 packing하는 경우를 반영한다(`a_sub_blocks`, `b_sub_blocks`). 즉 NR개의 레지스터가 반드시 `M_STEPS × K_STEPS`개 sub-tile과 1:1 대응되는 것은 아니며, 한 레지스터가 여러 step에서 재사용될 수 있다 — 그래서 offset 식에 shift가 들어간다.

### simx 모델 대응 (`sim/simx/decode.cpp:1080-1115`)

simx는 이 micro-op 전개를 decoder에서 선행 수행하여, 각 uop을 독립 `Instr`로 ibuffer에 푸시한다. RTL uop sequencer와 동일한 `(k, m, n)` 루프 구조를 가진다 — 같은 (rs1, rs2, rs3) 매핑식을 사용.

### 요약

- **SW** (`mma_sync`): warp 타일 전체를 1개 ISA 명령으로 표현
- **HW 프런트엔드** (`VX_uop_sequencer` + `VX_tcu_uops`): 타일을 datapath 폭에 맞게 `M_STEPS × N_STEPS × K_STEPS`번 시간적으로 전개
- **HW 백엔드** (`VX_tcu_int` / `VX_tcu_fp`): uop 1개를 `TC_M × TC_N × TC_K` 병렬 MAC으로 공간적으로 소화

## 사용 예시

### GEMM 커널

```cpp
#include <vx_tensor.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<32, vt::fp16, vt::fp32>;

void gemm_kernel(float *A, float *B, float *C, int M, int N, int K) {
    ctx::fragment_a   fragA;
    ctx::fragment_b   fragB;
    ctx::fragment_acc fragC;

    // 타일 인덱스 계산
    uint32_t tile_row = blockIdx.y * ctx::tileM;
    uint32_t tile_col = blockIdx.x * ctx::tileN;

    // 누산기 초기화
    ctx::fill_fragment(fragC, 0.0f);

    // K 차원 루프
    for (int k = 0; k < K; k += ctx::tileK) {
        // A, B 타일 로드
        ctx::load_matrix_sync(fragA, A + tile_row * K + k, K);
        ctx::load_matrix_sync(fragB, B + k * N + tile_col, N);

        // 행렬 곱셈-누산
        ctx::mma_sync(fragC, fragA, fragB, fragC);
    }

    // 결과 저장
    ctx::store_matrix_sync(C + tile_row * N + tile_col, fragC, N);
}
```

## 메모리 레이아웃 상세

### Matrix A 로딩 (row-major)

```
Thread lane = vx_thread_id();

block_idx    = lane / a_block_size;     // 어떤 sub-block
lane_in_blk  = lane % a_block_size;     // sub-block 내 위치
block_row    = (lane_in_blk / tcK) + (block_idx * tcM);
block_col    = (lane_in_blk % tcK) * i_ratio;

// 레지스터 r에 대해
for (r = 0; r < NRA; r++) {
    block_m = r / k_steps;
    block_k = r % k_steps;
    ptr = base + (block_m * m_stride) * ldm + (block_k * k_stride);
    data[r] = *ptr;
}
```

### Matrix B 로딩 (col-major)

```
block_idx    = lane / b_block_size;
lane_in_blk  = lane % b_block_size;
block_col    = (lane_in_blk / tcK) + (block_idx * tcN);
block_row    = (lane_in_blk % tcK) * i_ratio;

// B는 K×N 형태, col-major로 저장됨
for (r = 0; r < NRB; r++) {
    block_k = r / b_sub_steps;
    block_n = r % b_sub_steps;
    ptr = base + (block_k * k_stride) + (block_n * n_stride) * ldm;
    data[r] = *ptr;
}
```

## Sub-byte 타입 지원

### INT4 패킹

```cpp
template <typename D>
struct data_accessor_t<int4, D> {
    static inline D bit_fill(uint8_t src) {
        // 4비트 값을 32비트로 확장
        uint8_t src_u8 = (src << 4) | src;  // 2개 nibble 패킹
        // 4바이트로 확장
        uint32_t result = src_u8 | (src_u8 << 8) |
                         (src_u8 << 16) | (src_u8 << 24);
        return *reinterpret_cast<D*>(&result);
    }
};
```

## 관련 파일

- [tensor_cfg.h](../../../../sim/common/tensor_cfg.h) - 설정 정의
- [VX_tcu_unit.md](VX_tcu_unit.md) - 하드웨어 구현
- [VX_uop_sequencer.md](VX_uop_sequencer.md) - Micro-op 시퀀싱
