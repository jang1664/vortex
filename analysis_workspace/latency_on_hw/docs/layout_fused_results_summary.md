# C4_v3 vector layout-fused kernel overhead summary

## 결론

`C4_v3/raw_db.csv`에서 normal kernel과 대응되는 layout-fused kernel을 같은
shape끼리 비교했다. 주 지표는 커널 자체 비용을 가장 직접적으로 나타내는
`fpga_cycle`이며, 아래 overhead는 다음과 같이 계산했다.

```text
overhead (%) = (layout_fused / normal - 1) * 100
```

- 양수는 layout-fused가 느리다는 뜻이고, 음수는 layout-fused가 더 빠르다는
  뜻이다.
- 전반적인 병목은 `rope_layout_fused`, `rms_norm_layout_fused`, prefill의
  `kv_cache_quant_layout_fused_w4a16`, 그리고 작은 decode shape의
  `hadamard_layout_fused`이다.
- `softmax_layout_fused`는 대부분의 decode shape에서 약 `+3.9%`로 비교적
  일정한 overhead를 보인다.
- `elmul_layout_fused`와 `hadamard_layout_fused`는 prefill에서 normal과 거의
  동일하지만, 작은 decode shape에서는 overhead가 커진다.
- The original SiLU rows showed an apparent `-77%` prefill cycle reduction,
  but that result came from the normal kernel's `chunk32` traversal. After
  switching normal SiLU to the new default `linear` variant, fused prefill
  overhead is only `+0.68%` for Llama2 and `+0.82%` for Llama3 by median.
- 이 결과는 **standalone kernel끼리의 비교**다. layout-fused graph가 제거하는
  별도의 detile/retile kernel 비용은 포함하지 않았으므로, graph 전체의
  end-to-end 손익과 같지는 않다.

## SiLU traversal fix and C4_v3 remeasurement

The original `silu` kernel assigned one 32-element chunk to each lane and
processed the chunk serially. The layout-fused default used an element-wise
linear grid-stride loop, so the old normal-versus-fused result also measured a
large coalescing/traversal difference.

The normal SiLU build now provides two variants:

- `SILU_VARIANT=linear` (default): consecutive lanes process consecutive
  elements.
- `SILU_VARIANT=chunk32`: retains the previous traversal for A/B testing.

Both variants passed the C4_v3 hardware correctness test at `n=8201`. The
following results were then measured on C4_v3 with `warmup=0`, `iterations=1`,
the normal default `linear` variant, and the layout-fused
`linear_skip_pad_rows` variant. The primary comparison uses FPGA cycles.

### Llama2 SiLU rerun (`K=11008`)

| Phase | M | Normal cycle | Fused cycle | Fused/normal | Cycle overhead | Normal `avg_us` | Fused `avg_us` |
|---|---:|---:|---:|---:|---:|---:|---:|
| prefill | 1024 | 32,745,052 | 32,988,366 | 1.0074x | +0.74% | 345,851.763 | 348,030.729 |
| prefill | 2048 | 65,436,913 | 65,946,223 | 1.0078x | +0.78% | 689,727.625 | 695,070.188 |
| prefill | 4096 | 130,703,978 | 131,297,129 | 1.0045x | +0.45% | 1,376,757.961 | 1,383,638.256 |
| prefill | 8192 | 261,192,185 | 262,819,605 | 1.0062x | +0.62% | 2,750,482.673 | 2,767,231.891 |
| prefill | 16384 | 522,283,453 | 525,087,898 | 1.0054x | +0.54% | 5,499,137.170 | 5,528,016.195 |
| prefill | 32768 | 1,044,215,768 | 1,052,288,747 | 1.0077x | +0.77% | 10,993,155.768 | 11,078,243.883 |
| decode | 1 | 115,827 | 148,671 | 1.2836x | +28.36% | 2,693.483 | 2,691.360 |
| decode | 2 | 154,528 | 208,867 | 1.3516x | +35.16% | 2,692.112 | 3,747.155 |
| decode | 4 | 217,993 | 281,186 | 1.2899x | +28.99% | 3,760.644 | 3,748.699 |
| decode | 64 | 2,151,827 | 2,188,883 | 1.0172x | +1.72% | 23,951.652 | 23,770.668 |

- Prefill cycle overhead: median `+0.68%`, range `+0.45%` to `+0.78%`.
- Decode cycle overhead: median `+28.67%`, range `+1.72%` to `+35.16%`.

### Llama3 SiLU rerun (`K=14336`)

