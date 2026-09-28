# Manuscript Review Notes, 2026-07-14

대상 파일: `main.tex`

검토 범위: Abstract, Introduction, Background and Motivation, Design Overview, Native FP×INT Attention, Memory System, Layout and Runtime

제외 범위: Evaluation과 Evaluation 결과에 의존하는 Conclusion

목적: 현재 원고를 reviewer의 관점에서 검토하고, 주요 질문과 비평을 항목별로 정리한다. 각 항목의 수정 여부와 대응 방향은 이후 하나씩 결정한다.

## 총평

현재 논문의 핵심 아이디어는 분명하다. 기존 FP×INT 엔진을 attention에 적용할 때 발생하는 quantization 방향 문제를 QCOL과 QROW 데이터패스로 해결하고, 전용 tensor memory와 direct data path를 통해 연산기의 효율을 시스템 성능으로 연결한다는 흐름이다.

다만 Evaluation을 제외한 현재 원고만을 기준으로 하면 잠정적인 평가는 **Weak Reject 또는 Major Revision**에 가깝다. 아이디어가 약해서라기보다 다음 세 가지 핵심 정보가 충분히 설명되지 않았기 때문이다.

1. Kernel-by-kernel execution과 HBM intermediate materialization을 논문의 scope와 evaluation에서 어떻게 설명하는가
2. QROW가 요구하는 추가 연산과 데이터 공급 비용은 무엇인가
3. Direct path와 cache가 함께 사용될 때 correctness를 어떻게 보장하는가

## 주요 질문 및 비평

### R1. Kernel-by-kernel attention execution과 HBM intermediate

- 우선순위: Major
- 상태: `main.tex` 반영 완료
- 확인된 구현: 실험은 가장 단순한 kernel-by-kernel execution을 사용한다. QK GEMM kernel이 완료되면 결과를 HBM에 저장한다. 이후 별도의 softmax kernel이 HBM에서 이 결과를 읽어 처리한다. Softmax를 포함한 일반적인 vector kernel은 Vortex SIMD에서 실행한다. Softmax kernel 내부에서는 online softmax를 사용하지만 FlashAttention처럼 QK, softmax, PV를 하나의 tiled kernel로 결합하지 않는다.

이 구현 방식에서는 QK 결과가 HBM에 materialize된다. Kernel-by-kernel execution을 일관되게 적용한다면 softmax 결과도 HBM에 저장되고 이후 PV kernel이 이를 다시 읽는다. 따라서 online softmax는 softmax kernel 내부의 numerical algorithm을 의미하며, attention intermediate를 on-chip에서 유지하거나 QK와 PV를 fuse한다는 의미가 아니다.

FlashAttention을 사용하지 않는 것 자체는 문제가 아니다. 다만 현재 원고만 읽으면 online softmax와 FP×INT engine이 tiled dataflow로 결합되는 것으로 오해할 수 있다. 또한 long context attention에서 \(N^2\) intermediate를 HBM에 materialize하는 비용이 크기 때문에 이 실행 모델은 명시적인 scope와 limitation으로 설명해야 한다.

Reviewer 질문:

> Does the evaluated attention implementation materialize the QK output and softmax output in HBM between kernels? If so, how much of the end-to-end execution time and memory traffic is caused by these intermediate transfers?

권장 대응은 다음과 같다.

- Design 또는 runtime section에 `QK GEMM → HBM → SIMD online softmax → HBM → PV GEMM` 실행 순서를 명시한다.
- Online softmax는 별도의 SIMD kernel 내부에서 사용하며 QK와 PV kernel 사이의 fusion은 적용하지 않았다고 밝힌다.
- 현재 구현이 FP×INT engine과 memory system의 효과를 평가하기 위한 단순하고 보수적인 kernel execution model임을 설명한다.
- QK output과 softmax output의 HBM read 및 write traffic이 end-to-end evaluation에 포함된다는 점을 명시한다.
- 본문에서 \(N^2\) attention intermediate를 제거하거나 attention 전체를 on-chip에서 처리한다고 주장하지 않는다.
- Kernel fusion 또는 FlashAttention 계열의 tiled attention dataflow는 제안 기법과 직교하는 향후 최적화로 구분한다.
- 가능하다면 Evaluation에서 GEMM, softmax, intermediate HBM traffic의 시간 비중을 breakdown으로 보여준다.

