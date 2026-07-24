# C4 Normal Vector vs Layout-Fused Vector: All-Case Comparison

Date: 2026-07-24

## Purpose

This report compares every runnable normal vector kernel that has a
corresponding layout-fused vector kernel on the same C4 FPGA configuration.
It extends the earlier three-kernel fairness audit to all nine kernel
families and all semantically distinct Llama3-8B workload cases.

The following runnable pairs are covered:

| Normal app | Layout-fused app |
|---|---|
| `eladd` | `eladd_layout_fused` |
| `elmul` | `elmul_layout_fused` |
| `hadamard` | `hadamard_layout_fused` |
| `head_concat` | `head_concat_layout_fused` |
| `kv_cache_quant_w4a16` | `kv_cache_quant_layout_fused_w4a16` |
| `rmsnorm` | `rms_norm_layout_fused` |
| `rope` | `rope_layout_fused` |
| `silu` | `silu_layout_fused` |
| `softmax` | `softmax_layout_fused` |

`layout_fused_common` is excluded because it is a helper library, not a
runnable kernel.

## Test Method

- FPGA binary alias: `C4`
- Runner: `ci/run_black.sh hw --fpga-bin C4`
- C4 config:
  `configs/improve_th32_tcol32_hwexp_dcache.sh`
- Model shape source: Llama3-8B workload generator
- Batch size: 1
- Decode representative point: query length 1, KV length 4096
- Prefill representative point: sequence length 1024
- Each reported performance value is one hardware execution, not an average.
- Correctness was checked by each regression application's host verifier.
- Lower cycles are better.
- `Fused/Normal < 1.0` means the layout-fused kernel is faster.

The workload shapes were derived with:

```bash
/usr/bin/python3 tools/workload/gen_kernel_cfgs.py \
  --model llama3-8b \
  --stage generation \
  --batch 1 \
  --gen-kv-len 4096 \
  --max-seq-len 4096 \
  --qblk 32 \
  --variant all_fpint_gemm_improve_fused_layout_spinquant

/usr/bin/python3 tools/workload/gen_kernel_cfgs.py \
  --model llama3-8b \
  --stage prefill \
  --batch 1 \
  --prefill-seq-len 1024 \
  --max-seq-len 4096 \
  --qblk 32 \
  --variant all_fpint_gemm_improve_fused_layout_spinquant
```

The non-fused KV quantization cases come from the corresponding
`all_fpint_gemm_improve_alone_layout_spinquant` workload variant.

## Executive Summary

- All 13 decode comparisons passed correctness.
- Decode layout-fused was faster for KV Quant-K (`0.935x`) and KV Quant-V
  (`0.966x`).
- The unweighted geometric mean of the 13 decode ratios was `1.232x`, or
  about 23.2% more cycles for layout-fused.
- Of the 12 correctness-valid prefill comparisons, layout-fused was faster
  for:
  - Head Concat: `0.924x`, 7.6% fewer cycles
  - SiLU: `0.905x`, 9.5% fewer cycles
- Excluding the latency-only Hadamard R3-Q comparison, the unweighted
  geometric mean of the 12 valid prefill ratios was `1.218x`, or about 21.8%
  more
  cycles for layout-fused.
- Prefill Hadamard R3-Q normal intentionally uses the faster one-warp launch
  for latency measurement. Its known correctness failure is accepted pending
  an RTL LMEM-ordering fix.

## Decode KV Quant Correction and Optimization

The original KV Quant-K and KV Quant-V decode rows did not execute the
requested append update. The regression host parsed `--persistent-kind`, but
silently ignored the generated workload's `--cache-update append` argument.
It therefore ran the generic full-cache path with `K=1`, and its verifier
validated that different operation. The resulting `617,296` and `606,762`
cycle values were not decode append measurements.

The regression now parses `--cache-update full|append`, recognizes the
supported decode KV-K and KV-V configurations, and routes append commands
through the persistent-update correctness test. The device kernel also keeps
the one-warp append implementation separate from the large prefill function,
reducing the append path's register and instruction footprint without
changing the prefill code layout.

| Case | Original mislabeled cycles | Corrected fused cycles | Reduction | Corrected fused/normal |
|---|---:|---:|---:|---:|
| KV Quant-K | 617,296 | 72,914 | 88.2% | 0.935x |
| KV Quant-V | 606,762 | 75,072 | 87.6% | 0.966x |

Both append correctness tests passed, including separate coverage with
optional logical correction-qparam outputs enabled. Prefill regression checks
also passed at `2,972,690` cycles for KV Quant-K and `3,251,415` cycles for KV
Quant-V, consistent with the pre-optimization report values.

## Decode Results