| Phase | M | Normal cycle | Fused cycle | Fused/normal | Cycle overhead | Normal `avg_us` | Fused `avg_us` |
|---|---:|---:|---:|---:|---:|---:|---:|
| prefill | 1024 | 42,612,825 | 43,162,776 | 1.0129x | +1.29% | 449,368.528 | 455,569.615 |
| prefill | 2048 | 85,097,852 | 86,458,717 | 1.0160x | +1.60% | 896,869.266 | 911,004.001 |
| prefill | 4096 | 170,166,772 | 171,842,755 | 1.0098x | +0.98% | 1,792,577.279 | 1,810,318.081 |
| prefill | 8192 | 340,065,533 | 341,912,110 | 1.0054x | +0.54% | 3,580,875.957 | 3,600,607.642 |
| prefill | 16384 | 680,433,854 | 683,176,489 | 1.0040x | +0.40% | 7,163,978.958 | 7,192,374.859 |
| prefill | 32768 | 1,359,966,578 | 1,368,985,283 | 1.0066x | +0.66% | 14,316,975.293 | 14,411,695.903 |
| decode | 1 | 130,950 | 177,609 | 1.3563x | +35.63% | 2,692.720 | 2,697.030 |
| decode | 2 | 174,468 | 225,500 | 1.2925x | +29.25% | 2,659.550 | 3,745.861 |
| decode | 4 | 258,085 | 330,022 | 1.2787x | +27.87% | 3,745.734 | 4,772.779 |
| decode | 64 | 2,764,266 | 2,883,258 | 1.0430x | +4.30% | 30,118.762 | 31,184.234 |

- Prefill cycle overhead: median `+0.82%`, range `+0.40%` to `+1.60%`.
- Decode cycle overhead: median `+28.56%`, range `+4.30%` to `+35.63%`.

The old SiLU entries in the raw-DB summary and outlier inventory below are
retained as pre-fix historical data. They must not be used as the current SiLU
layout overhead.

## 전체 shape 요약

각 셀의 `%` 값은 shape별 cycle overhead의 **median [min, max]**이다. `증가`는
layout-fused cycle이 normal보다 큰 shape 수를 나타낸다. `avg_us`는 host/runtime
고정 비용도 포함하므로 참고 지표로 병기했다.

### Llama2

| Normal → layout-fused | 비교 수 | FPGA cycle overhead | 증가 | `avg_us` overhead |
|---|---:|---:|---:|---:|
| `eladd` → `eladd_layout_fused` | 10 | +13.24% [+11.61%, +79.84%] | 10/10 | +13.08% [+12.91%, +79.19%] |
| `elmul` → `elmul_layout_fused` | 10 | +0.17% [-0.13%, +44.05%] | 5/10 | +0.09% [-0.14%, +39.74%] |
| `hadamard` → `hadamard_layout_fused` | 20 | -1.20% [-4.01%, +619.10%] | 8/20 | -1.23% [-3.98%, +593.37%] |
| `head_concat` → `head_concat_layout_fused` | 10 | -4.05% [-11.53%, +21.92%] | 3/10 | -4.06% [-9.69%, +39.09%] |
| `kv_cache_quant_w4a16` → `kv_cache_quant_layout_fused_w4a16` | 24 | +29.93% [-5.07%, +130.83%] | 12/24 | +27.66% [-0.82%, +130.38%] |
| `rmsnorm` → `rms_norm_layout_fused` | 10 | +38.23% [+24.96%, +41.84%] | 10/10 | +38.22% [-1.06%, +41.71%] |
| `rope` → `rope_layout_fused` | 30 | +94.88% [+48.32%, +105.86%] | 30/30 | +50.17% [+28.64%, +79.16%] |
| `silu` (`chunk32`, pre-fix) → `silu_layout_fused` | 10 | -76.61% [-77.18%, -44.15%] | 0/10 | -76.60% [-77.18%, -28.14%] |
| `softmax` → `softmax_layout_fused` | 294 | +3.90% [-4.25%, +11.21%] | 292/294 | +3.90% [-4.25%, +17.28%] |

### Llama3

