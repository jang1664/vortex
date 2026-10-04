# Rev4 layout-fused 최적화 결과

2026-10-04. `candidate_fpga_bins.rev4.yaml`, HW, TH16/MXU16, FPGA `0000:2a:00.1`.
Standalone=C1, fused=C4. Benchmark는 warmup 1회 + 3회 측정의 median FPGA cycle이다.
Softmax standalone=`rev2_shuffle_grouped`, fused=`rev2_shuffle_cursor`.

## 변경과 원인

- Softmax cursor에만 행별 barrier 3회와 fence 2회를 제거했다. Overflow 경로의 종료 barrier도 제거했다.
  한 block은 한 warp이고, 각 warp는 독립된 LMEM partition을 쓴다. Scores는 같은 lane이 write/read하며 lane reduction은 register shuffle이다.
  Full-warp exp, butterfly reduction, FP16 변환, 주소 cursor와 수학적 연산은 유지했다.
  Baseline/수정 후 명령 수가 거의 같은 상태에서 cycle이 크게 감소했다. 현재 rev4에서 동기화 대기가 주요 비용임을 확인했다.
  Barrier와 fence 각각의 독립 기여도 및 이전 bitstream과의 RTL 차이 효과는 별도로 분리 측정하지 않았다.
- Elmul은 padding stride의 runtime ctz/table lookup을 곱셈으로 대체하고, 복잡한 padded-row 경로를 noinline helper로 분리했다.
  Compact 경로의 stack frame이 96B에서 32B로 감소했다. Tail의 함수 호출 비용은 아래 표에 함께 기록한다.
- Standalone kernel, RTL, config, 기본 variant와 numeric tolerance는 변경하지 않았다.

## 기본 regression pair

| Pair | 기존 fused cycles | 수정 fused cycles | 수정 standalone cycles | 기존 overhead | 수정 overhead | 기준 | 결과 |
|---|---:|---:|---:|---:|---:|---:|---|
| softmax/decode | 43,959 | 36,304 | 31,119 | 41.53% | 16.66% | 30% | PASS |
| softmax/prefill | 229,111 | 126,148 | 130,689 | 80.16% | -3.47% | 30% | PASS |
| softmax/tail_columns | 112,409 | 76,607 | 73,096 | 53.50% | 4.80% | 30% | PASS |
| elmul/decode | 43,526 | 34,657 | 28,023 | 56.76% | 23.67% | 50% | PASS |
| elmul/prefill | 83,397 | 68,101 | 60,383 | 37.68% | 12.78% | 50% | PASS |
| elmul/tail_rows | 76,934 | 84,668 | 61,259 | 25.42% | 38.21% | 50% | PASS |

Elmul tail fused cycles는 76,934 → 84,668(+10.05%)로 증가했다. Decode·prefill 개선과 교환한 비용이며 모든 측정 shape는 50% 기준을 통과했다.

## 추가 softmax 검증

| Shape | standalone cycles | fused cycles | overhead | 결과 |
|---|---:|---:|---:|---|
| softmax/mask_tail | 239,497 | 244,003 | 1.88% | PASS |
| softmax/overflow | 1,624,468 | 1,691,160 | 4.11% | PASS |
| softmax/prefill_1k | 9,919,593 | 10,130,426 | 2.13% | PASS |

- prefill_1k: B1/H1/Q1024/K1024/stride1024/mask1/scale0.125.
- overflow: B1/H1/Q1/K32769/stride32800/mask0/scale0.125; C4 warp별 score cache 한계를 넘는 경로.
- mask_tail: B1/H1/Q65/K129/stride160/mask1/scale0.125.
- Random seed 0, 1, 2986547050, 4294967295: B1/H1/Q32/K32/stride32/mask1. 모두 기능 PASS.

## 검증 범위와 원자료

- Softmax 기본 기능 6/6 + 추가 기능 10/10 PASS, FP16 예외 적용 없음. Overhead 기본 3/3 + 추가 3/3 PASS.
- 최종 Elmul 기능 6/6 PASS, FP16 예외 적용 없음. Overhead 3/3 PASS.
- 총 22회 최종 채택 구현 기능 검사와 9쌍 overhead 검사. `no_sync` 이후 softmax 코드는 설명 주석만 추가했다.
- 관련 없는 kernel은 다시 실행하지 않았다. 전체 78-case regression을 새로 실행한 결과로 표현하지 않는다.
- 개별 report의 `PARTIAL_PASS`는 app/case를 선택해 실행했기 때문이다. 선택한 검사는 모두 PASS다.
- [변경 전 전체 regression](../rev4_20261004/SUMMARY.md)
- [Softmax 기본](no_sync/SUMMARY.md)
- [Softmax 추가](extended/SUMMARY.md), [입력 정의](extended_cases.json)
- [Elmul 최종](elmul_split/SUMMARY.md)
- [Elmul stride만 수정한 중간 결과](elmul_stride/SUMMARY.md): decode 52.00%로 미통과였으며 최종 구현과 구분한다.

## 최종 source SHA-256

- `tests/regression/softmax_common/kernel.shuffle_cached.h`: `f4c141e993440413e647b4903c0c856185d1ea3821f97aead996cafb0608e082`
- `tests/regression/elmul_layout_fused/kernel.linear_skip_pad_rows.cpp`: `965f59b90a8723ffdf6169d117aa595678b2d6c332b25ec08b7317cb4cf004b4`
