# Matched historical simulation smoke baseline

Observed 2026-09-08 22:31 KST. Both modes use the same archived non-RAM DUT,
archived headers, repo DP/SP RAM exceptions, guarded vendor IP configuration,
kernel program and host application. Neither stage contains diagnostic observers.
Original Makefiles and `ci/run_black.sh` are unchanged.

The baseline is the current backend with `U55C_PERFORMANCE_PROFILE` unset:
legacy paired-PC abstraction and legacy DRAM timing (1 GHz). This is not a
checkout of the old backend implementation. The document mode uses the frozen
documentation profile with 900 MHz DRAM timing and bandwidth/latency parameters.
Both have kernel100/AXI450 MHz. The DRAM difference is intentional model scope,
not an attempt to compare differently clocked kernels.

| Case (M=N=16, QBLK32) | Legacy baseline cycles, twice | Document cycles, twice | Document minus baseline |
| --- | --- | --- | --- |
| K=16 | 6782, 6782 | 7344, 7344 | +562 cycles |
| K=64 | 6857, 6857 | 7419, 7419 | +562 cycles |

All eight runs pass output verification and terminate normally without fatal
assertions. These small cases do not establish sustained memory bandwidth or
which model is closer to U55C. Hardware errors remain **unmeasured**, not zero.

Baseline instructions are 6247/6253 (K16/K64); document instructions are
6253/6259. The device program hashes match and baseline hashes are verified
before/after its four launches. The program has a data-dependent MMIO polling
loop in `tests/regression/fpint_gemm_ffn_hw/kernel.cpp:226`; instruction counts
need not match across timing models. The exact six-instruction difference has
not been independently attributed by an instruction trace.

Stages are `build_hbm_reference/sim/xrtsim_vcs/archived-{baseline,document}-guarded-mul`.
Baseline compilation audit records 217 archive, two approved repo RAM, nine
harness and zero unexpected inputs; report is `baseline_guarded_mul_compile_audit.json`
in the stages' parent directory. Original raw logs and before/after hash list
are in `build_hbm_reference_document/baseline_guarded_*`.

`reference-smoke-results.json` records eight results with per-log hashes, exact
arguments, executable/program/manifest/temporary-Makefile hashes, full model
manifests and modeled device time. Regenerate with `collect_reference_smoke.py`.
The collector rejects missing PASS markers, ambiguous counters, fatal errors
and absent simulator completion. It does not establish provenance by itself.

Launch symlinks were restored to the document stage after baseline runs;
document K64 was then repeated successfully. Hardware runtime clocks, UUID,
repeatability, matched ABI/IP provenance and held-out validation remain open.
