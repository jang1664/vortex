# Normal vector vs layout-fused vector 최적화 공정성 audit

## 목적과 비교 기준

이 문서는 Llama 계열 E2E에서 C3 normal vector와 C4 layout-fused
vector를 공정하게 비교하기 위한 다음 작업 목록이다.

여기서 용어는 다음과 같이 고정한다.

- **normal vector**: C3에서 사용하는 row-major vector kernel
- **layout-fused vector**: C4에서 tiled input/output을 직접 처리하는
  `*_layout_fused` kernel
- **공정한 비교**: 두 kernel이 동일한 논리 연산과 정밀도를 수행하고,
  각 layout에 적합한 최선의 mapping/reduction/address 최적화를 적용한
  상태

Normal kernel에 별도의 tiling kernel latency를 더하는 C4-alone
pipeline 비교가 아니다. Normal과 layout-fused 단일 vector kernel을
비교한다.

아래 수치는 stale `raw_db.csv`가 아니라 당시 current source를 직접
C4 hardware에서 실행해 얻은 대표 shape 결과다. 최종 C3-vs-C4
판정에서는 각 normal kernel을 C3, layout-fused kernel을 C4에서 다시
측정해야 한다.

## 우선순위 요약

| 우선순위 | Kernel | 판정 | 핵심 원인 |
| ---: | --- | --- | --- |
| 1 | SILU | 최적화 수준 불공정 확정 | Normal이 M row를 바깥 loop로 순회하며 K 방향만 분산 |
| 2 | RMSNorm | Benchmark 불공정 확정 | Normal bench가 prefill에도 항상 128 threads를 launch |
| 3 | Softmax | 최적화 variant 불공정 확정 | Normal은 cached reduction, fused는 shuffle-grouped |
| 완료 | KV cache quantization | 해결 완료 | Semantics 불일치와 normal prefill mapping 문제 수정 |
| 완료 | Hadamard | 해결 완료 | 양쪽 factorized 단일-kernel 경로와 최적화 정렬 |
| 관찰 | Head concat | 불공정 미확정 | Tiled locality의 실제 이점일 가능성이 큼 |

다음 세션에서는 SILU부터 시작하고, RMSNorm benchmark 수정,
Softmax 순서로 진행하는 것이 좋다.

---

## 1. SILU: normal kernel 최적화 부족

### Fresh hardware 증거

| Shape | Normal SILU | Layout-fused SILU | Fused / normal |
| --- | ---: | ---: | ---: |
| Generation, M=1, K=14336 | 612,206 | 532,591 | 0.87x |
| Prefill, M=1024, K=14336 | 414,878,074 | 188,866,290 | 0.46x |

Layout-fused kernel을 row-major 입출력으로 실행한 통제 실험도 normal보다
빨랐다.

| Shape | Normal SILU | Fused implementation의 row variant |
| --- | ---: | ---: |
| M=1, K=14336 | 612,206 | 461,213 |
| M=1024, K=14336 | 414,878,074 | 243,905,981 |

따라서 차이 전체를 tiled layout의 이점으로 설명할 수 없다. Normal
SILU의 implementation/mapping이 뒤처져 있다.

### 코드상 원인

- Normal `tests/regression/silu/kernel_v2.cpp`
  - 각 thread가 모든 M row를 바깥 loop로 순회한다.
  - 한 row 안에서 K chunk만 thread에 분산한다.
  - Prefill에서 row-level parallelism을 활용하지 못한다.
- Fused `tests/regression/silu_layout_fused/kernel_v2.cpp`
  - linear tiled/skip-padding fast path가 있다.
  - 전체 logical tensor를 flat global thread ID로 분산한다.

측정된 prefill IPC도 normal 약 2.90, fused 약 6.91로 큰 차이가 났다.

### 다음 구현 방향

1. Normal row-major tensor 전체를 flat grid-stride loop로 처리한다.
2. `index = global_thread_id; index < M*K; index += total_threads` 형태로
   M과 K를 함께 병렬화한다.
3. `kernel_v1.cpp`의 단순 flat mapping을 참고하되 현재 FP16 pair/vector
   load/store와 activation 계산은 유지한다.
