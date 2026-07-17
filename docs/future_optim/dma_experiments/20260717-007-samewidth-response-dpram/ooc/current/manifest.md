# DMA OOC Experiment Manifest

| Field | Value |
| --- | --- |
| Experiment ID | `current` |
| Purpose | Produce the Phase 1 C4 improve DMA OOC synthesis result |
| Comparison rule | Compare with `20260717-006-c4-aligned-baseline` |
| Changed production RTL | Same-width response storage uses `VX_dp_ram` |
| Config | `/home/jaeyongjang/project.local/vortex_fpint/configs/improve_th16_tcol32_hwexp_dcache.sh` |
| Git commit | `502a49dbb52cb78858d481c8cde29728045551b2` |
| Git state | `git_status.txt` |
| Vivado | `v2025.1 (64-bit)` |
| Device | `xcu55c-fsvh2892-2L-e` |
| OOC top | `VX_dma_engine_ooc` |
| Constraint | `hw/syn/xilinx/dut/project.xdc` |
| Unittest | PASS before OOC invocation; see parent experiment |
| xrt-vcs-sim | PASS before OOC invocation; see parent experiment |
| OOC synthesis | PASS; see `post_synth_util.rpt` and `post_synth_timing_summary.rpt` |
| Checkpoint | `not-retained` |
| Conclusion | Keep as the Phase 1 candidate; see parent experiment comparison |

This script performs only the OOC stage. Structural DMA variants must pass the
unittest and xrt-vcs-sim gates required by
`docs/future_optim/dma_optimization_experiment_rules.md` before invoking it.
