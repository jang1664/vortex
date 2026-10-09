# Decode final-output failure: offline causal replay

2026-10-09. Llama3-8B, B1, past KV1024, first generated token, one decoder
layer. This investigation uses saved C1–C4 FPGA dumps and independent CPU
operations; it makes no FPGA allocation, performs no new hardware run, and
changes no RTL, kernel, fixture, tolerance, or latency database.

## Finding

PV arithmetic explains the final-output failure for this workload. Retain the
actual device probabilities and KV input, compute PV with the correct existing
backend arithmetic, and replay the rest of the layer on CPU: all four final
outputs pass the unchanged gate. Replaying the CPU tail from the actual wrong
PV continues to fail; that replay nevertheless agrees with the hardware final
output within the output tolerance. This separates propagated PV error from
an independent large error in the downstream decoder operations.

| Candidate | PV path | Diagnosed arithmetic defect | PV outputs explained bit-exactly |
|---|---|---|---:|
| C1 | FP16 TCU | FP16-to-FP32 subnormal input conversion multiplies magnitude by four | 4093 / 4096 |
| C2 | FP16 TCU | Same converter defect | 4093 / 4096 |
| C3 | Naive MXU | QROW input multiplier flushes subnormals; output converter also loses hidden bit for subnormal outputs | 4096 / 4096 |
| C4 | Improve MXU | Same QROW multiplier and output converter behavior | 4096 / 4096 |

The three remaining TCU differences have maximum absolute error 0.0000152588;
the defect model uses a float64 dot instead of the exact hardware reduction
schedule. This small residual is not fully attributed by this replay.

## Final-output counterfactual

The correct-PV column is a **CPU prediction**, not output from repaired FPGA
hardware. It uses actual upstream tensors; it does not replace them with
reference tensors. C1/C2 preserve FP16 dequantized V; C3/C4 preserve the intended
FP16 rounding of probability times scale before the INT4 accumulation.

| Candidate | Recorded hardware violations / 4096 | Recorded final relative L2 (%) | Correct PV + CPU tail violations / 4096 | Correct PV + CPU tail relative L2 (%) | CPU final gate |
|---|---:|---:|---:|---:|---|
| C1 | 470 | 0.30655 | 0 | 0.03802 | PASS |
| C2 | 473 | 0.30753 | 0 | 0.03802 | PASS |
| C3 | 635 | 0.35603 | 0 | 0.04474 | PASS |
| C4 | 635 | 0.35603 | 0 | 0.04474 | PASS |

The final gate is unchanged: atol/rtol0.005, the existing magnitude-dependent
absolute/relative rule, at most2% violating elements, relative L2<=1%,
cosine>=0.999, and no nonfinite values. Actual hardware outputs still FAIL.
The CPU tail from actual PV agrees with recorded hardware outputs with relative
L2 0.033–0.036%; its final comparison against the golden output still FAILs.

## Which MXU defect dominates?

| CPU replay intervention (C3 and C4) | Final violations / 4096 | Final relative L2 (%) | Gate |
|---|---:|---:|---|
| Fix only output FP32-to-FP16 conversion | 631 | 0.35395 | FAIL |
| Fix only QROW input scaling | 0 | 0.04436 | PASS |
| Fix both | 0 | 0.04474 | PASS |

The input scaler is dominant for this case. Adding the output-converter model
changes only three of the4096 observed PV values, but it is still a real RTL
arithmetic issue to address. Passing this one case with only the scaler repaired
does not establish that the output converter can be left incorrect generally.

## Why non-small input fixtures did not avoid it

Softmax normalization and KV scaling create small intermediate values even
when hidden states and weights are not subnormal. Among32800 nonzero attention
probabilities (32 heads x1025 keys),4695 are subnormal for C1/C2 and4694 for
C3/C4. The C1/C2 actual dequantized V tensors have no subnormals, so their
converter issue in this replay is triggered by probabilities.

For C3/C4,10245 of32800 nonzero probability-times-scale products fall below
FP16's smallest normal magnitude,2^-14 (about6.1035e-5). Scales themselves are
normal. A simple example is normal probability2^-10 times normal scale2^-5:
the correct FP16 result2^-15 is representable, but a flush-to-zero multiplier
returns zero. Repeated losses change the PV sum, then propagate through output
projection, residual, RMSNorm and MLP. The saved pre-PV checkpoints checked in
this run (normalization, projections, Q Hadamard and softmax) pass local limits;
context is the first failing checkpoint in that inspected sequence.

## RTL locations and minimal repair targets

