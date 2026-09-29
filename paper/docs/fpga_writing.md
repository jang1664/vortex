# ACM/SIGDA FPGA 학회 게재 LLM·Transformer 및 관련 연산 가속기: 작성·실험 체크리스트

조사 기준일: **2026-09-29**. 대상은 **2022–2026년 ACM/SIGDA International Symposium on Field-Programmable Gate Arrays (FPGA / ISFPGA) 학회 proceedings에 게재된 논문**이다. LLM 가속기와 함께 2022·2023년의 Transformer 부분 연산 및 관련 행렬 연산 가속기를 구분해 포함했다. 해당 학회 논문의 전수조사나 성능 순위표는 아니다. **어떤 주장을 어떤 실험·표·그림으로 뒷받침해야 하는지**를 정리하는 것이 목적이다.

FPGA 학회 게재가 확인된 **7편**을 정리했다. 생성형 LLM 관련 4편 중 FlightLLM과 TeLLMe는 상세 본문을 확인했고, FMC-LLM은 1쪽 논문, Hummingbird+는 게재 정보만 확인한 상태다. 추가한 2022년 HiSparse·Sextans와 2023년 Approximate Hybrid Binary-Unary Computing은 모두 공개 본문을 확인했다. **게재 자격은 학회·출판 기록으로 확인하고, 본문 분석에는 해당 논문의 저자 공개본도 사용한다.** 표·그림 번호와 수치는 링크한 공개본 버전 기준이며 최종 출판본과 다를 수 있다.

다른 학회·저널에 게재된 논문과 FPGA 학회 게재를 확인하지 못한 preprint는 목록과 사례 근거에서 제외했다. 특히 **FCCM과 ACM/SIGDA FPGA는 서로 다른 학회**다. 상세 체크리스트는 아래 사례를 참고한 작성 권고이며, 이 표본만으로 학회 전체의 보고 관행이나 빈도를 일반화하지 않는다.

이 문서의 **필수**는 주장의 타당성을 판단하는 데 필요한 작성 권고다. 모든 학회의 공식 제출 요건이나 모든 선행 논문이 충족한 공통 항목을 뜻하지 않는다. 공식 형식 요건은 마지막 절에 별도로 정리했다.

## 1. 먼저 준비할 최소 평가 묶음

FPGA 구현을 주된 기여로 주장한다면 다음을 우선 준비한다. LUT/FF utilization은 이 중 한 부분이다.

| 우선순위 | 포함할 내용 | 독자가 판단할 수 있어야 하는 것 |
|---|---|---|
| 필수 | 보드·정확한 FPGA part·FPGA 수·메모리·도구 버전·실제 동작 주파수 | 어느 플랫폼에서 재현 가능한가? |
| 필수 | LUT, FF, DSP, BRAM, URAM의 사용량과 비율; 구현 단계와 집계 범위 | 실제 장치에 들어가며 어떤 자원이 한계인가? |
| 필수 | 모델/checkpoint, 정밀도, batch, 입력·출력 길이, 가속 범위 | 어떤 문제를 얼마나 처리했는가? |
| 필수 | 대상 단계의 절대 latency/throughput와 공정한 baseline | 성능 향상이 어느 조건에서 성립하는가? |
| 필수 | 실측·RTL 시뮬레이션·성능 모델·문헌 인용의 구분 | 수치의 근거와 신뢰 범위는 무엇인가? |
| 필수 | 기여별 ablation과 병목 분석 | 제안 기법 때문에 좋아졌는가? |
| 조건부 필수 | 전력 및 energy/token 또는 tokens/J | 에너지 효율을 주장한다면 실제 비용은 얼마인가? |
| 조건부 필수 | PPL/task accuracy와 기준 모델 대비 변화 | 양자화·근사·pruning 등으로 모델 품질이 바뀌었는가? |
| 강력 권장 | 모듈별 자원 breakdown, floorplan, timing/routing 설명 | FPGA에 맞춘 설계 선택이 왜 필요한가? |
| 강력 권장 | context/batch/model sweep, 실패·열세 조건, 재현 자료 | 결과가 단일 유리한 설정에만 의존하지 않는가? |

### 1.1 누락·불명확 항목 점검 결과

기존 목록에는 실행 주파수·setup/hold·측정 반복·전력 경계가 있었지만, 아래 항목은 빠져 있거나 구체성이 부족했다. 다음 절과 작성용 표에 보완했다. 우선순위는 이 문서의 작성 권고이며, 조사한 모든 논문이 이를 보고했다는 뜻은 아니다.

| 보완 항목 | 보고 수준 | 위치 |
|---|---|---|
| Fmax와 target/실행 clock의 구분, 최대값을 확인한 방법 | 실행 clock·달성 조건은 기본; 최대 주파수/주파수 개선 주장에는 Fmax 근거 필요 | §4.3.1, 표 B2 |
| speed grade, timing corner, clock uncertainty, 다중 clock·CDC·미제약 경로 | 본문에는 part·주요 clock·closure 여부; 세부 제약과 검증 report는 부록/artifact | §4.3.1 |
| pipeline latency, 실제 II, stall, cycles와 MHz의 분리 | 연산기·dataflow·scheduling 기여라면 보고 | §4.5 |
| AXI outstanding 요청, 접근 패턴, port–PC mapping·remap 비용 | HBM 대역폭·주소 mapping 기여라면 보고 | §4.7 |
| 최대 모델/context/batch의 메모리 용량 근거 | capacity·scalability 주장이라면 보고 | §4.7 |
| 실행 중 clock 변화·열 상태, 전력 추정의 신호 activity 범위 | 동적 clock 또는 지속 성능·전력 추정 주장에 맞춰 보고 | §4.6 |
| P&R 전략·seed·제약 파일·build 시간 | 재현 설정은 artifact; build 시간 개선을 주장하면 본문 실험 | §6 |

## 2. FPGA 학회 게재 논문 목록

P는 prefill, D는 autoregressive decode를 의미한다. 두 단계를 지원한다는 사실과 전체 애플리케이션을 FPGA에서 실행한다는 사실은 별개다. CPU 분담, 측정 구간, 모델링 범위는 이어지는 근거 표에서 확인한다.

