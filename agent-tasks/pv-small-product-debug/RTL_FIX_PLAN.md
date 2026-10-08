# PV numerical correctness: RTL repair plan

Status: proposed; no RTL changes or new simulations have been made for this plan.

## Evidence and scope

The combined model of two arithmetic defects matches every output bit in the four original failing PV cases and all 120 isolated hardware pattern cases. A match to that model demonstrates reproduction of the defects, not correct IEEE arithmetic.

| Path | Observed defect | Example | Planned repair |
| --- | --- | --- | --- |
| QROW input scaling through `VX_fp16_mul.sv` | The selected Xilinx FP16 multiplier flushes subnormal products to zero. | Normal inputs `P=2^-9`, `scale=2^-6` produce zero instead of `2^-15`; summing 16 products weighted by 2 should produce the normal result `2^-10`. | Supply gradual underflow with round-to-nearest, ties-to-even (RNE), retaining the FP16 interface. |
| GEMM output conversion in `VX_f32_to_f16.sv` | The subnormal-output branch shifts the FP32 fraction without its implicit leading one. | An expected output `2^-15 + 2^-22` becomes `2^-22`. | Restore the leading one before shifting; verify guard, round, sticky, and rounding carry. |

The input-scaling defect is the main source of the observed 1.4–24.2% relative L2 errors. The output converter is a separate defect, isolated using cancellation with normal intermediate products.

References:

- [Diagnosis status](STATUS.yaml)
- [Detailed numerical report](../../third_party/tvm/docs/vortex_pv_numerics_debug.md)
- Hardware evidence: `/home/jaeyongjang/project.local/tvm/build/pv_debug_20261008/`