| Case | Representative shape | Normal cycles | Normal IPC | Fused cycles | Fused IPC | Fused/Normal | Correctness |
|---|---|---:|---:|---:|---:|---:|---|
| RMSNorm | M=1, K=4096 | 157,971 | 3.901919 | 175,863 | 3.772385 | 1.113x | Both pass |
| RoPE-Q | B=1, S=1, H=32, D=128 | 214,730 | 2.308983 | 333,522 | 1.748934 | 1.553x | Both pass |
| RoPE-K | B=1, S=1, H=8, D=128 | 161,848 | 0.983824 | 259,212 | 0.813759 | 1.602x | Both pass |
| Hadamard R3-Q | rows=32, D=128 | 507,730 | 2.036236 | 586,771 | 1.935290 | 1.156x | Both pass |
| Hadamard R3-K | rows=8, D=128 | 188,736 | 1.503878 | 204,991 | 1.509954 | 1.086x | Both pass |
| Hadamard R4 | rows=1, D=14336 | 1,734,810 | 6.510105 | 1,877,960 | 6.325063 | 1.083x | Both pass |
| KV Quant-K | K=1, N=128, QBLK=128 | 77,943 | 0.697266 | 72,914 | 0.742532 | **0.935x** | Both pass |
| KV Quant-V | K=1, N=128, QBLK=128 | 77,720 | 0.693914 | 75,072 | 0.698223 | **0.966x** | Both pass |
| Softmax | B=1, H=32, Q=1, K=4096 | 1,921,810 | 8.177688 | 2,593,020 | 6.484409 | 1.349x | Both pass |
| Head Concat | B=1, S=1, H=32, D=128 | 130,469 | 0.692854 | 212,154 | 0.652941 | 1.626x | Both pass |
| ElAdd | N=4096 | 231,462 | 2.221095 | 289,569 | 2.517383 | 1.251x | Both pass |
| SiLU | N=14336 | 424,194 | 3.144995 | 529,123 | 2.797943 | 1.247x | Both pass |
| ElMul | N=14336 | 324,623 | 4.823038 | 420,720 | 3.952928 | 1.296x | Both pass |

### Decode Observations

The decode results show a broad small-shape overhead in the layout-fused
implementations. After correcting and specializing the append path, KV
quantization is slightly faster than normal. RoPE and Head Concat now show the
largest fixed-cost sensitivity, at roughly `1.55x` to `1.63x`.

## Prefill Results

| Case | Representative shape | Normal cycles | Normal IPC | Fused cycles | Fused IPC | Fused/Normal | Correctness |
|---|---|---:|---:|---:|---:|---:|---|
| RMSNorm | M=1024, K=4096 | 59,559,843 | 9.579889 | 66,211,390 | 9.277832 | 1.112x | Both pass |
| RoPE-Q | B=1, S=1024, H=32, D=128 | 100,405,877 | 4.537690 | 128,262,800 | 3.897721 | 1.277x | Both pass |
| RoPE-K | B=1, S=1024, H=8, D=128 | 25,068,713 | 4.545002 | 32,262,366 | 3.876669 | 1.287x | Both pass |
| Hadamard R3-Q | rows=32768, D=128 | 442,057,960 | 2.317573 | 515,449,395 | 2.188586 | 1.166x* | Normal fails; fused passes |
| Hadamard R3-K | rows=8192, D=128 | 110,616,993 | 2.315689 | 128,067,426 | 2.202368 | 1.158x | Both pass |
| Hadamard R4 | rows=1024, D=14336 | 1,671,737,890 | 6.878468 | 1,805,710,230 | 6.699049 | 1.080x | Both pass |
| KV Quant-K | K=1024, N=128, QBLK=128 | 2,472,060 | 5.334147 | 2,971,581 | 6.863620 | 1.202x | Both pass |
| KV Quant-V | K=1024, N=128, QBLK=128 | 2,445,249 | 5.384468 | 3,253,657 | 6.309493 | 1.331x | Both pass |
| Softmax | B=1, H=32, Q=1024, K=1024 | 569,046,589 | 4.293338 | 625,502,958 | 4.286358 | 1.099x | Both pass |
| Head Concat | B=1, S=1024, H=32, D=128 | 12,989,049 | 2.529148 | 12,001,291 | 4.245327 | **0.924x** | Both pass |
| ElAdd | N=4,194,304 | 41,805,591 | 10.432553 | 91,800,896 | 4.550395 | 2.196x | Both pass |
| SiLU | N=14,680,064 | 208,565,012 | 6.103704 | 188,789,136 | 6.915678 | **0.905x** | Both pass |
| ElMul | N=14,680,064 | 144,989,113 | 10.426497 | 210,095,672 | 7.217846 | 1.449x | Both pass |

