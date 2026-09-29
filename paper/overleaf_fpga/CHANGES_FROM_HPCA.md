# HPCA → FPGA 전환에서 사라지거나 약해진 정보

비교일: 2026-09-28 · E2 및 I5 복원 반영: 2026-09-29

이 문서는 **HPCA 원고가 전달하던 정보 중 현재 FPGA 원고에서 삭제되거나 덜 명시적으로 전달되는 내용**을 기록한다. 각 정보를 복원해야 하는지, 없어도 되는지는 판단하지 않는다. 서식 변경 목록이나 수정의 정당화 대신, 원문의 주장·이유·조건·범위가 무엇이었고 현재 어디까지 남았는지를 적었다.

## 비교 범위와 읽는 방법

- 원본: [HPCA main.tex](../overleaf_hpca/main.tex). 비교본: [FPGA main.tex](main.tex).
- `%` 주석, `comment`, `\iffalse … \fi`의 비활성 원고는 제외했다. 축약 작업 도중의 버전이 아니라 현재 파일끼리 비교했다.
- 최근 복원한 HPCA 원문의 세미콜론 문장 10곳은 손실에 포함하지 않았다. 초록의 세미콜론 제거 및 활용률 표현 수정도 현재 상태를 기준으로 했다.
- **정보/설명 삭제**는 빠진 내용 자체를, **의미 약화·한정 삭제**는 문장이 남아 있어도 줄어든 의미를 기록한다. **해당 문맥에서 삭제**는 다른 절에 관련 내용이 남아 있는 경우다. 어느 분류도 중요도나 복원 권고를 뜻하지 않는다.
- 각 항목의 **다른 곳에 남은 정보**를 보면, 논문 전체에서 찾을 수 없는 내용과 현재 위치에서만 빠진 내용을 구분할 수 있다. 결과 수치가 남아 있더라도 그 결과를 예상하거나 해석하는 이유가 삭제되었으면 별도로 기록했다.
- 영어 인용은 활성 원문에서 발췌했으며 LaTeX 명령을 유지했다. 인용의 행 링크는 작성 시점 기준이다.

## 섹션별 확인 범위

| 원고 부분 | 이 문서에서 확인할 손실 |
|---|---|
| Numerical and Neural Network Accuracy | Q-COL 정확도 유지·개선의 근거 — E1. E2의 Q-ROW 검증 목적은 HPCA 문장으로 복원 완료 |
| Introduction | 용량 절감의 활용처, 병목 원인, 대역폭의 인과관계, 구현 범위 — I1–I7. I5의 에너지 비용 설명은 복원 |
| Background and Motivation | 실행 단계 설명, compute-bound 이동 가능성, fusion 한정, quantization 정의 — B1–B8 |
| System Overview | SIMT 유지 목적, address flexibility와 비용의 교환 이유 — O1–O2 |
| Abstract | WKV 채택 동향, GPU 경로의 의미, open-source 속성, 설계·평가 목적 — A1–A4 |
| Conclusion | 범용 경로 확장 회피, 공동 설계의 필요성 주장 — C1–C2 |
| 의미가 다른 설명으로 교체된 부분 | Q-ROW 축 방향, 면적·플랫폼 귀속, 기존 연구의 한계·대상 범위 — M1–M4 |
| §4 GEMM Engine, §5 Tensor Memory, §6 Layout/Runtime | 비교한 활성 본문의 문구에서 정보 손실을 발견하지 않음 |
| §7의 정확도 도입부 이외 | 방법론·결과 해설의 문구에서 정보 손실을 발견하지 않음. 문단 병합은 손실에서 제외 |

## 1. Numerical and Neural Network Accuracy — 평가의 근거와 목적

### E1. Q-COL의 정확도가 유지되거나 개선될 것이라는 설명

분류: **설명 삭제** · [HPCA:1631](../overleaf_hpca/main.tex:1631) → [FPGA:1559](main.tex:1559)

**HPCA에서 전달하던 문장**

> Q-COL follows the same scale-application order as conventional GPU FP16 execution while retaining the established FIGNA-style computation, and is therefore expected to preserve, or potentially improve upon, its numerical accuracy.

**현재 FPGA의 대응 표현**

> Q-COL retains the GPU FP16 scale-application order with FIGNA-style arithmetic, while Q-ROW folds scales into the FP operand before prealignment.

**사라지거나 약해진 정보:** **GPU FP16과 같은 scale 적용 순서 및 FIGNA 계산 방식 → 정확도 유지 또는 개선 기대**라는 인과관계가 사라졌다. 현재 문장은 연산 순서와 계산 방식만 설명하며, 그것이 Q-COL 정확도에 어떤 의미를 갖는지 말하지 않는다.

