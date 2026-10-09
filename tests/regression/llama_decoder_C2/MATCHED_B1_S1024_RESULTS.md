# C2 matched-variant B1/S1024 measurement (2026-10-09)

One Llama3-8B decoder layer, batch 1, 1024 prefill tokens, all 32 query heads and
8 KV heads. Image:
`naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_axi_fix`.
FPGA `0000:3d:00.1`, Slurm allocation 5784, 100 MHz.

**Final-output PASS**, both before and after the three timed repetitions.
The user's updated acceptance policy checks only the existing C++ final-output
gate. Intermediate comparisons were not run. Numeric thresholds are unchanged:
atol/rtol 0.005, violating fraction <=2%, relative L2 <=0.01, cosine >=0.999,
and no nonfinite values. The result has relative L2 0.000898854866,
max absolute error 0.01171875, 17,038/4,194,304 violating elements, zero nonfinite
values and cosine 0.999999600. This does not claim the previously diagnosed TCU
subnormal defect was fixed.

## Timing and requested dequantization correction

| Repetition | Original decoder wall (s) | Wall minus KV dequant host time (s) |
|---|---:|---:|
| 0 | 46.172960773 | 46.054094681 |
| 1 | 46.161757871 | 46.042891779 |
| 2 | 46.159376247 | 46.040510155 |
| Median | **46.161757871** | **46.042891779** |

The timer encloses only `decoder.run(false,{})`. Setup transfers, intermediate
downloads, counter queries and final checking are outside it. KV dequantization
still executes in each graph; the second column is an accounting correction in
postprocessing, not an independently executed graph without dequantization.

The mandatory warmup records 127 operations in `warmup_profile.csv`:

- All operations: 4,614,457,778 cycles = 46.144577780 s.
- KV dequantization: 16 operations, 11,847,669 cycles = 0.118476690 s.
- Summed KV dequant `host_seconds`: **0.118866092 s**, including launch/wait.
  This is the value subtracted from each raw wall sample.

The raw wall median is 0.03723% above the warmup cycle sum. Warmup and wall
samples are different graph executions; their difference includes run variation.
There were no additional profiling graph passes (`--profile-repetitions 0`) and
no duplicate verify graph before timing mode's built-in preflight.

## Adapter changes for this run

The shared decoder now selects the independent benchmark's defaults for:

- Head concat: `kernel.chunk16_packed.cpp`.
- Eladd: `ELADD_ROW_COALESCED_CURSOR`, row size 4096.
- SiLU: `kernel.linear.cpp`.
- KV dequantization: `kernel.groupwise_fp16.cpp`, matching launch helpers.
- KV quantization: the existing work-item, mapping and launch helpers instead of
  a fixed decoder-specific warp mapping.

The standalone kernel implementations, RTL, fixture and frozen latency_on_hw
results were not changed. Explicit head and KV reorder kernels remain in the
connected graph and in its measured time. The raw median is 3.097% below the
earlier adapter implementation's 47.637037274 s; the earlier report is preserved
in [B1_S1024_RESULTS.md](B1_S1024_RESULTS.md).

## Artifacts

`build_llama_decoder_c2_parallel_20261009/results/matched_variants_b1_s1024_20261009/`

- `run.sh`: exact execution; timing mode, three wall repetitions, no extra
  profiles or intermediate diagnostics.
- `timing/timings.csv`, `timing/warmup_profile.csv`, `timing/verification.json`.
- `summary.json`: raw and corrected wall samples, dequant totals and final gate.
- `timing.log`, `session.log`, `session.txt`: command, board and allocation.
- `sha256.json`: executable/device/runtime/config/fixture fingerprints.

For the corrected total, select `key.*.fp16` and `value.*.dequant` in
`warmup_profile.csv`; `value.*.fp16` is a transpose and must remain included.
