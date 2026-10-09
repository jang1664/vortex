# C1–C4 decoder versus Rev5_v2 aggregate: latency summary and QK diagnosis

2026-10-09. One decoder layer with actual model dimensions and all heads.
The summary tables compare all four candidates against their Rev5_v2
Llama3-8B B1/S1024 prefill aggregates. C4 uses its previously recorded decoder
wall measurement. Earlier C4 same-image independent replay experiments are
retained separately as supplementary evidence. This supersedes
the earlier unmatched-variant C1–C3 comparison. Historical measurements remain
unchanged. A separate section below reports fresh C1–C4 first-step decode
measurements against Rev5_v2. A compact measured-versus-estimate table is in
[MEASURED_VS_ESTIMATE_REV5_V2.md](MEASURED_VS_ESTIMATE_REV5_V2.md).

## Rev5_v2 remeasurement update: fixed decoder golden reference

2026-10-09, after the selective hardware rerun. These values use the actual
Rev5_v2 standalone measurements. Current comparison tables below use Rev5_v2;
explicitly labeled historical diagnostics retain their original measurements.

Keep the recorded decoder wall time fixed, with the same KV-dequant exclusion.
Compute `rev5_v2 = documented_rev5 + new_reorder + (new_QK - old_QK)
+ (new_KV_quant - old_KV_quant)`; the KV-quant replacement applies only to
C4 decode. All other operation results are preserved. Contributions use device cycles at
100 MHz, weighted by calls per layer. No decoder host-time correction is added.
This is a targeted aggregate update for these workloads, not a full-suite
compose/plot regeneration or a new whole-decoder measurement.

| Stage | Candidate | Measured golden (s) | Rev5_v2 estimate (s) | Original Rev5 error (%) | Rev5_v2 error (%) |
|---|---|---:|---:|---:|---:|
| Prefill | C1 | 285.319981 | 280.534557 | -3.20% | **-1.68%** |
| Prefill | C2 | 46.042892 | 45.264144 | -11.14% | **-1.69%** |
| Prefill | C3 | 31.832401 | 31.454269 | -6.68% | **-1.19%** |
| Prefill | C4 | 31.060445 | 30.299684 | -2.45% | **-2.45%** |
| First decode step | C1 | 4.087995 | 4.064528 | -5.30% | **-0.57%** |
| First decode step | C2 | 0.499419 | 0.515983 | -35.38% | **+3.32%** |
| First decode step | C3 | 0.272474 | 0.278294 | +0.98% | **+2.14%** |
| First decode step | C4 | 0.113003 | 0.118120 | +4.01% | **+4.53%** |

Error is `(estimate - measured) / measured * 100`. All rows are Llama3-8B,
B1, one layer. Prefill uses S1024; decode uses past KV1024 and valid KV1025,
the first generated token rather than the 128-token average.

| Stage | Candidates | Added reorder (s/layer) | QK increase (s/layer) |
|---|---|---:|---:|
| Prefill | C1/C2 | 1.94073155 | 2.41013024 |
| Prefill | C3 | 1.74870251 | 0 |
| First decode step | C1/C2 | 0.18375318 | 0.00949152 |
| First decode step | C3 | 0.00314206 | 0 |

C1/C2 share the same standalone C1 QK/reorder measurements under the existing
aggregate routing. C3 adds Q/K/V head reorders only. C4 decode replaces the
compact KV-quant inputs with padded-source measurements: 0.00470920 s becomes
0.00529120 s per layer (+0.00058200 s); C4 prefill is unchanged.
Unlike the earlier decoder-profile accounting correction, Rev5_v2 independently
measures these operations; their timings need not equal the decoder's internal
profile timings. Other TCU operations retain their historical Rev5 results.
The previously recorded decode final-output checks fail, so the decode rows
remain diagnostic timings. C4 also retains the image difference documented below.

