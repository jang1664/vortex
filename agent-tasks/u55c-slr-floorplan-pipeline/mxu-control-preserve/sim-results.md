# MXU local/TX FF preservation simulation results

**14/14 xrt-vcs-sim GEMM cases and 4/4 directed VCS tests PASS.**

## Source and setup

- Completed: 2026-09-07T10:51:47 KST.
- Exact production TH32/t4 and TH32/t8 configs; MXU32x32, W4, RAM8, SLR enabled.
- Two fresh isolated builds: `build/experiment-archive/build_mxu_preserve_th32_t4` and `build/experiment-archive/build_mxu_preserve_th32_t8`.
  Each was configured after sourcing its exact config, using XLEN64 and `/opt/vortex`.
- VCS W-2024.09-SP1, `/usr/bin/gcc`, `/usr/bin/g++`, shared `build/vcs_simlib`.
- Every run uses the configure-generated `ci/run_black.sh xrt-vcs-sim` wrapper from its build.
  Debug traces are enabled; FSDB is disabled. Initial 300s timeout sufficed.
- Frozen RTL: 330 files; SHA-256 manifest `4ca083ff5d66a76e1ca1bc09c84a7db299f8095cfd88262c9b834f97482911a0`.
  Source hashes were captured before compilation and verified unchanged after all full-system runs.
- [simulation-manifest.json](simulation-manifest.json) includes exact RTL/config hashes, simulator
  and application hashes, per-run numerical/trace/slot evidence, and baseline comparisons.

## Full-system checks and cycle comparison

Numerical output PASS, zero strict trace/assertion failures, and nonempty, complete
response-slot allocation/response/release evidence were required for every case.
Baseline is the recorded pre-change four-config-pnr evidence, not a reused simulator.

| Profile | Case | Before | After | Delta | Change |
|---|---|---:|---:|---:|---:|
| th32_t4 | smoke_qcol | 6502 | 6502 | +0 | +0.000% |
| th32_t4 | overlap_qcol | 7254 | 7254 | +0 | +0.000% |
| th32_t4 | qrow | 6878 | 6877 | -1 | -0.015% |
| th32_t4 | odd_tail_qcol | 6500 | 6501 | +1 | +0.015% |
| th32_t4 | overlap_d0_t1 | 7253 | 7252 | -1 | -0.014% |
| th32_t4 | overlap_d1_t0 | 7253 | 7253 | +0 | +0.000% |
| th32_t4 | overlap_d1_t1 | 7253 | 7253 | +0 | +0.000% |
| th32_t8 | smoke_qcol | 6427 | 6503 | +76 | +1.183% |
| th32_t8 | overlap_qcol | 7251 | 7254 | +3 | +0.041% |
| th32_t8 | qrow | 6803 | 6803 | +0 | +0.000% |
| th32_t8 | odd_tail_qcol | 6500 | 6499 | -1 | -0.015% |
| th32_t8 | overlap_d0_t1 | 7254 | 7253 | -1 | -0.014% |
| th32_t8 | overlap_d1_t0 | 7253 | 7252 | -1 | -0.014% |
| th32_t8 | overlap_d1_t1 | 7252 | 7252 | +0 | +0.000% |

Maximum absolute host-cycle change: **1.183%** (one sample per case).
Host/device completion polling can shift this counter; these single samples are
not a statistically isolated performance measurement.

