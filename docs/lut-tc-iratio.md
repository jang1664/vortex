# LUT Tensor Core — i_ratio 관점에서의 재해석

**참조 논문**: Mo et al., *LUT Tensor Core: A Software-Hardware Co-Design for LUT-Based Low-Bit LLM Inference*, ISCA 2025 ([arXiv:2408.06003](https://arxiv.org/abs/2408.06003))

이 문서는 LUT Tensor Core(이하 LUT TC)의 설계 선택을 Vortex TCU WMMA 경로에서 익숙한 `i_ratio` / `wmma_config_t` 프레임으로 재해석한다. 관련 기본 개념은 [`rtl/tcu/vx_tensor.md`](rtl/tcu/vx_tensor.md)를 참고.

## 1. 배경 — MAC 기반 WMMA에서의 i_ratio

현재 Vortex TCU WMMA 경로에서 `i_ratio`는 다음과 같이 정의된다:

```cpp
// kernel/include/vx_tensor.h
static constexpr uint32_t i_ratio = sizeof(vreg_t) / sizeof(input_t);
```

의미는 "**32-bit 레지스터 하나에 K 방향으로 몇 개 원소를 packing할지**"이다. fp16이면 2, int8이면 4, int4이면 8.

이 개념은 **두 역할을 동시에** 수행한다:
- (1) 메모리 대역폭 압축 — 로드 한 번에 여러 원소 획득
- (2) MAC의 K-direction 공간적 병렬 입력 제공

### FPxINT 확장 시의 난점

A=fp16(i_ratio=2)과 B=int4(i_ratio=8)를 혼합하면 **element-K 축이 A와 B에서 4배 차이**가 발생하여 `xtileK`를 공유할 수 없다. 해결 옵션은 세 방향이 있다:

1. **정면 분리**: `ItA`/`ItB`를 분리하고 register-K도 각각 다르게 가져간다 → `wmma_config_t`, load path, MAC 경로 전면 재설계.
2. **Padding**: B를 `i_ratio=2`에 맞추어 reg당 int4 2개만 저장(나머지 비트는 don't-care) → SW는 드롭인에 가깝지만 메모리 절약이 사라지거나 load-time expand 파이프라인이 필요.
3. **MAC 회피**: 곱셈 자체를 수행하지 않는 아키텍처로 전환 → LUT TC가 이 방향을 택함.

## 2. LUT TC 핵심 인사이트 — i_ratio 축 회전

사용자 프레이밍으로 정리하면 LUT TC의 설계 변경은 다음과 같이 요약된다:

> **i_ratio가 걸려 있던 축을 K에서 N으로 회전시키고, K는 상수(=4)로 고정하고, weight bit-width 축(W_BIT)을 새로 시간축에 추가한다.**

MAC TC에서 "32-bit 레지스터 하나를 어떻게 채울 것인가?"라는 질문의 답이 LUT TC에서는 축이 달라진다:

| | MAC TC (현재 Vortex) | LUT TC |
|---|---------------------|--------|
| 레지스터 packing 방향 | K 방향 원소 | **N 방향 lane의 selector 비트** |
| i_ratio 정의 | `32bit / sizeof(input_t)` | **`32bit / (K · W_BIT)`** (weight 측) |
| K 처리 방식 | 가변, 공간적(MAC K-lane) | **상수(=4), LUT 차원으로 흡수** |
| W_BIT 처리 방식 | N/A (MAC 폭 고정) | **시간적 (bit-serial cycle)** |
| 활성화 레지스터 | K-packed 원소 | **precomputed LUT entry** |

이 회전의 결과로 "A=fp16, B=int4의 i_ratio 불일치"라는 **문제가 발생할 무대 자체가 제거**된다.

## 3. 가중치 측 — N 방향 packing의 구체적 수치

K=4 고정 기준으로 한 32-bit 레지스터가 담는 N-lane 수:

| Weight 타입 | W_BIT | N-lane당 비트 (= K·W_BIT) | 32-bit reg당 N-lane 수 |
|------------|-------|---------------------------|------------------------|
| INT1       | 1     | 4                         | **8**                  |
| INT2       | 2     | 8                         | **4**                  |
| INT3       | 3     | 12                        | **2** (상위 8비트 미사용) |
| INT4       | 4     | 16                        | **2**                  |

MAC TC와의 **dual 관계**:

- MAC TC: bit-width가 작을수록 **K 방향으로 더 많이** packing (예: int4 → 8개/reg)
- LUT TC: bit-width가 작을수록 **N 방향으로 더 많이** packing (예: INT1 → 8 N-lane/reg)

즉 packing 이득의 구조적 관계가 축만 바꿔 보존된다.

### Bit-serial execution

한 LMMA 명령은 **W_BIT 사이클**에 걸쳐 실행된다. 각 사이클에서:

- weight의 t-번째 비트를 K-lane에서 뽑아내어 LUT 인덱스로 사용
- LUT에서 조회한 값을 `<< t` 시프트하여 누산

같은 1-bit LUT이 모든 비트 평면에서 **재사용**되므로 LUT 저장 용량은 W_BIT과 독립이고 K에만 의존한다.

## 4. 활성화 측 — LUT entry 저장

활성화 레지스터는 더 이상 "K-packed 원소"를 저장하지 않는다. 대신 **미리 계산된 내적 결과(LUT entry)**가 들어간다.

```
warp당 LUT 저장량: M × 2^(K-1) entries   (weight reinterpretation으로 대칭화 후)
entry 폭: Accum_dtype 폭 (예: fp16 또는 fp32)
```

- K=4 → `2^(K-1) = 8` entries per M-row (대칭화 적용 시)
- 예: M=2, Accum=fp16 → 2 × 8 × 2바이트 = 32바이트 = 8 레지스터 분량

활성화 원소 → LUT entry 변환은 **precompute 단계**에서 일어나므로, 레지스터 packing 관점에서 "i_ratio"가 정의될 지점이 없다. 레지스터는 "몇 개의 활성화 원소"가 아니라 "몇 개의 entry"를 저장하는 것으로 용도 변경된다.

### Weight reinterpretation (대칭화)

LUT 저장 절반 절감을 위한 offline 변환:

```
q'_w = 2q_w − (2^K − 1)        // unsigned {0..15} → symmetric {-15, -13, ..., +13, +15}
```

odd-function 대칭성을 활용하여 `LUT[-i] = -LUT[i]`가 되도록 만들고, entries를 `2^K → 2^(K-1)`로 절반 줄인다. 런타임에 부호 비트로 negation을 수행.

## 5. 세 축의 통합 프레이밍

LUT TC는 MAC TC에서의 K·N·M·W_BIT 처리 방식을 다음과 같이 재배치한다:

| 축 | MAC TC | LUT TC |
|----|--------|--------|
| **K** (내적 길이) | 공간적 — MAC 어레이의 K-lane | **상수(=4), LUT 차원으로 pre-materialize** |
| **N** (출력 폭) | thread/register 분산 (NRC) | **weight 레지스터에 selector 비트로 packing** + MUX fan-out |
| **M** | thread/warp 분산 | 동일 (작게 유지 — LUT 저장 부담) |
| **W_BIT** | 존재 안 함 | **시간적 (bit-serial cycle)** |

### Tile shape의 역전

이 축 재배치의 자연스러운 결과:

| | Conventional TC | LUT TC |
|---|----------------|--------|
| 대표 shape | M16 N16 K16 (정사각) | **M2 N64 K4** (길쭉) |
| M | 크게 | 작게 — LUT 저장소 감소 |
| N | 적당 | 크게 — LUT entry 재사용 (MUX fan-out) |
| K | 크게 | 작게(=4) — LUT 크기 `2^K` 지수 폭증 제한 |

MAC TC가 "정사각에 가까운 타일"(Vortex의 `wmma_config_t`도 `xtileM ≈ xtileN ≈ xtileK` 선호)을 최적화하는 것과 정반대 방향이다.

## 6. 하드웨어 비용 — 곱셈기 → MUX + Register

MAC TC의 주 비용은 곱셈기 어레이. LUT TC는 이를 **MUX + 레지스터 파일**로 대체한다:

- **Table storage**: 레지스터 (SRAM/FPGA-LUT 아님) — `M × 2^(K-1)` entries
- **MUX**: weight bit를 selector로 사용해 entry 선택
- **Negation**: 대칭화로 인한 부호 반전 (offline 최적화로 절반 줄임)
- **Accumulator**: Accum_dtype 폭, W_BIT 사이클에 걸쳐 시프트 누산

**논문 수치** (INT1×FP16 기준):
- 면적: 기존 TC의 **38.3%**
- 속도: **5.51×** (BitNet end-to-end)
- Compute density: **20.9×**
- 전력 효율: **11.2×**

## 7. Vortex TCU와 비교한 FPxINT 확장 접근 세 가지

앞서 논의한 세 접근을 동일 프레임으로 대조:

| 접근 | i_ratio 문제 해법 | SW 변경 | HW 변경 | 메모리 비용 |
|------|---------------------|---------|---------|-------------|
| (a) 정면 분리 (ItA/ItB 독립) | 양쪽 경로 모두 유지 | 큼: `wmma_config_t`, load, MAC 전면 | 큼: mixed datapath 신설 | 원본 유지 |
| (b) Padding (int4 → fp16 i_ratio) | B를 느슨하게 저장 | 작음: 드롭인에 가까움 | 중간: MAC 신설, 대칭 구조로 쉬움 | **A: 4× 증가** 또는 load-time expand 복잡도 |
| (c) **LUT TC** | 곱셈 자체를 제거 (축 회전 + 상수화) | 중간: LMMA intrinsic + precompute 커널 + DFG fusion | **큼 but 다른 축**: 곱셈기 → MUX+reg, tile shape 재설계 | **저장 오히려 감소** (38% 면적) |

## 8. 정리

- MAC TC의 `i_ratio`는 "32-bit reg를 K 방향으로 어떻게 쪼갤 것인가"의 답이었다
- FPxINT 확장에서 이 개념은 A·B 간 불일치로 파손된다
- LUT TC는 이 축(K)을 **상수로 고정**하고 packing의 자유도를 **N 방향으로 회전**시켜 문제를 무대 밖으로 내보낸다
- 활성화는 LUT entry로 pre-materialize되어 레지스터 packing 의미가 재정의된다
- W_BIT이라는 새 시간 축이 추가되어 가변 weight bit-width를 흡수한다
- **"i_ratio 불일치"가 문제로 성립하지 않는 아키텍처** — 다만 그 대가로 tile shape가 "길쭉한 M2N64K4"로 역전되고, precompute 단계가 software stack에 새로 요구된다

## 관련 문서

- [`rtl/tcu/vx_tensor.md`](rtl/tcu/vx_tensor.md) — Vortex WMMA API, fragment / NR / mma_sync 상세
- [`rtl/tcu/VX_tcu_pkg.md`](rtl/tcu/VX_tcu_pkg.md) — Vortex TCU HW 파라미터 정의
- [`rtl/tcu/VX_uop_sequencer.md`](rtl/tcu/VX_uop_sequencer.md) — WMMA 명령의 uop 전개 경로