Sources: [exact comparison](../rev5_v2/decoder_comparison.json),
[selected correction rows](../rev5_v2/decoder_comparison_rows.csv),
[reproducible calculation](../rev5_v2/compare_decoder.py), and
[QK/reorder preservation checks](../rev5_v2/completion.json), and
[C4 KV-quant remeasurement](../rev5_v2/kv_quant_padded/SUMMARY.md).

## C1–C4 at a glance: Llama3-8B, B1/S1024 prefill, one layer

### Actual measurement versus estimate

| Candidate | Measured (s) | Rev5_v2 estimate (s) | Estimate error (%) |
|---|---:|---:|---:|
| **C1** | 285.320 | 280.535 | **-1.68%** |
| **C2** | 46.043 | 45.264 | **-1.69%** |
| **C3** | 31.832 | 31.454 | **-1.19%** |
| **C4** | 31.060 | 30.300 | **-2.45%** |

**Measured is the decoder wall time with KV dequant excluded by default, as
assumed in the comparison.** The default deduction is 0.118957810 s for C1
and 0.118866092 s for C2, using untimed warmup host measurements. C3/C4 have no
KV-dequant deduction. Original raw wall times are retained in the detailed
measurement section below.
Estimate error = `(rev5_v2 estimate − measured) / measured × 100`.
Negative values mean that Rev5_v2 underestimates decoder time under this scope.

### Rev5 to Rev5_v2 cycle increase against the measured golden reference

Measured above remains the **fixed golden reference**, with the same default
KV-dequant exclusion. Rev5_v2 adds the independently measured reorder work
and replaces the TCU QK timings. The table shows the increase over original
Rev5 and the remaining error against measured.

All cycle values are in **million cycles (Mcycle), at 100 MHz**:
`Mcycle = seconds × 100`. Measured is a **wall-time cycle equivalent**, not a
hardware counter total. Rev5 and its additions use device cycles; host launch
costs are not added to the correction.