4. Generation과 prefill에 같은 mapping을 강제하지 말고 shape에 따라
   adaptive path가 필요한지 C3 hardware에서 판단한다.
5. 정확성 통과 후 C3 normal과 C4 fused를 동일 M/K로 재측정한다.

### 완료 조건

- M=1과 M=1024 correctness 통과
- Normal prefill이 fused row variant와 비슷한 instruction/mapping 수준
- 최종 C3 normal vs C4 fused overhead를 새로 기록

---

## 2. RMSNorm: normal benchmark launch가 불공정

### Fresh hardware 증거

| Shape | Normal bench | Layout-fused | 비고 |
| --- | ---: | ---: | --- |
| Generation, M=1, K=4096 | 158,741 | 171,807 | Normal이 빠름 |
| Prefill, M=1024, K=4096 | 83,372,099 | 66,215,457 | Normal bench가 느림 |

하지만 normal correctness host의 adaptive launch를 사용해 같은
M=1024/K=4096을 실행하면 **59,527,586 cycles**였다. 이는
layout-fused 66,215,457보다 빠르다.

따라서 이 항목은 kernel algorithm보다 benchmark host 설정 문제다.

### 코드상 원인

- `tests/regression/rmsnorm/bench_main.cpp`
  - 항상 `num_warps * num_threads`, 즉 대표 C4 설정에서 128 threads를
    launch한다.
- `tests/regression/rmsnorm/main.cpp`
  - token 수가 충분하면 한 warp, 즉 32 threads를 사용하는 adaptive
    launch가 이미 있다.
- `tests/regression/rms_norm_layout_fused/bench_main.cpp`
  - prefill에서 adaptive one-warp launch를 사용한다.

Normal benchmark만 다른 launch policy를 사용하므로 raw DB 비교가
불공정해진다.

### 다음 구현 방향

1. Normal `main.cpp`의 adaptive launch 계산을 `bench_main.cpp`와 공유한다.
2. 가능하면 작은 inline host helper로 분리해 correctness/benchmark
   drift를 막는다.
3. Generation M=1과 prefill M=1024 모두 C3에서 재측정한다.
4. 이전 normal RMSNorm raw DB row는 stale 처리한다.

### 완료 조건

- `main`과 `bench_main`이 동일한 grid/block 계산 사용
- C3 prefill benchmark가 correctness host 실행과 유사한 cycle
- Layout-fused와 비교할 때 launch 차이가 제거됨

---

## 3. Softmax: normal reduction variant가 뒤처짐

### Fresh hardware 증거

| Shape | Normal Softmax | Layout-fused Softmax | Fused / normal |
| --- | ---: | ---: | ---: |
| Generation, B=1 H=32 Q=1 K=4096 | 721,250 | 544,733 | 0.76x |
| Prefill, B=1 H=32 Q=1024 K=1024 | 592,487,976 | 624,809,105 | 1.05x |

Generation에서는 fused가 약 24.5% 빠르지만 prefill에서는 fused가 약
5.5% 느리다. 이는 layout 자체보다 reduction implementation 차이가
generation에서 크게 작용한다는 신호다.

### 코드상 원인

- Normal default:
  - `SOFTMAX_VARIANT=rev2`
  - `softmax_common/kernel.simt_cached.h`
  - local/shared-memory reduction과 barrier 사용
- Layout-fused default:
  - `SOFTMAX_LAYOUT_FUSED_VARIANT=rev2_shuffle_grouped`
  - warp shuffle reduction
  - grouped load/store

두 kernel 모두 one-warp execution이지만 normal에는 fused에서 이미
검증한 shuffle-grouped reduction이 없다.

### 다음 구현 방향

1. Fused `rev2_shuffle_grouped`의 softmax math/reduction core를 normal
   row-major accessor와 결합한다.
2. Normal에 `rev2_shuffle_grouped` variant를 추가하고 hardware
   비교 후 default 승격 여부를 결정한다.
3. Mask, tail K, causal prefill correctness를 모두 유지한다.
4. Generation K=4096과 prefill Q/K=1024를 C3에서 재측정한다.

