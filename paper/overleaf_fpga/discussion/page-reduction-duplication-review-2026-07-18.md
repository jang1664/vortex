# `main.tex` Page-Reduction Duplication Review, 2026-07-18

대상 파일: `main.tex`

목적: HPCA의 reference 제외 11-page 제한에 맞추기 전에, 원고에서 같은 주장이나 메커니즘을 반복 설명하는 부분을 식별하고 안전한 통합 방향을 기록한다.

현재 상태: `_outputs/main.pdf`는 총 13쪽이다. Conclusion 일부가 13쪽으로 넘어간 뒤 References가 시작하므로, reference 제외 본문은 약 12쪽을 조금 넘는다. 목표까지 약 1쪽 이상을 줄여야 한다.

주의: 이 문서는 축약 후보를 정리한 검토 기록이다. `main.tex`에는 아직 아래 변경을 적용하지 않았다.

## 중복 설명 후보

| 우선순위 | 반복되는 내용 | 반복 위치 | 권장 정리 방향 | 예상 절감 |
|---|---|---|---|---:|
| 1 | C1→C2→C3→C4의 의미를 반복 해석 | 후보 정의 `main.tex:517-542`<br>E2E 해석 `main.tex:657-668`<br>GEMM breakdown `main.tex:706-720`<br>Energy `main.tex:742-748` | Methodology에는 후보 정의만 둔다. E2E에는 C4-vs-C1 최종 수치와 breakdown을 가리키는 문장만 유지한다. C1→C4의 상세 인과 분석은 GEMM Latency Breakdown 한 곳에서 수행한다. Energy에서는 새로운 에너지 수치만 보고한다. | 180–230 words |
| 2 | 큰 FP-INT MXU에는 별도 memory system이 필요하고 crossbar는 비싸다는 논증 | Introduction `main.tex:109-112`<br>Background Gap 2 `main.tex:285-290`<br>Design Overview `main.tex:322-331`<br>Memory System `main.tex:428-434`<br>Evaluation `main.tex:666-668`, `717-720` | Introduction은 한 문장으로 문제를 예고한다. Background에는 정량적 동기와 crossbar-overhead figure를 둔다. Memory System에는 실제 topology와 address constraint를 둔다. Overview에서는 direct tensor path만 소개하고 crossbar 동기를 재설명하지 않는다. | 120–180 words |
| 3 | Linear-only FP-INT는 attention을 FP path에 남긴다는 문제 | Introduction `main.tex:108-109`<br>Background Gap 1 `main.tex:229-240`<br>Attention section 도입 `main.tex:335-337`<br>Attention section 결론 `main.tex:423`<br>E2E `main.tex:657-664`<br>GEMM breakdown `main.tex:706-715` | Background Gap 1을 canonical motivation으로 사용한다. Native FP-INT Attention Support는 바로 제안 datapath로 진입하고 section-ending fallback 요약은 삭제한다. Evaluation의 반복은 1번 방향으로 통합한다. | 80–120 words |
| 4 | Token/channel 방향, Q-COL/Q-ROW, reduction-axis 문제, RHS transpose 요구 | Background 정의 `main.tex:239-260`<br>Design Overview `main.tex:318-319`<br>상세 설계 `main.tex:335-412` | Background에는 용어와 quantization-scheme table을 유지한다. 수학적 원인과 하드웨어 해법은 Native FP-INT Attention Support에 집중한다. Overview는 qdir와 load direction을 독립 설정한다는 한 문장으로 축약한다. | 120–170 words |
| 5 | WKV의 linear, QKᵀ, PV가 모두 FP-INT라는 핵심 관찰 | Abstract `main.tex:81`<br>Introduction `main.tex:99-100`<br>Background `main.tex:133-149`<br>Conclusion `main.tex:823-824` | Background의 세 수식을 기술적 기준 설명으로 유지한다. Introduction은 핵심 관찰 한 문장만 남기고 연산별 나열을 제거한다. Abstract와 Conclusion은 각각 짧은 recap만 유지한다. | 40–70 words |
| 6 | Dequantization은 memory만 줄이고 compute/energy 이득을 잃는다는 설명 | Introduction `main.tex:102-106`<br>Why Memory Saving Alone is Insufficient `main.tex:182-207`<br>Software Optimization `main.tex:211-213` | Background의 두 짧은 subsection을 하나로 통합한다. Roofline 근거, Marlin/BitDecoding 인용, overlappable latency와 unavoidable energy/FP-MAC cost의 차이만 유지한다. Introduction은 한 문장으로 축약한다. | 80–120 words |
| 7 | Q-ROW scale을 input에 fold한다는 내용을 같은 절 안에서 반복 | 직접식 설명 `main.tex:355-366`<br>변환식과 설명 `main.tex:368-390` | 두 식과 scale을 prealignment 전에 A에 적용한다는 한 문장을 유지한다. Effective scale이 1이라는 반복 해설은 축약한다. Tile이 group boundary를 넘지 않는 조건과 32-multiplier 결과는 유지한다. | 70–110 words |
| 8 | Non-coherent DMA의 fence, completion polling, cache 관리 | Design Overview `main.tex:330-331`<br>Cache-Bypassed Tensor DMA `main.tex:479-481`<br>Cache Visibility `main.tex:504-505` | Runtime의 Cache Visibility를 유일한 상세 설명으로 유지한다. Overview와 Memory System에서는 non-coherent path라는 사실과 Runtime section 참조만 남긴다. | 60–90 words |
| 9 | Tile-major layout, aligned allocation, fused transformation의 반복 소개 | Design Overview `main.tex:330-331`<br>Memory constraint `main.tex:457`<br>Runtime 도입 `main.tex:493`<br>첫 subsection `main.tex:495-502`<br>Methodology `main.tex:604-610`<br>E2E `main.tex:695-698` | Runtime을 canonical 설명으로 사용하고 도입부와 첫 subsection의 첫 문장을 병합한다. Methodology에는 transformation 비용이 포함됐다는 한 문장만 유지하고 E2E의 재설명은 삭제한다. | 40–70 words |
| 10 | Introduction의 Goal paragraph가 바로 뒤 Contributions를 미리 반복 | Goal and approach `main.tex:111-112`<br>Contributions `main.tex:114-127` | Contributions를 유지하고 Goal paragraph는 한 문장짜리 전환으로 축약한다. 마지막 contribution은 Vortex 구현과 네 design point까지만 남기고 세부 구현과 최대 speedup은 Evaluation로 이동한다. | 70–110 words |
| 11 | MMIO descriptor command flow | Design Overview `main.tex:326-327`<br>Software Implementation `main.tex:613-617` | Design Overview에 descriptor/micro-op 동작을 유지한다. Evaluation에서는 같은 interface를 사용했다는 한 문장과 평가에 고유한 attention execution schedule만 유지한다. | 25–40 words |
| 12 | GEMM 가속 후 vector kernel이 병목으로 이동한다는 결론 | E2E `main.tex:695-698`<br>GEMM Breakdown `main.tex:717-720`<br>Energy `main.tex:746-748` | Latency bottleneck 해석은 E2E에 한 번만 유지한다. GEMM Breakdown의 반복 문장은 삭제하고, Energy에는 에너지 비율과 energy-specific 해석만 유지한다. | 20–35 words |

