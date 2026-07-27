# Vortex Scalar Zfh FPU_DSP/Vivado Support Specification

Status: confirmed

## Goal

Enable scalar RISC-V Zfh execution through the Xilinx `FPU_DSP` backend for
RV64 Vortex using:

```text
-march=rv64imaf_zfh -mabi=lp64f
CONFIGS += -DEXT_D_DISABLE -DEXT_ZFH_ENABLE -DFPU_DSP -DVIVADO
```

The implementation must preserve the existing FP32 DSP behavior while keeping
double precision disabled.

## Scope

### RTL

- Preserve and transport `fmt`, `src_fmt`, subtraction, and integer-width
  information into `VX_fpu_dsp` instead of using the legacy overloaded format.
- Implement FP16 arithmetic, fused arithmetic, divide, square root, comparison,
  classify, sign injection, min/max, move, FP16/FP32 conversion, and supported
  FP16/integer conversions in the DSP backend.
- Apply RISC-V NaN-boxing rules to FP16 operands and results.
- Keep FP16/FP32 variable-latency responses correctly tagged and arbitrated.
- Permit Zfh with `FPU_DSP` only when `VIVADO` supplies the required Xilinx IP;
  retain the existing `FPU_FPNEW` path.

### Xilinx IP integration

- Add the scalar half-precision FMA, divide, square-root, and H/S conversion IP
  configurations required by the DSP implementation.
- Update VCS wrapper compilation, standalone synthesis, XRT packaging, and any
  other manually maintained XCI lists.
- Keep IP generation safe for first and incremental invocations.

### Configuration and regression

- Add a reusable `EXT_D_DISABLE + EXT_ZFH_ENABLE + FPU_DSP + VIVADO` config.
- Reuse and extend `tests/regression/fp16_zfh` to cover the DSP path, including
  arithmetic, conversions, comparisons, negative values, zero, and rounding.
- Preserve the existing FPNEW Zfh regression and legacy FP32 DSP behavior.

## Design Decisions

- Internal DSP operand/result containers remain 32 bits. FP16 values use the
  low 16 bits and are NaN-boxed as `0xffffhhhh` at architectural boundaries.
- New scalar FP16 IP names are distinct from GEMM-oriented `xil_f16add` and
  `xil_f16mul` instances.
- Format-specific pipelines retain independent valid/latency tracking. Vivado
  2025.1 supports FP16 FMA latency 4, FP16 divide/sqrt up to latency 15, H-to-S
  conversion up to latency 2, and S-to-H conversion up to latency 3; the
  existing FP32 divide/sqrt latency is not reduced solely to align responses.
- Generic non-Vivado `FPU_DSP` and `FPU_DPI` Zfh configurations remain rejected.

## Constraints

- Existing unrelated worktree changes must be preserved.
- Generated/configured build-tree copies must be refreshed through `configure`.
- RTL blackbox testing uses `xrt-vcs-sim` through `ci/run_black.sh` from a
  configured build directory.
- Files created by the task are written in English.

## Completion Criteria

- The DSP/Vivado Zfh configuration elaborates and compiles with generated IP.
- `fp16_zfh` passes under `xrt-vcs-sim` with the DSP/Vivado configuration.
- The same regression still passes through FPNEW.
- A representative legacy FP32 DSP regression passes.
- IP generation succeeds on a fresh output and an incremental second run.
- Synthesis/package scripts reference every newly required XCI.
