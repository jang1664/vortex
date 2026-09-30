# HPCA 본문 리뷰 및 수정 체크리스트

**대상:** FINISH 논문의 문제 정의, 수식, datapath, memory system, runtime 설명  
**제외:** 현재 조정 중인 실험 설정, 성능 수치, area normalization 및 energy methodology

## 전체 판단

실험 설정을 제외하면 본문의 큰 논리 흐름과 Q-COL/Q-ROW 수식에서 치명적인 오류는 보이지 않는다. 문제 정의에서 출발해 reconfigurable MXU, tensor path, software constraint 처리로 이어지는 구성도 전반적으로 자연스럽다.

다만 HPCA reviewer가 본문만 읽고도 질문할 가능성이 높은 설명 공백이 있다. 우선순위가 가장 높은 항목은 다음 두 가지다.

1. 각 operation과 quantization scheme이 Q-COL/Q-ROW 및 load direction으로 어떻게 매핑되는지
2. I/W/SZ/O의 동시 TMEM 접근을 어떻게 conflict-free하게 유지하는지

아래 항목을 하나씩 해결한다.

## 수정 체크리스트

### 1. Operation-to-mode mapping 표 추가

**상태:** [o] 해결

현재 Table I은 원래 K/V tensor의 token-wise/channel-wise quantization direction만 보여준다. FINISH가 실제로 어떤 Q-COL/Q-ROW 및 load configuration을 사용하는지 알려면 여러 문단을 따라가야 한다.

다음과 같은 표를 추가하는 것이 좋다.

| Operation | INT operand | Original quantization | MXU direction | Load direction |
|---|---|---|---|---|
| Linear | W | channel/group-wise | Q-COL | Standard |
| $QK^T$ | K | token-wise | Q-COL | Transposed |
| $QK^T$ | K | channel-wise | Q-ROW | Transposed |
| $PV$ | V | token-wise | Q-ROW | Standard |
| $PV$ | V | channel-wise | Q-COL | Standard |

이 표의 목적은 다음 두 configuration attribute가 서로 독립적이라는 핵심 기여를 한눈에 보여주는 것이다.

- Quantization direction: Q-COL 또는 Q-ROW
- INT operand loading: Standard 또는 Transposed

표를 넣기 전에 각 quantization scheme의 실제 mapping을 구현과 대조해 확인해야 한다.

---

### 2. G-DMA의 동시 TMEM bank conflict 처리 설명

**상태:** [o] 보류.

본문은 I/W/SZ/O의 네 DMA engine이 각각 TMEM bank를 선택하고, conflict가 없을 때 operand delivery와 output writeback을 overlap한다고 설명한다. 그러나 software section이 명시적으로 보장하는 내용은 주로 다음과 같다.

- HBM–TMEM endpoint mapping
- 64 B alignment
- T-DMA의 conflict-free tile transfer

I/W/SZ/O가 동시에 접근할 때 같은 TMEM bank를 선택하지 않도록 하는 방법은 명확하지 않다. 다음 내용을 설명해야 한다.

- I/W/SZ/O tile을 서로 다른 bank 또는 bank group에 배치하는가?
- Bank assignment는 runtime, descriptor generator, 또는 hardware scheduler 중 어디에서 결정하는가?
- 불가피한 conflict가 발생하면 serialize하거나 stall하는가?
- DMA transfer와 MXU execution을 위한 double buffering 또는 ping-pong schedule은 무엇인가?
- 네 DMA port가 실제로 동시에 최대 bandwidth를 낼 수 있는 조건은 무엇인가?

가능하면 한 개의 representative tile에 대해 bank placement와 cycle-level schedule을 작은 그림 또는 표로 제시한다.

---

### 3. Related-work positioning 강화 및 AxCore 설명 통일

**상태:** [o] 해결

가장 가까운 AxCore와 FINISH의 차이가 현재 한두 문장으로만 설명된다. Source 안에는 AxCore에 대한 서로 다른 표현도 존재하므로 하나로 통일해야 한다.

- `does not natively support token-wise KV quantization`
- `does not natively support channel-wise K and token-wise V quantization`

AxCore가 지원하지 않는 정확한 quantization direction과 operation을 원 논문 및 구현 기준으로 다시 확인한다.

가능하면 다음 항목을 비교하는 표를 추가한다.

| Design | Linear FP-INT | $QK^T$ | $PV$ | Q-COL/Q-ROW | Transposed load | KV schemes | Full stack |
|---|---|---|---|---|---|---|---|
| Prior design(s) |  |  |  |  |  |  |  |
| FINISH |  |  |  |  |  |  |  |

FINISH의 novelty는 TMEM, decoupled GEMM, tile-major layout을 각각 새로운 요소로 주장하기보다 다음 통합점에 집중하는 것이 좋다.