이 대응을 사용하면 reviewer가 구현을 과도하게 해석하는 것을 막을 수 있다. 반면 논문이 long context attention의 memory traffic 자체를 해결한다고 주장한다면 현재 kernel-by-kernel dataflow와 충돌할 수 있으므로, claim을 FP×INT GEMM acceleration과 system integration 범위로 제한하는 것이 안전하다.

저자 대응: Evaluation의 Software Implementation 문단에 sequential kernel execution을 명시했다. QK 결과와 softmax 결과가 HBM을 경유하며, online softmax는 별도의 Vortex SIMD kernel에서 실행된다고 설명했다. QK, softmax, PV를 하나의 tiled attention kernel로 fuse하지 않는다는 점과 intermediate HBM transfer의 latency와 energy가 보고된 결과에 포함된다는 점도 명시했다.

### R2. QROW의 activation scaling 비용과 확장성

- 우선순위: Critical
- 상태: 반영 완료.
- 관련 위치: `main.tex:351`
- 확인된 설계: 32$\times$32 MXU는 output dimension에서 32, 64, 128의 quantization group size를 지원한다. GEMM dimension이 quantization group 경계와 맞지 않으면 kernel이 다음 경계까지 padding한다. 따라서 하나의 32 column MXU tile 안에서는 $h(n)$이 항상 상수이고 모든 column이 같은 scale vector를 사용한다. Input scaler는 prealigner 앞에서 activation을 scaling하고 그 결과를 32개 MXU column이 공유한다. 이에 따라 input scaler는 PE마다 복제된 1024개 multiplier가 아니라 32개의 FP multiplier로 구성되며 activation replay도 필요하지 않다.

QROW 수식에서

\[
\bar{A}^{(h)}[m,k] = A[m,k]S_{\mathrm{ROW}}[k,h]
\]

이므로 같은 activation \(A[m,k]\)도 output group \(h\)마다 서로 다른 값으로 scaling되어야 한다.

Reviewer 질문:

> How does the QROW datapath generate differently scaled versions of the same activation for multiple output groups without replaying the activation or replicating the input scaler?

본문에서 명확히 해야 할 내용은 다음과 같다.

- Input scaler의 개수
- 한 cycle에 처리할 수 있는 output group \(h\)의 수
- Activation을 output group마다 replay하는지 여부
- Scale metadata가 요구하는 bandwidth
- \(G_N\)이 throughput에 미치는 영향
- Per-channel quantization처럼 \(h\)의 수가 많을 때 peak throughput을 유지하는 방법

Architecture figure는 input scaler가 prealigner 앞에 있다는 점을 보여준다. 추가된 본문은 지원 group size와 padding 조건으로 인해 tile 안에서 $h(n)$이 상수라는 점을 설명하고, 32개 FP multiplier의 결과를 모든 MXU column이 재사용한다는 mapping을 명시한다. 남은 작업은 area와 power overhead를 읽기 쉬운 module level breakdown으로 제시하는 것이다.

저자 대응: Design section에 지원 group size가 32, 64, 128이고 경계가 맞지 않는 GEMM에는 padding을 적용한다고 설명했다. 이 조건에서 $h(n)$은 하나의 MXU tile 안에서 상수이므로 scale folded activation을 32개 column이 공유할 수 있다. 또한 32$\times$32 MXU가 1024개의 per PE multiplier 대신 32개의 input multiplier를 사용하며 activation replay가 필요하지 않다고 명시했다. Evaluation의 결과 문장은 현재 유지한다. 먼저 module level breakdown figure의 legend를 의미 있는 상위 component 중심으로 다시 구성한 뒤 area와 power 결과를 수정한다.

### R3. 기존 per-term FP multiplication과 QROW input scaling의 차이

- 우선순위: Critical
- 상태: Design 반영 완료
- 관련 위치: `main.tex:333`
- 확인된 설계: QROW도 reduction term마다 quantization scale을 곱하므로 per-term dequantization 자체를 제거하지는 않는다. 핵심은 이 multiplication을 prealigner 앞의 input scaler로 이동시킨다는 점이다. Scale이 FP activation에 먼저 fold된 뒤 prealignment를 거치므로, prealigner 이후의 내부 integer datapath에서는 reduction axis의 모든 term이 동일한 effective scale을 갖는다. 이는 내부적으로 quantization scale이 모두 1인 것과 동등한 효과를 만든다. 따라서 main MXU와 correction path는 integer reduction을 유지할 수 있고 output scaler는 bypass된다.