`*` The Hadamard R3-Q ratio is a latency-only comparison. The normal result
is retained by policy even though its correctness verifier reports errors.

### Prefill Observations

The larger prefill shapes amortize some fixed costs, but the layout-fused
path still regresses most correctness-valid cases. Head Concat benefits from
its fused output layout and SiLU benefits at the large MLP activation size.
ElAdd has the largest valid prefill regression at `2.196x`. Hadamard R3-Q is
reported separately as a latency-only result.

## Known Correctness Failure: Prefill Hadamard R3-Q Normal

The following normal command failed twice:

```bash
timeout 300s ./ci/run_black.sh hw \
  --fpga-bin C4 \
  --app hadamard \
  --args '-rows 32768 -dim 128 -K 1'
```

First execution:

```text
PERF: instrs=1024501727, cycles=442147550, IPC=2.317104
Verification: max_diff=1.739746 mean_diff=0.000017 errors=396
Hadamard transform failed with 396 errors.
```

Second execution:

```text
PERF: instrs=1024501632, cycles=442399151, IPC=2.315786
Verification: max_diff=2.494141 mean_diff=0.000021 errors=528
Hadamard transform failed with 528 errors.
```

The mismatch locations differed between executions. The corresponding
layout-fused command passed with zero errors:

```bash
timeout 300s ./ci/run_black.sh hw \
  --fpga-bin C4 \
  --app hadamard_layout_fused \
  --args '-m 1024 -n 32 -k 128'
```

```text
requested: PASS (0 errors)
PERF: instrs=1128105248, cycles=515449395, IPC=2.188586
```

The failure was reproduced again with the current adaptive launch:

```text
Variant: adaptive_row
Launch: 32 threads/row
PERF: instrs=1024502120, cycles=442130941, IPC=2.317192
Verification: max_diff=2.497070 mean_diff=0.000043 errors=1320
```

The first mismatches were row 2109 at columns 31, 63, 95, and 127, followed
by row 2113. Those rows are assigned to the same physical warp slot by the
four-warp scheduler. Running the identical device kernel with 128 threads
per row passed, which excluded the kernel arithmetic, 8 MiB buffer boundary,
and host reference as causes.

The 32-thread launch creates a one-warp workgroup. Its `__syncthreads()`
calls `vx_barrier(id, 1)`, which the RTL explicitly treats as a no-op. The
repeated local-scratch butterfly stages therefore lacked a real inter-warp
drain interval on C4. A stage-level `vx_fence()` experiment still failed
because that fence follows the global/cache path and is not an explicit
local-memory queue drain.

A correctness workaround used a minimum of two warps for `base_k=1`.
Factorized K=3/28/172 and zero-padding launches retained their previous
policy. The exact failing shape passed five consecutive C4 executions:

| Run | Threads/row | Cycles | IPC | Errors |
|---:|---:|---:|---:|---:|
| 1 | 64 | 765,719,036 | 1.684 | 0 |
| 2 | 64 | 766,499,245 | 1.683 | 0 |
| 3 | 64 | 765,135,583 | 1.686 | 0 |
| 4 | 64 | 765,902,457 | 1.684 | 0 |
| 5 | 64 | 765,715,400 | 1.684 | 0 |

The final C4 regression also passed `rows=8192, K=1`, K=3, K=28, K=172,
zero-padding K=0, and a forced 128-thread multiwarp case, all with zero
errors.

That workaround was subsequently disabled because the current purpose of
the normal-kernel run is latency measurement rather than correctness. The
default adaptive launch again uses 32 threads per row. The post-revert C4
measurement produced:

```text
Launch: 32 threads/row
PERF: instrs=1024501751, cycles=442057960, IPC=2.317573
Verification: max_diff=2.538086 mean_diff=0.000039 errors=1157
```

The `442,057,960`-cycle value is therefore used in the prefill table as an
explicitly accepted latency-only result. The RTL issue remains open and is
tracked in `docs/bugs/lmem-omega-single-warp-store-load-visibility.md`.

## Hadamard Measurement Behavior

`hadamard_layout_fused` runs only the shape selected by its arguments, so its
`PERF` output always corresponds to the requested workload. For example:

```bash
timeout 300s ./ci/run_black.sh hw \
  --fpga-bin C4 \
  --app hadamard_layout_fused \
  --args '-m 1024 -n 1 -k 14336 --layout-from gemm_a_tiled'
```

## Softmax Prefill Shape Note

The workload generator decomposes prefill Softmax into a representative
`H=1` invocation with repeated calls. That direct generated shape produced:

| Softmax prefill H=1 | Cycles | IPC | Correctness |
|---|---:|---:|---|
| Normal | 17,852,823 | 4.278297 | Pass |
| Layout-fused | 19,783,785 | 4.236692 | Pass |