| Normal → layout-fused | 비교 수 | FPGA cycle overhead | 증가 | `avg_us` overhead |
|---|---:|---:|---:|---:|
| `eladd` → `eladd_layout_fused` | 10 | +13.84% [+10.55%, +78.89%] | 10/10 | +13.90% [+11.47%, +79.07%] |
| `elmul` → `elmul_layout_fused` | 10 | +0.09% [+0.00%, +41.48%] | 10/10 | +0.07% [-0.94%, +40.65%] |
| `hadamard` → `hadamard_layout_fused` | 30 | +5.55% [-1.48%, +625.30%] | 20/30 | +5.54% [-1.47%, +596.18%] |
| `head_concat` → `head_concat_layout_fused` | 10 | -4.97% [-11.12%, +23.30%] | 3/10 | -4.98% [-15.73%, +39.32%] |
| `kv_cache_quant_w4a16` → `kv_cache_quant_layout_fused_w4a16` | 24 | +33.73% [-1.07%, +129.87%] | 23/24 | +27.70% [-1.36%, +129.39%] |
| `rmsnorm` → `rms_norm_layout_fused` | 10 | +40.60% [+19.48%, +44.86%] | 10/10 | +40.67% [-4.49%, +44.78%] |
| `rope` → `rope_layout_fused` | 60 | +95.59% [+41.54%, +112.21%] | 60/60 | +46.07% [+28.21%, +130.13%] |
| `silu` (`chunk32`, pre-fix) → `silu_layout_fused` | 10 | -76.93% [-77.19%, -46.33%] | 0/10 | -76.92% [-77.18%, -43.90%] |
| `softmax` → `softmax_layout_fused` | 294 | +3.91% [-3.57%, +12.15%] | 292/294 | +3.88% [-3.57%, +17.71%] |

## Prefill과 decode 구분

전체 median은 prefill/decode shape 구성이 서로 달라 성능 특성을 가릴 수 있다.
아래는 FPGA cycle overhead를 phase별로 나눈 결과다.

### Llama2

| Layout-fused kernel | Prefill: 비교 수, median [min, max] | Decode: 비교 수, median [min, max] |
|---|---:|---:|
| `eladd_layout_fused` | 6, +13.11% [+12.94%, +13.41%] | 4, +26.55% [+11.61%, +79.84%] |
| `elmul_layout_fused` | 6, -0.06% [-0.13%, +0.38%] | 4, +30.94% [+1.61%, +44.05%] |
| `hadamard_layout_fused` | 12, -1.96% [-3.37%, +0.89%] | 8, +92.91% [-4.01%, +619.10%] |
| `head_concat_layout_fused` | 6, -4.49% [-7.98%, -2.20%] | 4, +17.60% [-11.53%, +21.92%] |
| `kv_cache_quant_layout_fused_w4a16` | 12, +90.65% [+60.47%, +130.83%] | 12, -3.32% [-5.07%, -0.61%] |
| `rms_norm_layout_fused` | 6, +38.97% [+37.78%, +41.84%] | 4, +29.44% [+24.96%, +41.50%] |
| `rope_layout_fused` | 6, +54.33% [+48.32%, +58.63%] | 24, +96.06% [+50.01%, +105.86%] |
| `silu_layout_fused` (pre-fix normal) | 6, -76.88% [-77.18%, -76.51%] | 4, -55.73% [-75.91%, -44.15%] |
| `softmax_layout_fused` | 6, +2.89% [-4.25%, +11.21%] | 288, +3.90% [+2.14%, +10.98%] |

### Llama3

| Layout-fused kernel | Prefill: 비교 수, median [min, max] | Decode: 비교 수, median [min, max] |
|---|---:|---:|
| `eladd_layout_fused` | 6, +13.79% [+13.56%, +14.35%] | 4, +27.09% [+10.55%, +78.89%] |
| `elmul_layout_fused` | 6, +0.02% [+0.00%, +0.14%] | 4, +26.08% [+1.37%, +41.48%] |
| `hadamard_layout_fused` | 18, -0.22% [-1.48%, +5.78%] | 12, +139.56% [+7.19%, +625.30%] |
| `head_concat_layout_fused` | 6, -5.52% [-6.31%, -3.33%] | 4, +16.85% [-11.12%, +23.30%] |
| `kv_cache_quant_layout_fused_w4a16` | 12, +90.62% [+61.35%, +129.87%] | 12, +2.32% [-1.07%, +6.12%] |
| `rms_norm_layout_fused` | 6, +40.97% [+40.36%, +44.86%] | 4, +29.59% [+19.48%, +40.63%] |
| `rope_layout_fused` | 12, +51.54% [+41.54%, +59.98%] | 48, +98.58% [+49.66%, +112.21%] |
| `silu_layout_fused` (pre-fix normal) | 6, -77.02% [-77.19%, -76.92%] | 4, -58.75% [-76.21%, -46.33%] |
| `softmax_layout_fused` | 6, +5.21% [-3.57%, +12.15%] | 288, +3.91% [+2.24%, +11.45%] |