논문은 기존 엔진에서 reduction 도중 metadata가 변하면 각 term에 FP multiplication과 FP reduction이 필요하다고 설명한다. QROW도 \(A \times S\) 형태의 per-term FP multiplication을 수행하므로, contribution을 per-term dequantization의 제거라고 표현하면 부정확하다. 차이는 scale multiplication의 위치와 이후 reduction의 representation에 있다.

Reviewer 질문:

> QROW still performs a per-term scale multiplication. Is the key contribution the relocation of this multiplication before prealignment, rather than its elimination, and how does this relocation avoid a floating-point reduction?

본문에서는 다음 두 실행 순서를 직접 대비하는 것이 좋다.

- 기존 방식은 각 INT term을 scale로 dequantize한 뒤 FP product를 만들고 FP reduction을 수행한다.
- QROW는 FP activation에 term별 scale을 먼저 fold하고, 그 결과를 prealigner가 공통 integer representation으로 변환한 뒤 INT RHS와 곱하고 integer reduction을 수행한다.
- Prealigner 이후에는 scale metadata가 reduction axis를 따라 변하지 않는다. 이를 effective scale이 모두 1이 된 것으로 설명할 수 있다.
- Output에 적용할 별도의 scale이 남지 않으므로 output scaler를 bypass한다.
- Input scaler는 MXU의 모든 PE에 복제되지 않고 column dimension 단위로 배치되어 재사용된다.

다만 “scale이 1이 된다”는 표현은 실제 metadata를 1로 바꾼다는 의미가 아니라, scale이 activation에 이미 흡수되어 prealigner 이후 datapath가 추가 scale을 볼 필요가 없다는 논리적 의미임을 밝혀야 한다. Input scaler의 precision과 prealignment 과정에서의 rounding도 R4의 numerical specification과 함께 설명하는 것이 좋다.

저자 대응: Design section에서 per-term scale multiplication을 제거한다는 표현을 삭제하고, 이 multiplication을 RHS dequantization에서 prealigner 앞의 FP input으로 이동시킨다고 명시했다. Scale이 activation에 흡수된 뒤에는 downstream datapath가 reduction axis를 따라 scale metadata를 소비하지 않으며, 이는 prealignment 이후 effective scale이 모두 1인 것과 같다고 설명했다. 실제 metadata를 1로 변경하는 것이 아니라 추가 scale operation이 남지 않는다는 논리적 의미도 명확히 했다. 이에 따라 main product와 zero-point correction은 integer reduction을 유지하고 output scaler는 bypass된다. 또한 $\bar{A}$가 prealignment를 거쳐 $\hat{\bar{A}}$가 되는 notation을 correction path와 직접 연결했다. R2의 module-level breakdown은 input-side multiplier를 column 단위로 공유할 때의 area와 power overhead를 제시한다.

### R4. Datapath의 수치 표현과 정확도 보장

- 우선순위: Critical
- 상태: Design 반영 완료
- 관련 위치: `main.tex:336`, `main.tex:390`

Prealigner 설명에서는 exponent alignment와 fixed point shift를 단순화를 위해 생략한다. 그러나 이 부분은 실제 구현의 numerical correctness를 결정한다.

다음 정보를 제공할 필요가 있다.

- Activation과 scale의 FP format
- Integer weight와 zero point의 bit width
- \(\hat{A}\), multiplier output, reduction tree, accumulator의 bit width
- Rounding mode와 saturation 여부
- Exponent alignment 방식
- Overflow가 발생하지 않는 조건
- 수식에서 사용하는 \(\mathcal{T}\) 연산의 정의
- 기존 dequantize then FP×FP 결과와의 numerical equivalence 범위

Reviewer는 최소한 bit width table과 각 datapath에서 rounding이 발생하는 위치를 요구할 가능성이 높다.

