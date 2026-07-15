# Tensor Core Unit (TCU) Documentation

## 개요

Vortex GPU의 Tensor Core Unit (TCU)은 행렬 곱셈-누산 (Matrix Multiply-Accumulate, MMA) 연산을 가속화하는 전용 하드웨어 유닛입니다. NVIDIA의 Tensor Core와 유사한 WMMA (Warp Matrix Multiply-Accumulate) 연산을 지원합니다.

## 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              TCU System                                  │
│                                                                         │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────┐ │
│  │   vx_tensor.h   │    │  VX_uop_sequencer│   │     VX_tcu_unit     │ │
│  │  (SW API)       │───▶│  (Micro-op Gen)  │──▶│   (HW Execution)    │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────────┘ │
│                                                          │              │
│                              ┌───────────────────────────┘              │
│                              ▼                                          │
│                    ┌───────────────────┐                                │
│                    │    VX_pe_switch   │                                │
│                    │ (FP/INT Routing)  │                                │
│                    └────────┬──────────┘                                │
│                    ┌────────┴──────────┐                                │
│                    ▼                   ▼                                │
│              ┌──────────┐       ┌──────────┐                            │
│              │ VX_tcu_fp│       │VX_tcu_int│                            │
│              │(FP16/BF16)│       │(INT8/INT4)│                           │
│              └──────────┘       └──────────┘                            │
└─────────────────────────────────────────────────────────────────────────┘
```

## 문서 구조

| 문서 | 설명 |
|------|------|
| [VX_tcu_pkg.md](VX_tcu_pkg.md) | TCU 패키지 정의 및 상수 |
| [VX_uop_sequencer.md](VX_uop_sequencer.md) | Micro-op 시퀀서 |
| [VX_tcu_unit.md](VX_tcu_unit.md) | TCU 메인 유닛 |
| [VX_tcu_fp.md](VX_tcu_fp.md) | 부동소수점 TCU |
| [VX_tcu_int.md](VX_tcu_int.md) | 정수 TCU |
| [vx_tensor.md](vx_tensor.md) | 소프트웨어 API |

## 지원 데이터 타입

| 타입 | ID | 비트 | 설명 |
|------|-----|------|------|
| FP32 | 0 | 32 | IEEE 754 단정밀도 |
| FP16 | 1 | 16 | IEEE 754 반정밀도 |
| BF16 | 2 | 16 | Brain Floating Point |
| I32 | 8 | 32 | 부호있는 32비트 정수 |
| I8 | 9 | 8 | 부호있는 8비트 정수 |
| U8 | 10 | 8 | 부호없는 8비트 정수 |
| I4 | 11 | 4 | 부호있는 4비트 정수 |
| U4 | 12 | 4 | 부호없는 4비트 정수 |

### Floating-point input format configuration

The floating-point TCU supports both FP16 and BF16 inputs by default. A build
can remove one input-format datapath with the following compile-time macros:

| Build defines | Supported FP input formats |
|---------------|----------------------------|
| Neither macro defined | FP16 and BF16 |
| `DISALBE_BF16` | FP16 only |
| `DISALBE_FP16` | BF16 only |

The `DISALBE_*` spelling is intentional and is part of the configuration API.
Defining both macros is invalid. These macros do not change FP32 accumulation,
FP32 output, or integer TCU formats.

## WMMA 연산

### 기본 연산

```
D = A × B + C

여기서:
- A: M×K 입력 행렬
- B: K×N 입력 행렬
- C: M×N 누산기 행렬 (입력)
- D: M×N 결과 행렬 (출력)
```

### 타일 크기

NUM_THREADS=32, NR=8일 때:
- **Tile Capacity**: 32 × 8 = 256
- **tileM**: 16
- **tileN**: 16
- **tileK**: 16 (입력 타입에 따라 조정됨)

## 사용 예시

```cpp
#include <vx_tensor.h>

using ctx = vortex::tensor::wmma_context<32, vt::fp16, vt::fp32>;

ctx::fragment_a   fragA;
ctx::fragment_b   fragB;
ctx::fragment_acc fragC;

// 타일 초기화
ctx::fill_fragment(fragC, 0);

// 행렬 로드
ctx::load_matrix_sync(fragA, pA, K);
ctx::load_matrix_sync(fragB, pB, N);

// 행렬 곱셈-누산
ctx::mma_sync(fragC, fragA, fragB, fragC);

// 결과 저장
ctx::store_matrix_sync(pC, fragC, N);
```

## 명령어 인코딩

WMMA 명령어는 RISC-V Custom0 opcode를 사용합니다:

```
.insn r RISCV_CUSTOM0, 0, 2, x[fmd], x[fms], x0

fmd: 출력 형식 ID (fmt_d)
fms: 입력 형식 ID (fmt_s)
```

## 관련 파일

### RTL 파일
- `hw/rtl/tcu/VX_tcu_pkg.sv` - TCU 패키지
- `hw/rtl/tcu/VX_tcu_unit.sv` - TCU 메인 유닛
- `hw/rtl/tcu/VX_tcu_fp.sv` - FP TCU
- `hw/rtl/tcu/VX_tcu_int.sv` - INT TCU
- `hw/rtl/core/VX_uop_sequencer.sv` - Micro-op 시퀀서

### 소프트웨어 파일
- `kernel/include/vx_tensor.h` - WMMA API
- `sim/common/tensor_cfg.h` - 설정 및 타입 정의

### 테스트
- `tests/regression/sgemm_tcu/` - TCU GEMM 테스트