**다른 곳에 남은 정보:** §7.5의 “in Q-COL, its error remains approximately three orders of magnitude lower”라는 측정 결과와 정확도/PPL 표는 남아 있다. 그러나 이 결과가 남아 있다는 사실과, 앞의 정확도 유지·개선 설명이 삭제된 것은 별개다. 정확도 개선의 가능성이라는 `potentially`의 한정까지 포함한 원래 설명은 현재 활성 본문에서 찾지 못했다.

### E2. Q-ROW 검증의 질문이 추가 오차·정확도 저하인지 명시 — 복원 완료

상태: **HPCA 원문으로 복원 완료 (2026-09-29)** · [HPCA:1631](../overleaf_hpca/main.tex:1631) → [FPGA:1559](main.tex:1559)

**현재 두 원고에 동일하게 유지한 문장**

> We therefore examine whether this scale reordering introduces additional arithmetic error or degrades model-level accuracy.

추가 산술 오차나 모델 정확도 저하 여부를 검증한다는 목적을 복원했다. 이 항목은 더 이상 현재 FPGA 원고의 정보 손실에 해당하지 않는다. `main_highlight.tex`에서도 이 문장의 하이라이트를 제거했다. 앞 문장에 관한 E1은 변경하지 않았다.

## 2. Introduction — 문제의 동기와 기여의 범위

### I1. 문제를 키우는 요인과 연산·데이터 이동의 동시 최적화 필요성

분류: **설명 축약** · [HPCA:117](../overleaf_hpca/main.tex:117) → [FPGA:70](main.tex:70)

**HPCA에서 전달하던 문장**

> Large language models (LLMs) have become core AI workloads, but increasing model sizes and context lengths make inference increasingly constrained by memory capacity, memory bandwidth, and compute cost. Efficient serving must therefore reduce both data movement and arithmetic overhead rather than optimizing either in isolation.

**현재 FPGA의 대응 표현**

> Large language model (LLM) inference is constrained by memory capacity, bandwidth, and computation.

**사라지거나 약해진 정보:** 모델 크기와 context 길이의 증가가 제약을 심화한다는 원인, 그리고 **데이터 이동과 산술 비용을 따로 최적화해서는 안 된다**는 도입부의 설계 요구가 빠졌다. LLM이 주요 AI workload라는 배경 설명도 제거됐다.

**다른 곳에 남은 정보:** 긴 context의 KV traffic·attention 연산 증가 설명은 같은 문단에 남아 있다. 연산기와 메모리 경로를 함께 다루는 실제 설계는 §3–6에 남아 있지만, 이 도입 문장의 동시 최적화 요구는 같은 형태로 제시되지 않는다.

### I2. 양자화로 확보한 메모리 용량의 활용처

분류: **정보 삭제** · [HPCA:123](../overleaf_hpca/main.tex:123) → [FPGA:70](main.tex:70)

**HPCA에서 전달하던 문장**

> The saved capacity can be used for a larger model, a longer context, or a larger serving batch, improving the accuracy--throughput--cost tradeoff.

**현재 FPGA의 대응 표현**

> Weight-only quantization (WoQ) reduces model footprint and traffic by storing weights in INT4 or INT8 while retaining FP activations

**사라지거나 약해진 정보:** 절약한 용량을 **더 큰 모델, 더 긴 context, 더 큰 serving batch**에 사용할 수 있다는 세 가지 활용처와, 그 결과 accuracy–throughput–cost tradeoff를 바꿀 수 있다는 설명이 사라졌다.

**다른 곳에 남은 정보:** 현재 본문에는 model footprint와 traffic 감소가 남아 있다. 세 가지 활용처를 이 용량 절감의 효과로 연결하는 설명은 활성 본문에서 찾지 못했다.

### I3. WoQ의 per-token weight traffic과 KV cache의 capacity pressure

분류: **구체성 감소** · [HPCA:126](../overleaf_hpca/main.tex:126) → [FPGA:70](main.tex:70)

**HPCA에서 전달하던 문장**

> the KV cache becomes another major source of capacity and bandwidth pressure

**현재 FPGA의 대응 표현**

> Long contexts also increase KV-cache traffic

**사라지거나 약해진 정보:** KV cache가 대역폭뿐 아니라 **메모리 용량을 압박한다**는 내용이 traffic 증가로 축약됐다. 같은 도입부에서 WoQ가 줄이는 traffic도 원문의 `per-token weight traffic`에서 일반적인 `traffic`으로 바뀌어, 토큰별 weight read 비용이라는 대상이 덜 명시적이다.

**다른 곳에 남은 정보:** 일반적인 memory capacity 제약과 WoQ의 model footprint 감소는 남아 있다. KV cache 자체의 capacity pressure나 WoQ의 per-token weight traffic이라는 구체적 설명과는 구분해야 한다.

### I4. 긴 context에서 attention이 prefill latency의 큰 비중이 된다는 설명

