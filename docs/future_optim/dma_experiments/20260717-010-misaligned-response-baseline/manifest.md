# DMA OOC Experiment Manifest

| Field | Value |
| --- | --- |
| Experiment ID | `20260717-010-misaligned-response-baseline` |
| Purpose | Produce a reproducible C4 improve DMA OOC synthesis result |
| Comparison rule | Compare only with an OOC run using identical synthesis inputs |
| Changed production RTL | See `git_status.txt` and the parent experiment manifest |
| Config | `/home/jaeyongjang/project.local/vortex_fpint/configs/improve_th16_tcol32_hwexp_dcache.sh` |
| Git commit | `9960894ada773fcf3c8bb53001f6135ae877fbc9` |
| Git state | `git_status.txt` |
| Vivado | `v2025.1 (64-bit)` |
| Device | `xcu55c-fsvh2892-2L-e` |
| OOC top | `VX_dma_engine_ooc` |
| Constraint | `hw/syn/xilinx/dut/project.xdc` |
| Unittest | Not run by this synthesis-only script |
| xrt-vcs-sim | Not run by this synthesis-only script |
| OOC synthesis | PASS; see `post_synth_util.rpt` and `post_synth_timing_summary.rpt` |
| Checkpoint | `not-retained` |
| Conclusion | Measurement only; record the decision in the parent experiment manifest |

This script performs only the OOC stage. Structural DMA variants must pass the
unittest and xrt-vcs-sim gates required by
`docs/future_optim/dma_optimization_experiment_rules.md` before invoking it.