### 완료 조건

- Normal generation에서 barrier/local-memory reduction overhead 제거
- Masked generation과 causal prefill correctness 통과
- Normal과 fused의 차이가 주로 tiled load/store 비용만 반영

---

## 4. KV cache quantization: 해결 완료

이전에는 normal과 layout-fused가 다음 면에서 공정하지 않았다.

- Normal은 legacy unsigned asymmetric 중심
- Fused K는 SpinQuant signed asymmetric
- Fused V는 SpinQuant signed symmetric
- Normal prefill은 warp-per-group mapping으로 병렬성이 제한됨
- Fused는 qparam reuse와 tiled source/weight cursor 사용

수정 후 normal에도 동일한 K/V SpinQuant semantics를 추가하고 다음
adaptive mapping을 적용했다.

- Generation: warp-per-group
- Prefill: thread-per-group

최종 Llama3-8B C3 normal vs C4 fused 결과:

| Cache / stage | C3 normal | C4 fused | C4 overhead |
| --- | ---: | ---: | ---: |
| K generation | 75,162 | 93,600 | 24.5% |
| V generation | 74,644 | 90,620 | 21.4% |
| K prefill, K=1024 | 2,382,697 | 2,971,772 | 24.7% |
| V prefill, K=1024 | 2,390,236 | 3,208,283 | 34.2% |

남은 차이는 tiled source cursor, tiled weight scatter, qparam slot
replication/addressing 같은 C4 layout work다. 상세 내용은
`docs/kernel/optimizations/kv_normal_vs_layout_fused_fairness.md`에 있다.

---

## 5. Hadamard: 해결 완료

Hadamard는 양쪽 모두 factorized 단일-kernel 경로를 사용하도록
정리했다.

- K가 power of two면 base stage를 skip
- non-power-of-two면 butterfly와 base를 같은 kernel에서 처리
- standalone의 불필요한 두 번째 launch/intermediate tensor 제거
- layout-fused도 동일한 factorized 의미 사용

대표 C4 동일-hardware 진단에서 fused overhead는 대략 1--4%였다.
현재는 normal 쪽이 의도적으로 덜 최적화된 항목으로 보지 않는다.

---

## 6. Head concat: watchlist, 불공정으로 확정하지 않음

Fresh C4 결과:

| Shape | Normal | Layout-fused | Fused / normal |
| --- | ---: | ---: | ---: |
| Generation, B1 S1 H32 D128 | 169,378 | 208,749 | 1.23x |
| Prefill, B1 S1024 H32 D128 | 13,116,845 | 11,852,548 | 0.90x |

두 구현 모두 전체 element를 flat global thread mapping으로 처리한다.
Prefill에서 fused가 약 9.6% 빠른 것은 tiled input/output의 locality
이점일 가능성이 크며, SILU처럼 명확한 normal mapping 누락은 아직
발견되지 않았다.

SILU/RMSNorm/Softmax 수정 후에도 E2E 우선순위가 높으면 다음 통제
실험을 수행한다.

- 동일 row-major layout을 사용하는 fused compute variant
- 동일 launch/grid 조건
- instruction, IPC, memory stall 비교

---

## 불공정 문제가 발견되지 않은 kernel

다음 kernel은 fresh 대표 측정에서 layout-fused가 normal보다 느리거나,
normal에 명확히 빠진 optimization이 발견되지 않았다.

- `eladd`
- `elmul`
- `rope`
- 현재 factorized `hadamard`

이 항목들은 C4 fused overhead 최적화 대상일 수는 있지만,
**normal이 덜 최적화돼 비교가 불공정한 항목**은 아니다.

## 다음 세션 권장 순서

1. SILU normal flat/adaptive mapping 구현
2. C3 correctness와 M=1/M=1024 fresh benchmark
3. RMSNorm benchmark launch를 correctness host와 통합
4. C3 RMSNorm generation/prefill 재측정
5. Softmax normal shuffle-grouped variant 구현
6. C3/C4 softmax generation/prefill 재측정
7. 세 kernel의 stale raw DB row 삭제 후 suite 재실행
8. Llama E2E weighted contribution을 다시 계산