분류: **해당 문맥에서 삭제** · [HPCA:126](../overleaf_hpca/main.tex:126) → [FPGA:70](main.tex:70)

**HPCA에서 전달하던 문장**

> Attention computation also grows with the attended sequence length and becomes a substantial fraction of prefill latency at long contexts

**현재 FPGA의 대응 표현**

> Long contexts also increase KV-cache traffic

**사라지거나 약해진 정보:** 현재 Introduction은 긴 context에서 attention computation이 증가한다고만 적는다. **prefill이라는 단계와 전체 latency에서 attention이 차지하는 비중**을 함께 연결한 설명이 빠졌다.

**다른 곳에 남은 정보:** §2.4의 “especially long-sequence prefill”, Fig. 3의 캡션, §7.2의 long-sequence FP attention 병목 설명에는 관련 정보가 남아 있다. 이 항목은 원고 전체에서 long-context attention 동기가 없어진 경우가 아니다.

### I5. Fusion으로 지연을 숨겨도 반복 dequantization의 에너지 비용은 발생 — 요청한 의미 복원

상태: **non-negligible energy overhead와 지연 은폐 후에도 남는 비용을 복원 (2026-09-29)** · [HPCA:131](../overleaf_hpca/main.tex:131) → [FPGA:80](main.tex:80)

**HPCA에서 전달하던 표현**

> introducing non-negligible energy overhead even when the dequantization latency is hidden through fusion

**현재 FPGA의 대응 표현**

> Marlin~\cite{marlin} and BitDecoding~\cite{bitdecoding} hide much of the conversion latency through fusion, but retain FP MACs. During decode, repeated KV-cache dequantization incurs non-negligible energy overhead even when its latency is hidden through fusion.

반복 KV-cache dequantization의 에너지 overhead가 무시할 수 없으며, fusion으로 지연을 숨겨도 그 비용이 남는다는 의미를 Introduction에 복원했다. HPCA 문장 전체를 그대로 복원한 것은 아니며, 사용자와 확인한 두 문장으로 반영했다.

HPCA의 매 토큰·누적 KV cache 전체 접근이라는 상세 표현은 이 문장에 추가하지 않았다. 매 토큰 dequantization과 누적 cache에 대한 관련 설명은 §2.3과 §7.4에 남아 있다. 에너지 비용의 크기와 지연 은폐와의 관계는 더 이상 이 문맥에서 누락된 정보가 아니다.

### I6. 고밀도 array가 operand와 partial-sum 공급 요구를 높인다는 원인

분류: **해당 문맥에서 삭제** · [HPCA:144](../overleaf_hpca/main.tex:144) → [FPGA:92](main.tex:92)

**HPCA에서 전달하던 문장**

> increasing \fpint{} array density also raises operand- and partial-sum-bandwidth demand

**현재 FPGA의 대응 표현**

> scaling register files, caches, DMA, and crossbars to feed denser arrays can erode their area and energy advantages

**사라지거나 약해진 정보:** Introduction의 두 번째 gap에서 **array density 증가 → operand 및 partial-sum bandwidth 요구 증가 → 주변 구조 확장 비용**이라는 앞 단계가 사라졌다. 해당 문단의 주변 구조 목록에서도 local memory가 빠졌다. 두 번째 contribution 항목에서는 tensor traffic과 범용 경로의 분리 및 높은 MXU 활용률이라는 목적이 restricted connectivity의 공급 설명으로 축약됐다.

**다른 곳에 남은 정보:** §2.4의 operand/partial-sum/command bandwidth 문장, §5 첫 문단과 §5.1의 partial-sum·back-pressure 설명에 해당 이유가 남아 있다. TMEM의 traffic 분리는 §3.3과 §5에도 명시돼 있다.

### I7. Vortex에 무엇을 구현했는지에 대한 기여 항목의 열거

분류: **해당 문맥에서 삭제** · [HPCA:159](../overleaf_hpca/main.tex:159) → [FPGA:105](main.tex:105)

**HPCA에서 전달하던 문장**

> We extend the Vortex GPGPU with the proposed hardware, runtime, and LLM kernels

**현재 FPGA의 대응 표현**

> Four incremental Vortex-based FPGA designs isolate the contributions

**사라지거나 약해진 정보:** 구현·평가 contribution에서 **hardware뿐 아니라 runtime과 LLM kernels도 구현·확장했다**는 범위가 빠졌다. 현재 문장은 네 가지 Vortex 기반 FPGA 설계의 비교 목적을 설명한다.

**다른 곳에 남은 정보:** runtime 확장은 §6.1에, native C++ kernels와 runtime 사용은 §7.1의 Software implementation에 남아 있다. 구현 범위 전체가 사라진 것은 아니다.

## 3. Background and Motivation — 정의와 병목을 설명하는 연결고리