## 권장 적용 순서

우선 `1 → 2 → 4 → 6 → 8 → 10` 순서로 정리하는 것이 좋다. 이 항목들은 절감 폭이 크고, 원고의 고유한 기술 내용이나 재현성 정보를 제거할 위험이 비교적 낮다.

각 행의 예상 절감량은 서로 일부 겹치므로 단순 합산하면 안 된다. 중복을 제거해 계산하면 약 650–900 words를 줄일 여지가 있다. Two-column float 재배치까지 고려하면 약 1쪽 전후를 회수할 가능성이 있지만, 실제 분량은 각 변경 묶음 적용 후 `_outputs/`에 다시 빌드하여 확인해야 한다.

## 유지해야 할 반복과 기술 세부사항

- Abstract, Introduction, Contributions, Conclusion의 짧은 thesis recap은 논문 구조상 필요하므로 완전히 제거하지 않는다. 각 위치에서 담당하는 수준만 다르게 한다.
- Q-COL/Q-ROW의 수학적 equivalence를 설명하는 식과 실제 zero-point correction routing을 설명하는 식은 역할이 다르다. 반복 prose를 줄이되 식을 기계적으로 삭제하지 않는다.
- Cache visibility를 축약할 때 producer fence, HBM write 이후 completion update, launch-time invalidation, kernel-end fence가 canonical Runtime 설명에 모두 남아 있는지 확인한다.
- Figure caption은 본문과 독립적으로 이해될 필요가 있다. 본문과 유사하다는 이유만으로 삭제하지 않고, caption에만 존재하는 실험 조건이 있는지 먼저 확인한다.
- Evaluation을 통합한 뒤에는 end-to-end, GEMM-only, energy 수치가 서로 혼동되지 않도록 각 숫자에 정확히 하나의 인접한 해석이 남아 있어야 한다.

## 다음 검토 시 확인할 사항

1. 우선순위가 높은 중복군부터 한 묶음씩 수정한다.
2. 각 묶음 적용 후 LaTeX 산출물은 `_outputs/` 아래에 생성한다.
3. References가 시작되는 실제 페이지와 Conclusion의 마지막 페이지를 확인한다.
4. 11쪽에 도달하지 못한 경우에만 unique technical detail, figure 크기, caption 길이 등의 추가 축약을 검토한다.