저자 대응: QCOL과 QROW가 공통으로 사용하는 prealigner가 FIGNA의 numerical accuracy preserving prealignment scheme을 따른다고 Design section에 명시했다. 각 FP16 input은 integer multiplication과 reduction 전에 31 bit signed aligned mantissa로 표현되며, 이후의 integer accumulation과 FP conversion도 FIGNA를 따른다고 설명했다. QCOL은 activation을 직접 prealign하고 QROW는 scale folded activation을 같은 prealigner에 입력한다. 이에 따라 이 numerical format은 QROW만의 변경이 아니라 두 mode가 공유하는 FIGNA datapath의 속성으로 설명된다.

### R5. Cache와 direct path 사이의 memory consistency

- 우선순위: Critical
- 상태: Design 반영 완료
- 관련 위치: `main.tex:501`

초기 설명은 cache path와 direct path 사이에서 explicit fence와 synchronization을 사용하는 것으로 읽혔다. 그러나 일반적으로 fence는 operation ordering을 보장할 뿐 dirty cache line의 writeback이나 stale cache line의 invalidation까지 자동으로 보장하지는 않는다.

Reviewer 질문:

> Are tensor buffers mapped as uncached memory, or does the runtime explicitly flush and invalidate cache lines before ownership transfers between the scalar cores and the direct path?

실제 사용하는 정책을 다음 중 하나 이상의 형태로 명시해야 한다.

- TMEM buffer를 uncached memory로 mapping
- Cache가 write through로 동작
- Runtime이 cache flush와 invalidation을 수행
- Cache path와 direct path 사이에서 buffer ownership을 이전
- Hardware coherence mechanism을 제공

현재 설명만으로는 functional correctness를 판단하기 어렵다.

저자 대응: GEMM과 vector stage를 fuse하는 실제 실행 순서에 맞춰 설명을 수정했다. GEMM 앞에 fuse된 vector stage는 GEMM input 생성을 모두 마친 뒤 Vortex fence를 실행한다. 이 fence는 pending store를 drain하고 cached data를 HBM으로 flush한 뒤 GEMM이 input을 읽도록 보장한다. GEMM 뒤에 fuse된 vector stage는 추가 fence를 사용하지 않는다. GEMM node의 result writeback DMA가 accumulator tile을 cache bypass path를 통해 HBM에 기록하고, 해당 HBM write가 끝난 뒤에만 read only MMIO completion register를 갱신한다. 후속 SIMT code는 자신의 target tile이 완료될 때까지 이 register를 polling한 뒤 연산을 시작한다. Result writeback DMA는 cache line을 allocate하지 않으므로 이후 SIMT load는 완료된 tile을 HBM에서 읽는다. 또한 Vortex는 모든 kernel launch의 시작에 cache를 invalidate하고 모든 kernel의 끝에 fence를 강제로 실행한다. 마지막 fence는 control이 runtime으로 돌아가기 전에 cached write를 flush한다. 본문에서는 애매한 Output DMA 대신 GEMM result writeback DMA라는 용어를 사용했다.

### R6. HBM과 TMEM의 congruence 조건

- 우선순위: Major
- 상태: Design 반영 완료
- 관련 위치: `main.tex:431`, `main.tex:439`

초기 주소 조건은 `min(NUM_pc, NUM_tmem)`을 사용했다. 이 조건이 일반적인 channel count와 bank count 조합에서도 one-to-one mapping을 보장하는지는 명확하지 않았다.

Reviewer 질문:

> Under what assumptions does the proposed congruence condition guarantee a one-to-one channel-to-bank mapping?

현재 식이 성립하기 위해 필요한 다음 전제를 설명할 필요가 있다.

- 두 bank count가 power of two인지
- 작은 bank count가 큰 bank count를 나누는지
- HBM과 TMEM이 동일한 low order interleaving을 사용하는지
- Address hashing이나 XOR mapping이 없는지
- 두 주소가 동일한 offset 기준으로 표현되는지

식을 일반화하거나, 해당 식이 보장되는 architecture constraint를 명시하는 것이 좋다.

저자 대응: 주소 조건을 일반적인 channel count와 bank count에 적용할 수 있도록 `min` 대신 `gcd`를 사용했다. 실제 design space에서는 HBM channel count, TMEM bank count, data width를 power of two로 제한하고, 작은 bank count가 큰 bank count를 나누도록 구성한다. 따라서 지원하는 모든 configuration에서 `gcd = min`이 성립한다. 또한 HBM과 TMEM은 동일한 low order address interleaving과 byte offset convention을 사용하며, allocation base를 congruence modulus에 맞춰 정렬한다. XOR mapping이나 address hashing은 사용하지 않는다. Bank count가 같은 경우에는 1:1 mapping이고, 다른 경우에는 destination $i$를 source $i \bmod \min(\mathrm{NUM}_{pc}, \mathrm{NUM}_{tmem})$에 연결하는 deterministic interleaved mapping임을 본문에 명시했다.

