**plan.rev2.md 적대적 리뷰**

검토일: 2026-09-11. 대상: [plan.rev2.md](plan.rev2.md). 소스 HEAD: `a1f98615c1994e6ee18c902a77e433b2ffe54055` 및 현재 worktree. 이전 리뷰의 사용자 제약도 함께 확인했다.

**판정: 수정 필요.** rev2는 출력 준비/재사용 분리, improve 전용 scheduler, N-fast 우선, 저장 공간 제한, reset 범위를 명확하게 개선했다. 후속 사용자 지시로 R1은 허용 오차 0.1% 적용, R2는 독립 S/Z DMA 사용, R3는 naive의 N-fast 고정으로 설계 방향이 정해졌다. 이 결정을 계획과 구현에 반영하고 검증해야 하며, R4의 계측 경계 문제도 남아 있다.

**후속 사용자 지시 — 2026-09-11**

1. **수치 검증 허용 오차를 0.1%로 정한다.** 사용자 원문: “허용 오차를 0.1%하는걸로 하자. review에 user가 지시했다고 써줘.” 상대 오차 기준의 구현 상수는 `0.001f`다. R1의 1% 비교 결과는 변경 전의 역사적 증거이며, 앞으로 적용할 기준은 0.1%다. 기대값이 0인 경우의 절대 오차 분기는 별도로 명시하고 확인해야 한다.
2. **naive도 improve처럼 scale DMA와 zero-point DMA를 독립적으로 갖도록 한다.** 사용자 원문: “naive도 scale 과 zero point dma를 improve 처럼 독립적으로 가지도록 하고 싶어.” 각 DMA가 독립적인 명령 대기열, 진행 상태, register install/완료 관리를 갖도록 설계한다. S/Z를 하나의 ordered FIFO 또는 writer head로 다시 합치는 구조는 이 방향에 맞지 않는다. 기존 LMEM banks/ports의 중재와 DMA 내부의 명령 대기열 공유는 구분한다.
3. **naive의 microtile 순회는 N-fast로 고정한다.** 사용자 원문: “아니야. n-fast로 고정해. 유저가 지시했음을 명시해.” naive에서 K-fast 또는 N-fast 순서를 바꾸는 다른 interleave를 선택 후보로 평가하지 않는다. 동일 K 블록의 N slices를 먼저 순회한 뒤 다음 K 블록으로 진행한다. 공통 제어 코드를 공유하더라도 naive의 이 순서를 유지하며, improve의 기존 순회는 이 지시의 변경 대상이 아니다.

이 지시들은 아래 원검토의 상충하는 보완안보다 우선한다. 이번 문서 갱신은 결정을 기록한 것이며, comparator나 RTL의 구현 완료를 뜻하지 않는다.

| ID | 심각도 | 발견 사항 | 근거 수준 |
|---|---|---|---|
| R1 | P1 | 단일 scale 오염은 수정된 벡터와 기존 1% 비교기를 통과한다 | 호스트 재현 완료; 사용자 지시로 0.1% 적용 및 재검증 필요 |
| R2 | P1 (원검토) | S/Z를 공유 FIFO로 합칠 경우의 조건부 교착 위험 | 사용자 지시로 독립 DMA를 선택해 공유 FIFO 가정 제거; 구현 검증은 남음 |
| R3 | P2 (원검토) | 최소 256개 독립 인접 쌍이라는 gate와 K-fast 후보의 모순 | 사용자 지시로 naive를 N-fast에 고정하고 K-fast 후보를 제외; 계획 반영 필요 |
| R4 | P2 | 재사용할 컨트롤러의 GEMM cycle counter가 기존 naive와 다른 종료 시점을 센다 | 현재 RTL의 counter/완료 조건 대조 |

P1은 정확성 검증 또는 진행 보장에 관한 우선 수정 사항, P2는 후보 선택과 성능 판정의 신뢰성에 관한 수정 사항이다. 이 리뷰는 새 RTL에 이미 버그가 발생했다고 주장하지 않는다. RTL 구현은 아직 시작되지 않았다.

