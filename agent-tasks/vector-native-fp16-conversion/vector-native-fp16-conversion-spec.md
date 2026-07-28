# Native FP16 Conversion Helpers

## Goal

Use hardware Zfh conversion instructions for vector-kernel FP16 input/output
conversion while preserving FP32 arithmetic. Keep the existing software
conversion implementation as a fallback for builds without Zfh.

## Scope

- `tests/regression/vector_common/fp16.h`
- Representative regression-kernel build and functional checks
- C4 hardware latency measurements for a small set of vector kernels

Quantization and dequantization arithmetic are outside this change; they
already have separate native-FP16 work.

## Design decisions

- Keep the public `fp16_to_float(fp16_t)` and `float_to_fp16(float)` APIs.
- Under a compiler Zfh feature guard, reinterpret the storage bits as
  `_Float16` and use C++ casts so LLVM emits `fcvt.s.h` and `fcvt.h.s`.
- Retain the current bit-manipulation implementation unchanged as fallback.
- Allow tests to force the software fallback with
  `VX_FP16_FORCE_SOFTWARE_CONVERSION` for same-xclbin A/B measurements.
- Preserve all vector-kernel arithmetic in `float`/FP32.
- Confirm the generated kernel disassembly contains native conversion
  instructions before relying on latency results.

## Constraints and assumptions

- The Zfh hardware/software profile uses `rv64imaf_zfh` and an LP64F ABI.
- Existing user changes elsewhere in the dirty worktree must be preserved.
- C4 measurements must use the C4 FPGA binary/configuration that supports Zfh.

## Final agreed spec

Confirmed by the user's explicit request on 2026-07-28.
