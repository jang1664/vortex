# Expanded exploratory GEMM (2026-09-08 22:42 KST)

These are exploratory cases, not a held-out acceptance set. No model parameter
changed. All use the same previously hashed host/kernel binary and QBLK32,
one kernel launch per process, default QDIR0 and deterministic input generation.

| M x N x K | HW median [min,max], five samples | Baseline, two runs | Document, two runs | Document signed error |
| --- | --- | --- | --- | --- |
| 16 x 16 x 256 | 9434 [9423,9530] | 7082,7082 | 7569,7569 | -19.77% |
| 64 x 64 x 64 | 10810 [10803,10843] | 8433,8433 | 8919,8919 | -17.49% |

Both model modes and every hardware launch pass output checks. Hardware job
4908 uses one excluded warm-up plus five samples per shape in one allocated
FPGA job; all post-run board reports match candidate UUID, DATA100/HBMAXI450
and HEALTHY status. The job terminated and released its allocation.
Baseline/document VCS hashes and program hashes pass before/after checks;
the temporary launch links are restored to document mode.

The absolute document shortfall is 1865 and 1891 cycles, versus 1750 and 1771
for the earlier two small shapes. This suggests investigating a substantial
startup/control contribution; it does not prove one fixed offset or identify
HBM latency as the cause. Do not fit a global latency constant to these total
kernel-cycle gaps. Existing `fpint_gemm_ffn_hw --pol N` runs a fixed-count MMIO
poll loop without submitting GEMM and can isolate part of this question with
the same binary. That mode deliberately skips output verification, so any
future results must be labeled control-path diagnostics, not GEMM correctness.

Evidence:

- `reference-explore-results.json`: eight model runs, source/config/program
  hashes, exact arguments, counters and raw log hashes.
- `hardware-explore-results.json`: warm-ups and ten measured hardware samples,
  board snapshots, statistics and signed/absolute model errors.
- `build_hbm_hardware_reference/hardware-repeats-4908/`: raw hardware artifacts.
- `build_hbm_reference_document/explore_{baseline,document}_gemm*`: raw VCS logs.
- `reference-clock-evidence.md`: direct xclbin section extraction reconciles
  platform300 default with linked100 and observed runtime100 MHz.

Unfinished: control/setup diagnosis, explicit IP provenance audit, independent
DMA/long-stream workload coverage, tolerance selection before held-out cases,
held-out comparison and final regressions/acceptance audit. These four GEMM
shapes do not measure isolated HBM-port bandwidth or zero-load latency.