## 해석

1. **RoPE가 가장 일관된 overhead다.** 두 모델 모두 모든 대응 shape에서
   느려졌고, cycle 기준 prefill은 약 `+42~60%`, decode median은 약
   `+96~99%`다. `avg_us` overhead가 cycle overhead보다 작게 보이는 것은
   runtime 고정 비용의 영향이며, 커널 최적화 우선순위는 cycle을 기준으로
   잡는 편이 적절하다.
2. **RMSNorm도 모든 shape에서 cycle regression이다.** median은 Llama2
   `+38.23%`, Llama3 `+40.60%`다.
3. **KV-cache quant는 phase별 양상이 반대다.** Prefill median은 두 모델 모두
   약 `+90.6%`지만, decode는 Llama2 `-3.32%`, Llama3 `+2.32%`로 normal과
   비슷하다.
4. **Hadamard는 prefill에서는 사실상 동등하다.** 그러나 작은 decode shape의
   고정 address-generation 비용 때문에 median이 Llama2 `+92.91%`, Llama3
   `+139.56%`, 최악에는 약 `+625%`까지 증가한다. 절대 workload가 매우 작은
   shape의 비율이므로 percentage만으로 전체 latency 영향을 판단하면 안 된다.
5. **Elmul 역시 prefill에서는 동등하고 decode에서만 느려진다.** 반면
   `head_concat_layout_fused`는 prefill에서 약 `4~6%` 빠르다.
6. **The original SiLU comparison was invalid as a layout-overhead result.**
   It compared the normal `chunk32` traversal against the fused linear
   traversal. The corrected results are reported in the rerun section above.
7. 모든 대응 행을 단순히 합친 median은 Llama2 `+4.64%` (418쌍), Llama3
   `+5.04%` (458쌍)지만, 각각 294쌍인 softmax가 통계를 지배하므로 kernel
   전체의 대표값으로 사용하지 않는 것이 좋다.

## 디버깅 대상: 예상 범위를 벗어난 모든 case (original raw DB)

This inventory is based on the original raw DB. Its SiLU entries are retained
only to document the traversal bug; the corrected SiLU results are above.
Hadamard, Head Concat, SiLU에 대해서 다음을 정상 범위로 가정했다.

```text
1.0x <= layout_fused / normal <= 2.0x
```

즉 layout-fused가 normal보다 빠른 case(`< 1.0x`)와 2배를 초과하여 느린
case(`> 2.0x`)를 모두 아래에 기록했다. 판정 기준은 `fpga_cycle`이며,
`ratio = fused cycle / normal cycle`이다. 총 67건이다.

| Kernel | Llama2 | Llama3 | 합계 |
|---|---:|---:|---:|
| Hadamard | 16 (빠름 12, 2배 초과 4) | 17 (빠름 10, 2배 초과 7) | 33 |
| Head Concat | 7 (모두 빠름) | 7 (모두 빠름) | 14 |
| SiLU | 10 (모두 빠름) | 10 (모두 빠름) | 20 |

### Hadamard: Llama2

| Phase | Normal shape (`rows x dim`) | Fused shape (`m x n x k`) | Normal cycle | Fused cycle | Ratio | Overhead |
|---|---:|---:|---:|---:|---:|---:|
| prefill | 1024 x 11008 | 1024 x 1 x 11008 | 1,699,496,827 | 1,648,565,337 | 0.970x | -3.00% |
| prefill | 65536 x 128 | 2048 x 32 x 128 | 73,405,385 | 73,133,794 | 0.996x | -0.37% |
| prefill | 2048 x 11008 | 2048 x 1 x 11008 | 3,393,201,731 | 3,285,687,752 | 0.968x | -3.17% |
| prefill | 131072 x 128 | 4096 x 32 x 128 | 146,775,734 | 145,212,994 | 0.989x | -1.06% |
| prefill | 4096 x 11008 | 4096 x 1 x 11008 | 6,747,137,117 | 6,562,673,688 | 0.973x | -2.73% |
| prefill | 262144 x 128 | 8192 x 32 x 128 | 293,350,734 | 289,411,210 | 0.987x | -1.34% |
| prefill | 8192 x 11008 | 8192 x 1 x 11008 | 13,504,961,114 | 13,192,541,539 | 0.977x | -2.31% |
| prefill | 524288 x 128 | 16384 x 32 x 128 | 586,671,069 | 577,948,544 | 0.985x | -1.49% |
| prefill | 16384 x 11008 | 16384 x 1 x 11008 | 26,997,961,969 | 26,301,434,921 | 0.974x | -2.58% |
| prefill | 1048576 x 128 | 32768 x 32 x 128 | 1,173,346,003 | 1,154,565,598 | 0.984x | -1.60% |
| prefill | 32768 x 11008 | 32768 x 1 x 11008 | 53,991,323,371 | 52,172,087,401 | 0.966x | -3.37% |
| decode | 32 x 128 | 1 x 32 x 128 | 121,322 | 344,312 | 2.838x | +183.80% |
| decode | 64 x 128 | 1 x 64 x 128 | 156,429 | 603,937 | 3.861x | +286.08% |
| decode | 128 x 128 | 1 x 128 x 128 | 227,340 | 1,138,858 | 5.009x | +400.95% |
| decode | 2048 x 128 | 1 x 2048 x 128 | 2,364,713 | 17,004,691 | 7.191x | +619.10% |
| decode | 64 x 11008 | 64 x 1 x 11008 | 107,603,710 | 103,286,814 | 0.960x | -4.01% |