### B1. LLM 연산 구성과 WoQ에서 WKV로 확장되는 단계

분류: **해당 문맥에서 삭제** · [HPCA:222](../overleaf_hpca/main.tex:222) → [FPGA:168](main.tex:168)

**HPCA에서 전달하던 문장**

> The main operations of LLM inference are the Q/K/V linear projections, attention computation

**현재 FPGA의 대응 표현**

> \wkv{} quantization keeps activations in FP and stores weights and KV tensors in INT.

**사라지거나 약해진 정보:** §2.1에서 Q/K/V projection, attention, output projection, FFN을 열거하던 설명이 없어졌다. **WoQ에서는 linear/FFN이 FP×INT가 되고, KV 양자화까지 적용하면 attention도 FP×INT가 된다**는 단계별 설명 대신 WKV의 최종 operand 형식으로 바로 시작한다.

**다른 곳에 남은 정보:** FP Q×INT K와 FP probability×INT V는 Introduction에, Q/K/V/O 및 FFN 연산 목록은 §7.2에 남아 있다. §2.1의 세 개 수식도 유지된다.

### B2. Prefill과 decode가 서로 다른 병목을 갖는 실행상의 이유

분류: **설명 삭제** · [HPCA:304](../overleaf_hpca/main.tex:304) → [FPGA:246](main.tex:246)

**HPCA에서 전달하던 문장**

> Prefill processes the prompt in parallel and is generally compute-bound

**현재 FPGA의 대응 표현**

> Prefill is generally compute-bound

**사라지거나 약해진 정보:** **prefill은 prompt를 병렬 처리한다**는 이유가 제거됐다. 이어지는 decode 문장에서도 **token by token으로 진행하면서 KV cache를 반복해서 읽기 때문에 memory-bound인 경우가 많다**는 원인이 삭제됐다. 현재 §2.2에는 compute-bound/memory-bound라는 분류가 남아 있다.

**다른 곳에 남은 정보:** §2.3의 “for each generated token” 및 §2.4의 “decode repeatedly accesses the growing cache”에 decode의 반복 접근은 남아 있다. prompt의 병렬 처리와 두 실행 방식의 대비를 설명하는 문장은 활성 본문에서 찾지 못했다.

### B3. Arithmetic intensity 증가가 decode를 compute-bound 쪽으로 옮길 수 있음

분류: **설명 삭제** · [HPCA:305](../overleaf_hpca/main.tex:305) → [FPGA:246](main.tex:246)

**HPCA에서 전달하던 문장**

> can move decode closer to the compute-bound regime

**현재 FPGA의 대응 표현**

> Decode is often memory-bound, but batching, GQA, MQA, MLA, and quantization increase arithmetic intensity

**사라지거나 약해진 정보:** GQA/MQA/MLA/batching/quantization이 arithmetic intensity를 높인다는 내용은 남았지만, **그래서 decode도 compute-bound 영역에 가까워질 수 있다**는 해석이 빠졌다. `can`으로 표현했던 가능성까지 포함한 설명이다.

**다른 곳에 남은 정보:** roofline 그림과 arithmetic intensity 증가 문장은 유지됐다. 독자가 그림에서 읽어낼 수 있는 것과 본문이 이 가능성을 명시하는 것은 구분했다.

### B4. Fusion의 지연 은폐 범위를 제한하던 much of

분류: **한정 표현 삭제** · [HPCA:337](../overleaf_hpca/main.tex:337) → [FPGA:275](main.tex:275)

**HPCA에서 전달하던 문장**

> Although this fusion hides much of the conversion latency

**현재 FPGA의 대응 표현**

> Fusion hides conversion latency, not its energy or the cost of FP arithmetic.

**사라지거나 약해진 정보:** §2.3에서 fusion이 conversion latency의 **상당 부분**을 숨긴다는 한정이 사라졌다. 현재 문장만 보면 은폐 범위가 제한되지 않은 표현으로 읽힐 수 있다.

**다른 곳에 남은 정보:** Introduction의 “hide much of the conversion latency”와 §7.1의 “hide most, but not all”은 유지된다. 원고 전체에서 이 한정이 사라진 것은 아니다.

### B5. Lookup 방식이 이용하는 low-bit weight pattern과 제거하는 실행 경로

분류: **기전 설명 축약** · [HPCA:351](../overleaf_hpca/main.tex:351) → [FPGA:288](main.tex:288)

**HPCA에서 전달하던 문장**

> exploit low-bit weight patterns to replace dot products with table lookups

**현재 FPGA의 대응 표현**

> replace low-bit dot products with table lookups

**사라지거나 약해진 정보:** FIGLUT/LUT Tensor Core 설명에서 lookup이 **low-bit weight pattern을 이용한다**는 대상과 기전이 빠졌다. 이어지는 문장에서도 기존 dequantize-then-FP-MAC 경로를 제거한다는 설명 및 TOPS/mm²·TOPS/W라는 두 지표명이 `array-level efficiency`로 축약됐다.

