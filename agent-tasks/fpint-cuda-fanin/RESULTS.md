# rtl-c4-v1 CUDA matrix accuracy sweep

## Outcome

Completed the 100-seed experiment on RTX 3090 using the existing, unchanged
`rtl-c4-v1` CUDA arithmetic. All 13,200 expected metric rows are present,
with no duplicate/missing coordinates or nonfinite metrics. Each matrix has
256 output elements. The FPINT path evaluated 2,200 matrices, totaling 563,200
output elements. CPU- and GPU-FP64-reference metric rows are identical.

At K=32768, mean ULP errors and Student-t 95% confidence intervals are:

| Direction | FPINT rtl-c4-v1 CUDA | NVIDIA Tensor Core |
| --- | ---: | ---: |
| QCOL | 0.005625 [0.003424, 0.007826] | 4.601797 [1.040096, 8.163498] |
| QROW | 3.019375 [0.864433, 5.174317] | 1.775234 [1.264025, 2.286444] |

QCOL has a lower sample mean at every tested K. QROW does not have a consistent
advantage: its mean is lower at K=64,256,2048 and higher at the other eight K
values. Many QROW confidence intervals overlap; sample-mean ordering alone is
not a statistical significance claim.

The tested arithmetic paths place FP16 rounding differently: QROW rounds
input-times-scale before its integer dot, whereas the Tensor Core baseline
rounds dequantized weights before GEMM. QCOL applies output scaling in FP32.
These operation-order differences are part of the measured methods. This
experiment measures error against FP64 calculations rounded to FP16; the prior
C4 RTL/SV/Python/CUDA bit-equivalence tests establish a separate property.

## Experiment configuration

- M=N=16; K=32,64,128,256,512,1024,2048,4096,8192,16384,32768.
- QCOL and QROW, signed asymmetric INT4, QBLOCK=MXU_K=16.
- 100 trials; seeds 20260729 through 20260828 inclusive.
- Input signs uniform; sampled exponent uniform in [-24,15]; mantissa field
  Normal(512,256), rounded/clipped to [0,1023], then values rounded to FP16.
- Weights uniform in [-8,7], zero points in [-4,3], scales in [2^-14,2^-11].
- Methods: `ours` = actual rtl-c4-v1 CUDA kernel for each K, `gpu_tensor_core`
  = PyTorch FP16 GEMM, `gpu_model` = existing auxiliary numerical model.
- References: CPU NumPy FP64 and GPU PyTorch FP64, each narrowed to FP16.
- Seed-level metrics: mean/max/p50/p95 ULP across 256 elements. Confidence
  intervals use the 100 seed-level means, not individual elements as trials.
- CUDA toolkit 12.8; PyTorch 2.11.0+cu126; RTX 3090; driver 570.211.01.
- Tensor Core kernel selection was verified at K=32 and K=32768.
- Recorded experiment timestamps: 2026-10-21 17:52:11 to 17:54:43 KST.

Historical runs used QBLOCK=32. Changing to C4's QBLOCK=16 changes quantization
grouping and generated scale/zero arrays. Historical-vs-current aggregate
differences must not be interpreted as an isolated arithmetic-version effect.
No historical CSVs were available in this worktree for a direct comparison.

## Code and validation

`fan_in_sweep.py data` now requires `--version legacy|rtl-c4-v1`. Geometry
defaults are version-specific; incompatible C4 geometry/device settings fail.
The CUDA path builds the existing kernel with FMA/FTZ disabled and does not
fall back to CPU. Legacy vectorized arithmetic and both baselines are retained.
Raw/summary CSVs and plot legends identify the model version; metadata records
source hashes and the CUDA build. Resume rejects mismatched versions, workload
configurations or recorded source hashes. Mixed-version CSV aggregation fails.

- 17 tests passed, including actual CUDA vs versioned Python output and FP32
  trace equality at K=32,64,128,32768, legacy arithmetic regression, version and
  geometry validation, resume rejection, and plotting.
- Explicit legacy and CUDA CLI smoke runs completed with their default block
  sizes (32 and 16 respectively); each produced 48 expected metric rows.
- A matching CUDA resume skipped both completed seeds and left the CSV
  byte-identical. Its log is `agent-tasks/fpint-cuda-fanin/resume_smoke.log`.
- Final main-run integrity checks confirmed all expected coordinates, source
  hashes, 100 seeds, 256 elements per matrix, and finite metrics.
- CPU-reference PNG inspected: both QCOL/QROW panels and versioned legend render
  correctly. CPU/GPU reference PNG, SVG and PDF files are generated.

## Artifacts and reproduction

Directory:
`analysis_workspace/numerical_acc/results/fpint_real_2scomp/20261021_rtl_c4_v1_qblock16_100seeds/`

- `raw_seed_metrics.csv`: 13,200 seed-level metric rows.
- `summary.csv`: 132 aggregate rows with 95% confidence intervals.
- `metadata.json`: complete configuration, tool versions, source/build hashes,
  execution command, Tensor Core profiler evidence and completion status.
- `fp16_int4_real2scomp_fanin_vs_ref_{CPU,GPU}.{png,svg,pdf}`: accuracy plots.
- `libfpint_cuda.so`, `cuda_build.log`: compiled numerical emulator and build log.
- Console log: `agent-tasks/fpint-cuda-fanin/run.log`.

From the source root, with the `vortex` conda environment active, choose a new
output directory:

```bash
python hw/unittest/fpint_emul/py/fan_in_sweep.py data \
  --version rtl-c4-v1 \
  --k-values 32,64,128,256,512,1024,2048,4096,8192,16384,32768 \
  --m 16 --n 16 --qblock 16 --trials 100 --base-seed 20260729 \
  --quant signed-asymmetric --device cuda:0 --verify-tensor-core \
  --output analysis_workspace/numerical_acc/results/fpint_real_2scomp/NEW_RUN
python hw/unittest/fpint_emul/py/fan_in_sweep.py plot \
  analysis_workspace/numerical_acc/results/fpint_real_2scomp/NEW_RUN/raw_seed_metrics.csv
```

## Mean ULP by K

CPU FP64 reference, rounded to FP16. Each entry is the mean across 100 trials;
full confidence intervals are in `summary.csv`. GPU-FP64-reference metrics are
identical for this run.

| K | QCOL FPINT | QCOL Tensor Core | QROW FPINT | QROW Tensor Core |
| ---: | ---: | ---: | ---: | ---: |
| 32 | 0.000117 | 0.750664 | 2.238398 | 1.651016 |
| 64 | 0.000313 | 1.775352 | 2.036289 | 2.868477 |
| 128 | 0.000664 | 2.046562 | 3.389727 | 1.490117 |
| 256 | 0.000820 | 2.088945 | 3.688945 | 4.666758 |
| 512 | 0.004063 | 1.943164 | 4.142734 | 4.029922 |
| 1024 | 0.001406 | 4.613281 | 4.251172 | 2.561406 |
| 2048 | 0.000781 | 2.293477 | 4.193906 | 5.082734 |
| 4096 | 0.001172 | 1.553789 | 6.358008 | 1.609531 |
| 8192 | 0.001758 | 2.455391 | 4.625000 | 2.051211 |
| 16384 | 0.002461 | 3.617969 | 4.472539 | 3.487773 |
| 32768 | 0.005625 | 4.601797 | 3.019375 | 1.775234 |