### R7. 네 가지 execution pattern의 명시적인 mapping

- 우선순위: Major
- 상태: 수정하지 않음
- 관련 위치: `main.tex:317`

논문은 linear, QK, PV에서 나타나는 네 가지 execution pattern을 모두 지원한다고 주장한다. 그러나 operation별 mapping이 한눈에 정리되어 있지 않다.

다음 정보를 포함하는 표를 추가하면 claim을 검증하기 쉬워진다.

| Operation | Quantized operand | Quantization direction | MXU load direction | Datapath | Correction |
| --- | --- | --- | --- | --- | --- |
| Linear | Weight | Token-wise or channel-wise | To be specified | QCOL or QROW | To be specified |
| QK | K | Token-wise | To be specified | To be specified | To be specified |
| QK | K | Channel-wise | To be specified | To be specified | To be specified |
| PV | V | Token-wise | To be specified | To be specified | To be specified |

저자 대응: 현재 원고에서는 추가 수정하지 않는다.

### R8. Hardware가 지원하는 quantization 범위

- 우선순위: Major
- 상태: 수정하지 않음

현재 원고는 여러 quantization framework의 예를 제시하지만 실제 hardware support boundary는 명확하지 않다.

Reviewer가 질문할 수 있는 내용은 다음과 같다.

- INT2, INT3, INT4, INT8 중 지원하는 format
- Symmetric과 asymmetric quantization의 지원 여부
- Arbitrary group size의 지원 여부
- Group size가 MXU tile과 정렬되지 않을 때의 처리 방식
- Token-wise와 channel-wise metadata의 physical layout
- FP16, BF16, FP8 중 지원하는 activation format
- MQA, GQA, MLA를 동일한 datapath에서 실행할 수 있는지 여부

지원 범위를 표로 정리하면 논문의 generality와 한계가 명확해진다.

저자 대응: 현재 원고에서는 추가 수정하지 않는다.

### R9. Roofline motivation의 가정과 계산 과정

- 우선순위: Major
- 상태: 수정하지 않음
- 관련 위치: `main.tex:183`, `main.tex:206`

Motivation에서는 batch scaling, GQA, MLA, quantization이 generation을 compute bound 방향으로 이동시킨다고 주장한다. 그러나 GQA와 MQA는 KV data와 관련 연산량을 모두 줄인다. 따라서 arithmetic intensity가 증가하는 조건을 명시할 필요가 있다. MLA도 일반적인 QK와 PV 연산과 정확히 같은 데이터플로를 사용하지 않을 수 있다.

Roofline figure를 재현할 수 있도록 다음 정보를 공개하는 것이 좋다.

- Model과 layer dimensions
- Context length와 batch size
- Query head와 KV head의 수
- KV bit width
- FLOP과 memory traffic에 포함한 tensor
- Scale과 zero point traffic의 포함 여부
- Cache reuse에 대한 가정
- MLA 연산을 FLOP과 byte로 계산한 방법

저자 대응: 현재 원고에서는 추가 수정하지 않는다.

### R10. Multi-core 환경에서의 system level 확장성

- 우선순위: Major
- 상태: 보류
- 관련 위치: `main.tex:297`

Overview figure는 socket, cluster, core 구조를 보여주지만 설계 설명은 주로 하나의 FP×INT engine과 하나의 core 관점이다.

다음 내용을 설명할 필요가 있다.

- 여러 core가 하나의 engine을 공유하는지 여부
- 여러 outstanding descriptor를 지원하는지 여부
- Warp와 core 사이의 arbitration 방식
- Context switch와 preemption 지원 여부
- TMEM partitioning 방식
- Multi-core 실행 시 HBM pseudo channel 충돌 처리
- Descriptor가 virtual address와 physical address 중 무엇을 사용하는지

실제 구현과 평가가 single core 범위라면 system figure와 claim도 그 범위에 맞게 제한할 수 있다.