**다른 곳에 남은 정보:** TOPS/mm²와 TOPS/W라는 지표는 Introduction에 남아 있다. §4는 FINISH/FIGNA의 integer arithmetic을 설명하지만, 기존 LUT 방식의 low-bit weight pattern 활용 설명을 대신하지는 않는다.

### B6. Token/channel 방향, group size, 하드웨어 방향이 서로 다른 개념임을 설명

분류: **명시성 감소** · [HPCA:383](../overleaf_hpca/main.tex:383) → [FPGA:318](main.tex:318)

**HPCA에서 전달하던 문장**

> These hardware directions are distinct from the token-wise and channel-wise quantization directions of the original K and V tensors.

**현재 FPGA의 대응 표현**

> The mapping from token/channel quantization depends on the operation and load orientation.

**사라지거나 약해진 정보:** 원래 K/V tensor의 token/channel quantization 방향과 MXU가 보는 Q-COL/Q-ROW가 **서로 다른 좌표계의 개념**이라는 명시적 설명이 제거됐다. 앞 문단에서는 metadata가 scale·zero point라는 정의, token-wise/channel-wise라는 명명, 동일한 K/V도 framework에 따라 다른 축으로 quantize될 수 있다는 설명이 축약됐다.

**다른 곳에 남은 정보:** 현재도 token/channel과 Q-COL/Q-ROW를 각각 언급하고 mapping이 operation/load orientation에 달렸다고 설명한다. group size가 metadata를 공유하는 원소 수라는 정의와 scheme별 K/V 방향 표도 남아 있다. 정의와 표가 전부 삭제된 경우는 아니다.

### B7. FP attention fallback이 잃는 두 가지 효율과 두 단계의 적용 관계

분류: **설명 약화** · [HPCA:356](../overleaf_hpca/main.tex:356) → [FPGA:291](main.tex:291)

**HPCA에서 전달하던 문장**

> Falling back to an FP attention path therefore loses the compute- and energy-efficiency benefits of KV-cache quantization in both stages

**현재 FPGA의 대응 표현**

> FP fallback therefore limits both stages, especially long-sequence prefill

**사라지거나 약해진 정보:** FP fallback의 불이익을 **KV-cache 양자화의 compute efficiency와 energy efficiency를 모두 잃는 것**으로 특정하던 설명이 “두 단계를 제한한다”로 바뀌었다. 이 문장 안에서는 무엇이 손실되는지 드러나지 않는다.

**다른 곳에 남은 정보:** prefill/decode 모두 영향을 받는다는 범위는 남아 있다. compute-density/energy 이점은 Introduction에, 실제 latency와 energy 결과는 §7에 남아 있다.

### B8. Operand 공급의 지연 조건과 범용 경로 확장의 구체적 대상

분류: **해당 문맥에서 삭제** · [HPCA:408](../overleaf_hpca/main.tex:408) → [FPGA:340](main.tex:340)

**HPCA에서 전달하던 문장**

> system-level throughput also depends on memory bandwidth, command bandwidth, and low-latency tensor transfers

**현재 FPGA의 대응 표현**

> A denser MXU needs matching operand, partial-sum, and command bandwidth.

**사라지거나 약해진 정보:** §2.4의 시스템 요구에서 **낮은 tensor-transfer latency**가 빠지고 bandwidth 요구만 남았다. 이어지는 설명도 local memory/cache/register file을 연결하는 crossbar와 FP×FP MXU 교체 상황의 열거를 줄이고, ports/banks 증가에 따른 면적 비용으로 축약됐다.

**다른 곳에 남은 정보:** §5.3의 TMEM 1-cycle 대 baseline 약 20-cycle access latency와 outstanding request/queue 설명은 유지된다. 범용 경로의 구체적 구성과 확장 비용은 §5에 남아 있다.

## 4. System Overview — 설계 선택의 목적과 전제

### O1. SIMT를 남겨두는 목적: programmability와 generality

분류: **목적 설명 삭제** · [HPCA:443](../overleaf_hpca/main.tex:443) → [FPGA:373](main.tex:373)

**HPCA에서 전달하던 문장**

> to preserve programmability and generality

**현재 FPGA의 대응 표현**

> The SIMT pipeline retains control flow, kernel launch, synchronization, and vector operations

**사라지거나 약해진 정보:** SIMT가 처리하는 control/vector/launch/synchronization 기능 목록은 남았지만, 이를 유지하는 이유가 **programmability와 generality의 보존**이라는 설명은 빠졌다.

