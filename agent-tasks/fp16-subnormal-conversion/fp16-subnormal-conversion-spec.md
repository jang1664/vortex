# Scalar FP16 subnormal conversion

Status: confirmed by the user's request to correctly handle subnormal conversion after the softmax failure was reproduced.

## Goal

Preserve representable subnormal values in the DSP/Vivado scalar FP32-to-FP16 and FP16-to-FP32 conversions. The existing softmax regression loses four nonzero FP16 probabilities because the Xilinx float-to-float IP flushes them to zero.

## Scope and design

- Change `hw/rtl/fpu/VX_fpu_f2f.sv` and add focused conversion verification.
- Keep the normal/special-value IP path, module interfaces, serializer, PE count, ready/valid behavior, and existing conversion latencies.
- Add a latency-aligned RTL correction for finite FP32 magnitudes below the FP16 minimum normal value and nonzero FP16 subnormal inputs.
- Preserve signed zero and NaN boxing. Handle all five legal RISC-V rounding modes in the corrected narrowing path; dynamic rounding is resolved upstream.
- Set NX when rounding discards nonzero bits and UF for inexact results tiny after rounding. Exact subnormal conversion has neither flag.
- Do not change IP generation, kernel conversion policies, GEMM implementations, or FP16 arithmetic operators. Existing normal-path rounding/flag limitations remain outside this correction.

## Verification

- VCS tests against an independent SoftFloat reference: all half subnormals in both signs, FP32 boundary/tie/tiny/random inputs, all legal rounding modes, flags, NaN boxing, serialization, tags, lane masks, bubbles, and output backpressure.
- Run tests only from the separately configured repository-root build directory with the C4 config sourced.
- Repeat the original softmax `xrt-vcs-sim` with scale 1 and 3 using the original hardware conversion kernel. Scale 3 previously failed with three reported mismatches and four actual flushed outputs.
- No synthesis or FPGA binary regeneration in this task.