저자 대응: 현재 단계에서는 추가 수정하지 않는다.

### R11. Software stack claim과 본문 설명의 차이

- 우선순위: Major
- 상태: 대응 완료
- 관련 위치: `main.tex:329`, `main.tex:458`

Overview에서는 compiler, runtime, kernel을 포함한 full stack을 주장하고 figure에는 PyTorch frontend와 backend가 등장한다. 그러나 pre-Evaluation 본문은 runtime과 allocator를 짧게 설명하는 수준이다.

다음 내용을 구분해 설명해야 한다.

- PyTorch graph에서 capture하는 operation
- QCOL과 QROW를 선택하는 주체와 기준
- Mapping이 static rule인지 cost model인지
- Unsupported shape의 fallback 경로
- Quantization metadata layout을 변환하는 주체
- Kernel fusion이 compiler transformation인지 hand-written kernel인지

현재 상태에서는 compiler가 구현된 시스템 구성요소인지 단순한 mapping rule인지 판단하기 어렵다.

저자 대응: 새로운 compiler stack을 구현했다는 인상을 주는 표현을 제거했다. 본 구현은 기존 Vortex runtime과 kernel programming infrastructure를 활용하며, 제안한 \fpint{} compute and memory architecture를 FPGA prototype과 complete workload execution이 가능한 accelerator system으로 구현한다. Native C++ kernel은 SIMT pipeline에서 실행되며 MMIO descriptor를 통해 GEMM node를 설정하고 시작한다. Load direction, quantization direction, descriptor setup, and layout handling are explicitly encoded in the kernels and runtime code. TVM과 같은 tensor compiler와 automatic graph lowering은 사용하지 않는다. Contribution은 software stack 자체가 아니라 E2E \fpint{} accelerator implementation과 system evaluation으로 정리했다.

### R12. 기존 연구와의 novelty boundary

- 우선순위: Major
- 상태: 대응 완료
- 관련 위치: `main.tex:217`, `main.tex:320`

Virgo를 인용하여 decoupled engine 자체가 최초가 아니라는 점을 인정한 것은 적절하다. 다만 별도의 Related Work section이 없어 다음 차이가 여러 section에 흩어져 있다.

- FIGNA, FIGLUT, LUT-TC와 비교한 quantization 방향 지원
- AxCore와 비교한 attention 적용 가능성
- Virgo와 비교한 decoupling granularity
- 기존 accelerator scratchpad 또는 direct DMA와 비교한 memory system novelty

현재 contribution은 모든 구성요소를 새로 발명했다는 주장보다는 기존 아이디어를 FP×INT attention에 맞게 통합하고, arithmetic dataflow와 memory mapping constraint를 함께 설계했다는 데 가까워 보인다. 이 novelty boundary를 명시하면 system paper로서의 contribution이 더 설득력 있게 보일 수 있다.

저자 대응: 별도의 Related Work section을 추가하지 않고 각 비교를 가장 관련된 위치에서 설명한다. Background and Motivation의 Gap 1에서 prior \fpint{} designs가 주로 linear layer의 weight GEMM을 대상으로 한다는 점과 attention을 고려한 AxCore가 token-wise KV quantization을 native하게 지원하지 않는다는 점을 함께 설명한다. Introduction에서는 AxCore의 세부 설명을 제거했다. Decoupled engine은 해당 구조를 처음 설명하는 Design Overview에서 Virgo를 인용하고 shared memory 기반 operand supply와 본 설계의 dedicated tensor path를 비교한다. Memory section은 scratchpad나 DMA 자체보다 dense \fpint{} engine을 위한 banking, interconnect mapping, and software managed layout의 결합에 초점을 둔다.

## 표현과 편집에 관한 질문

### R13. 미해결 TODO

- 우선순위: Minor
- 상태: 검토 필요
- 관련 위치: `main.tex:126`

현재 보이는 TODO는 제출 전 제거해야 한다. 해당 TODO의 내용은 이전 결정에 따라 수정하지 않더라도 최종 PDF와 source에는 남지 않도록 처리해야 한다.

저자 대응:

### R14. 용어와 quantization axis 정의

- 우선순위: Minor
- 상태: 대응 완료

다음 용어의 일관성을 확인할 필요가 있다.