Normal Hadamard의 추가 option은 `dim=128` case에서 `K=1`, `dim=11008`
case에서 `K=172`다. Fused의 `k=11008` case에는
`--layout-from gemm_a_tiled`이 사용됐다.

### Hadamard: Llama3

| Phase | Normal shape (`rows x dim`) | Fused shape (`m x n x k`) | Normal cycle | Fused cycle | Ratio | Overhead |
|---|---:|---:|---:|---:|---:|---:|
| prefill | 65536 x 128 | 2048 x 32 x 128 | 73,237,290 | 73,094,144 | 0.998x | -0.20% |
| prefill | 16384 x 128 | 2048 x 8 x 128 | 18,371,249 | 18,325,731 | 0.998x | -0.25% |
| prefill | 131072 x 128 | 4096 x 32 x 128 | 146,473,389 | 145,288,561 | 0.992x | -0.81% |
| prefill | 32768 x 128 | 4096 x 8 x 128 | 36,700,198 | 36,342,763 | 0.990x | -0.97% |
| prefill | 262144 x 128 | 8192 x 32 x 128 | 292,772,442 | 289,468,476 | 0.989x | -1.13% |
| prefill | 65536 x 128 | 8192 x 8 x 128 | 73,237,290 | 72,392,688 | 0.988x | -1.15% |
| prefill | 524288 x 128 | 16384 x 32 x 128 | 585,454,533 | 577,642,954 | 0.987x | -1.33% |
| prefill | 131072 x 128 | 16384 x 8 x 128 | 146,473,389 | 144,533,555 | 0.987x | -1.32% |
| prefill | 1048576 x 128 | 32768 x 32 x 128 | 1,170,755,410 | 1,153,482,028 | 0.985x | -1.48% |
| prefill | 262144 x 128 | 32768 x 8 x 128 | 292,772,442 | 288,660,151 | 0.986x | -1.40% |
| decode | 32 x 128 | 4 x 8 x 128 | 123,131 | 340,560 | 2.766x | +176.58% |
| decode | 64 x 128 | 4 x 16 x 128 | 156,702 | 607,189 | 3.875x | +287.48% |
| decode | 16 x 128 | 1 x 16 x 128 | 103,446 | 209,523 | 2.025x | +102.54% |
| decode | 128 x 128 | 4 x 32 x 128 | 227,276 | 1,139,151 | 5.012x | +401.22% |
| decode | 32 x 128 | 1 x 32 x 128 | 123,131 | 342,000 | 2.778x | +177.75% |
| decode | 2048 x 128 | 4 x 512 x 128 | 2,359,881 | 17,116,118 | 7.253x | +625.30% |
| decode | 512 x 128 | 1 x 512 x 128 | 654,101 | 4,314,453 | 6.596x | +559.60% |

이 표의 normal Hadamard option은 모두 `K=1`이다. Llama3의 `dim=14336,
K=28` 계열은 모두 정상 범위에 들어와 이 표에는 없다.

### Head Concat: 모든 비정상 case

Fused args에는 아래 shape에 공통으로 `--layout-to gemm_a_tiled`이 추가된다.
Llama3 decode에는 실제 GQA PV layout을 반영하기 위해
`-query-heads-per-kv 4`도 추가된다. 기존 측정은 이 값이 workload의 shape
metadata에만 있고 실행 args에는 빠져 있어 `q_per_kv=1` layout을 측정했다.
아래 Llama3 decode 수치는 benchmark와 workload argument propagation을 고친
뒤 `C4_v3`, `warmup=0`, `iterations=3`으로 다시 측정한 값이다.