- [TCU input converter](../../../../hw/rtl/tcu/VX_tcu_fedp_dsp.sv): line59 uses
  `127 - 14 - leading_zeros + 1`; for this10-bit leading-zero count the exponent
  must be `127 - 15 - leading_zeros`. Exhaustively evaluating the expressions
  for all2046 signed nonzero FP16 subnormals gives4x for the current expression
  and exact IEEE widening for the corrected expression. This is a Python
  evaluation of the RTL expression, not HDL simulation.
- [MXU input scaler](../../../../hw/rtl/core/gemm/VX_gemm_unit.sv): line1118
  instantiates `VX_fp16_mul` with `USE_LATENCY1_IP=1`. The selected native-half
  Xilinx path is in [VX_fp16_mul.sv](../../../../hw/rtl/core/gemm/VX_fp16_mul.sv)
  around line353. The existing measured input/output FTZ model plus output
  conversion model reproduces every saved C3/C4 PV value. A repair must preserve
  subnormal inputs and results while preserving the multiplier handshake and
  latency contract; this investigation does not select or implement that design.
- [MXU output converter](../../../../hw/rtl/core/gemm/VX_f32_to_f16.sv): the
  subnormal shift uses `fp32_mant_with_pad` without the normalized FP32 hidden
  one. Correct significand construction and guard/round/sticky handling are
  required at the subnormal and smallest-normal boundaries.

The SIMD FPU's separate `VX_fpu_f2f.sv` is not the TCU converter or MXU QROW
multiplier identified here. This evidence does not require a layout, cache,
request-ordering, or timing hypothesis to explain the observed failure.

## Evidence and limits

[Numeric results](DECODE_NUMERICS_OFFLINE.json) contain per-stage comparisons,
PV defect predictions, corrected-PV tail results, and single-defect ablations.
CPU script/log: `build_decoder_compare_20261009/offline_decode_debug/`.
Input dumps: `build_decoder_compare_20261009/gqa_grouped/C*/timing/`.
The script reuses existing reference arithmetic and numeric defect models.

Reproduce without FPGA:

```bash
source /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
"$py" /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build_decoder_compare_20261009/offline_decode_debug/analyze.py
```

This establishes a strong arithmetic cause and a passing CPU counterfactual
for the saved Llama3 case. It does not certify corrected RTL timing, other
shapes, or a new FPGA bitstream. RTL unit tests and eventual FPGA replay remain
necessary after implementing a repair.


## Two independent final-output reference modes

The checked-in `tests/regression/llama_decoder_common/dual_reference.py`
implements two reference modes for decode. Both start from the original fixture
inputs, parameters, and initial KV cache; neither takes actual FPGA intermediate
values as its reference inputs. IEEE replay is checked bit-exactly against the
saved fixture before comparison. This is stronger independence than the
actual-input counterfactual used in the diagnosis above.

- **IEEE**: existing reference, unchanged.
- **IP**: C3/C4 PV QROW scales probabilities with the characterized native-half
  multiplier's input/output FTZ behavior before INT4 accumulation; accumulation
  and output conversion remain correct. C1/C2 references are unchanged.

Neither mode models the custom TCU subnormal-times-four error or the custom MXU
output converter's missing hidden bit. Existing final-output tolerances apply
to both. IP acceptance can therefore tolerate a sufficiently small residual
converter error, but does not reclassify that bug as an IP limitation or fix it.

| Candidate | IEEE gate | IEEE relative L2 (%) | IP gate | IP relative L2 (%) | IP violations / 4096 |
|---|---|---:|---|---:|---:|
| C1 | FAIL | 0.30655 | FAIL | 0.30655 | 470 |
| C2 | FAIL | 0.30753 | FAIL | 0.30753 | 473 |
| C3 | FAIL | 0.35603 | PASS | 0.04811 | 0 |
| C4 | FAIL | 0.35603 | PASS | 0.04811 | 0 |

The IP reference reaches PASS for C3/C4, while the TCU converter error remains
visible as FAIL for C1/C2. Maximum absolute error against the IP reference is
0.001953125 for C3/C4. No new FPGA run was used.

The checker always records both results in `dual_reference.json`. Its default
exit gate is IEEE; `--gate ip` selects IP-compatible acceptance explicitly.
It preserves the fixture and the existing C++ `verification.json`; the C++
runner's original strict gate has not been changed. Current scope is one decode
step and the characterized MXU native-half multiplier, not arbitrary IP modes.

Validation: all four saved candidate dumps checked; IEEE outputs bit-exact to
the original fixtures; four CPU tests passed for normal products, input FTZ,
normal-input output underflow, and the smallest-normal rounding boundary.
[Recorded dual-reference results](DECODE_DUAL_REFERENCE.json).