**다른 곳에 남은 정보:** §5.1에는 “local memory preserves the SIMT programming model”이라는 관련 설명이 남아 있다. 다만 이는 local memory의 역할이며, §3.1에서 SIMT를 유지하는 전체 설계 목적과 동일한 문장은 아니다.

### O2. 주소 유연성을 포기할 수 있는 이유: GEMM의 규칙적인 tiled access

분류: **인과 설명 축약** · [HPCA:511](../overleaf_hpca/main.tex:511) → [FPGA:440](main.tex:440)

**HPCA에서 전달하던 문장**

> The simplified connectivity trades address flexibility for lower cost, but GEMM tensors follow regular tiled access patterns

**현재 FPGA의 대응 표현**

> Restricted connectivity lowers hardware cost

**사라지거나 약해진 정보:** §3.3에서 **address flexibility를 비용과 맞바꾼다 → GEMM 접근이 규칙적이므로 그 제약을 감수할 수 있다 → allocation/layout으로 충족한다**는 설명이, 비용 감소와 제약 충족이라는 두 문장으로 줄었다. alignment-aware allocation의 대상이 HBM이라는 구체성도 이 위치에서 빠졌다.

**다른 곳에 남은 정보:** §5의 제한된 연결 및 alignment 조건과 §6의 실제 allocation/tile-major 설명은 유지된다. §6 첫 문단에도 “trades interconnect cost for three software-visible address constraints”가 남아 있다. 제약이나 해결법 자체의 삭제가 아니라 Overview의 설계 이유가 축약된 경우다.

## 5. Abstract — 초록만 읽을 때 전달되지 않는 정보

### A1. WKV 양자화의 채택이 늘고 있다는 동향

분류: **정보 삭제** · [HPCA:99](../overleaf_hpca/main.tex:99) → [FPGA:54](main.tex:54)

**HPCA에서 전달하던 문장**

> LLM inference increasingly employs both weight and KV cache quantization.

**현재 FPGA의 대응 표현**

> Weight-and-KV-cache (WKV) quantization makes the dominant LLM GEMMs products of FP activations and INT weights or KV tensors.

**사라지거나 약해진 정보:** WKV 양자화를 **점점 더 사용한다**는 동향 설명이 삭제되고, WKV가 만드는 연산 형태로 시작한다.

**다른 곳에 남은 정보:** Introduction에는 긴 context와 KV traffic 때문에 WKV를 사용한다는 동기가 있다. 채택 증가 자체를 명시한 문장은 활성 본문에서 찾지 못했다.

### A2. GPU 경로의 실행 방식과 memory 이점·compute/energy 손실의 대비

분류: **해당 문맥에서 삭제** · [HPCA:99](../overleaf_hpca/main.tex:99) → [FPGA:54](main.tex:54)

**HPCA에서 전달하던 문장**

> Today's GPUs execute these operations by dequantizing INT operands on the fly and running the resulting FP$\times$FP product on Tensor Cores.

**현재 FPGA의 대응 표현**

> GPUs dequantize INT operands before FP$\times$FP computation

**사라지거나 약해진 정보:** 초록에서 **on-the-fly 변환과 Tensor Core 사용**이 빠졌다. 뒤따르던 “memory traffic은 줄이지만 compute/energy 효율 이점은 잃는다”는 대비도 제거됐다. 기존 가속기가 남기는 FP attention 문제가 특히 long-context에서 문제라는 범위도 초록에서는 빠졌다.

**다른 곳에 남은 정보:** GPU 실행 방식과 효율의 대비는 Introduction/§2.3에 남아 있다. long-context attention 병목은 I4에 적은 위치에 남아 있다.

### A3. Vortex가 open-source라는 속성

분류: **정보 삭제** · [HPCA:103](../overleaf_hpca/main.tex:103) → [FPGA:54](main.tex:54)

**HPCA에서 전달하던 문장**

> we extend the open-source Vortex GPGPU into an end-to-end stack

**현재 FPGA의 대응 표현**

> We extend the Vortex GPGPU and evaluate four incremental designs on an FPGA prototype.

**사라지거나 약해진 정보:** Vortex의 **open-source** 속성이 초록에서 제거됐다. §3.1의 `Built on the open-source Vortex GPGPU`도 `Built on Vortex`로 바뀌었다.

**다른 곳에 남은 정보:** Vortex 이름과 인용은 남아 있다. 참고문헌 제목의 표기는 별개로, 현재 활성 본문에서 open-source라고 직접 설명하는 문장은 찾지 못했다.

### A4. 초록에서의 설계 목표와 단계별 평가 목적

분류: **해당 문맥에서 삭제** · [HPCA:103](../overleaf_hpca/main.tex:103) → [FPGA:54](main.tex:54)

**HPCA에서 전달하던 문장**

> evaluate four incremental design points to isolate the system-level contribution of each architectural feature

**현재 FPGA의 대응 표현**

> evaluate four incremental designs on an FPGA prototype

