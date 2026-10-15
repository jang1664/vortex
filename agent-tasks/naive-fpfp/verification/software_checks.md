# Naive FPFP software checks

Date: 2026-10-14. All checks used the isolated configured directory
`build_fpfp_software`. No FPGA device access or RTL simulation was performed.

## Build and capability checks

Base configuration:
`configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh`.
For each single-format build, the exact legacy `-DGEMM_NAIVE` token was removed
from the sourced `CONFIGS`, then only the indicated capability was added.
`make -C hw config` regenerated the C header, the kernel library was rebuilt,
and the regression host plus `kernel.vxbin` were compiled. The generated header
was also preprocessed with the exact build flags using `g++ -E -dM`.

| Configuration | Generated capability macros | Host + kernel | CLI rejection before device open | Supported-format CLI check |
|---|---|---|---|---|
| FPFP-only: `GEMM_NAIVE_FP16_ENABLE` | FP16 present; FPINT absent; shared `GEMM_NAIVE` derived | PASS | Default INT4 and alternating-format requests rejected | `--fp16-weights -m 0` passed capability validation and reached the expected shape rejection |
| FPINT-only: `GEMM_NAIVE_ENABLE` | FPINT present; FP16 absent; shared `GEMM_NAIVE` derived | PASS | `--fp16-weights` and alternating-format requests rejected | `-m 0` passed capability validation and reached the expected shape rejection |
| Dual: legacy `GEMM_NAIVE` plus `GEMM_NAIVE_FP16_ENABLE` | Both capabilities present | PASS | Not applicable to either supported format | Numerical hardware verification delegated to the RTL verification task |

The deliberate `-m 0` check confirms the requested format passes the capability
gate while keeping execution before `vx_dev_open`. It is not an end-to-end
hardware functionality result. All six single-format CLI probes returned the
expected diagnostic and exit status 255. In particular, FPFP-only header
processing does **not** accidentally enable `GEMM_NAIVE_ENABLE` after deriving
the shared `GEMM_NAIVE` presence macro.

Evidence under `build_fpfp_software/`:

- `software_fp16_only_flags.txt`, `software_fp16_only_macros.txt`,
  `software_fp16_only_build.log`, `software_fp16_only_cli.json`.
- `software_int4_only_flags.txt`, `software_int4_only_macros.txt`,
  `software_int4_only_build.log`, `software_int4_only_cli.json`.
- `software_build.log`: dual-format host/kernel build.
- Saved single-format host executables `fpint_gemm_ffn_hw_naive.fp16_only` and
  `.int4_only`, and corresponding `kernel.fp16_only.vxbin` /
  `kernel.int4_only.vxbin`.

The existing unused `pack_int4_pair` warning remains; no unrelated cleanup was
performed. The build directory's current default executable is FPINT-only.

## CPU reference and allocation checks

`software_reference_check.cpp` and `software_reference_check.log` in the same
build directory record PASS for:

- All 63,488 finite half bit patterns: decoding and exact round trip compared
  with the host compiler's `_Float16` conversion.
- Directed subnormal A, subnormal B, signed/cancelling terms, and subnormal
  final outputs against explicit expected half values.
- FPFP with QBLK=0 and QDIR=57005: no qparam vectors or scratch allocations.
- Exact scratch requirement 229,376 bytes (224 KiB): fits 1,310,720-byte LMEM;
  an allocation smaller than the requirement is rejected.
- Seed reproducibility, changed-seed input variation, and finite reference
  outputs for M=4, K=384, N=32.
- Rejection of poisoned NaN output and a one-bit nonzero FP16 mismatch.

FPFP numerical checks are bit exact except signed zero; raw bit mismatches are
reported separately. The mathematical FP64 diagnostic does not relax the
pass/fail rule. The existing FPINT tolerance remains unchanged.

## Software files changed

Under `tests/regression/fpint_gemm_ffn_hw_naive/`:

- `common.h`: appended format/poll-only arguments and format/status constants.
- `kernel.cpp`: CONTROL[23] format submission, capability validation, and an
  explicit poll-only argument independent of QDIR.
- `main.cpp`: FPFP/alternating-format CLI, format-aware allocations, capability
  checks, and numerical diagnostics.
- `fpfp_test_vectors.h`: row-major FP16 vectors and FP32 tree/ACC reference.
- `bench_main.cpp`: explicit rejection when the INT4 benchmark capability is
  absent.
- `Makefile`: shared ABI/header dependencies.
- `README.md`: usage, arithmetic contract, ABI and memory layout.

Existing field offsets are preserved by appending the new arguments. Rebuild
both host and kernel together after the ABI update. Compile-time capability
checks do not identify a mismatched FPGA image; the current runtime exposes no
GEMM-format capability query.