- FP-INT, FP×INT, mpGEMM
- Quantization direction과 quantization granularity
- Transpose 전후 token-wise와 channel-wise가 가리키는 tensor axis
- WKV의 최초 정의

특히 token-wise와 channel-wise는 tensor shape와 axis를 함께 정의해야 QK에서 K가 transpose된 뒤 metadata가 reduction 방향으로 변한다는 설명을 정확히 따라갈 수 있다.

저자 대응: Target arithmetic 표기는 FP-INT로 통일하고 mpGEMM 또는 FP$\times$INT 표기를 제거했다. Quantization direction은 scale과 zero point metadata가 배치되는 방향을 뜻하며, quantization group size는 metadata를 공유하는 element 수를 뜻하도록 구분했다. Token-wise와 channel-wise는 Background의 Gap 1에서 처음 사용하기 전에 transpose 이전의 원본 K와 V tensor를 기준으로 정의한다. RHS, MXU, Q-COL, and Q-ROW are defined immediately before their first use in the Gap 1 hardware comparison. Quantized operand가 MXU의 right hand side에 mapping된 이후에는 metadata가 column 또는 row와 결합되는 방향을 각각 Q-COL과 Q-ROW로 지칭한다. Introduction에서는 이러한 hardware 내부 용어를 사용하지 않는다. WKV는 abstract와 Introduction에서 weight and KV cache quantization으로 정의했다.

### R15. Citation 또는 적용 조건이 필요한 일반적 주장

- 우선순위: Minor
- 상태: 대응 완료

다음 주장은 구체적인 조건이나 citation이 필요하다.

- W+KV quantization이 increasingly deployed라는 주장
- 32K 또는 128K context에서 KV cache가 weight와 comparable하다는 주장
- Mixed precision GEMM이 dominant recurring operation이라는 주장

KV cache와 weight 크기의 비교에는 model size, batch size, context length, KV head 수, bit width를 함께 제시하는 것이 좋다.

저자 대응: Weight와 KV cache를 함께 quantize하는 최근 방법의 예로 WKVQuant와 SpinQuant를 인용했다. 기존의 32K 또는 128K context에서 KV cache capacity와 bandwidth가 model weights와 comparable하다는 문장은 제거했다. 현재 figure는 memory footprint 비교가 아니라 long context에서 attention GEMM의 계산 비중이 증가하는 것을 보여주므로, 해당 graph가 직접 뒷받침하는 prefill compute 관점의 주장으로 수정했다. Mixed precision GEMM이 dominant하다는 일반적 표현 대신 linear layer, $QK^T$, and PV의 operand를 각각 열거하고 WKV quantization 이후 모든 core GEMM이 one FP operand and one INT operand를 갖는다고 설명했다. 이 설명에는 FIGNA, WKVQuant, and SpinQuant를 인용했다.

### R16. Abstract의 정량적 결과

- 우선순위: Evaluation 완료 후 검토
- 상태: 보류

현재 Abstract에는 headline result가 없다. 새로운 실험 결과가 확정된 뒤 system speedup, energy efficiency, area overhead 중 핵심 결과를 추가하는 것이 좋다. 이 항목의 수치와 claim은 이번 review 범위에서는 판단하지 않는다.

저자 대응:

## 잘된 점

- Array 수준의 효율과 system 수준의 효율을 분리해 보는 문제 설정이 명확하다.
- FP×INT attention의 arithmetic limitation이 prefill과 generation 모두에 존재한다는 설명이 이전보다 명확하다.
- QCOL과 QROW의 수학적 구분이 핵심 아이디어를 이해하는 데 효과적이다.
- Virgo를 인용하여 decoupled engine에 대한 overclaim을 피한 점이 적절하다.
- Direct path가 layout constraint를 만든다는 tradeoff를 숨기지 않고 software와 함께 해결하려는 구조가 system paper에 잘 맞는다.

## 권장 검토 순서

1. R1: Kernel-by-kernel attention dataflow와 HBM intermediate
2. R2와 R3: QROW의 구현 비용과 기존 방식과의 차이
3. R4: Numerical specification
4. R5: Cache와 direct path의 correctness
5. R6: Address mapping condition
6. R7과 R8: Operation mapping과 hardware support boundary
7. R9: Roofline methodology
8. R10과 R11: System scalability와 software stack
9. R12: Novelty boundary
10. R13부터 R16까지: 표현, citation, abstract 정리
