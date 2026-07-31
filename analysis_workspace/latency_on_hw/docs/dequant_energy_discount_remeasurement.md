# C4_v3 KV dequantization energy discount remeasurement

> Plot policy override (2026-08-01): Llama energy plot에서 weight
> dequantization에는 QDIR=0/QBLK=32 asymmetric sweep의 관측 최솟값
> `0.48263`을 적용한다. K/V dequantization은 QDIR=1 sweep에서 선택한
> `0.28516`을 유지한다. 아래의 개별 측정값과 통계 자체는 변경하지 않는다.

## 결론

Llama E2E energy graph의 KV-cache dequantization에는 기존 단일 discount
`0.25339` 대신 다음 두 값을 적용한다.

| KV 경로 | E2E quantization mode | Pure/total dynamic-energy ratio |
|---|---|---:|
| K cache | `spinquant_signed_asymmetric` | `0.41995` |
| V cache | `spinquant_signed_symmetric` | `0.56406` |

두 경로의 full energy를 가중치로 사용한 통합 비율은 `0.47742`이지만,
K와 V의 측정 비율 차이가 크므로 `prepare.py`에서는 경로별 값을 사용한다.
Weight dequantization의 기존 `0.53230` rule은 이번 측정 대상이 아니므로
그대로 유지한다.

추가로 K/N을 함께 바꾼 13-shape sweep에서는 평균 discount가 K cache
`0.43926`, V cache `0.39826`, 두 경로의 energy-weighted combined
`0.42103`으로 측정됐다. 범위와 표준편차가 커서 discount는 shape에 대해
불변인 상수가 아니다. 다만 이 sweep은 shape당 full/compute/control을 한
세트씩 측정한 breadth 실험이고, 실제 대표 shape의 반복 측정보다 noise에
민감하므로 `prepare.py`의 대표-shape rule은 변경하지 않는다.

## 재측정 이유

기존 KV discount `0.25339`는 C4_v3에서 측정한 `K=N=128`, `QBLK=32`,
`QDIR=1`, `legacy_uint4_asymmetric` 결과였다. 실제 SpinQuant Llama E2E
workload의 KV dequantization은 다음 설정을 사용하므로 기존 결과와
quantization block 및 mode가 일치하지 않았다.

| 경로 | K | N | QBLK | QDIR | Mode |
|---|---:|---:|---:|---:|---|
| K cache to QK^T | 128 | 128 | 128 | 1 | `spinquant_signed_asymmetric` |
| V cache to PV | 128 | 128 | 128 | 1 | `spinquant_signed_symmetric` |

## 측정 환경과 방법

- 측정일: 2026-07-31
- FPGA: U55C, `C4_v3`
- FPGA binary alias: `C4_v3`
- App: `tests/regression/dequant_hbm_energy`
- Power mode: separate, idle-subtracted dynamic energy
- Full: power iteration 6회, 한 working-set sweep인 kernel iteration 6,394회
- Compute/control: 각각 power iteration 8회, kernel iteration 4,096회
- Compute/control은 독립 측정 2회씩 수행

대표 실행 형태는 다음과 같다.

```text
ci/run_black.sh hw --fpga-bin C4_v3 \
  --app dequant_hbm_energy --bench --power \
  --power-iterations <6 or 8> --no-power-auto-duration \
  --args "-k 128 -n 128 -q 128 -d 1 \
    --quant-mode <spinquant mode> --mode <full|compute|control> \
    --power-kernel-iterations=<1 or 4096>"
```

Full mode의 `--power-kernel-iterations=1`은 benchmark가 한 working-set
sweep인 6,394회로 올린다. Pure dequantization energy는 compute에서
동일한 memory/control 경로의 energy를 빼서 계산했다.

```text
full_energy_per_shape
  = full_energy_j / (6 * 6394)

pure_energy_per_shape(rep)
  = compute_energy_j(rep) / (8 * 4096)
  - control_energy_j(rep) / (8 * 4096)

discount
  = mean(pure_energy_per_shape) / full_energy_per_shape
```