#### Llama3 decode GQA 수정 후 전체 결과

| Batch | Normal cycle | Fused cycle | Ratio | Overhead | Normal IPC | Fused IPC |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 153,240 | 188,945 | 1.233x | +23.30% | 0.711 | 0.713 |
| 2 | 171,215 | 206,140 | 1.204x | +20.40% | 0.838 | 0.917 |
| 4 | 192,607 | 218,239 | 1.133x | +13.31% | 1.077 | 1.321 |
| 64 | 916,126 | 814,283 | 0.889x | -11.12% | 2.322 | 4.014 |

Corrected fused correctness는 `batch=1, seq=1, heads=32, headdim=128,
query_heads_per_kv=4`에서 C4_v3 hardware로 통과했다. 이 layout은 32개의
semantic Q-head 결과를 8개 physical matrix의 4개 row로 읽는다.

| Model | Phase | Shape (`batch x seq x heads x headdim`) | Normal cycle | Fused cycle | Ratio | Overhead |
|---|---|---:|---:|---:|---:|---:|
| Llama2 | prefill | 1 x 1024 x 32 x 128 | 12,543,395 | 11,664,473 | 0.930x | -7.01% |
| Llama2 | prefill | 1 x 2048 x 32 x 128 | 24,656,485 | 24,113,787 | 0.978x | -2.20% |
| Llama2 | prefill | 1 x 4096 x 32 x 128 | 50,284,038 | 47,848,107 | 0.952x | -4.84% |
| Llama2 | prefill | 1 x 8192 x 32 x 128 | 99,763,247 | 95,800,236 | 0.960x | -3.97% |
| Llama2 | prefill | 1 x 16384 x 32 x 128 | 208,863,137 | 192,197,022 | 0.920x | -7.98% |
| Llama2 | prefill | 1 x 32768 x 32 x 128 | 399,592,730 | 383,087,109 | 0.959x | -4.13% |
| Llama2 | decode | 64 x 1 x 32 x 128 | 953,002 | 843,098 | 0.885x | -11.53% |
| Llama3 | prefill | 1 x 1024 x 32 x 128 | 12,521,423 | 11,763,290 | 0.939x | -6.05% |
| Llama3 | prefill | 1 x 2048 x 32 x 128 | 25,075,125 | 23,574,493 | 0.940x | -5.98% |
| Llama3 | prefill | 1 x 4096 x 32 x 128 | 50,049,212 | 47,606,791 | 0.951x | -4.88% |
| Llama3 | prefill | 1 x 8192 x 32 x 128 | 103,462,632 | 96,933,636 | 0.937x | -6.31% |
| Llama3 | prefill | 1 x 16384 x 32 x 128 | 202,642,397 | 192,390,555 | 0.949x | -5.06% |
| Llama3 | prefill | 1 x 32768 x 32 x 128 | 398,326,399 | 385,061,216 | 0.967x | -3.33% |
| Llama3 | decode | 64 x 1 x 32 x 128 | 916,126 | 814,283 | 0.889x | -11.12% |

두 모델 모두 동일한 7개 shape가 비정상 범위에 들어오며, 나머지 decode
shape 3개는 정상 범위에 있다.

### SiLU: 모든 case (pre-fix `chunk32` normal)

SiLU는 측정된 20개 case가 전부 `< 1.0x`다. Normal의 `n`과 fused의 `m*k`는
같다.

