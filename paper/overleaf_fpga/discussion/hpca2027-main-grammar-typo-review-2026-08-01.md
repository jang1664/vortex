# HPCA 2027 Main Track 원고 문법·오탈자 검토

검토 대상: `_outputs/main.pdf` (2026-08-01 빌드, 본문 1–11쪽)

이 문서는 PDF에 실제로 나타나는 영어 문장과 그림 표기를 검토한 결과다. 참고문헌에 수록된 논문 제목과 저자명은 원 출판물의 표기를 보존해야 하므로 검사 대상에서 제외했다.

판정은 다음 두 등급으로 구분한다.

- **수정 필요**: 관사, 수식 관계, 띄어쓰기, 하이픈, 관용 표현 등에 명확한 문제가 있다.
- **수정 권장**: 문법적으로 성립할 수는 있지만 선행사나 수식 대상이 모호하거나, 학술 문장으로 부자연스럽다.

## 1. 수정이 필요한 항목

### 1.1 관사 누락: `dedicated tensor memory and datapath`

- PDF: 2쪽, Introduction의 contribution 목록
- Source: [`main.tex:153`](../main.tex#L153)
- 원문:

  > We present dedicated tensor memory and datapath to decouple tensor traffic ...

- 수정안:

  > We present a dedicated tensor-memory subsystem and datapath to decouple tensor traffic ...

- 이유:

  `memory`는 이 문맥에서 불가산 명사로 무관사 사용이 가능하지만, `datapath`는 가산 명사의 단수형이므로 관사 없이 단독으로 사용할 수 없다. 두 명사를 하나의 설계 요소로 묶으려면 `a dedicated ... subsystem and datapath`처럼 관사를 명시하는 편이 자연스럽다. 이미 원고의 다른 부분에서 `a dedicated tensor-memory subsystem`을 사용하므로 그 표현과 맞추는 것이 가장 안전하다.

### 1.2 단수 가산 명사의 한정사 누락: `Quantization group size`

- PDF: 3쪽, Limitation 1
- Source: [`main.tex:352`](../main.tex#L352)
- 원문:

  > Quantization group size separately specifies how many elements share each metadata entry.

- 수정안 A:

  > The quantization group size separately specifies how many elements share each metadata entry.

- 수정안 B:

  > A separate group-size parameter specifies how many elements share each metadata entry.

- 이유:

  여기서 `group size`는 하나의 구체적인 파라미터를 뜻하는 단수 가산 명사구다. 영어의 단수 가산 명사는 보통 `a`, `the`, 소유격 등의 한정사가 필요하다. 앞 문장에서 이미 quantization metadata를 설명했으므로 특정 파라미터를 가리키는 `The`가 적절하다. 수정안 B는 `separately`가 무엇과 분리된다는 뜻인지도 더 명확하게 만든다.

### 1.3 괄호 앞 공백 누락: `direction(QDir)`

- PDF: 4쪽, Hardware-Generated GEMM Command Stream
- Source: [`main.tex:519`](../main.tex#L519)
- 원문:

  > quantization direction(QDir)

- 수정안:

  > quantization direction (QDir)

- 이유:

  영어 본문에서 약어·기호를 설명하는 괄호는 앞 단어와 한 칸 띄운다. 함수 호출이나 수학식이 아니므로 `direction(QDir)`처럼 붙이면 안 된다.

### 1.4 비교 구문의 수식 대상이 잘못 연결됨

- PDF: 7쪽, GEMM Engine DMA
- Source: [`main.tex:919`](../main.tex#L919)
- 원문:

  > Because TMEM is tightly coupled and provides a 1-cycle access latency, compared with the roughly 20-cycle access latency of the baseline local-memory path, the G-DMA sustains its port bandwidth ...

- 수정안:

  > Because TMEM is tightly coupled and has a 1-cycle access latency—versus roughly 20 cycles for the baseline local-memory path—the G-DMA sustains its port bandwidth ...

- 이유:

  원문의 `compared with ...` 분사구는 쉼표 뒤에 놓여 주절의 주어인 `the G-DMA`를 수식하는 것처럼 읽힌다. 하지만 실제로 비교하려는 대상은 G-DMA가 아니라 `TMEM의 1-cycle latency`와 `baseline local-memory path의 20-cycle latency`다. 비교 대상을 같은 문법적 위치에 두어야 한다.

### 1.5 약어 발음에 따른 관사 오류: `a FP16×FP16`

- PDF: 8쪽, C1 설명
- Source: [`main.tex:1252`](../main.tex#L1252)
- 원문:

  > C1 enables a FP16×FP16 tensor core unit (TCU).

- 수정안:

  > C1 enables an FP16×FP16 tensor core unit (TCU).

- 이유:

  `a/an`은 철자가 아니라 발음으로 결정한다. `FP16`은 보통 “eff-pee sixteen”으로 읽으며 첫소리가 모음 `/ɛ/`이므로 `an`을 사용한다.

### 1.6 Figure 번호 앞 공백 누락: `Fig.11`

- PDF: 9쪽, Latency/Power/Area Measurement Methodology
- Source: [`main.tex:1311`](../main.tex#L1311)
- 원문:

  > Fig.11 shows the floorplan of the complete design.

- 수정안:

  > Fig. 11 shows the floorplan of the complete design.

- LaTeX 수정:

  ```tex
  Fig.~\ref{fig:floorplan}
  ```

- 이유:

  약어 `Fig.`와 번호 사이에는 공백이 필요하다. LaTeX에서는 줄바꿈으로 둘이 분리되는 것을 방지하기 위해 일반 공백보다 nonbreaking space인 `~`를 사용한다.

### 1.7 복합 수식어와 괄호 앞 공백

- PDF: 10쪽, Fig. 12 캡션
- Source: [`main.tex:1407`](../main.tex#L1407)
- 원문:

  > system-level time-to-first-token(TTFT)/time-per-output-token(TPOT)

- 수정안:

  > system-level time to first token (TTFT) and time per output token (TPOT)

- 이유:

  두 가지 문제가 있다.

  1. `token(TTFT)`와 `token(TPOT)`에서 설명용 괄호 앞 공백이 빠졌다.
  2. `time to first token`과 `time per output token`은 여기서 명사구 자체로 사용되므로 전체를 하이픈으로 연결할 필요가 없다. 하이픈은 이 명사구가 다른 명사를 앞에서 수식할 때 주로 사용한다. 슬래시보다 `and`를 사용하면 두 지표의 병렬 관계도 명확해진다.

### 1.8 결론의 비관용적 표현: `on geometric mean`

- PDF: 11쪽, Conclusion
- Source: [`main.tex:2080`](../main.tex#L2080)
- 원문:

  > FINISH reduces end-to-end latency by 3.24× in prefill and 5.93× in decode on geometric mean, and energy per token by 2.67× and 8.72×, respectively.

- 수정안:

  > Compared with the linear-only FP-INT baseline, FINISH achieves geometric-mean end-to-end speedups of 3.24× in prefill and 5.93× in decode, while reducing energy per token by 2.67× and 8.72×, respectively.

- 이유:

  영어에서는 집계 방식을 나타낼 때 `on geometric mean`이라고 하지 않는다. `on average`, `in terms of the geometric mean`, 또는 형용사형 `geometric-mean`을 사용한다. 또한 원문은 하나의 `reduces`가 latency와 energy에 동시에 걸리면서 두 쌍의 수치를 `respectively`로 연결해 구조가 복잡하다. Abstract와 같은 `achieves ... speedups, while reducing ...` 구조로 쓰면 지연시간과 에너지 결과가 명확히 분리된다.

## 2. 그림 내부의 명확한 표기 오류

다음 항목은 PDF 5쪽 Fig. 6 내부에 있다. 이 텍스트는 `main.tex`가 아니라 포함된 그림 파일 `figures/top_diagram.pdf` 안에 들어 있다.

| 현재 표기 | 수정 표기 | 이유 |
|---|---|---|
| `High Bandwidth Memory(HBM)` | `High-Bandwidth Memory (HBM)` | 복합 형용사 `High-Bandwidth`에 하이픈이 필요하고, 설명용 괄호 앞을 띄워야 한다. |
| `RMSnorm` | `RMSNorm` | 고유 알고리즘 명칭의 일반적인 대소문자 표기는 `RMSNorm`이다. |
| `No Back - pressure` | `No Backpressure` | `backpressure`는 이 문맥에서 한 단어로 쓰며, 하이픈 양쪽의 불필요한 공백도 제거해야 한다. |
| `64B` | `64 B` | SI/IEEE식 단위 표기에서는 숫자와 단위 기호 사이를 띈다. 본문에서도 `64 B`를 사용한다. |

## 3. 문법적으로 가능하지만 수정을 권장하는 항목

아래 항목은 엄밀히 말해 모두 “문법 오류”라고 단정할 수는 없다. 다만 선행사, 수식 범위 또는 논리적 병렬성이 모호해 reviewer가 문장을 다시 읽게 만들 수 있다.

### 3.1 복합 수식어의 범위가 모호함

- PDF: 1쪽, Abstract
- Source: [`main.tex:95`](../main.tex#L95)
- 원문:

  > In such weight and KV cache (WKV) quantized models, ...

- 권장 수정:

  > In such WKV-quantized models, ...

  또는

  > In models with quantized weights and KV caches, ...

- 이유:

  원문은 `quantized`가 `weight`에만 걸리는지, `weight and KV cache` 전체에 걸리는지 즉시 명확하지 않다. 여러 단어가 뒤의 명사를 공동으로 수식할 때는 `WKV-quantized models`처럼 복합 수식어를 하이픈으로 묶거나 전치사구로 풀어 쓰는 편이 안전하다.

### 3.2 대명사 `They`의 선행사가 멀리 있음

- PDF: 1쪽, Introduction
- Source: [`main.tex:130`](../main.tex#L130)
- 원문:

  > They therefore capture the memory benefit of quantization ...

- 권장 수정:

  > These kernels therefore capture the memory benefit of quantization ...

- 이유:

  문법적으로 `They`는 앞의 `Software kernels`를 가리킬 수 있다. 그러나 그 사이에 `generating each token`, `the accumulated KV cache`, `energy overhead` 등 여러 명사구가 있어 선행사가 멀고 모호하다. 학술 문장에서는 핵심 주어를 다시 명시하는 편이 읽기 쉽다.

### 3.3 부자연스러운 전치사: `dequantize them onto`

- PDF: 2쪽, Why Memory Savings Alone Are Insufficient
- Source: [`main.tex:304`](../main.tex#L304)
- 원문:

  > ... rather than reducing memory traffic only to dequantize them onto an FP unit.

- 권장 수정:

  > ... rather than reducing memory traffic only to dequantize the operands before executing them on an FP unit.

- 이유:

  `dequantize A onto B`는 일반적인 영어 결합이 아니다. `onto`는 대상을 어떤 위치나 장치 위로 이동시키는 의미를 강하게 갖지만, 여기서는 dequantization 이후 FP unit에서 연산한다는 시간적 순서를 표현하려는 것이다. 따라서 `dequantize ... before executing ... on`이 정확하다. `them`이 operands인지 traffic인지 모호한 점도 명사 재사용으로 해결된다.

### 3.4 비표준적인 병렬 명사: `compute-energy efficiency`

- PDF: 2쪽, Limitations of Software-Based FP-INT Execution
- Source: [`main.tex:336`](../main.tex#L336)
- 원문:

  > ... retain the lower compute-energy efficiency of FP×FP execution ...

- 권장 수정:

  > ... retain the lower computational and energy efficiency of FP×FP execution ...

  또는 의도가 에너지 효율 하나라면:

  > ... retain the lower energy efficiency of FP×FP execution ...

- 이유:

  `compute-energy efficiency`는 널리 정착된 복합 명사가 아니어서 `compute energy`라는 하나의 물리량인지, computation efficiency와 energy efficiency라는 두 지표인지 불분명하다. 두 지표를 뜻한다면 접속사 `and`로 병렬 구조를 명시해야 한다.

### 3.5 열거 마지막 항목의 문법적 형태가 다름

- PDF: 5쪽, Quantization-Direction-Reconfigurable FP-INT GEMM Engine
- Source: [`main.tex:579`](../main.tex#L579)
- 원문:

  > ... with g(k)=..., h(n)=..., and K_g the reduction indices in group g.

- 권장 수정:

  > ... with g(k)=..., h(n)=..., and K_g denoting the set of reduction indices in group g.

- 이유:

  `with` 뒤의 첫 두 항목은 완전한 등식인데 마지막 항목은 동사 없이 `K_g the reduction indices`로 끝난다. 이 형태도 부가적 서술 구조로 해석할 수는 있지만, 열거 항목의 문법적 형태가 평행하지 않다. `denoting`을 넣고 단일 기호가 집합을 가리킨다는 뜻으로 `the set of`를 추가하면 정확해진다.

### 3.6 포트 매핑 문장의 대상이 불명확함

- PDF: 7쪽, Interleaved and Aligned Tensor Data Path
- Source: [`main.tex:891`](../main.tex#L891)
- 원문:

  > A 4-to-8 connection, for example, maps eight-port endpoint i to four-port endpoint i mod 4.

- 권장 수정:

  > A 4-to-8 connection, for example, maps port i of the eight-port endpoint to port i mod 4 of the four-port endpoint.

- 이유:

  원문에서는 `i`가 endpoint의 식별자인지 endpoint 내부 port의 식별자인지 불분명하다. 실제 수식은 port index의 매핑을 설명하므로 `port i of ...`를 명시해야 한다. 이 항목은 순수 문법보다는 기술적 수식 범위의 문제다.

### 3.7 SpinQuant가 `FP16 input`만 수식하는 것처럼 읽힘

- PDF: 9쪽, Workloads
- Source: [`main.tex:1348`](../main.tex#L1348)
- 원문:

  > Both models are quantized with INT4 weights, an INT4 KV cache, and FP16 input using SpinQuant W4A16KV4 quantization.

- 권장 수정:

  > We quantize both models using SpinQuant W4A16KV4, with INT4 weights, an INT4 KV cache, and FP16 activations.

- 이유:

  문장 끝의 `using SpinQuant ...`는 문법적으로 가장 가까운 `FP16 input`을 수식하는 것처럼 읽힐 수 있다. 실제 의도는 전체 모델 quantization 과정이 SpinQuant를 사용한다는 것이므로 `using SpinQuant`를 주동사 바로 뒤로 옮겨야 한다. 또한 여러 inference input/activation 값을 뜻하므로 `FP16 activations`가 더 자연스럽다.

### 3.8 `and/or`와 공유 관사로 인한 모호성

- PDF: 9쪽, Workloads
- Source: [`main.tex:1348`](../main.tex#L1348)
- 원문:

  > GEMMs execute on the FP TCU and/or FP-INT GEMM engine available in each candidate.

- 권장 수정:

  > Depending on the candidate, GEMMs execute on the FP TCU, the FP-INT GEMM engine, or both.

- 이유:

  `and/or`는 포함 관계는 표현하지만 어느 candidate가 어느 조합을 쓰는지 문장 구조상 흐리게 만든다. 또한 하나의 `the`가 두 하드웨어 명사구에 공유되어 두 번째 명사구의 경계가 약하다. 세 가능성을 직접 열거하면 더 명확하다.

### 3.9 본문에서 약어를 소문자로 사용

- PDF: 9쪽, End-to-End Latency and Data Layout Overhead
- Source: [`main.tex:1453`](../main.tex#L1453)
- 원문:

  > The breakdown separates these costs into gemm, vector, and layout.

- 권장 수정:

  > The breakdown separates these costs into GEMM, vector, and layout components.

- 이유:

  `GEMM`은 원고 전체에서 대문자로 사용하는 약어다. Figure legend의 내부 키를 그대로 지칭하는 의도라면 따옴표나 이탤릭을 사용할 수 있지만, 일반 본문에서는 대문자 표기를 유지하는 편이 일관된다. `components`를 추가하면 세 항목이 breakdown category라는 사실도 분명해진다.

### 3.10 짧은 도입 전치사구 뒤 쉼표

- PDF: 10쪽, Dynamic Power and Energy
- Source: [`main.tex:1524`](../main.tex#L1524)
- 원문:

  > In decode the geometric-mean energy reduction grows to 23.33×, ...

- 권장 수정:

  > In decode, the geometric-mean energy reduction grows to 23.33×, ...

- 이유:

  짧은 도입 전치사구 뒤 쉼표는 일부 스타일에서 생략할 수 있으므로 엄격한 문법 오류는 아니다. 다만 바로 뒤에 긴 주어가 이어지므로 쉼표를 넣으면 `In decode`의 범위와 주절 시작점이 명확해진다.

### 3.11 대명사 `its`의 선행사가 모호함

- PDF: 10쪽, Numerical and Neural Network Accuracy
- Source: [`main.tex:1629`](../main.tex#L1629)
- 원문:

  > Q-COL follows the same scale-application order as conventional GPU FP16 execution while retaining the established FIGNA-style computation, and is therefore expected to preserve, or potentially improve upon, its numerical accuracy.

- 권장 수정:

  > Q-COL follows the same scale-application order as the conventional GPU FP16 execution path while retaining the established FIGNA-style computation. It is therefore expected to preserve, or potentially improve upon, the numerical accuracy of the conventional GPU FP16 path.

- 이유:

  `its`는 문법적으로 `Q-COL`, `execution`, 또는 `computation` 중 어느 것을 가리키는지 확정하기 어렵다. 특히 Q-COL 자체의 accuracy인지 GPU path의 accuracy인지에 따라 의미가 달라진다. 비교 기준을 명사로 다시 명시해야 한다.

### 3.12 CPU 앞 관사

- PDF: 11쪽, Fig. 14 캡션
- Source: [`main.tex:1563`](../main.tex#L1563)
- 원문:

  > ... against an FP64 reference run on CPU.

- 권장 수정:

  > ... against an FP64 reference computed on a CPU.

  또는 특정 evaluation CPU를 뜻한다면:

  > ... against an FP64 reference computed on the CPU.

- 이유:

  `on CPU`는 표나 메모에서 사용하는 축약형으로는 흔하지만, 완전한 문장에서는 가산 명사 `CPU` 앞에 `a` 또는 `the`가 필요하다. `reference run`보다 `reference computed`가 결과값을 가리키는 표현으로도 더 직접적이다.

### 3.13 중첩된 도입구로 문장 구조가 무거움

- PDF: 11쪽, Numerical and Neural Network Accuracy
- Source: [`main.tex:1633`](../main.tex#L1633)
- 원문:

  > Regarding the quality at the neural network level, for both Llama2-7B and Llama3-8B, the GPU FP16 baseline and our FINISH system achieve similar average accuracies ...

- 권장 수정:

  > At the neural-network level, the GPU FP16 baseline and FINISH achieve similar average accuracies across the six zero-shot tasks for both Llama2-7B and Llama3-8B and yield almost identical WikiText-2 perplexities.

- 이유:

  원문은 `Regarding ...`와 `for both ...`라는 두 도입구가 연속되어 주어가 늦게 나온다. 문법적으로 가능하지만 처리 부담이 크다. 평가 수준을 나타내는 `At the neural-network level`만 앞으로 두고 모델 범위는 결과 뒤로 옮기면 주어와 동사가 빨리 연결된다. 두 모델 각각의 perplexity를 말하므로 복수형 `perplexities`도 더 정확하다.

### 3.14 복합 형용사의 하이픈

- PDF: 11쪽, Fig. 15 캡션
- Source: [`main.tex:1719`](../main.tex#L1719)
- 원문:

  > Breakdown of the GEMM engine area/power and full system area.

- 권장 수정:

  > Breakdown of the GEMM-engine area and power and the full-system area.

- 이유:

  `full system`이 뒤의 `area`를 공동으로 수식하므로 `full-system area`로 묶는 것이 자연스럽다. `area/power`의 슬래시도 두 측정값의 관계가 모호하므로 `area and power`로 풀어 쓰는 편이 좋다. `GEMM-engine`은 복합 형용사임을 분명히 하지만, 원고 전반의 `GEMM engine` 표기를 유지하려면 하이픈 없이 두어도 된다.

## 4. 전역 표기 일관성 권장사항

다음은 개별 문법 오류라기보다 원고 전체에서 통일하면 좋은 표기다.

| 현재 혼용 | 권장 기준 | 설명 |
|---|---|---|
| `64B`, `8B`, `512B/cycle` / `64 B`, `8 B` | `64 B`, `8 B`, `512 B/cycle` | 숫자와 단위 사이 공백을 통일한다. |
| `system level` / `system-level` | 명사 앞에서는 `system-level` | 예: `system-level latency`; 단, `at the system level`에는 하이픈을 쓰지 않는다. |
| `full system area` / `full-system area` | `full-system area` | 명사 앞 복합 형용사 표기를 통일한다. |
| `memory-mapped IO` | `memory-mapped I/O` | 정식 영어 약어는 일반적으로 `I/O`다. `MMIO` 정의는 그대로 유지한다. |
| `gemm` / `GEMM` | `GEMM` | 고유 약어의 대소문자를 통일한다. |
| `FP--INT` / `FP-INT` / `FP×INT` | 의미에 따라 `FP-INT` 또는 `FP×INT` | 데이터형 조합/시스템 명칭과 실제 곱셈 기호를 구분해 일관되게 사용한다. |
| `Fig.` / `Figure` | 한 가지 기준 | IEEE 문체에 맞춰 본문에서는 보통 `Fig.`를 일관되게 사용한다. |

## 5. 우선순위 요약

제출 전 최소한 다음 항목은 수정하는 것을 권한다.

1. `a FP16×FP16` → `an FP16×FP16`
2. `Fig.11` → `Fig. 11`
3. `direction(QDir)` → `direction (QDir)`
4. Fig. 12 캡션의 괄호 앞 공백과 `system-level` 표기
5. `Quantization group size` 앞 한정사 추가
6. G-DMA 문장의 잘못 연결된 `compared with` 구조
7. 결론의 `on geometric mean` 표현 교체
8. Fig. 6 내부의 `Memory(HBM)`, `RMSnorm`, `Back - pressure` 수정

나머지 항목은 문법적으로 완전히 틀렸다고 단정하기보다는 reviewer가 의미를 빠르게 이해하도록 만드는 명료성 개선이다.