## 결과

| KV 경로 | Full energy (uJ) | Pure rep 1 (uJ) | Pure rep 2 (uJ) | Pure mean (uJ) | Discount |
|---|---:|---:|---:|---:|---:|
| K / asymmetric | 1718.007 | 732.011 | 710.956 | 721.484 | 41.995% |
| V / symmetric | 1139.478 | 593.778 | 691.688 | 642.733 | 56.406% |
| Combined, energy-weighted | 2857.485 | 1325.789 | 1402.644 | 1364.217 | 47.742% |

반복별 통합 비율은 46.397%와 49.087%였다. V symmetric 결과의 반복 간
편차가 K보다 크지만, 두 mode 모두 기존 25.339%보다 명확히 높다.

## 적용

`analysis_workspace/latency_on_hw/prepare.py`의
`DEQUANT_PURE_ENERGY_RULES`에서 이름을 기준으로 두 경로를 분리한다.

```text
^kv_cache_dequant_k_  -> 0.41995
^kv_cache_dequant_v_  -> 0.56406
```

따라서 Llama E2E energy no-area-normalization figure를 준비할 때 K/V
dequantization component의 `kernel_energy_j`에 각각 위 비율이 적용된다.

## Raw data와 제외 데이터

Raw power data는 다음 디렉터리에 보존한다.

```text
build_regression/power_logs/dequant_qdir1_qblk128_20260731/
```

유효 결과는 `asym_full_r1`, `sym_full_r1` 및 이름에 `k4096`이 포함된
compute/control 디렉터리다. 초기 점검 중 생성된 `asym_compute_r1`과
`asym_compute_r2`는 kernel iteration이 1인 짧은 샘플이므로 계산에서
제외했다. 이어지는 control 실행은 측정 전에 중단했으며 결과에 포함하지
않았다.

## QBLK/QDIR 고정 13-shape sweep

### 목적과 shape 선택

고정 discount의 matrix shape 의존성을 확인하기 위해 `QBLK=128`,
`QDIR=1`은 유지하고 K와 N을 모두 변경했다. 총 element 수는 대부분
15,360 또는 16,384로 비슷하게 유지하면서 K/N aspect ratio를 `1/16`부터
`16`까지 바꿨다. 따라서 전체 matrix 크기 변화보다 row/column 방향성과
QDIR=1 grouping의 영향을 더 직접적으로 볼 수 있다.

```text
(K, N) =
  (32, 512), (40, 384), (48, 320), (64, 256), (80, 192),
  (96, 160), (128, 128), (160, 96), (192, 80), (256, 64),
  (320, 48), (384, 40), (512, 32)
```

각 shape에서 다음 6개 실행을 수행했다.

- K cache: `spinquant_signed_asymmetric`의 full/compute/control
- V cache: `spinquant_signed_symmetric`의 full/compute/control
- 모든 mode에서 power iteration 4회
- Compute/control은 kernel iteration 4,096회
- Full은 benchmark가 256 MiB working-set 한 sweep에 필요한 iteration
  수로 자동 조정

총 13 shape × 2 quant mode × 3 mode = 78개 C4_v3 hardware 실행이 모두
`PASSED`했다. Shape별 full iteration 수가 다르므로 각
`power_summary.csv`의 `power_kernel_iterations`로 개별 정규화했다.
Raw CSV truncation은 없었다. Run-window sample 수의 min/median/max는
full `235/356.5/836`, compute `122/169.5/399`, control `81/104.5/293`이었다.

```text
full_energy_per_shape
  = full_energy_j / (4 * full_kernel_iterations)

pure_energy_per_shape
  = compute_energy_j / (4 * 4096)
  - control_energy_j / (4 * 4096)

discount
  = pure_energy_per_shape / full_energy_per_shape
```

### Shape별 결과