**2022–2026년 게재 논문 7편을 연도순으로 정리했다.** ID의 P1–P4는 생성형 LLM 관련 논문, R1–R3는 Transformer 부분 연산·관련 행렬 연산 논문이다.

| ID | 논문·저자 | 학회 게재 근거 | 본문 확인 범위 | 작성 관점에서 우선 볼 부분 |
|---|---|---|---|---|
| R1 | **High-Performance Sparse Linear Algebra on HBM-Equipped FPGAs Using HLS: A Case Study on SpMV (HiSparse)**, Yixiao Du et al. | FPGA 2022; [출판 DOI](https://doi.org/10.1145/3490422.3502368) | [저자 공개 출판본](https://raw.githubusercontent.com/cornell-zhang/HiSparse/master/fpgafp193a-du.pdf)의 설계·평가 확인 | U280 SpMV; Transformer 한 층의 희소 행렬 및 graph 행렬. HBM 채널 배분, split-kernel timing, buffer 크기 탐색 |
| R2 | **Sextans: A Streaming Accelerator for General-Purpose Sparse-Matrix Dense-Matrix Multiplication**, Linghao Song et al. | FPGA 2022; [출판 DOI](https://doi.org/10.1145/3490422.3502357), [저자 게재 기록](https://about.blaok.me/publication/sextans/) | [저자 공개본](https://arxiv.org/pdf/2109.11081)의 설계·평가 확인 | U280 범용 SpMM; 200개 행렬·1,400개 workload. 자원 수량/비율, floorplan, bandwidth·에너지 효율, 실측과 projection 구분 |
| R3 | **Approximate Hybrid Binary-Unary Computing with Applications in BERT Language Model and Image Processing**, Alireza Khataei, Gaurav Singh, Kia Bazargan | FPGA 2023, pp. 165–175; [출판 DOI](https://doi.org/10.1145/3543622.3573181), [소속기관 기록](https://experts.umn.edu/en/publications/approximate-hybrid-binary-unary-computing-with-applications-in-be) | [저자 공개 출판본](https://people.ece.umn.edu/~kia/Papers/FPGA23_AHBU.pdf)의 설계·평가 확인 | BERT 계열 Softmax/GELU 근사; 함수 오차·LUT·critical path·cycle 수와 GLUE 품질을 연결 |
| P1 | **FlightLLM: Efficient Large Language Model Inference with a Complete Mapping Flow on FPGAs**, Shulin Zeng et al. | FPGA 2024; [출판 DOI](https://doi.org/10.1145/3626202.3637562) | [저자 공개본 v2](https://arxiv.org/pdf/2401.03868v2)의 평가 절·표·그림 확인 | LLaMA2-7B/OPT-6.7B, P/D, U280 구현과 VHK158 시뮬레이션; 자원·floorplan·bandwidth·정확도·ablation |
| P3 | **FMC-LLM: Enabling FPGAs for Efficient Batched Decoding of 70B+ LLMs with a Memory-Centric Streaming Architecture**, Wenheng Ma et al. | FPGA 2025, p. 55, **1쪽 논문**; [출판 DOI](https://doi.org/10.1145/3706628.3708863), [소속기관 출판 기록](https://research.cuhk.edu.hk/en/publications/fmc-llm-enabling-fpgas-for-efficient-batched-decoding-of-70b-llms/) | [저자 공개 1쪽 출판본](https://shenlibo1999.github.io/files/C3-FPGA25-THU.pdf) 확인 | V80 master + 8 U55C, 70B 모델; TPOT 제약 하 throughput와 비용 효율 |
| P2 | **TeLLMe: An Efficient End-to-End Ternary LLM Prefill and Decode Accelerator with Table-Lookup Matmul on Edge FPGAs**, Ye Qiao et al. | FPGA 2026; [공식 프로그램의 Computing Engines 세션](https://wp.isfpga.org/program/) | [공개본 「TeLLMe v2」의 revision v2](https://arxiv.org/pdf/2510.15926v2)의 평가 절·표·그림 확인 | BitNet 0.73B, P/D, KV260; 모듈별 자원·CPU LM head·lookup 설계 ablation |
| P4 | **Hummingbird+: Advancing FPGA-based LLM Deployment from Research Prototype to Edge Product**, Jindong Li et al. | FPGA 2026; [출판 DOI](https://doi.org/10.1145/3748173.3779189), [공식 프로그램](https://wp.isfpga.org/program/) | [저자 페이지](https://adamgallas.github.io/)에서도 full paper 게재 확인. **본문 미확보** | edge 제품화 관점의 후속 읽기 대상; 상세 수치·표 번호는 미기재 |

FMC-LLM의 짧은 지면에서 상세 자원 표가 없다는 이유로 일반적인 full paper에도 해당 근거가 불필요하다고 해석하지 않는다. Hummingbird+의 평가 내용을 다른 버전·관련 연구의 결과로 대신 채우지 않는다. 모델 계열·규모·batch·보드 수가 다르므로 P1–P4의 tokens/s를 직접 순위화하지 않는다.

[FPGA 2022 공식 프로그램](https://isfpga.org/past/fpga2022/program/)에서 생성형 LLM 전체 추론을 직접 다루는 논문은 확인하지 못했다. 따라서 해당 연도는 HBM·자원·timing 평가의 참고 사례로 포함한다. HiSparse는 압축 Transformer에서 추출한 한 층의 행렬도 평가하지만, 전체 모델 추론 평가는 아니다. [FPGA 2023 공식 프로그램](https://www.isfpga.org/past/fpga2023/program/)의 BERT 관련 논문도 비선형 연산과 encoder 구성요소가 중심이며 autoregressive decode 가속기가 아니다.

연도는 preprint 최초 공개일이 아니라 **FPGA 학회 게재 연도**를 따른다. 예를 들어 Sextans의 arXiv 식별자는 2021년이지만 이 목록에서는 FPGA 2022 논문이다. R1–R3를 최근 생성형 LLM 논문과 같은 tokens/s 비교표에 넣지는 않는다.

## 3. 각 논문에서 실제로 확인한 보고 항목

이 표는 논문에 있는 내용을 기록한다. `미확인`은 해당 공개본에서 근거를 확인하지 못했다는 뜻이며, 자원을 쓰지 않았다는 뜻이 아니다. 전력 측정 경계가 불분명한 경우 전력 수치가 있다는 이유만으로 board measurement로 분류하지 않았다.

| ID | 자원·물리 구현 근거 | 성능·품질·원인 분석 근거 | 참고할 때 지킬 경계 |
|---|---|---|---|
| [P1](https://arxiv.org/pdf/2401.03868v2) | Table 3: LUT/FF/BRAM/URAM/DSP, 수량·%, 모듈별 분해. Fig. 10: 보드·floorplan. §6.1: 225 MHz, xbutil 전력 측정 | Table 4: PPL. Table 5: bandwidth 활용. Fig. 14: 최적화별 latency. Fig. 15: batch sweep | U280은 실제 시스템, VHK158은 검증된 cycle simulator 결과 |
| [P2](https://arxiv.org/pdf/2510.15926v2) | Table 3: 모듈별 다섯 자원, 전체 수량·%. Table 4: TLMM 구현별 LUT. §4.1: 250 MHz | Table 2: PPL. Figs. 10–11: prompt/generation별 성능과 latency breakdown. §4.4: ablation | E2E는 PYNQ runtime 측정, breakdown은 RTL simulation. LM head는 CPU에서 실행 |
| [P3](https://shenlibo1999.github.io/files/C3-FPGA25-THU.pdf) | Fig. 1: master–slave 다중 FPGA 구조. §2: V80 + 8 U55C 구성. 상세 LUT/FF/timing 표는 없음 | §2: Llama-3.1-70B-Instruct, TPOT 50 ms 제약에서 throughput 및 GPU 대비 throughput/비용 효율 | 1쪽 출판본이므로 상세 측정·자원·정확도 ablation의 근거로 사용하지 않음 |
| [P4](https://wp.isfpga.org/program/) | 본문 미확보로 미확인 | 본문 미확보로 미확인 | 게재 목록에만 포함; 구체적인 평가 관행의 근거로 사용하지 않음 |
| [R1](https://raw.githubusercontent.com/cornell-zhang/HiSparse/master/fpgafp193a-du.pdf) | Table 1: LUT/REG/DSP/BRAM/URAM 수량·%. §4, Fig. 9: floorplan과 split-kernel 전후 117→237 MHz. §6.1: HBM 18채널 배분과 routing 한계 | Tables 2–3: 행렬 크기·밀도, GOPS·bandwidth efficiency. Table 6: W·GOPS/W. Fig. 11: buffer 설계 공간. Table 8: preprocessing 비용 | 고정소수점과 부동소수점 변형을 구분. Transformer 평가는 한 층의 SpMV이며, 모델 정확도나 전체 추론 throughput이 아님 |
| [R2](https://arxiv.org/pdf/2109.11081) | Table 4: Used/Available/Utilization %. Table 3: 주파수·메모리 대역폭·전력. Fig. 6: U280 layout | Table 1: 최적화별 speedup. Table 2: workload 범위. Fig. 9: bandwidth utilization 정의·분포. Fig. 10: energy efficiency | Sextans는 U280 실측, Sextans-P는 성능 시뮬레이션·전력 projection. §4.2.3의 bandwidth utilization은 실제 버스 점유율과 다름 |
| [R3](https://people.ece.umn.edu/~kia/Papers/FPGA23_AHBU.pdf) | §4.2: FPGA part·Vivado 버전. Table 3: 함수별 LUT·Tcrit(ns)·cycles·area×latency·오차. Tables 5–6: LUT/FF/DSP/BRAM·cycles | Table 4: GLUE 개발 세트 품질. Fig. 6: 기존 기법 대비 상대 비용. §4.3: Softmax/GELU/MMA의 병목 비교 | 품질은 Python/Fairseq 평가. 하드웨어는 부분 구성요소 평가이며 LayerNorm 미구현. 전체 모델 실기 실행이나 post-route timing closure 근거로 확대하지 않음 |

### 3.1 LUT/FF 보고의 구체적인 참고 예

| 사례 | 원문 수치 | 작성에 적용할 점 |
|---|---|---|
| FlightLLM Table 3 | LUT 574k (44.0%), FF 943k (36.2%), BRAM 1,252 (62.1%), URAM 792 (82.5%), DSP 6,345 (70.2%) | 합계뿐 아니라 buffer/controller/compute/interconnect를 분리해 자원 비용의 원인을 보여줌 |
| TeLLMe Table 3 | LUT 98,303 (84%), FF 136,721 (28%), BRAM 98.5 (68%), URAM 60 (94%), DSP 610 (49%) | control/communication까지 분해. BRAM의 소수 표현은 단위와 집계 방식을 밝혀야 함 |

수치는 분석에 사용한 공개본의 표를 확인한 사례이며 서로 다른 장치·모델의 효율 순위를 뜻하지 않는다. 출처: [FlightLLM Table 3](https://arxiv.org/pdf/2401.03868v2), [TeLLMe Table 3](https://arxiv.org/pdf/2510.15926v2).

### 3.2 2022·2023년 사례에서 추가로 배울 작성 방식

- **절대값을 제시하고 상대 개선율을 함께 쓴다.** HiSparse Table 6은 45 W와 0.37 GOPS/W를 보고한 뒤 baseline 대비 에너지 효율 배수를 설명한다. Sextans Table 3도 실측 설계의 189 MHz·52 W·peak 181.1 GFLOP/s를 제시한다. 절대 성능·전력·효율을 생략하고 배수만 적는 방식으로 해석하지 않는다. [HiSparse](https://raw.githubusercontent.com/cornell-zhang/HiSparse/master/fpgafp193a-du.pdf), [Sextans](https://arxiv.org/pdf/2109.11081)
- **자원 표 형식은 연구 범위에 따라 다르다.** Sextans Table 4는 LUT 379,649/1,303,680 (29%), FF 690,255/2,607,360 (26%)처럼 가용량과 비율까지 제공한다. 반면 2023년 BERT 논문 Table 5는 구성요소별 절대 자원 수와 cycles를 중심으로 비교한다. 후자는 단위 연산 구현 비교의 사례이며, 완성 시스템 논문에서 보드 전체 utilization을 생략할 근거는 아니다. [Sextans Table 4](https://arxiv.org/pdf/2109.11081), [BERT 논문 Table 5](https://people.ece.umn.edu/~kia/Papers/FPGA23_AHBU.pdf)
- **메모리 연결과 timing은 설계 기여를 설명하는 본문 소재다.** HiSparse는 행렬용 16채널과 벡터 입출력용 2채널, 채널 확장 시 routing 문제, die 경계를 고려한 kernel 분할을 설명한다. 주소 remap을 쓰는 설계에서도 주소 bit 배치·port–PC 연결 그림과 remap 전후 bandwidth/성능/자원/timing을 연결해 제시할 수 있다. 이는 이 사례에서 도출한 작성 권고이며, 해당 논문이 Vortex의 주소 remap을 구현했다는 뜻은 아니다. [HiSparse §§4, 6.1](https://raw.githubusercontent.com/cornell-zhang/HiSparse/master/fpgafp193a-du.pdf)
- **근사 연산의 이득에는 품질 근거가 필요하다.** 2023년 BERT 논문은 함수 오차와 하드웨어 비용뿐 아니라 GLUE 품질도 보고한다. 개별 GELU/Softmax가 빨라져도 MMA가 병목으로 남을 수 있음을 설명한다. 연산 단위 개선율을 전체 모델 speedup으로 바꾸어 주장하지 않는다. [BERT 논문 §4.3, Tables 3–6](https://people.ece.umn.edu/~kia/Papers/FPGA23_AHBU.pdf)

## 4. 논문 본문에 포함할 요소

이하 체크리스트는 위 사례를 바탕으로 한 **작성 권고**다. 특정 논문이 아래 항목을 모두 보고했다는 의미는 아니다.

### 4.1 문제 정의와 기여

- [ ] 대상 시나리오를 정한다: batch-1 응답 지연, batched serving, 긴 context, 저전력 edge 등.
- [ ] 가속 범위를 명시한다: GEMM/GEMV kernel, attention, decoder block, 전체 모델, 또는 요청 수신부터 출력까지.
- [ ] prefill/decode 각각의 compute·memory 병목을 실제 profile 또는 정량 모델로 보인다.
- [ ] 기존 연구와의 차이를 메커니즘으로 쓴다: DSP packing, on-chip buffering, sparse scheduling, dataflow, memory layout, runtime 등.
- [ ] 기여 문장마다 대응하는 결과를 지정한다. “메모리 접근 감소”에는 bytes/token 또는 transaction 수, “자원 절감”에는 동일 기능의 자원 비교가 필요하다.
- [ ] “왜 FPGA인가?”에 답한다: 가변 정밀도, DSP cascade, distributed RAM, memory bank, spatial pipeline, DPR 중 실제 사용한 특성과 이득을 연결한다.

### 4.2 아키텍처와 구현 가능성

- [ ] 전체 시스템 그림: CPU/PS, FPGA/PL, DDR/HBM, PCIe/AXI, KV-cache, 데이터·제어 흐름을 표시한다.
- [ ] 핵심 datapath 그림: PE 수, lane 수, 정밀도, pipeline stage, accumulator 폭, buffer 크기·port를 표시한다.
- [ ] weight/activation/KV-cache/scale/sparse index를 어디에 두고 언제 읽고 쓰는지 설명한다.
- [ ] GEMM과 GEMV, prefill과 decode가 어떤 자원을 공유하며 어디서 실행 방식이 달라지는지 보여준다.
- [ ] nonlinear operation, quantize/dequantize, embedding, LM head, sampling의 실행 위치를 밝힌다.
- [ ] 모델/shape 변경 시 bitstream 재생성, 컴파일, runtime 설정 중 무엇이 필요한지 설명한다.
- [ ] DSP cascade 길이, bank conflict, fanout, SLR crossing 등 성능을 제한한 물리 조건을 설명한다.

단순히 block diagram을 넣는 것으로 끝내지 않는다. 제안한 buffering이나 scheduling이 기존 bottleneck을 없애는 과정을 데이터 이동과 cycle 수준에서 설명하고, 이를 실험으로 확인한다.

### 4.3 자원 사용량과 timing: FPGA 구현 논문의 기본 표

**최소 보고:** exact device/board, 구현 단계, LUT/FF/DSP/BRAM/URAM 수량과 비율, 실제 실행 주파수. synthesis 수치만 있으면 그렇게 표시하고 post-route 구현 완료로 표현하지 않는다. 실제 보드 측정과 implementation report의 design/configuration도 일치시킨다.

| 항목 | 기재 내용 | 자주 생기는 혼동 |
|---|---|---|
| LUT / FF | 사용 수량, 가용량, 비율. LUTRAM/SRL 포함 방식 | LUT를 물리 면적 mm²와 동일시; 가용 자원을 사용량으로 오인 |
| DSP | 사용 수량, 블록 종류, packing 방식과 연산 정밀도 | DSP 수만으로 실제 MAC/cycle을 추정 |
| BRAM / URAM | primitive 수, BRAM18/BRAM36 또는 KiB/MiB 단위, 배치/분할 방식 | BRAM18과 BRAM36을 같은 수량으로 비교 |
| 자원 비율의 분모 | 전체 device인지 shell을 제외한 user region인지 | shell이 다른 설계의 utilization %를 직접 비교 |
| 집계 범위 | accelerator IP, DMA/interconnect 포함 top, shell 포함 전체 | 작은 IP 수치와 다른 논문의 전체 설계를 비교 |
| 주파수 | target clock, post-route에서 timing을 만족한 clock, benchmark clock, 확인한 경우 Fmax; 여러 domain이면 각각 | HLS target 또는 한 번 성공한 clock을 최대 주파수로 표현 |
| timing | post-route 여부, setup/hold·pulse-width 검사와 제약 완전성; 필요하면 WNS/TNS·WHS/THS | 목표 MHz 또는 setup WNS 하나만으로 전체 timing closure를 주장 |
| 물리 제약 | CLB, SLR별 점유, routing congestion, critical path/fanout | LUT가 남아 있다는 이유만으로 PE를 더 넣을 수 있다고 주장 |

모듈별 breakdown은 compute, attention/nonlinear, buffer/KV-cache, control, interconnect/DMA 정도로 시작한다. 계층별 보고는 parent/child 중복 합산을 피하고, 공유 IP와 합성 최적화 때문에 합계가 달라지면 설명한다. 자원을 쓰지 않으면 `0`, 장치에 없으면 `N/A`, 확인하지 않았으면 `NR`로 구분한다.

#### 4.3.1 Fmax: 무엇을 보고하고 어떻게 확인하는가?

**실제 실행 주파수는 기본 보고 항목이다. Fmax도 유용하지만, 최대 주파수를 탐색하지 않았다면 실행 주파수를 Fmax로 이름 붙이지 않는다.** MHz는 절대값으로 제공하고 baseline 대비 주파수 개선율은 보조로 쓴다. 조사 사례에서도 HiSparse는 117→237 MHz의 timing 개선을, Sextans는 실측 설계의 189 MHz를 보고한다. 이 수치만으로 모든 논문이 같은 방식으로 Fmax를 탐색했다고 판단할 수는 없다. [HiSparse §4](https://raw.githubusercontent.com/cornell-zhang/HiSparse/master/fpgafp193a-du.pdf), [Sextans Table 3](https://arxiv.org/pdf/2109.11081)

| 구분 | 의미와 보고 방법 |
|---|---|
| Target clock | 합성·구현에 준 목표 period/frequency. 달성 결과가 아님 |
| Achieved clock | 명시한 구현·제약에서 timing을 만족한 주파수. 한 설정의 성공 결과이며 최대값 보장은 아님 |
| Fmax | 명시한 device·제약·구현 방법에서 확인한 최대 주파수. 탐색 범위/간격 또는 도구의 산출 방법과 결과 단계를 함께 제시 |
| Benchmark clock | latency·throughput·power를 측정할 때 실제로 사용한 주파수. achieved clock/Fmax보다 낮을 수 있음 |
| HLS estimate / IP OOC 결과 | 추정치 또는 독립 IP의 구현 결과. shell·interconnect를 포함한 전체 시스템의 post-route 결과와 분리 |

Vivado에서 최대값을 확인하려면 clock 제약을 바꾸어 synthesis/implementation을 반복하고, fully routed 설계의 timing을 확인하는 방식이 근거가 된다. 탐색에서 통과한 최고 주파수와 실패한 다음 설정, 사용한 전략을 남기면 범위가 분명해진다. 단일 실행의 WNS를 주파수로 환산한 값은 같은 netlist에 대한 추정으로 표시하고, 재구현으로 확인한 Fmax와 구분한다. AMD는 `report_timing`/`report_timing_summary`가 Fmax를 직접 제공하지 않는다고 설명한다. [AMD UG1388](https://docs.amd.com/r/en-US/2026.1/ug1388-acap-system-integration-validation-methodology/Assessing-the-Maximum-Frequency-of-the-Design)

- [ ] 정확한 part와 **speed grade**, 도구 버전, post-route 여부, timing corner/전압·온도 가정, clock uncertainty를 기록한다. STA의 corner는 실제 보드 온도 측정과 구분한다.
- [ ] core/AXI/HBM interface 등 관련 clock domain과 고정한 clock을 밝힌다. 한 domain의 Fmax를 시스템 전체 clock으로 쓰지 않는다.
- [ ] setup의 WNS/TNS뿐 아니라 hold의 WHS/THS, 관련 pulse-width 검사, 실패 endpoint와 미제약 경로를 확인한다. false/multicycle path의 근거 및 CDC 검증은 필요한 범위에서 남긴다.
- [ ] Fmax가 기여라면 critical path의 시작·끝 블록, logic/routing delay와 병목 변화, 추가 register·LUT 비용을 보고한다.
- [ ] 같은 구현 결과의 resource·timing을 함께 보고한다. 자원이 가장 작은 run과 Fmax가 가장 높은 run의 수치를 한 설계 결과로 합치지 않는다.

WNS/TNS 등 모든 상세 로그를 본문에 넣을 필요는 없다. 본문에는 **실행 MHz, timing을 만족한 구현 단계·조건, Fmax 주장에 필요한 근거**를 두고, 제약 파일과 timing/CDC report는 부록·artifact로 제공할 수 있다. Vivado timing summary는 setup과 hold 등을 구분하며, 기본 설정에서는 미제약 경로를 포함하지 않으므로 별도 확인이 필요하다. [AMD UG835](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/report_timing_summary)

이 절의 AMD 문서는 용어와 확인 방법의 근거다. §2의 **FPGA 학회 게재 논문 목록**에 추가한 연구 논문은 아니다.

### 4.4 LLM workload와 정확도

- [ ] 모델 이름뿐 아니라 checkpoint/revision, parameter 수, layer/hidden/head 구성, MHA/GQA/MQA 여부를 기록한다.
- [ ] weight·activation·accumulation·KV-cache 정밀도를 각각 기록한다. `INT4` 하나로 전체 경로를 표현하지 않는다.
- [ ] quantization group size, scale/zero-point, sparse pattern·density, metadata 비용을 포함한다.
- [ ] batch/concurrency, prompt 길이, 생성 길이, 최대 context, KV-cache 초기 상태, early stop 여부를 지정한다.
- [ ] 손실이 있는 변환은 원본과 변환 후의 PPL/task metric을 동일 데이터·설정에서 비교한다. fine-tuning/calibration 데이터와 비용도 밝힌다.
- [ ] 정확한 연산 구현이라면 golden software와의 출력 비교, 허용 오차, overflow/rounding 검증을 제시한다.
- [ ] 긴 context를 주장하면 긴 입력에서의 품질도 평가한다. 짧은 문장의 PPL만으로 long-context 품질 보존을 주장하지 않는다.
- [ ] 모델 계열이나 parameter 수가 다르면 품질과 성능을 병렬로 제시하고, 동일 모델의 가속률처럼 표현하지 않는다.

`tokens/J ÷ PPL`처럼 여러 값을 합친 지표는 보조 분석으로 사용할 수 있으나, 원래의 품질·latency·energy 값을 대체하지 않는다. 같은 크기의 모델도 능력이 같다고 가정하지 않는다.

### 4.5 성능 지표와 측정 범위

| 지표 | 기록할 정의·조건 |
|---|---|
| Prefill latency | prompt 처리 구간; embedding/LM head/first-token sampling의 포함 여부 |
| TTFT | 지정한 시작 시점부터 첫 output token까지. queueing/network 포함 여부를 명시 |
| TPOT / TBT / inter-token latency | 첫 token 이후의 평균 시간 또는 인접 token 간 시간. 평균과 p95/p99를 구별 |
| Decode throughput | decode 구간에 생성한 token 수 / 그 구간 시간. request당인지 전체 batch 합계인지 명시 |
| End-to-end latency | tokenizer, transfer, prefill, decode, sampling, CPU 연산, 필요 시 재구성을 포함한 명시적 구간 |
| Kernel latency / GOPS | 보조 지표. 연산 수 산정, MAC을 1 또는 2 ops로 세는지, sparse/dense-equivalent 여부 |

첫 token 생성 시점을 `t1`, 마지막을 `tN`, 출력 token 수를 `N > 1`이라 하면 한 요청의 평균 inter-token latency는 `(tN - t1) / (N - 1)`로 정의할 수 있다. 이 정의를 사용할 경우 첫 token을 다시 decode 분자에 포함하지 않는다. batch 전체 tokens/s의 역수는 개별 요청 TPOT가 아니다.

성능 그래프는 speedup만 그리지 말고 절대 ms·tokens/s도 제공한다. host timer/보드 counter/RTL cycle 중 무엇을 썼는지, warm-up과 반복 횟수, 평균/중앙값 및 변동을 기록한다. 매우 짧은 kernel은 timer 오차와 launch overhead를 고려한다. 요청 지연/SLO를 주장하는 serving 실험은 arrival pattern과 tail latency를 함께 보고한다.

연산기·pipeline·scheduling이 기여라면 다음을 추가한다.

- [ ] 핵심 loop/engine의 **latency(cycles), 실제 initiation interval(II), pipeline fill/drain**, 처리 단위와 병렬도를 보고한다. HLS pragma의 목표 II와 도구가 달성한 II를 구분한다.
- [ ] `II=1`이어도 memory stall/backpressure로 매 cycle 유효 연산이 수행되는 것은 아니다. 대표 workload에서 유효 연산률과 stall 원인을 제시한다.
- [ ] 같은 clock에서의 cycle 감소와 각 설계의 달성 clock에서의 실제 시간 감소를 구분한다. 단일 고정 clock 구간은 `time = cycles / frequency`로 연결하되, host·비동기 통신 시간은 별도로 측정한다.
- [ ] peak GOPS/TOPS를 쓰면 `연산/cycle × 실행 Hz`의 산식과 정밀도를 밝히고 sustained 성능을 함께 제시한다. token 성능을 peak 연산 성능으로 대체하지 않는다.

Sextans는 II=1 scheduling을 설계 근거로 사용한다. HLS 보고서 역시 latency와 target/achieved II를 별도 항목으로 제공한다. [Sextans §§3.2, 3.5](https://arxiv.org/pdf/2109.11081), [AMD HLS tutorial](https://docs.amd.com/r/2023.2-English/Vitis-Tutorials-Hardware-Acceleration/Vitis-HLS-for-Kernel-Optimizations)

### 4.6 전력·에너지

에너지 효율이 기여라면 **전력값의 출처와 범위**가 필수다. 전력 측정 없이 vendor TDP만 넣고 measured energy efficiency로 표현하면 안 된다.

- [ ] 보드 센서/전력계/소프트웨어 계측 또는 Vivado estimate 중 무엇인지 명시한다.
- [ ] FPGA chip, card, PS/PL, DDR/HBM, host CPU, 전체 시스템 중 포함 범위를 쓴다.
- [ ] active power와 idle power, idle subtraction 여부, 측정 시간·sampling interval을 기록한다.
- [ ] throughput과 전력을 같은 workload·batch·실행 구간에서 얻는다.
- [ ] 여러 FPGA를 사용하면 활성 카드·대기 카드·필요한 외부 메모리와 통신 비용을 포함한다.
- [ ] Vivado 추정은 구현 단계, activity source/SAIF/VCD 또는 vectorless 가정, 온도 등의 조건을 적는다.
- [ ] activity 기반 추정은 stimulus workload·구간과 activity annotation 범위를 남긴다. vectorless fallback이 포함되면 이를 밝힌다.
- [ ] 동적 clock이나 열에 따른 clock 변화가 가능하면 실제 clock·온도와 안정화 조건을 기록한다. 장시간 지속 성능을 주장할 때는 충분한 실행 구간에서 throughput·power·clock 변화를 확인한다.

정상상태에서 평균 전력 `P`와 throughput `R`의 측정 범위가 같으면 `energy/token = P / R` [J/token], `tokens/J = R / P`다. 짧은 요청이나 P/D 전력이 크게 다른 경우에는 `E = ∫P(t)dt`를 요청 구간에 대해 구하고 생성 token 수로 나눈다. FPGA chip power와 GPU board power를 비교했다면 경계 차이를 표시하고 시스템 전체 우위로 확대하지 않는다.

### 4.7 메모리·bandwidth·compute utilization

이 문서에서는 아래 세 가지 utilization을 구분한다.

| 용어 | 의미 | 필요한 보조 정보 |
|---|---|---|
| Resource utilization | 사용한 LUT/FF/DSP/메모리 블록 수 / 가용량 | device와 집계 범위 |
| Compute utilization | 유효하게 수행한 연산 / 해당 구간의 실행 가능 연산 | 정밀도, clock, PE 수, 실제/논리적 sparse 연산 수 |
| Bandwidth utilization | 실제 전달 bytes / 시간 / 기준 bandwidth | bytes 집계 범위와 분모가 peak인지 measured sustainable인지 |

- [ ] weights, KV-cache, activation, metadata의 용량과 bytes/token을 구분한다.
- [ ] HBM/DDR 채널 수, port 폭·clock, bank mapping, burst length, 유효 bandwidth를 적는다.
- [ ] memory subsystem이 기여라면 outstanding transaction 수·요청 크기/정렬·stride·read/write 비율을 명시한다. nominal peak, 해당 구성의 microbenchmark bandwidth, application 유효 bandwidth를 구분한다.
- [ ] 주소 remap은 입력 주소 bit와 변환 후 PC/bank/local address의 대응, interleave granularity, port–PC 연결을 그림·식으로 제시한다. 동일 접근 trace의 remap on/off bandwidth·stall과 추가 LUT/FF·latency·clock 영향을 비교한다.
- [ ] 모델 크기/latency로 계산한 bandwidth proxy와 memory counter로 측정한 traffic을 구분한다.
- [ ] context가 길어질 때 KV-cache 용량·대역폭·TPOT가 어떻게 증가하는지 보인다.
- [ ] 최대 지원 model/context/batch는 weight·KV-cache·activation·workspace·metadata·예약 공간을 포함한 peak 메모리 사용량으로 설명한다. 이론적 용량과 실제 실행으로 확인한 최대 설정을 구분한다.
- [ ] on-chip reuse, buffering, fusion의 이득을 traffic/stall 감소와 연결한다.

병목 설명에는 `T ≥ max(실제 연산량 / sustained compute, 실제 bytes / sustained bandwidth)` 같은 하한 모델이 유용하다. 이는 compute와 transfer가 충분히 겹치는 이상적인 경계이며, overlap되지 않는 구간·동기화·통신 비용은 별도로 반영해야 한다.

### 4.8 비교 실험의 공정성

필수 baseline은 **제안 기법이 없는 내부 구현**과 **가장 가까운 관련 연구/실용 구현**이다. GPU보다 우수하다고 주장한다면 최적화된 GPU baseline이 필요하다. GPU 비교 자체가 모든 FPGA 논문의 필수 요건은 아니다.

- [ ] 가능하면 모델/checkpoint, batch, prompt/output 길이, 품질 조건, timing boundary를 맞춘다.
- [ ] GPU baseline의 framework·version·kernel·정밀도·KV-cache·batching 설정을 기록한다.
- [ ] FPGA와 GPU가 서로 다른 양자화/희소성을 쓴다면 모델 변경 이득과 하드웨어 이득을 분리한다.
- [ ] 선행 연구의 original reported 수치, 직접 재현, 자체 reimplementation, simulator 이식을 구분한다.
- [ ] 장치·clock·정밀도·메모리 차이를 비교 표에 남긴다. LUT 개수나 공정 노드로 speedup을 단순 정규화하지 않는다.
- [ ] decode-only, kernel-only 결과를 end-to-end 결과와 같은 열에 넣지 않는다.
- [ ] 최댓값인지 평균인지, geometric mean인지, 어느 workload 집합을 평균냈는지 명시한다.
- [ ] cost/TCO를 주장하면 가격 기준일, 구매/대여 조건, 보드 수, host, 메모리, 전기·가동률 가정을 제시한다.

### 4.9 Ablation, 설계 공간, 제한점

| 기여 주장 | 최소한의 대응 실험 | 함께 볼 비용 |
|---|---|---|
| 새로운 MAC/GEMM engine | 같은 기능·정밀도·병렬도에서 기존 engine과 비교 | LUT/FF/DSP, achieved clock, cycles, energy |
| buffer/fusion/dataflow | 기법 on/off 및 단계별 latency·traffic | BRAM/URAM, 추가 control, FIFO, routing |
| mixed precision / sparsity | 양자화·pruning 단계별 품질/크기/latency | scale/index, decompress, calibration/training |
| PE/lane 확장 | 병렬도 sweep | resource growth와 clock 저하, bandwidth 포화 |
| 긴 context 지원 | context별 latency·메모리·품질 | cache spill, 최대 지원 길이, offloading |
| 다중 FPGA | 카드 수별 throughput/latency | 통신량·동기화·전체 power·효율 |
| DPR/phase switching | static baseline, 원래 재구성 시간, 숨기고 남은 시간 | partial bitstream 크기, reserved region, clock/routing |
| compiler/runtime | 준비 시간, compile time, instruction/storage 및 runtime overhead | 지원 모델·shape, 재합성 필요성 |

자원 절감 ablation은 같은 주파수에서 비교하고, 최종 설계의 실제 달성 주파수 결과도 별도로 보이면 좋다. 성능 이득을 위해 clock이나 자원을 늘린 실험은 그 사실을 숨기지 않는다. 작은 모델/짧은 prompt/큰 batch에서 손해를 보는 조건과 미지원 operator도 결과의 일부로 보고한다.

## 5. 그대로 채워 사용할 표·그림 구성

아래의 `—`는 작성 전 빈칸이다. 제출본에서는 실제 값, `NR`, `N/A`, `0`를 구분해 채운다.

### 표 A. 플랫폼 및 workload

| Design | Board / part·speed grade / 카드 수 | Tool version | Clock: target / achieved / 실행 | Memory 용량·BW | Model / W-A-KV-Acc | Batch / input / output | 측정 범위·방법 |
|---|---|---|---|---|---|---|---|
| Internal baseline | — | — | — | — | — | — | — |
| Proposed | — | — | — | — | — | — | — |
| External baseline | — | — | — | — | — | — | — |

### 표 B. 구현 후 자원과 timing

Caption에 FPGA part, report 단계, shell 포함 여부, BRAM 단위를 쓴다. timing은 별도 열 또는 caption/인접 문단에서 함께 보고한다.

| Component | LUT | FF | DSP | BRAM36 equivalent | URAM |
|---|---:|---:|---:|---:|---:|
| Compute engine | — | — | — | — | — |
| Attention / nonlinear | — | — | — | — | — |
| Buffers / memory subsystem | — | — | — | — | — |
| Control / DMA / interconnect | — | — | — | — | — |
| Total used | — | — | — | — | — |
| Available within stated scope | — | — | — | — | — |
| Utilization (%) | — | — | — | — | — |

공유 자원은 한 번만 집계한다. BRAM36 equivalent를 선택했다면 변환 규칙을 명시한다. 필요한 경우 CLB/LUTRAM/SLR 열 또는 별도 표를 추가한다.

### 표 B2. Clock와 timing 근거

각 행은 동일 configuration의 구현 결과다. Fmax를 탐색하지 않았으면 `NR (미탐색)`로 쓰고 achieved clock과 실행 clock은 채운다. 여러 clock이면 domain별 행을 추가한다.

| Design / clock domain | Target (MHz) | Achieved (MHz) | Fmax (MHz)·확인 방법 | 실행 (MHz) | 구현 단계·scope | Setup WNS/TNS (ns) | Hold WHS/THS (ns) |
|---|---:|---:|---|---:|---|---|---|
| Internal baseline / core | — | — | — | — | post-route / system 또는 IP OOC | — | — |
| Proposed / core | — | — | — | — | post-route / system 또는 IP OOC | — | — |

Caption 또는 부록에 part/speed grade, timing corner, uncertainty, 미제약 경로·예외 처리와 관련 검사 결과를 둔다. 이 표의 clock과 표 B의 자원 수치, 표 C의 실험이 어느 구현에 대응하는지 식별할 수 있어야 한다. 지면이 부족하면 본문에는 MHz·closure 결과를 두고 상세 slack을 부록으로 옮긴다.

### 표 C. 절대 성능·전력·품질

| Model / B / input / output | TTFT (ms) | TPOT (ms/token) | Decode (tokens/s) | E2E (ms) | Power (W) | Energy (J/output token) | Quality | 근거·범위 |
|---|---:|---:|---:|---:|---:|---:|---|---|
| — | — | — | — | — | — | — | — | board / RTL / model / literature; chip / board / system |

Prefill throughput을 추가할 때는 output token throughput과 구분한다. decode-only 설계의 TTFT를 `0`으로 쓰지 않는다. 에너지가 decode-only인지 E2E인지 caption에 명시한다.

### 권장 그림과 질문

| 그림 | 답해야 하는 질문 |
|---|---|
| 시스템 구조 + 핵심 datapath | 계산과 데이터 이동을 어디서 어떻게 수행하는가? |
| Floorplan/SLR 배치 | 제안 구조가 실제 FPGA에 어떤 제약으로 매핑되는가? |
| P/D latency와 operator breakdown | 어느 단계에서 무엇이 병목인가? |
| Baseline 대비 절대 성능 + speedup | 어느 workload에서 얼마나 개선되는가? |
| 기여별 ablation | 각 설계 기법의 독립적인 효과와 비용은 무엇인가? |
| Context/batch/parallelism sweep | 성능 우위의 범위와 포화점은 어디인가? |
| Accuracy–latency 또는 energy trade-off | 절약한 비용에 비해 품질 손실은 허용 가능한가? |

페이지가 부족하면 실험 설정과 전체 자원 표, 핵심 성능, 품질, 핵심 ablation을 본문에 우선 둔다. 상세 보고서와 sweep은 보충 자료로 옮길 수 있지만, 핵심 주장의 근거가 본문에서 사라지지 않게 한다.

## 6. 원고 작성과 재현 자료

권장 본문 흐름은 **문제/병목 → 기여 → 아키텍처·mapping → 구현·평가 방법 → 성능/비용 → 원인 분석 → 한계**다. 관련 연구는 논문별 소개를 늘어놓기보다 precision, phase, memory, programmability, scale 등 자신의 기여와 연결되는 축으로 비교한다.

- [ ] Abstract의 최대 speedup에는 상대 baseline과 대표 조건을 붙인다.
- [ ] “end-to-end”, “real-time”, “efficient”, “scalable”에 측정 가능한 정의를 준다.
- [ ] `up to` 결과를 평균 결과로 바꾸지 않는다. device 측정 결과를 전체 시스템 결과로 확대하지 않는다.
- [ ] 표와 본문에 같은 model/configuration/clock/precision을 사용한다.
- [ ] 타 논문의 후속 개정판 수치를 초기 버전의 표 번호와 섞지 않는다.
- [ ] code commit, config, model revision, tool/driver version, build/run command, seed를 남긴다.
- [ ] XDC/SDC, platform/shell·IP 버전, synthesis/P&R strategy·directive, 지원되는 경우 placement seed를 남긴다. 여러 run 중 결과를 선택했다면 시도 횟수와 선택 기준을 밝힌다.
- [ ] compilation·mapping·재구성 시간이 기여라면 preprocessing, HLS, synthesis, place-and-route, bitstream 생성, load 시간을 분리하고 host 사양·thread 수를 기록한다. 일반 가속기 논문에서 전체 build 시간을 본문 필수 지표로 볼 필요는 없다.
- [ ] raw latency/power log, utilization/timing report, 결과 집계·plot script를 보관한다.
- [ ] simulator를 사용하면 보드/RTL 기준 검증 대상과 예측 오차, 적용 범위를 제공한다.

현재 프로젝트처럼 여러 RTL/config 변형을 비교하는 경우에는 **동일 configuration의 bitstream·자원 report·timing report·실행 log를 한 묶음으로 관리**하는 것이 우선이다. 같은 source revision이어도 PE 수, buffer 크기, clock 제약이 다르면 동일 구현 결과가 아니다. 이 문서는 현재 원고의 실험 충족 여부를 감사한 결과는 아니다.

## 7. ACM FPGA 제출 형식과 연구 평가 요건은 구분

2026-09-29에 확인한 [FPGA 2027 공식 CFP](https://wp.isfpga.org/call-for-papers/)는 long paper를 참고문헌 제외 최대 10쪽, ACM `sigconf` 형식, double-blind로 안내한다. artifact 제출은 권장되지만 논문 제출의 필수 조건은 아니며, artifact 링크도 익명성을 지켜야 한다.

CFP의 형식 요건과 이 문서의 연구 평가 체크리스트는 서로 다른 층위다. 예를 들어 전체 자원 사용량과 timing은 FPGA 구현 주장을 검증하는 데 필요한 근거로 권고한 것이며, CFP에 “LUT/FF 표가 있어야 접수된다”는 규정이 있다는 뜻은 아니다. 실제 제출 시에는 해당 연도·학회 CFP를 다시 확인한다.