**사라지거나 약해진 정보:** 초록에서 네 설계를 비교하는 목적이 **각 architectural feature의 시스템 기여를 분리하는 것**이라는 설명이 빠졌다. FINISH 소개 역시 array-level efficiency를 system-level speedup으로 전환한다는 목표 대신 linear와 attention으로 native 실행 범위를 확장한다고 설명한다. tensor interconnect의 `low-cost` 수식어도 초록에서는 사라졌다.

**다른 곳에 남은 정보:** 기여 분리 목적은 Introduction의 네 번째 contribution과 §7.1에 남아 있다. array-to-system 이득은 Conclusion에, interconnect 비용 감소는 §3.3과 §5에 남아 있다. 최근 복원한 `sustain high utilization of the denser array`는 현재 초록에 있으므로 손실로 기록하지 않았다.

## 6. Conclusion — 결과에서 끌어내는 주장

### C1. 전용 메모리가 범용 메모리 fabric의 비례 확장을 피한다는 설명

분류: **해당 문맥에서 삭제** · [HPCA:2079](../overleaf_hpca/main.tex:2079) → [FPGA:2006](main.tex:2006)

**HPCA에서 전달하던 문장**

> A dedicated tensor-memory subsystem feeds the denser compute array without proportionally scaling the general-purpose memory fabric.

**현재 FPGA의 대응 표현**

> with dedicated tensor memory sustaining the denser array

**사라지거나 약해진 정보:** Conclusion에서 **높아진 compute density를 지원하되 범용 memory fabric은 그에 비례해 키우지 않는다**는 비용상의 의미가 빠졌다. 현재 문장은 tensor memory가 array를 지원한다는 기능만 전달한다.

**다른 곳에 남은 정보:** Introduction의 두 번째 contribution 및 §5의 memory-system 설명에는 비례 확장을 피한다는 내용이 남아 있다.

### C2. 연산기와 operand delivery의 공동 설계가 필요하다는 결론

분류: **주장 강도 변경** · [HPCA:2085](../overleaf_hpca/main.tex:2085) → [FPGA:2006](main.tex:2006)

**HPCA에서 전달하던 문장**

> realizing the system-level benefit of WKV quantization requires co-designing native \fpint{} attention support with an operand-delivery system capable of sustaining the increased compute density

**현재 FPGA의 대응 표현**

> These results show how native quantized-attention support and operand delivery together translate array efficiency into system-level gains.

**사라지거나 약해진 정보:** **시스템 이득을 얻으려면 두 요소를 공동 설계해야 한다**는 필요조건 형태의 주장이 없어졌다. 현재 문장은 두 요소가 함께 시스템 이득을 만드는 방식을 결과가 보여준다고 설명한다. 공동 설계라는 연구 결론의 강도가 달라졌다.

**다른 곳에 남은 정보:** 두 요소의 결합 자체와 측정된 speedup/energy 수치는 남아 있다. 필요조건의 주장과 결합 설계에서 관찰한 효과를 구분해 기록했다.

## 7. 삭제로만 분류할 수 없는 의미 변경

### M1. Q-ROW 매핑의 non-reduction 설명이 reduction terms 설명으로 교체

분류: **의미 변경** · [HPCA:384](../overleaf_hpca/main.tex:384) → [FPGA:318](main.tex:318)

**HPCA에서 전달하던 문장**

> maps its quantization groups along the non-reduction dimension of the GEMM

**현재 FPGA의 대응 표현**

> Their scales and zero points vary across reduction terms

**사라지거나 약해진 정보:** HPCA의 channel-wise K 및 token-wise V 예시는 group이 **non-reduction dimension**에 놓인다고 설명했다. FPGA에서는 해당 두 경우가 Q-ROW라는 매핑은 유지하면서, scale/zero point가 **reduction terms에 따라 변한다**고 설명한다. 원래 축 방향 설명이 다른 설명으로 교체된 것이다.

**다른 곳에 남은 정보:** 양쪽 원고의 상세 엔진 절과 수식은 유지됐다. 이 문서에서는 어느 설명을 채택해야 하는지 판단하지 않는다. 단어 축약으로 처리하면 검토에서 놓칠 수 있는 의미 변경으로 분리했다.

### M2. 5.5% 면적 비중의 주어와 array 효율 결과의 플랫폼 수식 범위

분류: **결과의 귀속 표현 변경** · [HPCA:511](../overleaf_hpca/main.tex:511) → [FPGA:440](main.tex:440)

**HPCA에서 전달하던 문장**

> Together, they scale HBM-to-TMEM bandwidth to $8\times$ the baseline with only 5.5\% of the total area.

**현재 FPGA의 대응 표현**

> The tensor path provides $8\times$ the baseline HBM-to-TMEM bandwidth, while DMA and interconnect logic occupy 5.5\% of total area.