| K | N | K full (uJ) | K pure (uJ) | K discount | V full (uJ) | V pure (uJ) | V discount | Combined |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 32 | 512 | 1647.652 | 777.474 | 47.187% | 1201.435 | 585.811 | 48.759% | 47.850% |
| 40 | 384 | 1342.579 | 782.357 | 58.273% | 1052.253 | 620.720 | 58.990% | 58.588% |
| 48 | 320 | 1559.219 | 695.191 | 44.586% | 1186.485 | 409.981 | 34.554% | 40.251% |
| 64 | 256 | 1560.225 | 696.037 | 44.611% | 1188.133 | 648.179 | 54.554% | 48.910% |
| 80 | 192 | 1834.156 | 874.580 | 47.683% | 1271.716 | 508.954 | 40.021% | 44.546% |
| 96 | 160 | 1853.540 | 816.516 | 44.052% | 1659.541 | 473.242 | 28.516% | 36.713% |
| 128 | 128 | 1551.468 | 550.712 | 35.496% | 1251.844 | 491.199 | 39.238% | 37.167% |
| 160 | 96 | 1930.387 | 880.233 | 45.599% | 1658.761 | 714.193 | 43.056% | 44.424% |
| 192 | 80 | 2174.472 | 1153.167 | 53.032% | 1765.582 | 841.675 | 47.671% | 50.630% |
| 256 | 64 | 2464.140 | 833.188 | 33.813% | 1757.824 | 508.678 | 28.938% | 31.783% |
| 320 | 48 | 2710.356 | 1192.774 | 44.008% | 2175.964 | 624.173 | 28.685% | 37.184% |
| 384 | 40 | 3296.292 | 1147.063 | 34.799% | 2465.900 | 829.296 | 33.631% | 34.299% |
| 512 | 32 | 3883.182 | 1471.865 | 37.904% | 2908.908 | 905.188 | 31.118% | 34.997% |

`Combined`는 각 shape에서 `(K pure + V pure) / (K full + V full)`로
계산한 energy-weighted 비율이다.

### 분포 통계

| 통계 | K / asymmetric | V / symmetric | Combined |
|---|---:|---:|---:|
| Mean | 43.926% | 39.826% | 42.103% |
| Median | 44.586% | 39.238% | 40.251% |
| Sample standard deviation | 7.131 pp | 10.202 pp | 7.821 pp |
| P10 | 34.938% | 28.736% | 34.439% |
| P90 | 51.962% | 53.395% | 50.286% |
| Minimum | 33.813% | 28.516% | 31.783% |
| Maximum | 58.273% | 58.990% | 58.588% |
| Coefficient of variation | 16.23% | 25.62% | 18.58% |

최솟값은 K와 combined 모두 `(256,64)`에서 나왔고, V 최솟값은
`(96,160)`에서 나왔다. 세 지표의 최댓값은 모두 `(40,384)`에서 나왔다.

N과 QBLK의 관계로 나누면 평균 discount는 다음과 같다.

| N group | Shape 수 | K / asymmetric mean | V / symmetric mean |
|---|---:|---:|---:|
| N > 128 | 6 | 47.732% | 44.232% |
| N = 128 | 1 | 35.496% | 39.238% |
| N < 128 | 6 | 41.526% | 35.516% |

`log2(K/N)`에 대한 단순 선형 회귀에서는 한 octave 증가할 때 K discount가
`-1.602 pp`, V discount가 `-2.486 pp`, combined가 `-1.986 pp` 감소했다.
Pearson correlation은 각각 `-0.582`, `-0.631`, `-0.658`이고 R-squared는
`0.339`, `0.399`, `0.433`이다. 즉 K가 N보다 길어질수록 discount가
낮아지는 중간 정도의 경향은 있지만, aspect ratio만으로 shape 간 변동을
모두 설명할 수는 없다.

### 대표-shape 반복 측정과의 관계

이번 4-iteration breadth sweep의 `(128,128)` 결과는 K `35.496%`, V
`39.238%`였다. 앞 절의 더 긴 독립 반복 측정은 K `41.995%`, V
`56.406%`였다. 차이는 각각 `-6.499 pp`, `-17.168 pp`이며 V estimator가
짧은 sweep에서 특히 민감함을 보여준다.