| Model | Phase | Normal `n` | Fused `m x k` | Normal cycle | Fused cycle | Ratio | Overhead |
|---|---|---:|---:|---:|---:|---:|---:|
| Llama2 | prefill | 11,272,192 | 1024 x 11008 | 144,910,606 | 33,637,479 | 0.232x | -76.79% |
| Llama2 | prefill | 22,544,384 | 2048 x 11008 | 286,315,620 | 66,679,926 | 0.233x | -76.71% |
| Llama2 | prefill | 45,088,768 | 4096 x 11008 | 576,081,145 | 131,574,633 | 0.228x | -77.16% |
| Llama2 | prefill | 90,177,536 | 8192 x 11008 | 1,155,785,499 | 266,099,873 | 0.230x | -76.98% |
| Llama2 | prefill | 180,355,072 | 16384 x 11008 | 2,293,484,707 | 538,632,454 | 0.235x | -76.51% |
| Llama2 | prefill | 360,710,144 | 32768 x 11008 | 4,619,779,117 | 1,054,315,916 | 0.228x | -77.18% |
| Llama2 | decode | 11,008 | 1 x 11008 | 266,295 | 148,719 | 0.558x | -44.15% |
| Llama2 | decode | 22,016 | 2 x 11008 | 426,823 | 203,186 | 0.476x | -52.40% |
| Llama2 | decode | 44,032 | 4 x 11008 | 695,376 | 284,591 | 0.409x | -59.07% |
| Llama2 | decode | 704,512 | 64 x 11008 | 9,064,681 | 2,183,229 | 0.241x | -75.91% |
| Llama3 | prefill | 14,680,064 | 1024 x 14336 | 188,114,197 | 43,211,727 | 0.230x | -77.03% |
| Llama3 | prefill | 29,360,128 | 2048 x 14336 | 375,383,858 | 85,798,834 | 0.229x | -77.14% |
| Llama3 | prefill | 58,720,256 | 4096 x 14336 | 749,964,714 | 173,057,166 | 0.231x | -76.92% |
| Llama3 | prefill | 117,440,512 | 8192 x 14336 | 1,503,119,146 | 342,920,733 | 0.228x | -77.19% |
| Llama3 | prefill | 234,881,024 | 16384 x 14336 | 2,989,979,480 | 689,744,664 | 0.231x | -76.93% |
| Llama3 | prefill | 469,762,048 | 32768 x 14336 | 5,967,128,787 | 1,371,922,457 | 0.230x | -77.01% |
| Llama3 | decode | 14,336 | 1 x 14336 | 321,697 | 172,659 | 0.537x | -46.33% |
| Llama3 | decode | 28,672 | 2 x 14336 | 506,641 | 224,982 | 0.444x | -55.59% |
| Llama3 | decode | 57,344 | 4 x 14336 | 879,297 | 334,981 | 0.381x | -61.90% |
| Llama3 | decode | 917,504 | 64 x 14336 | 11,838,427 | 2,816,275 | 0.238x | -76.21% |

### 디버깅 우선순위와 확인점 (original raw DB)

#### 절대 latency 기준 kernel 순위

비정상 case만 대상으로 `avg_us`의 절대값을 비교하면 다음 순서다. Max는
각 kernel의 가장 큰 layout-fused latency이며, `max |delta|`는 같은 case가
아니어도 되는 normal 대비 절대 latency 차이의 최댓값이다.

| 순위 | Kernel | 비정상 case 중 fused max | Fused median | Normal 대비 max `|delta|` | 해석 |
|---:|---|---:|---:|---:|---|
| 1 | `hadamard_layout_fused` | 549.178 s | 1.089 s | 19.171 s | 절대 실행시간이 가장 큼 |
| 2 | `silu_layout_fused` | 14.442 s | 0.579 s | 48.370 s | 절대 차이는 가장 큼 |
| 3 | `head_concat_layout_fused` | 4.054 s | 0.504 s | 0.176 s | 세 kernel 중 영향이 가장 작음 |

절대 fused latency만 기준으로 하면 **Hadamard → SiLU → Head Concat** 순서다.
그러나 performance regression, 즉 fused가 실제로 더 소요한 절대 시간만 보면
비정상 case는 Hadamard decode에만 존재한다. 가장 큰 두 regression은 다음과
같다.

| 순위 | Model | Fused shape | Normal latency | Fused latency | 절대 증가 | Cycle ratio |
|---:|---|---:|---:|---:|---:|---:|
| 1 | Llama3 | `m=4,n=512,k=128` | 0.026001 s | 0.181018 s | +0.155016 s | 7.253x |
| 2 | Llama2 | `m=1,n=2048,k=128` | 0.025966 s | 0.180039 s | +0.154073 s | 7.191x |
| 3 | Llama3 | `m=1,n=512,k=128` | 0.007997 s | 0.046038 s | +0.038042 s | 6.596x |
| 4 | Llama2 | `m=1,n=128,k=128` | 0.003746 s | 0.013253 s | +0.009507 s | 5.009x |
| 5 | Llama3 | `m=4,n=32,k=128` | 0.003748 s | 0.013222 s | +0.009474 s | 5.012x |

반대로 예상과 다른 결과의 절대 차이(`|fused-normal|`)를 기준으로 하면 SiLU가
가장 중요하다. Llama3 `m=32768,k=14336`에서 normal `62.812 s` 대비 fused
`14.442 s`로 `48.370 s` 차이가 난다. 이는 performance 문제라기보다는 두
benchmark가 정말 동일한 일을 측정하는지 확인해야 하는 강한 신호다.