**사라지거나 약해진 정보:** Overview의 5.5%가 기존에는 `Together, they`가 가리키는 설계에 붙어 있었고, 현재는 **DMA and interconnect logic**의 비중이라고 표현된다. 또한 HPCA Conclusion에서는 `On an FPGA prototype`이 array-level TOPS/mm²·TOPS/W 설명을 앞에서 수식했으나, FPGA Conclusion에서는 이 구절이 end-to-end speedup 문장 앞으로 이동했다.

**다른 곳에 남은 정보:** 8×, 5.5%, array-level 3.13×/2.54× 등의 수치와 §7.1의 FPGA 측정/28 nm 합성 방법 설명은 유지됐다. 수치의 삭제가 아니라 무엇의 값이며 어느 플랫폼에 관한 문장인지에 대한 귀속 표현의 변경이다.

### M3. 기존 attention 가속기의 한계: quantization methods에서 directions로 범위 변경

분류: **설명 범위 변경** · [HPCA:144](../overleaf_hpca/main.tex:144) → [FPGA:92](main.tex:92)

**HPCA에서 전달하던 문장**

> existing attention-oriented designs cannot efficiently handle various quantization methods

**현재 FPGA의 대응 표현**

> Attention-oriented designs also lack efficient support for some quantization directions

**사라지거나 약해진 정보:** Introduction에서 기존 attention 가속기의 지원 한계를 **여러 quantization method**에 대한 문제로 설명하던 표현이 **일부 quantization direction**에 대한 문제로 바뀌었다. method와 direction은 같은 범위의 용어가 아니므로, 원문의 더 넓은 표현이 사라진 것으로 구분했다. 원문에 구체적으로 적혀 있지 않은 다른 제약까지 있었다고 추정하지는 않는다.

**다른 곳에 남은 정보:** §2.4의 scheme별 방향 표와 AxCore의 channel-wise K/token-wise V 지원 한계는 유지된다. 어떤 범위로 주장할지는 이 문서에서 판단하지 않는다.

### M4. 결론의 기존 가속기를 FP-INT 가속기로 한정하던 표현

분류: **대상 한정 삭제** · [HPCA:2077](../overleaf_hpca/main.tex:2077) → [FPGA:2006](main.tex:2006)

**HPCA에서 전달하던 문장**

> most prior \fpint{} accelerators accelerate only linear layers and fall back to an FP$\times$FP datapath for attention

**현재 FPGA의 대응 표현**

> prior accelerators typically retain FP attention

**사라지거나 약해진 정보:** Conclusion에서 비교 대상이 **기존 FP-INT accelerators**라는 한정이 빠져 `prior accelerators`로 바뀌었다. linear layer만 가속한다는 명시적 범위와 attention의 FP×FP datapath라는 구체적 실행 형식도 이 문장에서 제거됐다.

**다른 곳에 남은 정보:** Abstract와 Introduction에는 prior FP-INT accelerator 및 linear-only 한계가 남아 있다. 원고 전체의 비교 대상이 새로 정의된 것은 아니지만, 결론만 읽을 때의 대상 범위가 달라졌다.

## 8. 손실로 계산하지 않은 내용

- Q-COL/Q-ROW 수식, zero-point correction, 32개 FP multiplier 공유, operand-loading 방향에 관한 상세 설명은 유지됐다.
- Tensor-memory의 interleaving/alignment 제약, T-DMA/G-DMA, cache bypass의 coherence 및 visibility 설명, tile-major allocation/layout/fusion 설명은 유지됐다.
- C1–C4 정의, FPGA 측정 및 28 nm 합성 방법, workload·quantization 조건, latency/energy 결과 해설은 유지됐다.
- 정확도 절의 fan-in 범위, FP64 reference, Q-COL의 약 세 자릿수 낮은 ULP error, Q-ROW의 유사한 error, zero-shot accuracy/PPL 결과는 유지됐다. **이 사실은 E1에 적은 설명의 손실을 취소하지 않는다. E2는 원문 복원으로 해결됐다.**
- 표·그림의 위치 이동, 문단 병합, 문서 클래스·간격·글꼴 변경, 세미콜론만 변경한 부분은 정보 손실 목록에서 제외했다.
- §2 끝에서 Q-COL/Q-ROW 지원·tensor memory·software support를 함께 열거하던 문장은 없어졌지만, 이 세 요소 및 그 결합은 §3–6에 남아 있다. 해당 요소 자체가 없어진 것으로 계산하지 않았다.

2026-09-29에는 사용자 요청에 따라 FPGA의 `main.tex`와 `main_highlight.tex`에서 E2 문장을 HPCA 원문으로 복원하고, I5의 에너지 비용 설명을 합의한 문구로 복원했다. HPCA 원고는 수정하지 않았다.