Primary validation configuration: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`, TH16/MXU16. The existing hardware alias is `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update`. Its name does not mean the floating-point multiplier is DSP-free: the configuration enables `FPU_DSP` and `VIVADO`.

No changes to GEMM layouts, DMA addresses, KV capacity semantics, submission ABI, or SIMT F2F are included. The new logic must derive lane counts from configuration; it must not impose a new 16/32-only restriction.

## 1. Repair the output converter first

File: `hw/rtl/core/gemm/VX_f32_to_f16.sv`.

1. Preserve the existing normal, overflow, NaN, signed-zero, and optional output-register paths.
2. In the branch that converts a normal FP32 value into a subnormal FP16 value, form a **35-bit** significand containing `{1'b1, fp32_mant, 11'b0}` before the right shift. The current 34-bit fraction-plus-padding value omits the leading one.
3. Apply the existing exponent-dependent right shift to that explicitly widened value, then feed the retained bits to the rounding helper. Ensure SystemVerilog expression sizing cannot truncate the leading one before the shift.
4. Audit the guard/round/sticky bits across the reachable shift range. RNE must handle ties and carry from the largest subnormal into the smallest normal.
5. Preserve `OUT_REG=0/1` and valid timing exactly.

This converter is shared by the internal accumulator and LMEM accumulator paths. The numerical repair intentionally applies to both; normal-output regression checks must cover those callers.

Expected cost: a small combinational change, with no new RAM, DSP, or pipeline stage. Confirm this from elaboration and synthesis rather than treating it as a measured result.

## 2. Repair the QROW input multiplier

Files: `hw/rtl/core/gemm/VX_fp16_mul.sv`, its QROW instantiation in `VX_gemm_compute_core.sv`, and a small arithmetic leaf only if the existing helpers cannot express the operation cleanly.

### Implementation choice

IP capability check (2026-10-08): the repository creates Xilinx `floating_point` v7.1. The installed Vivado 2025.1 `floating_point_v7_1/component.xml` and GUI definitions expose no denormal/subnormal/flush-control parameter. AMD [PG060](https://docs.amd.com/v/u/en-US/pg060-floating-point), "Denormalized Numbers," specifies flushing denormal operands and results to signed zero for this operator. `C_Has_UNDERFLOW` only enables an exception indication in the result channel; it does not enable gradual underflow. Thus the present Half-to-Half multiplier cannot be repaired by toggling an IP option. Custom exponent widths are an IP-based alternative, but require format conversion and a rounding analysis, rather than an FP16 denormal-support switch.

Introduce a compile-time parameter, provisionally `GRADUAL_UNDERFLOW`, defaulting to zero. Enable it for the C4/improve QROW input-scaler instantiation. The selected implementation must support subnormal inputs and outputs. Other multiplier callers retain their existing implementation in this initial repair.

Use synthesizable integer significand arithmetic for the selected implementation, reusing existing handshake/buffering helpers. The implementation is selected at elaboration: do not retain the vendor multiplier alongside a second multiplier with a runtime result mux. Do not switch the entire FPU to FPNEW.

Arithmetic steps:

1. Decode sign, exponent, fraction, zero, infinity, and NaN.
2. Form 11-bit significands with leading one for normal inputs and leading zero for subnormal inputs. Use the proper effective exponent for subnormals.
3. Compute the exact 11-by-11-bit product into 22 bits, with signed exponent arithmetic.
4. Normalize and retain guard, round, and sticky information through any right shift.
5. Round **once** to FP16 using RNE. For subnormal outputs, round on the `2^-24` grid instead of flushing them.
6. Handle rounding into a normal number, overflow, signed zero, and exceptional operands. Preserve the wrapper's established NaN policy where specified; document that policy in the tests.

Do not implement this as an FP16 multiply followed by FP16 rescaling: an intermediate rounding can lose the information needed for correct final rounding. The diagnostic `P * 2` workaround is not the RTL solution.

### Pipeline and integration constraints

The active C4 QROW path selects the latency-one multiplier and uses a one-cycle scaler alignment. The target is the same effective one-cycle latency and one accepted operand pair per cycle, with the existing ready/valid behavior.

- Preserve independent A/B arrival handling, output backpressure, lane alignment, and metadata ownership.
- Reuse the wrapper's existing stream-join and elastic-buffer mechanisms where applicable.
- VCS must exercise the same new synthesizable arithmetic used in hardware. The current DPI conversion helpers are not a suitable independent IEEE oracle.
- Audit the existing prealigner's subnormal handling end to end. It already uses exponent one and a zero hidden bit for FP16 subnormal inputs, so widening the interface is not the initial approach.
- Inspect elaborated selection to ensure unrelated QCOL/TCU/naive multiplier instances remain unchanged.
- If one-cycle timing cannot be met, stop and report the measured critical path. A second pipeline stage requires a separate, explicit update of metadata/credit alignment and cycle measurements; do not silently add it.

Expected cost: 11-by-11-bit multiplication plus normalization, sticky-bit, rounding, and classification logic per active scaler lane. The existing vendor multiplier already consumes arithmetic resources, so net DSP/LUT/FF changes must be measured. No additional BRAM or operand queue depth is planned.

## 3. Verification sequence

Keep the two repairs as separately reviewable changes. Validate the converter before integrating the multiplier, then validate their combination.

| Step | Checks | Completion criterion |
| --- | --- | --- |
| Baseline | Record source/config identity, selected RTL, existing failures, and representative GEMM cycles. | Reproducible baseline with the exact configuration and inputs. |
| Converter unit tests | Signed values around zero, `2^-25` tie, minimum subnormal, maximum subnormal, minimum normal, normal rounding, overflow, infinity, NaN; `OUT_REG=0/1`. | Bit-exact finite outputs against an independent RNE reference; documented exceptional-value policy and unchanged valid timing. |
| Multiplier unit tests | Directed normal/subnormal operands, underflow boundary, tie-to-even, rounding carry, signs, overflow and exceptional operands. Seeded random pairs and all 65,536 half encodings against a small boundary-operand set. | Exact arithmetic reference agreement and no lost/duplicated/reordered transactions. |
| Multiplier flow tests | Independent A/B arrivals, bubbles, sustained traffic, and randomized output backpressure using the actual latency-one mode. | Correct operand pairing; preserved latency contract and II=1 under continuous ready. |
| Scaler-to-accumulator integration | Feed retained subnormal products through the existing prealigner, MXU, accumulator, and corrected output converter. | Small products survive and contribute to the expected sum. |
| VCS blackbox | Directed PV cases below plus ordinary QROW/QCOL GEMM. | No numerical or protocol regressions; report before/after cycles. |
| Resource/timing comparison | Compare the same configuration, tool settings, and constraints before/after. | Report LUT, FF, DSP, BRAM, and timing changes; no unexpected buffering or duplicate multipliers. |
| Updated FPGA image | Replay the 120 isolated patterns, the four original failures, and dynamic/static KV tests. | Correct-reference checks pass; matching the old defect model is not a pass criterion. |
| TVM integration | Run the established random-weight Llama checks and representative long-context PV/attention cases. | Original PV failures resolved without regression in dynamic-length equivalence or graph execution. |

Use an independent software arithmetic reference or independently generated vectors; first verify its subnormal and RNE behavior. Do not derive expected outputs from the RTL under test or the diagnostic defect model. For NaNs, compare the defined classification/payload policy rather than assuming an arbitrary external payload convention.

Use the existing `hw/unittest/fp16_mul` harness where possible, extending it for the new selected path and latency-one flow. Add a focused converter harness because it needs independent coverage. Run from configured build directories with the repository's prescribed host compilers and VCS flow.

### Small VCS cases

Use `ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw` from a configured build directory after sourcing the C4 configuration. Include `--perf 3` for cycle comparisons. Keep simulator cases small; replay the larger sweep on FPGA after producing the corrected bitstream.

Reuse the existing host vector-generation, packing, reference, and launch flow in `tests/regression/fpint_gemm_ffn_hw/main.cpp`. Add only a narrow directed-input option or fixture loader if required, before existing packing. Check the host FP16 helper against the independent oracle before relying on it.

Required patterns:

- Uniform normal versus subnormal `P * scale`, with a normal final output, to isolate input underflow.
- Cancellation with all nonzero products normal and a subnormal final output, to isolate output conversion.
- Positive and negative rounding boundaries, including promotion from subnormal to normal.
- One-hot positions on both sides of microtile and 128-element DMA-tile boundaries, plus tagged per-tile scales.
- At least one K greater than 256 and non-full final tile, using existing legal dimension/alignment rules and capacity/target-size helpers.
- A small ordinary QROW and QCOL GEMM, plus a shared-converter caller smoke test.

Capture performance on ordinary `M=1,4`, `K=N=256` first. A longer `M=256` baseline may be reused only when source/config/tool identity is established; otherwise report it as pending or run it after correctness is settled. Do not let a large VCS performance sweep delay isolation of arithmetic failures.

## 4. FPGA and TVM acceptance

The current xclbin contains the defects. A new synthesis/PnR image is required to validate the repaired RTL on FPGA. Use a new output postfix and alias, preserving the old image and recording the new source/config hashes and manifest. Do not relabel an old bitstream as fixed.

Replay artifacts using `tvm/apps/vortex_llama3/debug_pv_numerics.py` and the existing original-case fixtures. Extend result reporting to distinguish correct arithmetic from reproduction of the old model.

For the four previously failing TVM cases, apply the established CPU-reference gates: relative L2 at most 1%, violation fraction at most 2%, and cosine similarity at least 0.999, using the existing elementwise tolerance definition. Also check fixed-capacity and active-length paths against each other. Do not waive the observed large errors as harmless FP16 noise.

Run the established full random-weight Llama3-8B smoke workload, and separately include long active lengths such as 320 and 512: a short decode-only smoke test does not cover this failure regime. Hardware execution must use the isolated real-XRT runtime, not the shared runtime that is currently configured for VCS.

## 5. Precision boundary and follow-up decision

Gradual underflow restores correct FP16 multiplication, but FP16 still has finite precision and a minimum positive subnormal of `2^-24`. It cannot preserve arbitrarily small products. Ordinary per-product rounding also remains; exact agreement with an FP32 dequantization-and-matmul reference is not promised.

Evaluate realistic longer-length distributions, including 1024 and 2048, using inexpensive numerical experiments before launching long hardware tests. If correctly rounded FP16 scaling still fails the required accuracy gates, report that separately from the two diagnosed defects. A wider-exponent internal scaler/prealigner interface would then need its own design and cost review. Do not silently expand this repair into a full FP32 datapath redesign.

Deliverables: the two localized RTL repairs and integration selection, independent unit tests, focused blackbox fixtures, before/after numerical and cycle tables, measured resource/timing deltas, and a final FPGA/TVM validation report. The present task produces this plan only.
