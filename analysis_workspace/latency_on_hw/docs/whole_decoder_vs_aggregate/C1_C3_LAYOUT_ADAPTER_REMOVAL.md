# C1–C3 decoder layout adapter removal (2026-10-10)

All 18 B1 model/candidate/stage cases PASS, with bit-identical final outputs and same-layout intermediate buffers versus the original implementation. The additional C3 B2/S32 CPU-reference check also passes.

## Changes

- Q/K: RoPE reads `[B,S,H,D]` and stores `[B,H,S,D]`; no separate head reorder.
- V: KV quant reads the projection using a `kv_heads * head_dim` row stride; packed KV bytes and qparams are unchanged.
- C1/C2 PV: TCU loads row-major dequantized V; the separate V transpose is removed.
- PV output concat is retained. No RTL or C4 changes. These paths apply to prefill and decode, not an S=1-only shortcut.
- At this decoder-only verification stage, features were enabled only by the common decoder Makefile. With those options disabled, normalized generated assembly for the tested TH16/Zfh RoPE, quant and TCU variants matched HEAD (before this change). The subsequent [Rev7 latency refresh](REV7_B1_S1024_LAYOUT_REFRESH.md) also exposes these features through the standalone apps and benchmark harnesses.

## Correctness

Existing deterministic CPU fixtures (seed 20260831), real model dimensions, batch 1; original final-output thresholds and nonfinite checks are unchanged. Decode is the first token with 1024 existing KV entries and capacity 1056. Every head executes.

| Candidate | Model | Case | Final gate | Relative L2 (%) | Changed same-layout buffers vs before |
|---|---|---|---|---:|---:|
| C1 | llama3-8b | prefill32 | PASS | 0.041089 | 0 |
| C1 | llama2-7b | prefill32 | PASS | 0.103511 | 0 |
| C1 | llama3-8b | decode1024 | PASS | 0.041921 | 0 |
| C1 | llama2-7b | decode1024 | PASS | 0.039307 | 0 |
| C1 | llama3-8b | prefill1024 | PASS | 0.045443 | 0 |
| C1 | llama2-7b | prefill1024 | PASS | 0.049127 | 0 |
| C2 | llama3-8b | prefill32 | PASS | 0.041128 | 0 |
| C2 | llama2-7b | prefill32 | PASS | 0.103541 | 0 |
| C2 | llama3-8b | decode1024 | PASS | 0.042204 | 0 |
| C2 | llama2-7b | decode1024 | PASS | 0.039304 | 0 |
| C2 | llama3-8b | prefill1024 | PASS | 0.045102 | 0 |
| C2 | llama2-7b | prefill1024 | PASS | 0.049137 | 0 |
| C3 | llama3-8b | prefill32 | PASS | 0.044294 | 0 |
| C3 | llama2-7b | prefill32 | PASS | 0.104603 | 0 |
| C3 | llama3-8b | decode1024 | PASS | 0.047710 | 0 |
| C3 | llama2-7b | decode1024 | PASS | 0.038825 | 0 |
| C3 | llama3-8b | prefill1024 | PASS | 0.046322 | 0 |
| C3 | llama2-7b | prefill1024 | PASS | 0.049895 | 0 |
| C3 | llama3-8b | prefill32, **batch 2** | PASS | 0.074486 | Separate CPU reference; no old dump |

Comparison includes final output, Q/K Hadamard, packed KV and qparams, and attention results. New row-major V dequant output is compared with the previous pre-transpose V buffer, not the previous transposed buffer.

## Measured decoder wall time

Before/after executables run on the same allocated FPGA for each candidate, using the same fix_sub_norm image and fixtures. Median of three uninstrumented decoder.run() passes after a verified warmup. Includes dequant and retained concat; excludes host transfers, output checks, setup, and counter queries. Negative change means faster.