The priority list below records the pre-fix interpretation. Item 1 is now
resolved by the normal `linear` default; Hadamard decode is the next unresolved
performance issue.

1. **SiLU benchmark/traversal equivalence (resolved):** the normal `chunk32`
   traversal caused the apparent difference. The corrected prefill overhead is
   below 1% by median.
2. **Hadamard decode 성능 디버깅:** 실제 fused regression이 있는 유일한
   kernel이며, 먼저 위 표의 155ms 증가 두 case를 본다.
3. **Hadamard prefill 재현성 확인:** fused latency 자체는 최대 549초로 가장
   크지만 차이는 `-0.2~-3.4%`이고 fused가 빠른 방향이다. 반복 측정으로 작은
   차이가 안정적인지 먼저 확인한다.
4. **Head Concat 확인:** 절대 차이가 최대 176ms이고 모두 fused가 빠른
   방향이므로 마지막으로 확인한다.

#### 세부 확인점

1. **Hadamard decode의 2배 초과 case를 먼저 확인한다.** 모두 `dim=128`이고,
   fused `n`이 16 이상인 shape다. `n` 증가에 따라 ratio가 최대 `7.253x`까지
   커지므로 tiled offset 계산이나 `m/n` geometry에 따른 반복/launch 구조를
   우선 확인할 가치가 있다.
2. **SiLU는 단순 측정 노이즈로 보기 어려운 일관된 차이다.** Prefill에서 두
   모델 모두 fused가 약 `4.3x` 빠르다. normal과 fused가 동일 연산, 동일
   precision, 동일 vectorization/variant, 동일 padding 범위를 실행하는지
   확인해야 한다.
3. **Head Concat은 두 모델에서 같은 shape가 반복적으로 2~11% 빠르다.** 먼저
   binary가 선택한 kernel variant와 실제 처리 element 수를 확인하고, 그 다음
   단일 측정치 변동 여부를 반복 측정으로 확인한다.
4. **Hadamard의 작은 음의 overhead도 반복 측정한다.** 대부분 `0.2~3.4%`
   차이여서 측정 변동일 수 있다. 현재 각 행은 `fpga_cycle_samples=1`이므로
   재현성 확인 전에는 구현 차이로 단정하지 않는다.

## 비교 방법과 데이터 범위

- 입력 파일:
  - `outputs_llama2_main.C3_C4_v3/C4_v3/raw_db.csv`
    (1006 data rows, 마지막 수정 `2026-07-31 18:49:50 +09:00`)
  - `outputs_llama3_main.C3_C4_v3/C4_v3/raw_db.csv`
    (1090 data rows, 마지막 수정 `2026-07-31 18:49:56 +09:00`)
- 집계 시 두 파일의 모든 행은 `status=pass`였으며 `fpga_cycle`과 `avg_us`가
  채워져 있었다.
- `eladd`, `elmul`, `silu`는 normal의 `n`과 fused의 `m*k`가 같은 행을
  대응시켰다.
- `rmsnorm`은 `batch*seq == m`, `hidden == k`를 사용했다.
- `hadamard`는 `rows == m*n`, `dim == k`를 사용했다. 여러 fused geometry가
  동일한 flattened normal geometry에 대응할 수 있다.
- `head_concat`과 `rope`는 layout 전용 option을 제외한 semantic shape가 같은
  행끼리 비교했다.
- KV-cache quant는 `k,n,q,d,t,quant-mode`가 같은 행끼리 비교했다. Decode의
  layout-fused 행은 여러 `cache-position`을 포함하지만 normal에는 해당 option이
  없어서 동일한 `k=1` normal baseline을 재사용했다. 따라서 이 decode 비교는
  layout 변환만을 완전히 분리한 수치는 아니다.
- `softmax`는 `batch,heads,seqq,seqk,seqk-stride,mask`가 모두 같은 행을
  대응시켰다. 각 모델에서 fused 297행 중 294행을 비교했으며, 나머지 3행
  (`batch=2`, `seqk=2064/2096/2128`)은 대응되는 normal 행이 없어 제외했다.
- Phase는 vector element count의 `m >= 1024`, sequence kernel의 `seq > 1`,
  softmax의 `seqq > 1`, KV-cache quant의 `k > 1`을 prefill로 분류하고 나머지를
  decode로 분류했다.