For consistency with the original fairness audit, the primary prefill table
uses the complete `B=1, H=32, Q=1024, K=1024` tensor. Both forms show
approximately the same regression direction.

## Exact Argument Mapping

### Decode

| Case | Normal args | Layout-fused args |
|---|---|---|
| RMSNorm | `-batch 1 -seq 1 -hidden 4096` | `-m 1 -k 4096` |
| RoPE-Q | `-batch 1 -seq 1 -heads 32 -headdim 128 -maxseq 8192 -offset 4095` | Same shape plus `--layout-to head_major_row` |
| RoPE-K | `-batch 1 -seq 1 -heads 8 -headdim 128 -maxseq 8192 -offset 4095` | Same shape plus `--layout-to head_major_row` |
| Hadamard R3-Q | `-rows 32 -dim 128 -K 1` | `-m 4 -n 8 -k 128` |
| Hadamard R3-K | `-rows 8 -dim 128 -K 1` | `-m 1 -n 8 -k 128` |
| Hadamard R4 | `-rows 1 -dim 14336 -K 28` | `-m 1 -n 1 -k 14336 --layout-from gemm_a_tiled` |
| KV Quant-K | `-k 1 -n 128 -q 128 -d 1 -t 1 --quant-mode spinquant_signed_asymmetric` | `-k 1 -n 128 -q 128 -d 1 -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_asymmetric --source-total-n 128 --head-col-offset 0 --cache-update append --cache-capacity 4096 --cache-position 4095` |
| KV Quant-V | `-k 1 -n 128 -q 128 -d 1 -t 0 --quant-mode spinquant_signed_symmetric` | `-k 1 -n 128 -q 128 -d 1 -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric --source-total-n 1024 --head-col-offset 0 --cache-update append --cache-capacity 4096 --cache-position 4095` |
| Softmax | `-batch 1 -heads 32 -seqq 1 -seqk 4096 -seqk-stride 4096 -mask 0` | Same |
| Head Concat | `-batch 1 -seq 1 -heads 32 -headdim 128` | Same shape plus `--layout-to gemm_a_tiled` |
| ElAdd | `-n 4096` | `-m 1 -k 4096` |
| SiLU | `-n 14336` | `-m 1 -k 14336` |
| ElMul | `-n 14336` | `-m 1 -k 14336` |

### Prefill

| Case | Normal args | Layout-fused args |
|---|---|---|
| RMSNorm | `-batch 1 -seq 1024 -hidden 4096` | `-m 1024 -k 4096` |
| RoPE-Q | `-batch 1 -seq 1024 -heads 32 -headdim 128 -maxseq 8192 -offset 0` | Same shape plus `--layout-to head_major_row` |
| RoPE-K | `-batch 1 -seq 1024 -heads 8 -headdim 128 -maxseq 8192 -offset 0` | Same shape plus `--layout-to head_major_row` |
| Hadamard R3-Q | `-rows 32768 -dim 128 -K 1` | `-m 1024 -n 32 -k 128` |
| Hadamard R3-K | `-rows 8192 -dim 128 -K 1` | `-m 1024 -n 8 -k 128` |
| Hadamard R4 | `-rows 1024 -dim 14336 -K 28` | `-m 1024 -n 1 -k 14336 --layout-from gemm_a_tiled` |
| KV Quant-K | `-k 1024 -n 128 -q 128 -d 1 -t 1 --quant-mode spinquant_signed_asymmetric` | `-k 1024 -n 128 -q 128 -d 1 -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_asymmetric --source-total-n 128 --head-col-offset 0` |
| KV Quant-V | `-k 1024 -n 128 -q 128 -d 1 -t 0 --quant-mode spinquant_signed_symmetric` | `-k 1024 -n 128 -q 128 -d 1 -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric --source-total-n 1024 --head-col-offset 0` |
| Softmax | `-batch 1 -heads 32 -seqq 1024 -seqk 1024 -seqk-stride 1024 -mask 1` | Same |
| Head Concat | `-batch 1 -seq 1024 -heads 32 -headdim 128` | Same shape plus `--layout-to gemm_a_tiled` |
| ElAdd | `-n 4194304` | `-m 1024 -k 4096` |
| SiLU | `-n 14680064` | `-m 1024 -k 14336` |
| ElMul | `-n 14680064` | `-m 1024 -k 14336` |

## Suggested Debugging Order

1. Investigate prefill ElAdd's `2.196x` regression.
2. Profile RoPE Q/K, whose fused paths regress both decode and prefill.
3. Preserve and build on the prefill Hadamard R3-Q, Head Concat, and SiLU
   wins.