| Candidate | Model | Case | Before (s) | After (s) | Change |
|---|---|---|---:|---:|---:|
| C1 | llama3-8b | prefill32 | 8.439462 | 8.391513 | -0.57% |
| C1 | llama2-7b | prefill32 | 8.770238 | 8.612585 | -1.80% |
| C1 | llama3-8b | decode1024 | 4.205876 | 4.066745 | -3.31% |
| C1 | llama2-7b | decode1024 | 5.035381 | 4.458721 | -11.45% |
| C2 | llama3-8b | prefill32 | 1.037480 | 0.978407 | -5.69% |
| C2 | llama2-7b | prefill32 | 1.830390 | 1.665557 | -9.01% |
| C2 | llama3-8b | decode1024 | 0.614336 | 0.460521 | -25.04% |
| C2 | llama2-7b | decode1024 | 1.614420 | 1.018577 | -36.91% |
| C3 | llama3-8b | prefill32 | 0.974773 | 0.911541 | -6.49% |
| C3 | llama2-7b | prefill32 | 1.694526 | 1.558999 | -8.00% |
| C3 | llama3-8b | decode1024 | 0.272625 | 0.269830 | -1.03% |
| C3 | llama2-7b | decode1024 | 0.249568 | 0.245817 | -1.50% |

## Prefill 1024: device cycle sum

One verified counter pass, summed at 100 MHz. The baseline is the earlier same-image fix_sub_norm regression; it was not rerun on the newly allocated board. These are device cycle sums, not decoder wall measurements.

| Candidate | Model | Before (s) | After (s) | Change |
|---|---|---:|---:|---:|
| C1 | llama3-8b | 285.086331 | 285.646277 | +0.20% |
| C1 | llama2-7b | 298.237988 | 295.592587 | -0.89% |
| C2 | llama3-8b | 46.097432 | 45.629618 | -1.01% |
| C2 | llama2-7b | 69.629757 | 66.567906 | -4.40% |
| C3 | llama3-8b | 31.840293 | 29.883294 | -6.15% |
| C3 | llama2-7b | 54.387465 | 50.361461 | -7.40% |

## PV load-layout tradeoff

Removing a transpose does not guarantee that PV GEMM becomes faster. Row-major B has a different TCU load cost. The following table includes V dequant + V transpose (before only) + PV, using device cycles at 100 MHz. Q/K and V head-reorder savings are outside this subtotal.

| Candidate | Model | Case | PV before/after (ms) | V dequant + transpose + PV before/after (ms) |
|---|---|---|---:|---:|
| C1 | llama3-8b | prefill32 | 36.083 / 44.775 | 47.952 / 49.479 |
| C1 | llama2-7b | prefill32 | 36.296 / 44.924 | 84.650 / 63.771 |
| C1 | llama3-8b | decode1024 | 19.961 / 30.601 | 233.406 / 91.025 |
| C1 | llama2-7b | decode1024 | 80.000 / 121.874 | 925.091 / 363.700 |
| C1 | llama3-8b | prefill1024 | 4915.503 / 6446.117 | 5131.682 / 6504.787 |
| C1 | llama2-7b | prefill1024 | 4909.419 / 6446.031 | 5781.737 / 6680.839 |
| C2 | llama3-8b | prefill32 | 36.279 / 44.796 | 48.368 / 49.487 |
| C2 | llama2-7b | prefill32 | 36.364 / 45.101 | 85.018 / 63.906 |
| C2 | llama3-8b | decode1024 | 20.227 / 31.203 | 238.381 / 91.982 |
| C2 | llama2-7b | decode1024 | 80.922 / 124.345 | 960.642 / 367.244 |
| C2 | llama3-8b | prefill1024 | 4984.299 / 6529.148 | 5204.520 / 6588.168 |
| C2 | llama2-7b | prefill1024 | 4982.001 / 6520.637 | 5869.393 / 6756.792 |

## Reproduction and evidence

Builds: `build_decoder_layout_c{1,2,3}`. Original binaries/fixtures: `build_decoder_fix_sub_norm_c{1,2,3}`. Detailed logs, profiles, timings and output dumps are in each new build’s `results/` directory. Orchestration and machine-readable comparisons: `build_decoder_layout_checks/{prepare.py,run.py,summary.json,standalone_identity.json}`.

Images:

- C1: `tcu_th16_c1_v3_fix_sub_norm`
- C2: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_qcol_fix_sub_norm`
- C3: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_fix_sub_norm`

Example from a configured new build (source its config before compiling):

```sh
./ci/run_black.sh hw --fpga-bin tcu_th16_c1_v3_fix_sub_norm \
  --app llama_decoder_C1 --run-only \
  --args "--model llama3-8b --batch 1 --seq-len 32 --mode timing --repetitions 3 --profile-repetitions 0 --fixture /absolute/existing/fixture --output /absolute/new/result"
```

The 1024-token Llama3 C1 cycle sum increased by 0.20%; this case does not demonstrate an overall speedup. The long-prefill baseline is historical, so sub-percent differences should not be attributed to this change alone.
