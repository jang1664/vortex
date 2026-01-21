# FPINT GEMM Emulation (Python)

SystemVerilog 검증 코드를 Python으로 포팅한 FPINT GEMM 에뮬레이션 모듈입니다.

## 기능

- **FP16 처리**: sfpy (SoftFloat)를 사용한 bit-exact IEEE 754 FP16 연산
- **Fixed-point 연산**: fxpmath를 사용한 고정소수점 연산
- **Prealign**: FP16 → Fixed-point 정렬 (denormal 지원)
- **GEMM 구현**:
  - Reference GEMM (bit-exact FP16 × FP16 via SoftFloat → FP32 accumulation)
  - QCOL (column-wise quantization) with 2's complement
  - QROW (row-wise quantization) with 2's complement

## 설치

```bash
pip install -r requirements.txt
```

## 사용법

### 기본 사용

```python
import numpy as np
from fpint_emul import (
    fpint_gemm_qcol_2scomp,
    generate_random_fp16,
    generate_random_weights,
    fp16_bit_to_float
)

# 테스트 데이터 생성
M, K, N = 2, 16, 16
KG = K // 16  # QBLOCK = 16

input_data = generate_random_fp16((M, K), value_range=(-2.0, 2.0))
weight_data = generate_random_weights((K, N), w_width=4)
scale_data = generate_random_fp16((KG, N), value_range=(0.1, 1.0))
zero_data = np.random.randint(-4, 4, size=(KG, N), dtype=np.int16)

# GEMM 실행
output = fpint_gemm_qcol_2scomp(
    input_data, weight_data, scale_data, zero_data,
    M, N, K, debug=False
)

# 결과 확인
for m in range(M):
    for n in range(N):
        print(f"output[{m},{n}] = {fp16_bit_to_float(output[m, n]):.4f}")
```

### Prealign 사용

```python
from fpint_emul import prealign, EXTRA_BIT

M, K = 2, 16
input_data = generate_random_fp16((M, K))

# Prealign 수행
aligned_fx, aligned_exp = prealign(input_data, EXTRA_BIT, M, K, debug=True)

print(f"Aligned fixed-point: {aligned_fx}")
print(f"Aligned exponents: {aligned_exp}")
```

### 테스트 실행

```bash
# 모듈 테스트
python fpint_emul.py

# 전체 테스트 스위트
python test_fpint_emul.py

# pytest 사용
pytest test_fpint_emul.py -v
```

## 구조

```
fpint_emul/
├── fpint_emul.py          # 메인 에뮬레이션 모듈
├── test_fpint_emul.py     # 테스트 스위트
├── requirements.txt       # 의존성 패키지
└── README.md             # 이 파일
```

## 주요 함수

### `fpint_gemm_ref(input_data, weight_data, scale_data, zero_data, M, N, K, qdir=QCOL, debug=False)`
Reference GEMM 구현 (sfpy를 통한 bit-exact FP16 연산)

**계산 방식:**
- **곱셈**: sfpy Float16으로 bit-exact IEEE 754 FP16 연산
  - Input: FP16
  - Weight: INT4 (signed) → FP16으로 변환
  - Scale: FP16
  - 계산: `FP16 × FP16` → FP16 (SoftFloat 사용, HW와 동일)
- **Accumulation**: FP32로 casting 후 누적
- **출력**: FP32 → FP16 변환

**주요 차이점:**
- NumPy의 float16: 내부적으로 float32로 승격하여 계산 (HW와 다름)
- sfpy의 Float16: IEEE 754 FP16 연산을 정확히 재현 (HW와 bit-exact)

**Parameters:**
- `input_data`: (M, K) FP16 activations (uint16)
- `weight_data`: (K, N) INT4 quantized weights (uint8)
- `scale_data`: FP16 scales (uint16)
- `zero_data`: INT16 zero points
- `qdir`: QCOL (0) or QROW (1)
- `debug`: 디버그 출력 활성화

**Returns:**
- `output_data`: (M, N) FP16 출력 (uint16)

### `prealign(input_data, extra_bitwidth, M, K, debug=False)`
FP16 데이터를 fixed-point로 정렬합니다.

**Parameters:**
- `input_data`: (M, K) FP16 배열 (uint16)
- `extra_bitwidth`: 추가 fractional bits (19 또는 3)
- `M`, `K`: 행렬 차원
- `debug`: 디버그 출력 활성화

**Returns:**
- `aligned_fx_data`: (M, K) signed int64 배열
- `aligned_exp_data`: (M, K//MXU_K) uint8 배열

### `fpint_gemm_qcol_2scomp(input_data, weight_data, scale_data, zero_data, M, N, K, debug=False)`
Column-wise quantization GEMM을 수행합니다.

**Parameters:**
- `input_data`: (M, K) FP16 activations
- `weight_data`: (K, N) 4-bit quantized weights
- `scale_data`: (K//QBLOCK, N) FP16 scales
- `zero_data`: (K//QBLOCK, N) int16 zero points
- `M`, `N`, `K`: 행렬 차원
- `debug`: 디버그 출력

**Returns:**
- `output_data`: (M, N) FP16 출력 (uint16)

### `fpint_gemm_qrow_2scomp(input_data, weight_data, scale_data, zero_data, M, N, K, debug=False)`
Row-wise quantization GEMM을 수행합니다.

**Parameters:**
- Scale/zero 차원: (K, N//QBLOCK)
- 나머지는 qcol과 동일

## Constants

```python
QBLOCK = 16          # Quantization block size
MXU_K = 16           # Matrix unit K dimension
MXU_N = 16           # Matrix unit N dimension
EXTRA_BIT = 19       # Main fractional bits
EXTRA_BIT_FOR_REDUCE = 3  # Reduce fractional bits
IN_EXP_BIAS = 15     # FP16 exponent bias
```

## Denormal 처리

FP16 denormal 숫자는 올바르게 처리됩니다:
- Denormal: `exp == 0, mantissa != 0`
- 정렬 시 `exp = max(exp, 1)` 적용
- Hidden bit는 denormal일 때 0

## 디버그 모드

`debug=True`로 설정하면 상세한 계산 과정을 출력합니다:

```python
output = fpint_gemm_qcol_2scomp(..., debug=True)
```

출력 예시:
```
[FPINT_EMUL.PREALIGN] extra_bitwidth=19, M=2, K=16
[FPINT_EMUL.PREALIGN] m=0, kg=0, max_exp=14
[FPINT_EMUL.PREALIGN]   k=0, sign=0, exp=14, man=0x000, shift=0, aligned=0x0000000000400000 (4194304)
...
```

## 검증

SystemVerilog 구현과의 비교:
1. Reference 구현과 bit-exact 일치 확인
2. Denormal 처리 동작 검증
3. 대규모 랜덤 테스트

## 참고

- SystemVerilog 원본: `hw/rtl/verification/fpint_emul.sv`
- 테스트벤치: `hw/rtl/verification/tb_fpint_emul.sv`
