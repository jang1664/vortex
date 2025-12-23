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

```cpp
template <frag_use_t U, typename T, uint32_t N>
struct fragment_t {
    using Type = T;
    static constexpr frag_use_t Use = U;
    static constexpr uint32_t NR = N;      // 레지스터 수 (8)
    std::array<vreg_t, N> data;            // vreg_t = float (32비트)
};
```

### 메모리 레이아웃

```
fragment_a (Matrix A, M×K):
  data[0..7]: 각 스레드가 담당하는 A 요소들
              32비트 레지스터에 여러 입력 요소 패킹

fragment_b (Matrix B, K×N):
  data[0..7]: 각 스레드가 담당하는 B 요소들

fragment_acc (Accumulator C/D, M×N):
  data[0..7]: 각 스레드가 담당하는 C/D 요소들
```

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
ctx::load_matrix_sync(fragA, pA, K);              // A: row-major
ctx::load_matrix_sync<col_major>(fragB, pB, K);   // B: col-major
```

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