따라서 다음과 같이 해석한다.

- 현재 K/V별 rule은 실제 E2E 대표 설정에 대한 더 긴 반복 측정값이므로
  그대로 유지한다.
- 13-shape 평균을 모든 KV matrix에 대한 새로운 상수 rule로 사용하지
  않는다.
- arbitrary K/N shape까지 정확히 보정해야 한다면 고정 상수 대신 shape별
  반복 측정이나 dimension-conditioned model이 필요하다.

Shape sweep의 raw data는 다음 디렉터리에 있다.

```text
build_regression/power_logs/dequant_shape_sweep_qblk128_qdir1_20260731/
```

## QDIR=0, QBLK=32 partial shape sweep

### 범위와 중단 기준

Weight-dequantization에 해당하는 QDIR=0 경로의 최저 pure-energy 비율을
찾기 위해 `QBLK=32`, `QDIR=0`을 고정하고 K/N shape를 변경했다. 각
shape에서 `spinquant_signed_asymmetric`와 `spinquant_signed_symmetric`의
full/compute/control을 측정했으며, 각 mode는 power iteration 4회였다.
Compute/control은 kernel iteration 4,096회이고 full은 256 MiB working-set
한 sweep으로 자동 조정됐다.

계획한 17개 중 사용자의 중단 요청 시점에 asym/sym 전체 세트가 완성된
13개 shape만 아래 결과와 통계에 포함한다. 총 13 × 2 × 3 = 78개 유효
실행이다. `(384,40)` asymmetric 세트는 완료됐지만 symmetric 세트가
완성되지 않아 제외했고, 이후 shape도 제외했다.

### 완료된 shape별 pure/total dynamic-energy 비율

| K | N | Asymmetric | Symmetric | Energy-weighted combined |
|---:|---:|---:|---:|---:|
| 16 | 1024 | 70.220% | 87.465% | 77.434% |
| 24 | 640 | 57.077% | 65.157% | 60.578% |
| 32 | 512 | 80.911% | 72.035% | 76.888% |
| 40 | 384 | 57.391% | 71.435% | 63.688% |
| 48 | 320 | 64.694% | 67.437% | 66.021% |
| 64 | 256 | 48.263% | 62.065% | 54.732% |
| 80 | 192 | 59.443% | 59.628% | 59.531% |
| 96 | 160 | 69.459% | 77.395% | 72.955% |
| 128 | 128 | 55.172% | 54.620% | 54.907% |
| 160 | 96 | 51.846% | 66.429% | 58.268% |
| 192 | 80 | 67.296% | 87.315% | 76.083% |
| 256 | 64 | 73.258% | 52.349% | 63.442% |
| 320 | 48 | 71.909% | 66.218% | 69.150% |

### 현재까지의 통계와 최솟값

| 통계 | Asymmetric | Symmetric | Combined |
|---|---:|---:|---:|
| Mean | 63.611% | 68.427% | 65.667% |
| Median | 64.694% | 66.429% | 63.688% |
| Minimum | **48.263%** at `(64,256)` | **52.349%** at `(256,64)` | **54.732%** at `(64,256)` |
| Maximum | 80.911% at `(32,512)` | 87.465% at `(16,1024)` | 77.434% at `(16,1024)` |

완료된 범위에서는 QDIR=0 비율이 QDIR=1 sweep보다 전반적으로 높았고,
aspect ratio에 대해 단조 증가하거나 감소하지 않았다. Weight plot policy는
asymmetric 관측 최솟값 `48.263%`를 보수적으로 선택한다. 사용자의 중단
요청에 따라 최저 후보 `(64,256)`의 고반복 확인 측정은 수행하지 않았다.

Raw data는 다음 디렉터리에 보존한다.

```text
build_regression/power_logs/dequant_shape_sweep_qdir0_qblk32_20260801/
```