| Candidate | Measured golden (Mcycle equivalent) | Original rev5 (Mcycle) | + Reorder (Mcycle) | + QK correction (Mcycle) | Rev5_v2 (Mcycle) | Increase over original rev5 (Mcycle / %) | Error vs measured (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| **C1** | 28,531.998 | 27,618.369 | +194.073 | +241.013 | **28,053.456** | **+435.086 / +1.58%** | **-1.68%** |
| **C2** | 4,604.289 | 4,091.328 | +194.073 | +241.013 | **4,526.414** | **+435.086 / +10.63%** | **-1.69%** |
| **C3** | 3,183.240 | 2,970.557 | +174.870 | +0.000 | **3,145.427** | **+174.870 / +5.89%** | **-1.19%** |
| **C4** | 3,106.044 | 3,029.968 | +0.000 | +0.000 | **3,029.968** | **+0.000 / +0.00%** | **-2.45%** |

`rev5_v2 = original_rev5 + reorder_cycles + QK_correction_cycles`.
Increase = `(rev5_v2 − original_rev5) / original_rev5 × 100`.
Error = `(rev5_v2 − measured) / measured × 100`, retaining the first
table's fixed denominator. Totals and percentages are computed before rounding.

- **Reorder**: add omitted Q/K/V head reorders and, for C1/C2, V transposes.
  The new standalone device times are 1.94073155 s for C1/C2 and
  1.74870251 s for C3. C1/C2 share measurements under aggregate routing.
- **QK**: the remeasured finite-input TCU QK adds 2.41013024 s for C1/C2.
  These additions come from Rev5_v2 raw measurements, rather than the earlier
  decoder-profile gaps retained in the historical diagnosis below.

These are aggregate updates from the Rev5_v2 standalone measurements;
the historical rev5 data remains unchanged. They cover the identified costs,
not every remaining source of error. C3 has no TCU QK correction. C4 has no
extra head-reorder launches and uses improve MXU QK, so both additions are zero.
The measured golden reference is unchanged for every candidate.

All four estimates start from Rev5's no-area-normalization E2E total including
Hadamard, divided by 32 layers, with the above Rev5_v2 updates. All rows use Llama3-8B B1/S1024 prefill, one
layer and all heads. Final outputs passed the recorded acceptance criteria;
C4's stricter local PV diagnostic remains a failure, as detailed below.

Remaining errors are not attributed entirely to launch overhead. The decode comparison appears separately below; other shapes remain untested. Historical
diagnostic tables below retain their explicitly labeled wall-versus-aggregate ratios;
those use the opposite direction and a different denominator from the estimate
errors in the two tables above. The supplementary reorder-subtraction table
retains its common-scope accounting view; it does not redefine the measured
golden reference used for the rev5 cycle correction.

### Historical C4 Rev5 baseline and measurement provenance

| Quantity | Value |
|---|---:|
| Rev5 C4 full 32-layer aggregate | 969.58987456 s |
| Rev5 C4 per-layer aggregate | 30.29968358 s |
| Previously measured C4 decoder wall | 31.060444846 s |
| Rev5 estimate minus measured wall | -0.760761266 s / -2.449293% of measured wall |
| Included measured operation rows | 24; no estimated or missing rows |

Rev5 uses `all_fpint_gemm_improve_fused_layout_spinquant`; its GEMM rows were
measured with `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_fix_pad`,
and vector rows with `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_axi_fix`.
The connected C4 measurement uses
`improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update` for all
operations. The comparison therefore includes image/implementation and input
context differences; it is not an isolated measurement of launch overhead.
No new FPGA run or historical data modification was needed for this correction.

Sources: [C4 rev5 selected rows](rev5_C4_llama3_b1_s1024_rows.csv) and
[exact comparison/provenance](C4_B1_S1024_VS_REV5_comparison.json).
The operation sum was also checked against rev5's prepared no-area-normalization
`total.csv`. The earlier 31.109715 s independent replay sum is retained only in
the supplementary table below and is not used as the first table's baseline.

## Decode: measured versus rev5_v2 estimate

Llama3-8B, one decoder layer, B1, past KV1024, first generated token
(valid KV1025). Measured is the recorded median of three decoder runs with
KV dequant excluded by default. It is unchanged in this comparison. Estimates
use the corresponding first step, not the 128-token average.
Error = `(estimate - measured) / measured * 100`.

### Current measured versus estimate

| Candidate | Measured (s) | Rev5_v2 estimate (s) | Estimate error (%) |
|---|---:|---:|---:|
| **C1** | 4.087995 | 4.064528 | **-0.57%** |
| **C2** | 0.499419 | 0.515983 | **+3.32%** |
| **C3** | 0.272474 | 0.278294 | **+2.14%** |
| **C4** | 0.113003 | 0.118120 | **+4.53%** |

### Error change from Rev5 to Rev5_v2

All corrections below use independently measured device cycles at 100 MHz,
weighted by calls per layer. No decoder profile host time is added to the
estimate. Positive absolute-error reduction means improvement; negative means
the absolute error grew. Corrections are in seconds, reduction is in percentage points.

| Candidate | Rev5 estimate (s) | Rev5 error (%) | + Reorder (s) | QK delta (s) | KV quant delta (s) | Rev5_v2 error (%) | Absolute-error reduction (pp) |
|---|---:|---:|---:|---:|---:|---:|---:|
| **C1** | 3.871283 | -5.30% | +0.18375318 | +0.00949152 | +0.00000000 | **-0.57%** | **+4.73** |
| **C2** | 0.322738 | -35.38% | +0.18375318 | +0.00949152 | +0.00000000 | **+3.32%** | **+32.06** |
| **C3** | 0.275152 | +0.98% | +0.00314206 | +0.00000000 | +0.00000000 | **+2.14%** | **-1.15** |
| **C4** | 0.117538 | +4.01% | +0.00000000 | +0.00000000 | +0.00058200 | **+4.53%** | **-0.52** |

C1/C2 improve by 4.73/32.06 percentage points. C3/C4 absolute errors grow
by 1.15/0.52 points. Correcting omitted work or physical inputs does not guarantee
a closer total when other differences already offset the missing cost.

C4 uses the new B1 physical-row 8 K/V measurements at cache position 1024,
each called 8 times per layer: K 32,930 cycles, V 33,210 cycles. Their combined
cost rises from 4.70920 ms to 5.29120 ms (+0.58200 ms), explaining the change
from +4.01% to +4.53%. It does not use the mean over all remeasured cache lengths.

These are targeted aggregate updates from the raw DB, not a new decoder run
or a full-suite compose/plot regeneration. Historical Rev5 data is unchanged.
The recorded strict CPU final-output checks failed; these remain diagnostic
timings. C4 decoder used `v4_nodsp_fsm_update`; the new KV-quant measurements
used `v4_fix_pad`, and preserved historical operations retain their original
images. This is not a same-image isolation of launch overhead.

Sources: [fixed decoder measurements](C1_C4_DECODE_GROUPED_VS_REV5_comparison.json),
[exact updated totals](../rev5_v2/decoder_comparison.json),
[selected raw measurement contributions](../rev5_v2/decoder_comparison_rows.csv),
[reproducible calculation](../rev5_v2/compare_decoder.py), and
[C4 KV-quant rerun](../rev5_v2/kv_quant_padded/SUMMARY.md).

## Supplementary C4 experiments: same-image independent operation aggregate

**This supplementary table uses the independent operation sum as denominator.** Each operation was
independently replayed with the same C4 image, board, actual input tensors,
and arguments as the connected decoder. All operations use C4's layout-fused
implementation. These supplementary results need no postprocessing
deduction for dequant, extra reorders, or TCU QK conversion. They demonstrate
agreement with the corresponding same-image operation sum, not with rev5.

| Model | Case | Independent operation sum (s) | Connected decoder wall (s) | Wall minus sum (s) | Difference (%) | Final output |
|---|---|---:|---:|---:|---:|---|
| Llama3-8B | Prefill B1/S1024 | 31.109715 | 31.060445 | -0.049271 | **-0.158%** | PASS |
| Llama2-7B | Prefill B1/S1024 | 50.062635 | 50.068739 | +0.006104 | **+0.012%** | PASS |
| Llama3-8B | Decode B1, past KV1024, query1 | 0.131971 | 0.134433 | +0.002462 | **+1.866%** | FAIL; diagnostic timing |
| Llama2-7B | Decode B1, past KV1024, query1 | 0.166981 | 0.170778 | +0.003798 | **+2.274%** | FAIL; diagnostic timing |

The independent sum is device cycles divided by 100 MHz. Connected wall
includes launch/wait and CPU bookkeeping, but excludes setup tensor transfers,
output downloads, verification, dumps, and counter queries. Runtime polling
sleeps and the fixed 0.5 ms settle delay were removed. Prefill uses one timed
sample after warmup; decode uses the median of three. Profiling and wall timing
are separate executions, so the small negative prefill difference is run
variation, not negative launch overhead.

| C4 measurement condition | Value |
|---|---|
| FPGA alias | `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update` |
| Geometry / frequency / board | TH16 / MXU16 / 100 MHz / `0000:2a:00.1` |
| Model scope | One full decoder layer; finite random inputs/weights; all heads; no embedding, LM head, or sampling |
| Decode cache | Past 1024 + one appended token = 1025 valid entries; capacity 1152; QK target_N and PV target_K aligned to 1056 |
| Decode parent layout | Physical `origin_M=8`, logical `target_M=1`, in both independent and connected runs |
| Measurement revision | Original busy-poll prefill and decode experiments, before the later decoder KV-quant direct-load optimization |

Prefill final outputs pass the recorded acceptance criteria, but the stricter
same-input PV diagnostic still fails for both models. Decode final outputs also
fail due to the previously diagnosed PV arithmetic problem. The latency rows
preserve these outcomes and do not establish full numerical correctness.
They are one-step decode measurements, not 128-token generation latency or TTFT.

| Model | Prefill final relative L2 error | Decode final relative L2 error | Decode packed KV/qparam mismatches |
|---|---:|---:|---:|
| Llama3-8B | 0.1120% | 0.3560% | 0 |
| Llama2-7B | 0.0905% | 0.2785% | 0 |

The later quant input optimization reduced isolated decode quant cycles but
was not a new whole-decoder wall measurement in the above experiments; those
numbers are not substituted into this table.

Sources: [C4 prefill report](SUMMARY.md), [C4 decode report](DECODE_B1_P1024.md),
and [later KV-quant optimization](PARALLEL_DECODERS_KV_QUANT_20261009.md).
Exact values come from `summary.json` under
`build_llama_decoder_c4/results/b1_s1024_busy_poll_20261009/` and
`build_llama_decoder_c4/results/decode_b1_p1024_20261009/`.

## C1–C3 measured wall and dequant adjustment

| Candidate | Rev5_v2 / layer (s) | Raw decoder wall (s) | Dequant removed (s) | Adjusted wall (s) | Estimate error vs adjusted wall (%) | Final output |
|---|---:|---:|---:|---:|---:|---|
| C1 | 280.534557 | 285.438939 | 0.118958 | 285.319981 | -1.68% | PASS |
| C2 | 45.264144 | 46.161758 | 0.118866 | 46.042892 | -1.69% | PASS |
| C3 | 31.454269 | 31.832401 | 0.000000 | 31.832401 | -1.19% | PASS |

C1 has one measured wall sample after warmup; C2/C3 use the median of three.
Only final-output correctness gates these measurements, as requested. Numeric
tolerances and the fraction/L2/cosine/finite guards are unchanged. Optional
local diagnostics do not override a passing final-output check.

`decoder.run(false, {})` is timed. Setup uploads/allocation, validation, dumps,
and counter queries are excluded; launch/wait and small CPU bookkeeping remain.
Each mandatory warmup records `warmup_profile.csv` outside the wall timer.
No extra profiling graphs are run (`--profile-repetitions 0`).

Postprocessing uses:

```text
adjusted_wall = measured_wall - sum(KV-dequant launch/wait host_seconds)
```

The subtracted time comes from that candidate’s mandatory warmup. It includes
`vx_start`/`vx_ready_wait`, excludes counter reads, and is an estimate of removing
dequant operations from the wall time. The actual graph still executes them.
C1/C2 subtract exactly 16 operations: eight `key.*.fp16` and eight
`value.*.dequant`. C1 static weight dequantization is outside the measured graph
and is not subtracted again. C3 has no dequant operations. Reorders are retained.

| Candidate | Wall samples (s) | Dequant device cycles / 100 MHz (s) | Previous raw wall (s) | New raw wall change |
|---|---|---:|---:|---:|
| C1 | 285.438939 | 0.118557 | 287.021792 | -0.551% |
| C2 | 46.172961, 46.161758, 46.159376 | 0.118477 | 47.637037 | -3.097% |
| C3 | 31.837745, 31.832401, 31.824960 | 0.000000 | 33.235482 | -4.222% |

## Historical Rev5 diagnostic: subtracting head reorders

This historical table compares against original Rev5, which omitted reorders.
It is not the current Rev5_v2 comparison; Rev5_v2 includes those operations.

These are accounting adjustments to the measured wall time, not reruns with
operations disabled. The connected graph still executes every required reorder.
Each subtraction uses launch/wait host time from the untimed warmup, so it is
an estimate rather than an exact measurement of a graph without these operations.

| Candidate | Rev5 / layer (s) | Raw wall (s) | KV dequant removed (s) | Reorder removed (s) | Wall after both subtractions (s) | Difference (s) | Difference (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| C1 | 276.183695 | 285.438939 | 0.118958 | 2.141517 | 283.178464 | +6.994769 | +2.533% |
| C2 | 40.913282 | 46.161758 | 0.118866 | 2.183773 | 43.859119 | +2.945836 | +7.200% |
| C3 | 29.705566 | 31.832401 | 0.000000 | 1.990838 | 29.841562 | +0.135996 | +0.458% |

Reorder removal includes Q/K/V head-major conversion for every candidate,
plus the dequantized V transpose for C1/C2. It does **not** remove the regular
output head-concat operation, which is already counted in rev5.

| Candidate | Q/K/V head-major conversion, host time (s) | V transpose, host time (s) |
|---|---:|---:|
| C1 | 1.985771 | 0.155746 |
| C2 | 2.020838 | 0.162935 |
| C3 | 1.990838 | 0.000000 |

After matching this scope, C3 is within **0.458%** of the rev5 sum. C1/C2 still
have a TCU QK difference; the controlled experiment below identifies its main
cause. Remaining differences in other operations have not all been isolated.

## What head reorder does

Projection and standalone RoPE buffers contain `[B, S, H, D]`: all heads of
one token, then all heads of the next token. Per-head QK/PV GEMMs require
`[B, H, S, D]`: all tokens of one head, then all tokens of the next head.
The decoder therefore performs three on-device reorders for Q, K and V.
C1/C2 additionally transpose each dequantized V for the `b_colmajor` TCU input.
C3 naive MXU consumes row-major V directly and needs no such V transpose.
These are separate from the output head-concat kernel already included in rev5.
The original Rev5 isolated benchmark starts with correctly laid-out inputs; its sum omits these
connections. Removing them from the connected graph without changing consumers
would feed incorrect rows into attention. They are removed only in the common-scope accounting table above.

The following historical decoder-profile gaps diagnose original Rev5; current
Rev5_v2 additions use the independent measurements in the cycle table above.

| Candidate | Extra reorder device time (s) | QK profile minus rev5 (s) | Concat profile minus rev5 (s) |
|---|---:|---:|---:|
| C1 | 2.141241 | +2.404438 | +0.000083 |
| C2 | 2.183502 | +2.414212 | +0.000479 |
| C3 | 1.985731 | +0.000958 | +0.000514 |

## Why TCU QK differs: confirmed input-dependent conversion cost

The isolated rev5 benchmark initializes FP16 buffers with arbitrary random
**bytes**, not bounded finite FP16 numbers. For this shape, the reproduced
benchmark output contains 1,048,491 NaNs and 85 infinities: **every output is
nonfinite**. Actual decoder Q/K produces finite attention scores.

The TCU store path converts each accumulated FP32 output to FP16 using the
software function `fp32_to_fp16_bits` in `kernel/include/vx_tensor.h:47`, called
by `store_matrix_sync` near line 403. NaN/Inf takes an early return. Finite
normal results execute additional rounding instructions and SIMT branches.
Thus the benchmark input changes instruction count and runtime even when
shape, memory traffic, and GEMM variant stay the same. This is distinct from
the previously deferred RTL FP16 subnormal arithmetic issue.

### Existing per-layer QK result (32 heads)

Device cycles divided by 100 MHz, excluding host launch overhead.

| Candidate | Backend | Rev5 QK (s) | Decoder QK (s) | Difference (s) | Difference (%) |
|---|---|---:|---:|---:|---:|
| C1 | TCU | 7.082181 | 9.486619 | +2.404438 | +33.951% |
| C2 | TCU | 7.082181 | 9.496393 | +2.414212 | +34.089% |
| C3 | Naive MXU | 0.234203 | 0.235161 | +0.000958 | +0.409% |

### Controlled FPGA replay

C1 `tcu_th16_c1_v3_axi_fix`, board `0000:2a:00.1`, 100 MHz.
The **actual historical standalone binary** was loaded once. M=N=1024, K=128,
TH16, grid 128×64, block 16. A/B/C were allocated once and held at
`0x10000` / `0x50000` / `0x90000` across every case. Only input bytes changed;
upload and output checks were outside launch/wait timing. Each pattern ran
three times; medians are shown. Counters are MCYCLE `0xB00` and MINSTRET `0xB02`,
core 0. No kernel, runtime, or RTL changes were made for this replay.

| Input pattern | Median cycles / head | Instructions / head | Device time / head (ms) | NaN outputs | Inf outputs |
|---|---:|---:|---:|---:|---:|
| Historical random bytes, srand(50) | 22,119,527 | 93,338,171 | 221.195 | 1,048,491 | 85 |
| Saved decoder Q/K, first head | 29,680,323 | 127,942,575 | 296.803 | 0 | 0 |
| All zeros (control) | 24,286,896 | 100,678,373 | 242.869 | 0 | 0 |
| Historical random bytes, repeated last | 22,141,019 | 93,338,171 | 221.410 | 1,048,491 | 85 |

Changing only raw-byte inputs to actual decoder Q/K adds **34.182% cycles**
and **37.074% instructions**. All 1,048,576 actual-input output elements match
the saved decoder first-head score buffer **bit for bit**, on all three repeats.
Only three finite output elements are subnormal.

The replay adds 7,560,796 cycles/head, or **2.419455 s for 32 identical heads**.
The actual 32-head decoder gap is 2.404438 s (C1) / 2.414212 s (C2). This close
agreement accounts for the dominant QK difference. The extrapolation repeats
one head; it is not a measurement of all heads with identical input statistics,
nor a replacement of historical values. The original rev5 result was
22,131,815 cycles/head, within 0.056% of the raw-byte replay median.

| Alternative explanation | Evidence / conclusion |
|---|---|
| Different QK shape, padding, or head count | Same 1024×128 by 128×1024, no tails, 32 heads per layer. |
| Different TCU implementation or register spills | Historical and linked TCU bodies are both 3,968 bytes; instructions match after normalizing one GOT relocation. Same 32-byte stack frame. |
| Different operand addresses | Fixed in the controlled replay; the large gap persists. |
| Software conversion and input values | Instruction count grows by 34,604,404; cycle gap reproduced with only input replacement. |
| Remaining small variation | Allocation/code placement and run variation may affect residual differences; not fully attributed. |

The old random-byte TCU benchmark underestimates real finite-data QK time.
Making decoder scores NaN to match that timing would invalidate inference.
This finding does not establish a universal 34% correction for all TCU shapes:
conversion cost is relatively more visible for this short K=128 GEMM.
No historical raw DB, suite, plot, or latency value has been overwritten.

## Matching the measured kernel variants

The source of truth is rev5’s C1 `kernel_variants.json`, run
`20261004T060802877116Z`; the other recorded run has the same selections.
Both kernel variant and applicable standalone launch-policy helpers are reused.

| App | Selected variant |
|---|---|
| eladd | row_coalesced_cursor, row size 4096 |
| concat | chunk16_packed |
| SiLU | linear |
| KV quant/dequant | groupwise_fp16 |
| RMSNorm | adaptive_m_rows |
| RoPE | task_chunk16 |
| Hadamard | r3_shuffle |
| softmax | rev2_shuffle_grouped |
| TCU | b_colmajor |
| elmul / naive GEMM | existing default |

The fixed warp-per-group quant launch was replaced with the standalone host
helper: this prefill uses thread-per-group, while single-token decode retains
warp-per-group. Dequant also uses its standalone helper. RoPE grid limits and
concat/SiLU work-item counts match standalone. Device thread/warp counts remain
configuration-derived. Existing standalone kernel implementations and RTL were
not edited. Each candidate build was reconfigured and its resident binary rebuilt.

The real model’s arithmetic parameters remain unchanged: attention scale is
1/sqrt(128), whereas the old isolated softmax cases omit scale and use default
1/sqrt(64); current V quantization is asymmetric, while rev5 uses symmetric V.
These are semantic parameters, not kernel variants. The existing independent
CPU fixtures were preserved rather than altering model arithmetic for timing.

## Baseline and reproducibility

Rev5 no-area-normalization E2E totals, including Hadamard, are divided by
32 decoder layers. All 24 included rows per candidate are measured; no
interpolation or missing rows. Rev5 excludes all dequantization. C2 history
reuses C1 vectors/TCU and C3 naive GEMMs; connected C2 runs entirely on C2.
C3 history reuses C1 vectors; connected C3 runs entirely on C3. All run at 100 MHz.
Current C1 ran on 0000:2a:00.1; C2/C3 ran on 0000:3d:00.1. A selected rev5 C1
raw log records 0000:3d:00.1, so matching images does not imply the same physical
board as every historical measurement.
No latency_on_hw suite, raw database or historical figure was modified.

- [Exact results](C1_C3_B1_S1024_MATCHED_comparison.json)
- [Per-operation profiles versus rev5](C1_C3_B1_S1024_MATCHED_operations.csv)
- [Historical selected variants](C1_C3_MATCHED_variants.json)
- [Historical measured rows](rev5_llama3_b1_s1024_rows.csv)
- [Previous comparison](C1_C3_B1_S1024_VS_REV5.md)
- Analysis: `build_decoder_compare_20261009/matched_analyze.py` and `matched_report.py`.

- C1 raw data, scripts and provenance: `build_llama_decoder_c1_parallel_20261009/results/matched_variants_b1_s1024_20261009/`.
- C2 raw data, scripts and provenance: `build_llama_decoder_c2_parallel_20261009/results/matched_variants_b1_s1024_20261009/`.
- C3 raw data, scripts and provenance: `build_llama_decoder_c3_parallel_20261009/results/matched_variants_b1_s1024_20261009/`.

Reproduce from the configured build using `ci/run_black.sh hw --fpga-bin
<candidate alias> --app llama_decoder_Cn --run-only --args "--model llama3-8b
--batch 1 --seq-len 1024 --mode timing --repetitions <1 or 3>
--profile-repetitions 0 --fixture <existing candidate fixture> --output <new directory>"`.

## QK replay provenance

- [All 12 replay samples](C1_QK_input_probe.csv).
- Probe source, Makefile, full log, and raw CSV:
  `build_llama_decoder_c1_parallel_20261009/tests/regression/qk_input_probe/`.
- Static assembly/input audit:
  `build_llama_decoder_c1_parallel_20261009/results/qk_static_audit/`.
- Actual input files: C1 matched timing directory, `q_hadamard.bin` (first head)
  and `key.0.0.fp16.bin`; reference output: first head of `scores.bin`.
- Historical binary: `build_latency_llama3/tests/regression/sgemm_tcu/kernel.vxbin`.
- Historical binary SHA-256: `edb4b3e0732a5d9f062ef6dbcf4ff22e69a6d74435d9f47ecad00b1e4b160103`.
- Probe source SHA-256: `71287cbc042b3652efe1ddd41b5831c56477b087f2a739d940df7304fdba32d9`.

Reproduction from `build_llama_decoder_c1_parallel_20261009`:

```bash
bash ci/run_black.sh hw --fpga-bin tcu_th16_c1_v3_axi_fix \
  --app tests/regression/qk_input_probe --run-only
```

The probe has fixed dimensions and input paths in its recorded source/Makefile.
The historical standalone binary and current replay host/runtime are intentionally
separate: this isolates input-dependent device execution on the original code.