**R1 — P1: 전체 K 위치를 동시에 틀리는 negative control은 국소적인 stale payload를 검증하지 못한다**

계획 위치: [§7, 185–195행](plan.rev2.md#L185), [P0 종료 조건, 240행](plan.rev2.md#L240).

[현재 checker](check_test_vectors.cpp#L25)의 `wrong_scale`/`wrong_zero`는 모든 K 위치에서 다음 그룹/행을 선택한다. 따라서 “36개 대조군 모두 거부”는 광범위한 오염의 검출 증거다. 부분 lane, 응답 조립, register install에서 값 하나만 이전 세대 것으로 남는 오류의 검출 증거는 아니다. §7.2의 impulse/tagged 보강 조건도 주로 A/W의 주기적 주소 alias에 맞춰져 있으며, 허용 오차에 묻히는 국소 S/Z 오류를 필수 대상으로 지정하지 않는다.

다음 반례를 검토 당시 [생산 initializer](../../tests/regression/fpint_gemm_ffn_hw_naive/main.cpp#L210), 실제 packed W를 해독하는 별도 계산, [생산 comparator](../../tests/regression/fpint_gemm_ffn_hw_naive/main.cpp#L317)의 **기존 1% 기준**으로 실행했다.

- `M=4, K=512, N=512, QBLK=32, QDIR=0, WTRANS=0`.
- 기대값은 원래 payload로 고정한다.
- 실제 계산에만 `scales[1 * N + 0] = scales[0 * N + 0]`을 적용한다. K 그룹 1, 열 0의 scale 하나를 이전 그룹 값으로 바꾸는 오류다. 값은 `1.0625 → 1.0`이며 나머지 A/W/S/Z는 동일하다.
- 네 출력이 모두 달라지지만 2,048개 출력 전체에서 comparator rejection은 **0개**다.

| 출력 | 정상 FP16 값 | 오염 후 FP16 값 | 상대 오차 | 생산 비교기 |
|---|---:|---:|---:|---|
| C[0,0] | 3508 | 3498 | 0.2851% | PASS |
| C[1,0] | 1225 | 1222 | 0.2449% | PASS |
| C[2,0] | -218 | -216.625 | 0.6307% | PASS |
| C[3,0] | -832 | -829 | 0.3606% | PASS |

같은 방식으로 `kg=1..15`, `n=0..511`의 7,680개 단일 scale 오염을 조사했을 때 **1,390개는 FP16 결과가 바뀌어도 모든 출력이 PASS**였다. 이는 디바이스 fault injection 결과가 아니라, 현재 수치 oracle의 검출 한계를 재현한 호스트 결과다. 국소 오염이 모두 통과한다는 주장도 아니다.

**영향:** 잘못된 그룹/세대의 값 일부를 설치하는 구현이 정상 metadata를 동반하면, 현재 대조군과 기본 수치 검증을 모두 통과할 수 있다. “값이 K에 따라 다르다”와 “그 값의 잘못된 선택을 최종 출력에서 검출한다”는 별도 조건이다.

**사용자 지시 반영 후 필수 보완:** 먼저 수치 검증 기준을 0.1%로 적용하고 정상 벡터와 국소 오류 대조군을 재검증한다. 위 네 오차는 모두 0.1%보다 크므로 이 특정 반례는 새 기준에서 거부된다. 7,680개 전체 사례나 디바이스 정상 결과를 새 기준으로 재검증했다는 뜻은 아니다. P0의 fault 모델에는 단일 S/Z 원소, 실제 전송 lane/beat, 한 명령의 stale install을 명시한다. 새 기준에서도 검출하지 못하는 필요한 오류 모델이 있다면 sparse/impulse 벡터 또는 독립적인 install payload 검사로 보완한다. 수정된 기본 벡터와 이를 사용하는 성능 baseline은 유지한다.

변경 전의 최소 반례를 재현하려면 `check_test_vectors.cpp`의 `main()`에서 위 shape/mode를 설정한 뒤 다음을 실행하면 된다. 기존 helper를 사용하되, 역사적 반례가 향후 `FP16_TOL` 변경에 영향을 받지 않도록 아래 비교에만 기존 `0.01f`를 명시했다.

```cpp
std::vector<uint16_t> a, scales, expected;
std::vector<uint8_t> w;
std::vector<int16_t> zeros;
build_test_vectors(a, w, scales, zeros, expected, true);
assert(reference_from_payload(a, w, scales, zeros, false, false) == expected);
scales[N] = scales[0];
auto actual = reference_from_payload(a, w, scales, zeros, false, false);
unsigned changed = 0, rejected = 0;
for (size_t i = 0; i < actual.size(); ++i) {
  changed += actual[i] != expected[i];
  rejected += !compare_fp16(actual[i], expected[i], 0.01f); // 변경 전 1% 기준
}
assert(changed == 4 && rejected == 0);
```

**R2 — 원검토 P1, 사용자 설계 방향 확정: 공유 FIFO의 조건부 위험을 독립 S/Z DMA로 제거한다**

계획 위치: [§3, 62–64행](plan.rev2.md#L62), [§4.2, 93–101행](plan.rev2.md#L93), [§6, 177행](plan.rev2.md#L177), [P0 종료 조건](plan.rev2.md#L240), [P3](plan.rev2.md#L254).

원검토의 “공유 FIFO”는 S와 Z 명령/응답이 하나의 순서 있는 대기열 또는 register-install writer head를 공유하는 가정이다. 메모리나 arbiter를 공유한다는 사실만으로 이런 FIFO가 존재하는 것은 아니다. 계획은 S/Z child 분리와 기존 combined payload 저장소의 용량 제한을 요구했지만, 물리 실행기를 계속 공유할지 용량을 나누어 독립시킬지는 확정하지 않았다. 따라서 이를 확정된 공유 FIFO 설계의 결함처럼 읽히게 한 원검토 표현은 과도했다.

현재 naive는 [하나의 quant DMA](../../hw/rtl/core/gemm/VX_gemm_node_naive.sv#L1300)와 [한 install owner에 따른 S/Z 라우팅](../../hw/rtl/core/gemm/VX_gemm_node_naive.sv#L1197)을 사용한다. **improve에는 실제로 별도 scale DMA와 zero-point DMA가 있다.** [VX_tmem_subsystem.sv](../../hw/rtl/mem/VX_tmem_subsystem.sv#L979)의 `u_ldma_scale`과 `u_ldma_zero_point`는 각각 qparam executor를 인스턴스화하고, 별도의 command queue, response slots, writer fence를 갖는다. 이 두 실행기가 공유 writer head 하나를 사용한다고 주장하는 것이 아니다.

후속 지시 전에 검토한, **S/Z를 하나의 ordered 실행기에 합치는 경우에만 적용되는** QCOL 실행 예는 다음과 같다. `S(u)`/`Z(u)`는 명령 u의 scale/zero load이며, S(0)과 S(2)는 같은 register bank를 사용한다.

1. S(0)은 설치되었고 Z(0)의 source service만 일시적으로 늦어진다.
2. 독립 SC child가 먼저 진행해 S(1), S(2)를 공유 전송 실행기에 넘긴다. S(2)의 source read 자체는 허용된다.
3. S(2)가 공유 ordered writer head를 차지한 뒤, S(0)의 마지막 소비를 기다린다. 덮어쓰기 fence는 올바르게 동작하고 있다.
4. GEMM(0)은 Z(0)이 설치되어야 [zero consumer를 통과](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1736)하고 뒤의 [QCOL scale consumer](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1923)에 도달할 수 있다.
5. Z(0)의 일시적 source 지연을 해제해도, Z(0)은 S(2)가 점유한 공유 실행기 또는 writer head 뒤에서 설치를 기다린다.

```text
S(2)의 공유 writer 점유
  → S(0) consume 대기
  → GEMM(0)의 Z(0) 필요
  → Z(0) install에 공유 writer 필요
  → S(2)의 점유 해제 대기
```

이 반례는 shared adapter가 위 순서를 허용할 경우의 설계 위험이며, 기존 naive RTL에서 관측한 교착이 아니다. 사용자가 선택한 독립 DMA 구조에서는 S(2)가 자신의 scale writer에서 기다리는 동안 Z(0)이 별도 zero-point writer로 설치될 수 있으므로, 위 순환 대기의 공유 writer 조건이 사라진다. 이를 새 설계에 여전히 존재하는 교착으로 취급하지 않는다.

**사용자 지시 반영 후 필수 보완:** 공유 FIFO의 merge 규칙을 설계하는 기존 권고를 대체한다. naive에 독립 scale DMA와 zero-point DMA를 두고, 각자의 descriptor/response 소유권, writer fence, 완료 이벤트를 관리한다. 한쪽 writer가 막혔다는 이유로 다른 쪽의 요청/응답/설치를 전역 차단하지 않도록 한다. 기존 payload 총량 제약과 양립하는 각 DMA의 슬롯 배분 및 자원 비용을 P0 ledger에 명시한다. 독립 DMA를 갖는 것이 반드시 기존 저장 용량을 두 배로 복제한다는 뜻은 아니다. scale writer를 막은 동안 zero-point가 진행하는 경우와 그 반대 경우를 QCOL/QROW 통합 테스트로 확인한다. LMEM banks/ports의 기존 중재는 유지하며, improve 전용 TMEM readiness scheduler를 naive로 가져오지 않는다.

**R3 — 원검토 P2, 사용자 순회 정책 확정: naive를 N-fast로 고정한다**

계획 위치: [§5, 162행](plan.rev2.md#L162), [§8, 209–214행](plan.rev2.md#L209).

원래 계획은 K-fast를 같은 gate로 평가할 선택 후보로 남겼다. 그런데 “consecutive command pairs”를 인접 ordinal `(i, i+1)`로 해석하고, 같은 N slice 쌍을 제외하며, 256개 이상의 eligible pair를 요구하면 이 후보는 구조적으로 탈락한다. 아래 비교는 원검토의 근거로 보존하며, 후속 사용자 지시 이후 K-fast는 naive의 후보가 아니다.

필수 th16/MXU16, M4/K512/N512에서는 DMA tile 하나가 `8 K microtiles × 8 N slices = 64 Input commands`다. 현재 [K-fast 순서](../../hw/rtl/core/gemm/VX_gemm_fsm.sv#L1470)는 같은 N slice를 8명령 연속 방문한다. 지정된 512명령 중간 구간을 실제 순서대로 열거하고 출력 tile 경계를 제외하면 다음과 같다.

| 순회 | 전체 Input 수 | 선택 구간 | eligible 인접 쌍 |
|---|---:|---|---:|
| N-fast | 1,024 | 256–767 | 510 |
| K-fast | 1,024 | 256–767 | 62 |

K-fast는 overlap이 100%이고 latency gate를 통과해도 최소 표본 수 256을 채울 수 없다. 이는 PSUM latency를 측정해 내리는 판단과 무관하다. “다음 독립 명령”을 찾아 중간 명령을 건너뛴 쌍을 뜻했다면, 현재의 consecutive/제외 문구로는 그 매칭 알고리즘이 고정되지 않는다.

**사용자 지시 반영 후 필수 보완:** naive를 N-fast로 고정하고, 계획의 K-fast 및 다른 순회 후보 비교 문구를 제거한다. 순회 선택이나 K-fast에 맞춘 overlap gate 재정의는 수행하지 않는다. 고정된 N-fast 명령 순서에서 독립 인접 쌍과 출력 tile 경계 제외 규칙을 명시하고, 기존 수치 gate로 검증한다. 성능 개선은 이 순서를 유지한 admission/completion 분리와 합법적인 source read-ahead 범위에서 진행한다. 원검토의 후보/gate 모순은 정책 선택으로 해소되었으며, 실제 성능 gate 충족은 구현 후 검증할 사항이다.

**R4 — P2: GEMM cycle counter의 종료 경계가 바뀌므로 동일한 이름의 수치를 그대로 비교하면 안 된다**

계획 위치: [§8, 205–216행](plan.rev2.md#L205), [P0 baseline](plan.rev2.md#L238), [P5 perf wiring](plan.rev2.md#L268).

현재 naive의 [cycle counter](../../hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv#L364)는 `job_active_q` 동안 증가한다. 이 상태는 [done_if handshake](../../hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv#L79)에서 내려간다. 재사용할 common controller의 [cycle counter](../../hw/rtl/core/gemm/VX_gemm_ctrl.sv#L2560)는 `invocation_active_q || gemm_unit_computing`을 세는데, `invocation_active_q`는 [invocation_complete 시점](../../hw/rtl/core/gemm/VX_gemm_ctrl.sv#L1498)에 내려간다. 완료 통지가 받아들여지기 전에도 counter가 멈출 수 있다.

따라서 완료 통지의 `ready`를 지연시키면 같은 실제 계산/메모리 작업을 수행해도 기존 naive에는 그 대기가 포함되고 common 경로에는 포함되지 않는다. 항상 ready인 경우에도 종료 edge의 포함 규칙을 맞춰야 한다. 이 리뷰에서 실제 blackbox baseline에 큰 완료 backpressure가 있었다고 확인한 것은 아니다. **두 counter의 의미가 같지 않다는 사실**과, 그 정규화가 계획에 없다는 점이 문제다.

§8은 input-handshake density의 동일 endpoint는 요구하지만, 핵심 25%/1% latency gate의 GEMM start/end event와 edge 포함 규칙은 정하지 않는다. 더구나 perf wiring 수정은 P5에 배치되어 있어 P0에서 고정한 수치를 나중에 다른 의미의 counter로 비교할 여지가 있다. 별도의 whole-kernel gate는 GEMM counter 자체의 비교 가능성을 보장하지 않는다.

**필수 보완:** 계측 정규화를 P0로 옮긴다. 양쪽에서 공통으로 관측 가능한 cfg acceptance, 해당 invocation의 마지막 store completion, done-valid/handshake 중 어떤 경계를 측정하는지 명시하고, 누적 counter라면 per-job delta 규칙까지 고정한다. FSDB에서 동일 경계로 얻은 시간과 perf 수치가 일치하는지 대조한다. done backpressure를 넣은 대조군으로 계산 지연과 통지 전달 지연이 정의대로 분리되는지도 확인한 뒤 baseline을 고정해야 한다.

**판정의 범위와 검증 기록**

이전 리뷰에서 지적한 G1/O 분리, active-reset 비지원, TMEM scheduler 제외는 rev2에서 실질적으로 보완되었다. §4.4가 visibility endpoint와 source-generation join을 P0의 필수 선행 조건으로 명시한 점도 인정한다. 아직 P0를 실행하지 않았다는 이유만으로 같은 항목을 다시 결함으로 세지 않았다. R2의 공유 FIFO 반례는 역사적 조건부 지적으로 남기고, 현재 보완 요구는 사용자가 선택한 독립 DMA의 구현 및 진행 검증으로 변경했다.

검토는 관련 계획/기존 리뷰/RTL/호스트 코드의 정적 대조, R1의 호스트 C++ 재현, R3의 순서 열거로 수행했다. C++ 재현은 `/usr/bin/g++ -std=c++17 -O2 -ffunction-sections -fdata-sections`, `runtime/include` 및 기존 `build/hw`의 include, `-Wl,--gc-sections`를 사용했다. 먼저 정상 packed-payload 결과와 생산 기대값의 일치를 확인한 뒤 오염시켰다. VCS, FPGA, 합성, timing 검증은 실행하지 않았다.

재현 당시 검토 대상의 SHA-256:

```text
plan.rev2.md:
e96109f00e2674f9c479b5dc22c2cdf0075d80c33781f0f257b2a7210240661a
tests/regression/fpint_gemm_ffn_hw_naive/main.cpp:
a0253b5974d1fa4ac23618fe9db314de5538dfd07a3f22fd58d74e600e0d4cb4
```

요청한 `review.rev2.md`를 작성하고 후속 사용자 결정을 이 파일에 반영했다. 계획, STATUS.yaml, RTL, 기존 테스트와 사용자 worktree 변경은 수정하지 않았다. 실제 comparator의 0.1% 적용과 독립 S/Z DMA 구현은 후속 작업이다.
