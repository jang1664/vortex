# Existing-U55C smoke comparison (2026-09-08 22:36 KST)

## Execution and identity

Configured separate `build_hbm_hardware_reference` with the candidate config,
XLEN64 and normal configure prerequisites. No RTL, IP, synthesis or new xclbin
was generated. Original `ci/run_black.sh hw --fpga-bin temp` ran under
single-task Slurm FPGA GRES allocations using the task's smoke/repeat scripts.
The wrapper recognized the enclosing allocation and did not launch nested jobs.

Job 4906 loaded the existing candidate xclbin and passed GEMM16 correctness
(8996 cycles). Job 4907 ran two preselected shapes, one excluded warm-up and
five measured fresh-process launches per shape. Each launch uses fresh BOs
and normal runtime reset; this is board warm-up, not a warm-cache benchmark.
All 12 repeat-job launches passed. Both jobs terminated and released allocation.
The board image was changed to the candidate by the normal runtime load; it
was not restored to the prior unrelated image. No firmware/reset utility used.

Hardware host application and `kernel.vxbin` hashes exactly match VCS:

- host: `8f98e5af6f3680af703f2452847beaac7444341947020f27929aa26938273368`
- device: `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`

Before/after hashes also pass for the repeated hardware run. Every post-run
board report has candidate UUID `04277889-d0a3-bd1d-c32e-72ef96e153c3`,
HEALTHY status, DATA_CLK100 and hbm_aclk450 MHz. Memory temperatures are retained
per sample in `hardware-smoke-results.json`; initial smoke reported 47 C.
These are post-run snapshots, not continuous telemetry or proof of no transient
throttling. Board state after releasing the allocation is not guaranteed.

## Exploratory results, not acceptance

| Case, M=N=16/QBLK32 | HW median [min,max] cycles | Baseline cycles/error | Document cycles/error |
| --- | --- | --- | --- |
| K=16 | 9094 [8998,9110] | 6782 / -25.42% | 7344 / -19.24% |
| K=64 | 9190 [9107,9223] | 6857 / -25.39% | 7419 / -19.27% |

Each hardware median uses five samples after its excluded warm-up; each model
uses two deterministic repeats. Error is `(model - HW median) / HW median`.
Hardware full range/median is 1.23% and 1.26%, respectively. The cycle differences
are substantially larger than this observed repeatability, but their cause is
not established. The document model is closer on these two cases and remains
too optimistic; this does not demonstrate general fidelity or justify fitting
HBM residual latency to whole-program overhead.

Whole-program counters include setup and data-dependent MMIO polling. No
isolated HBM latency or bandwidth was measured. No acceptance tolerance has
been chosen; no held-out evaluation has occurred and no parameters were tuned
to these samples. Continue with memory-sensitive/compute-heavy exploratory
cases and setup/ABI/IP/clock checks before interpreting the gap as HBM contention.

## Clock metadata caveat

Archived `ulp.hwh` at line 15616 connects `vortex_afu_1.ap_clk` to
`ulp_ucs.aclk_kernel_00` on `ulp_ucs_aclk_kernel_00`. Its port `CLKFREQUENCY`
attribute still says 300 MHz, unlike linked xclbin achieved/requested metadata
100 MHz and runtime DATA_CLK100. Treat that HWH attribute as non-authoritative
for operating frequency; record it rather than silently ignoring the discrepancy.
The runtime report's separate KERNEL_CLK500 is not the named Vortex clock net.
Finish explicit runtime clock-index-to-net mapping before closing the clock gate.

Raw reports: `build_hbm_hardware_reference/hardware-smoke-4906/` and
`build_hbm_hardware_reference/hardware-repeats-4907/`.
`collect_hardware_smoke.py` validates PASS/counters/UUID/clocks/program hashes
and records per-log hashes, statistics and signed/absolute errors in
`hardware-smoke-results.json`. The collector is not a complete provenance audit.