Nonzero internal event-span deltas (remaining intervals match):
- `th32_t4/overlap_qcol` `dma_accept_span_cycles`: -1.0 cycles.
- `th32_t4/overlap_qcol` `dma_complete_span_cycles`: -1.0 cycles.
- `th32_t4/overlap_qcol` `dma_total_span_cycles`: -1.0 cycles.
- `th32_t4/overlap_d1_t1` `input_accept_span_cycles`: +1.0 cycles.
- `th32_t4/overlap_d1_t1` `compute_fire_span_cycles`: +1.0 cycles.
- `th32_t4/overlap_d1_t1` `dma_accept_span_cycles`: +1.0 cycles.
- `th32_t4/overlap_d1_t1` `dma_complete_span_cycles`: +1.0 cycles.
- `th32_t4/overlap_d1_t1` `dma_total_span_cycles`: +1.0 cycles.
- `th32_t8/smoke_qcol` `dma_accept_span_cycles`: +4.0 cycles.
- `th32_t8/smoke_qcol` `dma_complete_span_cycles`: +3.0 cycles.
- `th32_t8/smoke_qcol` `dma_total_span_cycles`: +4.0 cycles.
- `th32_t8/overlap_qcol` `input_accept_span_cycles`: +8.0 cycles.
- `th32_t8/overlap_qcol` `compute_fire_span_cycles`: +8.0 cycles.
- `th32_t8/overlap_qcol` `dma_accept_span_cycles`: +9.0 cycles.
- `th32_t8/overlap_qcol` `dma_complete_span_cycles`: +9.0 cycles.
- `th32_t8/overlap_qcol` `dma_total_span_cycles`: +9.0 cycles.
- `th32_t8/qrow` `dma_accept_span_cycles`: +1.0 cycles.
- `th32_t8/qrow` `dma_complete_span_cycles`: +1.0 cycles.
- `th32_t8/qrow` `dma_total_span_cycles`: +1.0 cycles.
- `th32_t8/odd_tail_qcol` `dma_accept_span_cycles`: -5.0 cycles.
- `th32_t8/odd_tail_qcol` `dma_complete_span_cycles`: -4.0 cycles.
- `th32_t8/odd_tail_qcol` `dma_total_span_cycles`: -5.0 cycles.
- `th32_t8/overlap_d0_t1` `input_accept_span_cycles`: -2.0 cycles.
- `th32_t8/overlap_d0_t1` `compute_fire_span_cycles`: -2.0 cycles.
- `th32_t8/overlap_d0_t1` `dma_accept_span_cycles`: -2.0 cycles.
- `th32_t8/overlap_d0_t1` `dma_complete_span_cycles`: -2.0 cycles.
- `th32_t8/overlap_d0_t1` `dma_total_span_cycles`: -2.0 cycles.
- `th32_t8/overlap_d1_t0` `input_accept_span_cycles`: -2.0 cycles.
- `th32_t8/overlap_d1_t0` `compute_fire_span_cycles`: -2.0 cycles.
- `th32_t8/overlap_d1_t0` `dma_accept_span_cycles`: +2.0 cycles.
- `th32_t8/overlap_d1_t0` `dma_complete_span_cycles`: +1.0 cycles.
- `th32_t8/overlap_d1_t0` `dma_total_span_cycles`: +2.0 cycles.
- `th32_t8/overlap_d1_t1` `dma_accept_span_cycles`: +9.0 cycles.
- `th32_t8/overlap_d1_t1` `dma_complete_span_cycles`: +7.0 cycles.
- `th32_t8/overlap_d1_t1` `dma_total_span_cycles`: +9.0 cycles.

## Directed source-block timing checks

The test does not hand-copy the DUT behavior. `extract_registers.py` takes exact
uniquely anchored slices of the changed production core: the complete local
SLR/non-SLR conditional block, actual transport typedefs, and actual TX/RX blocks.
Only the standalone port/declaration wrapper is test-specific. Source and generated
block hashes are retained. The complete core is independently exercised above.

Each test checks 260 cycles, including 111 changing-data invalid cycles and eight
reset samples with both fire states. The local output matches the actual existing
`VX_pipe_buffer(DEPTH=1)` library implementation bit/cycle exactly, including data
sampling during invalid/reset cycles and valid reset. In SLR mode, TX captures at
one edge and RX at the next; block index, data, weight select and reset-valid timing
are all checked. TH32/t4 and TH32/t8 SLR and non-SLR variants all pass.

Run through `tools/verify_rtl.py unittest --sim vcs --timeout 300` in configured
build test directories. Logs and source-block metadata are linked by the manifest.

## Limits

No functional failures occurred. The verification agent's referenced legacy
`testbench.md`, `run-test` and `add-test-case` instruction files are absent; current
project-context/run-bb-common procedures and the deterministic verifier were used.
Simulation proves cycle/function preservation, not physical FF separation or
Laguna placement. Those require the separately requested fresh synthesis/PnR and
strict hook checks. This verification workflow runs no OOC, synthesis or PnR.