> 다양한 KV quantization direction을 linear 및 attention GEMM 전체에서 하나의 native FP-INT execution path로 처리하고, 이를 실제로 공급할 수 있는 memory/runtime stack까지 통합했다.

---

### 4. Power-of-two bank-count 설명 수정

**상태:** [o] 해결

현재 표현:

> FINISH restricts ... to powers of two to avoid misalignment.

Power-of-two 자체가 misalignment를 방지하는 것은 아니다. 작은 bank count가 큰 bank count를 나누도록 만들어 mapping condition을 단순화하는 것이 정확한 이유다.

추천 표현:

> FINISH restricts both bank counts to powers of two so that the smaller count divides the larger one, simplifying the mapping constraint.

`misalignement` 오탈자도 함께 수정한다.

---

### 5. Q-ROW의 group-size 및 tile-alignment 조건 명확화

**상태:** [o] 보류

Q-ROW scale folding은 32-column MXU tile 전체가 같은 output quantization group에 속한다는 조건에 의존한다. 현재 32, 64, 128 group size 및 padding을 설명하지만 다음 조건이 분명하지 않다.

- 각 output tile의 시작 column도 group boundary에 정렬되는가?
- Output group size가 32보다 작거나 32의 배수가 아니면 지원하지 않는가?
- Padding으로 인한 연산량 및 저장공간 overhead는 어떻게 처리되는가?

조건을 명확히 하는 추천 문장:

> Each output tile starts at a group-aligned column, and FINISH currently supports output-group sizes that are multiples of the 32-column MXU width.

실제 지원 범위가 더 넓다면 구현에 맞게 문장을 조정한다.

---

### 6. Row-major layout에 대한 단정 완화

**상태:** [o] 해결

현재 본문은 shape-dependent padding이나 bank-aware scheduling도 모든 supported shape에서 conflict를 해결하지 못한다고 단정한다. 이에 대한 증명이나 exhaustive analysis가 없다면 reviewer가 반례를 요구할 수 있다.

FINISH의 핵심 주장은 row-major layout으로 conflict-free execution이 불가능하다는 것이 아니라, tile-major layout이 shape별 특수 처리 없이 예측 가능한 bank mapping과 긴 DMA burst를 제공한다는 것이다.

추천 표현:

> Shape-dependent padding or bank-aware scheduling can mitigate these conflicts, but requires shape-specific handling and may break long contiguous DMA bursts.

---

### 7. Crossbar scaling 주장 범위 한정

**상태:** [o] 해결

`grow super-linearly` 또는 conventional crossbar가 FP-INT의 density advantage를 일반적으로 제거한다는 표현은 구현 조건에 따라 달라질 수 있다. Figure 5가 특정 target configuration의 합성 결과라면 그 범위로 한정하는 것이 안전하다.

추천 표현:

> In our target configuration, scaling the conventional crossbar-based path substantially reduces the density advantage of the FP-INT MXU.

가능하면 어떤 요소가 포함된 합성 결과인지 함께 명시한다.

- Crossbar datapath
- Arbitration/control
- Bank/request ports
- SRAM peripheral 또는 macro area 포함 여부

---

### 8. Software FP-INT limitation을 FP×FP와 decode energy로 균형 있게 구성

**상태:** [o] 해결

현재 subsection은 FP×FP MAC의 compute-energy limitation에 집중되어 있다. Decode에서는 fused execution이라도 KV dequantization energy가 무시하기 어렵다는 점을 별도의 limitation으로 연결한다.

Introduction 후보 문장:

> Moreover, unlike prefill, decode repeatedly dequantizes the accessed KV cache at every step, incurring non-negligible energy overhead even when fused.

Background 문단 후보:

> Software FP-INT GEMM kernels keep operands quantized in memory and fuse dequantization with GEMM. Fusion hides much of the conversion latency, but existing Tensor Cores still convert INT operands to FP and execute every MAC on the FP×FP datapath. These kernels therefore retain both the lower compute-energy efficiency of FP×FP execution and, specifically during decode, non-negligible energy overhead from repeatedly dequantizing the accessed KV cache.

최종 수치가 확정되기 전에는 이 문단에서 구체적인 energy 비율을 언급하지 않는다.

## 권장 해결 순서

1. Operation-to-mode mapping 표
2. G-DMA/TMEM bank-conflict 및 overlap schedule
3. AxCore 및 related-work positioning
4. Q-ROW 지원 조건
5. Power-of-two 설명
6. Row-major 및 crossbar claim 완화
7. Software limitation 문단 정리

앞의 세 항목은 논문의 기여와 구현 가능성을 직접 결정한다. 나머지는 기술적 정확성과 claim 강도를 다듬는 작업이다.
