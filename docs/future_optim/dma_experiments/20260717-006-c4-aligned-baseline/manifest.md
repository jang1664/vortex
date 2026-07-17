# DMA OOC Experiment Manifest

| Field | Value |
| --- | --- |
| Experiment ID | `20260717-006-c4-aligned-baseline` |
| Purpose | Establish a reproducible C4 improve DMA OOC synthesis baseline |
| Parent design | Historical C4 full-design report (context only) |
| Baseline design | This experiment starts the fixed OOC baseline series |
| Changed production RTL | None; `VX_dma_engine_ooc` is synthesis infrastructure |
| Backup | Not applicable; no production RTL structure was changed |
| Config | `configs/improve_th16_tcol32_hwexp_dcache.sh` |
| Git commit | `502a49dbb52cb78858d481c8cde29728045551b2` |
| Git state | `git_status.txt` |
| Vivado | `2025.1` |
| Device | `xcu55c-fsvh2892-2L-e` |
| OOC top | `VX_dma_engine_ooc` |
| Constraint | `hw/syn/xilinx/dut/project.xdc` |
| Unittest | Not applicable to baseline measurement; no production RTL changed |
| xrt-vcs-sim | Not applicable to baseline measurement; no production RTL changed |
| OOC synthesis | PASS; see `post_synth_util.rpt` and `post_synth_timing_summary.rpt` |
| Checkpoint | Retained for development-flow debugging; not enabled by default now |
| Conclusion | Keep as the fixed C4-aligned OOC baseline |

This run established the synthesis infrastructure without changing the
production DMA RTL. Structural DMA variants must pass the unittest and
xrt-vcs-sim gates required by
`docs/future_optim/dma_optimization_experiment_rules.md` before OOC synthesis.
