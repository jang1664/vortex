# TMEM LDMA Queue Depth Sweep Specification

## Status

Confirmed by the user on 2026-09-01.

## Goal

Measure the functional and performance impact of reducing the common TMEM
load-DMA stream queues for the current IMPROVE TH16 FPGA configuration.

## Scope

- Preserve the current default RTL configuration.
- Add a compile-time override for the command FIFO depth used by the TMEM
  input, weight, scale, and zero-point load-DMA stream queues.
- Permit command FIFO depth 2 in the common stream queue.
- Permit the weight response-slot count to be selected independently of the
  number of beats in one weight command, while retaining structural safety
  checks for supported positive power-of-two counts.
- Do not change the output-DMA queue or unrelated GEMM datapaths.

## Experiment Matrix

Use the current `GEMM_IMPROVE`, TH16, 32-column tile, big-memory configuration
with `MXU_WLOAD_NUM=4` and performance class 3.

| Case | Command FIFO depth | Input slots | Weight slots | Scale slots | Zero-point slots |
|---|---:|---:|---:|---:|---:|
| Baseline | 4 | 8 | 16 | 8 | 8 |
| Depth2 / slots4 | 2 | 4 | 4 | 4 | 4 |
| Depth2 / slots8 | 2 | 8 | 8 | 8 | 8 |

For each case, run `xrt-vcs-sim` with `fpint_gemm_ffn_hw` and:

- `M=4, N=256, K=256, QBLK=32, WTRANS=0`
- QCOL (`QDIR=0`) and QROW (`QDIR=1`)
- numerical correctness enabled

## Acceptance Criteria

- Focused RTL verification passes for both candidate parameter sets.
- All six blackbox runs pass numerical checking and terminate normally.
- Report total GEMM cycles and available DMA/overlap counters for every run.
- Compare each candidate against the freshly measured baseline, separately for
  QCOL and QROW.

## Constraints

- Use a configured build directory and `ci/run_black.sh` through the existing
  target GEMM runner.
- Source the selected configuration before simulation.
- Preserve unrelated worktree changes.
- Record exact compile defines and logs so each result is reproducible.
